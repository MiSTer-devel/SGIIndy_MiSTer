//============================================================================
//  tb_memmap -- sgi_memmap.sv against another version of itself.
//  `make -C verilator tb_memmap MEMMAP_REF=/path/to/sgi_memmap_ref.sv`
//
//  The reference is the same module renamed `sgi_memmap_ref` (a copy of an
//  earlier version, with the one word changed). Every input is driven and
//  `hit` and `offset` must agree exactly, so a rewrite that only reshapes the
//  logic - build 45b took the arithmetic down to addr[31:21] for timing - is
//  checked for equivalence, not for plausibility:
//
//    - memory sizes: every size the OSD offers, plus random ones
//    - MEMCFG halves: what the PROM programs (VLD, MSIZE 0/3/15/31, BNK clear)
//      and random 16-bit values (BNK set, invalid banks, overlaps)
//    - addresses: random, and every bank's base and end, a byte either side
//============================================================================
`timescale 1ns/1ps
module tb_memmap;

logic [31:0] memcfg0, memcfg1, addr, mem_mb;
wire         hit_n, hit_r;
wire  [31:0] off_n, off_r;

sgi_memmap     dut (.memcfg0(memcfg0), .memcfg1(memcfg1), .addr(addr), .hit(hit_n),
                    .mem_mb(mem_mb), .offset(off_n));
sgi_memmap_ref ref_(.memcfg0(memcfg0), .memcfg1(memcfg1), .addr(addr), .hit(hit_r),
                    .mem_mb(mem_mb), .offset(off_r));

int unsigned n = 0, bad = 0;

task automatic cmp();
    #1;
    n++;
    if (hit_n !== hit_r || (hit_r && off_n !== off_r) || (!hit_r && off_n !== off_r)) begin
        bad++;
        if (bad <= 10)
            $display("  MISMATCH cfg %08h %08h mb %0d addr %08h: hit %b/%b off %08h/%08h",
                     memcfg0, memcfg1, mem_mb, addr, hit_n, hit_r, off_n, off_r);
    end
endtask

function automatic logic [15:0] prom_half();
    logic [4:0] ms;
    case ($urandom_range(0, 4))
        0: ms = 5'd0; 1: ms = 5'd3; 2: ms = 5'd15; 3: ms = 5'd31;
        default: ms = 5'($urandom);
    endcase
    return {1'b0, 1'b0, 1'b1, ms, 8'($urandom)};
endfunction

function automatic logic [15:0] any_half();
    return ($urandom_range(0, 1) == 0) ? prom_half() : 16'($urandom);
endfunction

int sizes[] = '{4, 8, 12, 16, 20, 24, 32, 48, 64, 68, 80, 96, 128, 144, 192, 256, 0, 3, 300};

initial begin
    $display("tb_memmap: sgi_memmap against sgi_memmap_ref");
    for (int it = 0; it < 200000; it++) begin
        logic [15:0] h [4];
        for (int b = 0; b < 4; b++) h[b] = any_half();
        memcfg0 = {h[0], h[1]};
        memcfg1 = {h[2], h[3]};
        mem_mb  = ($urandom_range(0, 3) == 0) ? 32'($urandom_range(0, 400))
                                              : 32'(sizes[$urandom_range(0, sizes.size() - 1)]);
        // random addresses, low and high memory weighted
        for (int k = 0; k < 4; k++) begin
            case ($urandom_range(0, 3))
                0: addr = $urandom;
                1: addr = 32'h0800_0000 + $urandom_range(0, 32'h0FFF_FFFF);
                2: addr = 32'h2000_0000 + $urandom_range(0, 32'h0FFF_FFFF);
                default: addr = {2'b00, 8'($urandom), 22'($urandom)};
            endcase
            cmp();
        end
        // every bank's edges
        for (int b = 0; b < 4; b++) begin
            logic [31:0] base, lim;
            base = {2'b00, h[b][7:0], 22'b0};
            lim  = (({27'b0, h[b][12:8]} + 32'd1) << 22) >> (h[b][14] ? 1 : 0);
            for (int d = -2; d <= 2; d++) begin
                addr = base + 32'(d);                   cmp();
                addr = base + lim + 32'(d);             cmp();
                addr = base + (lim >> 1) + 32'(d);      cmp();
                addr = base + 32'h0040_0000 + 32'(d);   cmp();
                addr = base + 32'h0100_0000 + 32'(d);   cmp();
                addr = base + 32'h0400_0000 + 32'(d);   cmp();
            end
        end
    end
    $display("tb_memmap: %0d comparisons, %0d mismatches", n, bad);
    if (bad == 0) $display("MEMMAP: PASS");
    else $display("MEMMAP: FAIL");
    $finish;
end

endmodule
