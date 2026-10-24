//============================================================================
//  sgi_hpc3 - the High performance Peripheral Controller, third generation.
//
//  HPC3 owns the whole of 0x1FB80000-0x1FBFFFFF and everything hanging off it:
//  the eight PBUS DMA channels, two SCSI ports, the Ethernet port, ten PBUS
//  PIO chip selects (HAL2 is channel 0, INT2/IOC is channel 6) and the
//  battery-backed RAM window that carries the Dallas RTC. Address map from the
//  HPC3 chip specification's section 2 table, which agrees with IRIS's
//  src/hpc3.rs offset constants throughout.
//
//  WHAT THIS IS AND IS NOT. This is the register file plus the decode in front
//  of it. Two sets of channels behind it are real: SCSI channel 0 (sub-block
//  8, 0x1FB90000), whose registers and descriptor engine live in
//  hpc3_scsi_dma.sv, and PBUS DMA channels 0-3 (sub-blocks 0-3), the audio
//  channels, in hpc3_pbus_dma.sv, feeding HAL2 (hal2.sv, PBUS PIO channels
//  0-3). The two engines share this chip's one memory port. Every other
//  channel is plain storage that reads back what was written - enough for the
//  PROM's power-on tests, and honest about moving no data.
//
//  Registers are 32 bits at a stride of four, unlike MC's - so both words of
//  every doubleword bus cycle are live, and both are decoded.
//
//  A NOTE ON "READ ONLY". The spec marks cbp, bc, gio and dev read-only, and
//  says of rx_cbp that it "should only be updated through DMA descriptor
//  fetches (and not through PIO)". The PROM disagrees in practice: at
//  0xBFC03E58 it walks a one-bit pattern through 0x1FB94000 - enetr.cbp - and
//  reads each value back, dropping into an endless diagnostic loop if any
//  fails. So the register is writable through PIO on real silicon and the
//  spec's "read only" is advice to drivers, not a property of the hardware.
//  Every register here is therefore plain storage.
//
//  ADDRESSES THIS DOES NOT CLAIM stay unclaimed on the bus rather than reading
//  back zero, so `claimed` is an output. The holes are the map of what is
//  still missing, and the harness prints them on exit; making them silently
//  answer 0 would hide the next thing to build.
//============================================================================

module sgi_hpc3 #(
    parameter int AUDIO_CLK_HZ = 50_000_000
)(
    input  logic        clk,
    input  logic        reset,

    input  logic        sel,          // one-cycle request pulse, address in window
    input  logic        we,
    input  logic [18:0] addr,         // offset into the 512 KB window, 8-aligned
    // Which word of the doubleword the CPU actually addressed. Byte enables
    // cannot answer that on a read, and SCSI channel 0's control register
    // clears its interrupt when it is read - so a driver reading the byte
    // count beside it must not clear anything. See rtl/cpu/r4300_bus.sv.
    input  logic  [2:0] aoff,
    input  logic  [7:0] be,
    input  logic [63:0] wdata,
    output logic [63:0] rdata,
    output logic        ack,

    // ---- SCSI channel 0's bus master port, out to main memory ------------
    output logic        dma_req,
    output logic        dma_we,
    output logic [31:0] dma_addr,
    output logic [63:0] dma_wdata,
    output logic  [7:0] dma_be,
    input  logic [63:0] dma_rdata,
    input  logic        dma_ack,

    // ---- SCSI channel 0's device side, to the WD33C93B -------------------
    input  logic        scsi_dev_req,
    input  logic        scsi_dev_dir_in,
    input  logic  [7:0] scsi_dev_wdata,
    input  logic        scsi_dev_eop,
    output logic        scsi_dev_ack,
    output logic  [7:0] scsi_dev_rdata,
    output logic        scsi_dev_reset,

    output logic        scsi_dma_irq,

    // SGI: DDR3 debug beacon (docs/29) - the SCSI0 DMA channel's live state.
    output logic [63:0] dbg_scsi0_dma,

    // ---- audio -------------------------------------------------------------
    // The OSD's audio switch (hal2.sv `present`), and HAL2's DAC: signed
    // 16-bit, clk domain.
    input  logic        audio_en,
    output logic [15:0] audio_l,
    output logic [15:0] audio_r,
    // Beacon words: HAL2's two (hal2.sv dbg) and the PBUS engine's.
    output logic [63:0] dbg_audio [3],

    // ---- Ethernet: the window Main drives (docs/design/ethernet-plan.md) --
    // One request at a time from sgiindy.sv's UIO decoder: ex_rd reads word
    // ex_idx, ex_wr writes ex_wdata there; ex_done answers either. Indices
    // below 0x100 are the register store, 0x100 and up the live registers
    // ("the ethernet window" below).
    input  logic        ex_rd,
    input  logic        ex_wr,
    input  logic  [8:0] ex_idx,
    input  logic [15:0] ex_seq,
    input  logic [31:0] ex_wdata,
    output logic [31:0] ex_rdata,
    output logic        ex_done,
    // The Ethernet interrupt: IOC local 0 bit 3.
    output logic        enet_irq,

    // Combinational: 0 means this offset is not decoded here at all, and the
    // access should fall through to the core's unclaimed-cycle path.
    output logic        claimed
);

    // ---- block bases, from the HPC3 spec's address map --------------------
    localparam logic [18:0] PBUS_DMA_BASE = 19'h00000;  // 8 channels, stride 0x2000
    localparam logic [18:0] HD_ENET_BASE  = 19'h10000;  // hd0/hd1/enetr/enetx, stride 0x2000
    localparam logic [18:0] DMA_END       = 19'h20000;
    localparam logic [18:0] GEN_BASE      = 19'h30000;  // intstat, misc, eeprom, bus_error
    localparam logic [18:0] GEN_END       = 19'h30020;
    // The SEEQ 80C03's eight byte registers, one per word.
    localparam logic [18:0] SEEQ_BASE     = 19'h54000;
    localparam logic [18:0] SEEQ_END      = 19'h54020;
    // PBUS PIO channels 0-3: HAL2 itself, its AES, volume and synth ports.
    localparam logic [18:0] HAL2_BASE     = 19'h58000;
    localparam logic [18:0] HAL2_END      = 19'h59000;
    localparam logic [18:0] CFGDMA_BASE   = 19'h5C000;  // 8 channels, stride 0x200
    localparam logic [18:0] CFGDMA_END    = 19'h5D000;
    localparam logic [18:0] CFGPIO_BASE   = 19'h5D000;  // 10 channels, stride 0x100
    localparam logic [18:0] CFGPIO_END    = 19'h5E000;
    localparam logic [18:0] WRONLY_BASE   = 19'h5E000;  // prom_we, prom_swap, gen_out
    localparam logic [18:0] WRONLY_END    = 19'h60000;

    typedef enum logic [3:0] {
        BLK_NONE,
        BLK_DESC,     // channel + 0x0000 / 0x0004: buffer and descriptor pointers
        BLK_CTRL,     // channel + 0x1000..0x101F: byte count, control, fifo ptrs, config
        BLK_GEN,      // 0x30000: intstat, gio.misc, eeprom.data, gio.bus_error
        BLK_CFGDMA,
        BLK_CFGPIO,
        BLK_HAL2,
        BLK_WRONLY,
        BLK_SEEQ      // 0x54000: the SEEQ 80C03
    } blk_t;

    // ---- the store -------------------------------------------------------
    // EVERY REGISTER THAT IS PLAIN STORAGE LIVES IN ONE 256-WORD MEMORY, and
    // it is a memory rather than 6,144 flip-flops because that is what those
    // flip-flops cost: 3,637 ALMs of build 41's fit, a tenth of the device,
    // for a register file nothing reads twice a second.
    //
    //   0x00-0x1F  descriptor pairs   {sub-block, word}
    //   0x20-0x27  gen                {addr[4:3], word}
    //   0x28-0x2F  cfgdma             channel 0..7
    //   0x30-0x3F  cfgpio             channel 0..15
    //   0x80-0xFF  control groups     {sub-block, register 0..7}
    //
    // TWO COPIES, BECAUSE ONE BUS CYCLE READS TWO REGISTERS. A doubleword
    // covers the register at +0 and the one at +4 and the CPU may address
    // either, so the read is two ports; a memory has one. Both copies take
    // every write, and each answers one half. They are 2 M10Ks against 483
    // already in use.
    //
    // A read now lands a clock after its address instead of in the same
    // clock, and a partial write costs one more on top - the byte that is not
    // written has to be merged against the word as it is, which is the same
    // read. The bus waits for `ack` however long it takes (r4300_bus holds its
    // request in S_BUSY), nothing here has a deadline, and one PIO access to
    // these registers per boot phase is the traffic. SCSI channel 0, HAL2 and
    // the write-only ports are NOT in the store and still answer in the clock
    // after `sel`, which is what matters: the channel's registers are read on
    // every disk interrupt, and reading its control port clears one.
    localparam int ST_N = 256;
    logic [31:0] st0 [0:ST_N-1];       // answers the +0 half
    logic [31:0] st1 [0:ST_N-1];       // answers the +4 half
    logic  [7:0] st_ra0, st_ra1, st_wa;
    logic [31:0] st_q0, st_q1, st_wd;
    logic        st_we;

    always_ff @(posedge clk) begin
        if (st_we) begin
            st0[st_wa] <= st_wd;
            st1[st_wa] <= st_wd;
        end
        st_q0 <= st0[st_ra0];
        st_q1 <= st1[st_ra1];
    end

    // Power-up contents: Quartus turns this into the M10K's initial value and
    // the simulator runs it at time zero. (Starting the line with the
    // simulator's own name after `//` would make it read the sentence as a
    // directive.) The reset sweep below is what clears the store again on a
    // warm reset, as the `for` loops used to.
    integer ini;
    initial begin
        for (ini = 0; ini < ST_N; ini = ini + 1) begin
            st0[ini] = 32'h0;
            st1[ini] = 32'h0;
        end
    end

    // ---- decode ----------------------------------------------------------
    blk_t blk;
    always_comb begin
        blk = BLK_NONE;
        if (addr < DMA_END) begin
            // Within a 0x2000 sub-block: 0x0000-0x0FFF is the descriptor pair
            // (only the first doubleword of it exists), 0x1000-0x1FFF is the
            // control group.
            if (addr[12])                        blk = BLK_CTRL;
            else if (addr[11:3] == 9'h000)       blk = BLK_DESC;
        end
        else if (addr >= GEN_BASE    && addr < GEN_END)    blk = BLK_GEN;
        else if (addr >= HAL2_BASE   && addr < HAL2_END)   blk = BLK_HAL2;
        else if (addr >= CFGDMA_BASE && addr < CFGDMA_END) blk = BLK_CFGDMA;
        else if (addr >= CFGPIO_BASE && addr < CFGPIO_END) blk = BLK_CFGPIO;
        else if (addr >= WRONLY_BASE && addr < WRONLY_END) blk = BLK_WRONLY;
        else if (addr >= SEEQ_BASE   && addr < SEEQ_END)   blk = BLK_SEEQ;
    end

    assign claimed = (blk != BLK_NONE);

    // Sub-block and register indices. addr is doubleword aligned, so bit 2 is
    // always zero and the word within the pair comes from `w` instead: w=0 is
    // the register at addr+0, w=1 the one at addr+4.
    wire [3:0] sub = addr[16:13];
    function automatic logic [2:0] ctrl_reg(input logic w);
        ctrl_reg = {addr[4:3], w};
    endfunction

    //------------------------------------------------------------------
    // SCSI channel 0 - the one channel that is a real DMA engine
    //------------------------------------------------------------------
    // 0x1FB90000 is sub-block 8, and hpc3_scsi_dma.sv owns all eight of its
    // registers: the arrays below never see them.
    localparam logic [3:0] SUB_SCSI0 = 4'd8;
    wire scsi0_blk = (blk == BLK_DESC || blk == BLK_CTRL) && (sub == SUB_SCSI0);
    // PBUS DMA channels 0-3, 0x1FB80000-0x1FB87FFF: hpc3_pbus_dma.sv's.
    wire pbus_blk  = (blk == BLK_DESC || blk == BLK_CTRL) && (sub[3:2] == 2'b00);

    // The engine indexes its registers as {is_control_block, index}: 0x0 cbp,
    // 0x1 nbdp, 0x8 bc, 0x9 control, 0xA gio, 0xB dev, 0xC dmacfg, 0xD piocfg.
    function automatic logic [3:0] scsi0_reg(input logic w);
        scsi0_reg = (blk == BLK_CTRL) ? {1'b1, ctrl_reg(w)}
                                      : {3'b000, w};
    endfunction

    logic [31:0] scsi0_rd0, scsi0_rd1;
    // Which word of the doubleword the access is really for. A 64-bit store
    // covering both registers of a pair would need two write ports and no
    // driver issues one - the PROM uses `sw` throughout - so the addressed
    // word is the one that is written.
    wire         scsi0_word = aoff[2];

    // Declared before use in the write-merge below.
    logic [31:0] wval [0:1];
    logic  [1:0] wr_en;

    // The two engines' memory requests, before the arbiter at the bottom.
    logic        s_req, s_we, s_ack, p_req, p_we, p_ack;
    logic [31:0] s_addr, p_addr;
    logic [63:0] s_wdata, p_wdata;
    logic  [7:0] s_be, p_be;

    hpc3_scsi_dma u_scsi0_dma (
        .clk        (clk),
        .reset      (reset),

        .pio_sel    (sel && scsi0_blk),
        .pio_reg    (scsi0_reg(scsi0_word)),
        .pio_we     (we && wr_en[scsi0_word]),
        .pio_wdata  (wval[scsi0_word]),
        .rd_reg0    (scsi0_reg(1'b0)),
        .rd_data0   (scsi0_rd0),
        .rd_reg1    (scsi0_reg(1'b1)),
        .rd_data1   (scsi0_rd1),

        .dma_req    (s_req),
        .dma_we     (s_we),
        .dma_addr   (s_addr),
        .dma_wdata  (s_wdata),
        .dma_be     (s_be),
        .dma_rdata  (dma_rdata),
        .dma_ack    (s_ack),

        .dev_req    (scsi_dev_req),
        .dev_dir_in (scsi_dev_dir_in),
        .dev_wdata  (scsi_dev_wdata),
        .dev_eop    (scsi_dev_eop),
        .dev_ack    (scsi_dev_ack),
        .dev_rdata  (scsi_dev_rdata),
        .dev_reset  (scsi_dev_reset),

        .irq        (scsi_dma_irq),
        .dbg_dma    (dbg_scsi0_dma)
    );

    // ---- the DMA interrupt status register -------------------------------
    // gen.intstat, spec section 3.1: bits 7:0 are the PBUS channels, bit 8 is
    // SCSI channel 0 and bit 9 SCSI channel 1. It is read-only and reading it
    // does not disturb the status - the interrupt is acknowledged at the
    // channel's own control port.
    //
    // *** SPEC BUG ***, quoted: "Instead of being in one piece, it is broken
    // and can only be read in two pieces. Bits 4:0 can be read from
    // 0x1fbb0000. Bits 9:5 can be read from 0x1fbb000c. All other bits in both
    // registers should be ignored as they are indeterminate." SCSI0 is bit 8,
    // so it only ever appears at +0x000C. Nothing has tested this: the PROM
    // polls the WD33C93 and never looks here, and the descriptors it builds do
    // not set XIE, so this whole path can be wrong without the boot noticing.
    // PBUS channels 0-3 set theirs from descriptors with XIE; kdsp_a2's rings
    // have none, and the PBUS DMA interrupt is not wired to INT2 - IRIS does
    // not wire it either, and nothing an Indy runs has been seen to want it.
    logic [3:0] pbus_int, pbus_act;
    wire [9:0] intstat = {1'b0, scsi_dma_irq, 4'h0, pbus_int};

    // AN IF/ELSE CHAIN, NOT A CASE, and it has to stay one.
    //
    // This function is reached with a constant argument - hpc3_rd(1'b0)
    // and hpc3_rd(1'b1) - so Quartus 17.0 tries to CONSTANT-EVALUATE the
    // body rather than elaborate it. Its evaluator then meets
    // `case (blk)`, where blk is a non-constant 3-bit enum while the case
    // items evaluate at integer width, and asserts on the mismatch:
    //
    //    Internal Error: Sub-system: VRFX, File: verivalue_elab.cpp,
    //                    Line: 1789
    //    case_expr && case_expr->Size() == Size()
    //
    // That is a tool crash, not an error message: no line number, no file,
    // and a stack trace naming only Verific internals. The width mismatch
    // is what does it - the same case over a plain `enum` compiles - and
    // comparisons are evaluated by a different path, so the chain below is
    // the fix. It is exactly equivalent: the labels are distinct constants
    // and `default` is the final else.
    //
    // ioc_rd in sgi_ioc.sv is the same shape for the same reason. Anything
    // that cases a sized expression against differently sized items, in a
    // function called with constants, will crash Quartus the same way.
    // WHICH BLOCKS ARE IN THE STORE. SCSI channel 0's sub-block is not: the
    // engine owns those registers. Neither are HAL2's file, the write-only
    // PBUS ports or an address this module does not claim.
    wire stored = (blk == BLK_GEN) || (blk == BLK_CFGDMA) || (blk == BLK_CFGPIO) || (blk == BLK_SEEQ)
               || (((blk == BLK_DESC) || (blk == BLK_CTRL)) && !scsi0_blk && !pbus_blk);

    // ---- the Ethernet's live state (docs/design/ethernet-plan.md) ---------
    // What IRIX's if_ec2 reads with no time to wait lives here, not in the
    // store and not in Main: each channel's ACTIVE, the SEEQ's status and
    // command bytes, the interrupt. Main moves the frames and writes these
    // back through its port. The TX command's bits 6:5 pick the bank regs 0-5
    // write into (0 station address, 1 and 2 multicast filter and control).
    logic  [7:0] rx_cmd, tx_cmd;
    logic  [7:0] rx_stat, tx_stat;          // bit 7 OLD: read, or acknowledged
    logic        rx_act, tx_act;            // CTRL bit 9 of each channel
    logic        e_rst, e_loop;             // RESET bits 0 and 2, as written
    logic        e_dmairq;                  // a descriptor's XIE, raised by Main
    logic        e_nocarr = 1'b1;           // SEEQ reg 5 bit 1, from Main
    logic [15:0] e_seq = 16'd0;             // the guest's writes to the window
    // The SEEQ interrupts on a NEW status its command enables, and HPC3 on a
    // descriptor's XIE (IRIS seeq8003.rs raise_interrupt).
    wire rx_irq = !rx_stat[7] && |(rx_cmd[4:0] & rx_stat[4:0]);
    wire tx_irq = !tx_stat[7] && |(tx_cmd[3:0] & tx_stat[3:0]);
    assign enet_irq = rx_irq | tx_irq | e_dmairq;

    // The store's index for the register this access's half w addresses. An
    // if/else chain for the same reason hpc3_rd below is one. The SEEQ's
    // written registers are kept in 0x40-0x5F as {bank, reg}, which is where
    // Main reads the station address.
    function automatic logic [7:0] st_idx(input logic w);
        if (blk == BLK_CTRL)        st_idx = {1'b1, sub, ctrl_reg(w)};
        else if (blk == BLK_DESC)   st_idx = {3'b000, sub, w};
        else if (blk == BLK_GEN)    st_idx = {5'b00100, addr[4:3], w};
        else if (blk == BLK_CFGDMA) st_idx = {5'b00101, addr[11:9]};
        else if (blk == BLK_SEEQ)   st_idx = {3'b010, tx_cmd[6:5], addr[4:3], w};
        else                        st_idx = {4'b0011, addr[11:8]};   // BLK_CFGPIO
    endfunction

    // The store indices the Ethernet window acts on (sgi_hpc3's own numbering:
    // descriptor pairs {sub-block, word}, control groups {1, sub-block, reg}).
    localparam logic [7:0] IX_RX_NBDP  = 8'h15;    // 0x14004
    localparam logic [7:0] IX_TX_NBDP  = 8'h17;    // 0x16004
    localparam logic [7:0] IX_CRBDP    = 8'h18;    // 0x18000
    localparam logic [7:0] IX_CPFXBDP  = 8'h1A;    // 0x1A000
    localparam logic [7:0] IX_PPFXBDP  = 8'h1B;    // 0x1A004
    localparam logic [7:0] IX_RX_CTRL  = 8'hD1;    // 0x15004
    localparam logic [7:0] IX_RX_RESET = 8'hD5;    // 0x15014
    localparam logic [7:0] IX_TX_CTRL  = 8'hD9;    // 0x17004

    // Every store word the guest's writes to the window land in: the four
    // descriptor pairs from 0x14000, the two control groups, the SEEQ.
    function automatic logic enet_ix(input logic [7:0] i);
        enet_ix = (i[7:3] == 5'b00010) || (i[7:4] == 4'hD) || (i[7:5] == 3'b010);
    endfunction

    // Read addresses: the bus's access, or the window's own when it is the
    // one using the store (the TX/RX start and Main's port, below).
    logic  [7:0] ow_ra0, ow_ra1;
    logic        ow_rd;
    assign st_ra0 = ow_rd ? ow_ra0 : st_idx(1'b0);
    assign st_ra1 = ow_rd ? ow_ra1 : st_idx(1'b1);

    // What a stored half reads: the word out of the store, except for the two
    // halves of intstat. 0x1FBB0000 and 0x1FBB000C are generated, not stored;
    // 0x1FBB0004 and 0x1FBB0008 are storage. The store still holds a word for
    // the generated pair and a write still lands in it - nothing reads it, and
    // keeping the write unconditional keeps the write port's address one
    // function of the address.
    //
    // The Ethernet's live bits are generated the same way. Each CTRL reads
    // its channel's ACTIVE at bit 9 and the SEEQ's status in its low byte (RX
    // keeps its own bit 6, which HPC3 sets); RESET reads the interrupt at bit
    // 1. A SEEQ register reads as the 80C03 answers it: regs 0-4 (collision
    // counters, which reg 0 being 0 identifies an 80C03 by) 0, reg 5 NO_SQE
    // and the carrier, 6 and 7 the status bytes.
    function automatic logic [31:0] st_rd(input logic w, input logic [31:0] q);
        logic [7:0] ix;
        ix = st_idx(w);
        if (blk == BLK_GEN)
            st_rd = ({addr[4:3], w} == 3'd0) ? {27'h0, intstat[4:0]}
                  : ({addr[4:3], w} == 3'd3) ? {22'h0, intstat[9:5], 5'h0}
                  :                            q;
        else if (blk == BLK_SEEQ)
            st_rd = ({addr[4:3], w} == 3'd5) ? {30'h0, e_nocarr, 1'b1}
                  : ({addr[4:3], w} == 3'd6) ? {24'h0, rx_stat}
                  : ({addr[4:3], w} == 3'd7) ? {24'h0, tx_stat}
                  :                            32'h0;
        else if (ix == IX_RX_CTRL)  st_rd = {q[31:10], rx_act, q[8], rx_stat[7], q[6], rx_stat[5:0]};
        else if (ix == IX_TX_CTRL)  st_rd = {q[31:10], tx_act, q[8], tx_stat};
        else if (ix == IX_RX_RESET) st_rd = {q[31:2], enet_irq, q[0]};
        else st_rd = q;
    endfunction

    function automatic logic [31:0] hpc3_rd(input logic w);
        // Only the blocks that are not in the store reach this: SCSI channel
        // 0's registers, HAL2's revision, and everything else as zero.
        if (pbus_blk && (blk == BLK_DESC))
            hpc3_rd = w ? pb_dp : pb_bp;
        else if (pbus_blk)
            // ctrl is the first word of the control group; the rest of the
            // group reads zero, as IRIS's PbusDmaOps answers it.
            hpc3_rd = ({addr[4:3], w} == 3'd0) ? pb_ctrl : 32'h0;
        else if ((blk == BLK_DESC) || (blk == BLK_CTRL))
            hpc3_rd = w ? scsi0_rd1 : scsi0_rd0;
        // HAL2 ANSWERS ITS REVISION REGISTER AND NOTHING ELSE, and that
        // is enough to be listed. There is no audio path behind this and
        // there is not meant to be yet: `hinv` prints the audio line out
        // of HAL2_REV, not out of anything that makes a sound.
        //
        //   0x4010, the value IRIS returns (src/hal2.rs). The PROM's node
        //   printer at 0xBFC41664 splits it as
        //     (v >> 12) & 7  .  (v >> 4) & 0xF  .  v & 0xF
        //   so 0x4010 is revision 4.1.0, and the "A2" beside it is a
        //   hardcoded string at 0xBFC54B58 rather than anything this chip
        //   reports. That is the whole of
        //     Audio: Iris Audio Processor: version A2 revision 4.1.0
        //
        // BIT 15 IS THE SWITCH, AND IT IS SET AGAIN (hal2.sv REV_VALUE,
        // 2026-09-02): with it clear IRIX loads the kdsp_a2 audio driver,
        // which wedges the kernel in an endless bzero the first time
        // anything plays a sound (docs/design/scsi-fit-and-framebuffer-layout.md). Set, it means "no audio
        // present", and both the PROM and the IRIX driver skip the audio
        // path entirely - which is what this returned before, deliberately,
        // as IRIS's hal2_absent_read does. Clearing it commits to answering the
        // init sequence at 0xBFC00BD0, which writes IAR/IDR and then spins
        // on ISR bit 0 three times. Every register other than REV reads 0,
        // so busy is always clear and each spin exits on its first pass;
        // the init does not read indirect data back, so discarding the
        // writes costs nothing. **If that ever stops being true this hangs
        // the boot rather than skipping audio**, which is the risk bit 15
        // was buying off.
        //
        // The byte offset of the addressed register is addr with bit 2
        // replaced by w, so its 0x10-granular index is addr[7:4] whichever
        // half is being read.
        else if (blk == BLK_HAL2)
            hpc3_rd = {16'h0, w ? hal2_rd1 : hal2_rd0};
        else
            hpc3_rd = 32'h0000_0000;
    endfunction

    // ---- write data ------------------------------------------------------
    // be[7-i] guards the byte at addr+i: bytes 0..3 are the w=0 register and
    // bytes 4..7 the w=1 one. Partial writes merge against the current value.
    // The function's result goes into a variable before it is indexed, because
    // Quartus 17.0 will not bit-select a function call - `f(x)[7:0]` is a
    // syntax error there, reported as "near text '['; expecting ';'". Verilator
    // accepts it, which is how it got written this way.
    logic [31:0] rd_cur;
    always_comb begin
        wr_en[0] = sel && we && (|be[7:4]);
        wr_en[1] = sel && we && (|be[3:0]);
        rd_cur   = 32'h0;
        for (int w = 0; w < 2; w++) begin
            rd_cur = hpc3_rd(w[0]);
            for (int b = 0; b < 4; b++)
                wval[w][24 - 8*b +: 8] =
                    be[7 - 4*w - b] ? wdata[56 - 32*w - 8*b +: 8]
                                    : rd_cur[24 - 8*b +: 8];
        end
    end

    // The same two things for a stored access, a clock later: what the halves
    // read, and what a write leaves behind once the bytes it does not carry
    // are merged against that. `sel` is long gone by then - the bus holds the
    // address, the write enables and the data until the acknowledge - so these
    // are the enables without it.
    logic [31:0] st_rdv [0:1];
    logic [31:0] st_wv  [0:1];
    wire         acc_wr0 = we && (|be[7:4]);
    wire         acc_wr1 = we && (|be[3:0]);
    always_comb begin
        st_rdv[0] = st_rd(1'b0, st_q0);
        st_rdv[1] = st_rd(1'b1, st_q1);
        for (int w = 0; w < 2; w++)
            for (int b = 0; b < 4; b++)
                st_wv[w][24 - 8*b +: 8] =
                    be[7 - 4*w - b] ? wdata[56 - 32*w - 8*b +: 8]
                                    : st_rdv[w][24 - 8*b +: 8];
    end

    // ---- HAL2 -------------------------------------------------------------
    // The audio processor's register file. It used to be a constant here -
    // REV and nothing else - and the PROM's init at 0xBFC00BD0 wrote IAR and
    // IDR into a hole. Those land in real registers now. See rtl/sgi/hal2.sv,
    // and read its header before touching ISR: bit 0 is what that init spins
    // on, and it has to stay clear.
    //
    // A HAL2 register is 16 bytes from the next, so addr[7:4] names one
    // whichever half of the doubleword the CPU addressed - which is also why
    // the read above replicates it into both halves, as the constant did.
    // Writes take whichever half carries byte enables.
    wire        hal2_sel = sel && (blk == BLK_HAL2);
    wire        hal2_we  = hal2_sel && we && (wr_en[0] || wr_en[1]);
    wire [15:0] hal2_wd  = wr_en[0] ? wval[0][15:0] : wval[1][15:0];
    wire [15:0] hal2_rd0, hal2_rd1;

    // HAL2's DMA port into the PBUS engine.
    logic        x_req, x_we, x_two, x_ack;
    logic  [1:0] x_ch, x_ok;
    logic [63:0] x_wdata, x_rdata;
    logic [63:0] hal2_dbg [2];

    hal2 #(.CLK_HZ(AUDIO_CLK_HZ)) u_hal2 (
        .clk     (clk),
        .reset   (reset),
        .present (audio_en),
        .sel     (hal2_sel),
        .we      (hal2_we),
        .win     (addr[11:10]),
        .dsel    (addr[7:3]),
        .wsel    (~wr_en[0]),
        .wdata   (hal2_wd),
        .rdata0  (hal2_rd0),
        .rdata1  (hal2_rd1),
        .x_req   (x_req),
        .x_ch    (x_ch),
        .x_we    (x_we),
        .x_two   (x_two),
        .x_wdata (x_wdata),
        .x_ack   (x_ack),
        .x_ok    (x_ok),
        .x_rdata (x_rdata),
        .audio_l (audio_l),
        .audio_r (audio_r),
        .dbg     (hal2_dbg)
    );
    assign dbg_audio[0] = hal2_dbg[0];
    assign dbg_audio[1] = hal2_dbg[1];

    //------------------------------------------------------------------
    // PBUS DMA channels 0-3
    //------------------------------------------------------------------
    // Their bp, dp and ctrl are the engine's, not the store's. The word a
    // write lands on is the addressed one, as for SCSI channel 0: the PROM
    // and kdsp_a2 both use `sw`.
    wire        pb_word = aoff[2];
    wire  [2:0] pb_creg = {addr[4:3], pb_word};
    wire        pb_wr   = sel && we && pbus_blk && wr_en[pb_word]
                        && ((blk == BLK_DESC) || (pb_creg == 3'd0));
    wire [31:0] pb_bp, pb_dp, pb_ctrl;
    logic [15:0] pb_ndesc;
    logic [31:0] pb_nwords;

    hpc3_pbus_dma u_pbus_dma (
        .clk         (clk),
        .reset       (reset),
        .pio_we      (pb_wr),
        .pio_ch      (sub[1:0]),
        .pio_reg     ((blk == BLK_DESC) ? {1'b0, pb_word} : 2'd2),
        .pio_wdata   (wval[pb_word]),
        .pio_rd_ctrl (sel && !we && pbus_blk && (blk == BLK_CTRL) && (pb_creg == 3'd0)),
        .rd_ch       (sub[1:0]),
        .rd_bp       (pb_bp),
        .rd_dp       (pb_dp),
        .rd_ctrl     (pb_ctrl),
        .x_req       (x_req),
        .x_ch        (x_ch),
        .x_we        (x_we),
        .x_two       (x_two),
        .x_wdata     (x_wdata),
        .x_ack       (x_ack),
        .x_ok        (x_ok),
        .x_rdata     (x_rdata),
        .ch_int      (pbus_int),
        .ch_act      (pbus_act),
        .dma_req     (p_req),
        .dma_we      (p_we),
        .dma_addr    (p_addr),
        .dma_wdata   (p_wdata),
        .dma_be      (p_be),
        .dma_rdata   (dma_rdata),
        .dma_ack     (p_ack),
        .dbg_desc    (pb_ndesc),
        .dbg_words   (pb_nwords)
    );

    assign dbg_audio[2] = {pbus_act, pbus_int, 8'h00, pb_ndesc, pb_nwords};

    //------------------------------------------------------------------
    // The memory port: SCSI channel 0 and the PBUS engine
    //------------------------------------------------------------------
    // Both hold their request until acknowledged, so the grant is decided
    // when the port is idle and then held for that transaction; the answer
    // goes to whoever holds it. Alternating when both ask: SCSI is feeding a
    // bus phase with a target waiting, audio a FIFO with a deadline a whole
    // sample period away, and neither may starve the other. When only SCSI
    // asks, every signal below is exactly the SCSI channel's, as before.
    logic busy_m, own_p, last_p;
    wire  grant_p = busy_m ? own_p : (p_req && (!s_req || !last_p));

    always_ff @(posedge clk) begin
        if (reset) begin
            busy_m <= 1'b0;
            own_p  <= 1'b0;
            last_p <= 1'b0;
        end else if (!busy_m) begin
            if (s_req || p_req) begin
                busy_m <= 1'b1;
                own_p  <= grant_p;
            end
        end else if (dma_ack) begin
            busy_m <= 1'b0;
            last_p <= own_p;
        end
    end

    assign dma_req   = busy_m ? (own_p ? p_req : s_req) : (s_req | p_req);
    assign dma_we    = grant_p ? p_we    : s_we;
    assign dma_addr  = grant_p ? p_addr  : s_addr;
    assign dma_wdata = grant_p ? p_wdata : s_wdata;
    assign dma_be    = grant_p ? p_be    : s_be;
    assign s_ack     = dma_ack && busy_m && !own_p;
    assign p_ack     = dma_ack && busy_m &&  own_p;

    //------------------------------------------------------------------
    // The store's one access at a time
    //------------------------------------------------------------------
    // A stored access takes the clock after `sel` to read both halves out of
    // the memories, and answers at the end of it. A write of ONE half is made
    // in that same clock, from the merge above. A write of BOTH - a 64-bit
    // store covering the register at +0 and the one at +4 - needs the write
    // port twice, so the second half waits one clock more; it is the +4 half
    // that goes second, which is also the one that wins when both halves
    // address the same register. THAT IS NOT A CORNER CASE: cfgdma's stride is
    // 0x200 and cfgpio's 0x100, so a doubleword there covers one register
    // twice, and the flip-flop version's `for` loop left the +4 half's value
    // behind for exactly the same reason.
    //
    // ST_CLR is the reset sweep, 256 clocks of zeros through the write port,
    // in place of the `for` loops this replaces. A stored access that arrives
    // while it runs is remembered in `pend` and served when it is over; the
    // blocks outside the store are answered throughout, as they are in every
    // other state.
    //
    // THE ETHERNET WINDOW uses the same one-access-at-a-time machine, so the
    // store never has two writers:
    //   * A start - a CTRL write with AMASK (bit 10) clear and ACTIVE (bit 9)
    //     set on an idle channel - is followed by what HPC3's first descriptor
    //     fetch does to the pointers: on TX `PPFXBDP <- CPFXBDP; CPFXBDP <-
    //     NBDP` (ST_SH0..ST_SH2), on RX `CRBDP <- NBDP`. IRIX's if_ec2 reads
    //     the TX pair at the top of every transmit with no ACTIVE check, and a
    //     stale pair frees the packet just started; Main is milliseconds away,
    //     so the move is made here before the CPU's write is acknowledged.
    //   * Main's port (ST_EX, ST_EX2): a store word, or a live register. A
    //     store write and a channel stop carry the write count Main read its
    //     snapshot under and are dropped if the guest has written the window
    //     since, so a reset or restart is never overwritten by a decision
    //     made before it. The status bytes, the DMA interrupt and the carrier
    //     are Main's alone and always land.
    typedef enum logic [3:0] { ST_IDLE, ST_ACC, ST_WR1, ST_CLR,
                               ST_SH0, ST_SH1, ST_SH2, ST_EX, ST_EX2 } st_t;
    st_t         ststate;
    logic  [7:0] clr_idx, idx1_r;
    logic [31:0] wv1_r;
    logic        pend;
    logic        sh_tx, sh_rx;             // a start waiting for its pointer move
    logic [31:0] sh_nbdp;
    logic        ex_pend, ex_w;            // Main's request, held until served
    logic  [8:0] ex_ix;
    logic [15:0] ex_sq;
    logic [31:0] ex_wd;
    wire         ex_ok = (ex_sq == e_seq);

    // A start, from this access's halves.
    wire  [7:0] ix0 = st_idx(1'b0), ix1 = st_idx(1'b1);
    function automatic logic starts(input logic [31:0] v, input logic act);
        starts = !v[10] && v[9] && !act;
    endfunction
    wire tx_go = (acc_wr0 && (ix0 == IX_TX_CTRL) && starts(st_wv[0], tx_act))
              || (acc_wr1 && (ix1 == IX_TX_CTRL) && starts(st_wv[1], tx_act));
    wire rx_go = !e_rst
              && ((acc_wr0 && (ix0 == IX_RX_CTRL) && starts(st_wv[0], rx_act))
               || (acc_wr1 && (ix1 == IX_RX_CTRL) && starts(st_wv[1], rx_act)));

    // Main's live registers.
    function automatic logic [31:0] ex_live(input logic [8:0] i);
        if (i == 9'h100)      ex_live = {8'hEC, 3'b000, e_rst, e_loop, enet_irq, tx_act, rx_act, e_seq};
        else if (i == 9'h105) ex_live = {tx_cmd, rx_cmd, tx_stat, rx_stat};
        else                  ex_live = 32'h0;
    endfunction

    always_comb begin
        st_we  = 1'b0;
        st_wa  = 8'h00;
        st_wd  = 32'h0;
        ow_rd  = 1'b0;
        ow_ra0 = 8'h00;
        ow_ra1 = 8'h00;
        if (ststate == ST_CLR) begin
            st_we = 1'b1;
            st_wa = clr_idx;
        end
        else if (ststate == ST_ACC) begin
            if (acc_wr0) begin
                st_we = 1'b1; st_wa = st_idx(1'b0); st_wd = st_wv[0];
            end
            else if (acc_wr1) begin
                st_we = 1'b1; st_wa = st_idx(1'b1); st_wd = st_wv[1];
            end
        end
        else if (ststate == ST_WR1) begin
            st_we = 1'b1; st_wa = idx1_r; st_wd = wv1_r;
        end
        else if (ststate == ST_SH0) begin
            ow_rd  = 1'b1;
            ow_ra0 = sh_tx ? IX_TX_NBDP : IX_RX_NBDP;
            ow_ra1 = IX_CPFXBDP;
        end
        else if (ststate == ST_SH1) begin
            st_we = 1'b1;
            if (sh_tx) begin st_wa = IX_PPFXBDP; st_wd = st_q1; end    // the old CPFXBDP
            else       begin st_wa = IX_CRBDP;   st_wd = st_q0; end    // RX NBDP
        end
        else if (ststate == ST_SH2) begin
            st_we = 1'b1; st_wa = IX_CPFXBDP; st_wd = sh_nbdp;
        end
        else if (ststate == ST_EX) begin
            ow_rd  = 1'b1;
            ow_ra0 = ex_ix[7:0];
            if (ex_w && !ex_ix[8] && ex_ok) begin
                st_we = 1'b1; st_wa = ex_ix[7:0]; st_wd = ex_wd;
            end
        end
    end

    always_ff @(posedge clk) begin
        ack     <= 1'b0;
        ex_done <= 1'b0;
        if (ex_rd || ex_wr) begin
            ex_pend <= 1'b1;
            ex_w    <= ex_wr;
            ex_ix   <= ex_idx;
            ex_sq   <= ex_seq;
            ex_wd   <= ex_wdata;
        end

        if (reset) begin
            ststate  <= ST_CLR;
            clr_idx  <= 8'h00;
            pend     <= 1'b0;
            rdata    <= 64'h0;
            sh_tx    <= 1'b0;
            sh_rx    <= 1'b0;
            ex_pend  <= 1'b0;
            rx_act   <= 1'b0;
            tx_act   <= 1'b0;
            e_rst    <= 1'b0;
            e_loop   <= 1'b0;
            e_dmairq <= 1'b0;
            rx_stat  <= 8'h80;
            tx_stat  <= 8'h80;
            rx_cmd   <= 8'h00;
            tx_cmd   <= 8'h00;
        end else begin
            // The blocks that are not in the store answer in the clock after
            // `sel`, whatever the store is doing - including during the reset
            // sweep. HAL2 takes its write from `hal2_we` and the three
            // write-only PBUS registers accept and discard; nothing reads
            // them back.
            if (sel && claimed && !stored) begin
                rdata <= {hpc3_rd(1'b0), hpc3_rd(1'b1)};
                ack   <= 1'b1;
            end
            if (sel && stored && ((ststate != ST_IDLE) || ex_pend)) pend <= 1'b1;

            case (ststate)
                ST_CLR: begin
                    clr_idx <= clr_idx + 8'd1;
                    if (&clr_idx) ststate <= ST_IDLE;
                end

                ST_IDLE:
                    // Main's request first: it is two clocks, and the bus
                    // waits for its acknowledge however long it takes.
                    if (ex_pend) begin
                        ststate <= ST_EX;
                        ex_pend <= 1'b0;
                    end
                    else if (pend || (sel && stored)) begin
                        ststate <= ST_ACC;
                        pend    <= 1'b0;
                    end

                ST_ACC: begin
                    // Both halves are out of the memories now, and the write
                    // above is taking the first of them.
                    rdata  <= {st_rdv[0], st_rdv[1]};
                    idx1_r <= st_idx(1'b1);
                    wv1_r  <= st_wv[1];

                    // ---- the guest's side of the Ethernet window
                    for (int w = 0; w < 2; w++) begin
                        if (w ? acc_wr1 : acc_wr0) begin
                            if (enet_ix(w ? ix1 : ix0)) e_seq <= e_seq + 16'd1;
                            if (blk == BLK_SEEQ && {addr[4:3], w[0]} == 3'd6) rx_cmd <= st_wv[w][7:0];
                            if (blk == BLK_SEEQ && {addr[4:3], w[0]} == 3'd7) tx_cmd <= st_wv[w][7:0];
                            if ((w ? ix1 : ix0) == IX_RX_CTRL && !st_wv[w][10]) rx_act <= st_wv[w][9];
                            if ((w ? ix1 : ix0) == IX_TX_CTRL && !st_wv[w][10]) tx_act <= st_wv[w][9];
                            if ((w ? ix1 : ix0) == IX_RX_RESET) begin
                                // rising: both channels stop and the SEEQ is
                                // held; falling: it comes out with its
                                // commands clear and both statuses OLD
                                if (st_wv[w][0] && !e_rst) begin
                                    rx_act <= 1'b0;
                                    tx_act <= 1'b0;
                                end
                                if (!st_wv[w][0] && e_rst) begin
                                    rx_cmd   <= 8'h00;
                                    tx_cmd   <= 8'h00;
                                    rx_stat  <= 8'h80;
                                    tx_stat  <= 8'h80;
                                    e_dmairq <= 1'b0;
                                end
                                // CLRINT
                                if (st_wv[w][1]) begin
                                    rx_stat[7] <= 1'b1;
                                    tx_stat[7] <= 1'b1;
                                    e_dmairq   <= 1'b0;
                                end
                                e_rst  <= st_wv[w][0];
                                e_loop <= st_wv[w][2];
                            end
                        end
                    end
                    // Reading a SEEQ status register marks it OLD - the
                    // addressed word only, as for SCSI channel 0's control.
                    if (!we && blk == BLK_SEEQ && {addr[4:3], aoff[2]} == 3'd6) rx_stat[7] <= 1'b1;
                    if (!we && blk == BLK_SEEQ && {addr[4:3], aoff[2]} == 3'd7) tx_stat[7] <= 1'b1;
                    sh_tx <= tx_go;
                    sh_rx <= rx_go;

                    if (acc_wr0 && acc_wr1) ststate <= ST_WR1;
                    else if (tx_go || rx_go) ststate <= ST_SH0;
                    else begin
                        ack     <= 1'b1;
                        ststate <= ST_IDLE;
                    end
                end

                ST_WR1:
                    if (sh_tx || sh_rx) ststate <= ST_SH0;
                    else begin
                        ack     <= 1'b1;
                        ststate <= ST_IDLE;
                    end

                ST_SH0: ststate <= ST_SH1;

                ST_SH1:
                    if (sh_tx) begin
                        sh_nbdp <= st_q0;
                        ststate <= ST_SH2;
                    end else begin
                        sh_rx   <= 1'b0;
                        ack     <= 1'b1;
                        ststate <= ST_IDLE;
                    end

                ST_SH2: begin
                    sh_tx   <= 1'b0;
                    ack     <= 1'b1;
                    ststate <= ST_IDLE;
                end

                ST_EX:
                    if (ex_w) begin
                        if (ex_ix == 9'h101) rx_stat <= ex_wd[7:0];
                        if (ex_ix == 9'h102) tx_stat <= ex_wd[7:0];
                        if (ex_ix == 9'h103 && ex_ok) begin
                            if (ex_wd[0]) rx_act <= 1'b0;
                            if (ex_wd[1]) tx_act <= 1'b0;
                        end
                        if (ex_ix == 9'h104) begin
                            if (ex_wd[0]) e_dmairq <= 1'b1;
                            e_nocarr <= ex_wd[1];
                        end
                        ex_done <= 1'b1;
                        ststate <= ST_IDLE;
                    end
                    else if (ex_ix[8]) begin
                        ex_rdata <= ex_live(ex_ix);
                        ex_done  <= 1'b1;
                        ststate  <= ST_IDLE;
                    end
                    else ststate <= ST_EX2;

                ST_EX2: begin
                    ex_rdata <= st_q0;
                    ex_done  <= 1'b1;
                    ststate  <= ST_IDLE;
                end

                default: ststate <= ST_IDLE;
            endcase
        end
    end

endmodule
