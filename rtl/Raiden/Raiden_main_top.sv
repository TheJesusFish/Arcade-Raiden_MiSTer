// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Umberto Parisi (rmonic79). GPL v3 or later.
//
// Raiden_main_top — Main V30 + memory map M72-style.
// Refactor pattern Irem M72:
//  - raiden_addr_main: address translator (memrq + ls245_en + sdr_addr)
//  - raiden_ce_gen:    CE generator (stall su mem_rq_active + ls245_en)
//  - raiden_sdram_bridge_cpu: ls245_en→toggle SDRAM req, latch dout
//  - raiden_sprite_mainbus: spriteram + buffer (BUFFERED_SPRITERAM16)
//  - Main RAM 28KB BRAM interno (pattern M72 per region writable interna)
//  - shared RAM 4KB: instanziata in TOP (modulo raiden_shared_ram), porte esposte
//  - DOUT_VALID mux per cpu_din (pattern M72 m72.v:319-329)

module Raiden_main_top #(parameter SS_IDX_SPR = -1, parameter SS_IDX_CPU = -1) (
	input  wire        clk,
	input  wire        reset,
	input  wire        pause,
	// OSD CPU speed select (legacy port, ignorato — sempre 10 MHz)
	input  wire  [2:0] clk_sel,
	// Inputs HW
	input  wire  [7:0] p1_input,
	input  wire  [7:0] p2_input,
	input  wire [15:0] dsw_input,
	// SDRAM ROM Main bridge (Raiden.sv toplevel)
	input  wire [15:0] main_rom_rdata,
	input  wire        main_rom_ready,
	output wire [23:0] main_rom_addr,
	output wire        main_rom_req,
	// VBLANK per IRQ
	input  wire        vblank_in,
	// ioctl_download (legacy, non usato qui)
	input  wire        ioctl_download,
	// Layer control output
	output wire        ctrl_bg_en,
	output wire        ctrl_fg_en,
	output wire        ctrl_tx_en,
	output wire        ctrl_sp_en,
	output wire        ctrl_flipscreen,
	// Scroll registers $0F000-$0F03F flat 32 word
	output wire [511:0] scroll_words_flat,
	// Sound stub
	output wire        snd_cs,
	output wire  [3:1] snd_addr,
	output wire        snd_wr,
	output wire        snd_rd,
	output wire [15:0] snd_wdata,
	input  wire [15:0] snd_rdata,
	// VRAM read ports (text + sprite renderer)
	input  wire [10:0] text_vram_addr,
	output wire [15:0] text_vram_data,
	input  wire [10:0] spr_vram_addr,
	output wire [15:0] spr_vram_data,
	// Shared RAM Main↔Sub bridge — Main side (porte verso top: raiden_shared_ram)
	output wire [11:1] main_shared_addr,
	output wire        main_shared_cs,
	output wire  [1:0] main_shared_we,
	output wire [15:0] main_shared_wdata,
	input  wire [15:0] main_shared_rdata,
	// Probe
	output wire        dbg_irq_pending,
	// Savestate slaves (ssbus). Solo le BRAM che vivono in questo modulo.
	ssbus_if.slave     ss_workram,   // ram_lo/hi 14K (SS_IDX 0)
	ssbus_if.slave     ss_txt,       // txt_lo/hi 1K  (SS_IDX 1)
	ssbus_if.slave     ss_scroll,    // scroll_ram 32w (SS_IDX 2)
	ssbus_if.slave     ss_spr,       // spr_lo/hi 2K  (SS_IDX 7, → sprite_mainbus)
	ssbus_if.slave     ss_cpu,       // V30 main regs (SS_IDX 8, → cpu_v30_bridge)
	input  wire        ss_cpu_reload // reset CPU coordinato (post-load)
);

// ─── V30 CPU bus ────────────────────────────────────────────────────────
wire [19:0] cpu_addr;
wire        cpu_rd, cpu_wr;
wire  [1:0] cpu_be;
wire [15:0] cpu_dout;
reg  [15:0] cpu_din;

// ─── IRQ handler (vblank rising → vector $0C8) ──────────────────────────
reg  vblank_d;
reg  irq_pending;
wire cpu_irq_active;
always @(posedge clk) begin
	if (reset) begin
		vblank_d    <= 1'b0;
		irq_pending <= 1'b0;
	end else begin
		vblank_d <= vblank_in;
		if (vblank_in && !vblank_d)        irq_pending <= 1'b1;
		if (cpu_irq_active && irq_pending) irq_pending <= 1'b0;
	end
end
assign dbg_irq_pending = irq_pending;

// ─── Address translator (M72 pal.sv pattern) ────────────────────────────
wire        ls245_en;
wire [23:0] sdr_addr;
wire        ram_memrq, sprite_memrq, shared_memrq, sound_memrq;
wire        text_memrq, p1p2_memrq, dsw_memrq, watchdog_memrq;
wire        ctrl_memrq, scroll_memrq;
wire        DBEN = cpu_rd | cpu_wr;

raiden_addr_main u_addr (
	.A             (cpu_addr),
	.DBEN          (DBEN),
	.ls245_en      (ls245_en),
	.sdr_addr      (sdr_addr),
	.ram_memrq     (ram_memrq),
	.sprite_memrq  (sprite_memrq),
	.shared_memrq  (shared_memrq),
	.sound_memrq   (sound_memrq),
	.text_memrq    (text_memrq),
	.p1p2_memrq    (p1p2_memrq),
	.dsw_memrq     (dsw_memrq),
	.watchdog_memrq(watchdog_memrq),
	.ctrl_memrq    (ctrl_memrq),
	.scroll_memrq  (scroll_memrq)
);

// ─── SDRAM bridge (mem_rq_active FSM M72) ───────────────────────────────
// Interfaccia con bridge top-level (sdram_bridge.sv esterno) tramite porte
// main_rom_*. Adapter qui converte: ls245_en/sdr_addr → main_rom_req/addr.
// Toggle protocol locale (sdram_rq/sdram_ack) NON usato — usiamo direttamente
// il pattern level del bridge top: req=1 mentre wait, ready=pulse 1-cycle.
//
// Stall CE gen: mem_rq_active locale = ls245_en in volo finché ready.
reg main_rq_active;
reg main_rd_lat;
reg [15:0] main_ram_rom_data;
reg main_rom_addr_lo;     // byte select latched per ROM fetch
reg [23:0] main_rom_addr_lat;   // pattern M72 m72.v:262-269: addr LATCHED nel FSM
always @(posedge clk) begin
	if (reset) begin
		main_rq_active    <= 1'b0;
		main_rd_lat       <= 1'b0;
		main_ram_rom_data <= 16'd0;
		main_rom_addr_lo  <= 1'b0;
		main_rom_addr_lat <= 24'd0;
	end else begin
		main_rd_lat <= cpu_rd;
		if (!main_rq_active) begin
			if (ls245_en && cpu_rd && !main_rd_lat) begin
				// Rising edge cpu_rd in ROM region → start fetch
				main_rq_active    <= 1'b1;
				main_rom_addr_lo  <= cpu_addr[0];   // latch byte select
				main_rom_addr_lat <= sdr_addr;      // latch addr — non passare-attraverso
			end
		end else if (main_rom_ready) begin
			main_ram_rom_data <= main_rom_rdata;
			main_rq_active    <= 1'b0;
		end
	end
end
// Adapter al bridge top: addr/req STABILI per tutta la durata della req
assign main_rom_addr = main_rom_addr_lat;
assign main_rom_req  = main_rq_active;

// ─── CE generator pattern M72 ───────────────────────────────────────────
wire ce, ce_4x;
raiden_ce_gen u_ce (
	.clk           (clk),
	.reset         (reset),
	.pause         (pause),
	.clk_sel       (clk_sel),
	.ls245_en      (ls245_en),
	.mem_rq_active (main_rq_active),
	.ce            (ce),
	.ce_4x         (ce_4x)
);

// ─── V30 CPU bridge (cpu.vhd M72) ───────────────────────────────────────
cpu_v30_bridge #(.SS_IDX(SS_IDX_CPU)) u_cpu (
	.clk           (clk),
	.ce            (ce),
	.ce_4x         (ce_4x),
	.reset         (reset),
	.bus_addr      (cpu_addr),
	.bus_read      (cpu_rd),
	.bus_write     (cpu_wr),
	.bus_be        (cpu_be),
	.bus_dout      (cpu_dout),
	.bus_din       (cpu_din),
	.irq_req       (irq_pending),
	.irq_vector    (10'h0C8),
	.cpu_idle      (),
	.cpu_halt      (),
	.cpu_irqrequest(cpu_irq_active),
	.cpu_prefix    (),
	.ss            (ss_cpu),
	.ss_cpu_reload (ss_cpu_reload)
);

// ─── Main RAM 28KB (14K word) — internal ────────────────────────────────
// Load .mem zeros file per init garantita (Cyclone V M10K → INIT_FILE).
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] ram_lo [0:14*1024-1];
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] ram_hi [0:14*1024-1];
initial begin
	$readmemh("main_ram_zeros.mem", ram_lo);
	$readmemh("main_ram_zeros.mem", ram_hi);
end

wire [13:0] ram_word_addr = cpu_addr[14:1];
// write-enable originali (usati anche da txt/scroll — NON rimuovere)
wire ram_wr_lo = cpu_wr && cpu_be[0] && !cpu_be[1] && !cpu_addr[0];
wire ram_wr_hi = cpu_wr && cpu_be[0] && !cpu_be[1] &&  cpu_addr[0];
wire ram_wr_w  = cpu_wr && cpu_be[0] &&  cpu_be[1];
// write-enable work RAM gated su ram_memrq, per l'adaptor savestate
wire ram_we_lo_cpu = ram_memrq && (ram_wr_lo || ram_wr_w);
wire ram_we_hi_cpu = ram_memrq && (ram_wr_hi || ram_wr_w);
wire [15:0] ram_wdata_cpu = ram_wr_w ? cpu_dout : {cpu_dout[7:0], cpu_dout[7:0]};

// Savestate adaptor in serie sulla porta CPU (ZERO BRAM): SS idle → segnali gioco;
// durante SS → porta dirottata al ssbus (SS_IDX_WORKRAM).
reg [15:0] ram_rdata;
wire [13:0] ram_idx;
wire        ram_we_lo, ram_we_hi;
wire [15:0] ram_wdata_eff;
ss_ram16_adaptor #(.WIDTHAD(14), .SS_IDX(0)) u_ss_workram (
	.clk      (clk),
	.we_lo_in (ram_we_lo_cpu),
	.we_hi_in (ram_we_hi_cpu),
	.addr_in  (ram_word_addr),
	.wdata_in (ram_wdata_cpu),
	.we_lo_out(ram_we_lo),
	.we_hi_out(ram_we_hi),
	.addr_out (ram_idx),
	.wdata_out(ram_wdata_eff),
	.q_in     (ram_rdata),
	.ssbus    (ss_workram)
);
always @(posedge clk) if (ram_we_lo) ram_lo[ram_idx] <= ram_wdata_eff[7:0];
always @(posedge clk) if (ram_we_hi) ram_hi[ram_idx] <= ram_wdata_eff[15:8];
always @(posedge clk) ram_rdata <= {ram_hi[ram_idx], ram_lo[ram_idx]};

// ─── Sprite RAM Main bus (BUFFERED_SPRITERAM16) ─────────────────────────
wire [15:0] spr_DOUT;
wire        spr_DOUT_VALID;
wire vblank_rising_main = vblank_in & ~vblank_d;
raiden_sprite_mainbus #(.SS_IDX(SS_IDX_SPR)) u_spr_bus (
	.clk           (clk),
	.reset         (reset),
	.cpu_addr      (cpu_addr),
	.cpu_rd        (cpu_rd),
	.cpu_wr        (cpu_wr),
	.cpu_be        (cpu_be),
	.cpu_dout      (cpu_dout),
	.sprite_memrq  (sprite_memrq),
	.DOUT          (spr_DOUT),
	.DOUT_VALID    (spr_DOUT_VALID),
	.vblank_rising (vblank_rising_main),
	.spr_vram_addr (spr_vram_addr),
	.spr_vram_data (spr_vram_data),
	.ss_spr        (ss_spr)
);

// ─── Text RAM 2KB (1K word) — Main scrive, renderer legge ──────────────
// v114 textram double buffer (pattern sprite_mainbus BUFFERED_SPRITERAM16):
// CPU bank txt_lo/txt_hi <- CPU writes
// Buffer txt_lo_buf/txt_hi_buf <- copy parallel da CPU bank su vblank_rising
// Renderer legge dal buffer = snapshot stabile frame, no race mid-frame.
// Equivale a MAME tilemap render fine-frame.
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] txt_lo [0:1024-1];
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] txt_hi [0:1024-1];
initial begin integer i; for (i=0; i<1024; i=i+1) begin txt_lo[i]=0; txt_hi[i]=0; end end

(* ramstyle = "M10K,no_rw_check" *) reg [7:0] txt_lo_buf [0:1024-1];
(* ramstyle = "M10K,no_rw_check" *) reg [7:0] txt_hi_buf [0:1024-1];
initial begin integer i; for (i=0; i<1024; i=i+1) begin txt_lo_buf[i]=0; txt_hi_buf[i]=0; end end

wire [9:0] txt_word_addr = cpu_addr[10:1];
wire txt_we_lo_cpu = text_memrq && (ram_wr_lo || ram_wr_w);
wire txt_we_hi_cpu = text_memrq && (ram_wr_hi || ram_wr_w);
wire [7:0] txt_din_lo = cpu_dout[7:0];
wire [7:0] txt_din_hi = ram_wr_w ? cpu_dout[15:8] : cpu_dout[7:0];

// Savestate adaptor sul CPU bank txt (il double-buffer si ricostruisce a vblank).
reg  [15:0] txt_ss_rdata;
wire [9:0]  txt_idx;
wire        txt_we_lo, txt_we_hi;
wire [15:0] txt_wdata_eff;
ss_ram16_adaptor #(.WIDTHAD(10), .SS_IDX(1)) u_ss_txt (
	.clk      (clk),
	.we_lo_in (txt_we_lo_cpu),
	.we_hi_in (txt_we_hi_cpu),
	.addr_in  (txt_word_addr),
	.wdata_in ({txt_din_hi, txt_din_lo}),
	.we_lo_out(txt_we_lo),
	.we_hi_out(txt_we_hi),
	.addr_out (txt_idx),
	.wdata_out(txt_wdata_eff),
	.q_in     (txt_ss_rdata),
	.ssbus    (ss_txt)
);
always @(posedge clk) txt_ss_rdata <= {txt_hi[txt_idx], txt_lo[txt_idx]};

// CPU bank: 1 always per array M10K (m10k_pattern_separate)
always @(posedge clk) begin
	if (txt_we_lo) txt_lo[txt_idx] <= txt_wdata_eff[7:0];
end
always @(posedge clk) begin
	if (txt_we_hi) txt_hi[txt_idx] <= txt_wdata_eff[15:8];
end

// Copy FSM CPU bank → buffer su vblank_rising (pattern sprite_mainbus)
reg copying_txt;
reg [10:0] copy_txt_idx;
always @(posedge clk) begin
	if (reset) begin
		copying_txt  <= 1'b0;
		copy_txt_idx <= 11'd0;
	end else if (vblank_rising_main) begin
		copying_txt  <= 1'b1;
		copy_txt_idx <= 11'd0;
	end else if (copying_txt) begin
		txt_lo_buf[copy_txt_idx[9:0]] <= txt_lo[copy_txt_idx[9:0]];
		txt_hi_buf[copy_txt_idx[9:0]] <= txt_hi[copy_txt_idx[9:0]];
		if (copy_txt_idx == 11'd1023) copying_txt <= 1'b0;
		copy_txt_idx <= copy_txt_idx + 11'd1;
	end
end

// Renderer read da buffer (no race CPU mid-frame)
reg [7:0] txt_lo_rd, txt_hi_rd;
always @(posedge clk) txt_lo_rd <= txt_lo_buf[text_vram_addr[9:0]];
always @(posedge clk) txt_hi_rd <= txt_hi_buf[text_vram_addr[9:0]];

assign text_vram_data = {txt_hi_rd, txt_lo_rd};

// ─── Scroll RAM ($0F000-$0F03F: 32 word) ───────────────────────────────
reg [15:0] scroll_ram [0:31];
initial begin integer i; for (i=0; i<32; i=i+1) scroll_ram[i] = 16'd0; end
wire [4:0] scroll_word_addr = cpu_addr[5:1];
// wdata scroll: nel caso word entrambi i byte, altrimenti byte replicato su lo
wire        scroll_wren_cpu = scroll_memrq && (ram_wr_lo || ram_wr_hi || ram_wr_w);
wire [15:0] scroll_wdata_cpu = ram_wr_w ? cpu_dout
                             : ram_wr_hi ? {cpu_dout[7:0], 8'h00}
                             :             {8'h00, cpu_dout[7:0]};
// byte-enable per write parziale: durante SS scriviamo word intera (ssbus).
wire [1:0]  scroll_be_cpu = ram_wr_w ? 2'b11 : ram_wr_hi ? 2'b10 : 2'b01;

reg  [15:0] scroll_ss_rdata;
wire        scroll_wren;
wire [4:0]  scroll_idx;
wire [15:0] scroll_wdata_eff;
ss_ram_adaptor #(.WIDTH(16), .WIDTHAD(5), .SS_IDX(2)) u_ss_scroll (
	.clk      (clk),
	.wren_in  (scroll_wren_cpu),
	.addr_in  (scroll_word_addr),
	.wdata_in (scroll_wdata_cpu),
	.wren_out (scroll_wren),
	.addr_out (scroll_idx),
	.wdata_out(scroll_wdata_eff),
	.q_in     (scroll_ss_rdata),
	.ssbus    (ss_scroll)
);
wire        scroll_ss_sel = ss_scroll.access(2);
wire [1:0]  scroll_be_eff = scroll_ss_sel ? 2'b11 : scroll_be_cpu;
always @(posedge clk) begin
	if (scroll_wren) begin
		if (scroll_be_eff[0]) scroll_ram[scroll_idx][7:0]  <= scroll_wdata_eff[7:0];
		if (scroll_be_eff[1]) scroll_ram[scroll_idx][15:8] <= scroll_wdata_eff[15:8];
	end
	scroll_ss_rdata <= scroll_ram[scroll_idx];
end
genvar gi;
generate
	for (gi = 0; gi < 32; gi = gi + 1) begin : g_scroll_export
		assign scroll_words_flat[gi*16 +: 16] = scroll_ram[gi];
	end
endgenerate

// ─── control_w $0E006 (8-bit) ──────────────────────────────────────────
// MAME bit 0: BG dis, bit 1: FG dis, bit 2: TX dis, bit 3: SPR dis
//      bit 6: flipscreen
reg [7:0] ctrl_reg;
always @(posedge clk) begin
	if (reset) ctrl_reg <= 8'h0F;
	else if (ctrl_memrq && cpu_wr && cpu_be[0]) ctrl_reg <= cpu_dout[7:0];
end
assign ctrl_bg_en      = ~ctrl_reg[0];
assign ctrl_fg_en      = ~ctrl_reg[1];
assign ctrl_tx_en      = ~ctrl_reg[2];
assign ctrl_sp_en      = ~ctrl_reg[3];
assign ctrl_flipscreen =  ctrl_reg[6];

// ─── Sound stub ($0A000-$0A00D, 8-bit umask 00FF) ──────────────────────
assign snd_cs     = sound_memrq;
assign snd_addr   = cpu_addr[3:1];
assign snd_wr     = sound_memrq && cpu_wr && cpu_be[0];
assign snd_rd     = sound_memrq && cpu_rd && cpu_be[0];
assign snd_wdata  = cpu_dout;

// ─── Shared RAM bridge (Main side, modulo fisico in TOP) ──────────────
assign main_shared_addr  = cpu_addr[11:1];
assign main_shared_cs    = shared_memrq;
assign main_shared_we    = (shared_memrq && cpu_wr) ?
                           ((cpu_be[1] && cpu_be[0]) ? 2'b11 :
                            (cpu_be[0] && !cpu_addr[0]) ? 2'b01 :
                            (cpu_be[0] &&  cpu_addr[0]) ? 2'b10 : 2'b00) : 2'b00;
assign main_shared_wdata = (cpu_be[0] && !cpu_be[1] && cpu_addr[0]) ?
                           {cpu_dout[7:0], cpu_dout[7:0]} : cpu_dout;

// ─── DOUT_VALID mux for cpu_din (pattern M72 m72.v:319-329) ────────────
// Latch 1-cycle dei memrq per allinearsi con BRAM 1-cycle latency.
reg ram_rd_lat, text_rd_lat, p1p2_rd_lat, dsw_rd_lat, sound_rd_lat;
reg shared_rd_lat;
reg cpu_addr_lo_lat;
reg [15:0] p1p2_data_lat, dsw_data_lat, sound_data_lat;

always @(posedge clk) begin
	if (reset) begin
		ram_rd_lat       <= 1'b0;
		text_rd_lat      <= 1'b0;
		p1p2_rd_lat      <= 1'b0;
		dsw_rd_lat       <= 1'b0;
		sound_rd_lat     <= 1'b0;
		shared_rd_lat    <= 1'b0;
		cpu_addr_lo_lat  <= 1'b0;
		p1p2_data_lat    <= 16'd0;
		dsw_data_lat     <= 16'd0;
		sound_data_lat   <= 16'h00FF;
	end else begin
		ram_rd_lat      <= cpu_rd & ram_memrq;
		text_rd_lat     <= cpu_rd & text_memrq;
		p1p2_rd_lat     <= cpu_rd & p1p2_memrq;
		dsw_rd_lat      <= cpu_rd & dsw_memrq;
		sound_rd_lat    <= cpu_rd & sound_memrq;
		shared_rd_lat   <= cpu_rd & shared_memrq;
		cpu_addr_lo_lat <= cpu_addr[0];
		// IO data latch
		p1p2_data_lat   <= {p2_input, p1_input};
		dsw_data_lat    <= dsw_input;
		sound_data_lat  <= {8'hFF, snd_rdata[7:0]};
	end
end

// Byte align V30 (richiesto byte sempre su [7:0])
function [15:0] byte_align;
	input [15:0] data;
	input        addr_lo;
	begin
		byte_align = addr_lo ? {data[7:0], data[15:8]} : data;
	end
endfunction

// Pattern M72: priority mux su _valid_lat. Fallback a SDRAM (main_ram_rom_data).
always @(*) begin
	if      (spr_DOUT_VALID)  cpu_din = spr_DOUT;             // sprite RAM (già aligned)
	else if (ram_rd_lat)      cpu_din = byte_align(ram_rdata,        cpu_addr_lo_lat);
	else if (shared_rd_lat)   cpu_din = byte_align(main_shared_rdata, cpu_addr_lo_lat);
	else if (p1p2_rd_lat)     cpu_din = byte_align(p1p2_data_lat,    cpu_addr_lo_lat);
	else if (dsw_rd_lat)      cpu_din = byte_align(dsw_data_lat,     cpu_addr_lo_lat);
	else if (sound_rd_lat)    cpu_din = byte_align(sound_data_lat,   cpu_addr_lo_lat);
	else                       cpu_din = byte_align(main_ram_rom_data, main_rom_addr_lo);   // fallback ROM (SDRAM)
end

endmodule
