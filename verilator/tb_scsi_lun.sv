//============================================================================
//  tb_scsi_lun -- rtl/scsi/scsi.v as a disk target, answering INQUIRY per LUN.
//  `make -C verilator tb_scsi_lun`.
//
//  IRIX probes every logical unit of every target: Select-with-ATN, IDENTIFY
//  with the LUN in bits 2:0 (the WD33C93B sends it from its TARGET LUN
//  register), INQUIRY. A target that answers the same INQUIRY on every LUN is
//  one disk eight times over - hinv's "unit 1, lun 1..7" and the desktop's
//  Disk(0,1,1)..Disk(0,1,7). An unsupported LUN must answer with byte 0 =
//  0x7F (peripheral qualifier 3, device type 0x1F).
//
//    L0  IDENTIFY LUN 0          -> byte 0 = 0x00 (direct-access, present)
//    L1  IDENTIFY LUN 1          -> byte 0 = 0x7F
//    L7  IDENTIFY LUN 7          -> byte 0 = 0x7F
//    S2  no ATN, CDB byte 1 LUN 2 (SCSI-1 addressing) -> byte 0 = 0x7F
//    R0  IDENTIFY LUN 0 again    -> 0x00: nothing sticks from the probes
//
//  Each case also checks the rest of the exchange still completes: 36 bytes of
//  data, GOOD status, COMMAND COMPLETE, bus free.
//============================================================================
`timescale 1ns/1ps
module tb_scsi_lun;

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

scsi #(.ID(3'd1)) dut (
    .clk(clk), .rst(rst), .sys_rst(rst),
    .sel(sel), .bus_busy(1'b0), .atn(atn), .cd_enable(1'b0),
    .bsy(bsy), .msg(msg), .cd(cd), .io(io), .req(req), .req_bus(req_bus),
    .ack(ack), .host_csr_rd(1'b0), .host_data_rd(1'b0),
    .din(din), .dout(dout),
    .img_mounted(img_mounted), .img_blocks(32'd16384), .io_ack(1'b0),
    .sd_buff_addr(8'd0), .sd_buff_addr_hi(5'd0), .sd_buff_dout(16'd0), .sd_buff_wr(1'b0),
    .dbg_dma_word(1'b0), .dbg_dma_long(1'b0), .dbg_dma_lowbyte(8'd0),
    .tb_mounted(1'b0), .tb_ack(1'b0)
);

integer fails = 0;

task automatic clocks(input integer n);
    repeat (n) @(posedge clk);
endtask

// Wait for REQ or bus free, bounded.
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

// One INQUIRY. use_atn: select with ATN and send IDENTIFY(id_lun); cdb_lun goes
// in CDB byte 1 bits 7:5.
task automatic inquiry(input string name, input bit use_atn, input [2:0] id_lun,
                       input [2:0] cdb_lun, input [7:0] want_b0);
    reg [7:0] cdb [6];
    reg [7:0] data [64];
    reg [7:0] status, message;
    integer nd, nc, guard;
    bit got, freed, ok;
    cdb[0] = 8'h12; cdb[1] = {cdb_lun, 5'd0}; cdb[2] = 8'h00;
    cdb[3] = 8'h00; cdb[4] = 8'd36; cdb[5] = 8'h00;
    nd = 0; nc = 0; status = 8'hFF; message = 8'hFF;

    // Selection: our ID's bit on the bus, SEL, optionally ATN.
    din = 8'h02;
    atn = use_atn;
    sel = 1'b1;
    for (guard = 0; guard < 1000 && !bsy; guard++) @(posedge clk);
    sel = 1'b0;

    for (guard = 0; guard < 200; guard++) begin
        wait_req(got, freed);
        if (freed || !got) break;
        case ({msg, cd, io})
            3'b110: begin                       // MESSAGE OUT: IDENTIFY
                din = 8'h80 | {5'd0, id_lun};
                atn = 1'b0;                     // the last message byte
                handshake();
            end
            3'b010: begin                       // COMMAND
                din = cdb[nc < 6 ? nc : 5];
                nc++;
                handshake();
            end
            3'b001: begin                       // DATA (target -> initiator)
                if (nd < 64) data[nd] = dout;
                nd++;
                handshake();
            end
            3'b011: begin status = dout; handshake(); end    // STATUS
            3'b111: begin message = dout; handshake(); end   // MESSAGE IN
            default: handshake();
        endcase
    end
    clocks(20);

    ok = (nd == 36) && (data[0] == want_b0) && (status == 8'h00) &&
         (message == 8'h00) && !bsy;
    if (!ok) fails++;
    $display("  %-30s %s  byte0=%02x want %02x  data=%0d status=%02x msg=%02x bsy=%0d",
             name, ok ? "ok  " : "FAIL", nd > 0 ? data[0] : 8'hxx, want_b0, nd,
             status, message, bsy);
    clocks(50);
endtask

initial begin
    clocks(10);
    rst = 1'b0;
    clocks(5);
    img_mounted = 1'b1;
    clocks(3);
    img_mounted = 1'b0;
    clocks(10);

    $display("scsi.v INQUIRY per logical unit (disk target, ID 1)");
    inquiry("L0  IDENTIFY LUN 0",          1'b1, 3'd0, 3'd0, 8'h00);
    inquiry("L1  IDENTIFY LUN 1",          1'b1, 3'd1, 3'd0, 8'h7F);
    inquiry("L7  IDENTIFY LUN 7",          1'b1, 3'd7, 3'd0, 8'h7F);
    inquiry("S2  no ATN, CDB LUN 2",       1'b0, 3'd0, 3'd2, 8'h7F);
    inquiry("R0  IDENTIFY LUN 0 again",    1'b1, 3'd0, 3'd0, 8'h00);

    $display("%s", fails ? "TB_SCSI_LUN FAIL" : "TB_SCSI_LUN PASS");
    $finish;
end

endmodule
