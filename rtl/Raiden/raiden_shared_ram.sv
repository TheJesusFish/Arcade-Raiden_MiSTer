// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Umberto Parisi (rmonic79). GPL v3 or later.
//
// Raiden shared RAM Main↔Sub — 2 BRAM SPECULARI, no race, no stall.
//
// 4KB logici (2K word) condivisi. Implementati come 2 BRAM coerenti tra loro:
//   - mem_main_*: vista letta da Main
//   - mem_sub_* : vista letta da Sub
//
// Ogni write viene applicato a ENTRAMBE le BRAM per mantenere coerenza.
// Conflict scrittura simultanea sullo stesso byte: Main wins (priorità statica
// — match HW PCB arbitrato bus).
//
// Letture: ogni CPU legge dalla SUA BRAM, indirizzata col proprio addr.
//   - Latency 1 ciclo (BRAM registered output) uguale alle altre BRAM CPU.
//   - Nessun busy, nessun stall, nessun mux output.
//
// MAME memory map:
//   Main: $08000-$08FFF
//   Sub : $04000-$04FFF

module raiden_shared_ram #(parameter SS_IDX = -1)
(
	input  wire        clk,
	input  wire        reset,

	// Main port (16-bit)
	input  wire [11:1] main_addr,
	input  wire        main_cs,
	input  wire [15:0] main_din,
	output wire [15:0] main_dout,
	input  wire  [1:0] main_we,

	// Sub port (16-bit)
	input  wire [11:1] sub_addr,
	input  wire        sub_cs,
	input  wire [15:0] sub_din,
	output wire [15:0] sub_dout,
	input  wire  [1:0] sub_we,

	// Savestate slave (le due BRAM sono speculari: salvo mem_main, restore su entrambe)
	ssbus_if.slave     ss_shared
);

// Conflict scrittura: Main e Sub allo stesso byte. Main vince.
// In pratica: Sub-write attivo solo se Main NON scrive lo stesso byte.
wire main_wr_lo = main_cs & main_we[0];
wire main_wr_hi = main_cs & main_we[1];
wire sub_wr_lo  = sub_cs  & sub_we[0]
                 & ~(main_wr_lo & (main_addr == sub_addr));
wire sub_wr_hi  = sub_cs  & sub_we[1]
                 & ~(main_wr_hi & (main_addr == sub_addr));

// ── BRAM "mem_main_*" : vista Main ────────────────────────────────────────
// Porta A: write (Main e Sub mux). Porta B: read Main.
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] mem_main_lo [0:2047];
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] mem_main_hi [0:2047];
initial begin
	integer i;
	for (i=0; i<2048; i=i+1) begin mem_main_lo[i]=0; mem_main_hi[i]=0; end
end

// ── Savestate adaptor (write su ENTRAMBE le BRAM, read da mem_main) ──────
// A SS idle: trasparente (write main/sub, read normale). Durante SS: write ssbus
// su idx ssbus, read mem_main[idx] → q_in. Le BRAM restano speculari.
wire        ss_sel = ss_shared.access(SS_IDX);
reg  [15:0] ss_shared_rdata;
wire [10:0] ss_idx  = ss_shared.addr[10:0];
wire        ss_wr   = ss_sel & ss_shared.write;

reg  read_delay_sh;
always @(posedge clk) begin
	ss_shared.setup(SS_IDX, 32'd2048, 1);   // 2048 word, 16 bit
	if (ss_sel) begin
		if (ss_shared.write)     ss_shared.write_ack(SS_IDX);
		else if (ss_shared.read) begin
			if (read_delay_sh) ss_shared.read_response(SS_IDX, {48'd0, ss_shared_rdata});
			read_delay_sh <= 1;
		end
	end else read_delay_sh <= 0;
end

reg [7:0] dout_main_lo_r, dout_main_hi_r;
always @(posedge clk) begin
	if (ss_wr)      mem_main_lo[ss_idx] <= ss_shared.data[7:0];
	else if (main_wr_lo) mem_main_lo[main_addr] <= main_din[7:0];
	else if (sub_wr_lo)  mem_main_lo[sub_addr]  <= sub_din[7:0];
	dout_main_lo_r  <= mem_main_lo[main_addr];
	ss_shared_rdata[7:0] <= mem_main_lo[ss_idx];

	if (ss_wr)      mem_main_hi[ss_idx] <= ss_shared.data[15:8];
	else if (main_wr_hi) mem_main_hi[main_addr] <= main_din[15:8];
	else if (sub_wr_hi)  mem_main_hi[sub_addr]  <= sub_din[15:8];
	dout_main_hi_r  <= mem_main_hi[main_addr];
	ss_shared_rdata[15:8] <= mem_main_hi[ss_idx];
end

// ── BRAM "mem_sub_*" : vista Sub ──────────────────────────────────────────
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] mem_sub_lo [0:2047];
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] mem_sub_hi [0:2047];
initial begin
	integer i;
	for (i=0; i<2048; i=i+1) begin mem_sub_lo[i]=0; mem_sub_hi[i]=0; end
end

reg [7:0] dout_sub_lo_r, dout_sub_hi_r;
always @(posedge clk) begin
	if (ss_wr)      mem_sub_lo[ss_idx] <= ss_shared.data[7:0];   // restore: speculare
	else if (main_wr_lo) mem_sub_lo[main_addr] <= main_din[7:0];
	else if (sub_wr_lo)  mem_sub_lo[sub_addr]  <= sub_din[7:0];
	dout_sub_lo_r <= mem_sub_lo[sub_addr];

	if (ss_wr)      mem_sub_hi[ss_idx] <= ss_shared.data[15:8];
	else if (main_wr_hi) mem_sub_hi[main_addr] <= main_din[15:8];
	else if (sub_wr_hi)  mem_sub_hi[sub_addr]  <= sub_din[15:8];
	dout_sub_hi_r <= mem_sub_hi[sub_addr];
end

assign main_dout = {dout_main_hi_r, dout_main_lo_r};
assign sub_dout  = {dout_sub_hi_r,  dout_sub_lo_r};

endmodule
