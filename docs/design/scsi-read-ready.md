# SCSI DATA IN: capture the byte when it is ready, not after a count

## The bug this is for

Installing IRIX 5.3 from the CD on build 44, `inst` stopped at 79 % because
`/usr/share/data/sounds/prosonus/sfx/alarm_clock.aiff` came out of
`/dist/dmedia_tools.data` with a bad checksum - the same wrong checksum on every
retry. The ISO is good. Two bytes differed: the last 32-bit word of a 512-byte
block (bytes 508-511) arrived as `0b42 0b42` instead of `0550 0b42`. **Bytes
508-509 carried the values of bytes 510-511**; everything else in thousands of
files was right. A second, rarer symptom - a file nobody wrote changing on disk
(`stray-write`) - has been seen once in eleven board sessions.

## The mechanism this build tests

The byte a SCSI target sends comes from `scsi.v`'s sector buffers: two byte-wide
RAMs, even bytes in `buffer0` and odd in `buffer1`, word `data_cnt >> 1`.
Each buffer is a `scsi_dpram` with one real read port (B) and two look-ahead
registers, `q_c` and `q_d`, holding the next two words. The look-ahead is
filled by **stealing port B**: for a clock or two port B reads `address_c` or
`address_d` instead of `address_b`, and in those clocks `q_b` - the byte the
target is putting on the bus - holds the NEXT word's byte.

The controller steals after every change of address (every word the target
sends) and **again whenever a port-A write lands on an address the look-ahead
holds**. Port A is the HPS side: the next sector being filled into the ring.
At the end of a ring slot the look-ahead addresses run into the slot the HPS is
filling, and every such write re-arms a steal.

The WD33C93B model captured a DATA IN byte a fixed six clocks after it saw REQ
(`DIN_SETTLE`, measured: 4 was the minimum that passed `run-scsiwr.sh`), and
since build 36 took the next three bytes from `q_c`/`q_d` at the same moment
(`DIN_LOOKAHEAD`). Neither looked at whether the buffers were current. A
capture that lands in a stolen clock takes the next word's byte; a look-ahead
taken while the registers are being refilled takes the old ones. Taking bytes
508 and 509 during steals that fetched word 255 gives exactly `508 <- 510,
509 <- 511`.

## The change

* `scsi_dpram` exports **`rd_ready`**: port B's last read was `address_b`
  itself, no port-A write collided with it, and the look-ahead controller is
  idle with `q_c`/`q_d` valid for the current `address_c`/`address_d` and no
  write landing on them this clock.
* `scsi.v` exports **`dout_ready`** = both buffers ready, for a READ's DATA
  phase (every other source is combinational from the byte counter and is
  always ready).
* `wd33c93.sv` **waits after the settle until `dout_ready`** before taking the
  byte, and takes the look-ahead only when it is ready too. It gives up after
  63 clocks rather than hang, and counts that.

## The instruments, and the A/B

Two hidden switches (no OSD entries; `scripts/setopt.sh`):

| setting | status bit | what it is |
|---|---|---|
| `dinstrict=off` | 20 | build 44's capture: the count alone |
| `lookahead=off` | 19 | no look-ahead: every byte settles on its own, as before build 36 |

Beacon word 46 (`bcnread.py --stats` prints it as `din:`): clocks the capture
waited for the buffers, captures made while they were NOT ready (only possible
with `dinstrict=off`, or when forced), and forced captures.

`scripts/cdfile.sh` copies `/dist/dmedia_tools.data` off the CD under IRIX the
way the installer reads it, halts, and compares the copy with the ISO byte by
byte on the board. Run it with `dinstrict=off` first: if the corruption comes
back and the `din:` line shows captures while not ready, this is the bug;
then with the defaults, which must be clean with zero forced captures.

## Results

Build 45b (commit 6fd7ffc, rbf md5 `64cdbdc3f39bbf900b545906c66936b8`), board .92,
2026-09-27, each arm from the pristine image with the IRIX CD at ID6:

| arm | `din:` over the boot and the copy | the copy |
|---|---|---|
| `dinstrict=off` (build 44's capture) | 0 waited, **2 captures while not ready**, 0 forced | **1 byte differs**, +0x0ae47fc = byte **508** of its 512-byte block (`06004400`, disc `21004400`) |
| defaults (guard on) | 6 clocks waited, 0 not ready, 0 forced | identical, md5 `32841042d879fcb36a22d21eb6794b8f` |

The control reproduces the fault at the block offset the build 44 install hit,
with the counter saying why; the guard removes it. Over each boot's ~41 MB of
disk reads the guard never had to wait - the window is the CD target's, where a
2048-byte logical block is four host blocks behind one look-ahead.

Two harness faults cost the first A/B and are fixed in the scripts: Software
Manager opens after a root login when the CD is in the drive and took the typed
commands (`scripts/desktop.sh` quits it), and `efsread.py` does not follow
`/usr/tmp`'s symlink (the copy now goes to `/var/tmp`). Evidence:
`tests/out/hw/b45b-2/`, `tests/out/hw/b45b-3/`.

## The DMA engine's stop and go (build 46)

A separate hazard, found looking for the stray write (a file nobody wrote,
changed, once in eleven board sessions). `hpc3_scsi_dma.sv` took a PIO stop,
FLUSH or ch_reset by moving its state machine directly, and against a memory
that answers late - `verilator/tb_scsidma.sv` models ram_arb's grant and the
DDR3 round trip; `sim_ram.v` answers in a clock or two, which is why no
whole-machine test ever saw this - three things went wrong:

* FLUSH cleared ch_active on the write, with the held bytes' memory cycle still
  tens of clocks away. IRIX's `wd93dma_flush` (kernel.o, IP22) is `ctrl |=
  FLUSH; while (ctrl & ACTIVE)` - ACTIVE going low is its word that the buffer
  is complete.
* A stop left a memory request in flight with the engine idle; a go edge then
  took that request's acknowledge as its new descriptor's first word. With a
  descriptor fetch in flight that is a **stray write**: the new transfer's
  bytes landed in the abandoned descriptor's buffer.
* A stop in the same clock as one of the engine's own transitions was
  overridden, leaving the engine running with ch_active low.

Now stop, FLUSH and ch_reset are requests the engine takes (`stop_req`): it
lets an owed acknowledge arrive, finishes a moved byte's advance, writes the
held bytes (not after ch_reset), then idles; a go edge waits in `go_pend` for
that; ch_active reads 1 until a FLUSH has drained, and a go edge is not taken
while it does (so IRIX's read-modify-write of the register cannot start a
transfer). The bench: 26 checks and 4,000 random stop/FLUSH/go sequences, 7
failures before, 0 after. In IRIX's own flow many WD33C93 accesses sit between
a stop and the next go, so these windows are narrow; this is a hazard
removed, not yet a proven cause of the stray write.

## The "stray write" was the checker (2026-09-27)

`diskcheck` failed twice on build 46 the way it had once on build 41: a file
IRIX had checksummed correctly (`sum` in the session agreed with the true
file) read back different off the image afterwards - libX11.so.1, then
libXm.so.1. The second time the used image was kept (`diskcheck.sh` now keeps
it, with `efsdiff`, on any failure), and none of libXm's data blocks had
changed. Its **indirect extent block** had: past the 34 real extents (272
bytes) the rest of the 512-byte block held the tail of a directory block, the
`/dev/hdsp` entries (`hdsp0master`, `hdsp0r17` ... `..`, `.`).

IRIX does that itself. `efs_writeindir` (efs.a, efs_inode.o) takes the block
with `getblk`, `bcopy`s `numextents * 8` bytes of its in-core extents into it
and writes it - without clearing the rest, so the tail is whatever the buffer
held last. A real Indy writes the same bytes, and IRIX never reads past
`numextents`. `tools/misterdeploy/efsread.py` did: it took every nonzero
entry in the block as an extent, followed 27 of them into other blocks, and
handed `sumcheck` a different file. With `efsread` reading only
`numextents` entries the kept image's files are the pristine ones and
`diskcheck`'s own checker on it passes. All four files it sums have indirect
extents (18-36), which is why the "failure" was rare, moved between files,
and always had IRIX's own checksum right. `efsdiff.py` already knew this
("extent block tail rewritten"); `efsread.py` never did.

Two instruments came out of the hunt and one stays:

* `verilator/tb_scsi_cache_big.sv` - the block cache over a whole disk with
  every sector carrying its LBA and write generation, so the device checks
  each flushed sector lands at its own LBA. 3 x 150,000 random operations
  across 2 GB with the bypass toggled: no stray, torn or stale sector.
* A SCSI command log (every command's opcode, target, length and LBA into a
  DDR3 ring, `tools/misterdeploy/scsilog.py`) was built and sim-gated for
  build 47 (commit 1f53475) to tell "IRIX sent a WRITE there" from "the write
  came from below". With the cause found it was taken out again - the device
  is 89 % full - and is there to cherry-pick if a disk question ever needs it.
