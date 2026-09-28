# Audio: HAL2, HPC3's PBUS DMA, and the DAC

The sample path behind HAL2's register file: PBUS DMA channels 0-3 feeding
HAL2's ports, and codec A out to the MiSTer's audio. Before it, HAL2's revision
register reported "no audio" (bit 15 set), because IRIX's driver wedged the
desktop on the first sound when the DMA engine did not move.

## What the software needs

Read out of IRIX 5.3's `kdsp_a2.o` (`/usr/cpu/sysgen/IP22boot/`) and the IP24
PROM, both disassembled:

* **The driver loads only if HAL2's revision (`0x1FBD8020`) has bit 15 clear**
  (`exprobe` in `/var/sysgen/system/audio.sm`).
* **IRIX's rings are one self-linked descriptor each** (no EOX, no XIE), never
  stopped; `hal2_stop_dma` relinks the descriptor to a silent buffer.
* **The driver's only clock is the engine's progress**: it reads `pbus.bp` and
  takes `(bp - ring_base) / 4` as the ring position. A `bp` that does not move
  is what hung the desktop. Nothing uses the PBUS DMA interrupt.
* 32-bit indirect registers are read one half at a time through IAR bits 1:0.
* Output volume is PBUS PIO channel 2: right `0x1FBD8800`, left `0x1FBD8804`.
* **The PROM's startup tune** starts channels 1 and 2 on the same EOX chain
  (codec A and AES TX, 44.1 kHz mono) and waits for both to go inactive. It
  reads the raw NVRAM `volume` field before the environment defaults are
  written, so `sgi_ds1386.sv` seeds "80" into an empty NVRAM
  ([nvram.md](../reference/nvram.md)); without it the tune plays nothing.
  Samples are stored as `sample << 8`: the DAC takes bits 23:8.

## The design

```
 CPU PIO ──> sgi_hpc3 ──┬──> hpc3_pbus_dma   bp / dp / ctrl, channels 0-3
                        └──> hal2            registers, 3 Bresenham clocks,
                                             4 ports, output ──> AUDIO_L/R
 main memory <── sgi_hpc3's one DMA port <── {hpc3_scsi_dma, hpc3_pbus_dma}
```

* **`rtl/sgi/hpc3_pbus_dma.sv`**: per channel `cbp`, `nbdp`, byte count,
  EOX/XIE, interrupt. Descriptors are fetched from memory when reached; two
  words in one aligned doubleword (a stereo frame) are one memory transaction.
  A PIO write to the active channel wins over the engine's own update.
* **`rtl/sgi/hal2.sv`**: the register file with IRIS's reset values; 48 and
  44.1 kHz master clocks as exact averages of the core clock; three Bresenham
  generators; four ports (codec A out, codec B in, AES TX out, AES RX in),
  scheduled round-robin through the engine. The inputs write silence, which
  keeps IRIX's input ring moving. Codec A's attenuation, mute and the volume
  registers form the output stage.
* **`sgi_hpc3.sv`** claims PBUS PIO channels 0-3 for HAL2 and alternates its
  one memory port between the SCSI channel and the PBUS engine.
* **OSD "Audio: On/Off"** (`status[18]`): Off makes HAL2 read absent - no tune,
  no driver, a silent DAC.

## Existing disk images need a relink once

lboot links `kdsp_a2` only when the HAL2 probe passes, and images installed on
older cores were linked while HAL2 read absent: their `/unix` has no audio
driver. Once, as root: **`/etc/autoconfig -f`, then reboot**. A fresh install
on this core links it from the start.

## Tests

* `make -C verilator audiotest`: `sgi_hpc3` against a memory with random
  latency - IRIX's self-linked ring, the PROM's EOX chain across 4 KB, codec B
  silence, odd-word buffers, stopping a channel, the OSD switch.
* `make -C verilator hal2test`: HAL2's register file.
* `tests/run-audio.sh`: the PROM's startup tune recorded off the DAC in the
  whole-machine simulator and checked sample for sample against
  `tools/prom_tune.py`, which decodes it from the PROM image independently.
* Board: `scripts/audioprobe.sh` (plays a file under IRIX and samples the
  beacon's audio words, `bcnread.py --audio`).
