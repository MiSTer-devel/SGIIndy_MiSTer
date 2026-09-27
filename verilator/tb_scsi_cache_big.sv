//============================================================================
//  tb_scsi_cache_big -- the SCSI block cache over a whole disk, where every
//  sector says which LBA and which write it is.  `make -C verilator
//  tb_scsi_cache_big`.
//
//  WHY. tb_scsi_cache's device folds every LBA into 128 sectors per slot
//  (`lba % 128`) and its random test is 200 operations over LBAs 0-99, so a
//  write that lands 128*k sectors from where it was sent, or any mistake in
//  the upper bits of an LBA, reads back as correct there. IRIX's disk is four
//  million sectors, and on 2026-09-27 (build 46, diskcheck) a file IRIX had
//  read correctly - /usr/lib/libX11.so.1, far up the disk - was different on
//  the image after the session: a write landed where nothing sent it. The
//  same file changed the same way in build 41.
//
//  HOW. Every sector's content is a function of (slot, LBA, generation): its
//  first words carry the LBA, the generation and the slot, the rest a hash of
//  all three. So the DEVICE can check every sector written to it: the LBA in
//  the data must be the LBA it is written to (else a STRAY WRITE), the body
//  must match the hash (else TORN), and the generation must never go
//  backwards (else a STALE flush). The engine checks every sector it reads
//  against the generation it last wrote there (or 0). The device is sparse and
//  covers the full 32-bit LBA space of slots 0 and 1; slot 2 is the CD, read
//  only, as sgi_scsi.sv instantiates it (64 sectors a slot, the CD cached with
//  multi-block reads).
//
//    B1  30,000 random operations on all three slots: sequential runs, near
//        and far jumps across the whole disk, revisits of recently written
//        sectors, random device latency, the bypass switched now and then
//    B2  every sector the engine wrote holds its last write on the device
//============================================================================
`timescale 1ns/1ps
module tb_scsi_cache_big;

reg clk = 0, nreset = 0;
always #5 clk = ~clk;

reg  [31:0] e_lba = 0;
reg   [2:0] e_rd = 0, e_wr = 0;
wire  [2:0] e_ack;
wire [12:0] e_buff_addr;
wire [15:0] e_buff_dout;
wire        e_buff_wr;
reg  [15:0] e_buff_din;
wire [31:0] p_lba;
wire  [5:0] p_blk_cnt;
wire  [2:0] p_rd, p_wr;
reg   [2:0] p_ack = 0;
reg  [12:0] p_buff_addr = 0;
reg  [15:0] p_buff_dout = 0;
wire [15:0] p_buff_din;
reg         p_buff_wr = 0;
reg   [2:0] img_mounted = 0;
reg  [31:0] img_blocks = 0;
reg         bypass = 0;
wire [31:0] stat_hits, stat_misses, stat_writes;

scsi_cache #(.SECT0(64), .SECT1(64), .SECT2(64), .PF_DEPTH(8), .CACHE_CD(1), .MB_CD(1)) dut (
    .clk(clk), .nreset(nreset),
    .e_lba(e_lba), .e_rd(e_rd), .e_wr(e_wr), .e_ack(e_ack),
    .e_buff_addr(e_buff_addr), .e_buff_dout(e_buff_dout), .e_buff_din(e_buff_din), .e_buff_wr(e_buff_wr),
    .p_lba(p_lba), .p_blk_cnt(p_blk_cnt), .p_rd(p_rd), .p_wr(p_wr), .p_ack(p_ack),
    .p_buff_addr(p_buff_addr), .p_buff_dout(p_buff_dout), .p_buff_din(p_buff_din), .p_buff_wr(p_buff_wr),
    .img_mounted(img_mounted), .img_blocks(img_blocks), .bypass(bypass),
    .stat_hits(stat_hits), .stat_misses(stat_misses), .stat_writes(stat_writes)
);

// ---- sector content -----------------------------------------------------------
function automatic logic [15:0] sword(input int slot, input int unsigned lba,
                                      input int unsigned gen, input int w);
    logic [31:0] h;
    case (w)
        0: return lba[31:16];
        1: return lba[15:0];
        2: return gen[31:16];
        3: return gen[15:0];
        4: return {8'h5A, 8'(slot)};
        default: begin
            h = lba * 32'd2654435761 ^ gen * 32'd40503 ^ 32'(w) * 32'd9973 ^ 32'(slot) * 32'd7919;
            return h[31:16] ^ h[15:0];
        end
    endcase
endfunction

function automatic longint key(input int slot, input int unsigned lba);
    return {30'd0, 2'(slot), lba};
endfunction

int unsigned dgen [longint];   // what the device holds: generation per sector (absent = 0)
int unsigned mgen [longint];   // what the engine last wrote there

int fails = 0, checks = 0;
int err_stray = 0, err_torn = 0, err_stale = 0, err_read = 0, err_hang = 0;

// ---- engine-side sector buffer (ncr53c96's sbuf port, as in tb_scsi_cache) ----
reg [15:0] esbuf [0:255];
always @(posedge clk) begin
    if (e_buff_wr) esbuf[e_buff_addr[7:0]] <= e_buff_dout;
    e_buff_din <= esbuf[e_buff_addr[7:0]];
end

// ---- the device: sparse, full LBA; protocol as tb_scsi_cache's -----------------
int dev_lat_lo = 20, dev_lat_hi = 1500;
int d_state = 0, d_lat = 0, d_i = 0, d_slot = 0, d_n = 1;
int unsigned d_lba = 0;
int dev_reads = 0, dev_writes = 0;
logic [15:0] wsec [0:255];

always @(posedge clk) begin
    p_buff_wr <= 0;
    case (d_state)
    0: if (p_rd != 0 || p_wr != 0) begin
           d_slot <= (p_rd[0] | p_wr[0]) ? 0 : (p_rd[1] | p_wr[1]) ? 1 : 2;
           d_lba  <= p_lba;
           d_n    <= p_blk_cnt + 1;
           d_lat  <= $urandom_range(dev_lat_lo, dev_lat_hi);
           d_state <= (p_rd != 0) ? 1 : 3;
       end
    1: if (d_lat != 0) d_lat <= d_lat - 1;
       else begin
           // word 0 goes out in the same cycle the ack rises (see tb_scsi_cache)
           p_ack[d_slot] <= 1; d_state <= 2; dev_reads <= dev_reads + 1;
           p_buff_addr <= 13'd0;
           p_buff_dout <= sword(d_slot, d_lba, dgen.exists(key(d_slot, d_lba)) ? dgen[key(d_slot, d_lba)] : 0, 0);
           p_buff_wr   <= 1;
           d_i <= 1;
       end
    2: if (d_i < 256*d_n) begin
           int unsigned l;
           l = d_lba + d_i/256;
           p_buff_addr <= d_i[12:0];
           p_buff_dout <= sword(d_slot, l, dgen.exists(key(d_slot, l)) ? dgen[key(d_slot, l)] : 0, d_i % 256);
           p_buff_wr   <= 1;
           d_i         <= d_i + 1;
       end else begin p_ack[d_slot] <= 0; d_state <= 0; end
    3: if (d_lat != 0) d_lat <= d_lat - 1;
       else begin p_ack[d_slot] <= 1; d_i <= 1; p_buff_addr <= 13'd0; d_state <= 4; dev_writes <= dev_writes + 1; end
    4: if (d_i < 256*d_n*4) begin
           // each address held four cycles, the word sampled on the last
           p_buff_addr <= 13'(d_i/4);
           if (d_i % 4 == 3) begin
               wsec[(d_i/4) % 256] = p_buff_din;
               if ((d_i/4) % 256 == 255) check_written(d_slot, d_lba + (d_i/4)/256);
           end
           d_i <= d_i + 1;
       end else begin p_ack[d_slot] <= 0; d_state <= 0; end
    endcase
end

// A whole sector has arrived at the device for `lba`: is it this sector?
task automatic check_written(input int slot, input int unsigned lba);
    int unsigned hl, hg;
    int bad = 0;
    hl = {wsec[0], wsec[1]};
    hg = {wsec[2], wsec[3]};
    checks++;
    if (hl != lba || wsec[4] != {8'h5A, 8'(slot)}) begin
        err_stray++;
        if (err_stray <= 8)
            $display("  STRAY WRITE: slot %0d lba %0d received the data of slot %0d lba %0d (gen %0d)",
                     slot, lba, wsec[4][7:0], hl, hg);
        return;
    end
    for (int w = 5; w < 256; w++) if (wsec[w] != sword(slot, lba, hg, w)) bad++;
    if (bad) begin
        err_torn++;
        if (err_torn <= 8) $display("  TORN WRITE: slot %0d lba %0d gen %0d, %0d words wrong", slot, lba, hg, bad);
        return;
    end
    if (dgen.exists(key(slot, lba)) && hg < dgen[key(slot, lba)]) begin
        err_stale++;
        if (err_stale <= 8)
            $display("  STALE FLUSH: slot %0d lba %0d went from gen %0d back to %0d", slot, lba, dgen[key(slot, lba)], hg);
    end
    dgen[key(slot, lba)] = hg;
endtask

// ---- the engine ------------------------------------------------------------------
int unsigned gen_ctr = 0;

task automatic ewrite(input int s, input int unsigned lba);
    int g = 0;
    int unsigned gen;
    gen = ++gen_ctr;
    for (int w = 0; w < 256; w++) esbuf[w] = sword(s, lba, gen, w);
    @(negedge clk); e_lba = lba; e_wr = 3'b001 << s;
    while (!e_ack[s] && g < 3000000) begin @(negedge clk); g++; end
    e_wr = 0;
    if (g >= 3000000) begin err_hang++; return; end
    g = 0;
    while (e_ack[s] && g < 3000000) begin @(negedge clk); g++; end
    @(negedge clk);
    mgen[key(s, lba)] = gen;
endtask

task automatic mread(input int s, input int unsigned lba);
    int g = 0, bad = 0;
    int unsigned want;
    @(negedge clk); e_lba = lba; e_rd = 3'b001 << s;
    while (!e_ack[s] && g < 3000000) begin @(negedge clk); g++; end
    e_rd = 0;
    if (g >= 3000000) begin err_hang++; return; end
    g = 0;
    while (e_ack[s] && g < 3000000) begin @(negedge clk); g++; end
    @(negedge clk);
    want = mgen.exists(key(s, lba)) ? mgen[key(s, lba)] : 0;
    for (int w = 0; w < 256; w++) if (esbuf[w] !== sword(s, lba, want, w)) bad++;
    checks++;
    if (bad) begin
        err_read++;
        if (err_read <= 8)
            $display("  READ slot %0d lba %0d: %0d words wrong; got the sector of lba %0d gen %0d, want gen %0d",
                     s, lba, bad, {esbuf[0], esbuf[1]}, {esbuf[2], esbuf[3]}, want);
    end
endtask

task automatic settle();
    int g = 0;
    while ((dut.dirty[0] != 0 || dut.dirty[1] != 0 || dut.dirty[2] != 0 || dut.cst != 0) && g < 8000000) begin
        @(negedge clk); g++;
    end
    if (g >= 8000000) err_hang++;
    repeat (20) @(negedge clk);
endtask

task automatic check(input bit c, input string what);
    checks++;
    if (c) $display("  ok   %s", what);
    else begin fails++; $display("  FAIL %s", what); end
endtask

// ---- the workload ------------------------------------------------------------------
localparam int NOPS = 30000;
localparam int unsigned DISK = 32'd4194304;      // 2 GB of sectors
localparam int unsigned CDSZ = 32'd1048576;      // a 512 MB ISO
int unsigned cur [3];
int unsigned recent [64];
int nrec = 0;

initial begin
    int wmode [3];
    int runleft [3];
    $display("tb_scsi_cache_big: the block cache over a whole disk, every sector self-describing");
    img_blocks = DISK;
    repeat (8) @(negedge clk);
    nreset = 1;
    img_mounted = 3'b111; repeat (2) @(negedge clk); img_mounted = 0;
    repeat (20) @(negedge clk);
    for (int s = 0; s < 3; s++) begin cur[s] = $urandom_range(0, 1000); runleft[s] = 0; wmode[s] = 0; end

    $display("B1 %0d random operations, three slots, device latency %0d-%0d", NOPS, dev_lat_lo, dev_lat_hi);
    for (int n = 0; n < NOPS; n++) begin
        int s, r;
        int unsigned lim;
        s = $urandom_range(0, 9) < 8 ? $urandom_range(0, 1) : 2;     // mostly the disks
        lim = (s == 2) ? CDSZ : DISK;
        if (runleft[s] == 0) begin
            r = $urandom_range(0, 99);
            if (r < 45)      cur[s] = cur[s] + 1;                                   // keep going
            else if (r < 70) cur[s] = cur[s] + $urandom_range(1, 200) - 100;         // near: across the window
            else if (r < 85) cur[s] = $urandom_range(0, lim - 70);                   // far
            else if (nrec > 0 && s != 2) cur[s] = recent[$urandom_range(0, nrec - 1)]; // revisit a write
            else             cur[s] = cur[s] + 64;                                    // exactly a window on
            if (cur[s] >= lim - 64) cur[s] = $urandom_range(0, 1000);
            runleft[s] = $urandom_range(1, 40);
            wmode[s] = (s != 2) && ($urandom_range(0, 99) < 40);
        end
        if (wmode[s]) begin
            ewrite(s, cur[s]);
            recent[nrec < 64 ? nrec : $urandom_range(0, 63)] = cur[s];
            if (nrec < 64) nrec++;
        end else mread(s, cur[s]);
        cur[s] = cur[s] + 1;
        runleft[s]--;
        dev_lat_hi = ($urandom_range(0, 9) == 0) ? 3000 : 1500;
        if ($urandom_range(0, 1999) == 0) begin
            bypass = !bypass;
            $display("    op %0d: bypass %0d", n, bypass);
        end
        if (err_hang) break;
        if (n % 5000 == 4999)
            $display("    %0d ops: device reads %0d writes %0d, errors stray %0d torn %0d stale %0d read %0d",
                     n + 1, dev_reads, dev_writes, err_stray, err_torn, err_stale, err_read);
    end
    bypass = 0;
    settle();
    check(err_hang == 0,  $sformatf("no transaction hung (%0d)", err_hang));
    check(err_stray == 0, $sformatf("no sector written to an LBA that is not its own (%0d)", err_stray));
    check(err_torn == 0,  $sformatf("no sector written torn (%0d)", err_torn));
    check(err_stale == 0, $sformatf("no flush went back a generation (%0d)", err_stale));
    check(err_read == 0,  $sformatf("every sector read was the last one written there (%0d wrong)", err_read));

    $display("B2 the device holds every sector's last write");
    begin
        int lost = 0, total = 0;
        foreach (mgen[k]) begin
            total++;
            if (!dgen.exists(k) || dgen[k] != mgen[k]) begin
                lost++;
                if (lost <= 8) $display("    slot %0d lba %0d: device gen %0d, engine wrote gen %0d",
                                        k[33:32], k[31:0], dgen.exists(k) ? dgen[k] : 0, mgen[k]);
            end
        end
        check(lost == 0, $sformatf("%0d sectors written, %0d not on the device", total, lost));
    end
    $display("    device reads %0d, writes %0d; cache hits %0d misses %0d writes %0d",
             dev_reads, dev_writes, stat_hits, stat_misses, stat_writes);
    $display("tb_scsi_cache_big: %0d checks, %0d failed", checks, fails);
    if (fails == 0) $display("SCSICACHEBIG: PASS");
    else $display("SCSICACHEBIG: FAIL");
    $finish;
end

endmodule
