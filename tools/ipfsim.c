/*
 * ipfsim - what a next-line prefetch buffer in front of the 16 KB
 * direct-mapped instruction cache would catch, on an --itrace stream
 * (docs/design/cache-fill-latency.md section 8; the model behind build 46's
 * ram_arb prefetch buffer).
 *
 *   ./obj_wm/Vsim_top ... --itrace itrace.bin
 *   cc -O2 -o ipfsim tools/ipfsim.c && ./ipfsim itrace.bin
 *
 * On the IRIX boot trace (18.9M line changes, 588,454 misses) it printed:
 * 53.4 % of misses are to the previous miss + 1; a 3-line burst on a miss
 * (the line, then two into a buffer) leaves 54.2 % of the DDR3 fills.
 *
 * Trace: little-endian uint32 per access, physical address >> 5, repeats
 * collapsed (sim_cputest --itrace). Models, each counted separately:
 *   base      16 KB direct-mapped, every miss a fill
 *   sb1       + a one-line stream buffer: every demand miss on L prefetches
 *             L+1 into it; a miss that finds its line there is a buffer hit
 *             (the line moves into the cache and L+2 is prefetched)
 *   sbN       + N lines deep (L+1..L+N after a miss)
 *   pair      a miss fetches L and L+1 together into the cache (a 64-byte
 *             fill: the second line overwrites whatever held its set)
 * Also: how far (in line changes) the next access to L+1 is after the miss
 * on L - a stand-in for how much of a prefetch's latency is hidden.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SETS 512u               /* 16 KB / 32 B */
#define EMPTY 0xFFFFFFFFu

#define NB 4
static uint32_t tag_bn[NB][SETS];
static uint32_t bn_lo[NB], bn_n[NB], bn_used[NB];
static uint64_t bn_hit[NB], bn_miss[NB];
static uint32_t tag_base[SETS], tag_sb[SETS], tag_pair[SETS], tag_sb4[SETS], tag_pb[SETS];

int main(int argc, char **argv)
{
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 1; }
    memset(tag_base, 0xFF, sizeof tag_base);
    memset(tag_sb, 0xFF, sizeof tag_sb);
    memset(tag_pair, 0xFF, sizeof tag_pair);
    memset(tag_sb4, 0xFF, sizeof tag_sb4);
    memset(tag_pb, 0xFF, sizeof tag_pb);
    memset(tag_bn, 0xFF, sizeof tag_bn);
    uint32_t pb = EMPTY; uint64_t pb_hit = 0, pb_miss = 0;

    uint64_t n = 0, miss_base = 0;
    uint64_t sb_hit = 0, sb_miss = 0;           /* sb1 */
    uint64_t sb4_hit = 0, sb4_miss = 0;         /* 4 deep */
    uint64_t pair_miss = 0;
    uint64_t seq_miss = 0;                      /* base miss on prev_miss+1 */
    uint64_t dist_hist[10] = {0};               /* distance to next use of L+1 */
    uint32_t sb = EMPTY;
    uint32_t sb4[4] = {EMPTY, EMPTY, EMPTY, EMPTY};
    uint32_t prev_miss = EMPTY;
    /* pending distance measurement */
    uint32_t want = EMPTY; uint64_t want_at = 0;

    uint32_t buf[1 << 16];
    size_t got;
    while ((got = fread(buf, 4, 1 << 16, f)) > 0) {
        for (size_t i = 0; i < got; i++) {
            uint32_t line = buf[i];
            unsigned s = line & (SETS - 1);
            n++;

            if (want != EMPTY && line == want) {
                uint64_t d = n - want_at;
                int b = d <= 1 ? 0 : d <= 2 ? 1 : d <= 4 ? 2 : d <= 8 ? 3 : d <= 16 ? 4 :
                        d <= 64 ? 5 : d <= 256 ? 6 : 7;
                dist_hist[b]++;
                want = EMPTY;
            }

            /* base */
            if (tag_base[s] != line) {
                tag_base[s] = line;
                miss_base++;
                if (prev_miss != EMPTY && line == prev_miss + 1) seq_miss++;
                prev_miss = line;
                want = line + 1; want_at = n;
            }

            /* sb1 */
            if (tag_sb[s] != line) {
                tag_sb[s] = line;
                if (sb == line) { sb_hit++; sb = line + 1; }
                else            { sb_miss++; sb = line + 1; }
            }

            /* sb4: a 4-line window starting after the last miss */
            if (tag_sb4[s] != line) {
                tag_sb4[s] = line;
                int hit = 0;
                for (int k = 0; k < 4; k++) if (sb4[k] == line) hit = 1;
                if (hit) sb4_hit++; else sb4_miss++;
                for (int k = 0; k < 4; k++) sb4[k] = line + 1 + k;
            }

            /* pb: a miss is an 8-beat burst, L to the cache and L+1 to the
               buffer; a buffer hit is served and prefetches nothing */
            if (tag_pb[s] != line) {
                tag_pb[s] = line;
                if (pb == line) { pb_hit++; pb = EMPTY; }
                else            { pb_miss++; pb = line + 1; }
            }

            /* burstN: a demand miss on L fetches L..L+N-1 in one burst, L to
               the cache and L+1..L+N-1 to an (N-1)-line buffer that replaces
               the old one; a buffer hit moves its line to the cache and
               fetches nothing. */
            for (int m = 0; m < NB; m++) {
                if (tag_bn[m][s] != line) {
                    tag_bn[m][s] = line;
                    uint32_t lo = bn_lo[m], cnt = bn_n[m];
                    if (cnt && line >= lo && line < lo + cnt && ((bn_used[m] >> (line - lo)) & 1) == 0) {
                        bn_hit[m]++; bn_used[m] |= 1u << (line - lo);
                    } else {
                        bn_miss[m]++; bn_lo[m] = line + 1; bn_n[m] = (uint32_t)(m + 1); bn_used[m] = 0;
                    }
                }
            }

            /* pair */
            if (tag_pair[s] != line) {
                tag_pair[s] = line;
                pair_miss++;
                uint32_t nx = line + 1;
                tag_pair[nx & (SETS - 1)] = nx;
            }
        }
    }
    printf("accesses (line changes)   %llu\n", (unsigned long long)n);
    printf("base 16K DM misses        %llu\n", (unsigned long long)miss_base);
    printf("  of which prev miss + 1  %llu (%.1f %%)\n", (unsigned long long)seq_miss,
           100.0 * seq_miss / miss_base);
    printf("sb1: buffer hits %llu, fills %llu  -> DDR3 fills %.1f %% of base\n",
           (unsigned long long)sb_hit, (unsigned long long)sb_miss, 100.0 * sb_miss / miss_base);
    printf("sb4: buffer hits %llu, fills %llu  -> DDR3 demand fills %.1f %% of base\n",
           (unsigned long long)sb4_hit, (unsigned long long)sb4_miss, 100.0 * sb4_miss / miss_base);
    printf("pb (8-beat miss, L+1 to buffer, no prefetch on a hit): hits %llu, fills %llu -> %.1f %% of base\n",
           (unsigned long long)pb_hit, (unsigned long long)pb_miss, 100.0 * pb_miss / miss_base);
    for (int m = 0; m < NB; m++)
        printf("burst of %d lines on a miss: buffer hits %llu, DDR3 fills %llu -> %.1f %% of base, extra beats %llu\n",
               m + 2, (unsigned long long)bn_hit[m], (unsigned long long)bn_miss[m],
               100.0 * bn_miss[m] / miss_base, (unsigned long long)bn_miss[m] * 4 * (m + 1));
    printf("pair (64 B fills): fills %llu -> %.1f %% of base\n",
           (unsigned long long)pair_miss, 100.0 * pair_miss / miss_base);
    const char *lab[8] = {"1", "2", "3-4", "5-8", "9-16", "17-64", "65-256", ">256"};
    printf("line changes from a miss on L to the next access of L+1:\n");
    for (int b = 0; b < 8; b++)
        printf("  %-7s %llu\n", lab[b], (unsigned long long)dist_hist[b]);
    return 0;
}
