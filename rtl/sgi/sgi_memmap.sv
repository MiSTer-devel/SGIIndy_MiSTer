//============================================================================
//  sgi_memmap - where main memory appears, as MEMCFG0/1 say it does.
//
//  On an IP22/IP24 the DRAM banks are not at a fixed address. The MC compares
//  address bits [29:22] against a per-bank base field and answers only if that
//  bank is marked valid, and the PROM uses that to SIZE the memory: `szmem`
//  maps a bank at high memory, writes a pattern at one offset, and looks for
//  it reappearing at another. Where it reappears is the real SIMM size. A core
//  with RAM hardwired at 0x08000000 fails every one of those probes and the
//  PROM concludes there is no usable memory - which is exactly what this core
//  did before this module existed.
//
//  MEMCFG ENCODING, from the MC spec's section 5.12. Each register holds two
//  banks, high half first:
//
//     [15]    undefined            [14] BNK   two subbanks on the SIMM
//     [13]    VLD  bank installed  [12:8] MSIZE  SIMM size code
//     [7:0]   BASE address bits [29:22]
//
//  MSIZE is "megabytes minus one" per SIMM and there are always four SIMMs to
//  a bank, so the bank spans (MSIZE + 1) * 4 MB. A two-subbank SIMM (the 512Kx36,
//  2Mx36 and 8Mx36 parts) has BNK set and each subbank is placed separately,
//  so the window at BASE is half the bank.
//
//  SUBBANKS ARE NOT MODELLED. This core carries one contiguous block of RAM
//  and presents it as a single-subbank bank - four SIMMs of 1Mx36, 4Mx36 or
//  the like, which is a configuration a real Indy shipped in. The sizes that
//  need BNK set (8, 32 and 128 MB banks) are not offered, so the wrap below is
//  always "wrap at the installed size" and never has to place two subbanks at
//  different addresses. IRIS's memcfg_bank_info carries the general case if it
//  is ever needed.
//
//  READS OUTSIDE A VALID BANK RETURN ZERO, and writes are dropped. That is
//  IRIS's behaviour and the PROM depends on it: the probe at 0xBFC016EC zeroes
//  four words and then requires them to read back zero after writing a pattern
//  somewhere else, so unmapped memory answering 0xFFFFFFFF fails the data test
//  before the size test even starts. The MC spec would instead raise ADDR in
//  CPU_ERROR_STAT ("address does not map to a valid bank of memory"); nothing
//  yet turns that into a bus error, so returning zero is both simpler and what
//  the working emulator does.
//============================================================================

module sgi_memmap #(
    // Installed size of each bank in megabytes, 0 for an empty bank. Must be
    // a multiple of 4 and at most 128, and must be one of the single-subbank
    // sizes - see the note above.
    // No parameters: the size is a runtime input. See bank_mb below.
    parameter int UNUSED_PARAM = 0
)(
    input  logic        clk,
    input  logic [31:0] memcfg0,      // banks 0 (high half) and 1 (low half)
    input  logic [31:0] memcfg1,      // banks 2 and 3

    input  logic [31:0] addr,         // physical address
    output logic        hit,          // inside a valid bank
    input  logic [31:0] mem_mb,       // total megabytes actually fitted
    output logic [31:0] offset        // byte offset into this core's RAM
);

    // RUNTIME, not a parameter. The simulator picks the size on the command
    // line and the RTL has to agree with the memory actually behind it: a core
    // elaborated for 64 MB in front of a 32 MB host buffer advertises memory
    // that is not there, and the PROM's own memory test finds out - "Bank 0
    // memory probe *FAILED* ... No usable memory found". On hardware it is the
    // OSD's Memory setting, latched at reset - not a constant, which is why
    // the layout below is registered.
    //
    // BANKS COME IN 64, 16 AND 4 MB, largest first, and that list is not
    // arbitrary. A bank is four SIMMs, so it spans four times the SIMM size,
    // and the SIMMs that do NOT need BNK - the single-subbank parts - are the
    // 1Mx36, 4Mx36 and 16Mx36, giving 4, 16 and 64 MB banks. The two-subbank
    // parts (512Kx36, 2Mx36, 8Mx36) give 8, 32 and 128 MB banks and are the
    // case the note at the top of this file says is not modelled.
    //
    // So a size is expressible here exactly when it is a sum of 64s, 16s and
    // 4s across at most four banks:
    //
    //     32 MB  = 16 + 16          two banks
    //     48 MB  = 16 + 16 + 16     three banks   (the MiSTer single-SDRAM fit)
    //     64 MB  = 64               one bank
    //    128 MB  = 64 + 64          two banks
    //    256 MB  = 64 x 4           four banks
    //
    // Asking for 32 as a single 32 MB bank is what made `--ram-mb 32` fail
    // before this: it needs BNK, the PROM probed a bank that could not answer,
    // and its own diagnostic said so.
    logic [31:0] bank_mb  [4];
    logic [31:0] bank_off [4];
    logic [31:0] rem_mb   [5];
    logic [31:0] off_by   [5];
    always_comb begin
        rem_mb[0] = mem_mb;
        off_by[0] = 32'd0;
        for (int b = 0; b < 4; b++) begin
            bank_mb[b]  = (rem_mb[b] >= 32'd64) ? 32'd64
                        : (rem_mb[b] >= 32'd16) ? 32'd16
                        : (rem_mb[b] >= 32'd4 ) ? 32'd4
                        :                         32'd0;
            bank_off[b] = off_by[b];
            rem_mb[b+1] = rem_mb[b] - bank_mb[b];
            off_by[b+1] = off_by[b] + (bank_mb[b] << 20);
        end
    end

    // THE BANK LAYOUT IS REGISTERED, because it was the core clock's worst path
    // (build 51). mem_mb is a static OSD setting - it only changes while the
    // machine is held in reset - but the chain above (four 32-bit subtracts and
    // compares) still sat between it and every RAM address: with 128 MB in the
    // list, the fit's 300 worst endpoints all started at the Memory bit and
    // ended in ddr3_mux's address and data registers, -0.9 to -2.7 ns over four
    // seeds. Registered, the path into the offset adder below starts at these
    // few flops, as MEMCFG's base field already does. One clock of latency
    // after a change of size, inside a reset of 65,535 clocks.
    logic        bank_on_q [4];   // the bank is fitted at this size
    logic  [3:0] amask_q   [4];   // its size mask, bits 25:22
    logic  [9:0] off_q     [4];   // its offset into this core's RAM, bits 31:22
    always_ff @(posedge clk) begin
        for (int i = 0; i < 4; i++) begin
            bank_on_q[i] <= (bank_mb[i] != 32'd0);
            amask_q[i]   <= ((bank_mb[i] << 20) - 32'd1) >> 22;
            off_q[i]     <= bank_off[i][31:22];
        end
    end

    logic [15:0] half [4];
    assign half[0] = memcfg0[31:16];
    assign half[1] = memcfg0[15:0];
    assign half[2] = memcfg1[31:16];
    assign half[3] = memcfg1[15:0];

    // Per-bank decode, as plain combinational logic rather than variables
    // declared inside the loop below: this file is compiled by Quartus as well
    // as Verilator, and block-scoped `automatic` declarations are the kind of
    // construct that works everywhere except the one tool you need.
    logic        vld   [4];
    logic [31:0] base  [4];
    logic        bhit  [4];
    logic  [9:0] off_hi [4];

    // EXPLICIT generate/genvar, not `for (genvar b = ...)`. The inline form is
    // SystemVerilog that Verilator takes and Quartus 17.0 does not - it stops
    // parsing at the `for` and reports "expecting endmodule", then cascades
    // into a pile of redeclaration errors that look nothing like the cause.
    genvar b;
    generate
    for (b = 0; b < 4; b++) begin : g_bank
        // (MSIZE + 1) * 4 MB, halved when the SIMM carries two subbanks - in
        // 2 MB units, which is the finest a limit comes in.
        wire [6:0] units = half[b][14] ? ({2'b00, half[b][12:8]} + 7'd1)
                                       : ({2'b00, half[b][12:8]} + 7'd1) << 1;
        assign vld[b]   = half[b][13] && bank_on_q[b];
        assign base[b]  = {2'b00, half[b][7:0], 22'b0};
        // The installed SIMMs wrap within their own size (amask_q above), which
        // is how the PROM's alias probe measures them: configure the bank larger
        // than it is and the pattern written high reappears low.
        // ONLY addr[31:21] TAKES PART IN ANY ARITHMETIC (build 45b). A base is
        // 4 MB aligned and a limit a whole number of 2 MB, so `addr >= base`
        // is a compare of addr[31:22], `addr - base < limit` a subtract and a
        // compare of addr[31:21], and neither can borrow out of the bits below.
        // The 32-bit forms of the same expressions were on the CPU's path into
        // ddr3_mux, the core clock's second-worst family in build 45's fit.
        wire [10:0] d21 = addr[31:21] - {base[b][31:22], 1'b0};
        assign bhit[b]  = vld[b] && (addr[31:22] >= base[b][31:22])
                                 && (d21 < {4'b0, units});
        // The offset the same way: bank_off and base have nothing below bit 22
        // and the mask nothing above bit 25, so bits 21:0 are addr's own and
        // the rest is a four-bit subtract into a ten-bit add.
        wire  [3:0] m4 = (addr[25:22] - base[b][25:22]) & amask_q[b];
        assign off_hi[b] = off_q[b] + {6'b0, m4};
    end
    endgenerate

    always_comb begin
        hit    = 1'b0;
        offset = 32'h0;
        // Lowest-numbered valid bank wins if two overlap. The PROM never
        // programs an overlap; a real MC would answer with whichever bank's
        // comparator matched and is not specified for the ambiguous case.
        for (int b = 3; b >= 0; b--) begin
            if (bhit[b]) begin
                hit    = 1'b1;
                offset = {off_hi[b], addr[21:0]};
            end
        end
    end

endmodule
