//============================================================================
//  tb_audio_top - sgi_hpc3 with flat ports, for tb_audio.cpp.
//
//  An unpacked-array top-level port gets a raw C array whose glue does not
//  compile under the 5.020 simulator (see sim_top.sv), so HAL2's beacon words come out
//  here as three plain vectors. Nothing else is added: the bench drives the
//  chip's own PIO port and answers its own memory port.
//============================================================================
module tb_audio_top #(
    parameter int AUDIO_CLK_HZ = 5_000_000
)(
    input  logic        clk,
    input  logic        reset,
    input  logic        audio_en,

    input  logic        sel,
    input  logic        we,
    input  logic [18:0] addr,
    input  logic  [2:0] aoff,
    input  logic  [7:0] be,
    input  logic [63:0] wdata,
    output logic [63:0] rdata,
    output logic        ack,
    output logic        claimed,

    output logic        dma_req,
    output logic        dma_we,
    output logic [31:0] dma_addr,
    output logic [63:0] dma_wdata,
    output logic  [7:0] dma_be,
    input  logic [63:0] dma_rdata,
    input  logic        dma_ack,

    output logic [15:0] audio_l,
    output logic [15:0] audio_r,
    output logic [63:0] audio0,
    output logic [63:0] audio1,
    output logic [63:0] audio2
);
    logic [63:0] dbg [3];
    assign audio0 = dbg[0];
    assign audio1 = dbg[1];
    assign audio2 = dbg[2];

    sgi_hpc3 #(.AUDIO_CLK_HZ(AUDIO_CLK_HZ)) dut (
        .clk (clk), .reset (reset),
        .sel (sel), .we (we), .addr (addr), .aoff (aoff), .be (be),
        .wdata (wdata), .rdata (rdata), .ack (ack), .claimed (claimed),
        .dma_req (dma_req), .dma_we (dma_we), .dma_addr (dma_addr),
        .dma_wdata (dma_wdata), .dma_be (dma_be),
        .dma_rdata (dma_rdata), .dma_ack (dma_ack),
        // SCSI's device side idle: the only master that moves is audio.
        .scsi_dev_req (1'b0), .scsi_dev_dir_in (1'b0), .scsi_dev_wdata (8'd0),
        .scsi_dev_eop (1'b0), .scsi_dev_ack (), .scsi_dev_rdata (), .scsi_dev_reset (),
        .scsi_dma_irq (), .dbg_scsi0_dma (),
        .audio_en (audio_en), .audio_l (audio_l), .audio_r (audio_r),
        .dbg_audio (dbg)
    );
endmodule
