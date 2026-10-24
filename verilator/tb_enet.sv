//============================================================================
//  tb_enet -- the Ethernet window (sgi_hpc3.sv) between IRIX's if_ec2 on the
//  bus and Main's sgi_enet through the UIO decoder (sgi_enet_uio.sv).
//  `make -C verilator tb_enet`; docs/design/ethernet-plan.md section 3 is
//  the contract these checks come from.
//
//  The guest side is driven as tb_hpc3 drives the bus: one 32-bit word at a
//  time, `sw`/`lw` at the register's own offset. Main's side goes through
//  the real decoder on EXT_BUS, a strobe at a time, each reply read two
//  clocks after its strobe as sys_top's io_ack lets Main read it, with GAP
//  clocks between strobes (Main is far slower than that on the board).
//
//    E1  the 80C03 reads: reg 0 is 0 (it is how if_ec2 knows the chip), reg
//        5 NO_SQE with the carrier Main sets, and the window's presence word
//    E2  RX start: ACTIVE reads 1 at once, CRBDP <- NBDP
//    E3  TX start: ACTIVE at once, PPFXBDP <- CPFXBDP, CPFXBDP <- NBDP; a
//        CTRL write with AMASK set leaves ACTIVE alone; a second start
//        shifts again
//    E4  Main's writes carry the write count: dropped after a guest write,
//        applied when it matches; Main stops TX
//    E5  the interrupt: a NEW status the command enables, then CLRINT; XIE
//    E6  reading a status register marks it OLD
//    E7  RESET: rising stops both channels, falling clears the commands and
//        marks both statuses OLD
//    E8  the station address lands in the store by bank, and Main reads it
//        in one six-word read
//============================================================================
`timescale 1ns/1ps
module tb_enet;

localparam int ACK_LIMIT = 64;
localparam int GAP       = 12;

reg clk = 0;
always #5 clk = ~clk;

reg          reset = 1;
reg          sel = 0, we = 0;
reg [18:0]   addr = 0;
reg  [2:0]   aoff = 0;
reg  [7:0]   be = 8'hFF;
reg [63:0]   wdata = 0;
wire [63:0]  rdata;
wire         ack, claimed, enet_irq;

wire         ex_rd, ex_wr, ex_done, ex_inval;
wire  [8:0]  ex_idx;
wire [15:0]  ex_seq;
wire [31:0]  ex_wdata, ex_rdata;

wire [35:0]  EXT_BUS;
reg  [15:0]  io_din = 0;
reg          io_strobe = 0, io_uio = 0;
assign EXT_BUS[31:16] = io_din;
assign EXT_BUS[33]    = io_strobe;
assign EXT_BUS[34]    = io_uio;
assign EXT_BUS[35]    = 1'b0;

sgi_hpc3 dut (
    .clk (clk), .reset (reset),
    .sel (sel), .we (we), .addr (addr), .aoff (aoff), .be (be),
    .wdata (wdata), .rdata (rdata), .ack (ack), .claimed (claimed),
    .dma_req (), .dma_we (), .dma_addr (), .dma_wdata (), .dma_be (),
    .dma_rdata (64'h0), .dma_ack (1'b0),
    .scsi_dev_req (1'b0), .scsi_dev_dir_in (1'b0), .scsi_dev_wdata (8'h0),
    .scsi_dev_eop (1'b0), .scsi_dev_ack (), .scsi_dev_rdata (), .scsi_dev_reset (),
    .scsi_dma_irq (), .dbg_scsi0_dma (),
    .audio_en (1'b0), .audio_l (), .audio_r (), .dbg_audio (),
    .ex_rd (ex_rd), .ex_wr (ex_wr), .ex_idx (ex_idx), .ex_seq (ex_seq),
    .ex_wdata (ex_wdata), .ex_rdata (ex_rdata), .ex_done (ex_done),
    .enet_irq (enet_irq)
);

sgi_enet_uio uio (
    .clk (clk), .EXT_BUS (EXT_BUS),
    .ex_rd (ex_rd), .ex_wr (ex_wr), .ex_idx (ex_idx), .ex_seq (ex_seq),
    .ex_wdata (ex_wdata), .ex_rdata (ex_rdata), .ex_done (ex_done),
    .ex_inval (ex_inval)
);

int checks = 0, fails = 0;
task automatic check(input string what, input bit ok);
    checks++;
    if (!ok) begin fails++; $display("  FAILED  %s", what); end
endtask

// ---- the guest: one 32-bit word at its own offset -------------------------
logic [63:0] last_rdata;
task automatic access(input bit we_i, input logic [18:0] off, input logic [31:0] v);
    int waited;
    bit got;
    @(negedge clk);
    sel = 1'b1; we = we_i; addr = {off[18:3], 3'b000}; aoff = off[2:0];
    be = off[2] ? 8'h0F : 8'hF0;
    wdata = off[2] ? {32'h0, v} : {v, 32'h0};
    @(negedge clk);
    sel = 1'b0;
    got = 1'b0;
    waited = 0;
    while (!got && waited < ACK_LIMIT) begin
        @(posedge clk);
        if (ack) begin got = 1'b1; last_rdata = rdata; end
        waited++;
    end
    if (!got) begin fails++; $display("  FAILED  no ack at %05x", off); end
    @(negedge clk);
    we = 1'b0;
endtask
task automatic gw(input logic [18:0] off, input logic [31:0] v);
    access(1'b1, off, v);
endtask
function automatic logic [31:0] half(input logic [18:0] off);
    return off[2] ? last_rdata[31:0] : last_rdata[63:32];
endfunction
task automatic gr(input logic [18:0] off, output logic [31:0] v);
    access(1'b0, off, 32'h0);
    v = half(off);
endtask

// ---- Main: a strobe at a time ---------------------------------------------
task automatic spi_w(input logic [15:0] w, output logic [15:0] r);
    @(negedge clk);
    io_din = w; io_strobe = 1'b1;
    @(negedge clk);
    io_strobe = 1'b0;
    @(negedge clk);
    r = EXT_BUS[15:0];
    repeat (GAP) @(negedge clk);
endtask
task automatic m_begin();
    @(negedge clk); io_uio = 1'b1;
endtask
task automatic m_end();
    @(negedge clk); io_uio = 1'b0;
    repeat (4) @(negedge clk);
endtask
task automatic m_read(input logic [8:0] idx, input int n, output logic [31:0] v [8]);
    logic [15:0] r, lo;
    m_begin();
    spi_w(16'h0070, r); spi_w(16'd1, r); spi_w({7'd0, idx}, r); spi_w(16'(n), r);
    for (int i = 0; i < n; i++) begin
        spi_w(16'h0, lo);
        spi_w(16'h0, r);
        v[i] = {r, lo};
    end
    m_end();
endtask
task automatic m_rd1(input logic [8:0] idx, output logic [31:0] v);
    logic [31:0] a [8];
    m_read(idx, 1, a);
    v = a[0];
endtask
task automatic m_write(input logic [8:0] idx, input logic [15:0] seq, input logic [31:0] v);
    logic [15:0] r;
    m_begin();
    spi_w(16'h0070, r); spi_w(16'd2, r); spi_w({7'd0, idx}, r); spi_w(seq, r);
    spi_w(v[15:0], r); spi_w(v[31:16], r);
    m_end();
endtask

// the window's own offsets
localparam logic [18:0] RX_CBP = 19'h14000, RX_NBDP = 19'h14004, TX_NBDP = 19'h16004;
localparam logic [18:0] RX_CTRL = 19'h15004, RX_RESET = 19'h15014, TX_CTRL = 19'h17004;
localparam logic [18:0] CRBDP = 19'h18000, CPFX = 19'h1A000, PPFX = 19'h1A004;
function automatic logic [18:0] seeq(input int r);
    return 19'h54000 + 19'(4 * r);
endfunction

logic [31:0] v, st;
logic [31:0] six [8];
logic [15:0] seq;
logic        inval_seen = 0;
always @(posedge clk) if (ex_inval) inval_seen <= 1'b1;

initial begin
    repeat (4) @(negedge clk);
    reset = 0;
    repeat (300) @(negedge clk);       // the store's reset sweep

    $display("E1 the 80C03's reads and the window");
    gr(seeq(0), v); check("reg 0 reads 0 (an 80C03)", v[7:0] == 8'h00);
    gr(seeq(5), v); check("reg 5: NO_SQE and no carrier before Main says", v[7:0] == 8'h03);
    m_write(9'h104, 16'd0, 32'h0);     // MISC: carrier
    gr(seeq(5), v); check("reg 5: NO_SQE, carrier once Main says", v[7:0] == 8'h01);
    m_rd1(9'h100, st);
    check("STATE says the window exists", st[31:24] == 8'hEC);
    check("STATE: both channels idle", st[17:16] == 2'b00);
    gr(RX_CTRL, v); check("RX CTRL: ACTIVE clear", v[9] == 1'b0);

    $display("E2 RX start");
    gw(RX_NBDP, 32'h0812_3400);
    gw(RX_CTRL, 32'h0000_0200);
    gr(RX_CTRL, v); check("RX ACTIVE reads 1 straight after the start", v[9] == 1'b1);
    gr(CRBDP, v);   check("CRBDP <- NBDP", v == 32'h0812_3400);
    m_rd1(9'h100, st); check("STATE: RX active", st[16] == 1'b1);

    $display("E3 TX start and the first-descriptor pair");
    gw(CPFX, 32'h0800_1000);
    gw(TX_NBDP, 32'h0800_2000);
    gw(TX_CTRL, 32'h0000_0200);
    gr(TX_CTRL, v); check("TX ACTIVE reads 1 straight after the start", v[9] == 1'b1);
    gr(CPFX, v);    check("CPFXBDP <- NBDP", v == 32'h0800_2000);
    gr(PPFX, v);    check("PPFXBDP <- the old CPFXBDP", v == 32'h0800_1000);
    gw(TX_CTRL, 32'h0000_0400);       // AMASK set, ACTIVE clear: no change
    gr(TX_CTRL, v); check("a CTRL write with AMASK set leaves ACTIVE", v[9] == 1'b1);

    $display("E4 Main's writes and the write count");
    m_rd1(9'h100, st); seq = st[15:0];
    gw(19'h16000, 32'h1);             // TX CBP: a guest write to the window
    m_write(9'h103, seq, 32'h2);      // stop TX, on the old count
    gr(TX_CTRL, v); check("a stop made before a guest write is dropped", v[9] == 1'b1);
    m_rd1(9'h100, st); seq = st[15:0];
    m_write(9'h103, seq, 32'h2);
    gr(TX_CTRL, v); check("a stop on the current count lands", v[9] == 1'b0);
    m_write(9'h17, seq, 32'h0800_3000);   // TX NBDP, as at the end of a chain
    gr(TX_NBDP, v); check("Main's store write lands", v == 32'h0800_3000);
    m_write(9'h17, seq - 16'd1, 32'hDEAD_BEEF);
    gr(TX_NBDP, v); check("Main's store write on a stale count is dropped", v == 32'h0800_3000);
    gw(TX_NBDP, 32'h0800_4000);
    gw(TX_CTRL, 32'h0000_0200);       // a second start
    gr(CPFX, v); check("second start: CPFXBDP <- NBDP", v == 32'h0800_4000);
    gr(PPFX, v); check("second start: PPFXBDP <- the previous CPFXBDP", v == 32'h0800_2000);

    $display("E5 the interrupt");
    gw(seeq(6), 32'h3F);              // RX command: every status interrupts
    check("no interrupt with every status OLD", enet_irq == 1'b0);
    m_write(9'h101, 16'd0, 32'h30);   // RX status GOOD|END, NEW
    check("a NEW status the command enables interrupts", enet_irq == 1'b1);
    gr(RX_RESET, v); check("RESET bit 1 reads the interrupt", v[1] == 1'b1);
    gr(RX_CTRL, v);  check("RX CTRL's low byte is the SEEQ's status", v[7:0] == 8'h30);
    gw(RX_RESET, 32'h2);              // CLRINT
    check("CLRINT drops it", enet_irq == 1'b0);
    gr(RX_CTRL, v);  check("...and marks the status OLD", v[7:0] == 8'hB0);
    m_write(9'h104, 16'd0, 32'h1);    // XIE, carrier kept
    check("XIE interrupts", enet_irq == 1'b1);
    gw(RX_RESET, 32'h2);
    check("CLRINT drops XIE", enet_irq == 1'b0);
    gr(seeq(5), v); check("the carrier survived the MISC writes", v[7:0] == 8'h01);
    gw(seeq(7), 32'h4F);              // TX command 0x4f, as if_ec2 leaves it
    m_write(9'h102, 16'd0, 32'h08);   // TX success
    check("TX success interrupts under command 0x4f", enet_irq == 1'b1);

    $display("E6 a status read marks it OLD");
    gr(seeq(7), v); check("reg 7 reads the TX status", v[7:0] == 8'h08);
    check("...and the read retired the interrupt", enet_irq == 1'b0);
    gr(seeq(7), v); check("...as OLD now", v[7:0] == 8'h88);

    $display("E7 RESET");
    gw(TX_CTRL, 32'h0000_0200);
    gw(RX_RESET, 32'h1);
    gr(RX_CTRL, v); check("rising RESET stops RX", v[9] == 1'b0);
    gr(TX_CTRL, v); check("rising RESET stops TX", v[9] == 1'b0);
    m_rd1(9'h100, st); check("STATE: in reset", st[20] == 1'b1);
    gw(RX_RESET, 32'h0);
    m_rd1(9'h105, st);
    check("falling RESET: commands clear", st[31:16] == 16'h0000);
    check("falling RESET: both statuses OLD", st[15:0] == 16'h8080);
    gw(RX_RESET, 32'h4);
    m_rd1(9'h100, st); check("loopback is RESET bit 2", st[19] == 1'b1);
    gw(RX_RESET, 32'h0);

    $display("E8 the station address, by bank");
    gw(seeq(7), 32'h00);              // bank 0
    for (int i = 0; i < 6; i++) gw(seeq(i), 32'h08 + i);
    gw(seeq(7), 32'h20);              // bank 1: the multicast filter
    gw(seeq(0), 32'hAA);
    m_read(9'h040, 6, six);
    check("Main reads the station address in one go",
          six[0][7:0] == 8'h08 && six[1][7:0] == 8'h09 && six[2][7:0] == 8'h0A &&
          six[3][7:0] == 8'h0B && six[4][7:0] == 8'h0C && six[5][7:0] == 8'h0D);
    m_rd1(9'h048, v); check("bank 1 lands beside it", v[7:0] == 8'hAA);

    $display("E9 INVAL");
    m_begin(); begin logic [15:0] r; spi_w(16'h0070, r); spi_w(16'd3, r); end m_end();
    check("the decoder pulses ex_inval", inval_seen);

    $display("\n== tb_enet: %0d checks, %0d failed ==", checks, fails);
    $display("ENET: %s", fails ? "FAIL" : "PASS");
    $finish;
end

initial begin
    #2000000;
    $display("== tb_enet: TIMEOUT ==");
    $finish;
end

endmodule
