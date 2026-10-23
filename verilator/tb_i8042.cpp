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

static void key(uint8_t code, bool pressed)
{
    uint32_t tog = ((t->ps2_key >> 10) & 1) ^ 1;
    t->ps2_key = (tog << 10) | ((pressed ? 1u : 0u) << 9) | code;
    tick(16);
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

    printf("\nI8042: %s\n", failures ? "FAIL" : "PASS");
    delete t;
    return failures != 0;
}
