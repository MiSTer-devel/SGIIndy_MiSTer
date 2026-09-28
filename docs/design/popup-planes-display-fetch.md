# Menus: the popup planes, and the display's share of DDR3

## The bug

**Every IRIX menu was invisible** - the Toolchest's, 4Dwm's window menu (the
"—" button), every Motif pull-down. Toolchest > System on build 48 pressed the
button and drew nothing, or one row of the menu.

**The menu was in memory.** `fbgrab32.py` read it whole out of DDR3's popup
planes (aux `[3:2]`/`[7:6]`, rows 116..439, columns 115..320); the 4Dwm window
menu likewise (rows 400..623). The beacon's `lcache:` word counted thousands of
`aux_miss` a second while a menu was up.

**The cause.** On MiSTer the display reads two plane sets through
`fb_linecache` - the drawing planes on every line, the auxiliary planes (overlay,
popup, window ID) only on lines flagged as holding something. `ddr3_mux` serves
the display as `FBR_SUB` = 4-word reads, `FBR_AHEAD` = 2 in flight (build ~34,
for CPU latency): at the bridge's ~10-clock read latency about 0.46 words a
clock. The drawing planes take 0.39; a menu adds 672 more words on each of its
lines. The auxiliary cache - second in `fb_fetch_arb` - fell behind at the
menu's first line and then fetched every remaining line of the frame after the
display had passed it. A miss is zeros, and zero popup bits are transparent.
The 4 x 2 split was checked on a desktop with no menu, where the auxiliary
cache fetches nothing. The display RTL is unchanged from build 44 to 48, so the
20260918 release has the bug too.

## The fix (build 49)

**The popup bits come with the pixel.** On a real Newport every plane of a
pixel leaves the VRAM in the same serial transfer. `np_rex3` already keeps
`aux[3:0]` (popup buffer A, window ID A) copied into byte 3 of the drawing slot
for its CID clip (`DR_CID`), so `newport.sv` takes the popup bits from the
drawing-plane word it fetches anyway. A popup menu costs no auxiliary fetch at
all. Only writes with overlay bytes in the write mask mark a line for the
auxiliary cache (`aux_mark`; by the mask, not the value - the value put the end
of the pixel pipeline in front of a register, build 49b's one failing path).

**The overlay still needs the auxiliary planes** (drag icons, "custom visual
for drag shell"; GL overlays), so:

* `fb_linecache`: a fill that falls behind skips to the line after the
  display's, so a shortfall costs lines rather than the rest of the frame;
  outputs `fetching` and `urgent` (fetching a line the display wants within two).
* `ddr3_mux`: while the auxiliary cache fetches (`fbr_deep`) or either cache
  is urgent (`fbr_urgent`), `FBR_AHEAD_DEEP` = 5 display reads may be in flight
  (the read queue's room beside the other three readers). Main memory stays
  first: putting an urgent display ahead of it changed no bench number and
  lengthened the CPU's same-clock path (`ram_now`) - build 49's first fit
  missed by 0.726 ns there.
* `fb_fetch_arb`: an urgent auxiliary cache goes before a drawing cache that
  is not.

## Gates

* `make menufetchtest` (`verilator/tb_menufetch.cpp`): both caches,
  `fb_fetch_arb` and the real `ddr3_mux` against a ~10-clock bridge. Build 48's
  RTL loses 324/324 menu lines there, as on the board. Now, with the CPU read
  latency at rest unchanged (17.0 clocks): popup menu 0 misses and no extra
  traffic; menu-sized overlay 0 misses behind a CPU read every 60 or 20 clocks
  (+1.2 clocks a CPU read while it is up); 64x64 overlay behind a read every 4
  clocks 0; the desktop behind 12-word reads every 20 clocks 0 drawing-plane
  misses (build 48's RTL: ~850,000 pixels a frame).
* `tb_newport` test 10: popup, a highlighted item and an overlay drawn through
  REX3 reach the pins in their own colours; odd rectangle edges, so taking the
  wrong half of the word or the window-ID bits fails it.
* `tb_rex3`: a popup draw marks no line, an overlay draw exactly its own.

## Board (.143, the Sep 8 working image)

| | build 48 | build 49c |
|---|---|---|
| core / HDMI setup slack (m900, seed 5) | +0.080 / +0.061 ns | +0.565 / +0.352 ns |
| ALMs | | 37,058 (88 %) |
| cpu-tests on hardware | 2415/0 | 2415/0 (255 tests) |
| Toolchest > System | not shown | shown; Down arrow moves the highlight |
| 4Dwm window menu ("—") | not shown | shown |
| `rgb_miss` after boot | 37,919 | 0 |
| `aux_miss` with a menu up | thousands a second | 0 |
| drawing slot byte 3 vs `aux[3:0]` | | equal at every captured pixel (49b) |

Build 49 (`036b581`) missed the core clock by 0.726 ns and 49b (`b77df18`)
by 0.150 ns on one path; the two fixes are described above. 49c is `62cedfd`,
rbf md5 `56024cac02e24502dd27c842e3f71e57`.

Open question, not the display: in these runs the highlight of a menu posted
by a click did not follow pointer motion (ws `mouseMove`), while the arrow keys
moved it. The frame buffer shows IRIX drew no new highlight on the motion, so
whatever decides it is on the input side; it needs a check with a real mouse.
