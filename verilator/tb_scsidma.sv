//============================================================================
//  tb_scsidma -- hpc3_scsi_dma.sv on its own, against a memory that answers
//  late.  `make -C verilator tb_scsidma`.
//
//  The whole-machine tests (run-dma, run-scsiwr) drive this engine through
//  sim_ram.v, which answers a request in a clock or two. On the board a DMA
//  cycle waits for ram_arb's grant and then a DDR3 round trip, tens of clocks,
//  and the engine's request is held that whole time. This bench makes both
//  delays settable so the windows they open can be driven directly:
//
//    T1  a DATA IN transfer that ends normally: bytes land, nothing else moves
//    T2  FLUSH with bytes held: ch_active must not read 0 before they are in
//        memory (Linux's sgiwd93 dma_stop polls exactly that and then trusts
//        the buffer; IRIX's teardown writes FLUSH the same way)
//    T3  a stop with bytes held, then a new descriptor and a go edge while
//        the held bytes' write is still waiting for its acknowledge. The
//        acknowledge must not be taken as the new descriptor's first word -
//        if it is, the new transfer's bytes go wherever that garbage points.
//    T4  the same with the grant late: the request's fields change under a
//        request nobody has taken yet
//    T5  a stop while a descriptor fetch is in flight, then a go edge
//
//  Every write the engine makes is checked against the buffers the test set
//  up; anything outside them is a STRAY WRITE and fails the test.
//============================================================================
`timescale 1ns/1ps
module tb_scsidma;

reg clk = 0;
always #5 clk = ~clk;

reg          reset = 1;
reg          pio_sel = 0, pio_we = 0;
reg  [3:0]   pio_reg = 0;
reg [31:0]   pio_wdata = 0;
wire [31:0]  rd_data0, rd_data1;

wire         dma_req, dma_we;
wire [31:0]  dma_addr;
wire [63:0]  dma_wdata;
wire  [7:0]  dma_be;
reg  [63:0]  dma_rdata = 0;
reg          dma_ack = 0;

reg          dev_req = 0, dev_dir_in = 1, dev_eop = 0;
reg  [7:0]   dev_wdata = 0;
wire         dev_ack, dev_reset, irq;
wire [7:0]   dev_rdata;
wire [63:0]  dbg_dma;

hpc3_scsi_dma dut (
    .clk (clk), .reset (reset),
    .pio_sel (pio_sel), .pio_reg (pio_reg), .pio_we (pio_we), .pio_wdata (pio_wdata),
    .rd_reg0 (4'h9), .rd_data0 (rd_data0), .rd_reg1 (4'h0), .rd_data1 (rd_data1),
    .dma_req (dma_req), .dma_we (dma_we), .dma_addr (dma_addr), .dma_wdata (dma_wdata),
    .dma_be (dma_be), .dma_rdata (dma_rdata), .dma_ack (dma_ack),
    .dev_req (dev_req), .dev_dir_in (dev_dir_in), .dev_wdata (dev_wdata),
    .dev_eop (dev_eop), .dev_ack (dev_ack), .dev_rdata (dev_rdata),
    .dev_reset (dev_reset), .irq (irq), .dbg_dma (dbg_dma)
);

localparam logic [3:0] R_CBP = 4'h0, R_NBDP = 4'h1, R_BC = 4'h8, R_CTRL = 4'h9;
localparam logic [3:0] ST_RUN = 4'd6;   // dstate_t: D_RUN

// ---- memory: 64 KB of doublewords -----------------------------------------
logic [63:0] mem [0:8191];
int          grant_dly = 0;    // clocks a request waits before it is taken
int          ack_dly   = 12;   // clocks from taken to acknowledged
bit          rand_lat  = 0;    // T7: both drawn at random for every request
localparam int T7_RUNS = 400;
logic [63:0] last_rd  = 64'h0;

// Allowed write windows [lo, hi), byte addresses.
logic [31:0] ok_lo [0:3];
logic [31:0] ok_hi [0:3];
int          strays = 0;

function automatic bit write_ok(input logic [31:0] a);
    for (int k = 0; k < 4; k++)
        if (a >= ok_lo[k] && a < ok_hi[k]) return 1;
    return 0;
endfunction

initial begin : memory_model
    logic        t_we;
    logic [31:0] t_addr;
    logic [63:0] t_wdata;
    logic  [7:0] t_be;
    forever begin
        @(posedge clk);
        if (!reset && dma_req) begin
            if (rand_lat) begin
                grant_dly = $urandom_range(0, 20);
                ack_dly   = $urandom_range(3, 40);
            end
            repeat (grant_dly) @(posedge clk);
            // Taken here: the fields as they are NOW are the request.
            t_we = dma_we; t_addr = dma_addr; t_wdata = dma_wdata; t_be = dma_be;
            repeat (ack_dly) @(posedge clk);
            if (t_we) begin
                for (int b = 0; b < 8; b++)
                    if (t_be[7 - b]) begin
                        if (!write_ok({t_addr[31:3], 3'(b)})) begin
                            strays++;
                            $display("    STRAY WRITE byte %08h <= %02h", {t_addr[31:3], 3'(b)}, t_wdata[63 - 8*b -: 8]);
                        end
                        if (t_addr < 32'h10000)
                            mem[t_addr[15:3]][63 - 8*b -: 8] = t_wdata[63 - 8*b -: 8];
                    end
                // A write's acknowledge carries whatever the read path last
                // held - on the board, ddr3_mux's last read word.
                dma_rdata <= last_rd;
            end else begin
                last_rd    = (t_addr < 32'h10000) ? mem[t_addr[15:3]] : 64'h0;
                dma_rdata <= last_rd;
            end
            dma_ack <= 1'b1;
            @(posedge clk);
            dma_ack <= 1'b0;
        end
    end
end

// ---- helpers ---------------------------------------------------------------
int fails = 0, checks = 0;
task automatic check(input bit c, input string what);
    checks++;
    if (c) $display("  ok   %s", what);
    else begin fails++; $display("  FAIL %s", what); end
endtask

task automatic pio_write(input logic [3:0] r, input logic [31:0] d);
    @(posedge clk);
    pio_sel <= 1; pio_we <= 1; pio_reg <= r; pio_wdata <= d;
    @(posedge clk);
    pio_sel <= 0; pio_we <= 0;
endtask

function automatic bit ch_active();
    return rd_data0[4];
endfunction

task automatic put_desc(input logic [31:0] at, input logic [31:0] bp,
                        input logic [31:0] bc, input logic [31:0] dp);
    mem[at[15:3]]     = {bp, bc};
    mem[at[15:3] + 1] = {dp, 32'h0};
endtask

function automatic logic [7:0] pat(input int n, input int seed);
    return 8'(n * 7 + seed * 31 + 1);
endfunction

// Hand the engine one DATA IN byte; wait for its acknowledge.
task automatic dev_byte(input logic [7:0] b);
    int t = 0;
    @(posedge clk);
    dev_req <= 1; dev_dir_in <= 1; dev_wdata <= b;
    do begin @(posedge clk); t++; end while (!dev_ack && t < 400);
    dev_req <= 0;
    if (t >= 400 && !rand_lat) $display("    (dev_ack never came for byte %02h)", b);
endtask

task automatic wait_state(input logic [3:0] st, input int limit);
    int t = 0;
    while (dbg_dma[63:60] != st && t < limit) begin @(posedge clk); t++; end
endtask

task automatic wait_idle(input int limit);
    int t = 0;
    while (ch_active() && t < limit) begin @(posedge clk); t++; end
endtask

function automatic bit buf_has(input logic [31:0] base, input int n, input int seed);
    for (int k = 0; k < n; k++) begin
        logic [31:0] a = base + k;
        if (mem[a[15:3]][63 - 8*a[2:0] -: 8] != pat(k, seed)) return 0;
    end
    return 1;
endfunction

task automatic fresh(input int gd, input int ad);
    for (int k = 0; k < 8192; k++) mem[k] = 64'h0;
    for (int k = 0; k < 4; k++) begin ok_lo[k] = 0; ok_hi[k] = 0; end
    strays = 0; grant_dly = gd; ack_dly = ad; last_rd = 64'h0;
    dev_req = 0; dev_eop = 0;
    reset = 1; repeat (4) @(posedge clk); reset = 0;
    repeat (2) @(posedge clk);
    pio_write(R_CTRL, 32'h0);          // clear ch_reset
    repeat (2) @(posedge clk);
endtask

// ---- the tests -------------------------------------------------------------
initial begin
    $display("tb_scsidma: hpc3_scsi_dma against a slow memory");

    // T1 ---------------------------------------------------------------------
    $display("T1 DATA IN, 21 bytes, ends on the count (ack %0d)", 12);
    fresh(0, 12);
    ok_lo[0] = 32'h2000; ok_hi[0] = 32'h2000 + 21;
    put_desc(32'h1000, 32'h2000, 32'h8000_0000 | 21, 32'h0);
    pio_write(R_NBDP, 32'h1000);
    pio_write(R_CTRL, 32'h10);
    wait_state(ST_RUN, 500);
    for (int k = 0; k < 21; k++) dev_byte(pat(k, 1));
    wait_idle(500);
    check(!ch_active(), "the channel completes");
    check(buf_has(32'h2000, 21, 1), "every byte is in the buffer");
    check(strays == 0, "no write outside the buffer");

    // T2 ---------------------------------------------------------------------
    $display("T2 FLUSH with 5 bytes held (ack 40)");
    fresh(0, 40);
    ok_lo[0] = 32'h2000; ok_hi[0] = 32'h2000 + 64;
    put_desc(32'h1000, 32'h2000, 32'h8000_0000 | 64, 32'h0);
    pio_write(R_NBDP, 32'h1000);
    pio_write(R_CTRL, 32'h10);
    wait_state(ST_RUN, 500);
    for (int k = 0; k < 5; k++) dev_byte(pat(k, 2));
    pio_write(R_CTRL, 32'h18);         // `ctrl |= FLUSH` on a running channel
    begin
        int t = 0;
        while (ch_active() && t < 500) begin @(posedge clk); t++; end
        // The moment a driver polling ch_active would go on to read the buffer.
        check(buf_has(32'h2000, 5, 2), "the held bytes are in memory when ch_active reads 0");
    end
    repeat (100) @(posedge clk);
    check(buf_has(32'h2000, 5, 2), "and they do land eventually");
    check(strays == 0, "no write outside the buffer");

    // T3 ---------------------------------------------------------------------
    $display("T3 stop with 5 bytes held, new chain and go before the write is acknowledged (ack 40)");
    fresh(0, 40);
    ok_lo[0] = 32'h2000; ok_hi[0] = 32'h2000 + 64;
    ok_lo[1] = 32'h3000; ok_hi[1] = 32'h3000 + 16;
    put_desc(32'h1000, 32'h2000, 32'h8000_0000 | 64, 32'h0);
    put_desc(32'h1100, 32'h3000, 32'h8000_0000 | 16, 32'h0);
    pio_write(R_NBDP, 32'h1000);
    pio_write(R_CTRL, 32'h10);
    wait_state(ST_RUN, 500);
    for (int k = 0; k < 5; k++) dev_byte(pat(k, 3));
    pio_write(R_CTRL, 32'h00);         // stop
    pio_write(R_NBDP, 32'h1100);
    pio_write(R_CTRL, 32'h10);         // go, with the flush write outstanding
    wait_state(ST_RUN, 800);
    for (int k = 0; k < 16; k++) dev_byte(pat(k, 4));
    wait_idle(1000);
    repeat (100) @(posedge clk);
    check(!ch_active(), "the second chain completes");
    check(buf_has(32'h2000, 5, 3), "the first chain's held bytes are in its buffer");
    check(buf_has(32'h3000, 16, 4), "the second chain's bytes are in its buffer");
    check(strays == 0, "no write outside the two buffers");

    // T4 ---------------------------------------------------------------------
    $display("T4 as T3 with the grant 30 clocks late (ack 20)");
    fresh(30, 20);
    ok_lo[0] = 32'h2000; ok_hi[0] = 32'h2000 + 64;
    ok_lo[1] = 32'h3000; ok_hi[1] = 32'h3000 + 16;
    put_desc(32'h1000, 32'h2000, 32'h8000_0000 | 64, 32'h0);
    put_desc(32'h1100, 32'h3000, 32'h8000_0000 | 16, 32'h0);
    pio_write(R_NBDP, 32'h1000);
    pio_write(R_CTRL, 32'h10);
    wait_state(ST_RUN, 800);
    for (int k = 0; k < 5; k++) dev_byte(pat(k, 5));
    pio_write(R_CTRL, 32'h00);
    pio_write(R_NBDP, 32'h1100);
    pio_write(R_CTRL, 32'h10);
    wait_state(ST_RUN, 800);
    for (int k = 0; k < 16; k++) dev_byte(pat(k, 6));
    wait_idle(2000);
    repeat (200) @(posedge clk);
    check(!ch_active(), "the second chain completes");
    check(buf_has(32'h2000, 5, 5), "the first chain's held bytes are in its buffer");
    check(buf_has(32'h3000, 16, 6), "the second chain's bytes are in its buffer");
    check(strays == 0, "no write outside the two buffers");

    // T5 ---------------------------------------------------------------------
    $display("T5 stop while the next descriptor is being fetched, then go (ack 40)");
    fresh(0, 40);
    ok_lo[0] = 32'h2000; ok_hi[0] = 32'h2000 + 8;
    ok_lo[1] = 32'h3000; ok_hi[1] = 32'h3000 + 16;
    // Two descriptors: 8 bytes, then a second one the target never reaches.
    put_desc(32'h1000, 32'h2000, 32'h0000_0000 | 8, 32'h1010);
    put_desc(32'h1010, 32'h2800, 32'h8000_0000 | 8, 32'h0);
    put_desc(32'h1100, 32'h3000, 32'h8000_0000 | 16, 32'h0);
    pio_write(R_NBDP, 32'h1000);
    pio_write(R_CTRL, 32'h10);
    wait_state(ST_RUN, 500);
    for (int k = 0; k < 8; k++) dev_byte(pat(k, 7));
    // The eighth byte's flush, then the fetch of descriptor two; stop during it.
    wait_state(4'd2, 500);             // D_FETCH_LO_W
    pio_write(R_CTRL, 32'h00);
    pio_write(R_NBDP, 32'h1100);
    pio_write(R_CTRL, 32'h10);
    wait_state(ST_RUN, 800);
    for (int k = 0; k < 16; k++) dev_byte(pat(k, 8));
    wait_idle(1000);
    repeat (100) @(posedge clk);
    check(!ch_active(), "the new chain completes");
    check(buf_has(32'h2000, 8, 7), "the first descriptor's bytes are in its buffer");
    check(buf_has(32'h3000, 16, 8), "the new chain's bytes are in its buffer");
    check(strays == 0, "no write outside the buffers");

    // T6 ---------------------------------------------------------------------
    // IRIX's wd93dma_flush is `ctrl |= FLUSH; while (ctrl & ACTIVE)`: the
    // write carries back whatever ch_active read. Read during a drain and
    // written back with the bit set, that must not be taken as a go edge.
    $display("T6 read-modify-write of control during a FLUSH drain (ack 40)");
    fresh(0, 40);
    ok_lo[0] = 32'h2000; ok_hi[0] = 32'h2000 + 64;
    put_desc(32'h1000, 32'h2000, 32'h8000_0000 | 64, 32'h0);
    put_desc(32'h1100, 32'h3000, 32'h8000_0000 | 16, 32'h0);
    pio_write(R_NBDP, 32'h1000);
    pio_write(R_CTRL, 32'h10);
    wait_state(ST_RUN, 500);
    for (int k = 0; k < 5; k++) dev_byte(pat(k, 9));
    pio_write(R_NBDP, 32'h1100);       // a stale pointer a spurious start would follow
    pio_write(R_CTRL, 32'h18);
    @(posedge clk);
    pio_write(R_CTRL, rd_data0 | 32'h08);
    wait_idle(500);
    repeat (200) @(posedge clk);
    check(!ch_active(), "the channel is stopped");
    check(dbg_dma[63:60] == 4'd0, "and the engine is idle");
    check(buf_has(32'h2000, 5, 9), "the held bytes are in their buffer");
    check(strays == 0, "nothing was written anywhere else");

    // T7 ---------------------------------------------------------------------
    // Random: chain A takes some bytes, then a stop or a FLUSH lands at a
    // random clock (mid-flush, mid-fetch, idle), then chain B is started at a
    // random clock after it and run to its end. Memory latency random per
    // request. Every acknowledged byte must be where its chain put it, and
    // nothing may be written outside the two chains' buffers.
    $display("T7 %0d random stop/FLUSH/go sequences, random memory latency", T7_RUNS);
    begin
        int bad_runs = 0, stray_runs = 0, hang_runs = 0, early_runs = 0;
        for (int run = 0; run < T7_RUNS; run++) begin
            int cA1, cA2, cB1, cB2, nA, nB, d1, d2;
            logic [31:0] bA1, bA2, bB1, bB2;
            bit use_flush, ok, early;
            fresh(0, 10);
            rand_lat = 1;
            cA1 = $urandom_range(1, 40); cA2 = $urandom_range(1, 40);
            cB1 = $urandom_range(1, 40); cB2 = $urandom_range(0, 40);
            bA1 = 32'h2000 + $urandom_range(0, 7); bA2 = 32'h2800 + $urandom_range(0, 7);
            bB1 = 32'h3000 + $urandom_range(0, 7); bB2 = 32'h3800 + $urandom_range(0, 7);
            ok_lo[0] = bA1; ok_hi[0] = bA1 + cA1;  ok_lo[1] = bA2; ok_hi[1] = bA2 + cA2;
            ok_lo[2] = bB1; ok_hi[2] = bB1 + cB1;  ok_lo[3] = bB2; ok_hi[3] = bB2 + cB2;
            // Receive chains end in a zero-count EOX descriptor (see the
            // engine's header), which is a fetch after the last data byte.
            put_desc(32'h1000, bA1, cA1, 32'h1010);
            put_desc(32'h1010, bA2, cA2, 32'h1020);
            put_desc(32'h1020, 32'h0, 32'h8000_0000, 32'h0);
            if (cB2 != 0) begin
                put_desc(32'h1100, bB1, cB1, 32'h1110);
                put_desc(32'h1110, bB2, cB2, 32'h1120);
                put_desc(32'h1120, 32'h0, 32'h8000_0000, 32'h0);
            end else begin
                put_desc(32'h1100, bB1, cB1, 32'h1120);
                put_desc(32'h1120, 32'h0, 32'h8000_0000, 32'h0);
            end
            nA = $urandom_range(1, cA1 + cA2);
            nB = cB1 + cB2;
            d1 = $urandom_range(0, 60); d2 = $urandom_range(0, 60);
            use_flush = $urandom_range(0, 1);

            pio_write(R_NBDP, 32'h1000);
            pio_write(R_CTRL, 32'h10);
            for (int k = 0; k < nA; k++) dev_byte(pat(k, 100 + run));
            repeat (d1) @(posedge clk);
            if (use_flush) begin
                pio_write(R_CTRL, rd_data0 | 32'h08);
                begin
                    int t = 0;
                    while (ch_active() && t < 2000) begin @(posedge clk); t++; end
                end
            end else begin
                pio_write(R_CTRL, 32'h00);
            end
            // What a driver trusting ACTIVE would see now.
            early = 0;
            if (use_flush)
                for (int k = 0; k < nA; k++) begin
                    logic [31:0] a = (k < cA1) ? bA1 + k : bA2 + (k - cA1);
                    if (mem[a[15:3]][63 - 8*a[2:0] -: 8] != pat(k, 100 + run)) early = 1;
                end
            repeat (d2) @(posedge clk);
            pio_write(R_NBDP, 32'h1100);
            pio_write(R_CTRL, 32'h10);
            for (int k = 0; k < nB; k++) dev_byte(pat(k, 200 + run));
            wait_idle(3000);
            repeat (150) @(posedge clk);

            ok = !ch_active();
            if (!ok) hang_runs++;
            for (int k = 0; k < nA; k++) begin
                logic [31:0] a = (k < cA1) ? bA1 + k : bA2 + (k - cA1);
                if (mem[a[15:3]][63 - 8*a[2:0] -: 8] != pat(k, 100 + run)) ok = 0;
            end
            for (int k = 0; k < nB; k++) begin
                logic [31:0] a = (k < cB1) ? bB1 + k : bB2 + (k - cB1);
                if (mem[a[15:3]][63 - 8*a[2:0] -: 8] != pat(k, 200 + run)) ok = 0;
            end
            if (strays != 0) begin ok = 0; stray_runs++; end
            if (early) early_runs++;
            if (!ok) begin
                bad_runs++;
                if (bad_runs <= 8)
                    $display("    run %0d: A %0d+%0d took %0d, %s after %0d, go after %0d, B %0d+%0d: %s%s",
                             run, cA1, cA2, nA, use_flush ? "FLUSH" : "stop", d1, d2, cB1, cB2,
                             strays != 0 ? "stray write " : "", !ch_active() ? "data wrong" : "hung");
            end
            rand_lat = 0;
        end
        check(bad_runs == 0,   $sformatf("every run moved the right bytes to the right place (%0d bad)", bad_runs));
        check(stray_runs == 0, $sformatf("no run wrote outside its buffers (%0d did)", stray_runs));
        check(hang_runs == 0,  $sformatf("every second chain completed (%0d hung)", hang_runs));
        check(early_runs == 0, $sformatf("ACTIVE never read 0 after FLUSH before the bytes landed (%0d did)", early_runs));
    end

    $display("tb_scsidma: %0d checks, %0d failed", checks, fails);
    if (fails == 0) $display("SCSIDMA: PASS");
    else $display("SCSIDMA: FAIL");
    $finish;
end

initial begin
    #2s;
    $display("SCSIDMA: TIMEOUT");
    $finish;
end

endmodule
