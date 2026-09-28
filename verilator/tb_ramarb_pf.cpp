//============================================================================
//  tb_ramarb_pf - ram_arb's prefetch buffers against a slow memory: is every
//  word the CPU is given the word memory holds?
//
//  WHY. The instruction and data prefetch buffers (builds 46, 47) answer line
//  fills out of copies taken earlier, and stay coherent only by snooping the
//  writes this module issues. tb_ramarb.cpp never makes a line fill, and the
//  whole-machine simulation answers memory in one clock, so nothing checked
//  that snoop against a memory as slow as DDR3 - while IRIX 6.x installs, which
//  load code by DMA and then run it, died with init taking SIGSEGV.
//
//  THE MODEL. Memory answers a read's first word LAT clocks (+ jitter) after
//  the request and one word a clock after that, in order, like ddr3_mux; a
//  write lands in memory when it is issued and is acknowledged LAT clocks
//  later. The CPU is one master with one transaction at a time and a
//  one-clock request pulse, its payload held to the last acknowledgement
//  (r4300_bus); the DMA engine holds its request until acknowledged. Both work
//  a window of a few lines, so the buffers hit, get written, and refill.
//
//  THE CHECK. A CPU read may legitimately see a write that lands while it is
//  outstanding, or not: each word is accepted if it is memory's value when
//  the request was made or any value written to that word since.
//
//    make -C verilator ramarbpftest
//    LAT=20 CYCLES=2000000 SEED=7 IPF=1 DPF=1 DMA=30 ./obj_dir_ramarbpf/Vram_arb
//============================================================================
#include "Vram_arb.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <map>
#include <random>
#include <set>
#include <vector>

static int envi(const char *n, int d) { const char *v = getenv(n); return v ? atoi(v) : d; }

static Vram_arb *dut;
static std::mt19937 rng;
static uint64_t now = 0;
static int LAT, JIT, DMA_PCT, LINES;

// ---- memory: 64-bit words by word index --------------------------------------
static std::map<uint32_t, uint64_t> mem;
static uint64_t rd(uint32_t w) { auto it = mem.find(w); return it == mem.end() ? (0xA5A5000000000000ull | w) : it->second; }
static void wr(uint32_t w, uint64_t v, uint8_t be)
{
    uint64_t o = rd(w), m = 0;
    for (int b = 0; b < 8; b++) if ((be >> b) & 1) m |= 0xFFull << (8 * b);
    mem[w] = (o & ~m) | (v & m);
}

// Every value a word has held since a given moment, for the check.
struct WordHist { uint32_t w; std::vector<uint64_t> ok; };

// ---- the port model -----------------------------------------------------------
struct Beat { uint64_t at; uint64_t data; bool last; };
static std::deque<Beat> resp;          // in order
static uint64_t port_free_at = 0;      // the next response may not start before this

// ---- the CPU ------------------------------------------------------------------
struct CpuTx {
    bool active = false, we = false, ifill = false, dfill = false;
    uint32_t addr = 0; int burst = 1; uint64_t wdata = 0; uint8_t be = 0xFF;
    uint64_t w3[3] = {0, 0, 0};
    int got = 0;
    std::vector<WordHist> hist;        // reads: per word, the acceptable values
    uint64_t start = 0;
};
static CpuTx cpu;
static uint32_t last_iline = 0, last_dline = 0;

// ---- the DMA engine -----------------------------------------------------------
struct DmaTx { bool active = false, we = false; uint32_t addr = 0; uint64_t wdata = 0; uint8_t be = 0xFF; WordHist hist; };
static DmaTx dma;

static uint64_t n_cpu = 0, n_ifill = 0, n_dfill = 0, n_dma = 0, n_dmaw = 0, bad = 0, n_words = 0;
static uint64_t pf_hits = 0, dpf_hits = 0;

// A write anywhere: every outstanding read of that word may now see it.
static void note_write(uint32_t w)
{
    uint64_t v = rd(w);
    if (cpu.active && !cpu.we)
        for (auto &h : cpu.hist) if (h.w == w) h.ok.push_back(v);
    if (dma.active && !dma.we && dma.hist.w == w) dma.hist.ok.push_back(v);
}

static uint32_t pick_line()
{
    return (uint32_t)(0x100 + rng() % LINES);     // RAM offset >> 5
}

static void new_cpu_tx()
{
    cpu = CpuTx();
    cpu.active = true;
    cpu.start = now;
    int r = rng() % 100;
    uint32_t line;
    if (r < 35) {                      // instruction fill, mostly sequential
        line = (rng() % 3) ? last_iline + 1 : pick_line();
        if (line >= 0x100 + LINES) line = pick_line();
        last_iline = line;
        cpu.ifill = true; cpu.burst = 4; n_ifill++;
    } else if (r < 60) {               // data fill, often a stream
        line = (rng() % 2) ? last_dline + 1 : pick_line();
        if (line >= 0x100 + LINES) line = pick_line();
        last_dline = line;
        cpu.dfill = true; cpu.burst = 4; n_dfill++;
    } else if (r < 68) {               // uncached word read
        line = pick_line(); cpu.burst = 1;
    } else if (r < 90) {               // a store (one word)
        line = pick_line(); cpu.we = true; cpu.burst = 1;
    } else {                           // a dirty line written back (build 38)
        line = pick_line(); cpu.we = true; cpu.burst = 4;
    }
    int word = (cpu.burst == 1) ? (int)(rng() % 4) : 0;
    cpu.addr = (line << 5) | (word << 3);
    cpu.wdata = ((uint64_t)rng() << 32) | rng();
    cpu.be = cpu.we && cpu.burst == 1 ? (uint8_t)(rng() | 1) : 0xFF;
    for (auto &x : cpu.w3) x = ((uint64_t)rng() << 32) | rng();
    if (!cpu.we)
        for (int i = 0; i < cpu.burst; i++) {
            uint32_t w = (cpu.addr >> 3) + i;
            cpu.hist.push_back({w, {rd(w)}});
        }
    n_cpu++;
}

static void new_dma_tx()
{
    dma = DmaTx();
    dma.active = true;
    dma.we = (rng() % 100) < 70;
    dma.addr = (pick_line() << 5) | ((rng() % 4) << 3);
    dma.wdata = ((uint64_t)rng() << 32) | rng();
    dma.be = 0xFF;
    uint32_t w = dma.addr >> 3;
    dma.hist = {w, {rd(w)}};
    n_dma++;
}

static int cpu_pulse = 0;
static int cpu_gap = 0;

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    LAT = envi("LAT", 20); JIT = envi("JIT", 6); DMA_PCT = envi("DMA", 30);
    LINES = envi("LINES", 24);
    const uint64_t CYCLES = (uint64_t)envi("CYCLES", 2000000);
    rng.seed(envi("SEED", 1));
    dut = new Vram_arb;
    dut->pf_enable = envi("IPF", 1); dut->dpf_enable = envi("DPF", 1);
    dut->reset = 1; dut->clk = 0;
    for (int i = 0; i < 8; i++) { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }
    dut->reset = 0;

    for (; now < CYCLES && bad < 20; now++) {
        // ---- drive the masters for this clock
        if (!cpu.active && cpu_gap-- <= 0) { new_cpu_tx(); cpu_pulse = 1; cpu_gap = rng() % 4; }
        dut->cpu_req   = cpu_pulse;
        dut->cpu_we    = cpu.we; dut->cpu_addr = cpu.addr; dut->cpu_wdata = cpu.wdata;
        dut->cpu_be    = cpu.be; dut->cpu_burst = cpu.burst;
        dut->cpu_ifill = cpu.ifill; dut->cpu_dfill = cpu.dfill;
        for (int i = 0; i < 3; i++) {
            dut->cpu_wdata3[2 * i]     = (uint32_t)cpu.w3[i];
            dut->cpu_wdata3[2 * i + 1] = (uint32_t)(cpu.w3[i] >> 32);
        }
        if (!dma.active && (int)(rng() % 100) < DMA_PCT) new_dma_tx();
        dut->dma_req = dma.active; dut->dma_we = dma.we; dut->dma_addr = dma.addr;
        dut->dma_wdata = dma.wdata; dut->dma_be = dma.be;

        // ---- the port's answer for this clock
        dut->ram_ack = 0; dut->ram_last = 0; dut->ram_rdata = 0xDEADBEEFDEADBEEFull;
        if (!resp.empty() && resp.front().at <= now) {
            dut->ram_ack = 1; dut->ram_last = resp.front().last; dut->ram_rdata = resp.front().data;
            resp.pop_front();
        }
        dut->eval();

        // ---- sample what the DUT presents this clock (before the edge)
        bool req = dut->ram_req, we = dut->ram_we;
        uint32_t a = dut->ram_addr; int burst = dut->ram_burst ? dut->ram_burst : 1;
        uint64_t wd = dut->ram_wdata; uint8_t be = dut->ram_be;
        uint64_t w3[3];
        for (int i = 0; i < 3; i++) w3[i] = ((uint64_t)dut->ram_wdata3[2 * i + 1] << 32) | dut->ram_wdata3[2 * i];
        bool c_ack = dut->cpu_ack, c_last = dut->cpu_last; uint64_t c_data = dut->cpu_rdata;
        bool d_ack = dut->dma_ack;
        pf_hits += dut->dbg_pf_hit; dpf_hits += dut->dbg_dpf_hit;

        dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval();
        cpu_pulse = 0;

        // ---- the port takes the request: a write lands now, a read is queued
        if (req) {
            uint64_t t0 = std::max(now + LAT + (JIT ? rng() % JIT : 0), port_free_at);
            if (we) {
                wr(a >> 3, wd, be); note_write(a >> 3);
                if (burst == 4)
                    for (int i = 0; i < 3; i++) { wr((a >> 3) + 1 + i, w3[i], 0xFF); note_write((a >> 3) + 1 + i); }
                resp.push_back({t0, 0, true});
                port_free_at = t0 + 1;
            } else {
                for (int i = 0; i < burst; i++)
                    resp.push_back({t0 + i, rd((a >> 3) + i), i == burst - 1});
                port_free_at = t0 + burst;
            }
        }

        // ---- check what the CPU was given
        if (c_ack) {
            if (!cpu.active) { printf("FAILED cycle %llu: cpu_ack with no CPU transaction\n", (unsigned long long)now); bad++; continue; }
            if (!cpu.we) {
                if (cpu.got >= (int)cpu.hist.size()) { printf("FAILED cycle %llu: too many words\n", (unsigned long long)now); bad++; }
                else {
                    auto &h = cpu.hist[cpu.got];
                    bool ok = false;
                    for (auto v : h.ok) if (v == c_data) ok = true;
                    n_words++;
                    if (!ok) {
                        bad++;
                        printf("FAILED cycle %llu: CPU %s of line %05x word %d got %016llx; memory had %016llx at the request (cycle %llu) and %zu later value(s)\n",
                               (unsigned long long)now, cpu.ifill ? "I-fill" : cpu.dfill ? "D-fill" : "read",
                               cpu.addr >> 5, cpu.got, (unsigned long long)c_data,
                               (unsigned long long)h.ok[0], (unsigned long long)cpu.start, h.ok.size() - 1);
                    }
                }
            }
            cpu.got++;
            bool done = cpu.we ? true : (cpu.got == cpu.burst);
            if (c_last != done) { printf("FAILED cycle %llu: cpu_last=%d after %d of %d words\n", (unsigned long long)now, c_last, cpu.got, cpu.burst); bad++; }
            if (done) cpu.active = false;
        }
        if (d_ack) {
            if (!dma.active) { printf("FAILED cycle %llu: dma_ack with no DMA transaction\n", (unsigned long long)now); bad++; }
            else {
                if (dma.we) n_dmaw++;
                dma.active = false;
            }
        }
        if (cpu.active && now - cpu.start > 5000) { printf("FAILED cycle %llu: CPU transaction stuck\n", (unsigned long long)now); bad++; cpu.active = false; }
    }

    printf("LAT=%d JIT=%d DMA=%d%% LINES=%d IPF=%d DPF=%d: %llu cycles, %llu CPU transactions (%llu I-fills, %llu D-fills), %llu words checked, %llu DMA (%llu writes)\n",
           LAT, JIT, DMA_PCT, LINES, envi("IPF", 1), envi("DPF", 1), (unsigned long long)now,
           (unsigned long long)n_cpu, (unsigned long long)n_ifill, (unsigned long long)n_dfill,
           (unsigned long long)n_words, (unsigned long long)n_dma, (unsigned long long)n_dmaw);
    printf("fills answered from the buffers: %llu instruction, %llu data\n",
           (unsigned long long)pf_hits, (unsigned long long)dpf_hits);
    printf(bad ? "RAMARBPF: FAIL (%llu)\n" : "RAMARBPF: PASS\n", (unsigned long long)bad);
    delete dut;
    return bad ? 1 : 0;
}
