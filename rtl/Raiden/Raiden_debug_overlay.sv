// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Umberto Parisi (rmonic79). GPL v3 or later.
//
// Raiden_debug_overlay — overlay diagnostico CPU Main+Sub.
// Renderizza in alto a sinistra dello schermo, sopra il pixel pipeline arcade.
// Layout (8x8 char, riga = 8 px screen):
//   row0  "M:HHHHH  C:HH HB"    Main PC (20-bit) + ctrl_reg + heartbeat
//   row1  "S:HHHHH        HB"   Sub  PC (20-bit) + heartbeat
//   row2  "MWR:DDDD SWR:DDDD"   counters write shared (Main/Sub, 16-bit)
//
// Tutti i numeri hex. Le cifre lampeggianti = heartbeat (toggle ogni 30 frame).
// Niente Signal Tap, niente JTAG: pura pixel-overlay sui canali RGB.

module Raiden_debug_overlay (
	input  wire        clk,
	input  wire        ce_pix,
	input  wire        enable,        // off = pass-through totale

	input  wire  [9:0] render_x,
	input  wire  [8:0] render_y,
	input  wire        vblank_pulse,  // 1-cycle pulse a inizio VBlank

	// Probes
	input  wire [19:0] main_pc,
	input  wire [19:0] sub_pc,
	input  wire  [7:0] main_ctrl_reg,
	input  wire        main_ce_pulse, // 1 quando Main V30 esegue 1 ce
	input  wire        sub_ce_pulse,
	input  wire        main_shared_we,
	input  wire        sub_shared_we,

	// Video in/out
	input  wire [7:0]  rgb_r_in,
	input  wire [7:0]  rgb_g_in,
	input  wire [7:0]  rgb_b_in,
	output wire [7:0]  rgb_r_out,
	output wire [7:0]  rgb_g_out,
	output wire [7:0]  rgb_b_out
);

// ─── Heartbeat blinker ───────────────────────────────────────────────────
// Conta vblank; lampeggia ogni 30 frame.
reg [5:0] vbl_cnt;
always @(posedge clk) if (vblank_pulse) vbl_cnt <= vbl_cnt + 6'd1;
wire blink = vbl_cnt[4];   // toggle ~ ogni 16 frame

// ─── Activity counters ───────────────────────────────────────────────────
// Heartbeat conta ce della CPU al secondo (free run, wrap 16-bit).
reg [15:0] main_ce_cnt;
reg [15:0] sub_ce_cnt;
reg [15:0] main_shr_wr_cnt;
reg [15:0] sub_shr_wr_cnt;
always @(posedge clk) begin
	if (main_ce_pulse)  main_ce_cnt     <= main_ce_cnt     + 16'd1;
	if (sub_ce_pulse)   sub_ce_cnt      <= sub_ce_cnt      + 16'd1;
	if (main_shared_we) main_shr_wr_cnt <= main_shr_wr_cnt + 16'd1;
	if (sub_shared_we)  sub_shr_wr_cnt  <= sub_shr_wr_cnt  + 16'd1;
end

// Snapshot a vblank → display stabile (no glitch per pixel-aliasing).
reg [19:0] main_pc_l, sub_pc_l;
reg  [7:0] main_ctrl_l;
reg [15:0] main_ce_l, sub_ce_l, main_shr_l, sub_shr_l;
always @(posedge clk) if (vblank_pulse) begin
	main_pc_l   <= main_pc;
	sub_pc_l    <= sub_pc;
	main_ctrl_l <= main_ctrl_reg;
	main_ce_l   <= main_ce_cnt;
	sub_ce_l    <= sub_ce_cnt;
	main_shr_l  <= main_shr_wr_cnt;
	sub_shr_l   <= sub_shr_wr_cnt;
end

// ─── Char grid ───────────────────────────────────────────────────────────
// 8x8 char, 18 char per riga × 3 righe in alto sinistra.
// origin (x=0, y=0).
localparam [9:0] ORIGIN_X = 10'd0;
localparam [8:0] ORIGIN_Y = 9'd0;
localparam [3:0] CHARS_PER_ROW = 4'd18;
localparam [3:0] ROWS          = 4'd3;

wire [9:0] dx = render_x - ORIGIN_X;
wire [8:0] dy = render_y - ORIGIN_Y;

wire in_grid_x = (render_x >= ORIGIN_X) && (dx[9:3] < {3'd0, CHARS_PER_ROW});
wire in_grid_y = (render_y >= ORIGIN_Y) && (dy[8:3] < {2'd0, ROWS});
wire in_grid   = enable && in_grid_x && in_grid_y;

wire [4:0] char_col = dx[7:3];   // 0..17
wire [1:0] char_row = dy[4:3];   // 0..2
wire [2:0] px_col   = dx[2:0];   // 0..7
wire [2:0] px_row   = dy[2:0];

// ─── Message ROM ─────────────────────────────────────────────────────────
// Per ogni (row, col) genero il codice carattere:
//   - charset: 0..9='0'..'9', 10..15='A'..'F', 16=' ', 17=':', 18='M', 19='S',
//              20='C', 21='W', 22='R', 23='H', 24='B' (heartbeat blink)
// Layout righe (18 char ciascuna):
//   row0: M : H H H H H _ C : H H _ H B _ _ _
//   row1: S : H H H H H _ _ _ _ _ _ _ _ H B _
//   row2: M W R : H H H H _ S W R : H H H H _
//
// HHHHH = PC 20-bit (5 nibble). HB = blink char.
// CC = ctrl_reg 8-bit (2 nibble).
// MWR/SWR DDDD = counter 16-bit (4 nibble).
reg [4:0] char_code;
always @(*) begin
	char_code = 5'd16; // default space
	case (char_row)
		2'd0: case (char_col)
			5'd0:  char_code = 5'd18;             // 'M'
			5'd1:  char_code = 5'd17;             // ':'
			5'd2:  char_code = {1'b0, main_pc_l[19:16]};
			5'd3:  char_code = {1'b0, main_pc_l[15:12]};
			5'd4:  char_code = {1'b0, main_pc_l[11:8]};
			5'd5:  char_code = {1'b0, main_pc_l[7:4]};
			5'd6:  char_code = {1'b0, main_pc_l[3:0]};
			5'd8:  char_code = 5'd20;             // 'C'
			5'd9:  char_code = 5'd17;             // ':'
			5'd10: char_code = {1'b0, main_ctrl_l[7:4]};
			5'd11: char_code = {1'b0, main_ctrl_l[3:0]};
			5'd13: char_code = blink ? 5'd23 : 5'd24;   // 'H'/'B' blink
			default: char_code = 5'd16;
		endcase
		2'd1: case (char_col)
			5'd0:  char_code = 5'd19;             // 'S'
			5'd1:  char_code = 5'd17;             // ':'
			5'd2:  char_code = {1'b0, sub_pc_l[19:16]};
			5'd3:  char_code = {1'b0, sub_pc_l[15:12]};
			5'd4:  char_code = {1'b0, sub_pc_l[11:8]};
			5'd5:  char_code = {1'b0, sub_pc_l[7:4]};
			5'd6:  char_code = {1'b0, sub_pc_l[3:0]};
			5'd14: char_code = blink ? 5'd24 : 5'd23;   // 'B'/'H' blink
			default: char_code = 5'd16;
		endcase
		2'd2: case (char_col)
			5'd0:  char_code = 5'd18;             // 'M'
			5'd1:  char_code = 5'd21;             // 'W'
			5'd2:  char_code = 5'd22;             // 'R'
			5'd3:  char_code = 5'd17;             // ':'
			5'd4:  char_code = {1'b0, main_shr_l[15:12]};
			5'd5:  char_code = {1'b0, main_shr_l[11:8]};
			5'd6:  char_code = {1'b0, main_shr_l[7:4]};
			5'd7:  char_code = {1'b0, main_shr_l[3:0]};
			5'd9:  char_code = 5'd19;             // 'S'
			5'd10: char_code = 5'd21;             // 'W'
			5'd11: char_code = 5'd22;             // 'R'
			5'd12: char_code = 5'd17;             // ':'
			5'd13: char_code = {1'b0, sub_shr_l[15:12]};
			5'd14: char_code = {1'b0, sub_shr_l[11:8]};
			5'd15: char_code = {1'b0, sub_shr_l[7:4]};
			5'd16: char_code = {1'b0, sub_shr_l[3:0]};
			default: char_code = 5'd16;
		endcase
		default: char_code = 5'd16;
	endcase
end

// ─── Font 8x8 inline (solo 25 char) ──────────────────────────────────────
// 1 bit/pixel, 8 row per char. Bit7 = colonna 0 (sinistra).
reg [7:0] font_row;
always @(*) begin
	font_row = 8'd0;
	case (char_code)
		// 0..9
		5'd0:  case (px_row)
			3'd0: font_row=8'b00111100; 3'd1: font_row=8'b01100110;
			3'd2: font_row=8'b01100110; 3'd3: font_row=8'b01100110;
			3'd4: font_row=8'b01100110; 3'd5: font_row=8'b01100110;
			3'd6: font_row=8'b00111100; 3'd7: font_row=8'b00000000;
		endcase
		5'd1:  case (px_row)
			3'd0: font_row=8'b00011000; 3'd1: font_row=8'b00111000;
			3'd2: font_row=8'b00011000; 3'd3: font_row=8'b00011000;
			3'd4: font_row=8'b00011000; 3'd5: font_row=8'b00011000;
			3'd6: font_row=8'b01111110; 3'd7: font_row=8'b00000000;
		endcase
		5'd2:  case (px_row)
			3'd0: font_row=8'b00111100; 3'd1: font_row=8'b01100110;
			3'd2: font_row=8'b00000110; 3'd3: font_row=8'b00011100;
			3'd4: font_row=8'b00110000; 3'd5: font_row=8'b01100000;
			3'd6: font_row=8'b01111110; 3'd7: font_row=8'b00000000;
		endcase
		5'd3:  case (px_row)
			3'd0: font_row=8'b00111100; 3'd1: font_row=8'b01100110;
			3'd2: font_row=8'b00000110; 3'd3: font_row=8'b00011100;
			3'd4: font_row=8'b00000110; 3'd5: font_row=8'b01100110;
			3'd6: font_row=8'b00111100; 3'd7: font_row=8'b00000000;
		endcase
		5'd4:  case (px_row)
			3'd0: font_row=8'b00001100; 3'd1: font_row=8'b00011100;
			3'd2: font_row=8'b00111100; 3'd3: font_row=8'b01101100;
			3'd4: font_row=8'b01111110; 3'd5: font_row=8'b00001100;
			3'd6: font_row=8'b00001100; 3'd7: font_row=8'b00000000;
		endcase
		5'd5:  case (px_row)
			3'd0: font_row=8'b01111110; 3'd1: font_row=8'b01100000;
			3'd2: font_row=8'b01111100; 3'd3: font_row=8'b00000110;
			3'd4: font_row=8'b00000110; 3'd5: font_row=8'b01100110;
			3'd6: font_row=8'b00111100; 3'd7: font_row=8'b00000000;
		endcase
		5'd6:  case (px_row)
			3'd0: font_row=8'b00111100; 3'd1: font_row=8'b01100000;
			3'd2: font_row=8'b01100000; 3'd3: font_row=8'b01111100;
			3'd4: font_row=8'b01100110; 3'd5: font_row=8'b01100110;
			3'd6: font_row=8'b00111100; 3'd7: font_row=8'b00000000;
		endcase
		5'd7:  case (px_row)
			3'd0: font_row=8'b01111110; 3'd1: font_row=8'b00000110;
			3'd2: font_row=8'b00001100; 3'd3: font_row=8'b00011000;
			3'd4: font_row=8'b00110000; 3'd5: font_row=8'b00110000;
			3'd6: font_row=8'b00110000; 3'd7: font_row=8'b00000000;
		endcase
		5'd8:  case (px_row)
			3'd0: font_row=8'b00111100; 3'd1: font_row=8'b01100110;
			3'd2: font_row=8'b01100110; 3'd3: font_row=8'b00111100;
			3'd4: font_row=8'b01100110; 3'd5: font_row=8'b01100110;
			3'd6: font_row=8'b00111100; 3'd7: font_row=8'b00000000;
		endcase
		5'd9:  case (px_row)
			3'd0: font_row=8'b00111100; 3'd1: font_row=8'b01100110;
			3'd2: font_row=8'b01100110; 3'd3: font_row=8'b00111110;
			3'd4: font_row=8'b00000110; 3'd5: font_row=8'b00001100;
			3'd6: font_row=8'b00111000; 3'd7: font_row=8'b00000000;
		endcase
		// A..F
		5'd10: case (px_row)
			3'd0: font_row=8'b00011000; 3'd1: font_row=8'b00111100;
			3'd2: font_row=8'b01100110; 3'd3: font_row=8'b01100110;
			3'd4: font_row=8'b01111110; 3'd5: font_row=8'b01100110;
			3'd6: font_row=8'b01100110; 3'd7: font_row=8'b00000000;
		endcase
		5'd11: case (px_row)
			3'd0: font_row=8'b01111100; 3'd1: font_row=8'b01100110;
			3'd2: font_row=8'b01100110; 3'd3: font_row=8'b01111100;
			3'd4: font_row=8'b01100110; 3'd5: font_row=8'b01100110;
			3'd6: font_row=8'b01111100; 3'd7: font_row=8'b00000000;
		endcase
		5'd12: case (px_row)
			3'd0: font_row=8'b00111100; 3'd1: font_row=8'b01100110;
			3'd2: font_row=8'b01100000; 3'd3: font_row=8'b01100000;
			3'd4: font_row=8'b01100000; 3'd5: font_row=8'b01100110;
			3'd6: font_row=8'b00111100; 3'd7: font_row=8'b00000000;
		endcase
		5'd13: case (px_row)
			3'd0: font_row=8'b01111000; 3'd1: font_row=8'b01101100;
			3'd2: font_row=8'b01100110; 3'd3: font_row=8'b01100110;
			3'd4: font_row=8'b01100110; 3'd5: font_row=8'b01101100;
			3'd6: font_row=8'b01111000; 3'd7: font_row=8'b00000000;
		endcase
		5'd14: case (px_row)
			3'd0: font_row=8'b01111110; 3'd1: font_row=8'b01100000;
			3'd2: font_row=8'b01100000; 3'd3: font_row=8'b01111100;
			3'd4: font_row=8'b01100000; 3'd5: font_row=8'b01100000;
			3'd6: font_row=8'b01111110; 3'd7: font_row=8'b00000000;
		endcase
		5'd15: case (px_row)
			3'd0: font_row=8'b01111110; 3'd1: font_row=8'b01100000;
			3'd2: font_row=8'b01100000; 3'd3: font_row=8'b01111100;
			3'd4: font_row=8'b01100000; 3'd5: font_row=8'b01100000;
			3'd6: font_row=8'b01100000; 3'd7: font_row=8'b00000000;
		endcase
		// 16=' '
		5'd16: font_row = 8'd0;
		// 17=':'
		5'd17: case (px_row)
			3'd1: font_row=8'b00011000; 3'd2: font_row=8'b00011000;
			3'd4: font_row=8'b00011000; 3'd5: font_row=8'b00011000;
			default: font_row = 8'd0;
		endcase
		// 18='M'
		5'd18: case (px_row)
			3'd0: font_row=8'b01100110; 3'd1: font_row=8'b01111110;
			3'd2: font_row=8'b01111110; 3'd3: font_row=8'b01011010;
			3'd4: font_row=8'b01000010; 3'd5: font_row=8'b01000010;
			3'd6: font_row=8'b01000010; 3'd7: font_row=8'b00000000;
		endcase
		// 19='S'
		5'd19: case (px_row)
			3'd0: font_row=8'b00111100; 3'd1: font_row=8'b01100110;
			3'd2: font_row=8'b01100000; 3'd3: font_row=8'b00111100;
			3'd4: font_row=8'b00000110; 3'd5: font_row=8'b01100110;
			3'd6: font_row=8'b00111100; 3'd7: font_row=8'b00000000;
		endcase
		// 20='C'
		5'd20: case (px_row)
			3'd0: font_row=8'b00111100; 3'd1: font_row=8'b01100110;
			3'd2: font_row=8'b01100000; 3'd3: font_row=8'b01100000;
			3'd4: font_row=8'b01100000; 3'd5: font_row=8'b01100110;
			3'd6: font_row=8'b00111100; 3'd7: font_row=8'b00000000;
		endcase
		// 21='W'
		5'd21: case (px_row)
			3'd0: font_row=8'b01000010; 3'd1: font_row=8'b01000010;
			3'd2: font_row=8'b01000010; 3'd3: font_row=8'b01011010;
			3'd4: font_row=8'b01111110; 3'd5: font_row=8'b01111110;
			3'd6: font_row=8'b01100110; 3'd7: font_row=8'b00000000;
		endcase
		// 22='R'
		5'd22: case (px_row)
			3'd0: font_row=8'b01111100; 3'd1: font_row=8'b01100110;
			3'd2: font_row=8'b01100110; 3'd3: font_row=8'b01111100;
			3'd4: font_row=8'b01111000; 3'd5: font_row=8'b01101100;
			3'd6: font_row=8'b01100110; 3'd7: font_row=8'b00000000;
		endcase
		// 23='H'
		5'd23: case (px_row)
			3'd0: font_row=8'b01100110; 3'd1: font_row=8'b01100110;
			3'd2: font_row=8'b01100110; 3'd3: font_row=8'b01111110;
			3'd4: font_row=8'b01100110; 3'd5: font_row=8'b01100110;
			3'd6: font_row=8'b01100110; 3'd7: font_row=8'b00000000;
		endcase
		// 24='B'
		5'd24: case (px_row)
			3'd0: font_row=8'b01111100; 3'd1: font_row=8'b01100110;
			3'd2: font_row=8'b01100110; 3'd3: font_row=8'b01111100;
			3'd4: font_row=8'b01100110; 3'd5: font_row=8'b01100110;
			3'd6: font_row=8'b01111100; 3'd7: font_row=8'b00000000;
		endcase
		default: font_row = 8'd0;
	endcase
end

// Pixel selezione: bit (7 - px_col) del font_row
wire pixel_on = in_grid & font_row[3'd7 - px_col];

// ─── Color: testo bianco su fondo nero opaco (sopra arcade) ──────────────
assign rgb_r_out = !in_grid ? rgb_r_in : (pixel_on ? 8'hFF : 8'h00);
assign rgb_g_out = !in_grid ? rgb_g_in : (pixel_on ? 8'hFF : 8'h00);
assign rgb_b_out = !in_grid ? rgb_b_in : (pixel_on ? 8'hFF : 8'h00);

endmodule
