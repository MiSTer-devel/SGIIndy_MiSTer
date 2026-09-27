# Audio: HAL2, HPC3's PBUS DMA, and the DAC

Before this, the core had HAL2's register file and nothing behind it, and it
said so: HAL2's revision register had bit 15 set - "no audio" - because with
it clear IRIX loaded its audio driver, and the driver wedged the desktop the
first time anything made a sound (the System Shutdown confirmation, the console
bell). This note is how the sample path was built, what the guest software was
read to need, and how it is tested.

## What the software needs, read out of the software

The HAL2 and HPC3 specifications describe the chips; what matters here is what
the IP24 PROM and IRIX 5.3 actually do with them, so both were disassembled.
IRIX's driver is `/usr/cpu/sysgen/IP22boot/kdsp_a2.o`, an ECOFF relocatable
object pulled off a disk image with `tools/misterdeploy/efsread.py`; the
relocation-aware disassembly is `tools/misterdeploy/ecoffdis.py`.

### IRIX 5.3, `kdsp_a2`

* **`hal2_probe`** configures PBUS PIO channels 0-3 (`0x1FBDD000 + n*0x100`)
  and PBUS DMA channels 0-3 (`0x1FBDC000 + n*0x200`), then reads HAL2's
  revision at `0x1FBD8020` and loads only if bit 15 is clear. That is the
  `exprobe=(r,0xBFBD8020,2,0x0000,0x8000)` in `/var/sysgen/system/audio.sm`.
* **`hal2_init`** releases the chip's resets (ISR = 0x18) and programs, through
  IAR/IDR, spinning on ISR bit 0 after every transaction:

  | indirect register | value | meaning |
  |---|---|---|
  | DMA enable `0x9104` | `0x1E` | all four ports |
  | DMA endian `0x9108` | `0x00` | big-endian |
  | DMA drive `0x910C` | `0x0F` | PBUS channels 0-3 |
  | codec A ctrl1 `0x1404` | `0x210` | PBUS channel 0, clock 2, stereo - the output |
  | codec B ctrl1 `0x1504` | `0x209` | channel 1, clock 1, stereo - the input |
  | AES RX ctrl `0x1204` | `0x002` | channel 2, no clock |
  | AES TX ctrl `0x1304` | `0x213` | channel 3, clock 2, stereo |
  | BRES1-3 ctrl1/ctrl2 | `0`, `{1, 0xFFFF}` | all three at 48 kHz |

  and then writes the output volume, 0..255, to PBUS PIO channel 2:
  **right at `0x1FBD8800`, left at `0x1FBD8804`** (`hal2_volumectrl`,
  `dezipper_output_atten`; the audio panel's "Left Output Gain" goes to +4).
* **`hal2_start_dma`** builds **one descriptor per ring whose next pointer is
  itself** - no EOX, no XIE - writes `pbus.dp`, then `pbus.ctrl` with
  `real_time | ch_act_ld | ch_act`. The channel is never stopped again:
  `hal2_stop_dma` rewrites the descriptor in memory to point at a short silent
  buffer and lets the engine walk onto it. So the engine fetches every
  descriptor from memory when it reaches it.
* **The driver's only clock is the DMA engine's progress.** `kdsp_timercallback`
  reads `pbus.bp` and takes `(bp - ring_base) / 4` as the ring position it
  moves samples against. Nothing uses the PBUS DMA interrupt. A `bp` that does
  not move is what hung the desktop in 2026-09 (`transfer_samps` computed a
  negative count and zeroed its ring with interrupts off).
* **`hal2_write_codec_regs` reads a 32-bit indirect register one half at a
  time**: IAR = `0x1488` then IDR0 holds the low word, IAR = `0x1489` then IDR0
  holds the high word. IAR bits 1:0 are a read-back index - Linux's
  `hal2_i_look32` does the same. IRIS ignores them, which is harmless there
  because nothing downstream uses the value.
* `force_dma_frame` starts a channel and spins with no timeout until it goes
  inactive. It is only reached for AES input, which IRIX leaves without a
  clock, so it is not reached; if it ever is, the channel must be consumed.

### The IP24 PROM

* **0xBFC00BD0**, early init when HAL2 is present: AES TX ctrl `0x10A`
  (channel 2, clock 1, mono), BRES1 at 44.1 kHz.
* **The startup tune, 0xBFC030B4**: codec A ctrl1 `0x109` (channel 1, clock 1,
  mono), DMA enable `0x0C` (codec A and AES TX); the NVRAM `volume` variable
  (default "80") to both volume registers; an ADPCM tune decoded into RAM by a
  routine copied there (0xBFC032CC); a descriptor chain split at 4 KB
  boundaries with EOX on the last; **channels 1 and 2 both started on the same
  chain**; and a wait of up to 3000 x 1 ms (0xBFC03578) for **both** to go
  inactive. Codec A drains channel 1 and AES TX drains channel 2, both at
  44.1 kHz mono, so they finish together.
* **The tune reads the raw NVRAM `volume` field (PROM offset `0xE8`) before
  the environment check writes the defaults** - the tune is called at
  0xBFC02180, the check at 0xBFC02188. A real Indy's battery keeps "80" there;
  this core's NVRAM is empty after every load, so the first simulated boot
  played nothing at all (zero descriptors fetched) while `hinv` listed the
  audio processor. `sgi_ds1386.sv` now seeds "80" into the empty field on the
  first reset after a load ([nvram.md](../reference/nvram.md)).
* The decoder stores each sample as **`sample << 8` in a 32-bit word**
  (0xBFC0346C): the sample is bits 23:8. IRIS takes the same bits.
* Tunes: 0 at power-on (0xBFC02180), 1 from three places, 2 from 0xBFC048FC;
  the Command Monitor's `play <tune #>` plays any of them.

## The design

```
 CPU PIO ──> sgi_hpc3 ──┬──> hpc3_pbus_dma   bp / dp / ctrl, channels 0-3
                        │        ▲  x_* : "one or two words of channel n"
                        └──> hal2 ┘  registers, 3 Bresenham clocks, 4 ports,
                                     output stage ──> AUDIO_L / AUDIO_R
 main memory <── sgi_hpc3's one DMA port <── {hpc3_scsi_dma, hpc3_pbus_dma}
```

**`rtl/sgi/hpc3_pbus_dma.sv`** - PBUS DMA channels 0-3. Per channel: `cbp`,
`nbdp`, a 14-bit byte count, EOX/XIE, running, interrupt, and "needs a
descriptor". Starting a channel marks it as needing a descriptor, which the
engine fetches from `nbdp` (two doubleword reads) before anything else. A
consumer asks for one or two words; **two words in one aligned doubleword of
the current buffer are one memory transaction** - a stereo frame is one
transaction, as it is one GIO64 beat on the real machine. At the end of a
buffer the engine goes inactive on EOX or fetches the next descriptor at once,
so `bp` and `dp` always describe the buffer being played. A PIO write to the
channel the engine is working on wins: the engine drops its own update.
Channels 4-7 stay plain storage in `sgi_hpc3`'s M10K store.

**`rtl/sgi/hal2.sv`** - the chip:

* the register file, with the read-back index, IRIS's reset values and its
  global and codec resets (ISR bits 3 and 4 low);
* two master clocks, 48 kHz and 44.1 kHz, as exact long-run averages of the
  core clock, and three Bresenham generators dividing them by
  `mod = inc - modctrl - 1`;
* four ports - codec A out, codec B in, AES TX out, AES RX in - each running
  while its DMA enable bit is set and its ctrl1 names a clock and a mode.
  Every tick of its clock a port owes a frame (1, 2 or 4 words for mono, stereo,
  quad); a round-robin scheduler moves owed frames through the PBUS engine one
  at a time. The inputs write silence, which is what keeps IRIX's input ring
  moving; AES output is read and dropped;
* codec A plays the frame fetched at its previous tick (one frame of latency,
  standing in for HAL2's FIFO), taking bits 23:8 of each word;
* the output stage: codec A ctrl2's attenuation (left 11:7, right 6:2 of the
  high word, 1.5 dB steps) and mute (bit 10 of the low word), as Linux uses
  them - IRIX leaves both at zero - then the volume registers, 255 = unity.

**`rtl/sgi/sgi_hpc3.sv`** claims PBUS PIO channels 0-3 (`0x58000-0x58FFF`) for
HAL2, hands PBUS DMA channels 0-3's `bp`/`dp`/`ctrl` to the engine (the rest of
their control group reads zero, as IRIS answers it), puts their interrupt bits
in `gen.intstat`, and **alternates** its one memory port between the SCSI
channel and the PBUS engine when both ask. The PBUS interrupt is not wired to
INT2: nothing that runs on an Indy was found to want it, and IRIS does not
wire it either.

**The OSD's "Audio: On/Off"** (`status[18]`) is HAL2's `present` input. Off, the
revision register reads `0xC010`, the PROM plays no tune, IRIX never loads
`kdsp_a2`, and the DAC is silent: the machine exactly as it was.

**The DAC** goes to `AUDIO_L`/`AUDIO_R`, signed (`AUDIO_S = 1`), from `clk_sys`.
The framework's `audio_out.sv` samples it in the audio clock domain and only
takes a value that has held for two of its clocks.

## What it costs

Measured by `quartus_map` on `sgi_hpc3` alone: HAL2 976 ALUTs, 893 registers
and 4 DSP blocks; the PBUS engine 723 ALUTs and 508 registers. The fit's own
numbers are in `reports/summary.md` for the build that carries it.

Memory bandwidth: while a sound plays, codec A and AES TX each move a stereo
frame per 48 kHz tick - ~96,000 memory transactions a second through the DMA
port (a frame is one doubleword). On the board IRIX 5.3's `kdsp_a2` starts its
rings when something plays and not at boot: nothing moves at the login screen.

## Tests

* **`make -C verilator audiotest`** (`tb_audio.cpp`, `tb_audio_top.sv`) -
  `sgi_hpc3` through its own PIO decode against a C++ memory with a random
  1-24 clock latency: the register file (read-back index, resets, volume); an
  IRIX ring (one self-linked descriptor, 300 stereo frames, two wraps - every
  frame in order and scaled, `bp` advancing at the sample rate); the PROM's
  tune shape (a three-buffer EOX chain crossing 4 KB, channels 1 and 2 on the
  same chain, both inactive at its end, every sample in order); codec B's
  silence landing exactly behind `bp`; odd-word buffers with a stereo frame
  split across a descriptor boundary; stopping a channel; the OSD switch.
* **`make -C verilator hal2test`** - HAL2's register file alone.
* **`make -C verilator tb_hpc3`** - HPC3's storage registers; PBUS channels 0-3
  are left to `audiotest`.
* **`tests/run-audio.sh`** - the real PROM in the whole-machine simulator with
  `--audio --wav`: its startup tune is recorded off the DAC and checked sample
  for sample against `tools/prom_tune.py`, which decodes the tune from the PROM
  image independently; then `hinv` must list
  `Audio: Iris Audio Processor: version A2 revision 4.1.0`.
* On the board: `bcnread.py --audio` (beacon words 43-45, version 15) shows
  frames played, DMA operations, under/overruns and the peak sample.

## On the board (build 45b, 2026-09-27)

Commit 6fd7ffc, rbf md5 `64cdbdc3f39bbf900b545906c66936b8`, board .92:

* **The PROM's tune** goes through the PBUS DMA and HAL2 on every launch:
  182 descriptors, 184,304 words, the DAC at full scale, then both channels
  idle (one underrun, at the start).
* **THE RELEASE IMAGES' KERNEL HAS NO AUDIO DRIVER.** `/unix` on
  `SGIIndy53-pristine.img` carries 11,000 symbols and not one `hal2_*`: lboot
  links `kdsp_a2` only when `audio.sm`'s `exprobe` of HAL2's revision passes,
  and those kernels were linked on cores whose HAL2 read absent. So an
  existing image needs, once, as root: **`/etc/autoconfig -f`, then reboot**
  (`scripts/audioprobe.sh --autoconfig` does it; the result is kept on the
  board as `SGIIndy53-audio.img`). A fresh install on an audio core links it
  from the start.
* **IRIX then plays.** `playaiff alarm_clock.aiff` under the relinked kernel,
  sampled on the board at 10 Hz: codec A and AES TX running (channels `0x9`)
  for ~2.7 s, 496,930 words at ~178,000 words/s against 192,000 expected
  for 48 kHz stereo on two channels (the sampler's interval runs a little
  over 0.1 s), 27 samples of waveform (-4193 .. +5823) decaying to 0, then
  idle. `init 0` afterwards takes X off the screen - the old `kdsp_a2` hang
  does not return. Evidence: `tests/out/hw/audioprobe-b45b-4*`,
  `tests/out/hw/b45b-3/`.
* Not yet measured: whether it sounds right to a listener, codec B input,
  and the audio panel's volume path.

The first probe of this build proved nothing about IRIX: Software Manager,
which opens after a root login when the CD is in the drive, took the typed
`playaiff` and `init 0` (`scripts/desktop.sh` now quits it).

## Tools

`tools/prom_tune.py` decodes the PROM's three tunes exactly as the PROM does
and checks a WAV against one. `tools/misterdeploy/ecoffdis.py` disassembles an
ECOFF relocatable object such as `kdsp_a2.o` (`ecoffsyms.py` reads only linked
kernels); it annotates each
instruction with its relocation, which is what turns `lui $t0, 0` into a call
to `kvtophys` or a load of `hal2_params`.
