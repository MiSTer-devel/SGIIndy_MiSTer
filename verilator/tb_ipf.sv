//============================================================================
//  tb_ipf -- ram_arb's instruction prefetch buffer against a slow memory with
//  real contents.  `make -C verilator tb_ipf`.
//
//  tb_ramarb checks the arbiter's protocol; this checks what the buffer adds
//  to it: data. The port model is ddr3_mux's contract (one transaction at a
//  time, a burst answered a word a clock after a random latency, a write
//  acknowledged once) over a memory that holds values, and every word the CPU
//  is handed must be what memory held when it asked - or, when a DMA write
//  landed while it waited, what memory held when it finished. A buffered line
//  that missed a write fails that, whichever master wrote it.
//
//    D1  directed: a miss fetches the next two lines; both are then answered
//        with no port transaction; a DMA write into one, and a CPU store into
//        the other, each send the next fill of that line back to the port
//    D2  directed: pf_enable low - no 12-word bursts, no hits
//    R1  random: 60,000 CPU transactions (instruction fills walking lines with
//        jumps, data fills, stores, line writebacks into the same lines) with
//        a DMA master reading and writing underneath, random latency
//    R2  as R1 with the buffer off: the old behaviour, as a control
//============================================================================
`timescale 1ns/1ps
module tb_ipf;

reg clk = 0;
always #5 clk = ~clk;
reg reset = 1;

// ---- DUT ---------------------------------------------------------------------
reg          cpu_req = 0, cpu_we = 0, cpu_ifill = 0, pf_enable = 1;
reg          cpu_dfill = 0, dpf_enable = 1;
reg  [31:0]  cpu_addr = 0;
reg  [63:0]  cpu_wdata = 0;
reg   [7:0]  cpu_be = 8'hFF;
reg   [2:0]  cpu_burst = 1;
reg [191:0]  cpu_wdata3 = 0;
wire         cpu_ack, cpu_last;
wire [63:0]  cpu_rdata;
reg          dma_req = 0, dma_we = 0;
reg  [31:0]  dma_addr = 0;
reg  [63:0]  dma_wdata = 0;
reg   [7:0]  dma_be = 8'hFF;
wire         dma_ack, dma_granted;
wire         ram_req, ram_we;
wire [31:0]  ram_addr;
wire [63:0]  ram_wdata;
wire  [7:0]  ram_be;
wire  [3:0]  ram_burst;
wire [191:0] ram_wdata3;
reg  [63:0]  ram_rdata = 0;
reg          ram_ack = 0, ram_last = 0;
wire         dbg_cpu_wait, dbg_dma_go, dbg_pf_hit, dbg_pf_fill, dbg_dpf_hit, dbg_dpf_fill;

ram_arb dut (
    .clk(clk), .reset(reset),
    .cpu_req(cpu_req), .cpu_we(cpu_we), .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata),
    .cpu_be(cpu_be), .cpu_burst(cpu_burst), .cpu_wdata3(cpu_wdata3),
    .cpu_ifill(cpu_ifill), .pf_enable(pf_enable),
    .cpu_dfill(cpu_dfill), .dpf_enable(dpf_enable),
    .cpu_ack(cpu_ack), .cpu_last(cpu_last), .cpu_rdata(cpu_rdata),
    .dma_req(dma_req), .dma_we(dma_we), .dma_addr(dma_addr), .dma_wdata(dma_wdata),
    .dma_be(dma_be), .dma_ack(dma_ack), .dma_granted(dma_granted),
    .ram_req(ram_req), .ram_we(ram_we), .ram_addr(ram_addr), .ram_wdata(ram_wdata),
    .ram_be(ram_be), .ram_burst(ram_burst), .ram_wdata3(ram_wdata3),
    .ram_rdata(ram_rdata), .ram_ack(ram_ack), .ram_last(ram_last),
    .dbg_cpu_wait(dbg_cpu_wait), .dbg_dma_go(dbg_dma_go),
    .dbg_pf_hit(dbg_pf_hit), .dbg_pf_fill(dbg_pf_fill),
    .dbg_dpf_hit(dbg_dpf_hit), .dbg_dpf_fill(dbg_dpf_fill)
);

// ---- memory: 64 KB of doublewords, and the port in front of it ----------------
localparam int WORDS = 8192;
logic [63:0] mem [0:WORDS-1];
int  lat_lo = 3, lat_hi = 30;
int  err_overlap = 0, port_txn = 0, port_reads12 = 0;
bit  port_busy = 0;

function automatic logic [63:0] merge(input logic [63:0] old, input logic [63:0] d,
                                      input logic [7:0] be);
    logic [63:0] r = old;
    for (int b = 0; b < 8; b++) if (be[7 - b]) r[63 - 8*b -: 8] = d[63 - 8*b -: 8];
    return r;
endfunction

// A clocked process, not an `initial` waiting on the edge: the arbiter's
// request is a one-clock pulse, and a coroutine resumed after the edge's
// register updates never sees it (this bench's first version hung on exactly
// that - tb_scsidma's held requests hide it).
int          p_state = 0, p_cnt = 0, p_n = 0, p_i = 0;
logic        p_we;
logic [31:0] p_addr;
always @(posedge clk) begin
    ram_ack  <= 1'b0;
    ram_last <= 1'b0;
    if (reset) begin
        p_state = 0;
        port_busy = 0;
    end else begin
        if (ram_req) begin
            if (p_state != 0) err_overlap++;
            port_txn++;
            if (!ram_we && ram_burst == 4'd12) port_reads12++;
            p_we = ram_we; p_addr = ram_addr;
            p_n  = ram_we ? 1 : ((ram_burst == 4'd0) ? 1 : int'(ram_burst));
            // A write lands in memory as it is issued; nothing can come
            // between it and the next transaction on a one-deep port.
            if (ram_we) begin
                mem[ram_addr[15:3]] = merge(mem[ram_addr[15:3]], ram_wdata, ram_be);
                if (ram_burst == 4'd4) begin
                    mem[ram_addr[15:3] + 1] = ram_wdata3[63:0];
                    mem[ram_addr[15:3] + 2] = ram_wdata3[127:64];
                    mem[ram_addr[15:3] + 3] = ram_wdata3[191:128];
                end
            end
            p_cnt = $urandom_range(lat_lo, lat_hi);
            p_i = 0; p_state = 1; port_busy = 1;
        end else if (p_state == 1) begin
            if (p_cnt > 0) p_cnt--;
            else p_state = 2;
        end
        if (p_state == 2) begin
            ram_rdata <= p_we ? 64'hDEAD_BEEF_DEAD_BEEF : mem[p_addr[15:3] + p_i];
            ram_ack   <= 1'b1;
            ram_last  <= (p_i == p_n - 1);
            p_i++;
            if (p_i == p_n) begin p_state = 0; port_busy = 0; end
        end
    end
end

// ---- checks on the CPU side -----------------------------------------------------
int err_data = 0, err_unasked = 0, err_count = 0, err_hang = 0, cpu_txn = 0;
int hits = 0, fills12 = 0, dhits = 0, dfills12 = 0;
bit cpu_waiting = 0, cpu_waiting_q = 0;
// This process samples a clock behind the CPU task (it reads the values from
// before the edge, the task those after it), so the task's last ack is seen
// here after the task has stopped waiting: allow the clock after as well.
always @(posedge clk) begin
    if (!reset && dbg_pf_hit)  hits++;
    if (!reset && dbg_pf_fill) fills12++;
    if (!reset && dbg_dpf_hit)  dhits++;
    if (!reset && dbg_dpf_fill) dfills12++;
    if (!reset && cpu_ack && !cpu_waiting && !cpu_waiting_q) err_unasked++;
    cpu_waiting_q <= cpu_waiting;
end

// One CPU transaction: pulse, hold, collect. Reads are checked word by word.
task automatic cpu_txn_do(input bit we, input logic [31:0] addr, input int burst,
                          input bit ifill, input logic [63:0] wd, input logic [7:0] be,
                          input logic [191:0] wd3, input bit dfill = 0);
    logic [63:0] exp_old [4];
    logic [63:0] got [4];
    int nb = 0, t = 0;
    bit lastseen = 0;
    for (int i = 0; i < 4; i++) exp_old[i] = mem[addr[15:3] + i];
    @(posedge clk);
    cpu_req <= 1; cpu_we <= we; cpu_addr <= addr; cpu_burst <= 3'(burst);
    cpu_ifill <= ifill; cpu_dfill <= dfill; cpu_wdata <= wd; cpu_be <= be; cpu_wdata3 <= wd3;
    cpu_waiting = 1;
    @(posedge clk);
    cpu_req <= 0;
    while (!lastseen && t < 400) begin
        if (cpu_ack) begin
            if (nb < 4) got[nb] = cpu_rdata;
            nb++;
            if (cpu_last) lastseen = 1;
        end
        if (!lastseen) begin @(posedge clk); t++; end
    end
    cpu_waiting = 0;
    cpu_txn++;
    if (t >= 400) begin err_hang++; return; end
    if (nb != (we ? 1 : burst)) err_count++;
    if (!we)
        for (int i = 0; i < burst && i < 4; i++)
            if (got[i] !== exp_old[i] && got[i] !== mem[addr[15:3] + i]) begin
                err_data++;
                if (err_data <= 6)
                    $display("    DATA addr %05h word %0d: got %016h, memory had %016h / has %016h (%s)",
                             addr, i, got[i], exp_old[i], mem[addr[15:3] + i],
                             ifill ? "ifill" : dfill ? "dfill" : "read");
            end
endtask

task automatic ifill(input logic [31:0] line_addr);
    cpu_txn_do(0, {line_addr[31:5], 5'b0}, 4, 1, 64'h0, 8'hFF, 192'h0);
endtask

task automatic dfill(input logic [31:0] line_addr);
    cpu_txn_do(0, {line_addr[31:5], 5'b0}, 4, 0, 64'h0, 8'hFF, 192'h0, 1);
endtask

// ---- the DMA master: holds until acknowledged -----------------------------------
bit dma_run = 0;
int dma_txn = 0;
initial begin : dma_master
    forever begin
        @(posedge clk);
        if (dma_run && $urandom_range(0, 7) == 0) begin
            dma_we    <= $urandom_range(0, 1);
            dma_addr  <= {16'h0, 13'($urandom_range(0, 1023)) + 13'h0400, 3'b000};
            dma_wdata <= {$urandom, $urandom};
            dma_be    <= 8'hFF;
            dma_req   <= 1;
            do @(posedge clk); while (!dma_ack);
            dma_req <= 0;
            dma_txn++;
        end
    end
end

int fails = 0, checks = 0;
task automatic check(input bit c, input string what);
    checks++;
    if (c) $display("  ok   %s", what);
    else begin fails++; $display("  FAIL %s", what); end
endtask

task automatic fresh(input bit en, input bit den = 1);
    for (int i = 0; i < WORDS; i++) mem[i] = {32'(i), $urandom};
    pf_enable = en;
    dpf_enable = den;
    reset = 1; repeat (4) @(posedge clk); reset = 0; repeat (2) @(posedge clk);
    err_data = 0; err_unasked = 0; err_count = 0; err_hang = 0; err_overlap = 0;
    hits = 0; fills12 = 0; dhits = 0; dfills12 = 0; port_txn = 0; port_reads12 = 0; cpu_txn = 0; dma_txn = 0;
endtask

task automatic random_run(input int ntx);
    logic [31:0] line = 32'h2000;
    logic [31:0] dline = 32'h3000;
    dma_run = 1;
    for (int k = 0; k < ntx; k++) begin
        int r = $urandom_range(0, 99);
        if (r < 60) begin
            // instruction fills walk forward, sometimes jump
            if ($urandom_range(0, 9) < 7) line = line + 32'd32;
            else line = {16'h0, 11'($urandom_range(0, 255)) + 11'h100, 5'b0};
            line[15:13] = 3'b001;               // keep to 0x2000-0x3FFF
            ifill(line);
        end else if (r < 70) begin
            // data fills: mostly a stream (bzero, bcopy), sometimes a jump
            if ($urandom_range(0, 9) < 7) dline = dline + 32'd32;
            else dline = {16'h0, 11'($urandom_range(0, 255)) + 11'h100, 5'b0};
            dline[15:13] = 3'b001;
            dfill(dline);
        end else if (r < 85) begin
            // a store into the code lines, any bytes
            cpu_txn_do(1, {16'h0, 3'b001, 10'($urandom), 3'b000}, 1, 0,
                       {$urandom, $urandom}, 8'($urandom_range(1, 255)), 0);
        end else if (r < 92) begin
            cpu_txn_do(1, {16'h0, 3'b001, 8'($urandom), 5'b0}, 4, 0,
                       {$urandom, $urandom}, 8'hFF, {$urandom, $urandom, $urandom, $urandom, $urandom, $urandom});
        end else begin
            cpu_txn_do(0, {16'h0, 3'b001, 10'($urandom), 3'b000}, 1, 0, 0, 8'hFF, 0);
        end
    end
    dma_run = 0;
    repeat (100) @(posedge clk);
endtask

// DMA writes land in 0x2000-0x3FFF too (the master's window), so the random
// runs have both masters writing into the lines the buffer holds.

initial begin
    int t0, t1;
    $display("tb_ipf: ram_arb's instruction prefetch buffer");

    // D1 --------------------------------------------------------------------------
    $display("D1 directed: miss, two hits, invalidation by DMA and by a CPU store");
    fresh(1);
    lat_lo = 12; lat_hi = 12;
    t0 = port_txn;
    ifill(32'h2400);
    check(port_reads12 == 1, "a miss goes to the port as one 12-word read");
    t1 = port_txn;
    ifill(32'h2420);
    ifill(32'h2440);
    check(port_txn == t1, "the next two lines are answered with no port transaction");
    check(hits == 2, "and both count as buffer hits");
    // a DMA write into line 0x2420
    @(posedge clk);
    dma_we <= 1; dma_addr <= 32'h2428; dma_wdata <= 64'h1111_2222_3333_4444; dma_be <= 8'hFF; dma_req <= 1;
    do @(posedge clk); while (!dma_ack);
    dma_req <= 0;
    t1 = port_txn;
    ifill(32'h2420);
    check(port_txn == t1 + 1, "after a DMA write into a buffered line its fill goes to the port");
    // fetch 0x2440/0x2460 into the buffer again and store into 0x2460
    ifill(32'h2600); ifill(32'h2620); ifill(32'h2640);
    cpu_txn_do(1, 32'h2658, 1, 0, 64'hAAAA_BBBB_CCCC_DDDD, 8'h0F, 0);
    t1 = port_txn;
    ifill(32'h2640);
    check(port_txn == t1 + 1, "after a CPU store into a buffered line its fill goes to the port");
    check(err_data == 0 && err_unasked == 0 && err_count == 0 && err_hang == 0 && err_overlap == 0,
          "every word right, nothing unasked, no overlap");

    // D3 --------------------------------------------------------------------------
    $display("D3 directed: a data stream bursts from its second line; a lone miss does not");
    fresh(1, 1);
    lat_lo = 12; lat_hi = 12;
    dfill(32'h3000);
    check(port_reads12 == 0, "the first data fill of a stream is a plain 4-word read");
    dfill(32'h3020);
    check(port_reads12 == 1, "the second line of the stream fetches two more");
    t1 = port_txn;
    dfill(32'h3040); dfill(32'h3060);
    check(port_txn == t1 && dhits == 2, "which are answered with no port transaction");
    dfill(32'h3080);
    check(port_reads12 == 2, "and the stream bursts again at the line after them");
    t1 = port_reads12;
    dfill(32'h3800);
    check(port_reads12 == t1, "a data fill off the stream does not burst");
    // the instruction buffer is untouched by all that
    ifill(32'h2400); ifill(32'h2420);
    check(hits == 1, "the instruction buffer keeps its own lines");
    check(err_data == 0 && err_unasked == 0 && err_count == 0 && err_hang == 0 && err_overlap == 0,
          "every word right, nothing unasked, no overlap");

    // D2 --------------------------------------------------------------------------
    $display("D2 directed: both buffers off");
    fresh(0, 0);
    ifill(32'h2400); ifill(32'h2420); ifill(32'h2440);
    dfill(32'h3000); dfill(32'h3020); dfill(32'h3040);
    check(port_reads12 == 0 && hits == 0 && dhits == 0 && port_txn == 6, "six fills, six 4-word reads, no hits");

    // R1 --------------------------------------------------------------------------
    $display("R1 random, buffer on: 60,000 CPU transactions, DMA underneath, latency 3-30");
    fresh(1);
    lat_lo = 3; lat_hi = 30;
    random_run(60000);
    $display("    %0d CPU transactions, %0d DMA, %0d port transactions; instruction %0d hits %0d bursts; data %0d hits %0d bursts",
             cpu_txn, dma_txn, port_txn, hits, fills12, dhits, dfills12);
    check(err_data == 0,    $sformatf("every word the CPU got was memory's (%0d wrong)", err_data));
    check(err_overlap == 0, $sformatf("the port never saw two transactions (%0d)", err_overlap));
    check(err_unasked == 0, $sformatf("no unasked acknowledge (%0d)", err_unasked));
    check(err_count == 0,   $sformatf("every transaction answered its length (%0d not)", err_count));
    check(err_hang == 0,    $sformatf("no transaction hung (%0d)", err_hang));
    check(hits > 5000,      "the instruction buffer answered fills");
    check(dhits > 500,      "the data buffer answered fills");

    // R2 --------------------------------------------------------------------------
    $display("R2 random, both buffers off: the control");
    fresh(0, 0);
    random_run(20000);
    check(err_data == 0 && err_overlap == 0 && err_unasked == 0 && err_count == 0 && err_hang == 0,
          "everything right with the buffer off");
    check(hits == 0 && dhits == 0 && port_reads12 == 0, "and they stay off");

    $display("tb_ipf: %0d checks, %0d failed", checks, fails);
    if (fails == 0) $display("IPF: PASS");
    else $display("IPF: FAIL");
    $finish;
end

initial begin
    #500ms;
    $display("IPF: TIMEOUT");
    $finish;
end

endmodule
