# Ethernet for the Indy core - implementation plan (DRAFT)

Status: **draft, not started** (2026-09-27). Written to scope the work; every
number marked *estimate* is one. Facts were read from the sources named in
[References](#references) on the date above; the `audio` branch (PR #1) is the
state of the core this assumes.

## 1. Goal

`ec0` up under IRIX 5.3 on the board: `ifconfig ec0`, ping, telnet/ftp/NFS
to and from the LAN or the MiSTer itself, using the network hardware the
MiSTer already has. Out of scope for the first pass: netbooting from the PROM,
multicast beyond what the driver sets up on its own, and any speed above what
a real Indy's 10 Mbit/s port could carry.

## 2. What the Indy has

The Indy's integral Ethernet is a **SEEQ 80C03 EDLC** (Ethernet data link
controller) hanging off **HPC3**, which feeds it through two dedicated DMA
channels. The CPU never moves frame bytes itself.

**SEEQ 80C03 registers**: eight byte registers at HPC3 offset `0x54000`
(`A2:A0`; IRIS `SEEQ_BASE`):

| reg | read | write |
|---|---|---|
| 0-5 | - | station address (bank 0); 80C03 banks 1/2 = multicast filter, control |
| 6 | RX status (`OLD`, `GOOD`, `END`, `SHORT`, `DRBL`, `CRC`, `OFLOW`) | RX command (interrupt enables; match mode: off / promiscuous / station+broadcast / +multicast) |
| 7 | TX status (`OLD`, late collision, `SUCCESS`, 16 tries, collision, underflow) | TX command (bank select in bits 6:5; interrupt enables) |

**HPC3 Ethernet DMA** (the same descriptor-chain engine as the SCSI channel
we already have, `hpc3_scsi_dma.sv`):

| block | HPC3 offset | registers |
|---|---|---|
| RX DMA (channel 10) | `0x14000` | `CBP`, `NBDP` (+0x0/+0x4); `BC`, `CTRL`, `GIO`, `DEV`, `RESET`, `DMACFG`, `PIOCFG` (+0x1000..+0x101C) |
| TX DMA (channel 11) | `0x16000` | `CBP`, `NBDP`; `BC`, `CTRL`, `GIO`, `DEV` |
| extras the driver uses | `0x18000`, `0x1A000`, `0x1A004` | `CRBDP` (current RX descriptor), `CPFXBDP` / `PPFXBDP` (TX first-descriptor pointers) |
| FIFOs | `0x2C000` / `0x2E000` | RX / TX FIFO windows |

Contract details IRIS models and the driver depends on (IRIS `hpc3.rs`,
`seeq8003.rs`):

* **An RX buffer is `[2 pad bytes][frame][1 SEEQ status byte]`.** The status
  byte is DMA'd as the last byte, with end-of-packet; the frame carries no FCS.
* **Reading `RX_CTRL` merges the SEEQ's live status bits** (mask `0xBF`) into
  the channel's own (`RBO`, active mask, `ACTIVE`, endian).
* `RX_RESET`: bit 0 channel reset, bit 1 clear interrupt (write) / interrupt
  pending (read), bit 2 **loopback**.
* TX writes back the descriptor's byte-count word with `TXD` (`0x8000`) and
  samples `EOX`. `CPFXBDP` / `PPFXBDP` track the first descriptors of the
  frames in flight.
* Interrupts: HPC3 `intstat` bit 4 (SEEQ), 5 (RX DMA), 6 (TX DMA) -> the IOC's
  **local 0 bit 3, "Ethernet"** (already named in `rtl/sgi/sgi_ioc.sv`).

## 3. What exists today

**In the core:**
* HPC3's Ethernet channel registers at `0x14000`/`0x16000` are **plain
  storage** in `sgi_hpc3.sv`'s register memory. That is enough for the PROM's
  power-on walk of a one-bit pattern through `enetr.cbp` (`0xBFC03E58`), and
  moves no data.
* The SEEQ window at `0x54000` and the extras at `0x18000`/`0x1A000` are
  **not decoded** (the core's unclaimed-cycle path).
* **The machine already has a per-board Ethernet address, but only one
  byte of it is per board.**
  - `sgiindy.sv` latches six bytes from `games/SGIIndy/boot1.rom`, which the
    framework uploads at ioctl index `0x40` at every core start, before
    `boot.rom`. The default is `08:00:69:12:34:56`.
  - `sgi_ds1386.sv` seeds the address into the NVRAM, where the PROM builds
    `eaddr` from it (IRIX's installer panics without one).
  - `boot1.rom` is written by `tools/misterdeploy/mkmac.py`, run from
    `scripts/deploy.sh`: `08:00:69:12:34` plus **the last octet** of the
    MiSTer's eth0. On .92 that is `08:00:69:12:34:f1` (eth0
    `46:16:65:61:56:f1`).
  - A user who never runs `deploy.sh` gets the fixed default. Section 5
    replaces all of this.

**In IRIX (our images):**
* `/var/sysgen/system/irix.sm` has `VECTOR: module=if_ec2` **with no probe**,
  so every kernel already contains the integral Ethernet driver. Unlike audio
  (`kdsp_a2`, which needed `/etc/autoconfig -f` because its probe failed at
  link time), **no relink should be needed**. Verify on the board.
* The images currently boot in "standalone network mode" (SYSLOG: "IRIS's
  Internet address is the default"; `/etc/hosts` has `192.168.2.2 IRIS`).

**In Main_MiSTer** (danifunker fork; nothing emulates a SEEQ):

| module | chip | where the chip is | status |
|---|---|---|---|
| `support/minimig/minimig_a2065*` | AMD LANCE (Am7990) | on the ARM; FPGA forwards register writes through a DDR3 doorbell | upstream MiSTer-devel (#1247) |
| `support/mac/mac_sonic*`, `mac_eth*` | DP83932 SONIC (incl. Quadra 800) | on the ARM | fork `master` (#1321) |
| `support/next/next_enet*` | MB8795 | **in the FPGA**; Main is only the wire | fork `master` |

The reusable parts are the A2065's **host network layer**
(`minimig_a2065_ethernet.cpp`: AF_PACKET raw socket, cBPF MAC filter, macvlan
child, tap device, mode probing), which `next_enet` already shares. Its OSD
modes are **Off / eth0 (shared, filtered) / eth1 (dedicated) / macvlan of
eth0 / tap0** (tap is the only way out over WiFi). The **NeXT split** is also
reusable, and it is the one that fits the Indy:
* The chip and its DMA are in RTL, so the PROM's and IRIX's hardware pokes
  see real hardware.
* Only raw frames cross, through a DDR3 mailbox the daemon polls from Main's
  loop. The layout is a magic word, TX write pointer, RX write/read pointers,
  the guest MAC (for the host-side filter), and 4 x 2 KB TX and RX slots (u64
  length header, then the frame).
* The FPGA half is `NeXT_MiSTer/rtl/next/next_enet_bridge.sv` (324 lines,
  base address a parameter); the Main half is `next_enet.cpp` (255 lines).

## 4. Proposed architecture

```
IRIX if_ec2 --PIO--> sgi_seeq.sv (80C03 regs, address filter, RX/TX FIFOs)
                        |  frame bytes
             hpc3_enet_dma.sv (RX + TX descriptor engines) --HPC3 memory port--> RAM
                        |  raw frames
             sgi_enet_bridge.sv (port of next_enet_bridge) --ddr3_mux master--> DDR3 mailbox
                                                                                   |
Main: support/sgi/sgi_enet.cpp (or a generalised next_enet) <-- polls ------------+
      + minimig_a2065_ethernet.cpp host layer --> eth0 / eth1 / macvlan / tap0
```

**FPGA, new:**
1. `rtl/sgi/sgi_seeq.sv`: the 80C03 register file, bank select, RX match
   modes (station / broadcast / multicast hash / promiscuous), status
   registers with OLD/NEW semantics, interrupt line, and small RX/TX byte
   FIFOs (M10K). No CRC generation or checking (frames from the host have
   none; report every frame `GOOD`). The RX status byte is appended at end of
   frame.
2. `rtl/sgi/hpc3_enet_dma.sv`: RX and TX channels modelled on
   `hpc3_scsi_dma.sv` (descriptor fetch, byte count, EOX, `TXD` writeback,
   `CRBDP`/`CPFXBDP`/`PPFXBDP`, `RESET` incl. **loopback**), sharing HPC3's one
   memory port with the SCSI and PBUS engines. The Ethernet registers move
   out of the plain-storage memory into this block, the way SCSI channel 0's
   did.
3. `rtl/mister/sgi_enet_bridge.sv`: `next_enet_bridge.sv` with our
   parameters, as one more `ddr3_mux` master. **Register its request** (the
   b45b lesson: DMA masters into `ddr3_mux` are the core clock's critical
   path family).
4. `sgiindy.sv`: the OSD entries and the live link line of section 5; the
   bridge's enable follows the port selection and the cable switch.

**Mailbox address - decide in phase 0:**
* **(a) Our own window**, e.g. byte offset `0x0590_0000` = ARM `0x3590_0000`,
  beside the beacon at `0x3580_0000`. `ddr3_mux` is fixed to the `0x3000_0000`
  region (`REGION = 4'b0011`), so this is just another `wordaddr(BASE_ENET, ..)`
  master. Main's module then needs a per-core base address. *Recommended.*
* (b) The shared `0x1FF0_0000` window A2065 and NeXT use, which reuses
  `next_enet.cpp` nearly unchanged but needs a second DDR3 region in
  `ddr3_mux`.

**Main, new** (small):
* Either `support/sgi/sgi_enet.cpp`, a copy of `next_enet.cpp` with its own
  magic (`"SGIETH01"`) and base, or better, `next_enet` generalised into a
  core-agnostic "frame mailbox" taking {base, magic, status-bit field} per
  core.
* Start/stop/poll hooks for the SGIIndy core name where NeXT's are in
  `user_io.cpp`, and the mode read from our status bits.

## 5. The address and the OSD (requirements, 2026-09-27)

### The Ethernet address

**SGI's prefix, the MiSTer's own address underneath:** `08:00:69` (SGI's
OUI) followed by **the low three bytes of the MiSTer's eth0 address**. On .92
that is `08:00:69:61:56:f1`, from eth0 `46:16:65:61:56:F1`.

* **eth0's address is stable.** MiSTer pins it in
  `/media/fat/linux/u-boot.txt` (`ethaddr=46:16:65:61:56:F1` on .92;
  `addr_assign_type` 0), so the Indy's address never changes from one boot to
  the next. It does not change when the OSD's port selection changes either:
  it is the machine's identity, not the port's.
* **It is one address everywhere, by construction.** The same address is:
  - NVRAM `eaddr`, which the PROM shows in `printenv`;
  - what IRIX reads from `eaddr` and programs into the SEEQ's station
    registers;
  - what the bridge publishes in the mailbox's `GUEST_MAC` for the host-side
    filter;
  - the MAC of a macvlan child, or of eth1 in dedicated mode.

  The bridge takes it from the SEEQ's station registers, as NeXT's does from
  its NodeID writes, so a guest that reprograms its address is followed.
* **Main makes it, not `deploy.sh`.** At core load, before the framework's
  `boot0..3.rom` uploads, the SGI support module:
  - reads eth0's address (falling back to wlan0, then to the fixed default);
  - forms `08:00:69:xx:yy:zz`;
  - rewrites `games/SGIIndy/boot1.rom` if it differs, so the existing
    ioctl-`0x40` path delivers it.

  `mkmac.py` changes to the same formula, for boards running an older Main.
  **Phase 0 checks the ordering in `user_io.cpp`** (where the `bootN.rom` loop
  runs against the core-specific init hooks). If the hook runs too late, Main
  sends the six bytes itself at index `0x40` instead of through the file.
* **Collisions:** two boards collide only if their eth0 addresses share the
  low 24 bits. MiSTer's addresses are locally administered (randomly
  generated), so that is 1 in 16 million per pair.
* **One-time change on existing boards:** .92's Indy goes from
  `08:00:69:12:34:f1` to `08:00:69:61:56:f1`. IRIX derives its host ID
  (`sysinfo`) from `eaddr`, so anything keyed to the old one - node-locked
  licences, NFS exports by address - sees a new machine once.

### The OSD

Three things on the OSD, all in `CONF_STR` (status bits `[26:23]` are free;
the highest in use below the aspect ratio's `[122:121]` is `dpf` at `[22]`):

```
"O[25:23],Network port,Off,eth0 (shared),eth0 (own MAC),eth1,WiFi (NAT);",
"O[26],Network cable,Connected,Disconnected;",
"h0-, Link: up;",
"H0-, Link: no link;",
```

* **Which physical card.**
  - *eth0 (shared)* is the onboard NIC, shared with the MiSTer, frames picked
    out by the cBPF filter on the Indy's address.
  - *eth0 (own MAC)* is a macvlan child of eth0, so the Indy is its own
    station on the LAN.
  - *eth1* is a dedicated second NIC, e.g. a USB adapter, carrying the Indy's
    address.
  - *WiFi (NAT)* is tap0 on a private subnet routed out of whatever interface
    is up, and the only choice on a WiFi-only MiSTer.

  These are exactly the A2065 host layer's modes, so Main already implements
  them. A mode the board cannot do (no eth1, no tun) is refused by
  `a2065_mode_available()`, and the link line then says so.
* **Connected / disconnected, as a switch:** the virtual cable.
  - *Disconnected* means the bridge passes no frames either way while the
    SEEQ and its DMA keep running, as on a real Indy with the cable pulled:
    transmits complete and go nowhere, and nothing arrives.
  - It changes nothing IRIX can read. The 80C03 has no link-status register,
    and `if_ec2` only sees silence.
  - Toggling it needs no reset, and neither does changing the port: Main
    reopens the host interface.
* **Connected / disconnected, as a state:** the live link line.
  - The core drives `status_menumask` bit 0 (hps_io; `sgiindy.sv` passes 0
    today) from a new mailbox word Main writes, `LINK_STATE`: bit 0 = the
    host interface is open and has carrier (`/sys/class/net/<if>/carrier`,
    tap is always up), plus bits naming the port actually opened.
  - Main's menu already hides `CONF_STR` lines by that mask (`H0` hides the
    line when the bit is set, `h0` when it is clear; `menu.cpp`), and shows
    the text of a `-,text;` line. So exactly one of "Link: up" / "Link: no
    link" is drawn.
  - The cable switch forces "no link".
  - Phase 0 checks whether Main re-reads the mask while the OSD is open
    (`UIO_GET_OSDMASK`, `menu.cpp` 1912/5389) or only on entering it. If only
    on entering, add a refresh.
  - A second bit can show whether the guest has its receiver on (`ec0` up),
    from the SEEQ's RX command register.

## 6. Phases and gates

Each phase ends in a commit with its own sim test, and one fit per phase at
most (one build in flight at a time: fit, board run, results read before the
next build's RTL; all fits on m900).

**Phase 0 - contract (no RTL).**
* Disassemble `if_ec2.o` from `/var/sysgen/boot` (the `ecoffsyms.py` trick
  that named `kdsp_a2`'s contract) and list every register it touches and
  every bit it waits on. Cross-check against IRIS `seeq8003.rs` / `hpc3.rs`.
* What the PROM does to the Ethernet at power-on and in its diagnostics,
  beyond the `cbp` walk: loopback? SEEQ register tests?
* Choose the mailbox address (a/b above).
* Main: where the core-load hook runs relative to the `bootN.rom` uploads
  (for the address), and whether the OSD mask is re-read while the OSD is
  open (for the link line). Both are in section 5.

**Phase 1 - SEEQ + DMA, loopback only.**
* `sgi_seeq.sv` and `hpc3_enet_dma.sv`, with the channel's loopback bit
  wiring TX to RX inside the core.
* Gates:
  - `tb_enet`: register-level equivalence with IRIS's model.
  - A standalone sim image `tests/enet/` (like `tests/dma`) that builds
    descriptor chains, sends frames in loopback and checks the RX buffers
    byte for byte (pad, frame, status), `TXD` writeback, interrupts through
    the IOC.
  - The PROM still passes `run-prom`.
  - The IRIX sim boot reaches the banner and `ec0` probes.

**Phase 2 - the bridge, in simulation.**
* `sgi_enet_bridge.sv` plus a harness option in `sim_cputest.cpp` that plays
  the ARM daemon against the sim's memory: at least an ARP + ICMP echo
  responder, or a pcap in/out.
* Gate: the loopback image, then a guest-side "ping" image, round trips
  through the mailbox.

**Phase 3 - Main module, then the board.**
* `sgi_enet.cpp` (or the generalised mailbox) in the fork's Main, built and
  deployed to .92 with the fit.
* Board test script `scripts/netprobe.sh`, in the style of `audioprobe.sh`:
  - Boot the pristine image with Network = tap0.
  - Set `ec0` up on a private subnet and ping the MiSTer.
  - ftp a file of known checksum both ways.
  - Then the same over macvlan to a LAN host.
  - Report frames and bytes from beacon counters (add a beacon word).
  - The address: PROM `printenv eaddr`, IRIX `netstat -in` and the LAN's ARP
    table all show `08:00:69` + eth0's low three bytes.
  - The OSD: every port choice opens the right interface; the link line
    follows pulling the MiSTer's own cable; *Disconnected* stops ping and
    *Connected* resumes it without a reset.
* Also: diskcheck, cpu-tests and audio regressions as usual.

**Phase 4 - IRIX configuration.**
* Hostname and address (`/etc/sys_id`, `/etc/hosts`,
  `/etc/config/netif.options`); IRIX 5.3 has no DHCP client out of the box.
* Document a recipe for the images (and maybe a prepared image).

## 7. Budget (*estimates*)

* **ALMs:**
  - The two DMA channels together cost about what `hpc3_scsi_dma` does, or
    somewhat more: ~800-1,200.
  - SEEQ ~300-500.
  - Bridge ~300-400.
  - **~1,500-2,100 in all**, against ~4,500 free (build 47: 37,406 / 41,910,
    89 %). Tight; the fit will get harder, and the plain-storage registers
    freed from `sgi_hpc3`'s memory give little back.
* **M10K:** RX/TX FIFOs and the bridge's slot buffers, a handful of blocks
  (66 free).
* **Timing:** one more `ddr3_mux` master and one more HPC3 memory client; both
  need registered requests from day one.
* **Main:** a few hundred lines, mostly reuse.

## 8. Risks and open questions

* **Security.** Our images log in as root with no password and run IRIX
  5.3's 1994 services (telnet, rsh, ftp, NFS). On macvlan or eth0 the Indy is
  a peer on the user's LAN. The default must be **Off**, tap0 (private
  subnet, host-side NAT) is the recommended mode, and the OSD/README should
  say so plainly.
* **Driver timing assumptions**: TX-done and RX interrupts arriving far
  faster than 10 Mbit/s would allow. IRIS runs at host speed and boots, which
  is encouraging; rate-limit only if the driver proves to need it.
* **FCS / minimum frame length**: host frames arrive without FCS and may be
  shorter than 60 bytes; check what `if_ec2` expects in the length it computes
  from the RX byte count (IRIS pads nothing and passes).
* **The RX ring when the guest is slow**: the bridge must respect `RX_RPTR`
  (next_enet_bridge does) and the SEEQ must report overflow rather than
  corrupt a buffer.
* **Main fork vs upstream**: `next_enet` and the Mac SONIC are in the fork,
  not upstream; the A2065 host layer is upstream. Shipping Indy networking to
  users means either upstreaming the generalised mailbox or keeping it in the
  fork's Main.
* **WiFi-only MiSTers** can only use tap0 (a WiFi station cannot send a
  second source MAC); that needs `CONFIG_TUN` in the MiSTer kernel.

## References

* IRIS: `src/seeq8003.rs` (SEEQ model and NAT gateway), `src/hpc3.rs`
  (Ethernet channel registers and interrupt bits), `src/net.rs`,
  `src/net_pcap.rs`.
* MAME: `src/devices/machine/edlc.cpp` (SEEQ 8003), `src/mame/sgi/hpc3.cpp`.
* Main_MiSTer (fork): `support/next/next_enet.{h,cpp}`,
  `support/minimig/minimig_a2065_ethernet.cpp`, `support/mac/mac_sonic.cpp`.
* NeXT cores: `NeXT_MiSTer/rtl/next/next_enet_bridge.sv`,
  `NeXT_MiSTer/tb/tb_next_bridge.sv`, `NeXT-Color_MiSTer/rtl/tc_enet*.sv`.
* This core: `rtl/sgi/sgi_hpc3.sv` (`HD_ENET_BASE`, the `enetr.cbp` note),
  `rtl/sgi/hpc3_scsi_dma.sv`, `rtl/sgi/sgi_ioc.sv` (local 0 bit 3),
  `rtl/mister/ddr3_mux.sv` (`REGION`, `wordaddr`), `sgiindy.sv` (MAC upload at
  ioctl `0x40`), `docs/design/audio.md` (the autoconfig lesson).
