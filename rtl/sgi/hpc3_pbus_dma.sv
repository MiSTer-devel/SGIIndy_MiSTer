//============================================================================
//  hpc3_pbus_dma - HPC3's PBUS DMA channels 0-3, the ones audio uses.
//
//  WHAT THIS IS. The descriptor engine behind pbus.bp / pbus.dp / pbus.ctrl
//  for the four channels the HPC3 specification reserves for HAL2 ("Currently
//  audio uses four DMA channels -- PBUS(0:3)", section 2.6.4). Channels 4-7
//  have nothing behind them on an Indy and stay plain storage in sgi_hpc3.
//
//  WHO DRIVES IT, AND WHAT THEY NEED - read out of the two binaries that use
//  it, not out of the spec alone (docs/design/audio.md has the disassembly):
//
//  * IRIX 5.3's kdsp_a2 (hal2_start_dma, /usr/cpu/sysgen/IP22boot/kdsp_a2.o)
//    builds ONE descriptor per ring whose next pointer is ITSELF - no EOX, no
//    XIE - writes pbus.dp, then pbus.ctrl with ch_act|ch_act_ld, and never
//    stops the channel again: hal2_stop_dma rewrites the descriptor in memory
//    to point at a short silent buffer and lets the engine walk onto it. So
//    the engine must fetch every descriptor from memory when it gets to it,
//    and must keep a channel running for as long as its consumer does.
//  * The driver's only clock is this engine's progress. kdsp_timercallback
//    reads pbus.bp, and (bp - ring_base) / 4 is the ring position it moves
//    samples against. bp has to be the address of the next word the codec
//    will take, advancing at the codec's sample rate. A bp that does not move
//    was the whole of the 2026-09-02 desktop freeze (transfer_samps zeroing
//    its ring for ever); see rtl/sgi/hal2.sv.
//  * The PROM's startup tune (0xBFC030B4) builds a chain split at 4 KB
//    boundaries with EOX on the last descriptor, starts channels 1 AND 2 on
//    it, and then polls pbus.ctrl bit 1 of both for up to 3000 ms
//    (0xBFC03578). The channel must go inactive at the end of an EOX buffer.
//
//  REGISTERS, spec section 3.4:
//    bp    +0x0000  the current buffer pointer. The spec says read-only; it is
//                   writable here, as it is in IRIS, because nothing is lost.
//    dp    +0x0004  the next descriptor pointer.
//    ctrl  +0x1000  write: 1 little, 2 receive, 3 flush, 4 ch_act,
//                          5 ch_act_ld, 6 real_time, 15:8 high water,
//                          21:16 fifo_beg, 29:24 fifo_end
//                   read:  0 interrupt (cleared by the read), 1 ch_act
//  A descriptor is three words: buffer address, {EOX 31, EOXP 30, XIE 29,
//  byte count 13:0}, next descriptor.
//
//  THE CONSUMER SIDE. HAL2 asks for one or two 32-bit words of a channel at a
//  time and gets them with `x_ok` saying, per word, whether the channel was
//  running for it. Two words that lie in one aligned doubleword of the current
//  buffer cost ONE memory transaction - a stereo frame is one GIO64 beat on
//  the real machine as well - and that halves what audio costs the memory
//  port. Descriptor fetches take two doubleword reads; they happen once per
//  buffer, which for IRIX's rings is once per ring wrap.
//
//  THE HAZARD. A PIO write to a channel while the engine is in the middle of
//  a memory transaction for it. The spec says software must not do that and
//  "there are no guarantees"; this still must not corrupt anything, so a PIO
//  write to the channel in flight marks it, and the engine drops its own
//  register update when the transaction lands - the value software wrote wins
//  and the word in flight is reported as not delivered.
//============================================================================

module hpc3_pbus_dma #(
    parameter int NCH = 4
)(
    input  logic        clk,
    input  logic        reset,

    // ---- PIO --------------------------------------------------------------
    // A write strobe for one register of one channel. reg: 0 bp, 1 dp, 2 ctrl.
    input  logic        pio_we,
    input  logic  [1:0] pio_ch,
    input  logic  [1:0] pio_reg,
    input  logic [31:0] pio_wdata,
    // A read of ctrl, which clears that channel's interrupt bit.
    input  logic        pio_rd_ctrl,
    // The registers of `rd_ch`, combinationally, for the caller's read mux.
    input  logic  [1:0] rd_ch,
    output logic [31:0] rd_bp,
    output logic [31:0] rd_dp,
    output logic [31:0] rd_ctrl,

    // ---- the consumer (HAL2) ---------------------------------------------
    // Held, with its payload, until x_ack. x_two asks for two consecutive
    // words; x_wdata is {first word, second word} for a write.
    input  logic        x_req,
    input  logic  [1:0] x_ch,
    input  logic        x_we,
    input  logic        x_two,
    input  logic [63:0] x_wdata,
    output logic        x_ack,
    output logic  [1:0] x_ok,        // [1] first word, [0] second word
    output logic [63:0] x_rdata,     // {first word, second word}

    // Interrupt status and running state per channel, for gen.intstat.
    output logic [NCH-1:0] ch_int,
    output logic [NCH-1:0] ch_act,

    // ---- main memory -----------------------------------------------------
    // Held until dma_ack, one transaction at a time, 8-byte aligned.
    output logic        dma_req,
    output logic        dma_we,
    output logic [31:0] dma_addr,
    output logic [63:0] dma_wdata,
    output logic  [7:0] dma_be,
    input  logic [63:0] dma_rdata,
    input  logic        dma_ack,

    // Observation: descriptors fetched, words moved.
    output logic [15:0] dbg_desc,
    output logic [31:0] dbg_words
);

    // ---- per-channel state -------------------------------------------------
    logic [31:0] cbp  [NCH];
    logic [31:0] nbdp [NCH];
    logic [13:0] bc   [NCH];
    logic [NCH-1:0] act, eox, xie, intr, need;

    assign ch_int = intr;
    assign ch_act = act;

    assign rd_bp   = cbp[rd_ch];
    assign rd_dp   = nbdp[rd_ch];
    assign rd_ctrl = {30'h0, act[rd_ch], intr[rd_ch]};

    // ---- the engine ----------------------------------------------------------
    typedef enum logic [1:0] {
        E_IDLE,     // pick the next thing to do
        E_DESC,     // a descriptor read is on the bus
        E_XFER,     // a data transaction is on the bus
        E_ACK       // the consumer's answer is ready
    } e_t;
    e_t          st;
    logic  [1:0] ch;          // channel the engine is working on
    logic        dw;          // which of the descriptor's two reads is out
    logic [31:0] d0, d1;      // descriptor words 0 and 1 as they arrive
    logic        hit;         // a PIO write touched `ch` during the transaction
    logic        pair;        // the data transaction carries two words
    logic        mid;         // an op is parked waiting for its second word
    logic        second;      // the transaction on the bus is the op's second word
    logic        want2;       // the op asked for two words

    // Which running channel wants a descriptor, lowest first.
    logic        any_need;
    logic  [1:0] need_ch;
    always_comb begin
        any_need = 1'b0;
        need_ch  = 2'd0;
        for (int i = NCH - 1; i >= 0; i--)
            if (act[i] && need[i]) begin
                any_need = 1'b1;
                need_ch  = 2'(i);
            end
    end

    // A PIO write that lands on the engine's channel this clock.
    wire pio_on_ch = pio_we && (pio_ch == ch);

    // What E_IDLE issues when it starts a data transaction: the op's first
    // word (and its second with it, when both sit in one doubleword of the
    // buffer), or a parked op's second word.
    wire         go_mid  = !any_need && mid && act[ch];
    wire         go_new  = !any_need && !mid && x_req && !x_ack && act[x_ch];
    wire   [1:0] iss_c   = go_mid ? ch : x_ch;
    wire  [31:0] iss_ad  = cbp[iss_c];
    wire         iss_pr  = go_new && x_two && (iss_ad[2] == 1'b0) && (bc[iss_c] >= 14'd8);

    always_ff @(posedge clk) begin
        if (reset) begin
            st        <= E_IDLE;
            ch        <= 2'd0;
            dw        <= 1'b0;
            hit       <= 1'b0;
            pair      <= 1'b0;
            mid       <= 1'b0;
            second    <= 1'b0;
            want2     <= 1'b0;
            d0        <= 32'h0;
            d1        <= 32'h0;
            x_ack     <= 1'b0;
            x_ok      <= 2'b00;
            x_rdata   <= 64'h0;
            dma_req   <= 1'b0;
            dma_we    <= 1'b0;
            dma_addr  <= 32'h0;
            dma_wdata <= 64'h0;
            dma_be    <= 8'h00;
            dbg_desc  <= 16'h0;
            dbg_words <= 32'h0;
            for (int i = 0; i < NCH; i++) begin
                cbp[i]  <= 32'h0;
                nbdp[i] <= 32'h0;
                bc[i]   <= 14'h0;
            end
            act  <= '0;
            eox  <= '0;
            xie  <= '0;
            intr <= '0;
            need <= '0;
        end else begin
            x_ack <= 1'b0;
            if (dma_ack) dma_req <= 1'b0;

            case (st)
                // ---------------------------------------------------------
                E_IDLE: begin
                    hit <= 1'b0;
                    if (any_need) begin
                        // A running channel with no buffer. Serve it first:
                        // a consumer asking for it is waiting on this anyway.
                        ch       <= need_ch;
                        dw       <= 1'b0;
                        dma_req  <= 1'b1;
                        dma_we   <= 1'b0;
                        dma_addr <= {nbdp[need_ch][31:3], 3'b000};
                        dma_be   <= 8'hFF;
                        st       <= E_DESC;
                    end
                    else if (go_mid || go_new) begin
                        if (go_new) begin
                            want2   <= x_two;
                            x_ok    <= 2'b00;
                            x_rdata <= 64'h0;
                        end
                        ch        <= iss_c;
                        pair      <= iss_pr;
                        second    <= go_mid;
                        dma_req   <= 1'b1;
                        dma_we    <= x_we;
                        dma_addr  <= {iss_ad[31:3], 3'b000};
                        if (iss_pr) begin
                            dma_be    <= 8'hFF;
                            dma_wdata <= x_wdata;
                        end else begin
                            dma_be    <= iss_ad[2] ? 8'h0F : 8'hF0;
                            dma_wdata <= go_mid ? {x_wdata[31:0],  x_wdata[31:0]}
                                                : {x_wdata[63:32], x_wdata[63:32]};
                        end
                        st <= E_XFER;
                    end
                    // The op's second word waited for a buffer and the chain
                    // ended under it; or a new op is for a channel that is not
                    // running. Either way the answer is what is in x_ok now.
                    // `!x_ack`: the consumer is still holding the request it
                    // was answered for in this very clock.
                    else if (mid || (x_req && !x_ack)) begin
                        if (!mid) begin
                            x_ok    <= 2'b00;
                            x_rdata <= 64'h0;
                        end
                        st <= E_ACK;
                    end
                end

                // ---------------------------------------------------------
                // Two doubleword reads: the one holding word 0, then the one
                // holding word 2. Descriptors are quadword aligned (spec
                // 2.6.4), so word 1 comes with word 0 - but a doubleword-only
                // alignment is handled too, word 1 then arriving with word 2.
                E_DESC: begin
                    if (pio_on_ch) hit <= 1'b1;
                    if (dma_ack) begin
                        logic [31:0] w2;
                        logic        fin;
                        logic [31:0] a8;
                        fin = 1'b0;
                        w2  = 32'h0;
                        if (!dw) begin
                            if (nbdp[ch][2] == 1'b0) begin
                                d0 <= dma_rdata[63:32];
                                d1 <= dma_rdata[31:0];
                                a8 = nbdp[ch] + 32'd8;
                            end else begin
                                d0 <= dma_rdata[31:0];
                                a8 = nbdp[ch] + 32'd4;
                            end
                            dw       <= 1'b1;
                            dma_req  <= 1'b1;
                            dma_addr <= {a8[31:3], 3'b000};
                        end else begin
                            fin = 1'b1;
                            if (nbdp[ch][2] == 1'b0) begin
                                w2 = dma_rdata[63:32];
                            end else begin
                                d1 <= dma_rdata[63:32];
                                w2 = dma_rdata[31:0];
                            end
                        end

                        if (hit || pio_on_ch) begin
                            // Software rewrote the channel under us; its
                            // values stand, and it will be looked at afresh.
                            dma_req <= 1'b0;
                            st      <= E_IDLE;
                        end
                        else if (fin) begin
                            logic [31:0] c1;
                            c1 = (nbdp[ch][2] == 1'b0) ? d1 : dma_rdata[63:32];
                            dbg_desc <= dbg_desc + 16'd1;
                            cbp[ch]  <= d0;
                            bc[ch]   <= c1[13:0];
                            eox[ch]  <= c1[31];
                            xie[ch]  <= c1[29];
                            nbdp[ch] <= w2;
                            if (c1[13:0] == 14'd0) begin
                                // An empty buffer: the end of the chain, or
                                // a link to follow on the next pass.
                                if (c1[31]) begin
                                    act[ch]  <= 1'b0;
                                    need[ch] <= 1'b0;
                                    if (c1[29]) intr[ch] <= 1'b1;
                                end
                            end else begin
                                need[ch] <= 1'b0;
                            end
                            st <= E_IDLE;
                        end
                    end
                end

                // ---------------------------------------------------------
                E_XFER: begin
                    if (pio_on_ch) hit <= 1'b1;
                    if (dma_ack) begin
                        logic [31:0] ad, w;
                        logic  [3:0] step;
                        logic [13:0] nbc;
                        ad   = cbp[ch];
                        w    = ad[2] ? dma_rdata[31:0] : dma_rdata[63:32];
                        step = pair ? 4'd8 : 4'd4;
                        nbc  = (bc[ch] > 14'(step)) ? bc[ch] - 14'(step) : 14'd0;

                        if (hit || pio_on_ch) begin
                            // Not delivered: its x_ok bit stays clear.
                            mid <= 1'b0;
                            st  <= E_ACK;
                        end else begin
                            dbg_words <= dbg_words + (pair ? 32'd2 : 32'd1);
                            if (pair) begin
                                x_rdata <= dma_rdata;
                                x_ok    <= 2'b11;
                            end else if (!second) begin
                                x_rdata[63:32] <= w;
                                x_ok[1]        <= 1'b1;
                            end else begin
                                x_rdata[31:0]  <= w;
                                x_ok[0]        <= 1'b1;
                            end

                            cbp[ch] <= ad + {28'h0, step};
                            bc[ch]  <= nbc;
                            if (nbc == 14'd0) begin
                                if (xie[ch]) intr[ch] <= 1'b1;
                                if (eox[ch]) act[ch]  <= 1'b0;
                                else         need[ch] <= 1'b1;
                            end

                            if (pair || second || !want2) begin
                                mid <= 1'b0;
                                st  <= E_ACK;
                            end
                            else if (nbc == 14'd0) begin
                                // The second word is in the next buffer, or
                                // there is none: E_IDLE fetches, then resumes.
                                mid <= 1'b1;
                                st  <= E_IDLE;
                            end
                            else begin
                                // The second word, alone, in this buffer.
                                logic [31:0] na;
                                na = ad + 32'd4;
                                pair      <= 1'b0;
                                second    <= 1'b1;
                                dma_req   <= 1'b1;
                                dma_addr  <= {na[31:3], 3'b000};
                                dma_be    <= na[2] ? 8'h0F : 8'hF0;
                                dma_wdata <= {x_wdata[31:0], x_wdata[31:0]};
                            end
                        end
                    end
                end

                // ---------------------------------------------------------
                E_ACK: begin
                    mid   <= 1'b0;
                    x_ack <= 1'b1;
                    st    <= E_IDLE;
                end

                default: st <= E_IDLE;
            endcase

            // ---- PIO writes, last so they win ------------------------------
            if (pio_we) begin
                case (pio_reg)
                    2'd0: cbp[pio_ch]  <= pio_wdata;
                    2'd1: nbdp[pio_ch] <= pio_wdata;
                    2'd2: if (pio_wdata[5]) begin
                        if (pio_wdata[4]) begin
                            // Start. A channel already running keeps its
                            // place: hal2_start_dma may re-issue ch_act on a
                            // live ring and expects nothing to move.
                            if (!act[pio_ch]) begin
                                act[pio_ch]  <= 1'b1;
                                need[pio_ch] <= 1'b1;
                                bc[pio_ch]   <= 14'd0;
                            end
                        end else begin
                            act[pio_ch]  <= 1'b0;
                            need[pio_ch] <= 1'b0;
                        end
                    end
                    default: ;
                endcase
            end
            if (pio_rd_ctrl) intr[rd_ch] <= 1'b0;
        end
    end

endmodule
