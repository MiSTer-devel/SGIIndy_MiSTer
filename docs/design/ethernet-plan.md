# Ethernet for the Indy core - design

Status: **design, Phase 0 done** (2026-10-23). It replaces the 2026-09-27
draft, which put the SEEQ and both HPC3 Ethernet DMA engines in the FPGA
behind a NeXT-style frame mailbox (~1,500-2,100 ALMs, *estimate*). This
revision puts the chip on the ARM and keeps only a register window in the
FPGA, because the device is full (build 51: 88 %) and the CPU-speed work
needs room too. Numbers marked *estimate* are estimates.

## 1. Goal

`ec0` up under IRIX 5.3 on the board: `ifconfig ec0`, ping, telnet/ftp/NFS
to and from the LAN or the MiSTer itself, through the network hardware the
MiSTer already has. Out of scope for the first pass: netbooting from the PROM,
and any speed above what a real Indy's 10 Mbit/s port carried.

## 2. What the Indy has

A **SEEQ 80C03 EDLC** behind **HPC3**, fed by two dedicated DMA channels; the
CPU never moves frame bytes itself.

| block | HPC3 offset | registers |
|---|---|---|
| RX DMA (channel 10) | `0x14000` | `CBP`, `NBDP` (+0/+4); `BC`, `CTRL`, `GIO`, `DEV`, `RESET`, `DMACFG`, `PIOCFG` (+0x1000..+0x101C) |
| TX DMA (channel 11) | `0x16000` | `CBP`, `NBDP`; `BC`, `CTRL`, `GIO`, `DEV` |
| extras | `0x18000`, `0x1A000`, `0x1A004` | `CRBDP` (current RX descriptor), `CPFXBDP` / `PPFXBDP` (first descriptors of the TX frames in flight) |
| SEEQ 80C03 | `0x54000` + 4·reg | regs 0-5: station address / multicast / control by bank; 6: RX command / status; 7: TX command (bank select) / status |

`RX CTRL`: `0x200` ACTIVE, `0x400` active mask, `0x800` RBO, low byte the
SEEQ's RX status. `TX CTRL`: `0x200` ACTIVE, low byte the TX status (`0x08`
success). `RX RESET` (`0x15014`): bit 0 channel reset, bit 1 interrupt pending
(read) / clear (write), bit 2 loopback. The interrupt is the IOC's **local 0
bit 3** (named in `rtl/sgi/sgi_ioc.sv`). Constants: IRIS `src/hpc3.rs`.

Today all of these channel registers are **plain storage** in `sgi_hpc3.sv`'s
register memory (enough for the PROM's one-bit walk through `enetr.cbp`), and
the SEEQ window is **unclaimed**: it reads all-ones, so reg 5 says "no
carrier" and IRIX prints `ec0: no carrier` every 30 s.

## 3. What IRIX's driver needs (Phase 0)

Read out of IRIX 5.3's `/usr/cpu/sysgen/IP22boot/if_ec2.o` (the same code is
in `/unix`), 2026-10-23. These are the rules the split has to keep:

* **ACTIVE is the only thing the driver reads right after a start**, and it
  decides with it: on transmit, ACTIVE set means "append" (it clears EOX and
  XIE on the old tail descriptor and returns), clear means "restart" (it reads
  `NBDP`, skips descriptors whose `ETXD` bit is set, and starts at the first
  one that is not). There is no read-back after a start and no polling loop.
  **If ACTIVE read 0 while the ARM had not yet taken a start**, the interrupt
  handler would retire a live RX descriptor from a stale `CRBDP`, and
  transmit would start the same chain twice. So the FPGA sets ACTIVE itself,
  on the guest's start write.
* **`CPFXBDP` / `PPFXBDP` are read at the top of every transmit while any TX
  descriptor is in flight, with no ACTIVE check**, and in the interrupt
  handler while TX is active. The driver frees queued packets from its own
  ring pointer up to the first of the two it meets; if it meets a free
  descriptor first it stops TX (`CTRL = 0`) and rewrites `NBDP`. After a fully
  reclaimed chain both point behind the ring pointer, so a stale pair frees
  the packet just started and stops the channel: lost packets on nearly every
  burst. So the FPGA does what HPC3's first descriptor fetch does, **on the
  TX ACTIVE 0->1 edge: `PPFXBDP <- CPFXBDP; CPFXBDP <- NBDP`**. The ARM then
  advances the pair one packet at a time.
* **`CBP` and `BC` are never read** (only by the kernel debugger's dump).
  TX `NBDP` and `CRBDP` are read only after the driver saw ACTIVE == 0, so the
  ARM writes them, the TX status and its memory write-backs **before** it
  clears ACTIVE.
* **RX completion is found in memory.** Descriptor word 1 bit 14 (OWN) clear
  means done; bits 13:0 are the bytes *remaining*, so length = `0x62f` -
  remaining; the buffer is `[2 pad bytes][frame][1 status byte]`. Descriptors
  are 16 bytes (buffer, word 1, next, a software word), in pre-linked rings of
  256, accessed uncached; word 1 bit 31 EOX/EOR, 30 EOXP, 29 XIE, 24 "queued"
  (driver), 15 ETXD (hardware, on sent TX descriptors). Normally only 10 RX
  buffers are posted.
* **Never consume the RX end-of-ring descriptor**, or stop with `CRBDP`
  exactly on it: more than 5 "RX stopped with CRBDP != the end descriptor" in
  30 s switch the driver to promiscuous mode with 250 buffers for an hour.
* **SEEQ:** status registers 6 and 7 are never read in operation (the TX
  result comes from TX `CTRL`'s low bits when idle). Reg 0 reading 0 at attach
  identifies an 80C03; regs 0/1 are collision counts; reg 5 bit 1 is "no
  carrier". Set-up: bank 0 station address into regs 0-5, optional multicast
  filter through banks 1 and 2, TX command `0x4f` (bank 2 stays selected),
  control reg 3 = `0x37`, reg 2 = 0, then RX command mode|`0x3e` and
  mode|`0x3f` (mode `0x80` normal, `0xc0` multicast, `0x40` promiscuous).
* **Interrupt:** IOC local 0 bit 3; acknowledged by reading `RESET` bit 1 and
  writing 2, before any processing. Reset is `RESET = 3`, 10 us, `RESET = 0`.
  `ec_init` runs often: multicast changes, a 2 s watchdog when RX is inactive,
  and 5 s of transmitting without receiving anything.
* **The address is ARCS `eaddr`** (`init_sysid` -> kernel `eaddr` -> SEEQ
  regs 0-5). It must start `08:00:69` or `00:00:1d`, or `ec0` is not attached
  at all. The core already seeds it into the NVRAM (section 7).

Not determined from the binary: whether the real chip leaves the FCS in the
buffer (the driver does not care), which descriptor of a frame gets `ETXD`,
and HPC3's real start-to-fetch latency.

## 4. The split

```
IRIX if_ec2 --PIO--> sgi_hpc3: Ethernet register window (store + live bits)
                        ^   ACTIVE set on start, TX pointer shift, SEEQ regs, IRQ
                        |   custom UIO command over hps_io's EXT_BUS
                        v
Main: support/sgi/sgi_enet.cpp - the SEEQ and both descriptor engines
      reads/writes guest RAM directly (DDR3 at ARM 0x38000000)
      + minimig_a2065_ethernet.cpp host layer --> eth0 / eth1 / macvlan / tap0
```

The FPGA keeps what the driver reads with no time to wait (ACTIVE, the TX
pointer pair, the interrupt, the SEEQ's carrier bit); everything that moves
bytes is software on the ARM, which already sees guest RAM. There is no new
`ddr3_mux` master and no descriptor engine in RTL. Main's lag (a main-loop
pass: ~10 us idle, a few ms during SD writes) is then invisible to the driver
by the rules of section 3.

## 5. The FPGA window (`sgi_hpc3.sv`)

* **Store as before.** `NBDP`, `CBP`, `BC`, `CRBDP`, `CPFXBDP`, `PPFXBDP` stay
  words of the register memory; the SEEQ's written registers go into its free
  range `0x40-0x5F` as {bank, reg}.
* **Live bits** (flip-flops): RX and TX ACTIVE, interrupt pending, loopback,
  the SEEQ's TX command (for the bank) and a no-carrier bit from Main.
  * A guest write to a `CTRL` with ACTIVE set sets ACTIVE; with it clear it
    clears it. `RESET` bit 0 clears both ACTIVEs; bit 1 written clears the
    pending interrupt. Pending drives IOC local 0 bit 3.
  * On the TX ACTIVE 0->1 edge a small sequencer does the pointer shift of
    section 3 through the store, holding the bus `ack` for its few clocks.
  * SEEQ reads: reg 5 bit 1 = no carrier; regs 0-4 read 0; 6/7 read their
    OLD bit.
* **A write counter** (`seq`, 16 bits) counts every guest write to the window.
* **Main's port** is a custom UIO command on `EXT_BUS` (the `hps_ext.v`
  pattern Minimig uses for IDE): Main reads any store word or live register by
  index, writes store words and live bits, and pulses `ext_inval`. Every
  write Main makes carries the `seq` it read its snapshot under and is
  **dropped if the guest has written since**; Main re-reads and decides
  again. That keeps a guest reset or restart from being overwritten by a
  decision made before it.
* **`ram_arb` gets `ext_inval`**, which empties both prefetch buffers: Main's
  writes to guest RAM bypass the snooping the FPGA's own masters get.

## 6. Main (`support/sgi/sgi_enet.cpp`, branch `sgi-indy`)

Hooked like `hp9k_enet` (start at core load, poll in the main loop, stop on
unload), on the A2065 host layer (`ethernet_open`, `_send`, `_recv_nb`,
macvlan, tap; `a2065_mode_available`).

* **Each poll:** read `seq`, the live bits and the pointers. **TX**, if
  ACTIVE: walk from `CPFXBDP`, gather each frame (EOXP ends one) from guest
  RAM, send it, set `ETXD` in its descriptor, advance the pointer pair; at EOX
  write `NBDP`, TX `CTRL` status `0x08`, clear ACTIVE, raise the interrupt if
  XIE. **RX**, if ACTIVE: for each host frame take the next descriptor with OWN
  set, write `[2 pad][frame][status 0x20|...]` into its buffer, then
  `ext_inval`, then word 1 (remaining count, OWN clear), `CRBDP`, and the
  interrupt; stop on the end descriptor without consuming it. Frames shorter
  than 60 bytes are padded; the receive filter follows the SEEQ's RX mode
  (station + broadcast, + multicast, promiscuous).
* **Guest addresses** are physical; Main reads the MC's `MEMCFG0/1` through the
  same port and applies `sgi_memmap.sv`'s bank translation onto the DDR3
  window (RAM at window offset `0x08000000`, ARM `0x38000000`), byte order G
  -> ARM G^7 as for the frame buffer.
* **Ordering:** frame bytes, `dsb`, `ext_inval`, descriptor write-back, `dsb`,
  `ext_inval`, then registers and the interrupt.

## 7. The address and the OSD

**Address:** `08:00:69` followed by the low three bytes of the MiSTer's eth0
(`/sys/class/net/eth0/address`, pinned in `u-boot.txt`, so stable); on .92
`08:00:69:61:56:f1`. The core already takes six bytes at ioctl index `0x40`
before `boot.rom` (`sgiindy.sv`) and seeds them into the NVRAM where the PROM
builds `eaddr` (`sgi_ds1386.sv`); today they come from
`games/SGIIndy/boot1.rom`, which only `scripts/deploy.sh` writes, so every
other user gets the default `08:00:69:12:34:56`. **Main sends them** at core
load instead, before the framework's `bootN.rom` uploads; `mkmac.py` moves to
the same formula. Two boards collide only if their eth0 addresses share the
low 24 bits.

**OSD**, the standard's row on the top page under Memory, as on the HP 9000:

```
"O[26:24],Network interface,eth0,None,eth1,macvlan,tap0;",
```

eth0 is the default (Dani, 2026-10-23: "people know the risks of running
vintage operating systems"). Main reads the bits itself, so a change acts at
once and stays out of *Changes pending*; *None* is a pulled cable (the
no-carrier bit set, nothing passes). The value order is Main's A2065 mode
numbering, as `hp9k_enet` maps it.

## 8. Phases and gates

One build in flight at a time; all fits on m900. Core work on
`scsi-and-ethernet-enhancements`, Main work on `sgi-indy` (merged into
`scsi-consolidated` for board tests); one PR per core in each repo.

* **Phase 0 - contract.** Done: section 3. Still to check on the board:
  `MEMCFG0/1` at 32/48/64/128 MB, and that hps_io leaves the chosen UIO
  command number alone.
* **Phase 1 - the FPGA window** (one fit, ≤ 500 ALMs). Gates: a `tb_enet`
  bench driving the window as `if_ec2` does (start sets ACTIVE, the pointer
  shift, seq-checked writes, RESET, interrupt ack, SEEQ reads); `run-prom`;
  the PROM's own Ethernet tests.
* **Phase 2 - Main's engine against the sim.** `sim_cputest.cpp` grows the
  EXT_BUS port and runs `sgi_enet`'s engine against the sim's memory with a
  loopback or ARP/ICMP responder; gate: a guest image that pings through it.
* **Phase 3 - the board.** Main built and deployed to .143; IRIX by hand with
  misterkvms: `ifconfig ec0`, ping the MiSTer over tap0, ftp a file of known
  checksum both ways, then macvlan to a LAN host; every OSD choice; plus
  disk check, cpu-tests and audio as usual.
* **Phase 4 - IRIX configuration.** Hostname and address (`/etc/sys_id`,
  `/etc/hosts`, `netif.options`); a recipe in the docs.

## 9. Budget (*estimates*)

* **FPGA ~300-450 ALMs**: the UIO decoder and read mux, store arbitration, the
  live bits, the TX pointer sequencer, `seq`. No M10K. Room was made first:
  build 52 removed the SCSI block cache (~2,000 ALMs, 96 M10K).
* **Main:** a few hundred lines on top of the A2065 host layer, plus ports of
  IRIS's descriptor handling (`hpc3.rs` channels 10/11) and SEEQ filter.

## 10. Risks and open questions

* **Partial updates under a racing guest:** each of Main's writes is
  seq-checked on its own, so a group can land half; the rules above make
  every prefix harmless, but Phase 1's bench has to prove it.
* **TX append race:** the driver appends while ACTIVE is set and Main may
  finish the chain at the old tail at the same moment. The driver recovers on
  its next transmit (ACTIVE clear -> restart at the first descriptor without
  `ETXD`); real HPC3 has the same window.
* **Throughput:** one poll per main-loop pass bounds latency at a few ms
  during SD writes; fine for 10 Mbit/s, and the driver's 5 s and 2 s
  watchdogs are far away.
* **Security:** passwordless root and 1994 services on a LAN; the default is
  still eth0 by Dani's decision, and the README says what that means.
* **WiFi-only MiSTers** can only use tap0, which needs `CONFIG_TUN`.

## References

* The `if_ec2` study (2026-10-23): disassembly of
  `/usr/cpu/sysgen/IP22boot/if_ec2.o` with `ecoffdis.py`
  (`git show 2621a80:tools/misterdeploy/ecoffdis.py`).
* IRIS: `src/seeq8003.rs`, `src/hpc3.rs` (Ethernet channels, constants).
* Main_MiSTer: `support/hp9k/hp9k_enet.cpp` (hooks, OSD mode mapping),
  `support/minimig/minimig_a2065_ethernet.cpp` (host layer).
* Minimig-AGA_MiSTer `hps_ext.v` (the `EXT_BUS` command pattern).
* This core: `rtl/sgi/sgi_hpc3.sv` (the store, `HD_ENET_BASE`),
  `rtl/sgi/sgi_ioc.sv` (local 0 bit 3), `rtl/sgi/ram_arb.sv` (prefetch
  buffers), `rtl/sgi/sgi_memmap.sv`, `sgiindy.sv` (ioctl `0x40`),
  `rtl/sgi/sgi_ds1386.sv` (`eaddr` seed).
