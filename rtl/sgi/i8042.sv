//============================================================================
//  i8042 - the PC-style keyboard/mouse controller in IOC2.
//
//  The Indy carries a PC keyboard controller, reachable through IOC2 at
//  +0x40 (data) and +0x44 (command on a write, STATUS on a read). That
//  write/read split is the whole reason the previous stub had to read zero:
//  the PROM writes the self-test command 0xAA to +0x44 and then polls the
//  same address, so a register that reads back what was written answers
//  0xAA, whose bit 1 says "input buffer full", and the PROM waits forever
//  for a controller that never drains. See docs/reference/chipset.md finding 10.
//
//  This models the controller and both devices behind it, rather than the
//  PS/2 serial lines: MiSTer's hps_io already decodes the wire protocol into
//  `ps2_key` and `ps2_mouse`, so the line-level half would be two state
//  machines translating a protocol back into itself. Command handling and
//  the byte queue follow IRIS's src/ps2.rs, which drives both this PROM and
//  IRIX.
//
//  KEYBOARD SCAN CODES ARE SET 2, which is what `ps2_key` delivers and what
//  a PS/2 keyboard sends unasked - until the guest selects set 3 with `F0 03`,
//  as IRIX does; then each key is translated (set3() below). Set 1 translation (controller config bit
//  6) is accepted as a config write and then ignored - nothing in the PROM
//  or in IRIX's kernel driver asks for it, and translating would mean
//  carrying a 132-entry table for a case that does not arise. If something
//  ever does set it, the codes will be wrong rather than absent, which is a
//  visible failure rather than a silent one.
//
//  INTERRUPTS are generated but not yet routed: sgi_indy.sv leaves INT2's
//  sources tied off until the CPU takes interrupts at all. Until then the
//  PROM and the harness poll the status register, which is what the PROM's
//  own console path does anyway.
//============================================================================

module i8042 (
    input  logic        clk,
    input  logic        reset,
    input  logic        ce,

    // ---- register interface, from sgi_ioc -------------------------------
    input  logic        sel,        // one-cycle access pulse
    input  logic        we,
    input  logic        is_cmd,     // 0 = +0x40 data port, 1 = +0x44 cmd/status
    input  logic  [7:0] din,
    output logic  [7:0] dout,       // data byte or status, per is_cmd

    // ---- host events -----------------------------------------------------
    // MiSTer's decoded forms. Both are edge-encoded on their top bit: the
    // sender toggles it once per event, so a level compare against the last
    // seen value is the event strobe and no handshake is needed.
    input  logic [10:0] ps2_key,    // {toggle, pressed, extended, code[7:0]}
    input  logic [24:0] ps2_mouse,  // {toggle, dy[8:0], dx[8:0], 1'b0, btn_m, btn_r, btn_l}

    output logic        irq_kbd,
    output logic        irq_mouse
);

    // ---- output queue ----------------------------------------------------
    // Depth 32. A key press is at most three bytes and a mouse packet three,
    // so this holds ten events unread; the PROM never lets more than one or
    // two accumulate, and IRIX drains on interrupt.
    localparam int QDEPTH = 32;

    logic [8:0] queue [QDEPTH];     // {is_aux, data}
    logic [4:0] q_head, q_tail;
    logic [5:0] q_count;

    wire        q_empty = (q_count == 0);
    wire        q_full  = (q_count >= QDEPTH - 4);   // headroom for one packet
    wire [8:0]  q_front = queue[q_head];

    // Pushes are requested from several places in one cycle at most; a small
    // two-slot staging register would be needed for more, and nothing here
    // needs more.
    logic       push_en;
    logic [8:0] push_val;
    logic       pop_en;

    // Some device commands answer with more than one byte - a reset is ACK,
    // then the power-on self-test result, then (for the mouse) the device ID.
    // The port above takes one byte per cycle, so the first goes out with the
    // command and the rest are staged here and drained on idle cycles.
    logic [1:0] pend_cnt;
    logic [8:0] pend_b0, pend_b1;

    // ---- controller state ------------------------------------------------
    // config: the 8042 command byte. Bit 4 disables the keyboard port, bit 5
    // the mouse port, bits 0/1 enable the two interrupts. 0x47 is what a PC
    // BIOS leaves behind and what IRIS starts from: both interrupts on,
    // translation on, system flag set.
    logic [7:0] config_byte;
    logic       next_write_is_mouse;
    logic       kbd_scanning;
    logic [1:0] kbd_set;        // the scan-code set the guest selected: 2 or 3
    logic       mouse_enabled;
    logic [7:0] mouse_id;
    logic [7:0] mouse_resolution;
    logic [7:0] mouse_sample_rate;

    // What the next data-port write means, when it is not a plain command.
    typedef enum logic [3:0] {
        ARG_NONE,
        ARG_WRITE_CONFIG,
        ARG_KBD_LEDS,
        ARG_KBD_SCANSET,
        ARG_KBD_TYPEMATIC,
        ARG_MOUSE_RESOLUTION,
        ARG_MOUSE_SAMPLE,
        ARG_AUX_LOOP
    } arg_state_e;

    arg_state_e arg_state;

    // ---- status ----------------------------------------------------------
    // bit 0 OBF   - a byte is waiting
    // bit 1 IBF   - the controller has not consumed the last write. Always
    //               clear: every command completes in the cycle it arrives,
    //               so there is never a write in flight. This is the bit the
    //               old stub's loopback set by accident.
    // bit 2 SYS   - set once the controller has passed its self-test. Held
    //               set, as a machine that has been reset and tested is what
    //               the PROM finds.
    // bit 5 AUX   - the waiting byte came from the mouse port
    wire [7:0] status = {2'b00, q_front[8] && !q_empty, 2'b00, 1'b1, 1'b0, !q_empty};

    // Registered one cycle, to line up with sgi_indy's registered ack.
    //
    // This has to be sampled during the access cycle, not read combinationally
    // a cycle later: the pop below happens on the same edge that ends the
    // access, so by the time `ack` is high `q_front` has already advanced to
    // the next byte - or to an empty queue. Reading it then returns the byte
    // *after* the one asked for, which for a single queued ACK means 0x00 and
    // makes a controller that is answering correctly look mute. That is
    // exactly how the keyboard self-test failed: the PROM wrote 0xED, saw OBF
    // set, read the data port and got 0x00 instead of 0xFA.
    logic [7:0] dout_r;
    assign dout = dout_r;

    // A read of the data port consumes the byte. Reading the status port does
    // not, which is what lets the PROM poll OBF and then fetch.
    assign pop_en = sel && !we && !is_cmd && !q_empty;

    // ---- host event edges ------------------------------------------------
    logic        key_tog_q;
    logic        mouse_tog_q;
    wire         key_event   = (ps2_key[10]   != key_tog_q);
    wire         mouse_event = (ps2_mouse[24] != mouse_tog_q);

    // SCAN-CODE SET 3, BECAUSE IRIX ASKS FOR IT. hps_io delivers set 2, and up to
    // build 51 the controller acknowledged `F0 03` and kept sending set 2. Most
    // keys - the letters among them - have the same code in both sets, so
    // typing looked right, but set 2's Left Alt (11) is set 3's Left Ctrl and
    // set 2's Left Ctrl (14) is set 3's Caps Lock: under IRIX Alt+x gave ^X and
    // Ctrl toggled Caps Lock. In set 3 every key has one code of its own - no
    // E0 prefix - and a release is F0 and that code. The table pairs IRIS's
    // ScancodeSet2 and ScancodeSet3 (iris src/ps2.rs) key by key, plus
    // hps_io's own codes for Print Screen (E0 7C) and Pause (E0 77). A key with
    // no set-3 code is dropped. {valid, set-3 code} from {extended, set-2 code}.
    function logic [8:0] set3(input logic [8:0] k);
        case (k)
            9'h001: set3 = {1'b1, 8'h47};   // F9
            9'h003: set3 = {1'b1, 8'h27};   // F5
            9'h004: set3 = {1'b1, 8'h17};   // F3
            9'h005: set3 = {1'b1, 8'h07};   // F1
            9'h006: set3 = {1'b1, 8'h0F};   // F2
            9'h007: set3 = {1'b1, 8'h5E};   // F12
            9'h009: set3 = {1'b1, 8'h4F};   // F10
            9'h00A: set3 = {1'b1, 8'h3F};   // F8
            9'h00B: set3 = {1'b1, 8'h2F};   // F6
            9'h00C: set3 = {1'b1, 8'h1F};   // F4
            9'h00D: set3 = {1'b1, 8'h0D};   // Tab
            9'h00E: set3 = {1'b1, 8'h0E};   // Backquote
            9'h011: set3 = {1'b1, 8'h19};   // LAlt
            9'h012: set3 = {1'b1, 8'h12};   // LShift
            9'h014: set3 = {1'b1, 8'h11};   // LCtrl
            9'h015: set3 = {1'b1, 8'h15};   // Q
            9'h016: set3 = {1'b1, 8'h16};   // Key1
            9'h01A: set3 = {1'b1, 8'h1A};   // Z
            9'h01B: set3 = {1'b1, 8'h1B};   // S
            9'h01C: set3 = {1'b1, 8'h1C};   // A
            9'h01D: set3 = {1'b1, 8'h1D};   // W
            9'h01E: set3 = {1'b1, 8'h1E};   // Key2
            9'h021: set3 = {1'b1, 8'h21};   // C
            9'h022: set3 = {1'b1, 8'h22};   // X
            9'h023: set3 = {1'b1, 8'h23};   // D
            9'h024: set3 = {1'b1, 8'h24};   // E
            9'h025: set3 = {1'b1, 8'h25};   // Key4
            9'h026: set3 = {1'b1, 8'h26};   // Key3
            9'h029: set3 = {1'b1, 8'h29};   // Space
            9'h02A: set3 = {1'b1, 8'h2A};   // V
            9'h02B: set3 = {1'b1, 8'h2B};   // F
            9'h02C: set3 = {1'b1, 8'h2C};   // T
            9'h02D: set3 = {1'b1, 8'h2D};   // R
            9'h02E: set3 = {1'b1, 8'h2E};   // Key5
            9'h031: set3 = {1'b1, 8'h31};   // N
            9'h032: set3 = {1'b1, 8'h32};   // B
            9'h033: set3 = {1'b1, 8'h33};   // H
            9'h034: set3 = {1'b1, 8'h34};   // G
            9'h035: set3 = {1'b1, 8'h35};   // Y
            9'h036: set3 = {1'b1, 8'h36};   // Key6
            9'h03A: set3 = {1'b1, 8'h3A};   // M
            9'h03B: set3 = {1'b1, 8'h3B};   // J
            9'h03C: set3 = {1'b1, 8'h3C};   // U
            9'h03D: set3 = {1'b1, 8'h3D};   // Key7
            9'h03E: set3 = {1'b1, 8'h3E};   // Key8
            9'h041: set3 = {1'b1, 8'h41};   // Comma
            9'h042: set3 = {1'b1, 8'h42};   // K
            9'h043: set3 = {1'b1, 8'h43};   // I
            9'h044: set3 = {1'b1, 8'h44};   // O
            9'h045: set3 = {1'b1, 8'h45};   // Key0
            9'h046: set3 = {1'b1, 8'h46};   // Key9
            9'h049: set3 = {1'b1, 8'h49};   // Period
            9'h04A: set3 = {1'b1, 8'h4A};   // Slash
            9'h04B: set3 = {1'b1, 8'h4B};   // L
            9'h04C: set3 = {1'b1, 8'h4C};   // Semicolon
            9'h04D: set3 = {1'b1, 8'h4D};   // P
            9'h04E: set3 = {1'b1, 8'h4E};   // Minus
            9'h052: set3 = {1'b1, 8'h52};   // Quote
            9'h054: set3 = {1'b1, 8'h54};   // LBracket
            9'h055: set3 = {1'b1, 8'h55};   // Equals
            9'h058: set3 = {1'b1, 8'h14};   // CapsLock
            9'h059: set3 = {1'b1, 8'h59};   // RShift
            9'h05A: set3 = {1'b1, 8'h5A};   // Enter
            9'h05B: set3 = {1'b1, 8'h5B};   // RBracket
            9'h05D: set3 = {1'b1, 8'h5C};   // Backslash
            9'h061: set3 = {1'b1, 8'h13};   // IntlBackslash
            9'h066: set3 = {1'b1, 8'h66};   // Backspace
            9'h069: set3 = {1'b1, 8'h69};   // Keypad1
            9'h06B: set3 = {1'b1, 8'h6B};   // Keypad4
            9'h06C: set3 = {1'b1, 8'h6C};   // Keypad7
            9'h070: set3 = {1'b1, 8'h70};   // Keypad0
            9'h071: set3 = {1'b1, 8'h71};   // KeypadPeriod
            9'h072: set3 = {1'b1, 8'h72};   // Keypad2
            9'h073: set3 = {1'b1, 8'h73};   // Keypad5
            9'h074: set3 = {1'b1, 8'h74};   // Keypad6
            9'h075: set3 = {1'b1, 8'h75};   // Keypad8
            9'h076: set3 = {1'b1, 8'h08};   // Esc
            9'h077: set3 = {1'b1, 8'h76};   // NumLock
            9'h078: set3 = {1'b1, 8'h56};   // F11
            9'h079: set3 = {1'b1, 8'h7C};   // KeypadPlus
            9'h07A: set3 = {1'b1, 8'h7A};   // Keypad3
            9'h07B: set3 = {1'b1, 8'h84};   // KeypadMinus
            9'h07C: set3 = {1'b1, 8'h7E};   // KeypadStar
            9'h07D: set3 = {1'b1, 8'h7D};   // Keypad9
            9'h07E: set3 = {1'b1, 8'h5F};   // ScrollLock
            9'h083: set3 = {1'b1, 8'h37};   // F7
            9'h111: set3 = {1'b1, 8'h39};   // RAlt
            9'h114: set3 = {1'b1, 8'h58};   // RCtrl
            9'h11F: set3 = {1'b1, 8'h8B};   // LGUI
            9'h127: set3 = {1'b1, 8'h8C};   // RGUI
            9'h12F: set3 = {1'b1, 8'h8D};   // Apps
            9'h14A: set3 = {1'b1, 8'h77};   // KeypadSlash
            9'h15A: set3 = {1'b1, 8'h79};   // KeypadEnter
            9'h169: set3 = {1'b1, 8'h65};   // End
            9'h16B: set3 = {1'b1, 8'h61};   // Left
            9'h16C: set3 = {1'b1, 8'h6E};   // Home
            9'h170: set3 = {1'b1, 8'h67};   // Insert
            9'h171: set3 = {1'b1, 8'h64};   // Delete
            9'h172: set3 = {1'b1, 8'h60};   // Down
            9'h174: set3 = {1'b1, 8'h6A};   // Right
            9'h175: set3 = {1'b1, 8'h63};   // Up
            9'h177: set3 = {1'b1, 8'h62};   // Pause
            9'h17A: set3 = {1'b1, 8'h6D};   // PageDown
            9'h17C: set3 = {1'b1, 8'h57};   // PrintScreen
            9'h17D: set3 = {1'b1, 8'h6F};   // PageUp
            default: set3 = 9'h000;
        endcase
    endfunction
    wire [8:0] key_set3 = set3(ps2_key[8:0]);

    // A key event is up to three bytes (E0 F0 code) and a mouse packet three,
    // so both are emitted by a small sequencer rather than in one cycle.
    logic [1:0]  key_phase;
    logic [1:0]  mouse_phase;
    logic        key_busy, mouse_busy;
    logic        key_pressed_l;
    logic  [7:0] key_code_l;
    logic  [7:0] m_b0, m_b1, m_b2;

    assign irq_kbd   = !q_empty && !q_front[8] && config_byte[0];
    assign irq_mouse = !q_empty &&  q_front[8] && config_byte[1];

    // ps2_mouse is not a decoded form - hps_io passes the three bytes of the
    // real PS/2 packet straight through (hps_io.sv:368-370), so byte 0 with
    // its buttons, sign and overflow bits is [7:0], dx is [15:8] and dy is
    // [23:16]. Nothing to assemble: the mouse already said exactly this on
    // the wire and the guest wants it back unchanged.

    integer i;

    always_ff @(posedge clk) begin
        push_en  <= 1'b0;
        push_val <= 9'h000;

        if (reset) begin
            q_head              <= 0;
            q_tail              <= 0;
            q_count             <= 0;
            config_byte         <= 8'h47;
            next_write_is_mouse <= 1'b0;
            kbd_scanning        <= 1'b1;
            kbd_set             <= 2'd2;
            mouse_enabled       <= 1'b0;
            mouse_id            <= 8'h00;
            mouse_resolution    <= 8'h02;
            mouse_sample_rate   <= 8'd100;
            arg_state           <= ARG_NONE;
            // THE HOST'S TOGGLES ARE NOT RESET, SO THEY ARE COPIED, NOT CLEARED.
            // hps_io flips ps2_key[10] / ps2_mouse[24] once per event and keeps
            // them across a machine reset. Clearing these to 0 made the first
            // clock after every reset with a toggle at 1 look like a new event:
            // the last key or mouse packet was replayed into the output buffer
            // while the PROM ran its controller self-test, which then failed -
            // "PC keyboard/mouse controller diagnostic *FAILED* / Check or
            // replace: CPU base board" after about half of all OSD resets
            // (build 51, 3 of 5 on the board). verilator/tb_i8042.cpp.
            key_tog_q           <= ps2_key[10];
            mouse_tog_q         <= ps2_mouse[24];
            key_phase           <= 2'd0;
            mouse_phase         <= 2'd0;
            key_busy            <= 1'b0;
            mouse_busy          <= 1'b0;
            pend_cnt            <= 2'd0;
            dout_r              <= 8'h00;
        end else if (ce) begin
            if (sel)
                dout_r <= is_cmd ? status : (q_empty ? 8'h00 : q_front[7:0]);

            // ---- queue maintenance ---------------------------------------
            if (push_en && !pop_en) begin
                queue[q_tail] <= push_val;
                q_tail        <= q_tail + 1'b1;
                q_count       <= q_count + 1'b1;
            end else if (!push_en && pop_en) begin
                q_head  <= q_head + 1'b1;
                q_count <= q_count - 1'b1;
            end else if (push_en && pop_en) begin
                queue[q_tail] <= push_val;
                q_tail        <= q_tail + 1'b1;
                q_head        <= q_head + 1'b1;
            end

            // ---- register access -----------------------------------------
            if (sel && we) begin
                if (is_cmd) begin
                    // Controller command port.
                    next_write_is_mouse <= 1'b0;
                    arg_state           <= ARG_NONE;
                    case (din)
                        // Self-test. 0x55 is "controller passed"; the 0xAA
                        // that follows is the keyboard's own BAT result,
                        // which a real machine sees because the reset also
                        // resets the keyboard.
                        8'hAA: begin
                            push_en  <= 1'b1; push_val <= {1'b0, 8'h55};
                            pend_cnt <= 2'd1; pend_b0 <= {1'b0, 8'hAA};
                        end
                        // Keyboard interface test: 0x00 = no error.
                        8'hAB: begin push_en <= 1'b1; push_val <= {1'b0, 8'h00}; end
                        // Mouse interface test: same.
                        8'hA9: begin push_en <= 1'b1; push_val <= {1'b0, 8'h00}; end
                        8'h20: begin push_en <= 1'b1; push_val <= {1'b0, config_byte}; end
                        8'h60: arg_state           <= ARG_WRITE_CONFIG;
                        8'hD4: next_write_is_mouse <= 1'b1;
                        8'hD3: arg_state           <= ARG_AUX_LOOP;
                        8'hA7: config_byte         <= config_byte |  8'h20;
                        8'hA8: config_byte         <= config_byte & ~8'h20;
                        8'hAD: config_byte         <= config_byte |  8'h10;
                        8'hAE: config_byte         <= config_byte & ~8'h10;
                        default: ;   // unsupported commands are dropped
                    endcase
                end else begin
                    // Data port. Either an argument to the last command, or a
                    // command for one of the two devices.
                    if (arg_state != ARG_NONE) begin
                        arg_state <= ARG_NONE;
                        case (arg_state)
                            ARG_WRITE_CONFIG:     config_byte <= din;
                            ARG_AUX_LOOP:  begin push_en <= 1'b1; push_val <= {1'b1, din}; end
                            ARG_MOUSE_RESOLUTION: begin
                                mouse_resolution <= din;
                                push_en <= 1'b1; push_val <= {1'b1, 8'hFA};
                            end
                            ARG_MOUSE_SAMPLE: begin
                                mouse_sample_rate <= din;
                                push_en <= 1'b1; push_val <= {1'b1, 8'hFA};
                            end
                            // F0's argument: 00 asks for the set (ACK, then the set
                            // number, as IRIS answers), 02 and 03 select one. Set 1
                            // is acknowledged and not taken - nothing here can make it.
                            ARG_KBD_SCANSET: begin
                                push_en <= 1'b1; push_val <= {1'b0, 8'hFA};
                                if (din == 8'h00) begin
                                    pend_cnt <= 2'd1; pend_b0 <= {1'b0, 6'd0, kbd_set};
                                end else if (din == 8'h02 || din == 8'h03)
                                    kbd_set <= din[1:0];
                            end
                            // The keyboard acknowledges every argument too.
                            default: begin push_en <= 1'b1; push_val <= {1'b0, 8'hFA}; end
                        endcase
                    end else if (next_write_is_mouse) begin
                        next_write_is_mouse <= 1'b0;
                        case (din)
                            8'hFF: begin  // reset: ACK, then BAT, then the ID
                                mouse_enabled <= 1'b0;
                                mouse_id      <= 8'h00;
                                push_en  <= 1'b1; push_val <= {1'b1, 8'hFA};
                                pend_cnt <= 2'd2;
                                pend_b0  <= {1'b1, 8'hAA};
                                pend_b1  <= {1'b1, 8'h00};
                            end
                            8'hF2: begin  // identify: ACK, then the device ID
                                push_en  <= 1'b1; push_val <= {1'b1, 8'hFA};
                                pend_cnt <= 2'd1; pend_b0 <= {1'b1, mouse_id};
                            end
                            8'hF3: begin arg_state <= ARG_MOUSE_SAMPLE;
                                         push_en <= 1'b1; push_val <= {1'b1, 8'hFA}; end
                            8'hE8: begin arg_state <= ARG_MOUSE_RESOLUTION;
                                         push_en <= 1'b1; push_val <= {1'b1, 8'hFA}; end
                            8'hF4: begin mouse_enabled <= 1'b1;
                                         push_en <= 1'b1; push_val <= {1'b1, 8'hFA}; end
                            8'hF5: begin mouse_enabled <= 1'b0;
                                         push_en <= 1'b1; push_val <= {1'b1, 8'hFA}; end
                            default: begin push_en <= 1'b1; push_val <= {1'b1, 8'hFA}; end
                        endcase
                    end else begin
                        case (din)
                            8'hFF: begin  // reset: ACK, then the BAT result
                                kbd_scanning <= 1'b1;
                                kbd_set      <= 2'd2;
                                push_en  <= 1'b1; push_val <= {1'b0, 8'hFA};
                                pend_cnt <= 2'd1; pend_b0 <= {1'b0, 8'hAA};
                            end
                            8'hF2: begin  // identify: ACK, then 0xAB 0x83
                                push_en  <= 1'b1; push_val <= {1'b0, 8'hFA};
                                pend_cnt <= 2'd2;
                                pend_b0  <= {1'b0, 8'hAB};
                                pend_b1  <= {1'b0, 8'h83};
                            end
                            8'hED: begin arg_state <= ARG_KBD_LEDS;
                                         push_en <= 1'b1; push_val <= {1'b0, 8'hFA}; end
                            8'hF0: begin arg_state <= ARG_KBD_SCANSET;
                                         push_en <= 1'b1; push_val <= {1'b0, 8'hFA}; end
                            8'hF3: begin arg_state <= ARG_KBD_TYPEMATIC;
                                         push_en <= 1'b1; push_val <= {1'b0, 8'hFA}; end
                            8'hF4: begin kbd_scanning <= 1'b1;
                                         push_en <= 1'b1; push_val <= {1'b0, 8'hFA}; end
                            8'hF5: begin kbd_scanning <= 1'b0;
                                         push_en <= 1'b1; push_val <= {1'b0, 8'hFA}; end
                            default: begin push_en <= 1'b1; push_val <= {1'b0, 8'hFA}; end
                        endcase
                    end
                end
            end

            // ---- staged multi-byte responses -----------------------------
            else if (pend_cnt != 2'd0) begin
                push_en  <= 1'b1;
                push_val <= pend_b0;
                pend_b0  <= pend_b1;
                pend_cnt <= pend_cnt - 1'b1;
            end

            // ---- keyboard event sequencer --------------------------------
            // Runs only when the bus is idle, so a push from a command and a
            // push from a keystroke can never collide on the single port.
            else if (key_busy) begin
                case (key_phase)
                    2'd0: begin
                        push_en  <= 1'b1;
                        push_val <= {1'b0, 8'hE0};
                        key_phase <= 2'd1;
                    end
                    2'd1: begin
                        if (!key_pressed_l) begin
                            push_en   <= 1'b1;
                            push_val  <= {1'b0, 8'hF0};
                            key_phase <= 2'd2;
                        end else begin
                            push_en   <= 1'b1;
                            push_val  <= {1'b0, key_code_l};
                            key_busy  <= 1'b0;
                        end
                    end
                    default: begin
                        push_en  <= 1'b1;
                        push_val <= {1'b0, key_code_l};
                        key_busy <= 1'b0;
                    end
                endcase
            end
            else if (mouse_busy) begin
                case (mouse_phase)
                    2'd0: begin push_en <= 1'b1; push_val <= {1'b1, m_b0}; mouse_phase <= 2'd1; end
                    2'd1: begin push_en <= 1'b1; push_val <= {1'b1, m_b1}; mouse_phase <= 2'd2; end
                    default: begin push_en <= 1'b1; push_val <= {1'b1, m_b2}; mouse_busy <= 1'b0; end
                endcase
            end
            // ---- new host events -----------------------------------------
            else if (key_event) begin
                key_tog_q <= ps2_key[10];
                // Dropped rather than queued when the port is disabled, the
                // keyboard is not scanning, or the queue is nearly full. A
                // lost keystroke is better than a queue that overruns into
                // the middle of a mouse packet.
                if (kbd_scanning && !config_byte[4] && !q_full) begin
                    if (kbd_set == 2'd3) begin
                        // Set 3: the key's own code, never an E0 phase.
                        if (key_set3[8]) begin
                            key_pressed_l  <= ps2_key[9];
                            key_code_l     <= key_set3[7:0];
                            key_busy       <= 1'b1;
                            key_phase      <= 2'd1;
                        end
                    end else begin
                        key_pressed_l  <= ps2_key[9];
                        key_code_l     <= ps2_key[7:0];
                        key_busy       <= 1'b1;
                        // Skip the 0xE0 phase for an ordinary key.
                        key_phase      <= ps2_key[8] ? 2'd0 : 2'd1;
                    end
                end
            end
            else if (mouse_event) begin
                mouse_tog_q <= ps2_mouse[24];
                if (mouse_enabled && !config_byte[5] && !q_full) begin
                    m_b0 <= ps2_mouse[7:0];
                    m_b1 <= ps2_mouse[15:8];
                    m_b2 <= ps2_mouse[23:16];
                    mouse_busy  <= 1'b1;
                    mouse_phase <= 2'd0;
                end
            end
        end
    end

endmodule
