//============================================================================
//  ram_arb - the CPU and the DMA engines sharing main memory's ONE port.
//
//  This is the only arbiter in the core, and it is deliberately not a bus
//  arbiter: it covers the single main-memory port on rtl/mister/ddr3_mux.sv,
//  because the descriptors and buffers the HPC3's SCSI channel and the MC's
//  GIO64 fill engine touch are in main memory and nothing else here masters
//  anything. The Ethernet channels will want the same port and this will
//  serve them; a general crossbar is work nobody has asked for.
//
//  THE TWO MASTERS HAVE DIFFERENT SHAPES AND THAT IS THE WHOLE DIFFICULTY.
//  The CPU PULSES: rtl/cpu/r4300_bus.sv raises `bus_req` for exactly one
//  cycle and then waits in S_BUSY for an acknowledgement, holding its address
//  and write data but not its request. The DMA engines HOLD, because a master
//  that dropped its request into a variable-latency memory would wait forever
//  for an answer nobody had heard. A request that is caught or lost, sharing
//  a port with one that is caught repeatedly.
//
//  WHY THIS IS ITS OWN FILE. It used to be twenty lines inside sgi_indy.sv,
//  and those twenty lines had a bug that no simulation in this repository
//  could see, because `verilator/sim_ram.v` answers in ONE CYCLE and DDR3
//  answers in tens. Pulling it out buys exactly one thing and it is the thing
//  that mattered: it can be driven on its own against a memory that is as slow
//  as the real bridge. `make -C verilator ramarbtest` is that, and it fails
//  against the old logic at any latency above one.
//
//  THE BUG, WRITTEN DOWN SO IT IS NOT REINVENTED. The old version gated the
//  DMA on a transaction being in flight and did not gate the CPU:
//
//      wire cpu_ram_req = bus_req && sel_ram && mem_hit;
//      wire dma_grant   = dma_req && !ram_inflight && !cpu_ram_req && dma_hit;
//      assign ram_req   = cpu_ram_req | dma_grant;
//      ... else if (ram_req) begin
//              ram_inflight  <= 1'b1;
//              ram_owner_dma <= dma_grant;      // <-- clobbered mid-flight
//
//  So a CPU access landing anywhere inside a DMA transaction's round trip
//  asserted `ram_req` again and rewrote `ram_owner_dma` to 0 while the DMA's
//  answer was still coming. Three separate things then went wrong from that
//  one line, and all three were seen on hardware before the cause was:
//
//    * the CPU took the DMA's acknowledgement as its own, with the DMA's data
//      on it - a load returning a descriptor word or a disk byte instead of
//      what was asked for. It showed up as the PROM dereferencing a garbage
//      pointer: `lbu $v0, ($t6)` two instructions after `lw $t6, 0x148($a0)`,
//      panicking with bad addresses of 0xf103, 0x747474 and 0x9fc1dc77 on
//      three different boots - values that appear nowhere in the PROM image.
//    * the DMA never got an acknowledgement at all, so a SCSI command hung.
//      That is what made POST's device/cable diagnostic report the disk as
//      failed while the CD-ROM beside it passed.
//    * ddr3_mux drops a request for a master that already has one pending, so
//      the CPU's access was silently lost and only the misrouted ack ever
//      arrived. Whichever way it fell, the machine wedged or panicked.
//
//  IT WAS INVISIBLE IN SIMULATION FOR A REASON WORTH REMEMBERING. The window
//  is exactly as wide as memory is slow. With sim_ram's one-cycle answer the
//  DMA's transaction is in flight for a single cycle, and in the cycle it is
//  granted the CPU is by definition not asking - `dma_grant` requires
//  `!cpu_ram_req` - so there is very nearly no window at all. Against DDR3 it
//  is tens of cycles wide and gets hit constantly. This is the FOURTH time on
//  this project that a unit test whose memory model was kinder than the bridge
//  hid the whole bug; see the same note in ddr3_mux.sv and fb_linecache.sv.
//
//  THE FIX IS TO GATE BOTH MASTERS ON THE SAME THING AND REMEMBER THE PULSE.
//  One transaction on this port at a time, for either master, which is what
//  ddr3_mux can actually hold. The CPU cannot simply be stalled, because its
//  request is a pulse and stalling it drops it - so a CPU access that arrives
//  during a transaction is latched in `cpu_wait` and issued when the port is
//  free. Its payload needs no latch: r4300_bus.sv holds `bus_addr`, `bus_we`,
//  `bus_wdata` and `bus_be` from the cycle it raises `bus_req` until the cycle
//  it is acknowledged, which is exactly the interval this has to bridge.
//
//  THE INSTRUCTION PREFETCH BUFFER (build 46). Half of all instruction-cache
//  misses are to the line after the previous miss - 53.4 % of the 588,454 in
//  the IRIX boot trace (sim --itrace; docs/design/cache-fill-latency.md) - and
//  each costs a whole DDR3 round trip, ~20 clocks on the board, of which the
//  bridge's 9.5 are paid once per request however many words follow. So an
//  instruction line fill that misses here goes to the port as a 12-word
//  burst: words 0-3 are the line, answered to the CPU exactly as before with
//  `cpu_last` on the fourth; words 4-11 are the next two lines, kept in
//  `pf_mem`. A later instruction fill of either line is answered from here -
//  four words starting the clock after its request, no port transaction at
//  all. The replay said a burst of three lines leaves 54 % of the fills; the
//  eight extra words cost the port eight clocks, after the CPU has its line.
//
//  IT IS COHERENT BY SNOOPING, AND THIS IS THE ONE PLACE THAT CAN. Every write
//  to main memory - a CPU store, a data cache writeback, every DMA engine -
//  is issued to the port from this module, so a write issued into a buffered
//  line invalidates it. The buffer is tagged with the RAM OFFSET, not the
//  physical address, so the low-memory alias and MEMCFG's banks cannot make two
//  names for one line. A write cannot land while a burst is filling the
//  buffer: the port has one transaction at a time and the burst is it.
//
//  `pf_enable` is status[21] (no OSD entry; scripts/setopt.sh ipf=off), so one
//  bitstream measures the buffer against its absence.
//============================================================================

module ram_arb (
    input  logic        clk,
    input  logic        reset,

    // ---- the CPU ---------------------------------------------------------
    // `cpu_req` is a ONE-CYCLE PULSE, already gated by the caller on the
    // access being main memory and inside a valid bank. The payload must stay
    // valid from that pulse until `cpu_ack`, which r4300_bus.sv guarantees.
    input  logic        cpu_req,
    input  logic        cpu_we,
    input  logic [31:0] cpu_addr,
    input  logic [63:0] cpu_wdata,
    input  logic  [7:0] cpu_be,
    // Words to read, 1..4: a cache line fill. Part of the payload, so held
    // like the address. The port answers one `cpu_ack` per word and marks
    // the final one with `cpu_last`; a write is one word, one ack.
    input  logic  [2:0] cpu_burst,
    // A line write's words 1..3 (build 38): with cpu_we and cpu_burst = 4,
    // part of the payload and held like the rest of it.
    input  logic [191:0] cpu_wdata3,
    // The request is an INSTRUCTION line fill (r4300_bus bus_ifill, build 46),
    // held with the payload.
    input  logic        cpu_ifill,
    input  logic        pf_enable,
    // The request is a DATA line fill (r4300_bus bus_dfill, build 47), and
    // the data buffer's switch.
    input  logic        cpu_dfill,
    input  logic        dpf_enable,
    output logic        cpu_ack,
    output logic        cpu_last,
    // The word that goes with cpu_ack: the port's, or the buffer's.
    output logic [63:0] cpu_rdata,

    // ---- the DMA engines, already muxed into one ------------------------
    // `dma_req` is HELD until `dma_ack`.
    input  logic        dma_req,
    input  logic        dma_we,
    input  logic [31:0] dma_addr,
    input  logic [63:0] dma_wdata,
    input  logic  [7:0] dma_be,
    output logic        dma_ack,
    // Asserted in the cycle a DMA transaction is issued. The caller tags which
    // of its two engines owns it with this; without that tag the MC's fill
    // acknowledgements land on the SCSI channel as completed descriptor
    // cycles. Same class of mistake as the one above, one level down.
    output logic        dma_granted,

    // ---- the shared port on ddr3_mux -------------------------------------
    output logic        ram_req,
    output logic        ram_we,
    output logic [31:0] ram_addr,
    output logic [63:0] ram_wdata,
    output logic  [7:0] ram_be,
    output logic  [3:0] ram_burst,     // 1..4, or 12 for a prefetching fill
    output logic [191:0] ram_wdata3,
    input  logic [63:0] ram_rdata,
    input  logic        ram_ack,
    input  logic        ram_last,

    // ---- observation only (build 37) ------------------------------------
    output logic        dbg_cpu_wait,   // a CPU access is waiting for the port
    output logic        dbg_dma_go,     // a DMA transaction is issued
    // build 46: an instruction fill answered from the buffer / one that
    // fetched the next two lines
    output logic        dbg_pf_hit,
    output logic        dbg_pf_fill,
    // build 47: the same for data line fills
    output logic        dbg_dpf_hit,
    output logic        dbg_dpf_fill
);

    // Whether this port has a transaction outstanding, and whose it is. Both
    // masters are held off by `inflight`; the asymmetry between them was the
    // bug.
    logic inflight;
    logic owner_dma;

    // A CPU access that arrived while the port was busy. The CPU pulses, so
    // there is nothing to stall - the request has to be remembered or it is
    // gone.
    logic cpu_wait;

    // ---- the prefetch buffers: [0] instruction lines, [1] data lines --------
    logic [26:0] pf_tag  [2];   // RAM offset >> 5 of each buffer's first line
    logic [26:0] pf_tag1 [2];   // pf_tag + 1, registered: the compares stay equalities
    logic  [1:0] pf_v    [2];   // each line whole, and not written since
    logic [63:0] pf_mem  [16];  // buffer b, line l, word w at {b, l, w}
    logic        pf_run;        // the CPU's transaction is a 12-word burst
    logic        pf_buf;        // ...filling this buffer
    logic  [3:0] pf_beat;       // its words received so far
    logic        srv;           // answering a fill from a buffer
    logic        srv_buf;
    logic        srv_line;
    logic  [1:0] srv_beat;
    // THE DATA SIDE PREFETCHES ONLY A STREAM (build 47). An instruction miss
    // is followed by the next line half the time; a data miss is too when the
    // code is bzero or bcopy (87 % of the boot's data misses) and almost never
    // when it is a sort over a big table, where eight words fetched for nothing
    // are eight clocks of port that another fill waits behind. So a data fill
    // bursts only when its line is the one after the previous data fill's -
    // the second line of a stream on - which the boot replay says keeps nearly
    // all of the gain (42.5 % of the data fills left, against 40.9 % bursting
    // on every miss).
    logic [26:0] d_next;

    wire        cpu_pend = cpu_req | cpu_wait;
    wire [26:0] req_line = cpu_addr[31:5];
    wire        is_ifill = cpu_ifill && !cpu_we && (cpu_burst == 3'd4);
    wire        is_dfill = cpu_dfill && !cpu_we && (cpu_burst == 3'd4);
    wire        rb       = is_dfill;          // the buffer this fill looks in
    wire        en       = is_ifill ? pf_enable : is_dfill ? dpf_enable : 1'b0;
    wire        hit0     = pf_v[rb][0] && (req_line == pf_tag[rb]);
    wire        hit1     = pf_v[rb][1] && (req_line == pf_tag1[rb]);
    wire        pf_hit   = en && (hit0 || hit1);
    wire        stream   = !is_dfill || (req_line == d_next);

    // THE CPU WINS EVERY TIE, which is why `dma_go` subtracts it. That is not
    // politeness either: the CPU is the one master here that stalls a pipeline
    // while it waits, and the DMA engines are streaming into buffers nobody is
    // watching yet. A fill a buffer answers takes nothing from the port, so a
    // DMA transaction may be issued in the same clock.
    wire cpu_go     = cpu_pend & ~inflight & ~srv;
    wire cpu_go_hit = cpu_go & pf_hit;
    wire cpu_go_ram = cpu_go & ~pf_hit;
    wire pf_new     = cpu_go_ram & en & stream;
    wire dma_go     = dma_req & ~inflight & ~cpu_go_ram;

    // Writes issued to the port, for the snoop.
    wire        wr_issue = (cpu_go_ram & cpu_we) | (dma_go & dma_we);
    wire [26:0] wr_line  = dma_go ? dma_addr[31:5] : cpu_addr[31:5];

    // A word of the CPU's own transaction, and whether it goes to the CPU (the
    // demand line) or into the buffer (a prefetch burst's words 4-11).
    wire port_cpu_word = ram_ack & ~owner_dma;
    wire port_fwd      = port_cpu_word & (~pf_run | (pf_beat < 4'd4));

    always_ff @(posedge clk) begin
        if (reset) begin
            inflight  <= 1'b0;
            owner_dma <= 1'b0;
            cpu_wait  <= 1'b0;
            pf_v[0]    <= 2'b00;
            pf_v[1]    <= 2'b00;
            pf_run     <= 1'b0;
            pf_buf     <= 1'b0;
            pf_beat    <= 4'd0;
            srv        <= 1'b0;
            srv_buf    <= 1'b0;
            srv_beat   <= 2'd0;
            srv_line   <= 1'b0;
            pf_tag[0]  <= 27'd0;
            pf_tag[1]  <= 27'd0;
            pf_tag1[0] <= 27'd1;
            pf_tag1[1] <= 27'd1;
            d_next     <= 27'd0;
        end else begin
            // Remember a pulse that could not be issued; forget it once it is.
            if (cpu_req && !cpu_go) cpu_wait <= 1'b1;
            else if (cpu_go)        cpu_wait <= 1'b0;

            if (cpu_go_ram | dma_go) begin
                inflight  <= 1'b1;
                owner_dma <= dma_go;
            end else if (ram_ack && ram_last) begin
                // A burst is one transaction until its LAST word: the port
                // is still streaming, and a request issued into it now would
                // be dropped exactly as before.
                inflight  <= 1'b0;
            end

            // ---- a fill answered from the buffer: four words, one a clock
            if (cpu_go_hit) begin
                srv      <= 1'b1;
                srv_buf  <= rb;
                srv_beat <= 2'd0;
                srv_line <= !hit0;
            end else if (srv) begin
                srv_beat <= srv_beat + 2'd1;
                if (srv_beat == 2'd3) srv <= 1'b0;
            end

            // ---- a fill that fetches the next two lines behind its own
            if (cpu_go_ram) begin
                pf_run  <= pf_new;
                pf_beat <= 4'd0;
            end
            if (pf_new) begin
                pf_buf      <= rb;
                pf_tag[rb]  <= req_line + 27'd1;
                pf_tag1[rb] <= req_line + 27'd2;
                pf_v[rb]    <= 2'b00;
            end
            // The data stream moves on with every data line fill, answered
            // here or not.
            if (cpu_go && is_dfill) d_next <= req_line + 27'd1;
            if (port_cpu_word && pf_run) begin
                pf_beat <= pf_beat + 4'd1;
                if (pf_beat >= 4'd4) pf_mem[{pf_buf, 3'(pf_beat - 4'd4)}] <= ram_rdata;
                if (pf_beat == 4'd7)  pf_v[pf_buf][0] <= 1'b1;
                if (pf_beat == 4'd11) begin
                    pf_v[pf_buf][1] <= 1'b1;
                    pf_run          <= 1'b0;
                end
            end

            // ---- the snoop: a write into a buffered line forgets it, in both
            if (wr_issue) begin
                for (int b = 0; b < 2; b++) begin
                    if (wr_line == pf_tag[b])  pf_v[b][0] <= 1'b0;
                    if (wr_line == pf_tag1[b]) pf_v[b][1] <= 1'b0;
                end
            end
        end
    end

    assign ram_req   = cpu_go_ram | dma_go;
    assign ram_we    = dma_go ? dma_we    : cpu_we;
    assign ram_addr  = dma_go ? dma_addr  : cpu_addr;
    assign ram_wdata = dma_go ? dma_wdata : cpu_wdata;
    assign ram_be    = dma_go ? dma_be    : cpu_be;
    // The DMA engines move one word per transaction and have no burst input.
    assign ram_burst = dma_go ? 4'd1 : pf_new ? 4'd12 : {1'b0, cpu_burst};
    assign ram_wdata3 = cpu_wdata3;          // read only with the CPU's burst

    assign cpu_ack     = srv | port_fwd;
    assign cpu_last    = srv    ? (srv_beat == 2'd3)
                       : pf_run ? (pf_beat == 4'd3)
                       :          ram_last;
    assign cpu_rdata   = srv ? pf_mem[{srv_buf, srv_line, srv_beat}] : ram_rdata;
    assign dma_ack     = ram_ack &  owner_dma;
    assign dma_granted = dma_go;

    // A CPU access that arrived while a transaction held the port - the DMA
    // engines' (the CPU never overlaps its own) - and the clocks it waited.
    assign dbg_cpu_wait = cpu_pend & inflight;
    assign dbg_dma_go   = dma_go;
    assign dbg_pf_hit   = cpu_go_hit & ~rb;
    assign dbg_pf_fill  = pf_new & ~rb;
    assign dbg_dpf_hit  = cpu_go_hit &  rb;
    assign dbg_dpf_fill = pf_new &  rb;

endmodule
