//============================================================================
//  tb_audio.cpp - the audio path end to end: HPC3's PBUS DMA channels 0-3,
//  HAL2's registers, clocks and ports, and the DAC, through sgi_hpc3's own
//  PIO decode and memory port, against a memory that answers slowly.
//
//  What it checks, each against the contract the guest software was read to
//  need (docs/design/audio.md):
//    T1  HAL2's registers: REV, TSTATUS clear, the indirect file round trips,
//        a 32-bit register read back one half at a time through IAR[1:0] (the
//        way kdsp_a2's hal2_write_codec_regs reads it), the volume registers
//    T2  an IRIX ring: ONE descriptor whose next pointer is itself, codec A
//        stereo at 48 kHz - every sample comes out in order and scaled, bp
//        advances at the sample rate, the ring wraps
//    T3  the PROM's tune: an EOX chain split into three buffers, codec A mono
//        on channel 1 and AES TX on channel 2 at 44.1 kHz, both channels
//        running the same chain and both going inactive at its end
//    T4  codec B writes silence into its ring behind bp and nowhere else
//    T5  buffers that start on an odd word and are not a whole number of
//        doublewords: a stereo frame split across a descriptor boundary
//    T6  stopping a running channel with ch_act_ld: output silent, bp still
//    T7  the OSD's switch off: REV says absent, the DAC says nothing
//
//  Build:  make -C verilator audiotest
//============================================================================

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <map>
#include <vector>
#include <deque>
#include "Vtb_audio_top.h"
#include "verilated.h"

static const uint64_t CLK_HZ = 5000000;      // tb_audio_top's AUDIO_CLK_HZ

static int fails = 0, checks = 0;
static void check(const char *what, uint64_t got, uint64_t want)
{
    checks++;
    bool ok = (got == want);
    if (!ok) fails++;
    if (!ok || getenv("TB_VERBOSE"))
        printf("  %-58s %s  got 0x%llx want 0x%llx\n", what, ok ? "ok  " : "FAIL",
               (unsigned long long)got, (unsigned long long)want);
}
static void check_true(const char *what, bool c)
{
    checks++;
    if (!c) { fails++; printf("  %-58s FAIL\n", what); }
    else if (getenv("TB_VERBOSE")) printf("  %-58s ok\n", what);
}

// ---- the machine around the chip ---------------------------------------------
struct Bench {
    Vtb_audio_top *t = new Vtb_audio_top;
    uint64_t cycle = 0;

    // Memory: big-endian doublewords, addressed by physical byte address.
    std::map<uint32_t, uint64_t> mem;
    // One transaction at a time, answered after a random latency, as ram_arb
    // and ddr3_mux do (the latency is what hid the ram_arb bug for months).
    bool     m_busy = false;
    int      m_left = 0;
    uint32_t m_addr = 0;
    bool     m_we = false;
    uint64_t m_wdata = 0;
    uint8_t  m_be = 0;
    int      lat_max = 24;
    uint64_t n_txn = 0;

    // The DAC, sampled a few clocks after every frame codec A plays.
    uint32_t frames_seen = 0;
    int      frame_delay = -1;
    std::vector<std::pair<int16_t, int16_t>> played;

    uint64_t rd64(uint32_t a) { auto it = mem.find(a & ~7u); return it == mem.end() ? 0 : it->second; }
    uint32_t rd32m(uint32_t a) { uint64_t d = rd64(a); return (a & 4) ? (uint32_t)d : (uint32_t)(d >> 32); }
    void wr32m(uint32_t a, uint32_t v) {
        uint64_t d = rd64(a);
        if (a & 4) d = (d & 0xFFFFFFFF00000000ull) | v;
        else       d = (d & 0x00000000FFFFFFFFull) | ((uint64_t)v << 32);
        mem[a & ~7u] = d;
    }

    void tick() {
        t->clk = 0; t->eval();
        // memory model, on the falling edge so its outputs are settled for
        // the rising one
        t->dma_ack = 0;
        if (m_busy) {
            if (--m_left <= 0) {
                if (m_we) {
                    uint64_t d = rd64(m_addr), mask = 0;
                    for (int b = 0; b < 8; b++)
                        if (m_be & (0x80 >> b)) mask |= 0xFFull << (56 - 8 * b);
                    mem[m_addr] = (d & ~mask) | (m_wdata & mask);
                    t->dma_rdata = 0;
                } else {
                    t->dma_rdata = rd64(m_addr);
                }
                t->dma_ack = 1;
                m_busy = false;
                n_txn++;
            }
        } else if (t->dma_req && !was_acked) {
            m_busy = true;
            m_left = 1 + (rand() % lat_max);
            m_addr = t->dma_addr & ~7u;
            m_we = t->dma_we;
            m_wdata = t->dma_wdata;
            m_be = t->dma_be;
        }
        t->eval();
        t->clk = 1; t->eval();
        was_acked = t->dma_ack;
        cycle++;

        uint32_t f = (uint32_t)(t->audio0 >> 32);
        if (f != frames_seen) { frames_seen = f; frame_delay = 4; }
        if (frame_delay > 0 && --frame_delay == 0)
            played.push_back({(int16_t)t->audio_l, (int16_t)t->audio_r});
    }
    bool was_acked = false;

    void run(uint64_t n) { for (uint64_t i = 0; i < n; i++) tick(); }

    void reset() {
        t->reset = 1; t->sel = 0; t->we = 0;
        run(4);
        t->reset = 0;
        run(300);                   // HPC3's store sweeps itself clear
        played.clear();
        frames_seen = (uint32_t)(t->audio0 >> 32);
    }

    // One PIO access, the way r4300_bus presents it: a one-clock sel, the
    // payload held until ack.
    uint64_t pio(bool we, uint32_t off, uint8_t be, uint64_t wd) {
        t->sel = 1; t->we = we; t->addr = off & ~7u; t->aoff = off & 7;
        t->be = be; t->wdata = wd;
        tick();
        t->sel = 0;
        for (int i = 0; i < 64; i++) {
            if (t->ack) { uint64_t r = t->rdata; t->we = 0; tick(); return r; }
            tick();
        }
        printf("  PIO at %05x: no ack\n", off);
        fails++;
        return 0;
    }
    void wr32(uint32_t off, uint32_t v) {
        if (off & 4) pio(true, off, 0x0F, v);
        else         pio(true, off, 0xF0, (uint64_t)v << 32);
    }
    uint32_t rd32(uint32_t off) {
        uint64_t r = pio(false, off, 0, 0);
        return (off & 4) ? (uint32_t)r : (uint32_t)(r >> 32);
    }

    // ---- HAL2 ----------------------------------------------------------
    static const uint32_t H_ISR = 0x58010, H_REV = 0x58020, H_IAR = 0x58030,
                          H_IDR0 = 0x58040, H_IDR1 = 0x58050,
                          V_R = 0x58800, V_L = 0x58804;
    void iwr(uint16_t iar, uint16_t v0, uint16_t v1 = 0) {
        wr32(H_IDR0, v0); wr32(H_IDR1, v1); wr32(H_IAR, iar);
        check("TSTATUS clear after an indirect write", rd32(H_ISR) & 1, 0);
    }
    uint16_t ird(uint16_t iar) {
        wr32(H_IAR, iar | 0x80);
        return (uint16_t)rd32(H_IDR0);
    }

    // ---- PBUS DMA ------------------------------------------------------
    static uint32_t bp(int ch)   { return 0x00000 + ch * 0x2000; }
    static uint32_t dp(int ch)   { return 0x00004 + ch * 0x2000; }
    static uint32_t ctrl(int ch) { return 0x01000 + ch * 0x2000; }
    void desc(uint32_t at, uint32_t buf, uint32_t bytes, uint32_t next, bool eox) {
        wr32m(at, buf);
        wr32m(at + 4, (eox ? 0x80000000u : 0) | (bytes & 0x3FFF));
        wr32m(at + 8, next);
        wr32m(at + 12, 0);
    }
    void start(int ch, uint32_t d) {
        wr32(dp(ch), d);
        wr32(ctrl(ch), 0x70);        // real_time | ch_act_ld | ch_act
    }
};

// What the DAC does to a sample: volume v (0..255, 255 = unity) and no codec
// attenuation, exactly as hal2.sv computes it.
static int16_t dac(int32_t s, int v)
{
    uint32_t vm = (uint32_t)v + (v >> 7);
    uint32_t g = (65535u * vm) >> 8;
    int64_t p = (int64_t)s * (int64_t)g;
    return (int16_t)(p >> 16);
}

// A sample as the PROM and kdsp_a2 store it: sign-extended, shifted left 8.
static uint32_t word_of(int16_t s) { return (uint32_t)((int32_t)s << 8); }

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    srand(12345);
    Bench b;
    b.t->audio_en = 1;
    b.reset();

    // ---- T1 registers -------------------------------------------------------
    printf("T1 registers\n");
    check("REV reads 0x4010 (audio present)", b.rd32(Bench::H_REV) & 0xFFFF, 0x4010);
    check("ISR TSTATUS clear", b.rd32(Bench::H_ISR) & 1, 0);
    b.wr32(Bench::H_ISR, 0x18);
    check("ISR writable bits read back", b.rd32(Bench::H_ISR) & 0x1C, 0x18);
    b.iwr(0x1404, 0x0210);
    check("codec A ctrl1 round-trips", b.ird(0x1404), 0x0210);
    b.iwr(0x1408, 0x1234, 0xABCD);
    check("codec A ctrl2 low word, read-back index 0", b.ird(0x1408), 0x1234);
    check("codec A ctrl2 high word, read-back index 1", b.ird(0x1409), 0xABCD);
    b.wr32(Bench::H_IAR, 0x1488);
    check("index 0 also leaves the high word in IDR1", b.rd32(Bench::H_IDR1) & 0xFFFF, 0xABCD);
    b.iwr(0x2208, 0x0004, 0xFFF9);
    check("BRES2 inc", b.ird(0x2208), 0x0004);
    check("BRES2 modctrl", b.ird(0x2209), 0xFFF9);
    b.iwr(0x9104, 0x001E);
    check("DMA enable round-trips", b.ird(0x9104), 0x001E);
    b.wr32(Bench::H_ISR, 0x08);                 // CODEC_RESET_N low
    check("codec reset clears the port enables", b.ird(0x9104), 0x0000);
    check("codec reset clears codec A ctrl1", b.ird(0x1404), 0x0000);
    check("codec reset leaves BRES2 alone", b.ird(0x2208), 0x0004);
    b.wr32(Bench::H_ISR, 0x00);                 // GLOBAL_RESET_N low
    check("global reset: BRES2 inc back to 1", b.ird(0x2208), 0x0001);
    check("global reset: BRES2 modctrl back to 0xFFFF", b.ird(0x2209), 0xFFFF);
    b.wr32(Bench::H_ISR, 0x18);
    b.wr32(Bench::V_R, 0x40);
    b.wr32(Bench::V_L, 0x80);
    check("volume right at +0x800", b.rd32(Bench::V_R) & 0xFF, 0x40);
    check("volume left at +0x804", b.rd32(Bench::V_L) & 0xFF, 0x80);
    check("the PBUS channels come up stopped", b.rd32(Bench::ctrl(0)) & 2, 0);

    // ---- T2 an IRIX ring --------------------------------------------------
    printf("T2 IRIX ring: one self-linked descriptor, codec A stereo 48 kHz\n");
    b.reset();
    const int N2 = 300;                                  // frames in the ring
    const uint32_t RING = 0x100000, D2 = 0x200000;
    std::vector<std::pair<int16_t, int16_t>> src2;
    for (int i = 0; i < N2; i++) {
        int16_t l = (int16_t)(i * 97 - 12000), r = (int16_t)(20000 - i * 131);
        src2.push_back({l, r});
        b.wr32m(RING + 8 * i, word_of(l));
        b.wr32m(RING + 8 * i + 4, word_of(r));
    }
    b.desc(D2, RING, N2 * 8, D2, false);
    b.wr32(Bench::H_ISR, 0x18);
    b.wr32(Bench::V_R, 0xFF);
    b.wr32(Bench::V_L, 0xFF);
    b.iwr(0x2204, 0);                                    // BRES2 master 48 kHz
    b.iwr(0x2208, 1, 0xFFFF);                            // inc 1, mod 1
    b.iwr(0x1404, 0x0210);                               // codec A: ch 0, BRES2, stereo
    b.start(0, D2);
    check("channel 0 running", b.rd32(Bench::ctrl(0)) & 2, 2);
    check("dp reads the self-linked descriptor", b.rd32(Bench::dp(0)), D2);
    b.run(100);
    check("bp loaded from the descriptor on activation", b.rd32(Bench::bp(0)), RING);
    b.iwr(0x9104, 0x0008);                               // codec A on
    b.played.clear();
    uint32_t bp0 = b.rd32(Bench::bp(0));
    uint64_t c0 = b.cycle;
    b.run(CLK_HZ / 48000 * 700);                         // ~700 frames: 2+ wraps
    uint32_t bp1 = b.rd32(Bench::bp(0));
    uint64_t c1 = b.cycle;
    // bp is a ring position; unwrap it with the frame count HAL2 reports.
    double frames_expected = (double)(c1 - c0) * 48000.0 / CLK_HZ;
    check_true("bp stays inside the ring", bp1 >= RING && bp1 < RING + N2 * 8);
    printf("  %zu frames played over %.1f sample periods; bp 0x%x -> 0x%x\n",
           b.played.size(), frames_expected, bp0, bp1);
    check_true("frames played at the sample rate (+-3)",
               std::abs((double)b.played.size() - frames_expected) <= 3.0);
    // Find the first frame in the source and check the run from there on.
    {
        int start = -1;
        for (int k = 0; k < N2 && start < 0; k++)
            if (b.played.size() > 2 &&
                b.played[2].first == dac(src2[k].first, 255) &&
                b.played[2].second == dac(src2[k].second, 255)) start = k;
        check_true("the third frame played is a frame of the ring", start >= 0);
        int bad = 0;
        for (size_t i = 2; i < b.played.size() && start >= 0; i++) {
            auto &s = src2[(start + i - 2) % N2];
            if (b.played[i].first != dac(s.first, 255) || b.played[i].second != dac(s.second, 255)) {
                if (bad < 5) printf("  frame %zu: played %d,%d want %d,%d\n", i,
                                    b.played[i].first, b.played[i].second,
                                    dac(s.first, 255), dac(s.second, 255));
                bad++;
            }
        }
        check("every frame in order across the wraps (mismatches)", bad, 0);
    }
    check("no underruns in steady state (<= 1, the first tick)",
          (b.t->audio1 >> 48) <= 1, 1);
    check("descriptor fetched once per wrap (>= 2)", ((b.t->audio2 >> 32) & 0xFFFF) >= 2, 1);

    // ---- T3 the PROM's tune ----------------------------------------------------
    printf("T3 PROM tune: EOX chain on channels 1 and 2, 44.1 kHz mono\n");
    b.reset();
    const int N3 = 700;                                  // words, over 3 buffers
    const uint32_t BUF3 = 0x300000 + 0xF00, D3 = 0x380000;   // crosses 4 KB
    std::vector<int16_t> src3;
    for (int i = 0; i < N3; i++) {
        int16_t s = (int16_t)((i * 211) % 30000 - 15000);
        src3.push_back(s);
        b.wr32m(BUF3 + 4 * i, word_of(s));
    }
    // the PROM's split: at 4 KB boundaries
    {
        uint32_t a = BUF3, left = N3 * 4, d = D3;
        while (left) {
            uint32_t chunk = 0x1000 - (a & 0xFFF);
            if (chunk > left) chunk = left;
            left -= chunk;
            b.desc(d, a, chunk, left ? d + 16 : 0, left == 0);
            a += chunk; d += 16;
        }
    }
    b.wr32(Bench::H_ISR, 0x18);
    b.wr32(Bench::V_R, 80);
    b.wr32(Bench::V_L, 80);
    b.iwr(0x1304, 0x010A);                               // AES TX: ch 2, BRES1, mono
    b.iwr(0x2104, 1);                                    // BRES1 master 44.1 kHz
    b.iwr(0x2108, 1, 0xFFFF);
    b.iwr(0x1404, 0x0109);                               // codec A: ch 1, BRES1, mono
    b.iwr(0x9104, 0x000C);                               // codec A + AES TX
    b.played.clear();
    b.start(1, D3);
    b.start(2, D3);
    uint64_t guard = 0;
    while ((b.rd32(Bench::ctrl(1)) & 2) || (b.rd32(Bench::ctrl(2)) & 2)) {
        b.run(1000);
        if (++guard > 1000) break;
    }
    check("channel 1 went inactive at the end of the chain", b.rd32(Bench::ctrl(1)) & 2, 0);
    check("channel 2 went inactive at the end of the chain", b.rd32(Bench::ctrl(2)) & 2, 0);
    b.run(CLK_HZ / 44100 * 4);
    {
        // The played run must contain the whole tune, in order, mono in both.
        int start = -1;
        for (size_t i = 0; i < b.played.size() && start < 0; i++)
            if (b.played[i].first == dac(src3[0], 80) && b.played[i].second == dac(src3[0], 80))
                start = (int)i;
        check_true("the tune's first sample was played", start >= 0);
        int bad = 0;
        for (int k = 0; k < N3 && start >= 0; k++) {
            size_t i = start + k;
            if (i >= b.played.size() || b.played[i].first != dac(src3[k], 80)
                || b.played[i].second != b.played[i].first) {
                if (bad < 5 && i < b.played.size())
                    printf("  sample %d: played %d,%d want %d\n", k, b.played[i].first,
                           b.played[i].second, dac(src3[k], 80));
                bad++;
            }
        }
        check("every sample of the tune, in order (mismatches)", bad, 0);
    }
    check("bp of channel 1 at the end of the buffer", b.rd32(Bench::bp(1)), BUF3 + N3 * 4);

    // ---- T4 codec B writes silence ------------------------------------------------
    printf("T4 codec B: silence into its ring behind bp\n");
    b.reset();
    const uint32_t RING4 = 0x400000, D4 = 0x480000, N4 = 1024;   // bytes
    for (uint32_t a = RING4; a < RING4 + N4 + 64; a += 4) b.wr32m(a, 0xAAAAAAAA);
    b.desc(D4, RING4, N4, D4, false);
    b.wr32(Bench::H_ISR, 0x18);
    b.iwr(0x2104, 0);
    b.iwr(0x2108, 1, 0xFFFF);
    b.iwr(0x1504, 0x0209);                               // codec B: ch 1, BRES1, stereo
    b.start(1, D4);
    b.iwr(0x9104, 0x0010);
    b.run(CLK_HZ / 48000 * 60);                          // ~60 frames = 480 bytes
    b.iwr(0x9104, 0x0000);
    b.run(200);
    {
        uint32_t p = b.rd32(Bench::bp(1));
        int zeros_behind = 0, pattern_ahead = 0, bad = 0;
        for (uint32_t a = RING4; a < RING4 + N4; a += 4) {
            uint32_t v = b.rd32m(a);
            if (a < p) { if (v == 0) zeros_behind++; else bad++; }
            else       { if (v == 0xAAAAAAAA) pattern_ahead++; else bad++; }
        }
        printf("  bp 0x%x: %d words zeroed behind it, %d untouched ahead\n", p, zeros_behind, pattern_ahead);
        check_true("codec B wrote about 60 frames", zeros_behind >= 110 && zeros_behind <= 130);
        check("nothing but silence behind bp, nothing touched ahead", bad, 0);
        check("nothing written past the ring", b.rd32m(RING4 + N4), 0xAAAAAAAA);
    }

    // ---- T5 odd alignment and a frame across a descriptor boundary ---------------
    printf("T5 odd-word buffers, a frame split across descriptors\n");
    b.reset();
    // Two buffers of 3 and 5 words (12 and 20 bytes), the first starting on an
    // odd word, linked in a ring: 8 words = 4 stereo frames per lap, and every
    // lap has a frame whose two words are in different buffers.
    const uint32_t B5a = 0x500004, B5b = 0x500100, D5 = 0x580000;
    std::vector<int16_t> w5;
    for (int i = 0; i < 8; i++) w5.push_back((int16_t)(1000 * (i + 1) * ((i & 1) ? -1 : 1)));
    for (int i = 0; i < 3; i++) b.wr32m(B5a + 4 * i, word_of(w5[i]));
    for (int i = 0; i < 5; i++) b.wr32m(B5b + 4 * i, word_of(w5[3 + i]));
    b.desc(D5, B5a, 12, D5 + 16, false);
    b.desc(D5 + 16, B5b, 20, D5, false);
    b.wr32(Bench::H_ISR, 0x18);
    b.wr32(Bench::V_R, 255);
    b.wr32(Bench::V_L, 255);
    b.iwr(0x2204, 0);
    b.iwr(0x2208, 1, 0xFFFF);
    b.iwr(0x1404, 0x0210);                               // codec A: ch 0, BRES2, stereo
    b.start(0, D5);
    b.played.clear();
    b.iwr(0x9104, 0x0008);
    b.run(CLK_HZ / 48000 * 40);
    {
        int start = -1;
        for (int k = 0; k < 4 && start < 0; k++)
            if (b.played.size() > 2 && b.played[2].first == dac(w5[2 * k], 255)
                && b.played[2].second == dac(w5[2 * k + 1], 255)) start = k;
        check_true("a frame of the ring was played", start >= 0);
        int bad = 0;
        for (size_t i = 2; i < b.played.size() && start >= 0; i++) {
            int k = (start + (int)(i - 2)) % 4;
            if (b.played[i].first != dac(w5[2 * k], 255) || b.played[i].second != dac(w5[2 * k + 1], 255)) {
                if (bad < 5) printf("  frame %zu: played %d,%d want %d,%d\n", i, b.played[i].first,
                                    b.played[i].second, dac(w5[2 * k], 255), dac(w5[2 * k + 1], 255));
                bad++;
            }
        }
        check("frames split across descriptors come out whole (mismatches)", bad, 0);
    }

    // ---- T6 stopping a running channel ------------------------------------------
    printf("T6 stop a running channel\n");
    b.wr32(Bench::ctrl(0), 0x20);                        // ch_act_ld, ch_act clear
    check("channel 0 stopped", b.rd32(Bench::ctrl(0)) & 2, 0);
    uint32_t bps = b.rd32(Bench::bp(0));
    b.run(CLK_HZ / 48000 * 10);
    check("bp does not move once stopped", b.rd32(Bench::bp(0)), bps);
    check("the DAC goes silent (left)", b.t->audio_l, 0);
    check("the DAC goes silent (right)", b.t->audio_r, 0);

    // ---- T7 the OSD's switch ------------------------------------------------------
    printf("T7 audio off\n");
    b.t->audio_en = 0;
    b.reset();
    check("REV reads 0xC010 (absent)", b.rd32(Bench::H_REV) & 0xFFFF, 0xC010);
    b.start(0, D2);
    b.iwr(0x2204, 0);
    b.iwr(0x1404, 0x0210);
    b.iwr(0x9104, 0x0008);
    uint32_t bpo = b.rd32(Bench::bp(0));
    b.run(CLK_HZ / 48000 * 20);
    check("with audio off codec A does not take samples", b.rd32(Bench::bp(0)), bpo);
    check("with audio off the DAC is silent", b.t->audio_l, 0);

    printf("\n%d checks, %d failures; %llu memory transactions\n", checks, fails,
           (unsigned long long)b.n_txn);
    printf("%s\n", fails ? "TB_AUDIO FAIL" : "TB_AUDIO PASS");
    delete b.t;
    return fails ? 1 : 0;
}
