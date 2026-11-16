//============================================================================
//  cd_audio - no CD audio in this core, deliberately; READ TOC is real.
//
//  WHY THIS FILE EXISTS AT ALL. `scsi.v` reaches a CD-ROM's data path and its
//  audio path through the same switch:
//
//      generate if (CDROM != 0) begin : g_cd_audio
//          cd_audio #(...) cd_audio_i ( ... );
//      end else begin : g_no_cd_audio
//          assign ca_ast_code = 8'h05; ... (every ca_* tied off)
//      end endgenerate
//
//  so `CDROM(1)` - which is what makes the target answer INQUIRY as a CD-ROM,
//  address 2048-byte logical blocks and report capacity in them - also demands
//  a `cd_audio` module. The real one is in the MacLC core and is deliberately
//  NOT vendored here: `rtl/scsi/README.md` records that it pulls in a volume
//  lookup table this core has no use for, and there is no audio path in this
//  machine for it to feed anyway (HAL2 answers its revision register and
//  nothing else - see `rtl/sgi/sgi_hpc3.sv`).
//
//  So this is the `g_no_cd_audio` branch wearing the `g_cd_audio` branch's
//  port list. Every audio output carries the same constant that branch
//  assigns; only the TOC windows are live. **`scsi.v` is not modified**, which is the point:
//  it is vendored, and a data-only CD-ROM should not cost a fork of it.
//
//  THE CONSTANTS ARE COPIED, NOT INVENTED. They are exactly what
//  `g_no_cd_audio` in scsi.v assigns, and they are what a drive with a data
//  disc in it should report:
//
//    ast_code 0x05  audio status "no audio status to return"
//    cur_ctrl 0x14  Q-channel control: data track, digital copy prohibited
//    cur_trk  0x01  track 1
//    disc_audio 0   the disc is not an audio disc, so scsi.v's
//                   `cd_audio_read_rej` never rejects a READ
//
//  READ TOC (0x43) is NOT a constant: a one-track data disc, built from the
//  image size (see below). It used to answer zeroes, which IRIX 6.2 reads as
//  track 1 CONTROL 0 - an audio CD - and so would not mount the disc.
//
//  WHAT THIS COSTS. PLAY/PAUSE/audio-status commands
//  answer as no-ops with nothing behind them, and there is no sound. Reading
//  data blocks off an ISO is unaffected, which is the whole use for a CD-ROM
//  here: `hinv` listing it and, later, booting from it.
//
//  Replacing this with the real engine is a vendoring job, not a rewrite - the
//  port list below is the contract. See docs/FEATURES_EVALUATE.md.
//============================================================================

module cd_audio #(
    parameter [31:0] CLK_HZ = 32'd32_500_000
)(
    input               clk,
    input               rst,        // bus reset from the initiator
    input               bus_rst,
    input               mounted,
    input               img_mounted,
    input        [31:0] img_blocks,

    // Command hand-off from scsi.v's phase machine.
    input               cmd_stb,
    input         [7:0] cmd_op,
    input         [7:0] cdb1, cdb2, cdb3, cdb4, cdb5,
    input         [7:0] cdb6, cdb7, cdb8, cdb9,
    input               read_stb,
    input               eject_stb,

    // MODE SENSE page 0x0E audio port routing and the volume slider.
    input         [7:0] ap_ch0, ap_vol0, ap_ch1, ap_vol1,

    // The block-device channel the real engine uses to fetch audio frames.
    // Held inactive here, so scsi.v's arbitration never grants it and the data
    // path owns the block device outright.
    input               ch_grant,
    output              ca_io_active,
    output              ca_io_rd,
    output       [31:0] ca_io_lba,
    input               io_ack,
    input         [7:0] sd_buff_addr,
    input         [4:0] sd_buff_addr_hi,
    input        [15:0] sd_buff_dout,
    input               sd_buff_wr,

    // READ SUB-CHANNEL / audio status.
    output        [7:0] ast_code,
    output        [7:0] cur_ctrl,
    output        [7:0] cur_trk,
    output        [7:0] abs_m, abs_s, abs_f,
    output        [7:0] rel_m, rel_s, rel_f,

    // The three TOC windows scsi.v reads through.
    input         [8:0] toc_base,
    output        [7:0] toc_q0, toc_q1, toc_q2, toc_q3,
    output              toc_ready,
    input         [8:0] toc43_base,
    output        [7:0] toc43_q0, toc43_q1, toc43_q2, toc43_q3,
    output        [9:0] toc43_len,
    input         [8:0] toc2_base,
    output        [7:0] toc2_q0, toc2_q1, toc2_q2, toc2_q3,
    output        [9:0] toc2_len,

    output              disc_audio,
    output signed [15:0] snd_l,
    output signed [15:0] snd_r,
    output       [31:0] dbg_cda0,
    output       [31:0] dbg_cdur
);

    assign ca_io_active = 1'b0;
    assign ca_io_rd     = 1'b0;
    assign ca_io_lba    = 32'd0;

    assign ast_code     = 8'h05;
    assign cur_ctrl     = 8'h14;
    assign cur_trk      = 8'h01;
    assign abs_m = 8'h00; assign abs_s = 8'h00; assign abs_f = 8'h00;
    assign rel_m = 8'h00; assign rel_s = 8'h00; assign rel_f = 8'h00;

    // ---- READ TOC: one data track, from the image size -------------------
    // What a drive with a single-session data disc in it answers (the same
    // bytes IRIS serves, src/scsi.rs exec_read_toc_pma_atip):
    //
    //   format 0 (toc43, the table in full - scsi.v filters by start track):
    //     [0..3]    00 12 01 01           length 18, first track 1, last 1
    //     [4..11]   00 14 01 00 + addr    track 1: ADR 1 / CONTROL 4 = DATA
    //     [12..19]  00 14 AA 00 + addr    lead-out
    //   format 1 (toc2 plane at 496, the session page):
    //     00 0A 01 01 00 14 01 00 + addr(track 1)
    //   format 2 (toc2 plane at 0, full TOC, always MSF): A0/A1/A2/track 1
    //
    // addr is LBA (track 1 = 0, lead-out = disc length in 2048-byte sectors)
    // or, with CDB byte 1 bit 1 (MSF), 00 M S F (track 1 = 00:02:00, the
    // lead-out = its LBA + 150 frames). CONTROL 0x4 is what makes IRIX 6.2's
    // CD software see a data CD; with the all-zero table this file used to
    // serve, track 1's control read as 0 = two-channel audio.

    // Lead-out, worked out once per image: img_blocks counts 512-byte blocks.
    // M/S/F by repeated subtraction (a few hundred clocks after a mount),
    // because a /4500 and a /75 in logic would cost ALMs for no speed anyone
    // can see. M stops at 255 (a 'CD' that big is not a CD).
    reg  [31:0] blk_seen = 32'd0;
    reg  [31:0] lo_lba   = 32'd0;
    reg  [31:0] lo_rem   = 32'd0;
    reg   [7:0] lo_m = 8'd0, lo_s = 8'd2, lo_f = 8'd0;
    reg   [1:0] lo_st = 2'd0;
    always @(posedge clk) begin
        case (lo_st)
        2'd0: if (|img_blocks && img_blocks != blk_seen) begin
                  blk_seen <= img_blocks;
                  lo_lba   <= {2'b00, img_blocks[31:2]};
                  lo_rem   <= {2'b00, img_blocks[31:2]} + 32'd150;
                  lo_m <= 8'd0; lo_s <= 8'd0; lo_f <= 8'd0;
                  lo_st <= 2'd1;
              end
        2'd1: if (lo_rem >= 32'd4500 && lo_m != 8'hFF) begin
                  lo_rem <= lo_rem - 32'd4500;
                  lo_m   <= lo_m + 8'd1;
              end else lo_st <= 2'd2;
        2'd2: if (lo_rem >= 32'd75 && lo_s != 8'd59) begin
                  lo_rem <= lo_rem - 32'd75;
                  lo_s   <= lo_s + 8'd1;
              end else begin
                  lo_f  <= (lo_rem >= 32'd75) ? 8'd74 : lo_rem[7:0];
                  lo_st <= 2'd0;
              end
        default: lo_st <= 2'd0;
        endcase
    end

    wire msf = cdb1[1];

    // Format 0 table, by address in the full table (scsi.v's ca_t43_addr).
    function [7:0] t43;
        input [8:0] a;
        case (a)
        9'd1:  t43 = 8'h12;
        9'd2,  9'd3, 9'd6: t43 = 8'h01;
        9'd5,  9'd13: t43 = 8'h14;
        9'd10: t43 = msf ? 8'h02 : 8'h00;              // track 1: 00:02:00 / LBA 0
        9'd14: t43 = 8'hAA;
        9'd16: t43 = msf ? 8'h00 : lo_lba[31:24];
        9'd17: t43 = msf ? lo_m  : lo_lba[23:16];
        9'd18: t43 = msf ? lo_s  : lo_lba[15:8];
        9'd19: t43 = msf ? lo_f  : lo_lba[7:0];
        default: t43 = 8'h00;
        endcase
    endfunction

    // scsi.v reads q0 at toc43_base and q1..q3 as the NEXT three bytes it
    // serves. Below byte 4 those are header bytes; past it the start-track
    // filter has moved the descriptors by soff rows (start 0/1: none; any
    // later start, 0xAA included: the lead-out row alone), so the look-ahead
    // across the header's end jumps by the same amount scsi.v's address does.
    wire  [8:0] soff8 = (cdb6 == 8'h00 || cdb6 == 8'h01) ? 9'd0 : 9'd8;
    function [8:0] t43_ahead;
        input [8:0] b;
        input [1:0] i;
        t43_ahead = (b < 9'd4 && b + i >= 9'd4) ? b + i + soff8 : b + i;
    endfunction

    // The toc2 plane: format 2 full TOC at 0, format 1 session page at 496.
    function [7:0] t2;
        input [8:0] a;
        if (a >= 9'd496) case (a - 9'd496)
            9'd1:  t2 = 8'h0A;
            9'd2, 9'd3, 9'd6: t2 = 8'h01;
            9'd5:  t2 = 8'h14;
            9'd10: t2 = msf ? 8'h02 : 8'h00;
            default: t2 = 8'h00;
        endcase else case (a)
            // header: length 46 = 2 + 4 x 11, sessions 1..1
            9'd1:  t2 = 8'd46;
            9'd2, 9'd3: t2 = 8'h01;
            // descriptors at 4 + 11k: session, ADR/CTRL, TNO, POINT,
            // MIN SEC FRAME, ZERO, PMIN PSEC PFRAME
            9'd4, 9'd15, 9'd26, 9'd37: t2 = 8'h01;
            9'd5, 9'd16, 9'd27, 9'd38: t2 = 8'h14;
            9'd7:  t2 = 8'hA0;                         // first track 1, data disc
            9'd12: t2 = 8'h01;
            9'd18: t2 = 8'hA1;                         // last track 1
            9'd23: t2 = 8'h01;
            9'd29: t2 = 8'hA2;                         // lead-out
            9'd34: t2 = lo_m;
            9'd35: t2 = lo_s;
            9'd36: t2 = lo_f;
            9'd40: t2 = 8'h01;                         // track 1 at 00:02:00
            9'd46: t2 = 8'h02;
            default: t2 = 8'h00;
        endcase
    endfunction

    // The Apple 0xC1 window stays empty: no IRIX driver sends 0xC1.
    assign toc_q0 = 8'h00; assign toc_q1 = 8'h00;
    assign toc_q2 = 8'h00; assign toc_q3 = 8'h00;
    assign toc_ready = mounted;

    assign toc43_q0 = t43(toc43_base);
    assign toc43_q1 = t43(t43_ahead(toc43_base, 2'd1));
    assign toc43_q2 = t43(t43_ahead(toc43_base, 2'd2));
    assign toc43_q3 = t43(t43_ahead(toc43_base, 2'd3));
    assign toc43_len = 10'd14;                         // scsi.v: (rows - 1) x 8 + 6

    assign toc2_q0 = t2(toc2_base);
    assign toc2_q1 = t2(toc2_base + 9'd1);
    assign toc2_q2 = t2(toc2_base + 9'd2);
    assign toc2_q3 = t2(toc2_base + 9'd3);
    assign toc2_len = 10'd48;

    assign disc_audio = 1'b0;
    assign snd_l = 16'sd0;
    assign snd_r = 16'sd0;
    assign dbg_cda0 = 32'd0;
    assign dbg_cdur = 32'd0;

endmodule
