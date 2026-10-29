//============================================================================
//  l2_cache - a second-level cache in block RAM, between ram_arb and main
//  memory's one port.
//
//  WHY. Every first-level miss is a DDR3 round trip, ~20 clocks on the board
//  (docs/design/cache-fill-latency.md section 1), and the measured sluggishness
//  of IRIX is those trips: a real Indy has 1 MB of second-level cache that
//  swallows nearly all of them, this core had none. Replaying the IRIX boot's
//  two cache access streams (tools/l2sim.c, the same traces as icachesim.c and
//  dcachesim.c) through a 128 KB direct-mapped second level: 84 % of the
//  instruction fills and 82 % of the data fills answered on chip against 46 %
//  and 59 % from ram_arb's two-line buffers, and half the DDR3 transactions.
//  The instruction-side figure for the buffers matched the board (43-48 %),
//  the data-side one is a boot trace and the board found the data buffer worth
//  far less than its replay said; status[27] (setopt.sh l2=off) measures it.
//
//  WHAT IT IS. Direct-mapped, 2**IDX_BITS lines of 32 bytes (one line fill),
//  tagged with the RAM OFFSET like ram_arb's buffers, so the low-memory alias
//  and MEMCFG's banks cannot make two names for one line. WRITE-THROUGH, and
//  that is the whole coherence story: every write to main memory - a CPU
//  store, a data cache writeback, every DMA engine - is issued through this
//  module to the port AND merged into the line here if the line is present,
//  so DDR3 is always current and anything that reads DDR3 directly (a DMA
//  engine, an uncached load) needs no help. Only cache line fills look here;
//  everything else passes straight through, same clock, same payload.
//
//  THE BURSTS ARE ITS OWN. An instruction fill that misses here is fetched as
//  ram_arb's 12-word burst - its line and the two after it - and all three
//  land here, so this subsumes the prefetch buffers (sgi_indy.sv turns them
//  off while this is on). A data fill bursts the same way only on a stream,
//  ram_arb's rule. The CPU has its line after the fourth word, as before; the
//  tail of the burst streams in behind, and a request that arrives meanwhile
//  is remembered and issued when the port is free (`pend`; both masters hold
//  their payload until acknowledged, ram_arb.sv's contract).
//
//  MAIN'S WRITES ARE THE ONE HOLE, AND `ext_inval` PLUGS IT. The ARM writes
//  the Ethernet's frames and descriptors into guest RAM without passing this
//  port; it pulses ext_inval afterwards (docs/design/ethernet-plan.md), and
//  that empties this cache: a sweep writes every tag invalid, 2**IDX_BITS
//  clocks. While it runs a fill may only hit a line the sweep has already
//  passed, nothing fetched is kept, and a fill in flight when it starts is not
//  kept either (its words may predate the frame). Two invalidates per received
//  frame is what Main does today; a ranged invalidate is the obvious follow-up
//  if the network ever matters as much as the cache.
//
//  A HIT TAKES ONE RAM LATENCY. The tag and the first word come straight off
//  the RAMs' outputs the clock after the request (build 57; build 56 had a
//  register behind each and measured a hit at ~7 clocks on the bus, which with
//  84 % of instruction fills hitting was the clock worth taking), the other
//  three words one a clock after. A miss is issued to the port in that same
//  clock - one later than it would have been, against the ~20 it is about to
//  spend.
//
//  A PREDICTED MISS SKIPS THE LOOKUP (build 58). That one clock was the whole
//  cost of the cache to anything that streams through memory (IRIS's copy,
//  fill and stream kernels: 1-3 % on build 57, 4-7 % on build 56). After a
//  burst has fetched lines L..L+2, the fill of L+3 on the same side is a miss
//  by construction - the two prefetched lines hit, the third is new - so that
//  fill is issued to the port in the clock it arrives, no tag read first, and
//  streams in like any other fill (its line is marked invalid when the first
//  word lands, valid at the last). A wrong prediction is only a port burst the
//  cache already held - the words are the same, DDR3 is always current - never
//  a wrong answer. `i_next`/`dm_next` hold the prediction for each side.
//
//  Bench: `make -C verilator l2test` (tb_ramarb_pf.cpp driving ram_arb and
//  this together against a slow memory); the whole-machine simulation runs it
//  under the PROM and IRIX.
//============================================================================

module l2_cache #(
    parameter IDX_BITS = 12          // 4096 lines x 32 bytes = 128 KB
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        enable,      // off: every access passes through
    input  logic        ext_inval,   // Main wrote guest RAM: forget everything

    // ---- upstream: ram_arb's port side -----------------------------------
    // One transaction at a time; `up_req` is a one-clock pulse and the
    // payload is held until the last acknowledgement.
    input  logic        up_req,
    input  logic        up_we,
    input  logic [31:0] up_addr,      // RAM offset
    input  logic [63:0] up_wdata,
    input  logic  [7:0] up_be,
    input  logic  [3:0] up_burst,     // 1..4
    input  logic [191:0] up_wdata3,
    input  logic        up_ifill,     // the CPU's instruction line fill
    input  logic        up_dfill,     // the CPU's data line fill
    output logic [63:0] up_rdata,
    output logic        up_ack,
    output logic        up_last,

    // ---- downstream: ddr3_mux's RAM port ---------------------------------
    output logic        dn_req,
    output logic        dn_we,
    output logic [31:0] dn_addr,
    output logic [63:0] dn_wdata,
    output logic  [7:0] dn_be,
    output logic  [3:0] dn_burst,     // 1..4, or 12
    output logic [191:0] dn_wdata3,
    input  logic [63:0] dn_rdata,
    input  logic        dn_ack,
    input  logic        dn_last,

    // ---- observation: a fill answered here / one fetched from memory -----
    output logic        dbg_hit_i,
    output logic        dbg_hit_d,
    output logic        dbg_fill_i,
    output logic        dbg_fill_d
);

    localparam LINE_BITS = 27;                  // up_addr[31:5]
    localparam TAG_BITS  = LINE_BITS - IDX_BITS;
    localparam NLINES    = 1 << IDX_BITS;

    // ---- the arrays: one M10K-shaped RAM each, registered outputs ----------
    // tag_mem: {valid, tag}. data_mem: 64-bit words, no byte enables (a
    // partial store is read, merged and written back, which keeps the data
    // RAM in the densest M10K shape).
    logic [TAG_BITS:0]  tag_mem  [NLINES];
    logic [63:0]        data_mem [NLINES * 4];

    logic [IDX_BITS-1:0] tag_rd_addr, tag_wr_addr;
    logic [TAG_BITS:0]   tag_wr_data, tag_q;
    logic                tag_we;
    logic [IDX_BITS+1:0] data_rd_addr, data_wr_addr;
    logic [63:0]         data_wr_data, data_q;
    logic                data_we;

    always_ff @(posedge clk) begin
        if (tag_we) tag_mem[tag_wr_addr] <= tag_wr_data;
        tag_q  <= tag_mem[tag_rd_addr];
        if (data_we) data_mem[data_wr_addr] <= data_wr_data;
        data_q <= data_mem[data_rd_addr];
    end

    // ---- the request ---------------------------------------------------------
    wire [LINE_BITS-1:0] line   = up_addr[31:5];
    wire [IDX_BITS-1:0]  idx    = line[IDX_BITS-1:0];
    wire [TAG_BITS-1:0]  tag    = line[LINE_BITS-1:IDX_BITS];
    // Only the CPU's line fills carry a burst of 4 without a write, so the
    // flags need no owner check.
    wire                 is_fill = enable && !up_we && (up_burst == 4'd4) && (up_ifill || up_dfill);

    typedef enum logic [2:0] { S_IDLE, S_T1, S_HIT, S_FILL, S_WL } state_t;
    state_t state;

    logic        pend;           // a request arrived while busy
    logic        pt;             // a pass-through transaction is on the port
    logic        sweeping;       // writing every tag invalid
    logic [IDX_BITS-1:0] sweep_idx;

    // The transaction in hand, latched at `go`. The address stays on up_addr
    // until the last acknowledgement (the port needs it there anyway); a
    // write's data is copied because a fast acknowledgement can free the
    // master before the merge two clocks later.
    logic [IDX_BITS-1:0] r_idx;
    logic [TAG_BITS-1:0] r_tag;
    logic        r_fill, r_ifill, r_we, r_wline;
    logic  [1:0] r_word;         // a single write's word within its line
    logic  [7:0] r_be;
    logic [63:0] r_wdata;
    logic [191:0] r_wdata3;
    logic        r_stream;       // data fill on a stream: burst the next two
    logic        r_swept;        // the sweep has passed this line (or none runs)
    logic  [1:0] beat;           // hit: word being presented; fill: word within the line
    logic  [1:0] fline;          // fill: line within the burst (0..2)
    logic [LINE_BITS-1:0] cur_line;   // fill: the line now streaming in
    logic [LINE_BITS-1:0] d_next;     // the line after the previous data fill's
    logic [LINE_BITS-1:0] i_next;     // the line after the last instruction burst: a miss
    logic [LINE_BITS-1:0] dm_next;    // ...and after the last data burst
    logic        fill_kill;      // this fill's lines are not kept

    wire busy = (state != S_IDLE) || pt;
    wire go   = (up_req || pend) && !busy;
    // The fill after the last burst on its side: a miss, issued without a lookup.
    wire spec = is_fill && !sweeping && (line == (up_ifill ? i_next : dm_next));
    wire spec_go = go && spec;

    wire hit  = tag_q[TAG_BITS] && (tag_q[TAG_BITS-1:0] == r_tag) && r_swept;
    wire at_t1 = (state == S_T1);

    // A fill decided this clock: answered here, or fetched.
    wire fill_hit  = at_t1 && r_fill && hit;
    wire fill_miss = at_t1 && r_fill && !hit;
    wire [IDX_BITS-1:0] cur_idx = cur_line[IDX_BITS-1:0];
    wire [TAG_BITS-1:0] cur_tag = cur_line[LINE_BITS-1:IDX_BITS];
    wire fill_word = (state == S_FILL) && dn_ack;

    // ---- the port: pass-throughs the same clock, a miss from S_T1 ----------
    assign dn_req    = (go && (!is_fill || spec)) || fill_miss;
    assign dn_we     = up_we;
    assign dn_addr   = up_addr;
    assign dn_wdata  = up_wdata;
    assign dn_be     = up_be;
    assign dn_burst  = fill_miss ? ((r_ifill || r_stream) && !sweeping ? 4'd12 : 4'd4)
                     : spec_go   ? ((up_ifill || (line == d_next)) ? 4'd12 : 4'd4)
                     :             up_burst;
    assign dn_wdata3 = up_wdata3;

    // ---- upstream answers ------------------------------------------------------
    assign up_ack   = pt ? dn_ack
                    : fill_hit ? 1'b1
                    : (state == S_HIT) ? 1'b1
                    : (fill_word && fline == 2'd0);
    assign up_last  = pt ? dn_last
                    : (state == S_HIT) ? (beat == 2'd3)
                    : (fill_word && fline == 2'd0 && beat == 2'd3);
    assign up_rdata = (fill_hit || state == S_HIT) ? data_q : dn_rdata;

    // ---- RAM ports -----------------------------------------------------------------
    // Reads: a fill's four words issued on consecutive clocks from `go`, a
    // write's own word at `go` (for the merge).
    always_comb begin
        tag_rd_addr  = idx;
        data_rd_addr = {idx, up_we ? up_addr[4:3] : 2'b00};
        case (state)
            S_T1:    data_rd_addr = {r_idx, 2'd1};
            S_HIT:   data_rd_addr = {r_idx, beat + 2'd1};   // beat 1 reads word 2, beat 2 word 3
            default: ;
        endcase
    end

    // Writes to the data RAM: a fill's words, a hit write's merged word, a
    // line write's four words. Never two in one clock: the state machine
    // serialises every transaction.
    wire [63:0] merged = {
        r_be[7] ? r_wdata[63:56] : data_q[63:56],
        r_be[6] ? r_wdata[55:48] : data_q[55:48],
        r_be[5] ? r_wdata[47:40] : data_q[47:40],
        r_be[4] ? r_wdata[39:32] : data_q[39:32],
        r_be[3] ? r_wdata[31:24] : data_q[31:24],
        r_be[2] ? r_wdata[23:16] : data_q[23:16],
        r_be[1] ? r_wdata[15:8]  : data_q[15:8],
        r_be[0] ? r_wdata[7:0]   : data_q[7:0] };
    wire wr_hit = at_t1 && r_we && hit;
    always_comb begin
        data_we      = 1'b0;
        data_wr_addr = {cur_idx, beat};
        data_wr_data = dn_rdata;
        if (fill_word) begin
            data_we = 1'b1;
        end else if (wr_hit) begin
            data_we      = 1'b1;
            data_wr_addr = {r_idx, r_wline ? 2'd0 : r_word};
            data_wr_data = r_wline ? r_wdata : merged;
        end else if (state == S_WL) begin
            data_we      = 1'b1;
            data_wr_addr = {r_idx, beat};
            data_wr_data = (beat == 2'd1) ? r_wdata3[63:0]
                         : (beat == 2'd2) ? r_wdata3[127:64]
                         :                  r_wdata3[191:128];
        end
    end

    // Writes to the tag RAM. A fill's line is marked invalid when its first
    // word lands (the data words are about to change under whatever tag was
    // there) and valid when its last does, unless the sweep says otherwise;
    // the sweep takes the port whenever a fill does not need it.
    wire fill_inv = fill_word && (beat == 2'd0);
    wire fill_val = fill_word && (beat == 2'd3) && !fill_kill && !sweeping && !ext_inval;
    wire sweep_step = sweeping && !fill_inv;
    always_comb begin
        tag_we      = fill_inv || fill_val || sweep_step;
        tag_wr_addr = sweep_step ? sweep_idx : cur_idx;
        tag_wr_data = fill_val ? {1'b1, cur_tag} : {1'b0, cur_tag};
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state      <= S_IDLE;
            pend       <= 1'b0;
            pt         <= 1'b0;
            sweeping   <= 1'b1;          // the tags start as whatever the RAM holds
            sweep_idx  <= '0;
            beat       <= 2'd0;
            fline      <= 2'd0;
            fill_kill  <= 1'b0;
            d_next     <= '0;
            i_next     <= '0;
            dm_next    <= '0;
            r_fill     <= 1'b0;
            r_we       <= 1'b0;
            r_wline    <= 1'b0;
            r_ifill    <= 1'b0;
            r_stream   <= 1'b0;
            r_swept    <= 1'b0;
            cur_line   <= '0;
            r_idx      <= '0;
            r_tag      <= '0;
            r_word     <= 2'd0;
            r_be       <= 8'd0;
            r_wdata    <= 64'd0;
            r_wdata3   <= 192'd0;
        end else begin
            // Remember a pulse that found this busy; forget it once issued.
            if (up_req && !go) pend <= 1'b1;
            else if (go)       pend <= 1'b0;

            // A pass-through holds the port until its last word.
            if (go && !is_fill)        pt <= 1'b1;
            else if (pt && dn_ack && dn_last) pt <= 1'b0;

            // The sweep: every tag invalid, one a clock. One already running
            // needs no restart: nothing is kept while it runs.
            if (ext_inval) begin
                sweeping  <= 1'b1;
                if (!sweeping) sweep_idx <= '0;
            end
            if (sweep_step) begin
                sweep_idx <= sweep_idx + 1'b1;
                if (sweep_idx == {IDX_BITS{1'b1}} && !ext_inval) sweeping <= 1'b0;
            end

            // Whatever is in flight when Main writes is not kept.
            if (ext_inval) fill_kill <= 1'b1;

            case (state)
                S_IDLE: if (go) begin
                    r_idx    <= idx;
                    r_tag    <= tag;
                    r_fill   <= is_fill;
                    r_ifill  <= up_ifill;
                    r_we     <= up_we;
                    r_wline  <= up_we && (up_burst == 4'd4);
                    r_word   <= up_addr[4:3];
                    r_be     <= up_be;
                    r_wdata  <= up_wdata;
                    r_wdata3 <= up_wdata3;
                    r_stream <= up_dfill && (line == d_next);
                    r_swept  <= !sweeping || (idx < sweep_idx);
                    cur_line <= line;
                    fill_kill <= sweeping || ext_inval;
                    if (is_fill && up_dfill) d_next <= line + 1'b1;
                    // A predicted miss streams in at once; other fills and
                    // writes wait for the tag; reads pass through.
                    if (spec) begin
                        state <= S_FILL;
                        beat  <= 2'd0;
                        fline <= 2'd0;
                    end else if (is_fill || up_we) state <= S_T1;
                end

                S_T1: begin
                    beat <= 2'd1;
                    if (r_fill) begin
                        if (hit) state <= S_HIT;
                        else begin
                            state <= S_FILL;
                            beat  <= 2'd0;
                            fline <= 2'd0;
                        end
                    end else if (r_wline && hit) begin
                        state <= S_WL;            // words 1..3 follow
                    end else begin
                        state <= S_IDLE;          // merged word written this clock, or no line
                    end
                end

                S_HIT: begin
                    beat <= beat + 2'd1;
                    if (beat == 2'd3) state <= S_IDLE;
                end

                S_WL: begin
                    beat <= beat + 2'd1;
                    if (beat == 2'd3) state <= S_IDLE;
                end

                S_FILL: begin
                    if (dn_ack) begin
                        beat <= beat + 2'd1;
                        if (beat == 2'd3) begin
                            fline    <= fline + 2'd1;
                            cur_line <= cur_line + 1'b1;
                        end
                        if (dn_last) begin
                            state <= S_IDLE;
                            // The line after this burst is the next miss on this side.
                            if (r_ifill) i_next  <= cur_line + 1'b1;
                            else         dm_next <= cur_line + 1'b1;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    assign dbg_hit_i  = fill_hit  &&  r_ifill;
    assign dbg_hit_d  = fill_hit  && !r_ifill;
    assign dbg_fill_i = (fill_miss &&  r_ifill) || (spec_go &&  up_ifill);
    assign dbg_fill_d = (fill_miss && !r_ifill) || (spec_go && !up_ifill);

endmodule
