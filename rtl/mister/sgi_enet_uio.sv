//============================================================================
//  sgi_enet_uio - Main's port into the Ethernet window, over hps_io's EXT_BUS.
//
//  Main_MiSTer's support/sgi/sgi_enet.cpp runs the SEEQ 80C03 and HPC3's two
//  Ethernet DMA channels; the core keeps only the register window IRIX reads
//  with no time to wait (rtl/sgi/sgi_hpc3.sv, docs/design/ethernet-plan.md).
//  This is the wire between them: one UIO command, 0x70, which hps_io itself
//  does not decode, carried in 16-bit words the way Minimig's hps_ext.v carries
//  its IDE registers.
//
//    0x70, 1, idx, n            then n x (low word, high word) read back
//    0x70, 2, idx, seq, lo, hi  a write, dropped by the window if the guest
//                               has written since Main read `seq`
//    0x70, 3                    empty ram_arb's prefetch buffers
//
//  THE REPLY TO A STROBE IS READ TWO CLOCKS AFTER IT. sys_top raises io_ack a
//  clock after `rack` follows the strobe, and Main reads gp_in - io_ack and
//  the data together - once it sees the ack. So the word Main reads is the
//  io_dout set AT its strobe, and a store word has to be fetched a strobe
//  earlier: the first at the count word, each next one with the high half
//  of the one before. Main spends far longer than the window's few clocks
//  between two strobes.
//============================================================================

module sgi_enet_uio (
    input  logic        clk,
    inout  wire  [35:0] EXT_BUS,

    output logic        ex_rd,
    output logic        ex_wr,
    output logic  [8:0] ex_idx,
    output logic [15:0] ex_seq,
    output logic [31:0] ex_wdata,
    input  logic [31:0] ex_rdata,
    input  logic        ex_done,
    output logic        ex_inval
);
    localparam logic [15:0] UIO_SGI_ENET = 16'h0070;

    logic [15:0] io_dout;
    logic        dout_en;
    wire  [15:0] io_din    = EXT_BUS[31:16];
    wire         io_strobe = EXT_BUS[33];
    wire         io_uio    = EXT_BUS[34];
    assign EXT_BUS[15:0] = io_dout;
    assign EXT_BUS[32]   = dout_en;

    logic  [2:0] wc;          // which word of the command this strobe is, saturating
    logic [15:0] cmd, op, left;
    logic        hi;          // a read's next word out is the high half
    logic [31:0] data;

    always_ff @(posedge clk) begin
        ex_rd    <= 1'b0;
        ex_wr    <= 1'b0;
        ex_inval <= 1'b0;
        if (ex_done) data <= ex_rdata;

        if (!io_uio) begin
            wc      <= 3'd0;
            dout_en <= 1'b0;
            io_dout <= 16'h0;
        end
        else if (io_strobe) begin
            io_dout <= 16'h0;
            if (wc != 3'd7) wc <= wc + 3'd1;

            if (wc == 3'd0) begin
                cmd     <= io_din;
                dout_en <= (io_din == UIO_SGI_ENET);
            end
            else if (cmd == UIO_SGI_ENET) begin
                if (wc == 3'd1) begin
                    op       <= io_din;
                    ex_inval <= (io_din == 16'd3);
                    hi       <= 1'b0;
                end
                else if (op == 16'd1) begin
                    // READ idx n
                    if (wc == 3'd2) ex_idx <= io_din[8:0];
                    else if (wc == 3'd3) begin
                        left  <= io_din;
                        ex_rd <= (io_din != 16'd0);
                    end
                    else if (!hi) begin
                        io_dout <= data[15:0];
                        hi      <= 1'b1;
                    end
                    else begin
                        io_dout <= data[31:16];
                        hi      <= 1'b0;
                        left    <= left - 16'd1;
                        if (left > 16'd1) begin
                            ex_idx <= ex_idx + 9'd1;
                            ex_rd  <= 1'b1;
                        end
                    end
                end
                else if (op == 16'd2) begin
                    // WRITE idx seq lo hi
                    if (wc == 3'd2)      ex_idx          <= io_din[8:0];
                    else if (wc == 3'd3) ex_seq          <= io_din;
                    else if (wc == 3'd4) ex_wdata[15:0]  <= io_din;
                    else if (wc == 3'd5) begin
                        ex_wdata[31:16] <= io_din;
                        ex_wr           <= 1'b1;
                    end
                end
            end
        end
    end

endmodule
