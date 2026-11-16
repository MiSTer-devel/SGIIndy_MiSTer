/*
 * l2sim - how many DDR3 round trips a unified second-level cache in block RAM
 * would save, replayed from the simulator's two cache access streams
 * (tools/icachesim.c, tools/dcachesim.c describe the trace formats).
 *
 *   cc -O2 -o l2sim tools/l2sim.c
 *   ./l2sim itrace.bin dtrace.bin
 *
 * First level as the core has it: a 16 KB direct-mapped instruction cache
 * with 32-byte lines and an 8 KB direct-mapped data cache with 16-byte lines
 * (write-back, a dirty line written back on eviction). Behind both, ram_arb's
 * prefetch buffers as build 48 has them (docs/design/cache-fill-latency.md
 * section 8): an instruction fill that misses the buffer bursts its line and
 * the next two, the two extra lines are kept; a data fill does the same only
 * when its line follows the previous data fill's. That is "today" here.
 *
 * The alternative is one second level with 32-byte lines, direct-mapped or
 * two-way, 64 KB to 512 KB, filled with the same bursts (so it subsumes the
 * buffers: the two extra lines land in the second level instead). The two
 * traces come from separate runs, so they are interleaved by progress (the
 * same fraction of each file at every step) - close enough for a capacity
 * question, exact for nothing.
 *
 * What is counted is DDR3 transactions: a first-level fill answered on chip
 * (buffer or second level) costs a few clocks; one that is not is the ~20
 * clock trip the board pays. A data writeback that hits the second level
 * stays on chip (the second level is write-back towards DDR3); one that
 * misses allocates there.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define EMPTY 0xFFFFFFFFu

typedef struct { uint32_t line; uint8_t dirty; } Way;

typedef struct {
    const char *name;
    unsigned sets, ways;
    Way *w;
} Cache;

static Cache mk(const char *name, unsigned sets, unsigned ways)
{
    Cache c = { name, sets, ways, NULL };
    c.w = calloc((size_t)sets * ways, sizeof(Way));
    for (size_t i = 0; i < (size_t)sets * ways; i++) c.w[i].line = EMPTY;
    return c;
}

/* Look a line up, LRU within the set; allocate on a miss. Returns 1 on a hit.
   On a miss the evicted way is copied to *victim (line EMPTY if free). */
static int lookup(Cache *c, uint32_t line, int store, Way *victim)
{
    Way *t = &c->w[(size_t)(line & (c->sets - 1)) * c->ways];
    unsigned w;
    for (w = 0; w < c->ways; w++)
        if (t[w].line == line) break;
    Way hit;
    int was_hit = w < c->ways;
    if (was_hit) {
        hit = t[w];
    } else {
        w = c->ways - 1;
        if (victim) *victim = t[w];
        hit.line = line;
        hit.dirty = 0;
    }
    if (store) hit.dirty = 1;
    memmove(&t[1], &t[0], w * sizeof(Way));
    t[0] = hit;
    return was_hit;
}

/* Is the line present, without touching LRU or allocating. */
static int present(Cache *c, uint32_t line)
{
    Way *t = &c->w[(size_t)(line & (c->sets - 1)) * c->ways];
    for (unsigned w = 0; w < c->ways; w++)
        if (t[w].line == line) return 1;
    return 0;
}

/* ---- today: ram_arb's two 2-line prefetch buffers ---- */
typedef struct {
    uint32_t buf[2];
    uint32_t last_dfill;
    uint64_t i_bufhit, d_bufhit, xact;     /* xact = DDR3 transactions */
} Today;

static void today_ifill(Today *t, uint32_t line)
{
    if (t->buf[0] == line || t->buf[1] == line) { t->i_bufhit++; return; }
    t->xact++;                              /* one 12-word burst */
    t->buf[0] = line + 1; t->buf[1] = line + 2;
}

static void today_dfill(Today *t, uint32_t line /* 32-byte */, uint32_t *dbuf)
{
    if (dbuf[0] == line || dbuf[1] == line) { t->d_bufhit++; }
    else {
        t->xact++;
        if (line == t->last_dfill + 1) { dbuf[0] = line + 1; dbuf[1] = line + 2; }
    }
    t->last_dfill = line;
}

/* ---- the second level ---- */
typedef struct {
    Cache l2;
    uint32_t last_dfill;
    uint64_t i_hit, i_miss, d_hit, d_miss, wb_hit, wb_miss, l2_wb;
} L2;

static void l2_victim(L2 *s, Way v)
{
    if (v.line != EMPTY && v.dirty) s->l2_wb++;
}

/* A burst of n lines from DDR3 into the second level, the first is the
   demanded one; lines already present are not re-fetched (no new victim). */
static void l2_burst(L2 *s, uint32_t line, unsigned n)
{
    for (unsigned k = 0; k < n; k++) {
        Way v = { EMPTY, 0 };
        if (!present(&s->l2, line + k)) {
            lookup(&s->l2, line + k, 0, &v);
            l2_victim(s, v);
        } else if (k == 0) {
            lookup(&s->l2, line, 0, NULL);   /* LRU touch */
        }
    }
}

static void l2_ifill(L2 *s, uint32_t line)
{
    if (present(&s->l2, line)) { s->i_hit++; lookup(&s->l2, line, 0, NULL); return; }
    s->i_miss++;
    l2_burst(s, line, 3);
}

static void l2_dfill(L2 *s, uint32_t line)
{
    if (present(&s->l2, line)) { s->d_hit++; lookup(&s->l2, line, 0, NULL); }
    else {
        s->d_miss++;
        l2_burst(s, line, line == s->last_dfill + 1 ? 3 : 1);
    }
    s->last_dfill = line;
}

static void l2_write(L2 *s, uint32_t line)
{
    Way v = { EMPTY, 0 };
    int h = lookup(&s->l2, line, 1, &v);
    if (h) s->wb_hit++; else { s->wb_miss++; l2_victim(s, v); }
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s itrace.bin dtrace.bin\n", argv[0]);
        return 2;
    }
    FILE *fi = fopen(argv[1], "rb");
    FILE *fd = fopen(argv[2], "rb");
    if (!fi) { perror(argv[1]); return 1; }
    if (!fd) { perror(argv[2]); return 1; }
    fseek(fi, 0, SEEK_END); uint64_t ni = ftell(fi) / 4; rewind(fi);
    fseek(fd, 0, SEEK_END); uint64_t nd = ftell(fd) / 4; rewind(fd);
    uint32_t *ti = malloc(ni * 4), *td = malloc(nd * 4);
    if (fread(ti, 4, ni, fi) != ni || fread(td, 4, nd, fd) != nd) { perror("read"); return 1; }
    fclose(fi); fclose(fd);

    Cache l1i = mk("L1I DM 16K/32", 512, 1);
    Cache l1d = mk("L1D DM 8K/16", 512, 1);
    Today today = { { EMPTY, EMPTY }, EMPTY, 0, 0, 0 };
    uint32_t dbuf[2] = { EMPTY, EMPTY };
    L2 s[] = {
        { mk("DM 64K",    2048, 1), EMPTY },
        { mk("DM 128K",   4096, 1), EMPTY },
        { mk("DM 256K",   8192, 1), EMPTY },
        { mk("DM 512K",  16384, 1), EMPTY },
        { mk("2x32K",     1024, 2), EMPTY },
        { mk("2x64K",     2048, 2), EMPTY },
        { mk("2x128K",    4096, 2), EMPTY },
        { mk("2x256K",    8192, 2), EMPTY },
    };
    const unsigned NS = sizeof s / sizeof s[0];
    uint64_t i_rec = 0, d_rec = 0, l1i_miss = 0, l1d_fill = 0, l1d_wb = 0, d_stores = 0;

    /* Interleave by progress: advance whichever stream is further behind. */
    uint64_t pi = 0, pd = 0;
    while (pi < ni || pd < nd) {
        int take_i;
        if (pi >= ni) take_i = 0;
        else if (pd >= nd) take_i = 1;
        else take_i = (pi * nd <= pd * ni);
        if (take_i) {
            uint32_t line = ti[pi++];
            i_rec++;
            if (!lookup(&l1i, line, 0, NULL)) {
                l1i_miss++;
                today_ifill(&today, line);
                for (unsigned k = 0; k < NS; k++) l2_ifill(&s[k], line);
            }
        } else {
            uint32_t rec = td[pd++];
            uint32_t dword = rec >> 1;
            int store = rec & 1;
            d_rec++; d_stores += store;
            uint32_t line16 = dword >> 1;           /* 16-byte line */
            Way v = { EMPTY, 0 };
            if (!lookup(&l1d, line16, store, &v)) {
                l1d_fill++;
                if (v.line != EMPTY && v.dirty) {
                    l1d_wb++;
                    today.xact++;
                    /* a write into a buffered line invalidates it */
                    uint32_t wl = v.line >> 1;
                    if (today.buf[0] == wl) today.buf[0] = EMPTY;
                    if (today.buf[1] == wl) today.buf[1] = EMPTY;
                    if (dbuf[0] == wl) dbuf[0] = EMPTY;
                    if (dbuf[1] == wl) dbuf[1] = EMPTY;
                    for (unsigned k = 0; k < NS; k++) l2_write(&s[k], wl);
                }
                today_dfill(&today, line16 >> 1, dbuf);
                for (unsigned k = 0; k < NS; k++) l2_dfill(&s[k], line16 >> 1);
            }
        }
    }

    printf("I: %llu records, L1I misses %llu\n", (unsigned long long)i_rec, (unsigned long long)l1i_miss);
    printf("D: %llu records (%llu stores), L1D fills %llu, L1D writebacks %llu\n\n",
           (unsigned long long)d_rec, (unsigned long long)d_stores,
           (unsigned long long)l1d_fill, (unsigned long long)l1d_wb);
    printf("today (build 48 buffers): I fills answered %.1f%%, D fills %.1f%%, DDR3 transactions %llu\n\n",
           100.0 * today.i_bufhit / (l1i_miss ? l1i_miss : 1),
           100.0 * today.d_bufhit / (l1d_fill ? l1d_fill : 1),
           (unsigned long long)today.xact);
    printf("%-9s %7s %7s %7s | %9s %9s %10s\n", "L2", "I hit", "D hit", "WB hit",
           "L2 wbacks", "DDR3 xact", "vs today");
    for (unsigned k = 0; k < NS; k++) {
        L2 *x = &s[k];
        uint64_t trips = x->i_miss + x->d_miss + x->wb_miss + x->l2_wb;
        printf("%-9s %6.1f%% %6.1f%% %6.1f%% | %9llu %9llu %9.1f%%\n", x->l2.name,
               100.0 * x->i_hit / (l1i_miss ? l1i_miss : 1),
               100.0 * x->d_hit / (l1d_fill ? l1d_fill : 1),
               100.0 * x->wb_hit / (l1d_wb ? l1d_wb : 1),
               (unsigned long long)x->l2_wb, (unsigned long long)trips,
               100.0 * trips / (today.xact ? today.xact : 1));
    }
    printf("\n'I/D hit' = first-level fills the second level answers without DDR3 (the\n"
           "buffers' hits are included in it: the burst's extra lines land there);\n"
           "'DDR3 xact' = reads + writebacks that still go to memory.\n");
    return 0;
}
