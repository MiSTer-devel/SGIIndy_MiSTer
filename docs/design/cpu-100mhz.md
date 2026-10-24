# A 100 MHz CPU - plan

Status: **plan only, nothing built** (2026-10-24). Every figure comes from
earlier fits and board counters, cited where it is used. Numbers marked
*estimate* are estimates. The first step (section 6) is a timing report that
replaces the guesses in section 4.3 with a measured list.

## 1. Goal

Run the R4600 - pipeline, caches, TLB, FPU - at 100 MHz, twice today's clock,
and leave the rest of the machine at 50 MHz. An Indy with an R4600PC ran at
100 MHz, so `hinv` would then read like a real one. Out of scope: making the
memory path itself faster (section 3 says why it caps the gain).

## 2. Where it stands

* **One clock.** `rtl/pll/pll_0002.v` makes one 50 MHz output, `clk_sys`, and
  every block runs on it with `ce` tied high (`sgiindy.sv`). `DDRAM_CLK` is
  `clk_sys`, and so is `CLK_VIDEO` (a pixel is one `clk_sys` with Newport's
  pixel enable). Those, the 8254, `MC_RPSS_CTR`, the DS1386 and the SCC's NCO
  all assume 50 MHz, which is why only the CPU moves.
* **Timing today.** Build 53c meets 50 MHz with +1.404 ns (the whole design
  closes at ~54 MHz). Its worst paths are not in the CPU: they run from
  `mc_gio_dma`, `np_rex3` and `r4300_bus` into `ddr3_mux`. The CPU's own worst
  path, measured in a September fit, was ~17 ns (~57 MHz): the trap compare
  through `exceptionNew3` into the COP0 `EntryHi` write.
* **The pipeline can do it.** The Killer Instinct core this CPU comes from is
  timing-tuned for 100 MHz, and the N64 core before it runs at 93.75 MHz, both
  on this device (5CSEBA6U23I7, speed grade 7). What is ours on top of it is
  where the new long paths will be: the 48-entry TLB matched at once (KI has
  32), the physically indexed caches, the 64-bit mode bits and the no-stall
  loads.
* **Room.** 35,053 ALMs (84 %) in build 53c.

## 3. What 100 MHz buys

A line fill costs 18.5-20.2 clocks at 50 MHz (build 38,
[cache-fill-latency.md](cache-fill-latency.md)), and 9.5 of them are the DDR3
bridge alone. The rest are `ddr3_mux`, `ram_arb` and `r4300_bus`, which stay
at 50 MHz here. So a fill keeps its ~370-400 ns, while an instruction that
hits both caches takes half the time.

Time per instruction, with every stall counted as memory time and ~15 ns of
crossing per fill (section 4.2) - the pessimistic reading, since some stalls
are inside the CPU and would halve too:

| | clocks per instruction now (build 38) | ns now | ns at 100 MHz, *estimate* | gain, *estimate* |
|---|---:|---:|---:|---:|
| loop in the caches (`bench/i_cached`) | 1.00 | 20.0 | 10.0 | 2.0x |
| boot | 1.54 | 30.8 | 21.0 | 1.47x |
| login | 1.63 | 32.6 | 22.8 | 1.43x |
| `bzip2 -9` | 1.98 | 39.6 | 30.0 | 1.32x |

**About 1.3-1.5x for IRIX, 2x in the caches.** Every stall the memory side
loses later (the prefetch buffers since build 46 already removed some) raises
that figure, because what remains is CPU time.

## 4. Design

### 4.1 Clocks

The PLL gets a second output, `clk_cpu`, at exactly 100 MHz, phase-aligned
with `clk_sys` from the same VCO. At 2:1, with both edges known, the crossing
is synchronous: Quartus times every path between the domains, no synchroniser
flops are needed, and nothing is cut as a false path. A ratio that is not a
whole number (KI's, 1.5:1) needs the mailbox KI carries, ~7 clocks per access
(docs/39), which is why this plan targets 2:1 and nothing in between.

### 4.2 The boundary: `r4300_wrap` | `r4300_bus`

The CPU side (`r4300_wrap` and everything in `rtl/cpu/r4300/`) moves to
`clk_cpu`. `r4300_bus` and everything after it stays on `clk_sys`. The signals
that cross:

| direction | signals | handling |
|---|---|---|
| CPU -> bus | `mem_request`, `mem_rnw`, `mem_address`, `mem_req64`, `mem_size`, `mem_writeMask`, `mem_dataWrite`, `mem_dataWrite3` | registered in the CPU domain and held until the next `clk_sys` edge; a one-clock request is stretched to that edge |
| bus -> CPU | `mem_dataRead`, `mem_done`, `fill_grant`, `fill_data`, `fill_data_ready` | a `clk_sys` pulse becomes one `clk_cpu` pulse (edge-detected against a phase bit), so the caches see each fill beat once |
| bus -> CPU | `irq_lines`, `reset`, `boot_pc`, `INSTRCACHEON`, `DATACACHEON` | levels: one register in the CPU domain |
| CPU -> rest | `dbg_*` (beacon, perf counters) | strobes summed per `clk_sys` clock (0-2), so the counters stay exact; clocks per instruction then counts CPU clocks |

A phase bit - a `clk_sys` toggle sampled in `clk_cpu` - tells the CPU side
which of its two edges a `clk_sys` edge lands on. A request waits at most one
CPU clock for that edge and a reply arrives at most one CPU clock late:
~10-20 ns per transaction, *estimate*. Every crossing path is register to
register, so it fits in the 10 ns Quartus allows it.

### 4.3 The CPU's paths

Everything in `clk_cpu` must fit in 10 ns. Known: the trap -> `exceptionNew3`
-> `EntryHi` path (~17 ns). Likely, *estimate*: the 48-entry TLB match behind
the mini-TLBs, the physical tag compare in both caches, the 64-bit region
decode, the load/store alignment muxes, the multiplier and the divider. The
rule for each: cut it with a register where the extra clock lands on a rare
event (an exception, a TLB write, a mini-TLB miss); where it would land on
every instruction, restructure instead. The step 0 report ranks them.

### 4.4 Count

`cpu_cop0.vhd` advances `Count` every second clock, so it runs at 50 MHz on a
100 MHz CPU - half the pipeline clock, as on an R4600. IRIX measures its MHz
figure from `Count` ([cpu.md](../reference/cpu.md)), so `hinv` should read
100 MHz, and `bench/count_rate` should count 100,000,000 ticks in two seconds.
`calibrate_delay` and `DELAY()` use the 8254 and `MC_RPSS_CTR`, which stay on
`clk_sys`.

## 5. Budget, *estimate*

The boundary is ~440 registers (the 192-bit line write dominates), and the
CPU's new pipeline registers a few hundred: +300-800 ALMs. If that does not
fit, the debug beacon (~2,000 ALMs) is the first thing to make optional. At a
10 ns period the fit-to-fit scatter (~1.7 ns at 20 ns) matters more: expect a
seed sweep on m900.

## 6. Steps

One build at a time, each read before the next.

0. **Measure.** `quartus_sta` on build 53c's database: the CPU's internal paths
   against a 10 ns target, ranked. No fit.
1. **Shorten the CPU's paths at 50 MHz.** Same clock, so a functional slip is
   separated from the clock change. Gates: cpu-tests in the sim, the IRIX sim
   until init, then the board (cpu-tests, IRIX boot, DISKCHECK, X). Done when
   the fit's report shows every CPU-internal path under 10 ns.
2. **The crossing.** A two-clock bench for the boundary (random `clk_sys`-side
   latency, fills, uncached reads and writes, interrupts), and `sim_top` with
   a 2x CPU clock for run-prom and cpu-tests.
3. **100 MHz on the board.** cpu-tests, `count_rate`, `hinv`, IRIX boot,
   DISKCHECK, X, Ethernet, and perfprobe against build 53c as the same-night
   control (boot, login, `bzip2`, `ls`, perl).

## 7. Open

* `sim_top` and the Verilator harness drive one clock today.
* Anything inside the CPU that counts clocks as time - a stall watchdog, a
  timeout - halves in real time; read for it in step 1.
* If step 1 cannot reach 10 ns there is no cheap middle: the plan stops, and
  the CPU stays at 50 MHz.
