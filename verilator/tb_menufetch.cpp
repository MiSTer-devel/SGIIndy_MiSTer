//============================================================================
//  tb_menufetch - the display's two plane-set fetches through the REAL
//  ddr3_mux, with something posted in the auxiliary planes.
//
//  WHY. Build 48 on the board: Toolchest > System drew its menu into the
//  popup planes (fbgrab32.py found it whole, rows 116..439, columns
//  115..320) and the screen showed ONE ROW of it. The display fetched the
//  popup planes through the auxiliary line cache, so every line under the
//  menu needed both plane sets - 2 x 672 words - and ddr3_mux serves the
//  display in FBR_SUB = 4-word reads, FBR_AHEAD = 2 in flight: about 0.46
//  words a clock at the bridge's ~10-clock latency, against the ~0.51 the
//  menu needed. The auxiliary cache (second in fb_fetch_arb) fell behind at
//  the menu's first line and then fetched every remaining line of the frame
//  after the display had passed it; a miss is zeros, and zero popup bits are
//  transparent. tb_fetcharb could not see it: its bridge model streams whole
//  bursts, and its auxiliary lines are one in eight, never a run of 324.
//
//  What changed (build 49):
//    * the display takes the popup bits from the drawing planes (the
//      window-ID copy, newport.sv), so a popup menu marks no line and costs
//      no auxiliary fetch - which is how a real Newport's VRAM hands every
//      plane of a pixel over in one serial transfer;
//    * the overlay still needs the auxiliary planes, so while that cache is
//      fetching, ddr3_mux lets the display have FBR_AHEAD_DEEP sub-bursts in
//      flight (`fbr_deep`), and a cache about to run dry (`urgent`) goes
//      ahead of main memory with the same allowance, and ahead of the other
//      cache in fb_fetch_arb;
//    * a line cache that falls behind skips to the line after the display's
//      (fb_linecache.sv), so a shortfall costs lines, not the rest of the frame.
//
//  THE GATE (no arguments): shipping parameters, LAT=10 -
//    1  the desktop, a CPU read every 60 clocks: no misses at all
//    2  the board's popup menu: popup bits in the auxiliary planes, no line
//       marked - no misses, no more DDR3 traffic and no slower CPU reads
//       than the desktop
//    3  an overlay the size of that menu, its lines marked: no misses, and
//       none either behind a CPU reading every 20 clocks
//    4  a 64x64 overlay (a drag icon) behind a CPU reading every 4 clocks:
//       no misses
//    5  the desktop behind 12-word CPU reads every 20 clocks: no drawing-
//       plane misses (build 48 lost ~850,000 pixels a frame here)
//    6  an overlay behind that load: no misses from its third line below on -
//       the fill skipped ahead and caught up
//
//  EXPLORING: CASE=1|2|3 runs one picture and prints it, with knobs
//    LAT=10 JIT=3 BUSY=10     bridge: latency to first word, + 0..JIT-1, % busy
//    CPU_EVERY=60 CPU_BURST=4 a CPU read of CPU_BURST words every N clocks (0 off)
//    MY0 MY1 MX0 MX1          the rectangle (default the board's menu)
//  Build with -GFBR_SUB=/-GFBR_AHEAD= to try other splits (see the Makefile).
//
//    make -C verilator menufetchtest
//============================================================================
#include "Vtb_menufetch.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <random>
#include <vector>

static const int H_VIS = 1318, H_TOTAL = 1680;
static const int V_VIS = 1024, V_TOTAL = 1065;
static const int V_SYNC_AT = 1030;
static const int STRIDE = 2048, BPP = 4;
static const uint32_t AUX_OFF = 0x00800000u;
static const uint32_t FB_BASE = 0x04000000u;
static const int FRAMES = 4;

static int envi(const char *n, int d) { const char *v = getenv(n); return v ? atoi(v) : d; }

struct Params {
    int kind;                 // 1 desktop, 2 popup menu, 3 overlay
    int lat, jit, busy, cpu_every, cpu_burst;
    int y0, y1, x0, x1;
};
struct Result {
    uint64_t rmiss[FRAMES] = {0}, amiss[FRAMES] = {0};
    std::vector<int> line_amiss[FRAMES];
    double words_per_clock = 0, cpu_lat = 0;
    uint64_t cpu_reads = 0;
};

static Vtb_menufetch *dut;
static std::mt19937 rng;
static uint64_t now;
struct Word { uint64_t ready; uint64_t data; };
static std::deque<Word> rpipe;
static uint64_t last_ready, words_read;
static const Params *P;

static uint64_t content(uint32_t word_addr)
{
    uint32_t byte = word_addr << 3;
    if (byte < FB_BASE || byte >= FB_BASE + 0x01000000u) return 0x1111111111111111ull;
    uint32_t off = byte - FB_BASE;
    if (off < AUX_OFF) return 0x00C0C0C000C0C0C0ull;           // drawing planes
    off -= AUX_OFF;
    int y = off / (STRIDE * BPP), x = (off % (STRIDE * BPP)) / BPP;
    // Popup value 1 in both buffers (0x44), or overlay 0x5A in both (0x5A5A00).
    uint64_t v = P->kind == 2 ? 0x44 : P->kind == 3 ? 0x5A5A00 : 0;
    uint64_t w = 0;
    if (y >= P->y0 && y <= P->y1) {
        if (x     >= P->x0 && x     <= P->x1) w |= v;
        if (x + 1 >= P->x0 && x + 1 <= P->x1) w |= v << 32;
    }
    return w;
}

// Present BUSY / DOUT for this clock, settle, capture the command, clock.
static void tick()
{
    bool busy = (int)(rng() % 100) < P->busy;
    dut->DDRAM_BUSY = busy;
    dut->DDRAM_DOUT_READY = 0;
    dut->DDRAM_DOUT = 0xDEADBEEFDEADBEEFull;
    if (!rpipe.empty() && rpipe.front().ready <= now) {
        dut->DDRAM_DOUT = rpipe.front().data;
        dut->DDRAM_DOUT_READY = 1;
        rpipe.pop_front();
    }
    dut->eval();
    bool rd = dut->DDRAM_RD;
    uint32_t a = dut->DDRAM_ADDR & 0x1FFFFFF;
    int n = dut->DDRAM_BURSTCNT ? dut->DDRAM_BURSTCNT : 1;
    dut->clk = 1; dut->eval();
    dut->clk = 0; dut->eval();
    if (!busy && rd) {
        uint64_t t = now + P->lat + (P->jit ? rng() % P->jit : 0);
        if (t <= last_ready) t = last_ready + 1;
        for (int i = 0; i < n; i++) rpipe.push_back({t + i, content(a + i)});
        last_ready = t + n - 1;
        words_read += n;
    }
    now++;
}

// The CPU: one read at a time, held until its last word.
static int cpu_wait;
static bool cpu_on;
static uint64_t cpu_reads, cpu_lat_sum, cpu_t0;
static void cpu_step()
{
    if (!P->cpu_every) { dut->ram_req = 0; return; }
    if (cpu_on) {
        if (dut->ram_ack && dut->ram_last) {
            cpu_on = false; dut->ram_req = 0;
            cpu_reads++; cpu_lat_sum += now - cpu_t0;
            cpu_wait = P->cpu_every;
        }
    } else if (cpu_wait > 0) {
        cpu_wait--;
    } else {
        cpu_on = true; dut->ram_req = 1; dut->ram_we = 0;
        dut->ram_addr = (rng() % (32u << 20)) & ~31u;
        dut->ram_burst = P->cpu_burst;
        cpu_t0 = now;
    }
}

static Result run(const Params &p)
{
    P = &p;
    rng.seed(1234);
    now = 0; last_ready = 0; words_read = 0; rpipe.clear();
    cpu_wait = 0; cpu_on = false; cpu_reads = 0; cpu_lat_sum = 0;
    dut = new Vtb_menufetch;
    dut->reset = 1; dut->clk = 0; dut->px_req = 0; dut->vs = 0; dut->mark = 0;
    dut->ram_req = 0; dut->ram_we = 0; dut->ram_addr = 0; dut->ram_burst = 4;
    for (int i = 0; i < 8; i++) tick();
    dut->reset = 0; tick();

    // The rasteriser marks a line whose OVERLAY bytes it writes
    // (np_rex3's aux_mark); popup writes mark nothing since build 49.
    if (p.kind == 3)
        for (int y = p.y0; y <= p.y1; y++) { dut->mark = 1; dut->mark_line = y; tick(); }
    dut->mark = 0;
    dut->vs = 1; for (int i = 0; i < 3; i++) tick();
    dut->vs = 0;
    for (int i = 0; i < (V_TOTAL - V_VIS) * H_TOTAL; i++) { cpu_step(); tick(); }

    Result r;
    for (auto &v : r.line_amiss) v.assign(V_VIS, 0);
    struct Req { int y; int f; };
    std::deque<Req> inflight;
    uint64_t w0 = 0, c0 = 0, l0 = 0;
    for (int f = 0; f < FRAMES; f++) {
        if (f == 1) { w0 = words_read; c0 = cpu_reads; l0 = cpu_lat_sum; }
        for (int y = 0; y < V_TOTAL; y++) {
            dut->vs = (y == V_SYNC_AT || y == V_SYNC_AT + 1 || y == V_SYNC_AT + 2);
            for (int x = 0; x < H_TOTAL; x++) {
                bool vis = (y < V_VIS) && (x < H_VIS);
                uint32_t a = ((uint32_t)y * STRIDE + x) * BPP;
                dut->px_addr_rgb = vis ? a : ((uint32_t)y * STRIDE) * BPP;
                dut->px_addr_aux = dut->px_addr_rgb + AUX_OFF;
                dut->px_req = vis;
                if (vis) inflight.push_back({y, f});
                cpu_step();
                tick();
                dut->px_req = 0;
                if (dut->rgb_ack) {
                    Req q = inflight.front(); inflight.pop_front();
                    if (dut->rgb_miss) r.rmiss[q.f]++;
                    if (dut->aux_miss) { r.amiss[q.f]++; r.line_amiss[q.f][q.y]++; }
                }
            }
        }
    }
    double clocks = (double)(FRAMES - 1) * V_TOTAL * H_TOTAL;
    r.words_per_clock = (words_read - w0) / clocks;
    r.cpu_reads = cpu_reads - c0;
    r.cpu_lat = r.cpu_reads ? (double)(cpu_lat_sum - l0) / r.cpu_reads : 0.0;
    delete dut;
    return r;
}

static const char *kind_name(int k)
{
    return k == 1 ? "the desktop" : k == 2 ? "a popup menu" : "an overlay";
}

static void print(const Params &p, const Result &r)
{
    printf("%s, rows %d..%d columns %d..%d; LAT=%d JIT=%d BUSY=%d CPU_EVERY=%d CPU_BURST=%d\n",
           kind_name(p.kind), p.y0, p.y1, p.x0, p.x1, p.lat, p.jit, p.busy, p.cpu_every, p.cpu_burst);
    for (int f = 0; f < FRAMES; f++) {
        int in = 0, below = 0;
        for (int y = 0; y < V_VIS; y++) {
            if (!r.line_amiss[f][y]) continue;
            if (y >= p.y0 && y <= p.y1) in++;
            else if (y > p.y1) below++;
        }
        printf("  frame %d: drawing misses %7llu, auxiliary misses %7llu on %3d of its %d lines "
               "and %3d lines below it\n", f, (unsigned long long)r.rmiss[f],
               (unsigned long long)r.amiss[f], in, p.y1 - p.y0 + 1, below);
    }
    printf("  DDR3 %.3f words a clock; %llu CPU reads, %.1f clocks each (frames 1-3)\n",
           r.words_per_clock, (unsigned long long)r.cpu_reads, r.cpu_lat);
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    auto params = [](int kind) {
        Params p;
        p.kind = kind;
        p.lat = envi("LAT", 10); p.jit = envi("JIT", 3); p.busy = envi("BUSY", 10);
        p.cpu_every = envi("CPU_EVERY", 60); p.cpu_burst = envi("CPU_BURST", 4);
        p.y0 = envi("MY0", 116); p.y1 = envi("MY1", 439);
        p.x0 = envi("MX0", 115); p.x1 = envi("MX1", 320);
        return p;
    };
    if (getenv("CASE")) {
        Params p = params(envi("CASE", 2));
        print(p, run(p));
        return 0;
    }

    int fail = 0;
    auto check = [&](const char *what, bool ok) {
        printf("  %s %s\n", ok ? "ok     " : "FAILED ", what);
        if (!ok) fail = 1;
    };
    auto no_misses = [](const Result &r, bool aux) {
        for (int f = 1; f < FRAMES; f++)
            if (r.rmiss[f] || (aux && r.amiss[f])) return false;
        return true;
    };

    // A fetch in flight when the overlay ends can still finish after the
    // display has passed the next line; that line's pixels are zero whether
    // missed or not. Two lines of grace, then nothing.
    auto recovered = [](const Params &p, const Result &r) {
        for (int f = 1; f < FRAMES; f++)
            for (int y = p.y1 + 3; y < V_VIS; y++)
                if (r.line_amiss[f][y]) return false;
        return true;
    };

    Params p1 = params(1), p2 = params(2), p3 = params(3);
    Result r1 = run(p1); print(p1, r1);
    check("1 the desktop: no misses after the first frame", no_misses(r1, true));
    Result r2 = run(p2); print(p2, r2);
    check("2 a popup menu: no misses after the first frame", no_misses(r2, true));
    check("2 a popup menu costs no more DDR3 traffic than the desktop",
          r2.words_per_clock <= r1.words_per_clock * 1.01);
    check("2 ...and no slower CPU reads", r2.cpu_lat <= r1.cpu_lat + 0.05);
    Result r3 = run(p3); print(p3, r3);
    check("3 an overlay the size of that menu: no misses", no_misses(r3, true));
    Params p3b = p3; p3b.cpu_every = 20;
    Result r3b = run(p3b); print(p3b, r3b);
    check("3 ...nor behind a CPU reading every 20 clocks", no_misses(r3b, true));
    Params p4 = params(3); p4.y0 = 500; p4.y1 = 563; p4.x0 = 600; p4.x1 = 663; p4.cpu_every = 4;
    Result r4 = run(p4); print(p4, r4);
    check("4 a drag icon behind a CPU reading every 4 clocks: no misses", no_misses(r4, true));
    Params p5 = params(1); p5.cpu_every = 20; p5.cpu_burst = 12;
    Result r5 = run(p5); print(p5, r5);
    check("5 the desktop behind 12-word CPU reads every 20 clocks: no drawing-plane misses",
          no_misses(r5, false));
    Params p6 = params(3); p6.cpu_every = 20; p6.cpu_burst = 12;
    Result r6 = run(p6); print(p6, r6);
    check("6 an overlay behind that load: no auxiliary misses 3+ lines below it (caught up)",
          recovered(p6, r6));

    printf(fail ? "\nMENUFETCH: FAIL\n" : "\nMENUFETCH: PASS\n");
    return fail;
}
