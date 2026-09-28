/*
 * wborder - a dirty line evicted by a data-cache miss must reach memory before
 * anything that could read it: the evicting fill's own successors, a re-miss
 * on the victim, an uncached read of it, and an instruction fetch of it.
 *
 * WHY THIS EXISTS. ~90 % of the data cache's fills evict a dirty line (the
 * boot's data trace, tools/dcachesim.c), and the victim's writeback sits in
 * front of the fill that evicted it: ~16 clocks on the board, +14 in the
 * simulator (cpu-tests bench/ld_miss_dirty against ld_miss64). Taking the
 * writeback off the fill's path means letting the fill overtake the line, and
 * everything that must NOT overtake it - the next miss, an uncached access,
 * an instruction fill, ram_arb's prefetch buffers - is what this checks. It
 * passes on a core that writes the line back first, too: it is the ratchet
 * any reordering has to keep passing.
 *
 * THE CACHE, for the arithmetic: 16 KB direct-mapped, 32-byte lines, so lines
 * 16 KB apart share a set and the second evicts the first. Every region below
 * is set up and checked through KSEG1 (uncached), so the caches never vouch
 * for their own contents; only the accesses under test go through KSEG0.
 *
 *   T1  write a whole line, evict it with a load 16 KB away, load it again:
 *       the re-miss must see the stored words (the fill of the re-miss is
 *       behind the victim's write)
 *   T2  the same, but read the victim back through KSEG1 right after the
 *       evicting load - an uncached read must be behind the write too
 *   T3  a stream: every line of region A dirtied, then region B walked with
 *       one store per line (each miss evicts a dirty A line and is answered,
 *       on the board, from ram_arb's data buffer two times in three), then
 *       region C read (evicting the dirty B lines); A, B and C checked
 *       uncached, every word, stored and untouched ones alike
 *   T4  code written through the data cache: four instructions stored at a
 *       line never fetched before, the line evicted by a load 16 KB away,
 *       then called - the instruction fill must see the stored code, and
 *       ram_arb's instruction buffer, which may have fetched that line ahead
 *       of the previous call, must have dropped it when the line was written
 *
 * Each test runs over all 512 sets, three rounds with different patterns.
 * Reports on the SCC and exits through the test device, like tests/scsiwr.
 */

typedef unsigned char  u8;
typedef unsigned int   u32;

#define IOC          0xBFBD9800u
#define SCC_B_CMD    (IOC + 0x30 + 3)
#define SCC_B_DATA   (IOC + 0x34 + 3)
#define RR0_TX_EMPTY 0x04u

#define TD_SIGNATURE 0xBF400000u
#define TD_EXIT      0xBF40000Cu
#define TD_MAGIC     0x49524953u

#define RD8(a)     (*(volatile u8  *)(unsigned long)(a))
#define WR8(a, v)  (*(volatile u8  *)(unsigned long)(a) = (u8)(v))
#define RD32(a)    (*(volatile u32 *)(unsigned long)(a))
#define WR32(a, v) (*(volatile u32 *)(unsigned long)(a) = (u32)(v))

#define CACHE_BYTES  16384u
#define LINE_BYTES   32u
#define SETS         (CACHE_BYTES / LINE_BYTES)
#define LINE_WORDS   (LINE_BYTES / 4u)

/* Physical 0x08400000 onward, 4 MB into RAM and clear of this image (linked
 * at 0x08200000, tests/dma/link.ld). Regions A..C for the data tests, then a
 * code area for T4 that no line of which is ever fetched twice. */
#define KSEG0(pa)    ((pa) | 0x80000000u)
#define KSEG1(pa)    ((pa) | 0xA0000000u)
#define PA_A         0x08400000u
#define PA_B         (PA_A + CACHE_BYTES)
#define PA_C         (PA_B + CACHE_BYTES)
#define PA_CODE      0x08500000u   /* 3 rounds x 512 lines x 32 bytes = 48 KB */

/* ---- console, as tests/dma/dmatest.c ------------------------------------ */

static void pause(void)
{
    int i;
    for (i = 0; i < 8; i++) __asm__ __volatile__("" ::: "memory");
}

static void wr(int reg, u8 val)
{
    WR8(SCC_B_CMD, (u8)reg);
    pause();
    WR8(SCC_B_CMD, val);
    pause();
}

static void scc_init(void)
{
    wr(9, 0x40);
    pause(); pause();
    wr(4, 0x44);
    wr(1, 0x00);
    wr(3, 0xC0);
    wr(5, 0x60);
    wr(9, 0x00);
    wr(10, 0x00);
    wr(11, 0x56);
    wr(12, 0x00);
    wr(13, 0x00);
    wr(14, 0x03);
    wr(3, 0xC1);
    wr(5, 0x68);
}

static void putc_scc(int c)
{
    int spins = 0;
    while (!(RD8(SCC_B_CMD) & RR0_TX_EMPTY))
        if (++spins > 200000) return;
    WR8(SCC_B_DATA, (u8)c);
}

static void puts_scc(const char *s)
{
    while (*s) putc_scc(*s++);
}

static void puthex(u32 v)
{
    static const char d[] = "0123456789abcdef";
    int i;
    for (i = 28; i >= 0; i -= 4) putc_scc(d[(v >> i) & 0xF]);
}

/* ---- the harness -------------------------------------------------------- */

static int failures;

/* The first few mismatches of a test are printed; all are counted. */
static u32 test_bad;

static void mismatch(const char *t, u32 pa, u32 got, u32 want)
{
    if (test_bad++ < 4) {
        puts_scc("  FAIL ");
        puts_scc(t);
        puts_scc(" pa ");
        puthex(pa);
        puts_scc(" got ");
        puthex(got);
        puts_scc(" want ");
        puthex(want);
        putc_scc('\n');
    }
}

static void verdict(const char *t)
{
    puts_scc(test_bad ? "  FAIL " : "  ok   ");
    puts_scc(t);
    if (test_bad) {
        puts_scc(": ");
        puthex(test_bad);
        puts_scc(" words wrong");
        failures++;
    }
    putc_scc('\n');
    test_bad = 0;
}

static inline u32 count(void)
{
    u32 v;
    __asm__ __volatile__("mfc0 %0, $9" : "=r"(v));
    return v;
}

/* A word's value is its address mixed with the round and a salt, so a word
 * that came from the wrong line, the wrong round or the wrong phase of a test
 * is never equal by accident. */
static u32 pat(u32 pa, u32 round, u32 salt)
{
    u32 x = pa ^ (round * 0x9E3779B9u) ^ (salt * 0x85EBCA6Bu);
    x ^= x >> 15;
    x *= 0x2C1B3C6Du;
    x ^= x >> 12;
    return x;
}

static void fill_uncached(u32 pa, u32 bytes, u32 round, u32 salt)
{
    u32 o;
    for (o = 0; o < bytes; o += 4)
        WR32(KSEG1(pa + o), pat(pa + o, round, salt));
}

/* Write back and invalidate the whole data cache: Index_Writeback_Inv_D over
 * every set, so each test starts with nothing of the regions cached. */
static void dcache_flush(void)
{
    u32 a;
    for (a = 0x80000000u; a < 0x80000000u + CACHE_BYTES; a += LINE_BYTES)
        __asm__ __volatile__(".set push\n\t.set mips3\n\t"
                             "cache 0x01, 0(%0)\n\t.set pop" :: "r"(a) : "memory");
}

/* ---- T1 / T2 ------------------------------------------------------------ */

static void t_remiss(u32 round, int uncached)
{
    u32 s, w;
    const char *name = uncached ? "T2 uncached read of the victim" : "T1 re-miss on the victim";
    fill_uncached(PA_A, CACHE_BYTES, round, 1);
    fill_uncached(PA_B, CACHE_BYTES, round, 2);
    dcache_flush();
    for (s = 0; s < SETS; s++) {
        u32 a = PA_A + s * LINE_BYTES, b = PA_B + s * LINE_BYTES;
        volatile u32 *ca = (volatile u32 *)KSEG0(a);
        u32 got[LINE_WORDS];
        for (w = 0; w < LINE_WORDS; w++) ca[w] = pat(a + 4 * w, round, 3);
        (void)RD32(KSEG0(b));                       /* evicts the dirty line */
        if (uncached)
            for (w = 0; w < LINE_WORDS; w++) got[w] = RD32(KSEG1(a + 4 * w));
        else
            for (w = 0; w < LINE_WORDS; w++) got[w] = ca[w];
        for (w = 0; w < LINE_WORDS; w++)
            if (got[w] != pat(a + 4 * w, round, 3))
                mismatch(name, a + 4 * w, got[w], pat(a + 4 * w, round, 3));
        if (RD32(KSEG1(b)) != pat(b, round, 2))
            mismatch(name, b, RD32(KSEG1(b)), pat(b, round, 2));
    }
    dcache_flush();
    for (s = 0; s < CACHE_BYTES; s += 4)
        if (RD32(KSEG1(PA_A + s)) != pat(PA_A + s, round, 3))
            mismatch(name, PA_A + s, RD32(KSEG1(PA_A + s)), pat(PA_A + s, round, 3));
    verdict(name);
}

/* ---- T3 ----------------------------------------------------------------- */

static u32 t3_ticks;

static void t_stream(u32 round)
{
    const char *name = "T3 a stream of dirty misses";
    u32 s, o, t0;
    fill_uncached(PA_A, CACHE_BYTES, round, 4);
    fill_uncached(PA_B, CACHE_BYTES, round, 5);
    fill_uncached(PA_C, CACHE_BYTES, round, 6);
    dcache_flush();
    /* A: every word stored, the whole cache dirty */
    for (o = 0; o < CACHE_BYTES; o += 4)
        WR32(KSEG0(PA_A + o), pat(PA_A + o, round, 7));
    t0 = count();
    /* B: one store per line, into a different word each time - each miss
     * evicts a dirty A line; B's other seven words must survive the fill */
    for (s = 0; s < SETS; s++) {
        u32 w = s % LINE_WORDS;
        WR32(KSEG0(PA_B + s * LINE_BYTES + 4 * w), pat(PA_B + s * LINE_BYTES + 4 * w, round, 8));
    }
    /* C: loads only, each evicting a dirty B line */
    for (s = 0; s < SETS; s++)
        (void)RD32(KSEG0(PA_C + s * LINE_BYTES));
    t3_ticks += count() - t0;
    dcache_flush();
    for (o = 0; o < CACHE_BYTES; o += 4) {
        u32 a = PA_A + o, b = PA_B + o, c = PA_C + o;
        u32 wb = (o / LINE_BYTES) % LINE_WORDS;
        u32 want_b = ((o % LINE_BYTES) / 4 == wb) ? pat(b, round, 8) : pat(b, round, 5);
        if (RD32(KSEG1(a)) != pat(a, round, 7)) mismatch(name, a, RD32(KSEG1(a)), pat(a, round, 7));
        if (RD32(KSEG1(b)) != want_b)           mismatch(name, b, RD32(KSEG1(b)), want_b);
        if (RD32(KSEG1(c)) != pat(c, round, 6)) mismatch(name, c, RD32(KSEG1(c)), pat(c, round, 6));
    }
    verdict(name);
}

/* ---- T4 ----------------------------------------------------------------- */

typedef u32 (*fn_t)(void);

static void t_code(u32 round)
{
    const char *name = "T4 code written through the data cache";
    u32 s;
    /* Every line of this round's area first holds, in memory, a stub that
     * returns 0xDEADxxxx: a stale fetch then comes back as a wrong value
     * instead of running off the end of a line of zeroes. */
    for (s = 0; s < SETS; s++) {
        u32 pc = PA_CODE + (round * SETS + s) * LINE_BYTES;
        WR32(KSEG1(pc +  0), 0x3C02DEADu);          /* lui  $2, 0xDEAD */
        WR32(KSEG1(pc +  4), 0x34420000u | s);      /* ori  $2, $2, s  */
        WR32(KSEG1(pc +  8), 0x03E00008u);          /* jr   $31        */
        WR32(KSEG1(pc + 12), 0x00000000u);          /* nop             */
    }
    dcache_flush();
    for (s = 0; s < SETS; s++) {
        u32 pc = PA_CODE + (round * SETS + s) * LINE_BYTES;
        u32 k = (round << 12) ^ s ^ 0x5A00u;
        volatile u32 *c = (volatile u32 *)KSEG0(pc);
        u32 got;
        c[0] = 0x3C020000u | (k >> 16);             /* lui  $2, k>>16  */
        c[1] = 0x34420000u | (k & 0xFFFFu);         /* ori  $2, $2, k  */
        c[2] = 0x03E00008u;                         /* jr   $31        */
        c[3] = 0x00000000u;                         /* nop             */
        /* The load that evicts the code line, and a call whose target
         * depends on the loaded value. The dependency matters: this core's
         * loads do not stall until their value is used, so with `(void)` the
         * call's instruction fetch reaches memory while the victim is still
         * being read out of the cache - and the architecture promises
         * nothing there either (code written by stores wants cache ops).
         * What this checks is everything after the load has completed. */
        {
            u32 v = RD32(KSEG0(pc ^ CACHE_BYTES)), zero;
            __asm__ __volatile__("sltu %0, %1, $0" : "=r"(zero) : "r"(v));
            got = ((fn_t)(unsigned long)(KSEG0(pc) + zero))();
        }
        if (got != k) mismatch(name, pc, got, k);
    }
    verdict(name);
}

int main(void)
{
    u32 round;
    scc_init();
    puts_scc("WBORDER: dirty victims against the fills that evict them\n");
    for (round = 0; round < 3; round++) {
        t_remiss(round, 0);
        t_remiss(round, 1);
        t_stream(round);
        t_code(round);
    }
    puts_scc("  T3's cached walks: ");
    puthex(t3_ticks);
    puts_scc(" Count ticks\n");

    puts_scc(failures ? "WBORDER: FAILURES " : "WBORDER: ALL PASS ");
    puthex((u32)failures);
    putc_scc('\n');
    {
        int spins = 0;
        while (!(RD8(SCC_B_CMD) & RR0_TX_EMPTY) && ++spins < 200000) { }
        for (spins = 0; spins < 200000; spins++) __asm__ __volatile__("" ::: "memory");
    }
    if (RD32(TD_SIGNATURE) == TD_MAGIC)
        WR32(TD_EXIT, failures ? 1 : 0);
    for (;;) { }
}
