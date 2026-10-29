//============================================================================
//  tb_ioc_poweroff -- IOC PANEL's soft power-off edge (rtl/sgi/sgi_ioc.sv)
//  `make -C verilator tb_ioc_poweroff`
//
//  IRIX 6's cpu_powerdown writes 0xFFFFFFFE to PANEL (IOC + 0x50) and loops
//  forever; the PROM writes PANEL for its write-1-to-clear bits with bit 0
//  set. The core must report exactly the 1 -> 0 edge of bit 0 and nothing
//  else - one clock, once per edge:
//    T1  power-on: PANEL reads 1, no pulse
//    T2  the PROM's kind of write (bit 0 set): no pulse
//    T3  IRIX's write: one pulse, exactly one clock wide
//    T4  the same write again (the loop): no pulse - bit 0 is already 0
//    T5  bit 0 back to 1 (software), then 0 again: a second pulse
//    T6  a write to the other byte lane (offset 0x54) never pulses
//    T7  reset: PANEL back to 1, no pulse
//============================================================================
`timescale 1ns/1ps
module tb_ioc_poweroff;

reg clk = 0;
always #5 clk = ~clk;

reg         reset = 1;
reg         sel = 0, we = 0;
reg   [7:0] addr = 0;
reg   [2:0] aoff = 0;
reg   [7:0] be = 0;
reg  [63:0] wdata = 0;
wire [63:0] rdata;
wire        ack;
wire  [4:0] irq_lines;
wire [39:0] int2_state;
wire        power_off;

sgi_ioc dut (
    .clk        (clk),
    .reset      (reset),
    .ce         (1'b1),
    .sel        (sel),
    .we         (we),
    .addr       (addr),
    .aoff       (aoff),
    .be         (be),
    .wdata      (wdata),
    .rdata      (rdata),
    .ack        (ack),
    .l0_source  (8'h00),
    .l1_source  (8'h00),
    .map_source (8'h00),
    .irq_lines  (irq_lines),
    .int2_state (int2_state),
    .power_off  (power_off)
);

int fails = 0;
int pulses = 0;            // power_off clocks seen since the last clear
always @(posedge clk) if (power_off) pulses++;

// A 32-bit CPU write to IOC + off: an 8-aligned doubleword address, the word
// in the lane the offset selects (sgi_ioc.sv's ioc_wr_byte).
task automatic wr32(input [7:0] off, input [31:0] v);
    begin
        @(negedge clk);
        addr  = {off[7:3], 3'b000};
        aoff  = {off[2], 2'b00};
        be    = off[2] ? 8'h0F : 8'hF0;
        wdata = off[2] ? {32'h0, v} : {v, 32'h0};
        sel = 1; we = 1;
        @(negedge clk);
        sel = 0; we = 0; be = 0;
        repeat (3) @(negedge clk);
    end
endtask

task automatic rd32(input [7:0] off, output [31:0] v);
    begin
        @(negedge clk);
        addr = {off[7:3], 3'b000};
        aoff = {off[2], 2'b00};
        sel = 1; we = 0;
        @(negedge clk);
        sel = 0;
        // ack and rdata are registered on the clock after sel and last one
        // clock, so they are valid right here, at this negedge.
        if (!ack) begin $display("  FAIL read: no ack"); fails++; end
        v = off[2] ? rdata[31:0] : rdata[63:32];
        repeat (2) @(negedge clk);
    end
endtask

task automatic check(input string name, input bit ok);
    begin
        if (ok) $display("  ok   %s", name);
        else begin $display("  FAIL %s", name); fails++; end
    end
endtask

reg [31:0] v;

initial begin
    repeat (4) @(negedge clk);
    reset = 0;
    repeat (4) @(negedge clk);

    $display("T1 power-on");
    rd32(8'h50, v);
    check("PANEL bit 0 = 1 after reset", v[0] == 1'b1);
    check("no pulse at power-on", pulses == 0);

    $display("T2 the PROM's write, bit 0 set");
    wr32(8'h50, 32'h0000_0053);
    check("no pulse", pulses == 0);
    rd32(8'h50, v);
    check("bit 0 still 1", v[0] == 1'b1);

    $display("T3 IRIX's write, 0xFFFFFFFE");
    pulses = 0;
    wr32(8'h50, 32'hFFFF_FFFE);
    check("exactly one pulse clock", pulses == 1);
    rd32(8'h50, v);
    check("bit 0 now 0", v[0] == 1'b0);

    $display("T4 the same write again (cpu_powerdown's loop)");
    pulses = 0;
    repeat (3) wr32(8'h50, 32'hFFFF_FFFE);
    check("no pulse without an edge", pulses == 0);

    $display("T5 back on, then off again");
    pulses = 0;
    wr32(8'h50, 32'h0000_0001);
    check("no pulse on 0 -> 1", pulses == 0);
    wr32(8'h50, 32'h0000_0000);
    check("one pulse on the second 1 -> 0", pulses == 1);

    $display("T6 the other lane of the same doubleword");
    wr32(8'h50, 32'h0000_0001);
    pulses = 0;
    wr32(8'h54, 32'h0000_0000);
    check("offset 0x54 never pulses", pulses == 0);
    rd32(8'h50, v);
    check("PANEL untouched by it", v[0] == 1'b1);

    $display("T7 reset");
    wr32(8'h50, 32'hFFFF_FFFE);
    pulses = 0;
    reset = 1; repeat (3) @(negedge clk); reset = 0; repeat (3) @(negedge clk);
    rd32(8'h50, v);
    check("PANEL bit 0 = 1 after reset", v[0] == 1'b1);
    check("no pulse from reset", pulses == 0);

    if (fails == 0) $display("tb_ioc_poweroff: PASS");
    else            $display("tb_ioc_poweroff: FAIL (%0d)", fails);
    $finish;
end

endmodule
