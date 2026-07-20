// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Umberto Parisi (rmonic79). GPL v3 or later.
//
/*  Raiden_MiSTer — Audio subsystem Seibu (Z80 + YM2151 + OKI6295)
    Author: Umberto Parisi (rmonic79)

    Spec da MAME (reference/mame_seibu/seibusound.cpp + dcon.cpp):
      - Z80A @ 14.31818 MHz / 4 = 3.579545 MHz
      - YM2151 (jt51) @ 14.31818 / 4 = 3.579545 MHz
      - OKI M6295 (jt6295) @ 20 MHz / 16 = 1.25 MHz, PIN7=LOW

    Z80 memory map (seibu_sound_map):
      0x0000-0x1FFF  ROM fissa 8KB
      0x2000-0x27FF  RAM 2KB
      0x4000         pending_w (sound→main pending)
      0x4001         irq_clear_w (RST18 EOI)
      0x4002         rst10_ack_w (RST10 EOI)
      0x4003         rst18_ack_w (RST18 EOI)
      0x4007         bank_w (Z80 ROM bank, 1 bit)
      0x4008-0x4009  YM2151 r/w (a0=addr[0])
      0x4010-0x4011  soundlatch_r (main→sub latch byte 0/1)
      0x4012         main_data_pending_r (main2sub pending flag)
      0x4013         coin_r (legge coin/start input HW)
      0x4018-0x4019  main_data_w (sub→main latch byte 0/1)
      0x401B         coin_w (counter, ignorato in MiSTer)
      0x6000         OKI M6295 r/w
      0x8000-0xFFFF  ROM bank 32KB (in Raiden ROM=32KB lineari, no banking)

    Main↔sub comm @ 0xA0000-0xA000D (mappato in main_top.sv):
      offset 0/1: main_w → m_main2sub[0/1]
      offset 2/3: main_r → m_sub2main[0/1] (BUT offset 4 main_w → assert RST18)
      offset 4: main_w → assert RST18 IRQ to Z80
      offset 5: main_r → m_main2sub_pending (bit0)
      offset 6: main_w → set pending flags (mirror)

    IRQ Z80 (IM0):
      RST10 (vector 0xD7) ← YM2151 IRQ (fm_irqhandler)
      RST18 (vector 0xDF) ← main RST18_ASSERT
      Priorità: RST18 > RST10 (im0_vector_cb)

    Coin path:
      HW button → coin_input → coin_r (Z80 read) → Z80 elabora →
      sub2main soundlatch → main legge 0xA0004 → coin_credit incrementato
*/

module Raiden_audio_z80 #(parameter SS_IDX_ZRAM = -1) (
	input  wire        clk,
	input  wire        reset,
	input  wire        pause,
	input  wire  [1:0] clk_sel,    // OSD audio clock select (legacy, ignored)

	// OSD volume select (4-bit, pattern BoogieWings):
	//   0=Default, 1=Mute, 2=MAME, 3..15 = percentuale del Default
	input  wire  [3:0] fm_vol_sel,  // FM YM3812
	input  wire  [3:0] oki_vol_sel, // OKI 6295

	// ROM download (ioctl)
	input  wire        ioctl_download,
	input  wire        ioctl_wr,
	input  wire [26:0] ioctl_addr,
	input  wire [15:0] ioctl_dout,

	// Sound comm bus dal main 68k (mappato a 0xA0000-0xA000D)
	input  wire        snd_cs,         // is_snd region active
	input  wire  [3:1] snd_addr,       // bus_addr[3:1] = offset/2 (0..6)
	input  wire        snd_wr,         // ~bus_rnw & active
	input  wire        snd_rd,         // bus_rnw & active (per pending check)
	input  wire [15:0] snd_wdata,
	output wire [15:0] snd_rdata,
	input  wire        snd_nmi_n,      // legacy (unused, Seibu non usa NMI)
	input  wire        snd_reset_in,   // legacy

	// HW input coin (lette dal Z80 a 0x4013)
	input  wire  [7:0] coin_input,     // bit0=COIN1, bit1=COIN2 (ACTIVE_HIGH)

	// OKI ADPCM ROM bridge (256KB SDRAM, port 3)
	output wire [17:0] oki_rom_addr,
	input  wire  [7:0] oki_rom_data,
	input  wire        oki_rom_ok,

	// Audio output stereo 16-bit signed
	output reg signed [15:0] audio_l,
	output reg signed [15:0] audio_r,

	// Savestate slave: z80_ram (stato RAM Z80). I chip T80/YM/OKI e i soundlatch
	// (transitori handshake) ripartono al load — glitch audio momentaneo, gioco ok.
	ssbus_if.slave     ss_zram     // z80_ram 2K × 8
);

	// ─── Clock enable: clk_sys (80 MHz) → Z80/YM 3.579545 MHz, OKI 1 MHz ─────
	// MAME raiden.cpp:724 Z80 @ 14.318181/4 = 3.579 MHz
	//                :744 YM3812 @ 14.318181/4 = 3.579 MHz (shared con Z80)
	// 80/3.579 = 22.35 → div 22 → 3.636 MHz (errore +1.6%, accettabile)
	reg [4:0] cen_z80_cnt;
	reg       cen_z80;
	always @(posedge clk) begin
		if (reset) begin
			cen_z80_cnt <= 5'd0;
			cen_z80     <= 1'b0;
		end else begin
			if (cen_z80_cnt == 5'd21) begin
				cen_z80_cnt <= 5'd0;
				cen_z80     <= 1'b1;
			end else begin
				cen_z80_cnt <= cen_z80_cnt + 5'd1;
				cen_z80     <= 1'b0;
			end
		end
	end

	// OKI clock: MAME raiden.cpp:754 = 12 MHz / 12 = 1 MHz exact.
	// clk_sys 80 MHz / 1 MHz = 80 → divisor 80 (cnt 0..79)
	reg [6:0] cen_oki_cnt;
	reg       cen_oki;
	always @(posedge clk) begin
		if (reset) begin
			cen_oki_cnt <= 7'd0;
			cen_oki     <= 1'b0;
		end else if (cen_oki_cnt == 7'd79) begin
			cen_oki_cnt <= 7'd0;
			cen_oki     <= 1'b1;
		end else begin
			cen_oki_cnt <= cen_oki_cnt + 7'd1;
			cen_oki     <= 1'b0;
		end
	end

	// ─── Z80 signals ─────────────────────────────────────────────────────────
	wire [15:0] z80_addr;
	wire  [7:0] z80_dout;
	reg   [7:0] z80_din;
	wire        z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n, z80_m1_n;
	wire        z80_int_n;
	wire        z80_busak_n, z80_halt_n;

	// CS decoder (pattern Toki z80_cs.v - working Seibu reference):
	//   0x0000-0x1FFF  → ROM (8KB lineare, decrypted)
	//   0x2000-0x27FF  → RAM (2KB)
	//   0x4000-0x401F  → regs Seibu sound
	//   0x6000-0x6FFF  → OKI M6295
	//   0x8000-0xFFFF  → ROM bank
	wire rom_lo_cs   = ~z80_mreq_n && (z80_addr[15:13] == 3'b000);   // 0x0000-0x1FFF
	wire ram_cs      = ~z80_mreq_n && (z80_addr[15:11] == 5'b00100); // 0x2000-0x27FF
	wire reg_cs      = ~z80_mreq_n && (z80_addr[15:5]  == 11'h200);  // 0x4000-0x401F
	wire oki_cs      = ~z80_mreq_n && (z80_addr[15:12] == 4'h6);     // 0x6000-0x6FFF
	wire rom_hi_cs   = ~z80_mreq_n && (z80_addr[15] == 1'b1);        // 0x8000-0xFFFF

	// ─── ROM Z80 64KB raw: 2 BRAM split byte-low / byte-high (32K word) ──────
	// MRA layout: audiocpu @ ioctl_addr 0x4E0000-0x4EFFFF (64KB raw, byte-stream).
	// File 911-a05.010 fa 64KB. WIDE=1 ioctl: 2 byte per word (LSB=primo byte).
	// Split in 2 BRAM 8-bit × 32Kw: rom_lo[wordaddr]=byte_pari, rom_hi[wordaddr]=byte_dispari.
	//
	// MAME audiocpu region layout (sdgndmps):
	//   ROM_LOAD     "911-a05.010" 0x00000, 0x8000   → primi 32KB del file → region 0x00000-0x07FFF
	//   ROM_CONTINUE                0x10000, 0x8000  → secondi 32KB del file → region 0x10000-0x17FFF
	//   ROM_COPY     "audiocpu"     0x00000 → 0x18000, 0x8000 → region 0x18000-0x1FFFF (alias bank1)
	//
	// Seibu rom_bank con length>0x10000:
	//   bank 0 → region[0x10000-0x17FFF] = secondi 32KB del file
	//   bank 1 → region[0x18000-0x1FFFF] = primi 32KB del file (alias)
	//
	// Z80 access map effettiva per noi:
	//   0x0000-0x1FFF (rom_lo_cs): primi 8KB della ROM = file[0x0000-0x1FFF]
	//   0x8000-0xFFFF (rom_hi_cs banked):
	//     bank=0 → file[0x8000-0xFFFF]   (secondi 32KB)
	//     bank=1 → file[0x0000-0x7FFF]   (primi 32KB alias)
	(* ramstyle = "M10K,no_rw_check" *) reg [7:0] z80_rom_lo [0:32767];
	(* ramstyle = "M10K,no_rw_check" *) reg [7:0] z80_rom_hi [0:32767];
	reg [7:0] z80_rom_lo_q, z80_rom_hi_q;

	// Z80 ROM placed by MRA at 0x0A0000-0x0AFFFF (audiocpu, 64KB raw byte-pack)
	wire z80_rom_dl_wr =
		ioctl_download && ioctl_wr && (ioctl_addr >= 27'h0A0000) && (ioctl_addr < 27'h0B0000);
	wire [14:0] z80_rom_dl_word = ioctl_addr[15:1];   // word index 0..32767

	// Bank register (1 bit, scritto da Z80 a 0x4007)
	reg rom_bank;

	// Effective ROM byte address (16-bit lineare nel file 64KB):
	//   rom_lo_cs (0x0000-0x1FFF):       z80_addr[15:0]
	//   rom_hi_cs (0x8000-0xFFFF):
	//     bank=0 → z80_addr[15:0]                  (file[0x8000-0xFFFF])
	//     bank=1 → {1'b0, z80_addr[14:0]}          (file[0x0000-0x7FFF])
	wire [15:0] z80_rom_byte_addr =
		rom_lo_cs              ? z80_addr :
		(rom_hi_cs & ~rom_bank) ? z80_addr :
		(rom_hi_cs &  rom_bank) ? {1'b0, z80_addr[14:0]} :
		                          z80_addr;

	reg z80_addr_lsb_d;
	always @(posedge clk) begin
		if (z80_rom_dl_wr) begin
			z80_rom_lo[z80_rom_dl_word] <= ioctl_dout[7:0];
			z80_rom_hi[z80_rom_dl_word] <= ioctl_dout[15:8];
		end
		// word index = byte_addr[15:1], byte select = byte_addr[0]
		z80_rom_lo_q   <= z80_rom_lo[z80_rom_byte_addr[15:1]];
		z80_rom_hi_q   <= z80_rom_hi[z80_rom_byte_addr[15:1]];
		z80_addr_lsb_d <= z80_rom_byte_addr[0];
	end

	wire [7:0] z80_rom_raw = z80_addr_lsb_d ? z80_rom_hi_q : z80_rom_lo_q;

	// ─── sei80bu: opcode (M1) decrypt — Raiden Z80 ROM encryption ─────────────
	// MAME raiden.cpp:768-769: opcodes via sei80bu_device::opcode_r, data via raw.
	//
	// GATE Z80_ROM_DECRYPT_EN:
	//   0 = ROM raw (per raiden_dec.zip, ROM già decryptate offline)
	//   1 = sei80bu attivo (per raiden.zip MAME originale)
	// TODO: passare a 1 quando MRA userà raiden.zip originale.
	localparam Z80_ROM_DECRYPT_EN = 1'b1;

	wire [7:0] z80_rom_dec;
	wire       z80_rom_dec_ok;
	wire       z80_rom_cs = rom_lo_cs | rom_hi_cs;
	sei80bu u_sei80bu (
		.clk             (clk),
		.z80_rom_addr    (z80_addr),
		.z80_rom_data    (z80_rom_raw),
		.z80_rom_ok      (1'b1),
		.z80_rom_cs      (z80_rom_cs),
		.z80_m1          (~z80_m1_n),
		.decrypt_rom_data(z80_rom_dec),
		.decrypt_rom_ok  (z80_rom_dec_ok)
	);
	wire [7:0] z80_rom_q = Z80_ROM_DECRYPT_EN ? z80_rom_dec : z80_rom_raw;

	// ─── RAM Z80 2KB ─────────────────────────────────────────────────────────
	(* ramstyle = "M10K,no_rw_check" *) reg [7:0] z80_ram [0:2047];
	reg [7:0] z80_ram_q;

	// Savestate adaptor sulla porta CPU z80_ram (8-bit).
	wire        zram_wren_cpu = ram_cs && !z80_wr_n;
	wire [10:0] zram_idx;
	wire        zram_wren;
	wire  [7:0] zram_wdata_eff;
	ss_ram_adaptor #(.WIDTH(8), .WIDTHAD(11), .SS_IDX(SS_IDX_ZRAM)) u_ss_zram (
		.clk(clk), .wren_in(zram_wren_cpu), .addr_in(z80_addr[10:0]), .wdata_in(z80_dout),
		.wren_out(zram_wren), .addr_out(zram_idx), .wdata_out(zram_wdata_eff),
		.q_in(z80_ram_q), .ssbus(ss_zram)
	);
	always @(posedge clk) begin
		if (zram_wren) z80_ram[zram_idx] <= zram_wdata_eff;
		z80_ram_q <= z80_ram[zram_idx];
	end

	// ─── Sub-region decoder dentro reg_cs (z80_addr[4:0] = offset 0..31) ─────
	wire is_pending_w   = reg_cs && (z80_addr[4:0] == 5'h00) && !z80_wr_n;
	wire is_irq_clear   = reg_cs && (z80_addr[4:0] == 5'h01) && !z80_wr_n;
	wire is_rst10_ack   = reg_cs && (z80_addr[4:0] == 5'h02) && !z80_wr_n;
	wire is_rst18_ack   = reg_cs && (z80_addr[4:0] == 5'h03) && !z80_wr_n;
	wire is_bank_w      = reg_cs && (z80_addr[4:0] == 5'h07) && !z80_wr_n;
	wire is_ym_access   = reg_cs && (z80_addr[4:1] == 4'h4);                      // 0x4008-0x4009
	wire is_ym_w        = is_ym_access && !z80_wr_n;
	wire is_ym_r        = is_ym_access && !z80_rd_n;
	wire is_latch_lo_r  = reg_cs && (z80_addr[4:0] == 5'h10) && !z80_rd_n;
	wire is_latch_hi_r  = reg_cs && (z80_addr[4:0] == 5'h11) && !z80_rd_n;
	wire is_pending_r   = reg_cs && (z80_addr[4:0] == 5'h12) && !z80_rd_n;
	wire is_coin_r      = reg_cs && (z80_addr[4:0] == 5'h13) && !z80_rd_n;
	wire is_data_lo_w   = reg_cs && (z80_addr[4:0] == 5'h18) && !z80_wr_n;
	wire is_data_hi_w   = reg_cs && (z80_addr[4:0] == 5'h19) && !z80_wr_n;
	wire is_coin_w      = reg_cs && (z80_addr[4:0] == 5'h1B) && !z80_wr_n;

	// ─── ROM bank register (Z80 0x4007: bit0 → bank 0/1) ─────────────────────
	// MAME seibu_sound_device::bank_w: m_rom_bank->set_entry(BIT(data,0))
	always @(posedge clk) begin
		if (reset)
			rom_bank <= 1'b0;
		else if (cen_z80 && is_bank_w)
			rom_bank <= z80_dout[0];
	end

	// ─── Soundlatch main↔sub state ───────────────────────────────────────────
	// 2-byte main2sub + 2-byte sub2main + flags pending
	reg [7:0] main2sub [0:1];
	reg [7:0] sub2main [0:1];
	reg       main2sub_pending;
	reg       sub2main_pending;

	// ─── IRQ controller (IM0 vector RST10/RST18) ─────────────────────────────
	// Stato: rst10_irq, rst10_service, rst18_irq, rst18_service
	// IRQ assertion logic:
	//   ASSERT: rst10_irq=1 (FM IRQ) o rst18_irq=1 (main wakeup)
	//   CLEAR: rst10_service=1 (durante service) o EOI restoraservice=0
	reg rst10_irq, rst10_service;
	reg rst18_irq, rst18_service;
	wire ym_irq_n;
	wire ym_irq = ~ym_irq_n;
	reg  ym_irq_d;

	// IM0 vector inject: durante m1+iorq (interrupt acknowledge) il device
	// fornisce 0xDF (RST18) o 0xD7 (RST10). RST18 ha priorità.
	// Il vector deve essere LATCHED all'inizio dell'IACK e tenuto stabile
	// per tutta la durata dell'IACK (può durare più cicli clk). Se calcolato
	// combinatoriale, quando rst18_irq viene cleared il vector torna a 00
	// e Z80 fetcha 00 invece del vector corretto. Bug verificato in sim.
	wire iack_active = ~z80_m1_n && ~z80_iorq_n;
	reg  iack_active_d;
	reg  [7:0] iack_vector_latched;
	wire [7:0] iack_vector_now =
	    (rst18_irq && !rst18_service) ? 8'hDF :
	    (rst10_irq && !rst10_service) ? 8'hD7 :
	                                    8'h00;
	// Latch al rising edge di iack_active
	always @(posedge clk) begin
		if (reset) begin
			iack_active_d       <= 1'b0;
			iack_vector_latched <= 8'h00;
		end else begin
			iack_active_d <= iack_active;
			if (iack_active && !iack_active_d) begin
				iack_vector_latched <= iack_vector_now;
			end
		end
	end
	wire [7:0] iack_vector = iack_active_d ? iack_vector_latched : iack_vector_now;

	// IRQ line al Z80: ASSERT se RST10 pending (e non in service) OR RST18 pending
	wire irq_active = (rst10_irq && !rst10_service) || (rst18_irq && !rst18_service);
	assign z80_int_n = ~irq_active;

	always @(posedge clk) begin
		if (reset) begin
			rst10_irq     <= 1'b0;
			rst10_service <= 1'b0;
			rst18_irq     <= 1'b0;
			rst18_service <= 1'b0;
			ym_irq_d      <= 1'b0;
		end else begin
			ym_irq_d <= ym_irq;
			// YM IRQ rising/falling → RST10 assert/clear
			if (ym_irq && !ym_irq_d)        rst10_irq <= 1'b1;
			else if (!ym_irq && ym_irq_d)   rst10_irq <= 1'b0;

			// Main writes to 0xA0008 (MAME offset 4) → assert RST18
			// snd_addr = bus_addr[3:1], 0xA0008 → bit[3:1]=100 = 4
			if (snd_cs && snd_wr && snd_addr == 3'd4)
				rst18_irq <= 1'b1;

			// Z80 acknowledges IRQ: FALLING edge di iack_active (= fine IACK)
			// Solo allora clear rst*_irq e set service. Durante IACK il vector
			// rimane latched (vedi sopra) e il Z80 lo fetcha correttamente.
			if (iack_active_d && !iack_active) begin
				if (iack_vector_latched == 8'hDF) begin
					rst18_service <= 1'b1;
					rst18_irq     <= 1'b0;
				end else if (iack_vector_latched == 8'hD7) begin
					rst10_service <= 1'b1;
				end
			end

			// Z80 EOI writes
			if (cen_z80) begin
				if (is_irq_clear)  rst18_service <= 1'b0;
				if (is_rst10_ack)  rst10_service <= 1'b0;
				if (is_rst18_ack)  rst18_service <= 1'b0;
			end
		end
	end

	// ─── Soundlatch main_w/r logic ──────────────────────────────────────────
	// snd_addr = bus_addr[3:1] = offset/2 (0=word 0, 1=word 1, 2=word 2, 3=word 3, 4=word 4, 5=word 5, 6=word 6)
	// MAME usa byte access (umask16 0x00ff = byte basso). Mappa offset MAME → snd_addr:
	//   offset 0 (0xA0000) → snd_addr 0
	//   offset 1 (0xA0002) → snd_addr 1
	//   offset 2 (0xA0004) → snd_addr 2
	//   offset 3 (0xA0006) → snd_addr 3
	//   offset 5 (0xA000A) → snd_addr 5
	//   offset 6 (0xA000C) → snd_addr 6
	always @(posedge clk) begin
		if (reset) begin
			main2sub[0]      <= 8'd0;
			main2sub[1]      <= 8'd0;
			sub2main[0]      <= 8'd0;
			sub2main[1]      <= 8'd0;
			main2sub_pending <= 1'b0;
			sub2main_pending <= 1'b0;
		end else begin
			// Main writes (MAME seibu_sound_device::main_w):
			//   case 0/1: m_main2sub[offset] = data
			//   case 4:   update_irq_lines(RST18_ASSERT) — gestito sopra
			//   case 2/6: pending flags (sub2main=0, main2sub=1)
			if (snd_cs && snd_wr) begin
				case (snd_addr)
					3'd0: main2sub[0] <= snd_wdata[7:0];
					3'd1: main2sub[1] <= snd_wdata[7:0];
					3'd2, 3'd6: begin                        // MAME case 2/6
						sub2main_pending <= 1'b0;
						main2sub_pending <= 1'b1;
					end
					default: ;
				endcase
			end
			// Z80 reads soundlatch (→ MAME implicit: nessun side effect)
			// Z80 writes sub2main
			if (cen_z80) begin
				if (is_data_lo_w) sub2main[0] <= z80_dout;
				if (is_data_hi_w) sub2main[1] <= z80_dout;
				if (is_pending_w) begin
					main2sub_pending <= 1'b0;
					sub2main_pending <= 1'b1;
				end
			end
		end
	end

	// snd_rdata: main legge 0xA0004 (offset 2), 0xA0006 (offset 3), 0xA000A (offset 5).
	// MAME seibu_sound_device::main_r (seibusound.cpp:285):
	//   offset 2,3: sub2main[0/1] (Z80 → main latch bytes)
	//   offset 5:   main2sub_pending (main chiede: Z80 ha letto il mio comando?)
	//   default:    0xFF
	// NO sdgndmps override per Raiden (era bug copiato da GundamSD)
	wire [7:0] main_r_data =
		(snd_addr == 3'd2) ? sub2main[0] :
		(snd_addr == 3'd3) ? sub2main[1] :
		(snd_addr == 3'd5) ? {7'd0, main2sub_pending} :
		                      8'hFF;
	assign snd_rdata = {8'h00, main_r_data};

	// ─── YM3812 (jtopl2) mono ────────────────────────────────────────────────
	// MAME raiden.cpp:744 YM3812(config, "ymsnd", 14.318181_MHz_XTAL / 4)
	// Mono → duplicato L/R nel mixer sotto.
	wire [7:0] ym_dout;
	wire signed [15:0] ym_snd;
	wire        ym_sample;
	// Pause gate: stop chip cen durante pause (pattern Darius2 darius2_audio_top.sv)
	wire cen_z80_g = cen_z80 & ~pause;
	wire cen_oki_g = cen_oki & ~pause;

	jtopl2 u_jtopl2 (
		.rst    (reset),
		.clk    (clk),
		.cen    (cen_z80_g),
		.din    (z80_dout),
		.addr   (z80_addr[0]),
		.cs_n   (~is_ym_access),
		.wr_n   (z80_wr_n),
		.dout   (ym_dout),
		.irq_n  (ym_irq_n),
		.snd    (ym_snd),
		.sample (ym_sample)
	);

	// ─── OKI M6295 (jt6295) ──────────────────────────────────────────────────
	// rom_addr/rom_data/rom_ok arrivano dai port modulo (collegati a SDRAM port 3)
	wire [7:0] oki_dout;
	wire signed [13:0] oki_sound;
	wire        oki_sample;

	jt6295 #(.INTERPOL(1)) u_jt6295 (
		.rst       (reset),
		.clk       (clk),
		.cen       (cen_oki_g),
		.ss        (1'b1),                // PIN7 = HIGH (MAME raiden.cpp:754 verified)
		.wrn       (~(oki_cs & ~z80_wr_n)),
		.din       (z80_dout),
		.dout      (oki_dout),
		.rom_addr  (oki_rom_addr),
		.rom_data  (oki_rom_data),
		.rom_ok    (oki_rom_ok),
		.sound     (oki_sound),
		.sample    (oki_sample)
	);

	// ─── Z80 din mux ─────────────────────────────────────────────────────────
	always @(*) begin
		if (iack_active)         z80_din = iack_vector;
		else if (rom_lo_cs)      z80_din = z80_rom_q;
		else if (rom_hi_cs)      z80_din = z80_rom_q;       // Raiden ROM lineare
		else if (ram_cs)         z80_din = z80_ram_q;
		else if (is_ym_r)        z80_din = ym_dout;
		else if (is_latch_lo_r)  z80_din = main2sub[0];
		else if (is_latch_hi_r)  z80_din = main2sub[1];
		else if (is_pending_r)   z80_din = {7'd0, sub2main_pending};
		else if (is_coin_r)      z80_din = coin_input;
		else if (oki_cs)         z80_din = oki_dout;
		else                     z80_din = 8'hFF;
	end

	// ─── T80s Z80 core ───────────────────────────────────────────────────────
	wire t80_busrq_n   = 1'b1;
	wire t80_wait_n    = 1'b1;
	wire t80_nmi_n     = 1'b1;
	wire t80_reset_n   = ~reset & ~snd_reset_in;

	T80s u_z80 (
		.RESET_n (t80_reset_n),
		.CLK     (clk),
		.CEN     (cen_z80_g),
		.WAIT_n  (t80_wait_n),
		.INT_n   (z80_int_n),
		.NMI_n   (t80_nmi_n),
		.BUSRQ_n (t80_busrq_n),
		.M1_n    (z80_m1_n),
		.MREQ_n  (z80_mreq_n),
		.IORQ_n  (z80_iorq_n),
		.RD_n    (z80_rd_n),
		.WR_n    (z80_wr_n),
		.RFSH_n  (),
		.HALT_n  (z80_halt_n),
		.BUSAK_n (z80_busak_n),
		.OUT0    (1'b0),
		.A       (z80_addr),
		.DI      (z80_din),
		.DO      (z80_dout),
		.REG     ()
	);

	// ─── Mixer audio: jtframe_mixer Toki pattern (Q4.4 gains) ────────────────
	// Volume OSD pattern BoogieWings: Default/Mute/MAME + percentuali che
	// scalano il DEFAULT. Cambiando DEF_GAIN_* tutte le % scalano con lui.
	// Gain Q4.4: 0x10 = 1.0x. jtframe_mixer satura internamente.
	// Default Raiden tarato HW (screenshot 2026-07-13): FM 500%, ADPCM 400%
	// del gain MAME base (FM 0x10, OKI 0x0C). Loudness allineata ad altri core.
	//   FM  : 0x10 × 5 = 0x50   (= era 100% MAME × 5.0)
	//   OKI : 0x0C × 4 = 0x30   (= era  75% MAME × 4.0)
	// Le percentuali OSD scalano da QUESTI nuovi default. MAME (sel 2) resta
	// il valore MAME-esatto originale (0x10 / 0x0C) per chi vuole l'accurato.
	localparam [7:0] DEF_GAIN_FM  = 8'h50;   // FM  tarato (5× MAME 1.0)
	localparam [7:0] DEF_GAIN_OKI = 8'h30;   // OKI tarato (4× MAME 0.75)

	// mul Q4.8 (256 = 100% del Default). Voci OSD 2..14 (0=Default, 1=Mute).
	function [11:0] osd_mul_aud;
		input [3:0] sel;
		case (sel)
			4'd2:  osd_mul_aud = 12'd64;    // 25%
			4'd3:  osd_mul_aud = 12'd128;   // 50%
			4'd4:  osd_mul_aud = 12'd192;   // 75%
			4'd5:  osd_mul_aud = 12'd256;   // 100%
			4'd6:  osd_mul_aud = 12'd320;   // 125%
			4'd7:  osd_mul_aud = 12'd384;   // 150%
			4'd8:  osd_mul_aud = 12'd512;   // 200%
			4'd9:  osd_mul_aud = 12'd640;   // 250%
			4'd10: osd_mul_aud = 12'd768;   // 300%
			4'd11: osd_mul_aud = 12'd1024;  // 400%
			4'd12: osd_mul_aud = 12'd1280;  // 500%
			4'd13: osd_mul_aud = 12'd1792;  // 700%
			4'd14: osd_mul_aud = 12'd2560;  // 1000%
			default: osd_mul_aud = 12'd256;
		endcase
	endfunction

	// sel: 0=Default(tarato), 1=Mute, 2+ = % del Default.
	function [7:0] gain_resolve;
		input [3:0] sel;
		input [7:0] def_g;
		reg [19:0] scaled;
		begin
			case (sel)
				4'd0: gain_resolve = def_g;    // Default (tarato)
				4'd1: gain_resolve = 8'h00;    // Mute
				default: begin
					scaled = def_g * osd_mul_aud(sel);
					gain_resolve = (scaled[19:8] > 12'hFF) ? 8'hFF : scaled[15:8];
				end
			endcase
		end
	endfunction

	wire [7:0] fm_gain  = gain_resolve(fm_vol_sel,  DEF_GAIN_FM);
	wire [7:0] oki_gain = gain_resolve(oki_vol_sel, DEF_GAIN_OKI);

	wire signed [15:0] mixed_mono;
	jtframe_mixer #(.W1(14)) u_mixer (
		.rst   (reset),
		.clk   (clk),
		.cen   (1'b1),
		.ch0   (ym_snd),       // FM YM3812
		.ch1   (oki_sound),    // PCM OKI
		.ch2   (16'd0),
		.ch3   (16'd0),
		.gain0 (fm_gain),
		.gain1 (oki_gain),
		.gain2 (8'd0),
		.gain3 (8'd0),
		.mixed (mixed_mono),
		.peak  ()
	);

	always @(posedge clk) begin
		audio_l <= mixed_mono;
		audio_r <= mixed_mono;
	end

endmodule
