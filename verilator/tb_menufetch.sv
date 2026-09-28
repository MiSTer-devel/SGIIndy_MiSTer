//============================================================================
//  tb_menufetch - the display fetch path exactly as sgiindy.sv builds it:
//  two fb_linecaches (drawing planes; auxiliary planes with the flag table)
//  behind fb_fetch_arb, on the REAL ddr3_mux, whose other masters are a CPU
//  load model and nothing else. tb_menufetch.cpp drives the display's real
//  pattern with a menu or an overlay posted; its header says why.
//============================================================================
module tb_menufetch #(
    parameter int FBR_SUB   = 4,
    parameter int FBR_AHEAD = 2,
    parameter int FBR_AHEAD_DEEP = 5
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        px_req,
    input  logic [31:0] px_addr_rgb,
    input  logic [31:0] px_addr_aux,
    output logic [63:0] rgb_rdata,
    output logic        rgb_ack,
    output logic        rgb_miss,
    output logic [63:0] aux_rdata,
    output logic        aux_ack,
    output logic        aux_miss,
    input  logic        vs,
    input  logic        mark,
    input  logic [10:0] mark_line,
    output logic [31:0] aux_skips,

    // the CPU's port on the mux
    input  logic        ram_req,
    input  logic        ram_we,
    input  logic [31:0] ram_addr,
    input  logic  [3:0] ram_burst,
    output logic        ram_ack,
    output logic        ram_last,

    // the bridge
    input  logic        DDRAM_BUSY,
    output logic  [7:0] DDRAM_BURSTCNT,
    output logic [28:0] DDRAM_ADDR,
    input  logic [63:0] DDRAM_DOUT,
    input  logic        DDRAM_DOUT_READY,
    output logic        DDRAM_RD,
    output logic [63:0] DDRAM_DIN,
    output logic  [7:0] DDRAM_BE,
    output logic        DDRAM_WE
);
    logic        lr_req, lr_taken, lr_valid, la_req, la_taken, la_valid;
    logic [31:0] lr_addr, la_addr;
    logic  [7:0] lr_burst, la_burst;
    logic [63:0] lr_dout, la_dout;
    logic        lc_req, lc_taken, lc_valid;
    logic [31:0] lc_addr;
    logic  [7:0] lc_burst;
    logic [63:0] lc_dout;
    logic        aux_fetching, rgb_urgent, aux_urgent;

    fb_linecache #(.TRACK_ZERO(1'b0)) u_rgb (
        .clk(clk), .reset(reset),
        .px_req(px_req), .px_addr(px_addr_rgb), .px_rdata(rgb_rdata), .px_ack(rgb_ack),
        .vs(vs), .mark(1'b0), .mark_line(11'd0),
        .fbr_req(lr_req), .fbr_addr(lr_addr), .fbr_burst(lr_burst),
        .fbr_taken(lr_taken), .fbr_dout(lr_dout), .fbr_dout_valid(lr_valid),
        .miss(rgb_miss), .fetching(), .urgent(rgb_urgent), .dbg_skips(), .dbg_miss_mark(1'b0));

    fb_linecache #(.TRACK_ZERO(1'b1), .REGION_BASE(32'h0080_0000)) u_aux (
        .clk(clk), .reset(reset),
        .px_req(px_req), .px_addr(px_addr_aux), .px_rdata(aux_rdata), .px_ack(aux_ack),
        .vs(vs), .mark(mark), .mark_line(mark_line),
        .fbr_req(la_req), .fbr_addr(la_addr), .fbr_burst(la_burst),
        .fbr_taken(la_taken), .fbr_dout(la_dout), .fbr_dout_valid(la_valid),
        .miss(aux_miss), .fetching(aux_fetching), .urgent(aux_urgent), .dbg_skips(aux_skips), .dbg_miss_mark(1'b0));

    fb_fetch_arb u_arb (
        .clk(clk), .reset(reset),
        .a_req(lr_req), .a_urgent(rgb_urgent), .a_addr(lr_addr), .a_burst(lr_burst),
        .a_taken(lr_taken), .a_dout(lr_dout), .a_dout_valid(lr_valid),
        .b_req(la_req), .b_urgent(aux_urgent), .b_addr(la_addr), .b_burst(la_burst),
        .b_taken(la_taken), .b_dout(la_dout), .b_dout_valid(la_valid),
        .fbr_req(lc_req), .fbr_addr(lc_addr), .fbr_burst(lc_burst),
        .fbr_taken(lc_taken), .fbr_dout(lc_dout), .fbr_dout_valid(lc_valid));

    logic [63:0] ram_rdata, prom_rdata, fbw_rdata;
    logic        dl_ack, prom_ack, fbw_ack;
    logic  [5:0] dbg_busy, dbg_pend;
    logic        dbg_take, dbg_take_rd, dbg_gap, dbg_cmdwait;
    logic  [2:0] dbg_take_m;
    logic [63:0] dbg_rdlat [3];

    ddr3_mux #(.FBR_SUB(FBR_SUB), .FBR_AHEAD(FBR_AHEAD), .FBR_AHEAD_DEEP(FBR_AHEAD_DEEP)) u_mem (
        .clk(clk), .reset(reset),
        .fbr_req(lc_req), .fbr_addr(lc_addr), .fbr_burst(lc_burst),
        .fbr_taken(lc_taken), .fbr_dout(lc_dout), .fbr_dout_valid(lc_valid),
        .fbr_deep(aux_fetching), .fbr_urgent(rgb_urgent | aux_urgent),
        .dl_req(1'b0), .dl_addr(32'h0), .dl_wdata(64'h0), .dl_be(8'h0), .dl_ack(dl_ack),
        .ram_req(ram_req), .ram_we(ram_we), .ram_addr(ram_addr),
        .ram_wdata(64'h0), .ram_be(8'hFF), .ram_burst(ram_burst),
        .ram_wdata3(192'h0), .ram_rdata(ram_rdata), .ram_ack(ram_ack), .ram_last(ram_last),
        .prom_req(1'b0), .prom_addr(32'h0), .prom_rdata(prom_rdata), .prom_ack(prom_ack),
        .fbw_req(1'b0), .fbw_we(1'b0), .fbw_addr(32'h0), .fbw_wdata(64'h0), .fbw_be(8'h0),
        .fbw_rdata(fbw_rdata), .fbw_ack(fbw_ack),
        .bcn_req(1'b0), .bcn_addr(32'h0), .bcn_wdata(64'h0),
        .dbg_busy(dbg_busy), .dbg_pend(dbg_pend), .dbg_take(dbg_take),
        .dbg_take_m(dbg_take_m), .dbg_take_rd(dbg_take_rd), .dbg_gap(dbg_gap),
        .dbg_cmdwait(dbg_cmdwait), .dbg_rdlat(dbg_rdlat),
        .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
        .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE));
endmodule
