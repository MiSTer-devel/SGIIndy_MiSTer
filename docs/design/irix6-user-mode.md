# IRIX 6: user mode with Status.UX = 1 under a KX = 0 kernel

## The bug

**IRIX 6.5's installer died in its miniroot**: the kernel booted, mounted `/`
cleanly, and panicked with `init died (why = 3, what = 0xb)` - init took
SIGSEGV. IRIS runs the same install. The 20260918 release (build 44) fails the
same way, so it predates the prefetch work; a fresh disk partitioned by the
6.5 `fx` changes nothing.

**init's own exception frame says what happened.** Found in a RAM dump of the
board after the panic (the eframe beside the n32 Status `0x0400ff33`):

| | value | |
|---|---|---|
| EPC | `0x0fa5f5e8` | the `syscall` in libc's `_getuid` (`li v0,1024 ; syscall`) |
| v0 | `0x400` | getuid |
| Cause | `0x8` | TLBL, no interrupt pending |
| BadVAddr | `0x80000180` | the general exception vector's own address |

A syscall turned into a TLB miss on the address of the handler it was going
to.

**Why only IRIX 6.** IRIX 6 runs n32 processes with `UX = 1` under a 32-bit
kernel with `KX = 0`, so every exception and every ERET switches between 64-
and 32-bit addressing. IRIX 5's o32 processes run with `UX = 0` and the
cpu-tests suite with `KX = SX = UX = 1`: neither ever switches.

**The mechanism.** `cpu_cop0.vhd`'s `bit64mode` (= `region64`) is refreshed
only when an instruction reaches execute, so it describes the instruction
ahead of the one being decoded. After an ERET into the process, the first
instruction (`li`) reaches execute on the same clock the second (`syscall`)
traps. The vector block still sees the kernel's `KX = 0` and builds
`0x00000000_80000180` (it zero-extended in 32-bit mode); one clock later the
fetch sees `UX = 1`, takes that for an xuseg address, walks the TLB and
misses. EXL is already set, so the miss is "nested": EPC stays on the syscall
and Cause is overwritten with TLBL. `_getuid` is entered straight from an ERET
whenever its page's instruction-TLB refill (or an interrupt) returns to the
`li`.

## The fix (build 50)

- **Exception vectors are always sign-extended** (`0xFFFFFFFF_8000xxxx`,
  `0xFFFFFFFF_BFC00xxx`). Both 32- and 64-bit kernels reach them that way, so
  the stale mode bit no longer matters to the fetch.
- **The refill vector follows the faulting access's own mode**: `bit64now`
  (KX/SX/UX of the current privilege level, straight from Status) is sampled
  into `excBit64` with `excSavedEXL`, and picks 0x000 or the XTLB 0x080.
- **64-bit User mode faults above xuseg.** The User arm of the 64-bit region
  decode set nothing for other addresses, which made them unmapped physical
  accesses: a `UX = 1` process could read KSEG0.
- **32-bit User mode: `calcMemAddr(31 downto 29) < 8` removed.** A 3-bit slice
  against a 4-bit constant; GHDL lowered it to `< 3'b000`, so the simulated
  core never raised the address error.

## Tests

cpu-tests group `umode` (IRIS branch `claude/ux-user-tests`): a few words at
kuseg `0x00400000` in User mode under `all64`, `irix5` and `irix6` Status
settings, every exception recorded (vector, Cause, EPC, BadVAddr, Context,
XContext, EntryHi). IRIS main passes 17/17 tests (352 checks).

| | before | after |
|---|---|---|
| `umode/syscall_second` (irix6) | TLBL at `0x80000180`, EPC on the syscall - init's frame | PASS |
| refill vector, UX = 1, first instruction after ERET | 0x000 | XTLB |
| User load from KSEG0 | read `0x241b0001` from physical 0 | AdEL |
| full suite in sim | 250 tests 0 failed; umode 43 failed | 262 tests, 3 failed |
| full suite on the board (.143) | 255 tests 0 failed (build 49c) | 267 tests, 2752 passed, 3 failed |
| IRIX 6.5.22 install, board | init died after the root mount | miniroot up, mkfs, `Inst 4.1 Main Menu`, product list read |
| IRIX 6.2 install, board | hung after the root mount | miniroot up, csh + mkfs, `Inst Main Menu` |
| IRIX 5.3 boot, board (fresh pristine copy) | X, login, menus | the same; `init 0` clean |

Released as `releases/SGIIndy_20260928.rbf` (build 50: m900, seed 5,
BUILD_DATE 260928, md5 `95644161bee37082891c34cdb92c601c`), with build 49c's
menu fix underneath.

One install-time note, not a CPU matter: 6.5's mkfs on a freshly created 4 GB
image hit `wd93 ... cmd=0x2a timeout after 60 sec` once - a 256 KB WRITE at
LBA 4,336,160 stalled after 1 KB (`wr_pend`) and completed after the bus reset.
The first write that far into a new image file is the likely cost (exFAT
fills the gap below it); 6.2's mkfs of the same partition afterwards did not
stall.

The 3: `umode/fetch_miss_entry`. An instruction-TLB miss on an ERET's target
is still taken as nested (general vector, EPC unchanged - which is already the
target). The fetch starts while the ERET is in decode, with EXL still set.
IRIX handles it as a slow-path TLBL, as it always has on this core.
