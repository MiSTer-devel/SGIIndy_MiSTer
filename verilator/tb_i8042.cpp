// tb_i8042.cpp - the keyboard controller across a machine reset.
//
// hps_io flips ps2_key[10] / ps2_mouse[24] once per event and does not reset
// them, so after a reset with a toggle at 1 the controller must not see an
// event that is not there. Up to build 51 it did: it cleared its copy of the
// toggle to 0 on reset and replayed the last key into the output buffer while
// the PROM ran its controller self-test - "PC keyboard/mouse controller
// diagnostic *FAILED* / Check or replace: CPU base board" after about half of
// all OSD resets. This drives the register interface the way the PROM does
// (status at +0x44, data at +0x40) and checks the output buffer is empty after
// the reset, and that real events still arrive.
//
//   make -C verilator i8042test && verilator/obj_dir_i8042/Vi8042
#include "Vi8042.h"
#include <cstdio>
#include <cstdint>
#include <vector>
#include <initializer_list>

static Vi8042 *t;
static int failures = 0;

static void tick(int n = 1)
{
    for (int i = 0; i < n; i++) {
        t->clk = 0; t->eval();
        t->clk = 1; t->eval();
    }
}

static uint8_t access(bool is_cmd, bool we, uint8_t din = 0)
{
    t->sel = 1; t->is_cmd = is_cmd; t->we = we; t->din = din;
    tick();
    t->sel = 0; t->we = 0;
    tick();
    return t->dout;
}
static uint8_t status()        { return access(true, false); }
static uint8_t data()          { return access(false, false); }
static void    cmd(uint8_t v)  { access(true, true, v); }
static void    put(uint8_t v)  { access(false, true, v); }

static void check(const char *what, bool ok)
{
    printf("  %s  %s\n", ok ? "ok    " : "FAILED", what);
    if (!ok) failures++;
}

static void reset_machine()
{
    t->reset = 1; tick(8);
    t->reset = 0; tick(32);     // more than any sequencer needs to emit a packet
}

static void key(uint8_t code, bool pressed, bool ext = false)
{
    uint32_t tog = ((t->ps2_key >> 10) & 1) ^ 1;
    t->ps2_key = (tog << 10) | ((pressed ? 1u : 0u) << 9) | ((ext ? 1u : 0u) << 8) | code;
    tick(16);
}

// Everything the keyboard has queued, in order.
static std::vector<uint8_t> bytes()
{
    std::vector<uint8_t> v;
    while ((status() & 1) && v.size() < 64) v.push_back(data());
    return v;
}

static bool is(const std::vector<uint8_t> &v, std::initializer_list<uint8_t> want)
{
    return v == std::vector<uint8_t>(want);
}

static void show(const std::vector<uint8_t> &v)
{
    printf("        got");
    for (uint8_t b : v) printf(" %02X", b);
    printf("\n");
}

// One key pressed and released, with what the guest should read for each.
static void keycheck(const char *what, uint8_t code, bool ext,
                     std::initializer_list<uint8_t> make,
                     std::initializer_list<uint8_t> brk)
{
    key(code, true, ext);
    auto m = bytes();
    key(code, false, ext);
    auto b = bytes();
    bool ok = is(m, make) && is(b, brk);
    check(what, ok);
    if (!ok) { show(m); show(b); }
}

static void mouse(uint8_t b0, uint8_t dx, uint8_t dy)
{
    uint32_t tog = ((t->ps2_mouse >> 24) & 1) ^ 1;
    t->ps2_mouse = (tog << 24) | ((uint32_t)dy << 16) | ((uint32_t)dx << 8) | b0;
    tick(16);
}

static int drain()
{
    int n = 0;
    while ((status() & 1) && n < 64) { data(); n++; }
    return n;
}

int main()
{
    t = new Vi8042;
    t->ce = 1; t->sel = 0; t->we = 0; t->is_cmd = 0; t->din = 0;
    t->ps2_key = 0; t->ps2_mouse = 0;

    printf("power-on reset, toggles at 0\n");
    reset_machine();
    check("output buffer empty", (status() & 1) == 0);

    printf("a key, so the key toggle is left at 1\n");
    key(0x1C, true);
    check("the key arrives", (status() & 1) && data() == 0x1C);
    check("and nothing else", drain() == 0);

    printf("machine reset with the key toggle at 1 (the OSD's Apply and reset)\n");
    reset_machine();
    uint8_t s = status();
    check("output buffer still empty: no replayed key", (s & 1) == 0);
    if (s & 1) printf("        replayed byte 0x%02X\n", data());
    drain();

    printf("a real key after the reset\n");
    key(0x1C, false);
    uint8_t b0 = (status() & 1) ? data() : 0, b1 = (status() & 1) ? data() : 0;
    check("its release arrives as F0 1C", b0 == 0xF0 && b1 == 0x1C);
    check("and nothing else", drain() == 0);

    printf("mouse: an event (port disabled), then a reset with its toggle at 1\n");
    mouse(0x08, 5, 3);
    reset_machine();
    drain();
    cmd(0xD4); put(0xF4);          // write to the aux device: enable reporting
    uint8_t ack = (status() & 1) ? data() : 0;
    check("enabling the mouse answers FA", ack == 0xFA);
    tick(32);
    check("and no stale packet follows", drain() == 0);
    mouse(0x09, 7, 2);
    uint8_t m0 = (status() & 1) ? data() : 0, m1 = (status() & 1) ? data() : 0, m2 = (status() & 1) ? data() : 0;
    check("a real mouse packet arrives whole", m0 == 0x09 && m1 == 7 && m2 == 2);

    // ---- scan-code set 3 -------------------------------------------------
    // IRIX selects set 3 (keyboard command F0 03). hps_io keeps delivering set
    // 2, so the controller translates. Before it did, IRIX read set 2's Left
    // Alt (11) as its Left Ctrl and set 2's Left Ctrl (14) as Caps Lock.
    printf("scan-code set 2 (the default)\n");
    keycheck("Left Alt is 11 / F0 11", 0x11, false, {0x11}, {0xF0, 0x11});
    keycheck("Right Alt is E0 11 / E0 F0 11", 0x11, true, {0xE0, 0x11}, {0xE0, 0xF0, 0x11});

    printf("the guest selects set 3 (F0 03) and reads it back (F0 00)\n");
    put(0xF0); auto a1 = bytes();
    put(0x03); auto a2 = bytes();
    check("F0 03 is acknowledged twice", is(a1, {0xFA}) && is(a2, {0xFA}));
    put(0xF0); bytes();
    put(0x00); auto g = bytes();
    check("F0 00 answers FA 03", is(g, {0xFA, 0x03}));
    if (!is(g, {0xFA, 0x03})) show(g);

    printf("set 3\n");
    keycheck("Left Alt is 19 / F0 19", 0x11, false, {0x19}, {0xF0, 0x19});
    keycheck("Left Ctrl is 11 / F0 11", 0x14, false, {0x11}, {0xF0, 0x11});
    keycheck("Caps Lock is 14 / F0 14", 0x58, false, {0x14}, {0xF0, 0x14});
    keycheck("Right Alt is 39, no E0", 0x11, true, {0x39}, {0xF0, 0x39});
    keycheck("Right Ctrl is 58, no E0", 0x14, true, {0x58}, {0xF0, 0x58});
    keycheck("Up is 63, no E0", 0x75, true, {0x63}, {0xF0, 0x63});
    keycheck("Pause (hps_io E0 77) is 62", 0x77, true, {0x62}, {0xF0, 0x62});
    keycheck("Num Lock (77) is 76", 0x77, false, {0x76}, {0xF0, 0x76});
    keycheck("Esc is 08", 0x76, false, {0x08}, {0xF0, 0x08});
    keycheck("F7 (83) is 37", 0x83, false, {0x37}, {0xF0, 0x37});
    keycheck("A is 1C in both sets", 0x1C, false, {0x1C}, {0xF0, 0x1C});
    keycheck("Left Win (E0 1F) is 8B", 0x1F, true, {0x8B}, {0xF0, 0x8B});
    key(0x02, true); auto u = bytes(); key(0x02, false); auto u2 = bytes();
    check("a key with no set-3 code is dropped", u.empty() && u2.empty());

    printf("keyboard reset (FF) returns to set 2\n");
    put(0xFF); auto r = bytes();
    check("FF answers FA AA", is(r, {0xFA, 0xAA}));
    keycheck("Left Alt is 11 again", 0x11, false, {0x11}, {0xF0, 0x11});

    printf("\nI8042: %s\n", failures ? "FAIL" : "PASS");
    delete t;
    return failures != 0;
}
