//============================================================================
//  ramarb_l2 - ram_arb with l2_cache behind it, with ram_arb's own port list,
//  so tb_ramarb_pf.cpp drives the pair against its slow memory unchanged
//  (`make -C verilator l2test`, built with -DL2WRAP and --prefix Vram_arb).
//  Two extra inputs: `l2_disable` (an undriven Verilator input reads 0, so
//  the second level is on by default) and `ext_inval`.
//============================================================================
module ramarb_l2 (
    input  logic        clk,
    input  logic        reset,
    input  logic        cpu_req,
    input  logic        cpu_we,
    input  logic [31:0] cpu_addr,
    input  logic [63:0] cpu_wdata,
    input  logic  [7:0] cpu_be,
    input  logic  [2:0] cpu_burst,
    input  logic [191:0] cpu_wdata3,
    input  logic        cpu_ifill,
    input  logic        pf_enable,
    input  logic        cpu_dfill,
    input  logic        dpf_enable,
    input  logic        ext_inval,
    input  logic        l2_disable,
    output logic        cpu_ack,
    output logic        cpu_last,
    output logic [63:0] cpu_rdata,
    input  logic        dma_req,
    input  logic        dma_we,
    input  logic [31:0] dma_addr,
    input  logic [63:0] dma_wdata,
    input  logic  [7:0] dma_be,
    output logic        dma_ack,
    output logic        dma_granted,
    output logic        ram_req,
    output logic        ram_we,
    output logic [31:0] ram_addr,
    output logic [63:0] ram_wdata,
    output logic  [7:0] ram_be,
    output logic  [3:0] ram_burst,
    output logic [191:0] ram_wdata3,
    input  logic [63:0] ram_rdata,
    input  logic        ram_ack,
    input  logic        ram_last,
    output logic        dbg_cpu_wait,
    output logic        dbg_dma_go,
    output logic        dbg_pf_hit,
    output logic        dbg_pf_fill,
    output logic        dbg_dpf_hit,
    output logic        dbg_dpf_fill
);
    wire        a_req, a_we, a_ifill, a_dfill, a_ack, a_last;
    wire [31:0] a_addr;
    wire [63:0] a_wdata, a_rdata;
    wire  [7:0] a_be;
    wire  [3:0] a_burst;
    wire [191:0] a_wdata3;
    wire pf_h, pf_f, dpf_h, dpf_f, l2_hi, l2_hd, l2_fi, l2_fd;

    ram_arb u_arb (
        .clk(clk), .reset(reset),
        .cpu_req(cpu_req), .cpu_we(cpu_we), .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata),
        .cpu_be(cpu_be), .cpu_burst(cpu_burst), .cpu_wdata3(cpu_wdata3),
        .cpu_ifill(cpu_ifill), .pf_enable(pf_enable && l2_disable),
        .cpu_dfill(cpu_dfill), .dpf_enable(dpf_enable && l2_disable),
        .ext_inval(ext_inval),
        .cpu_ack(cpu_ack), .cpu_last(cpu_last), .cpu_rdata(cpu_rdata),
        .dma_req(dma_req), .dma_we(dma_we), .dma_addr(dma_addr), .dma_wdata(dma_wdata),
        .dma_be(dma_be), .dma_ack(dma_ack), .dma_granted(dma_granted),
        .ram_req(a_req), .ram_we(a_we), .ram_addr(a_addr), .ram_wdata(a_wdata),
        .ram_be(a_be), .ram_burst(a_burst), .ram_wdata3(a_wdata3),
        .ram_ifill(a_ifill), .ram_dfill(a_dfill),
        .ram_rdata(a_rdata), .ram_ack(a_ack), .ram_last(a_last),
        .dbg_cpu_wait(dbg_cpu_wait), .dbg_dma_go(dbg_dma_go),
        .dbg_pf_hit(pf_h), .dbg_pf_fill(pf_f), .dbg_dpf_hit(dpf_h), .dbg_dpf_fill(dpf_f)
    );

    // A small second level (64 lines = 2 KB) so the bench's window of lines
    // evicts and refills it constantly; the shape, not the size, is under test.
    l2_cache #(.IDX_BITS(6)) u_l2 (
        .clk(clk), .reset(reset), .enable(!l2_disable), .ext_inval(ext_inval),
        .up_req(a_req), .up_we(a_we), .up_addr(a_addr), .up_wdata(a_wdata), .up_be(a_be),
        .up_burst(a_burst), .up_wdata3(a_wdata3), .up_ifill(a_ifill), .up_dfill(a_dfill),
        .up_rdata(a_rdata), .up_ack(a_ack), .up_last(a_last),
        .dn_req(ram_req), .dn_we(ram_we), .dn_addr(ram_addr), .dn_wdata(ram_wdata),
        .dn_be(ram_be), .dn_burst(ram_burst), .dn_wdata3(ram_wdata3),
        .dn_rdata(ram_rdata), .dn_ack(ram_ack), .dn_last(ram_last),
        .dbg_hit_i(l2_hi), .dbg_hit_d(l2_hd), .dbg_fill_i(l2_fi), .dbg_fill_d(l2_fd)
    );

    // The bench reports "fills answered from the buffers": with the second
    // level on, those are its hits.
    assign dbg_pf_hit   = pf_h  | l2_hi;
    assign dbg_pf_fill  = pf_f  | l2_fi;
    assign dbg_dpf_hit  = dpf_h | l2_hd;
    assign dbg_dpf_fill = dpf_f | l2_fd;
endmodule
