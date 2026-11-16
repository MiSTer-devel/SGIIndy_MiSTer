//============================================================================
//  tb_cdtoc -- rtl/scsi/scsi.v as a CD-ROM target, answering READ TOC (0x43).
//  `make -C verilator tb_cdtoc`.
//
//  IRIX 6.2's CD software reads the TOC to decide what kind of disc is in the
//  drive; track 1's CONTROL nibble 0x4 is "data". The stub cd_audio.sv used to
//  serve an all-zero TOC (CONTROL 0 = audio), and 6.2 called every ISO an
//  audio CD. The image here is 1,200,004 512-byte blocks = 300,001 sectors:
//  lead-out LBA 0x000493E1, MSF 66:42:01 (300,151 frames).
//
//    F0L  format 0, LBA, start 0     -> header 00 12 01 01, track 1 data at 0,
//                                       lead-out AA at 300001
//    F0M  format 0, MSF, start 0     -> track 1 at 00:02:00, lead-out 66:42:01
//    FAA  format 0, MSF, start 0xAA  -> header 00 0A, lead-out row only
//    F1   format 1 (session info)    -> 00 0A 01 01 00 14 01 00 00 00 00 00
//    F2   format 2 (full TOC)        -> A0/A1/A2/track 1, lead-out 66:42:01
//
//  Every byte also checks dout_pair / dout_pair_next (the look-ahead the
//  WD33C93B's pair path reads) against the bytes actually served after it.
//============================================================================
`timescale 1ns/1ps
module tb_cdtoc;

reg clk = 0;
always #10 clk = ~clk;

reg        rst = 1'b1;
reg        sel = 1'b0;
reg        atn = 1'b0;
reg        ack = 1'b0;
reg  [7:0] din = 8'h00;
reg        img_mounted = 1'b0;

wire       bsy, msg, cd, io, req, req_bus;
wire [7:0] dout;
wire [15:0] dpair, dpair_next;

scsi #(.ID(3'd4), .CDROM(1)) dut (
    .clk(clk), .rst(rst), .sys_rst(rst),
    .sel(sel), .bus_busy(1'b0), .atn(atn), .cd_enable(1'b1),
    .bsy(bsy), .msg(msg), .cd(cd), .io(io), .req(req), .req_bus(req_bus),
    .ack(ack), .host_csr_rd(1'b0), .host_data_rd(1'b0),
    .din(din), .dout(dout), .dout_pair(dpair), .dout_pair_next(dpair_next),
    .img_mounted(img_mounted), .img_blocks(32'd1200004), .io_ack(1'b0),
    .sd_buff_addr(8'd0), .sd_buff_addr_hi(5'd0), .sd_buff_dout(16'd0), .sd_buff_wr(1'b0),
    .dbg_dma_word(1'b0), .dbg_dma_long(1'b0), .dbg_dma_lowbyte(8'd0),
    .tb_mounted(1'b0), .tb_ack(1'b0)
);

integer fails = 0;

task automatic clocks(input integer n);
    repeat (n) @(posedge clk);
endtask

task automatic wait_req(output bit got, output bit freed);
    integer t;
    got = 0; freed = 0;
    for (t = 0; t < 20000; t++) begin
        @(posedge clk);
        if (!bsy) begin freed = 1; return; end
        if (req) begin got = 1; return; end
    end
endtask

task automatic handshake();
    integer t;
    clocks(2);
    ack = 1'b1;
    for (t = 0; t < 1000 && req; t++) @(posedge clk);
    clocks(2);
    ack = 1'b0;
    clocks(3);
endtask

reg  [7:0] data  [128];
reg [15:0] pair  [128];
reg [15:0] pairn [128];
integer    nd;
reg  [7:0] status;

// One 10-byte command, IDENTIFY LUN 0, collect the DATA IN bytes.
task automatic cmd10(input [7:0] c0, c1, c2, c3, c4, c5, c6, c7, c8, c9);
    reg [7:0] cdb [10];
    reg [7:0] message;
    integer nc, guard;
    bit got, freed;
    cdb[0] = c0; cdb[1] = c1; cdb[2] = c2; cdb[3] = c3; cdb[4] = c4;
    cdb[5] = c5; cdb[6] = c6; cdb[7] = c7; cdb[8] = c8; cdb[9] = c9;
    nd = 0; nc = 0; status = 8'hFF; message = 8'hFF;

    din = 8'h10;
    atn = 1'b1;
    sel = 1'b1;
    for (guard = 0; guard < 1000 && !bsy; guard++) @(posedge clk);
    sel = 1'b0;

    for (guard = 0; guard < 400; guard++) begin
        wait_req(got, freed);
        if (freed || !got) break;
        case ({msg, cd, io})
            3'b110: begin din = 8'h80; atn = 1'b0; handshake(); end
            3'b010: begin din = cdb[nc < 10 ? nc : 9]; nc++; handshake(); end
            3'b001: begin
                if (nd < 128) begin data[nd] = dout; pair[nd] = dpair; pairn[nd] = dpair_next; end
                nd++;
                handshake();
            end
            3'b011: begin status = dout; handshake(); end
            3'b111: begin message = dout; handshake(); end
            default: handshake();
        endcase
    end
    clocks(50);
endtask

// READ TOC, then compare the first n bytes against want; the rest must be 0.
task automatic toc(input string name, input bit msf, input [7:0] start,
                   input [1:0] fmt, input integer alloc,
                   input integer n, input reg [7:0] want [64]);
    bit ok;
    integer i;
    string got;
    cmd10(8'h43, {6'd0, msf, 1'b0}, 8'h00, 8'h00, 8'h00, 8'h00, start,
          alloc[15:8], alloc[7:0], {fmt, 6'd0});
    ok = (status == 8'h00) && (nd == alloc);
    for (i = 0; i < nd && i < 128; i++) begin
        if (data[i] != ((i < n) ? want[i] : 8'h00)) ok = 0;
        // the look-ahead the pair path reads
        if (pair[i] != {data[i], (i + 1 < nd) ? data[i + 1] : pair[i][7:0]}) ok = 0;
        if (i + 3 < nd && pairn[i] != {data[i + 2], data[i + 3]}) ok = 0;
    end
    got = "";
    for (i = 0; i < n && i < nd; i++) got = {got, $sformatf("%02x ", data[i])};
    if (!ok) fails++;
    $display("  %-34s %s  status=%02x data=%0d\n      %s", name, ok ? "ok  " : "FAIL",
             status, nd, got);
    if (!ok) begin
        got = "";
        for (i = 0; i < n; i++) got = {got, $sformatf("%02x ", want[i])};
        $display("  want %s", got);
        for (i = 0; i < nd && i < 24; i++)
            $display("      [%0d] %02x pair %04x next %04x", i, data[i], pair[i], pairn[i]);
    end
endtask

reg [7:0] w [64];
initial begin
    clocks(10);
    rst = 1'b0;
    clocks(5);
    img_mounted = 1'b1;
    clocks(3);
    img_mounted = 1'b0;
    clocks(2000);                       // the lead-out's M/S/F settles

    // A fresh disc may answer the first command with UNIT ATTENTION.
    cmd10(8'h00, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    cmd10(8'h03, 0, 0, 0, 18, 0, 0, 0, 0, 0);

    $display("scsi.v READ TOC on a CD-ROM target (ID 4), 300,001-sector image");
    w = '{default: 8'h00};
    w[0:19] = '{8'h00, 8'h12, 8'h01, 8'h01,  8'h00, 8'h14, 8'h01, 8'h00,
                8'h00, 8'h00, 8'h00, 8'h00,  8'h00, 8'h14, 8'hAA, 8'h00,
                8'h00, 8'h04, 8'h93, 8'hE1};
    toc("F0L format 0, LBA, start 0", 1'b0, 8'h00, 2'd0, 32, 20, w);

    w[8:11]  = '{8'h00, 8'h00, 8'h02, 8'h00};
    w[16:19] = '{8'h00, 8'd66, 8'd42, 8'd1};
    toc("F0M format 0, MSF, start 0", 1'b1, 8'h00, 2'd0, 20, 20, w);
    toc("F0M format 0, MSF, start 1", 1'b1, 8'h01, 2'd0, 24, 20, w);

    w = '{default: 8'h00};
    w[0:11] = '{8'h00, 8'h0A, 8'h01, 8'h01,  8'h00, 8'h14, 8'hAA, 8'h00,
                8'h00, 8'd66, 8'd42, 8'd1};
    toc("FAA format 0, MSF, start 0xAA", 1'b1, 8'hAA, 2'd0, 12, 12, w);
    toc("FAA format 0, MSF, start 0xAA, 16", 1'b1, 8'hAA, 2'd0, 16, 12, w);

    w = '{default: 8'h00};
    w[0:11] = '{8'h00, 8'h0A, 8'h01, 8'h01,  8'h00, 8'h14, 8'h01, 8'h00,
                8'h00, 8'h00, 8'h00, 8'h00};
    toc("F1  format 1, LBA", 1'b0, 8'h00, 2'd1, 12, 12, w);

    w = '{default: 8'h00};
    w[0:3]   = '{8'h00, 8'd46, 8'h01, 8'h01};
    w[4:14]  = '{8'h01, 8'h14, 8'h00, 8'hA0, 8'h00, 8'h00, 8'h00, 8'h00, 8'h01, 8'h00, 8'h00};
    w[15:25] = '{8'h01, 8'h14, 8'h00, 8'hA1, 8'h00, 8'h00, 8'h00, 8'h00, 8'h01, 8'h00, 8'h00};
    w[26:36] = '{8'h01, 8'h14, 8'h00, 8'hA2, 8'h00, 8'h00, 8'h00, 8'h00, 8'd66, 8'd42, 8'd1};
    w[37:47] = '{8'h01, 8'h14, 8'h00, 8'h01, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h02, 8'h00};
    toc("F2  format 2 (full TOC)", 1'b1, 8'h00, 2'd2, 52, 48, w);

    $display("%s", fails ? "TB_CDTOC FAIL" : "TB_CDTOC PASS");
    $finish;
end

endmodule
