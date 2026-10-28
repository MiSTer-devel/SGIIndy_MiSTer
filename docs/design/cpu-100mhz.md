# A 100 MHz CPU - plan

Status: **stopped after steps 0 and 1a** (2026-10-28) - section 8 has the
measurements. The CPU's paths are logic-bound at ~11 ns median, and placement
under a 10 ns constraint recovers half a nanosecond; closing 10 ns means
re-pipelining the execute stage, which section 7's last line said would end
the plan. The CPU stays at 50 MHz. Sections 1-7 are the plan as written on
2026-10-24. Every figure comes from earlier fits and board counters, cited
where it is used. Numbers marked *estimate* are estimates.

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

## 8. Measured (2026-10-28): why it stops

**Step 0.** `quartus_sta` on build 54's database (seed 3, fitted for 20 ns),
every register-to-register path inside `u_cpu`, slack re-read against 10 ns:
**5,694 endpoints fail**, worst needs 17.3 ns. By logic alone (cell delay,
placement-independent): the one-clock 64x64 multiplier (9.9 ns, 47 levels),
the execute stage's `resultData -> forward mux -> address add -> region
decode -> D-cache index / mini-TLB / stall3` (5.7-6.5 ns, 17-25 levels), the
TLB read-out `COP0_0_INDEX_tlbEntry -> TLB_fetchAddrOut` (6.2 ns, 29 levels).
Everything else is 2-5 ns of cells under 8-12 ns of routing, so the open
question was how much of that routing a real 10 ns constraint would remove.

**Step 1a, the experiment.** The same RTL fitted once more with
`set_max_delay 10` on every CPU-internal path (SDC edit on the build machine
only). Placement moved by **0.48 ns on average** over 1,842 paths common to
both reports; **5,719 endpoints still fail**, worst -6.7 ns, median failing
data delay 11.5 ns over ~8 logic levels - on this speed grade ~8 LUT levels
is 10 ns, so these are depth, not slack. The failing set by root:

| root | failing endpoints | what it is | fix class |
|---|---:|---|---|
| `stall1` -> `TLBSH_*` | 2,352 | write enables of the 48-entry shadow TLB | a one-clock-late TLB write (cheap, hazard-covered) |
| `resultWriteEnable`/`resultData` -> execute | ~700 | forward mux -> adder/ALU/compare -> `PC`, `TLB_fetchAddrIn`, `resultData`, `mem1_address`, D-cache index: 11-17 levels, median 13.7 ns | **re-pipeline the execute stage** |
| fetch: `FetchAddr1` mux -> `TLB_instrMapped` -> `FetchIndexPhys` -> MLAB tag -> compare -> `stall1`/`instrcache_fill` | ~100 | the single-cycle I-cache hit on every instruction, 14-15 levels | restructure the fetch (speculative index + verify) |
| `mul2 -> prod` | 103 | the 64x64 multiply in one stage | rebalanced (below) |
| exception address -> BadVAddr/EntryHi/Context/XContext | ~140 | forward mux + adder fanning into four 64-bit registers | capture one clock late (below) |
| the rest | ~2,300 | FPU divider/shifter, hi/lo, decode-gated enables, RAM address registers, TLB state machines | dozens of individual cuts |

There is no cheap middle either. From the same report, CPU-internal
endpoints failing at other periods: 90 MHz 4,536; **80 MHz 1,676; 75 MHz
857**; 70 MHz 484; **60 MHz 2**. A 1.5:1 clock would need KI's mailbox
(~7 clocks per access, docs/39) and still leave ~850 paths to cut.

**What was built and kept out of the branch.** Two of the logic-bound items
were rewritten as behaviour-preserving changes and passed the sim gates
(cpu-tests 2259/0 on 246 tests, same as the baseline; run-prom; the IRIX 5.3
sim boot): `prim/cpu_mul.vhd` rebalanced into partial products + sum within
its two stages (the FPU reads the product at exactly two clocks), and
`cpu_cop0.vhd` writing BadVAddr/EntryHi/Context/XContext one clock after the
exception from a registered address. At 50 MHz they buy nothing - the core
clock is bound outside the CPU (`mc_gio_dma`/`np_rex3`/`r4300_bus` ->
`ddr3_mux`, section 2) - so they live as
`sgi-board-tools/cpu-step1-rtl.patch` for whoever reopens this, not on the
release branch.

**What reopening would take.** Roughly: the TLB write delay (one day), the
multiplier and exception capture (done), then the execute stage split into
address/ALU and cache/TLB halves with the forwarding network moved a stage
earlier, the fetch restructured around a speculative physical index, and the
FPU divider/shifter and hi/lo paths cut one by one - each step gated by
cpu-tests, the IRIX sim boot and a 45-minute fit, with IRIX's own TLB and
cache hazards as the correctness oracle. That is a new CPU pipeline, not a
step of this plan. The gain it would buy is still the 1.3-1.5x of section 3.
The data: `sgi-board-tools/cpu-step0/` and `cpu-exp1/` (paths, levels,
the Tcl that made them).
