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
