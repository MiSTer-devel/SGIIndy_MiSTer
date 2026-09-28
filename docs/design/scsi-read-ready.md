# SCSI: DATA IN capture, and the DMA engine's stop and go

## DATA IN: capture the byte when it is ready

**The bug.** Installing IRIX 5.3 from the CD, `inst` stopped at 79 % on a bad
checksum: in one file the last word of a 512-byte block arrived with **bytes
508-509 carrying the values of bytes 510-511**, the same on every retry.

**The cause.** A target's byte comes from `scsi.v`'s sector buffers
(`scsi_dpram`: one read port plus two look-ahead registers). The look-ahead is
refilled by briefly stealing the read port, and a write from the HPS side into
an address the look-ahead holds re-arms a steal. The WD33C93B model captured a
byte a fixed six clocks after REQ, without checking the buffers were current,
so a capture landing in a stolen clock took the next word's byte.

**The fix.**
* `scsi_dpram` exports `rd_ready` (the read port holds `address_b`'s data and
  the look-ahead is valid and idle); `scsi.v` exports `dout_ready` for a
  READ's DATA phase.
* `wd33c93.sv` waits after the settle until `dout_ready` before taking the
  byte and the look-ahead (at most 63 clocks, counted if it gives up).
* Hidden switch `dinstrict=off` (`status[20]`, `scripts/setopt.sh`) restores
  the old capture; beacon word 46 counts waits and not-ready captures.

**Board A/B** (build 45b), copying the same CD file under IRIX and comparing
with the ISO (`scripts/cdfile.sh`): the old capture made 2 captures while not
ready and **1 byte wrong at block offset 508**; the guard, 0 and an identical
file.

## The DMA engine's stop and go (build 46)

`hpc3_scsi_dma.sv` took a PIO stop, FLUSH or ch_reset by moving its state
machine directly. Against a memory that answers late (`verilator/tb_scsidma.sv`
models ram_arb and the DDR3 round trip; the whole-machine sim's memory answers
too fast to show it):

* FLUSH dropped ACTIVE before the held bytes were written, while IRIX's
  `wd93dma_flush` waits on ACTIVE to know the buffer is complete;
* a stop left a memory request in flight, and the next go took its
  acknowledge as the new descriptor's first word - a stray write;
* a stop in the same clock as the engine's own transition was lost.

Stop, FLUSH and ch_reset are now requests the engine finishes in order (owed
acknowledge, pending advance, held bytes, idle); a go waits for that, and
ACTIVE reads 1 until a FLUSH has drained. `tb_scsidma`: 26 checks and 4,000
random stop/FLUSH/go sequences, 7 failures before, 0 after.

## The "stray write" that was not

`diskcheck` occasionally found a file on the image that differed from what
IRIX had checksummed. The cause was the checker: IRIX's `efs_writeindir`
writes an indirect extent block without clearing past its `numextents`
entries (a real Indy does the same), and `tools/misterdeploy/efsread.py` read
the stale tail as extents. It now honours `di_numextents`.
`verilator/tb_scsi_cache_big.sv` (the block cache over a whole disk with
self-describing sectors) found no fault in the cache either.
