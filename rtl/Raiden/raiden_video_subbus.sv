// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Umberto Parisi (rmonic79). GPL v3 or later.
//
// Raiden video sub-bus (pattern Irem M72 board_b_d.sv)
// Gestisce BG RAM, FG RAM, Palette RAM con accesso CPU (Sub V30) e renderer.
// Espone DOUT + DOUT_VALID per mux cpu_mem_in del Sub_top.
//
// 3 BRAM dual-port (M10K Cyclone V):
//   bgram   2KB (1K word) — Sub R/W via porta A, renderer R via porta B
//   fgram   2KB (1K word) — Sub R/W via porta A, renderer R via porta B
//   palram  4KB (2K word) — Sub R/W via porta A, renderer R via porta B
//
// MAME memory map Sub:
//   $02000-$027FF  bgram
//   $02800-$02FFF  fgram
//   $03000-$03FFF  palette
//
// Pattern M72 DOUT_VALID = MRD & memrq (= sto producendo dato valido per CPU).

module raiden_video_subbus #(
	parameter SS_IDX_BG = -1,
	parameter SS_IDX_FG = -1,
	parameter SS_IDX_PAL = -1
)
(
	input  wire        clk,
	input  wire        reset,

	// CPU Sub interface (V30 16-bit)
	input  wire [19:0] cpu_addr,        // V30 byte addr
	input  wire        cpu_rd,          // V30 bus_read
	input  wire        cpu_wr,          // V30 bus_write
	input  wire  [1:0] cpu_be,          // V30 bus_be
	input  wire [15:0] cpu_dout,        // V30 bus_datawrite

	// memrq da raiden_addr_sub
	input  wire        bgram_memrq,
	input  wire        fgram_memrq,
	input  wire        palette_memrq,

	// CPU read mux output (pattern M72 DOUT/DOUT_VALID)
	output wire [15:0] DOUT,            // dato letto per CPU Sub
	output wire        DOUT_VALID,      // alto quando DOUT è valido per Sub

	// Renderer porte B (read-only, sempre attive)
	input  wire [10:0] bg_vram_addr,    // tile index renderer
	output wire [15:0] bg_vram_data,    // tile word renderer
	input  wire [10:0] fg_vram_addr,
	output wire [15:0] fg_vram_data,
	input  wire [10:0] pal_vram_addr,   // palette index renderer
	output wire [15:0] pal_vram_data,   // palette word renderer

	// Savestate slaves
	ssbus_if.slave     ss_bg,           // bg_lo/hi 1K
	ssbus_if.slave     ss_fg,           // fg_lo/hi 1K
	ssbus_if.slave     ss_pal           // pal_lo/hi 2K
);

// Word index per CPU access
wire [9:0]  bg_word_addr  = cpu_addr[10:1];   // bgram 1K word
wire [9:0]  fg_word_addr  = cpu_addr[10:1];   // fgram 1K word
wire [10:0] pal_word_addr = cpu_addr[11:1];   // palram 2K word

// Byte enable decode (V30 standard: be=01 byte, be=11 word)
wire wr_lo = cpu_wr && cpu_be[0] && !cpu_be[1] && !cpu_addr[0];
wire wr_hi = cpu_wr && cpu_be[0] && !cpu_be[1] &&  cpu_addr[0];
wire wr_w  = cpu_wr && cpu_be[0] &&  cpu_be[1];

// ─── BG RAM 2KB (1K word) ────────────────────────────────────────────────
// Split lo/hi byte BRAM per byte-enable. Porta A = CPU R/W, Porta B = renderer R.
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] bg_lo [0:1023];
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] bg_hi [0:1023];
initial begin integer i; for (i=0; i<1024; i=i+1) begin bg_lo[i]=0; bg_hi[i]=0; end end

reg [15:0] bg_cpu_rdata;
wire        bg_we_lo_cpu = bgram_memrq && (wr_lo || wr_w);
wire        bg_we_hi_cpu = bgram_memrq && (wr_hi || wr_w);
wire [15:0] bg_wdata_cpu = wr_w ? cpu_dout : {cpu_dout[7:0], cpu_dout[7:0]};
wire [9:0]  bg_idx;
wire        bg_we_lo, bg_we_hi;
wire [15:0] bg_wdata_eff;
ss_ram16_adaptor #(.WIDTHAD(10), .SS_IDX(SS_IDX_BG)) u_ss_bg (
	.clk(clk), .we_lo_in(bg_we_lo_cpu), .we_hi_in(bg_we_hi_cpu),
	.addr_in(bg_word_addr), .wdata_in(bg_wdata_cpu),
	.we_lo_out(bg_we_lo), .we_hi_out(bg_we_hi), .addr_out(bg_idx), .wdata_out(bg_wdata_eff),
	.q_in(bg_cpu_rdata), .ssbus(ss_bg)
);
always @(posedge clk) begin
	if (bg_we_lo) bg_lo[bg_idx] <= bg_wdata_eff[7:0];
	if (bg_we_hi) bg_hi[bg_idx] <= bg_wdata_eff[15:8];
	bg_cpu_rdata <= {bg_hi[bg_idx], bg_lo[bg_idx]};
end

// Renderer porta B (read sempre attivo)
reg [15:0] bg_vram_rdata;
always @(posedge clk) bg_vram_rdata <= {bg_hi[bg_vram_addr[9:0]], bg_lo[bg_vram_addr[9:0]]};
assign bg_vram_data = bg_vram_rdata;

// ─── FG RAM 2KB (1K word) — stessa struttura BG ─────────────────────────
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] fg_lo [0:1023];
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] fg_hi [0:1023];
initial begin integer i; for (i=0; i<1024; i=i+1) begin fg_lo[i]=0; fg_hi[i]=0; end end

reg [15:0] fg_cpu_rdata;
wire        fg_we_lo_cpu = fgram_memrq && (wr_lo || wr_w);
wire        fg_we_hi_cpu = fgram_memrq && (wr_hi || wr_w);
wire [15:0] fg_wdata_cpu = wr_w ? cpu_dout : {cpu_dout[7:0], cpu_dout[7:0]};
wire [9:0]  fg_idx;
wire        fg_we_lo, fg_we_hi;
wire [15:0] fg_wdata_eff;
ss_ram16_adaptor #(.WIDTHAD(10), .SS_IDX(SS_IDX_FG)) u_ss_fg (
	.clk(clk), .we_lo_in(fg_we_lo_cpu), .we_hi_in(fg_we_hi_cpu),
	.addr_in(fg_word_addr), .wdata_in(fg_wdata_cpu),
	.we_lo_out(fg_we_lo), .we_hi_out(fg_we_hi), .addr_out(fg_idx), .wdata_out(fg_wdata_eff),
	.q_in(fg_cpu_rdata), .ssbus(ss_fg)
);
always @(posedge clk) begin
	if (fg_we_lo) fg_lo[fg_idx] <= fg_wdata_eff[7:0];
	if (fg_we_hi) fg_hi[fg_idx] <= fg_wdata_eff[15:8];
	fg_cpu_rdata <= {fg_hi[fg_idx], fg_lo[fg_idx]};
end

reg [15:0] fg_vram_rdata;
always @(posedge clk) fg_vram_rdata <= {fg_hi[fg_vram_addr[9:0]], fg_lo[fg_vram_addr[9:0]]};
assign fg_vram_data = fg_vram_rdata;

// ─── Palette RAM 4KB (2K word, xBGR_444) ────────────────────────────────
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] pal_lo [0:2047];
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] pal_hi [0:2047];
initial begin integer i; for (i=0; i<2048; i=i+1) begin pal_lo[i]=0; pal_hi[i]=0; end end

reg [15:0] pal_cpu_rdata;
wire        pal_we_lo_cpu = palette_memrq && (wr_lo || wr_w);
wire        pal_we_hi_cpu = palette_memrq && (wr_hi || wr_w);
wire [15:0] pal_wdata_cpu = wr_w ? cpu_dout : {cpu_dout[7:0], cpu_dout[7:0]};
wire [10:0] pal_idx;
wire        pal_we_lo, pal_we_hi;
wire [15:0] pal_wdata_eff;
ss_ram16_adaptor #(.WIDTHAD(11), .SS_IDX(SS_IDX_PAL)) u_ss_pal (
	.clk(clk), .we_lo_in(pal_we_lo_cpu), .we_hi_in(pal_we_hi_cpu),
	.addr_in(pal_word_addr), .wdata_in(pal_wdata_cpu),
	.we_lo_out(pal_we_lo), .we_hi_out(pal_we_hi), .addr_out(pal_idx), .wdata_out(pal_wdata_eff),
	.q_in(pal_cpu_rdata), .ssbus(ss_pal)
);
always @(posedge clk) begin
	if (pal_we_lo) pal_lo[pal_idx] <= pal_wdata_eff[7:0];
	if (pal_we_hi) pal_hi[pal_idx] <= pal_wdata_eff[15:8];
	pal_cpu_rdata <= {pal_hi[pal_idx], pal_lo[pal_idx]};
end

reg [15:0] pal_vram_rdata;
always @(posedge clk) pal_vram_rdata <= {pal_hi[pal_vram_addr], pal_lo[pal_vram_addr]};
assign pal_vram_data = pal_vram_rdata;

// ─── DOUT_VALID + DOUT mux (pattern M72 board_b_d) ──────────────────────
// DOUT_VALID = MRD & (qualsiasi memrq attivo)
// DOUT = mux su memrq (priorità: bgram > fgram > palette, ma è esclusivo)
//
// V30 byte alignment: cpu_din[7:0] deve contenere il byte all'indirizzo
// richiesto. Mux interno a CPU bus side gestisce byte swap se cpu_addr[0]=1.

// Latch "che ho appena letto" per allineare con BRAM 1-cycle latency
reg bgram_rd_lat, fgram_rd_lat, palette_rd_lat;
reg cpu_addr_lo_lat;

always @(posedge clk) begin
	if (reset) begin
		bgram_rd_lat    <= 1'b0;
		fgram_rd_lat    <= 1'b0;
		palette_rd_lat  <= 1'b0;
		cpu_addr_lo_lat <= 1'b0;
	end else begin
		// Latch decoder ogni ciclo (pattern M72 _valid_lat)
		bgram_rd_lat    <= cpu_rd & bgram_memrq;
		fgram_rd_lat    <= cpu_rd & fgram_memrq;
		palette_rd_lat  <= cpu_rd & palette_memrq;
		cpu_addr_lo_lat <= cpu_addr[0];
	end
end

// Byte align (V30 vuole byte richiesto sempre su [7:0])
function [15:0] byte_align;
	input [15:0] data;
	input        addr_lo;
	begin
		byte_align = addr_lo ? {data[7:0], data[15:8]} : data;
	end
endfunction

assign DOUT_VALID = bgram_rd_lat | fgram_rd_lat | palette_rd_lat;

assign DOUT = bgram_rd_lat   ? byte_align(bg_cpu_rdata,  cpu_addr_lo_lat) :
              fgram_rd_lat   ? byte_align(fg_cpu_rdata,  cpu_addr_lo_lat) :
              palette_rd_lat ? byte_align(pal_cpu_rdata, cpu_addr_lo_lat) :
              16'h0000;

endmodule
