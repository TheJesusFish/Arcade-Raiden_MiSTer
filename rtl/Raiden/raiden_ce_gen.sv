// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Umberto Parisi (rmonic79). GPL v3 or later.
//
// Raiden V30 CE generator — divisore intero selezionabile via OSD.
//
// clk_sys = 80 MHz. V30 spec MAME = 10 MHz esatti.
//
// clk_sel[2:0] (da OSD P2O[22:20]):
//   0=10MHz → div 8  (10.0 MHz esatti)  ← spec MAME
//   1=8MHz  → div 10 (8.0 MHz)
//   2=12MHz → div 6  (13.3 MHz)
//   3=16MHz → div 5  (16.0 MHz)
//   4=24MHz → div 4  (20.0 MHz)
//   5=32MHz → div 2  (26.7 MHz)
//
// ce_4x = OGNI clk_sys (pattern R-Type: ce_4x è il clock interno della CPU,
// non un divisore). cpu.vhd richiede ce_4x ogni clk per il microcode/prefetch.
//
// Stall: durante accesso SDRAM in volo (ls245_en o mem_rq_active) il counter
// non avanza. La CPU resta congelata fino a che il dato arriva.

module raiden_ce_gen
(
	input  wire       clk,
	input  wire       reset,
	input  wire       pause,
	input  wire [2:0] clk_sel,
	input  wire       ls245_en,
	input  wire       mem_rq_active,
	output reg        ce,
	output reg        ce_4x
);

reg [3:0] ce_cnt;
reg [3:0] ce_div;

always @(*) begin
	case (clk_sel)
		3'd0: ce_div = 4'd7;   // 10 MHz spec MAME (80/8)
		3'd1: ce_div = 4'd9;   // 8 MHz  (80/10)
		3'd2: ce_div = 4'd5;   // 13.3 MHz (80/6)
		3'd3: ce_div = 4'd4;   // 16 MHz (80/5)
		3'd4: ce_div = 4'd3;   // 20 MHz (80/4)
		3'd5: ce_div = 4'd1;   // 26.7 MHz (80/2)
		default: ce_div = 4'd7;
	endcase
end

wire stall    = ls245_en | mem_rq_active;
wire allow_ce = ~pause & ~stall;

always @(posedge clk) begin
	if (reset) begin
		ce_cnt <= 4'd0;
		ce     <= 1'b0;
		ce_4x  <= 1'b0;
	end else begin
		ce    <= 1'b0;
		ce_4x <= 1'b0;
		if (allow_ce) begin
			// ce_4x: OGNI clk (pattern R-Type m72.v:138). cpu.vhd microcode
			// usa ce_4x come clock interno, non come divisore.
			ce_4x <= 1'b1;
			// ce: ogni ce_div+1 clk → 10 MHz spec MAME a div=7 @ clk_sys=80 MHz
			if (ce_cnt >= ce_div) begin
				ce_cnt <= 4'd0;
				ce     <= 1'b1;
			end else begin
				ce_cnt <= ce_cnt + 4'd1;
			end
		end
	end
end

endmodule
