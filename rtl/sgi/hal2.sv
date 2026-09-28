//============================================================================
//  hal2 - the Indy's audio processor: its registers, its clocks, and the
//  sample path from HPC3's PBUS DMA to the MiSTer's audio output.
//
//  WHAT THIS IS. The HAL2 ASIC of SGI's "A2" audio system as the software on
//  an Indy sees it: the five direct registers and the indirect file behind
//  IAR/IDR (PBUS PIO channel 0, 0x1FBD8000), the output volume registers
//  (PIO channel 2, 0x1FBD8800), three Bresenham sample-clock generators, and
//  four DMA ports - codec A out, codec B in, AES out and AES in - each moving
//  32-bit words through one of HPC3's PBUS DMA channels (hpc3_pbus_dma.sv).
//  Only codec A reaches the speakers; the others move data at their rate so
//  that the software driving them sees its rings advance, which is what it
//  waits on. docs/design/audio.md is the design note.
//
//  THE ORACLES, AND WHERE THEY DISAGREE.
//  * IRIS's src/hal2.rs for the IAR decode and the reset values - no datasheet
//    in reference/ covers them. Where a reset value looks arbitrary (the
//    Bresenham clocks come up as sel=1, inc=1, modctrl=0xFFFF) it is IRIS's,
//    and it is what makes the PROM's startup tune play at 44.1 kHz.
//  * IRIX 5.3's kdsp_a2 and the IP24 PROM for everything else, disassembled:
//      - kdsp_a2 hal2_init: DMA enable 0x1E, drive 0x0F; codec A ctrl1 0x210
//        (PBUS channel 0, BRES2, stereo); codec B 0x209 (channel 1, BRES1,
//        stereo); AES RX 0x002; AES TX 0x213 (channel 3, BRES2, stereo); all
//        three generators 48 kHz. Output volume goes to the PIO channel 2
//        registers, 0..255, right at +0 and left at +4 (hal2_volumectrl,
//        dezipper_output_atten; set_audio_params "Left Output Gain" -> +4).
//      - kdsp_a2 hal2_write_codec_regs READS A 32-BIT INDIRECT REGISTER ONE
//        HALF AT A TIME: IAR = 0x1488 then IDR0 is the low word, IAR = 0x1489
//        then IDR0 is the HIGH word. IAR[1:0] is a read-back index, the same
//        thing Linux's hal2_i_look32 does. IRIS ignores it; a
//        read-modify-write of codec ctrl2 would then write the low word into
//        the high one.
//      - PROM 0xBFC00BD0: AES TX ctrl 0x10A (channel 2, BRES1, mono), BRES1
//        44.1 kHz; the startup tune (0xBFC030B4) enables codec A (ctrl1 0x109,
//        channel 1, BRES1, mono) and AES TX together, points PBUS channels 1
//        AND 2 at one ADPCM-decoded chain, and waits for both to finish.
//  * The samples are 24-bit, right-justified and sign-extended in 32-bit
//    words: the PROM's tune decoder stores `sample << 8` (0xBFC0346C), and
//    IRIS takes bits 23:8 for the same reason. The 16-bit DAC gets 23:8.
//
//  THE BOOT HAZARD, still. ISR bit 0 is TSTATUS, "transaction busy", and the
//  PROM and IRIX spin on it after every IAR write. Every indirect transaction
//  here completes in the cycle IAR is written, so it reads 0 always. If it is
//  ever made to stick, the boot hangs in POST with nothing to say it was the
//  audio chip.
//
//  `present` IS THE OSD'S AUDIO SWITCH. With it low REV reads 0xC010 - bit 15
//  set, "no audio" - and the PROM skips its tune, IRIX's audio.sm probe fails
//  (exprobe of REV with mask 0x8000) and kdsp_a2 is never loaded: the machine
//  as it was before there was a sample path, and the way out if this one ever
//  misbehaves.
//============================================================================

module hal2 #(
    parameter int CLK_HZ = 50_000_000
)(
    input  logic        clk,
    input  logic        reset,
    input  logic        present,

    // ---- register port ---------------------------------------------------
    // An access to PBUS PIO channels 0-3, already decoded by sgi_hpc3.
    //   win  0 = HAL2 (0x58000), 1 = AES (0x58400), 2 = volume (0x58800),
    //        3 = synth (0x58C00)
    //   dsel = address bits 7:3 within the window - the doubleword
    // The HAL2 registers are 16 bytes apart, so dsel[4:1] names one whichever
    // half of the doubleword is addressed. The volume registers are 4 apart:
    // right at +0 (the doubleword's first half), left at +4. `wsel` says which
    // half a write carries: 0 the +0 word, 1 the +4 word.
    input  logic        sel,
    input  logic        we,
    input  logic  [1:0] win,
    input  logic  [4:0] dsel,
    input  logic        wsel,
    input  logic [15:0] wdata,
    output logic [15:0] rdata0,       // the doubleword's +0 word
    output logic [15:0] rdata1,       // and its +4 word

    // ---- PBUS DMA (hpc3_pbus_dma's consumer port) -------------------------
    output logic        x_req,
    output logic  [1:0] x_ch,
    output logic        x_we,
    output logic        x_two,
    output logic [63:0] x_wdata,
    input  logic        x_ack,
    input  logic  [1:0] x_ok,
    input  logic [63:0] x_rdata,

    // ---- the DAC ----------------------------------------------------------
    // Signed 16-bit, clk domain, changing at codec A's sample rate.
    output logic [15:0] audio_l,
    output logic [15:0] audio_r,

    // ---- observation --------------------------------------------------------
    //   dbg[0] {codec A frames played,        DMA ops finished}
    //   dbg[1] {underruns /16, overruns /16,  peak |sample| since reset, last left}
    output logic [63:0] dbg [2]
);

    //========================================================================
    // Registers
    //========================================================================

    localparam logic [3:0] R_ISR  = 4'h1;
    localparam logic [3:0] R_REV  = 4'h2;
    localparam logic [3:0] R_IAR  = 4'h3;
    localparam logic [3:0] R_IDR0 = 4'h4;
    localparam logic [3:0] R_IDR1 = 4'h5;
    localparam logic [3:0] R_IDR2 = 4'h6;
    localparam logic [3:0] R_IDR3 = 4'h7;

    // REV. Bit 15 clear means "audio present"; the PROM's node printer splits
    // the rest as (v>>12)&7 . (v>>4)&F . v&F, so 0x4010 prints as 4.1.0 and
    // the "A2" beside it in hinv is a string in the PROM, not a field here.
    wire [15:0] rev_value = present ? 16'h4010 : 16'hC010;

    // ---- IAR decode ------------------------------------------------------
    // iar[15:12] type   iar[11:8] number   iar[7] 1 = read, 0 = write
    // iar[3:2] parameter   iar[1:0] read-back index (which 16-bit word of the
    // indirect register a read puts in IDR0)
    localparam logic [3:0] TYPE_DMA        = 4'h1;   // codec / AES control
    localparam logic [3:0] TYPE_BRES       = 4'h2;   // Bresenham clock generators
    localparam logic [3:0] TYPE_GLOBAL_DMA = 4'h9;   // enable / drive / endian / relay

    localparam logic [3:0] NUM_AES_RX = 4'h2;
    localparam logic [3:0] NUM_AES_TX = 4'h3;
    localparam logic [3:0] NUM_CODECA = 4'h4;
    localparam logic [3:0] NUM_CODECB = 4'h5;

    // DMA enable bits, IRIS's DMA_EN_*: which of the four ports runs.
    localparam int EN_AESRX = 1, EN_AESTX = 2, EN_CODECA = 3, EN_CODECB = 4;

    // ---- state -----------------------------------------------------------
    // Only the three writable ISR bits are stored; TSTATUS and USTATUS read 0.
    logic  [2:0] isr;      // {CODEC_RESET_N, GLOBAL_RESET_N, CODEC_MODE}
    logic [15:0] iar;
    logic [15:0] idr [0:3];

    // ctrl[0] is CTRL1 (from IDR0); ctrl[1] and ctrl[2] are CTRL2's low and
    // high words, which arrive together in IDR0 and IDR1.
    logic [15:0] codeca_ctrl [0:2];
    logic [15:0] codecb_ctrl [0:2];
    logic [15:0] aestx_ctrl  [0:2];
    logic [15:0] aesrx_ctrl  [0:2];

    // Bresenham generators 1..3, indexed 0..2. CTRL1 is the master select,
    // CTRL2 is {IDR0 = inc, IDR1 = modctrl} and the modulus is
    // (inc - modctrl - 1) & 0xFFFF, as Linux's hal2_set_dac_rate writes it.
    logic [15:0] bres_sel     [0:2];
    logic [15:0] bres_inc     [0:2];
    logic [15:0] bres_modctrl [0:2];

    logic [15:0] dma_enable, dma_drive, dma_endian, dma_relay;

    // Output volume, PIO channel 2. 255 is full level.
    logic  [7:0] vol_r, vol_l;

    // ISR is read-only in its low two bits and read/write in the three above.
    wire [15:0] isr_rd = {11'h0, isr, 2'b00};

    // ---- reads -----------------------------------------------------------
    wire [3:0] regsel = dsel[4:1];
    logic [15:0] core_rd;
    always_comb begin
        case (regsel)
            R_ISR:   core_rd = isr_rd;
            R_REV:   core_rd = rev_value;
            R_IAR:   core_rd = iar;
            R_IDR0:  core_rd = idr[0];
            R_IDR1:  core_rd = idr[1];
            R_IDR2:  core_rd = idr[2];
            R_IDR3:  core_rd = idr[3];
            default: core_rd = 16'h0;
        endcase
        rdata0 = 16'h0;
        rdata1 = 16'h0;
        if (win == 2'd0) begin
            // Both halves show the register the doubleword names, as the
            // constant this used to be did.
            rdata0 = core_rd;
            rdata1 = core_rd;
        end else if (win == 2'd2 && dsel == 5'd0) begin
            rdata0 = {8'h0, vol_r};
            rdata1 = {8'h0, vol_l};
        end
        // The AES and synth windows read zero. kdsp_a2 only writes them (its
        // read-backs were compiled away), and the PROM does not look.
    end

    // One indirect register as its two 16-bit words, for a read.
    function automatic logic [31:0] ind_value(input logic [15:0] v);
        logic [31:0] r;
        logic [3:0]  ty, nm;
        logic [1:0]  pa;
        ty = v[15:12]; nm = v[11:8]; pa = v[3:2];
        r = 32'h0;
        if (ty == TYPE_GLOBAL_DMA) begin
            if      (pa == 2'd0) r = {16'h0, dma_relay};
            else if (pa == 2'd1) r = {16'h0, dma_enable};
            else if (pa == 2'd2) r = {16'h0, dma_endian};
            else                 r = {16'h0, dma_drive};
        end
        else if (ty == TYPE_DMA) begin
            if (nm == NUM_CODECA) begin
                if (pa == 2'd1) r = {16'h0, codeca_ctrl[0]};
                if (pa == 2'd2) r = {codeca_ctrl[2], codeca_ctrl[1]};
            end else if (nm == NUM_CODECB) begin
                if (pa == 2'd1) r = {16'h0, codecb_ctrl[0]};
                if (pa == 2'd2) r = {codecb_ctrl[2], codecb_ctrl[1]};
            end else if (nm == NUM_AES_TX) begin
                if (pa == 2'd1) r = {16'h0, aestx_ctrl[0]};
                if (pa == 2'd2) r = {aestx_ctrl[2], aestx_ctrl[1]};
            end else if (nm == NUM_AES_RX) begin
                if (pa == 2'd1) r = {16'h0, aesrx_ctrl[0]};
                if (pa == 2'd2) r = {aesrx_ctrl[2], aesrx_ctrl[1]};
            end
        end
        else if (ty == TYPE_BRES && nm >= 4'd1 && nm <= 4'd3) begin
            if (pa == 2'd1) r = {16'h0, bres_sel[nm[1:0] - 2'd1]};
            if (pa == 2'd2) r = {bres_modctrl[nm[1:0] - 2'd1], bres_inc[nm[1:0] - 2'd1]};
        end
        ind_value = r;
    endfunction

    wire [31:0] ind_rd = ind_value(wdata);

    // The strobes. A write to ISR with GLOBAL_RESET_N (bit 3) low resets the
    // chip's indirect state, with CODEC_RESET_N (bit 4) low the codec and AES
    // ports: IRIS's reading of the a2diags reset sequence (ISR 0, wait, 0x18).
    wire w_core  = sel && we && (win == 2'd0);
    wire w_isr   = w_core && (regsel == R_ISR);
    wire w_iar   = w_core && (regsel == R_IAR);
    wire g_reset = w_isr && !wdata[3];
    wire c_reset = w_isr &&  wdata[3] && !wdata[4];
    wire i_write = w_iar && !wdata[7];
    wire [1:0] bn = wdata[9:8] - 2'd1;     // generator 1..3 as 0..2

    // The direct registers and the volume.
    always_ff @(posedge clk) begin
        if (reset) begin
            isr   <= 3'h0;
            iar   <= 16'h0;
            vol_r <= 8'hFF;
            vol_l <= 8'hFF;
            for (int i = 0; i < 4; i++) idr[i] <= 16'h0;
        end else begin
            if (sel && we && win == 2'd2 && dsel == 5'd0) begin
                if (wsel) vol_l <= wdata[7:0];
                else      vol_r <= wdata[7:0];
            end
            if (w_core) begin
                case (regsel)
                    R_ISR:  isr    <= wdata[4:2];
                    R_IDR0: idr[0] <= wdata;
                    R_IDR1: idr[1] <= wdata;
                    R_IDR2: idr[2] <= wdata;
                    R_IDR3: idr[3] <= wdata;
                    // THE WRITE TO IAR IS THE TRANSACTION. A read puts the
                    // word the read-back index names into IDR0; index 0 also
                    // leaves the high word in IDR1, which is what IRIS does
                    // and what a driver reading both halves from IDR0/IDR1
                    // expects. (The write direction is the block below.)
                    R_IAR: begin
                        iar <= wdata;
                        if (wdata[7]) begin
                            if (wdata[1:0] == 2'd0) begin
                                idr[0] <= ind_rd[15:0];
                                idr[1] <= ind_rd[31:16];
                            end else begin
                                idr[0] <= ind_rd[31:16];
                            end
                        end
                    end
                    default: ;
                endcase
            end
        end
    end

    // The indirect file: written from IDR by an IAR write with bit 7 clear.
    // It decodes the value being written, not the stored one - the
    // transaction happens on that write.
    always_ff @(posedge clk) begin
        if (reset) begin
            dma_endian <= 16'h0;
            dma_relay  <= 16'h0;
        end else if (i_write && wdata[15:12] == TYPE_GLOBAL_DMA) begin
            if (wdata[3:2] == 2'd0) dma_relay  <= idr[0];
            if (wdata[3:2] == 2'd2) dma_endian <= idr[0];
        end

        if (reset || g_reset) begin
            dma_enable <= 16'h0;
            dma_drive  <= 16'h0;
            for (int i = 0; i < 3; i++) begin
                codeca_ctrl[i]  <= 16'h0;
                codecb_ctrl[i]  <= 16'h0;
                aestx_ctrl[i]   <= 16'h0;
                aesrx_ctrl[i]   <= 16'h0;
                // IRIS's reset values: 44100 Hz master, inc 1, mod 1 encoded
                // as 1-1-1 = 0xFFFF.
                bres_sel[i]     <= 16'h0001;
                bres_inc[i]     <= 16'h0001;
                bres_modctrl[i] <= 16'hFFFF;
            end
        end else if (c_reset) begin
            dma_enable <= dma_enable & ~16'h001E;
            for (int i = 0; i < 3; i++) begin
                codeca_ctrl[i] <= 16'h0;
                codecb_ctrl[i] <= 16'h0;
                aestx_ctrl[i]  <= 16'h0;
                aesrx_ctrl[i]  <= 16'h0;
            end
        end else if (i_write) begin
            case (wdata[15:12])
                TYPE_GLOBAL_DMA: begin
                    if (wdata[3:2] == 2'd1) dma_enable <= idr[0];
                    if (wdata[3:2] == 2'd3) dma_drive  <= idr[0];
                end
                TYPE_DMA:
                    case (wdata[11:8])
                        NUM_CODECA:
                            if (wdata[3:2] == 2'd1) codeca_ctrl[0] <= idr[0];
                            else if (wdata[3:2] == 2'd2) begin
                                codeca_ctrl[1] <= idr[0];
                                codeca_ctrl[2] <= idr[1];
                            end
                        NUM_CODECB:
                            if (wdata[3:2] == 2'd1) codecb_ctrl[0] <= idr[0];
                            else if (wdata[3:2] == 2'd2) begin
                                codecb_ctrl[1] <= idr[0];
                                codecb_ctrl[2] <= idr[1];
                            end
                        NUM_AES_TX:
                            if (wdata[3:2] == 2'd1) aestx_ctrl[0] <= idr[0];
                            else if (wdata[3:2] == 2'd2) begin
                                aestx_ctrl[1] <= idr[0];
                                aestx_ctrl[2] <= idr[1];
                            end
                        NUM_AES_RX:
                            if (wdata[3:2] == 2'd1) aesrx_ctrl[0] <= idr[0];
                            else if (wdata[3:2] == 2'd2) begin
                                aesrx_ctrl[1] <= idr[0];
                                aesrx_ctrl[2] <= idr[1];
                            end
                        default: ;
                    endcase
                TYPE_BRES:
                    if (wdata[11:8] >= 4'd1 && wdata[11:8] <= 4'd3) begin
                        if (wdata[3:2] == 2'd1) bres_sel[bn] <= idr[0];
                        if (wdata[3:2] == 2'd2) begin
                            bres_inc[bn]     <= idr[0];
                            bres_modctrl[bn] <= idr[1];
                        end
                    end
                default: ;
            endcase
        end
    end

    //========================================================================
    // Sample clocks
    //========================================================================
    // Two masters, 48 kHz and 44.1 kHz, as exact long-run averages of the
    // core clock; a Bresenham generator then divides one of them by
    // mod/inc. CTRL1 value 2 (the AES receiver's recovered clock) has no
    // receiver behind it and runs from the 48 kHz master.
    logic [26:0] m48_acc, m44_acc;
    logic        t48, t44;
    always_ff @(posedge clk) begin
        if (reset) begin
            m48_acc <= 27'd0;
            m44_acc <= 27'd0;
            t48     <= 1'b0;
            t44     <= 1'b0;
        end else begin
            if (m48_acc + 27'd48000 >= 27'(CLK_HZ)) begin
                m48_acc <= m48_acc + 27'd48000 - 27'(CLK_HZ);
                t48     <= 1'b1;
            end else begin
                m48_acc <= m48_acc + 27'd48000;
                t48     <= 1'b0;
            end
            if (m44_acc + 27'd44100 >= 27'(CLK_HZ)) begin
                m44_acc <= m44_acc + 27'd44100 - 27'(CLK_HZ);
                t44     <= 1'b1;
            end else begin
                m44_acc <= m44_acc + 27'd44100;
                t44     <= 1'b0;
            end
        end
    end

    logic [16:0] b_acc [0:2];
    logic  [2:0] btick;             // generator n+1 produced a sample clock
    always_ff @(posedge clk) begin
        if (reset) begin
            for (int i = 0; i < 3; i++) b_acc[i] <= 17'd0;
            btick <= 3'b000;
        end else begin
            for (int i = 0; i < 3; i++) begin
                logic        mt;
                logic [15:0] md;
                logic [16:0] na;
                mt = (bres_sel[i][1:0] == 2'd1) ? t44 : t48;
                md = bres_inc[i] - bres_modctrl[i] - 16'd1;
                na = b_acc[i] + {1'b0, bres_inc[i]};
                btick[i] <= 1'b0;
                if (mt) begin
                    if (md == 16'd0 || bres_inc[i] == 16'd0) begin
                        b_acc[i] <= 17'd0;
                    end else if (na >= {1'b0, md}) begin
                        btick[i] <= 1'b1;
                        // Never more than one clock per master tick; a
                        // setting faster than its master just runs at it.
                        b_acc[i] <= (na - {1'b0, md} >= {1'b0, md}) ? 17'd0
                                                                   : na - {1'b0, md};
                    end else begin
                        b_acc[i] <= na;
                    end
                end
            end
        end
    end

    //========================================================================
    // The four DMA ports
    //========================================================================
    // Port 0 codec A (out, the DAC), 1 codec B (in), 2 AES TX (out), 3 AES RX
    // (in). CTRL1 of each: [2:0] PBUS channel, [4:3] clock = generator number
    // 1..3 (0 = none; IRIS 39d304f), [9:8] mode 1 mono, 2 stereo, 3 quad.
    // A port runs while its DMA enable bit is set and it has a clock and a
    // mode; the inputs deliver silence. Only PBUS channels 0-3 have an engine
    // behind them (the spec's audio channels); a port pointed elsewhere
    // stands still.
    logic [15:0] pcfg [4];
    logic  [3:0] pen;
    assign pcfg[0] = codeca_ctrl[0];
    assign pcfg[1] = codecb_ctrl[0];
    assign pcfg[2] = aestx_ctrl[0];
    assign pcfg[3] = aesrx_ctrl[0];
    assign pen     = {dma_enable[EN_AESRX], dma_enable[EN_AESTX],
                      dma_enable[EN_CODECB], dma_enable[EN_CODECA]};

    // A generator's clock by its number; 0 is none.
    // (The ticks are an argument, not read from the module: Quartus 17 then
    // warns they are never read, and nothing is left to wonder about.)
    function automatic logic gen_tick(input logic [2:0] bt, input logic [1:0] n);
        gen_tick = (n == 2'd1) ? bt[0] : (n == 2'd2) ? bt[1]
                 : (n == 2'd3) ? bt[2] : 1'b0;
    endfunction

    logic [3:0] prun, ptick;
    always_comb begin
        for (int p = 0; p < 4; p++) begin
            prun[p]  = present && pen[p] && (pcfg[p][4:3] != 2'd0)
                    && (pcfg[p][9:8] != 2'd0) && (pcfg[p][2] == 1'b0);
            ptick[p] = prun[p] && gen_tick(btick, pcfg[p][4:3]);
        end
    end

    // Frames owed per port, and the words left of the frame in progress.
    logic  [1:0] pend [4];
    logic  [2:0] left;             // words still to move for the current frame
    logic  [1:0] cur;              // port being served
    logic        busy;             // an op is on x_*
    logic        first;            // the op is the frame's first
    logic [15:0] ovr_cnt, und_cnt;

    function automatic logic [2:0] frame_words(input logic [1:0] mode);
        frame_words = (mode == 2'd1) ? 3'd1 : (mode == 2'd2) ? 3'd2 : 3'd4;
    endfunction

    // Next port with a frame owed, round robin after the one just served.
    logic        pick_any;
    logic  [1:0] pick;
    always_comb begin
        pick_any = 1'b0;
        pick     = 2'd0;
        for (int k = 4; k >= 1; k--) begin
            if (pend[2'(cur + 2'(k))] != 2'd0 && prun[2'(cur + 2'(k))]) begin
                pick_any = 1'b1;
                pick     = 2'(cur + 2'(k));
            end
        end
    end

    // The op in flight finishes this clock, and with it the frame.
    wire  [2:0] left_n     = left - (x_two ? 3'd2 : 3'd1);
    wire        frame_done = busy && x_ack && (left_n == 3'd0 || !prun[cur]);

    // Codec A's samples: the frame being played, and the one fetched ahead.
    logic signed [15:0] play_l, play_r, next_l, next_r;
    logic               next_v;
    logic [31:0]        frames_a, ops_n;

    always_ff @(posedge clk) begin
        if (reset) begin
            for (int p = 0; p < 4; p++) pend[p] <= 2'd0;
            left     <= 3'd0;
            cur      <= 2'd0;
            busy     <= 1'b0;
            first    <= 1'b0;
            x_req    <= 1'b0;
            x_ch     <= 2'd0;
            x_we     <= 1'b0;
            x_two    <= 1'b0;
            x_wdata  <= 64'h0;
            play_l   <= 16'sd0;
            play_r   <= 16'sd0;
            next_l   <= 16'sd0;
            next_r   <= 16'sd0;
            next_v   <= 1'b0;
            frames_a <= 32'd0;
            ops_n    <= 32'd0;
            ovr_cnt  <= 16'd0;
            und_cnt  <= 16'd0;
        end else begin
            // ---- frames owed: +1 per sample clock, -1 per frame moved -----
            for (int p = 0; p < 4; p++) begin
                logic inc, dec;
                inc = ptick[p];
                dec = frame_done && (cur == 2'(p));
                if (!prun[p])                   pend[p] <= 2'd0;
                else if (inc && !dec) begin
                    if (pend[p] != 2'd3)        pend[p] <= pend[p] + 2'd1;
                    else                        ovr_cnt <= ovr_cnt + 16'd1;
                end
                else if (dec && !inc && pend[p] != 2'd0)
                                                pend[p] <= pend[p] - 2'd1;
            end

            // ---- codec A plays the frame fetched ahead at its clock ---------
            if (!prun[0]) begin
                play_l <= 16'sd0;
                play_r <= 16'sd0;
                next_v <= 1'b0;
            end else if (ptick[0]) begin
                if (next_v) begin
                    play_l   <= next_l;
                    play_r   <= next_r;
                    frames_a <= frames_a + 32'd1;
                end else begin
                    und_cnt  <= und_cnt + 16'd1;
                end
            end
            // (next_v is cleared by the tick and set by a fetch; a fetch
            // landing in the same clock as the tick wins, below.)
            if (prun[0] && ptick[0]) next_v <= 1'b0;

            // ---- one op at a time on the DMA port -------------------------
            if (!busy) begin
                if (pick_any) begin
                    logic [2:0] fw;
                    fw      = frame_words(pcfg[pick][9:8]);
                    cur     <= pick;
                    busy    <= 1'b1;
                    first   <= 1'b1;
                    left    <= fw;
                    x_req   <= 1'b1;
                    x_ch    <= pcfg[pick][1:0];
                    // Ports 1 and 3 are the inputs: they write silence.
                    x_we    <= pick[0];
                    x_two   <= (fw >= 3'd2);
                    x_wdata <= 64'h0;
                end
            end else if (x_ack) begin
                ops_n <= ops_n + 32'd1;
                // Codec A's first op of a frame is the frame's left and right.
                if (cur == 2'd0 && first && prun[0]) begin
                    logic signed [15:0] l, r;
                    l = x_ok[1] ? x_rdata[55:40] : 16'sd0;
                    r = (pcfg[0][9:8] == 2'd1) ? l
                      : (x_ok[0] ? x_rdata[23:8] : 16'sd0);
                    next_l <= l;
                    next_r <= r;
                    next_v <= 1'b1;
                end
                first <= 1'b0;
                left  <= left_n;
                if (frame_done) begin
                    x_req <= 1'b0;
                    busy  <= 1'b0;
                end else begin
                    // A quad frame's second pair.
                    x_two <= (left_n >= 3'd2);
                end
            end
        end
    end

    //========================================================================
    // Output level
    //========================================================================
    // The codec's own attenuation (CTRL2 high word: left 11:7, right 6:2, in
    // 1.5 dB steps) and mute (CTRL2 low word bit 10), as Linux's hal2 driver
    // uses them - IRIX leaves both at zero - and then the Indy's volume
    // registers, which is what IRIX's audio panel and the front-panel
    // buttons move. 255 is unity.
    function automatic logic [15:0] att_gain(input logic [4:0] a);
        case (a)
            5'd0:  att_gain = 16'd65535;  5'd1:  att_gain = 16'd55141;
            5'd2:  att_gain = 16'd46395;  5'd3:  att_gain = 16'd39037;
            5'd4:  att_gain = 16'd32845;  5'd5:  att_gain = 16'd27636;
            5'd6:  att_gain = 16'd23253;  5'd7:  att_gain = 16'd19565;
            5'd8:  att_gain = 16'd16462;  5'd9:  att_gain = 16'd13851;
            5'd10: att_gain = 16'd11654;  5'd11: att_gain = 16'd9806;
            5'd12: att_gain = 16'd8250;   5'd13: att_gain = 16'd6942;
            5'd14: att_gain = 16'd5841;   5'd15: att_gain = 16'd4914;
            5'd16: att_gain = 16'd4135;   5'd17: att_gain = 16'd3479;
            5'd18: att_gain = 16'd2927;   5'd19: att_gain = 16'd2463;
            5'd20: att_gain = 16'd2072;   5'd21: att_gain = 16'd1744;
            5'd22: att_gain = 16'd1467;   5'd23: att_gain = 16'd1234;
            5'd24: att_gain = 16'd1039;   5'd25: att_gain = 16'd874;
            5'd26: att_gain = 16'd735;    5'd27: att_gain = 16'd619;
            5'd28: att_gain = 16'd521;    5'd29: att_gain = 16'd438;
            5'd30: att_gain = 16'd369;    default: att_gain = 16'd310;
        endcase
    endfunction

    wire        mute  = codeca_ctrl[1][10];
    wire  [8:0] vml   = {1'b0, vol_l} + {8'h0, vol_l[7]};   // 0..256
    wire  [8:0] vmr   = {1'b0, vol_r} + {8'h0, vol_r[7]};

    // Two registered stages: the combined gain, then the product. The sample
    // changes at 48 kHz at the most, so the two clocks of latency are nothing.
    logic [24:0] g_l, g_r;
    logic signed [33:0] p_l, p_r;
    always_ff @(posedge clk) begin
        g_l <= att_gain(codeca_ctrl[2][11:7]) * vml;
        g_r <= att_gain(codeca_ctrl[2][6:2])  * vmr;
        p_l <= play_l * $signed({1'b0, g_l[24:8]});
        p_r <= play_r * $signed({1'b0, g_r[24:8]});
        if (reset || !present || mute) begin
            audio_l <= 16'h0;
            audio_r <= 16'h0;
        end else begin
            audio_l <= p_l[31:16];
            audio_r <= p_r[31:16];
        end
    end

    // ---- observation -----------------------------------------------------
    logic [15:0] peak;
    always_ff @(posedge clk) begin
        if (reset) peak <= 16'd0;
        else begin
            logic [15:0] m;
            m = play_l[15] ? 16'(-play_l) : play_l;
            if (m > peak) peak <= m;
        end
    end
    assign dbg[0] = {frames_a, ops_n};
    assign dbg[1] = {und_cnt, ovr_cnt, peak, play_l};

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = |{dma_drive, dma_endian, dma_relay, isr, idr[2], idr[3],
                    codecb_ctrl[1], codecb_ctrl[2], aestx_ctrl[1], aestx_ctrl[2],
                    aesrx_ctrl[1], aesrx_ctrl[2], bres_sel[0][15:2],
                    bres_sel[1][15:2], bres_sel[2][15:2], m48_acc, m44_acc};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
