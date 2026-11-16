# SCSI

Three pieces, only one of which is written here:

| | What | Where from |
|---|---|---|
| **Target** | `scsi.v` — a target-only SCSI device: the bus phase machine, REQ/ACK, and the disk command set (TEST UNIT READY, INQUIRY, READ CAPACITY, MODE SENSE/SELECT, REQUEST SENSE, READ/WRITE 6 and 10, FORMAT). Reads and writes blocks through MiSTer's `sd_lba`/`sd_buff_*` interface. | Vendored from the MacLC MiSTer core |
| **Initiator** | `wd33c93.sv` — the WD33C93B the Indy actually has, and `sgi_scsi.sv`, which decodes its two ports off the bus and arbitrates between the targets | Written here |
| **DMA** | the HPC3 SCSI DMA engine | `sgi_hpc3.sv` |

## Why a Mac core's SCSI target works on an SGI

A SCSI target does not know or care what kind of machine is driving it. It sees
selection, then REQ/ACK byte handshakes through COMMAND, DATA, STATUS and
MESSAGE phases, and it answers with the standard command set. `scsi.v` is
written as a target only — the Mac-specific parts of that core live in its
initiator (`ncr5380.sv`), which is exactly the piece being replaced here.

Everything Mac-flavoured in `scsi.v` is behind a parameter that defaults off:
`TOOLBOX_ENABLE` (BlueSCSI Toolbox), `CDROM` and `CDCHANGER_ENABLE` (AppleCD
command set and CD audio, which pulls in `cd_audio.sv` through a
`generate`). A plain disk target needs none of them.

`scsi_vendor.vh` sets the 8-byte INQUIRY vendor string. It is deliberately a
separate file so a build can change it without touching tracked source.

`cd_audio.sv` here is **ours, and a stub** — it is not the MacLC engine. The
real one is only reachable through `generate if (CDROM != 0)` and pulls in a
volume lookup table this core has no use for, so what is checked in is the
`g_no_cd_audio` tie-off branch wearing the `g_cd_audio` port list. That is what
lets a CD-ROM elaborate without vendoring the engine and without forking
`scsi.v`. READ TOC answers zeroes and the audio commands are no-ops; the data
path is untouched. See `docs/FEATURES_EVALUATE.md`.

## Phase encoding

`scsi.v` names its phases from the target's point of view, which reads
backwards from the initiator's. The `msg`/`cd`/`io` outputs are standard, so
decode those rather than the names:

| `scsi.v` phase | msg,cd,io | SCSI phase | Direction |
|---|---|---|---|
| `PHASE_CMD_IN` | 0,1,0 | COMMAND | initiator → target |
| `PHASE_DATA_IN` | 0,0,0 | DATA OUT | initiator → target |
| `PHASE_DATA_OUT` | 0,0,1 | DATA IN | target → initiator |
| `PHASE_STATUS_OUT` | 0,1,1 | STATUS | target → initiator |
| `PHASE_MESSAGE_OUT` | 1,1,1 | MESSAGE IN | target → initiator |

## `scsi.v` is no longer pristine

Two local changes, marked in the source with `SGI LOCAL CHANGE` at every hunk
so a re-vendor can find them.

**A READ's next three bytes are an output** (`dout_ahead_read`,
`dout_ahead_ok`; docs/design/r4600-accuracy-clock-disk.md §10). The WD33C93B model takes a DATA IN byte with
the three after it so that three bytes in four skip the settle for the
buffer's look-ahead prefetch. The bytes are the sector buffers' own `q_b` /
`q_c` / `q_d` terms, exactly the READ arms of `cmd_dout_pair` and
`cmd_dout_pair_next`. The existing `dout_pair` / `dout_pair_next` outputs carry
the same bytes but for every command, and connecting them builds every
response ROM three bytes further on: +2,249 ALMs over the three targets, 99 %
of the device. Two assigns and two ports; nothing inside the target changes.

And the older one:

**The CD-ROM logical block size follows MODE SELECT instead of being hardwired
to 2048.** Upstream reads the block descriptor's *length* and discards its
contents, so a drive stayed at 2048 whatever it was told. IRIX will not accept
that — an SGI install CD is a 512-byte volume-header disc, and `dksc` switches
the drive to 512 for EFS and back to 2048 for ISO 9660. IRIS models the same
switch in `src/scsi.rs`.

The failure it caused was silent, which is why it is worth the divergence: the
drive read the wrong blocks *successfully*. `sashARCS` lives at 512-block
52875, and a drive stuck at 2048 fetched byte 108288000 instead of 27072000.

Six sites move: the new `cd_blklen` register and its `cd_lba_shift`, the
capture out of the MODE SELECT block descriptor, `capacity` (now derived rather
than latched at mount, because the block size can change after a medium is in),
the READ CAPACITY block-length byte, the MODE SENSE block-length byte on the
three CD pages, and the LBA/transfer-length scale at command latch.

## The block port

`sgi_scsi.sv` wires its three slots to IDs 1, 2 and 6 and passes one
target's sector request at a time to hps_io, one sector per transaction:
`scsi.v` writes its buffer on `sd_buff_wr` without looking at its own ack, so
the shared buffer bus is safe only while one transaction is live.

Builds 26-51 had a block cache here (`scsi_cache.sv`, ported from
MacQuadra800_MiSTer). Main_MiSTer's write buffer (`support/sgi/sgi_disk.cpp`)
took over its job, and build 52 removed it for the ALMs and M10K Ethernet
needed; docs/design/scsi-block-cache.md has the measurement.

`sgi_scsi.sv` also counts, for the DDR3 beacon (`bcnread.py --stats`):
hps_io transactions by direction, cycles with one outstanding, cycles a
target spent waiting on its block port, cycles the SCSI bus was busy and in
a DATA phase, and bytes across it. Two readings a boot apart are the boot's
disk time. The harness `sim_scsi.h` still serves multi-sector runs the way
Main does (`user_io.cpp`: `blks = ((c >> 9) & 0x3F) + 1`).

## Provenance

`scsi.v` and `scsi_vendor.vh` are taken from the MacLC MiSTer core, which
carries no per-file licence header. **`cd_audio.sv` is not** — it is written
here, and only borrows the port list and the constants of the branch it
replaces. They are used here on the
understanding that both cores are the same author's work. Anyone republishing
this repository should confirm that before shipping.
