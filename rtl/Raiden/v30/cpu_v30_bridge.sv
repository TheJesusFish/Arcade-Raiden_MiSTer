// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) Umberto Parisi (rmonic79). GPL v3 or later.
//
//============================================================================
// cpu_v30_bridge — wrapper SystemVerilog attorno all'entity VHDL `cpu`
// (V30 NEC, sorgente: MiSTer-devel/WonderSwan_MiSTer rtl/cpu.vhd VHDL-2008).
//
// Scopo: esporre un'interfaccia bus pulita stile arcade-MiSTer
//   addr [19:0] / din [15:0] / dout [15:0] / rd / wr / be [1:0] / d_io / ack
// nascondendo:
//   - savestate signals (tied off)
//   - DMA hooks (tied off)
//   - register bus debug (tied off)
//   - turbo / SLOWTIMING flags (0)
//
// Note V30 / Raiden:
//   * Raiden V30 main @ 10 MHz, sub @ 10 MHz. ce 1 ogni N clk_sys.
//   * IRQ vectored: irqrequest_in alto, irqvector_in[9:0] = vector da hw
//     (Raiden non usa PIC 8259 esterno: vettore di IRQ4 lo fornisce direttamente).
//   * Bus 20-bit byte address, ma il core esporta `bus_addr unsigned(19 downto 0)`
//     allineato byte. data_m_be[1:0] = byte enable per accessi 8/16-bit.
//   * `d_io` non presente nel core WonderSwan (sintetizzato dal microcode interno).
//     L'I/O port instructions usano lo stesso bus_read/bus_write con flag
//     interno: in WonderSwan il decoding I/O è demandato al system-on-chip.
//     Per Raiden la mappa è memory-mapped quindi non usiamo distinzione.
//
// CE clock enable: per girare V30 a 10 MHz su clk_sys @ 60 MHz
//   ce 1 ogni 6 clk_sys. ce_4x ogni 1.5 cicli (non integer): per ora
//   ce_4x = ce per semplicità. WonderSwan usa ce_4x per la prefetch.
//============================================================================

module cpu_v30_bridge #(parameter SS_IDX = -1) (
	input  logic        clk,
	input  logic        ce,        // ~10 MHz: 1 ogni N clk_sys (gestito dal padre)
	input  logic        ce_4x,     // 4× ce; se non disponibile collegare a ce
	input  logic        reset,

	// Bus dati/istruzioni unificato (V30 ha bus singolo)
	output logic [19:0] bus_addr,
	output logic        bus_read,
	output logic        bus_write,
	output logic  [1:0] bus_be,
	output logic [15:0] bus_dout,
	input  logic [15:0] bus_din,

	// Interrupt
	input  logic        irq_req,
	input  logic  [9:0] irq_vector,

	// Status / debug (opzionali, possono restare floating)
	output logic        cpu_idle,
	output logic        cpu_halt,
	output logic        cpu_irqrequest,
	output logic        cpu_prefix,

	// Savestate: slave del bus savestate del sistema (bridge SS interno)
	ssbus_if.slave      ss,
	// reset CPU coordinato dal manager (post-load, a RAM tutte coerenti)
	input  logic        ss_cpu_reload
);

	// FIX BYTE READ ALIGNMENT (V30 + word-aligned ROM/RAM bus):
	// sub_top fornisce sempre il word completo a indirizzo pari (forza addr aligned).
	// Quando V30 fa READ a addr dispari, cpu.vhd legge bus_dataread[7:0]
	// aspettandosi il byte ALTO del word (= byte a addr odd), ma il byte voluto
	// sta su bus_din[15:8]. Lo swap fornisce il byte corretto.
	// NB: include sia byte read (bus_be=01) sia il primo accesso di word unaligned;
	// in quest'ultimo caso cpu.vhd usa solo i bit [7:0], quindi distorto ma poi
	// fa second access a addr+1 (pari, no swap) e ricostruisce il word.
	// In pratica swap su qualsiasi read con bus_addr[0]=1.
	// V30 byte alignment fixed in sub_top/main_top (cpu_din già allineato al
	// byte richiesto secondo bus_addr[0]). Bridge passa bus_din invariato.
	wire [15:0] bus_din_to_cpu = bus_din;

	// ─── Tied-off signals (M72 cpu.vhd port set) ────────────────────────────
	wire        sleep_savestate = 1'b0;
	wire        load_savestate  = 1'b0;
	wire        turbo           = 1'b0;
	wire        SLOWTIMING      = 1'b0;

	// SSBUS savestate registers — larghezze ESATTE da pacchetto VHDL
	// (rtl/Raiden/v30/bus_savestates.vhd):
	//   SSBUS_buswidth = 64
	//   SSBUS_busadr   = 7
	//
	// IMPORTANTE: il V30 al reset interno legge SS_CPU1..4 dai defval del
	// pacchetto reg_savestates.vhd:
	//   CPU3.defval = 0x0000FFFF00000000 → reg_cs = 0xFFFF (V30 reset vector)
	// Ma `Dout_buffer` di eReg_SS si reset a defval SOLO su BUS_rst=1.
	// Quindi dobbiamo pulsare SSBUS_rst durante il reset esterno per riportare
	// i registri ai defval, altrimenti partono con CS=0x0000 (post power-on
	// è ok via initial, ma se non rilancio sim/FPGA dopo cambio core resta).
	// SSBUS pilotato dal bridge savestate interno (raiden_v30_ss).
	wire [63:0] SSBUS_Din;
	wire  [6:0] SSBUS_Adr;
	wire        SSBUS_wren;
	wire [63:0] SSBUS_Dout;
	wire        ss_reset;   // pulse post-load
	// SSBUS_rst ricarica i DEFVAL: solo al power-on reset, NON al load (dove i
	// registri SS sono stati appena scritti coi valori salvati e vanno tenuti).
	wire        SSBUS_rst  = reset & ~ss_reset;
	// Reset CPU = reset esterno OPPURE ss_reset (post-load): fa ricaricare reg_ip/ax/...
	// da SS_CPU1..4 (cpu.vhd riga 577: on reset regs <= SS_CPU).
	wire        cpu_reset  = reset | ss_reset;

	raiden_v30_ss #(.SS_IDX(SS_IDX)) u_ss (
		.clk         (clk),
		.reset       (reset),
		.ss_cpu_reload(ss_cpu_reload),
		.ssbus_din   (SSBUS_Din),
		.ssbus_adr   (SSBUS_Adr),
		.ssbus_wren  (SSBUS_wren),
		.ssbus_dout  (SSBUS_Dout),
		.ss_reset_cpu(ss_reset),
		.ss          (ss)
	);

	// Register bus debug (dummy)
	// pRegisterBus: BUS_buswidth=8, BUS_busadr=8 (verifica con package)
	wire  [7:0] RegBus_Din_unused;
	wire  [7:0] RegBus_Adr_unused;
	wire        RegBus_wren_unused;
	wire        RegBus_rden_unused;
	wire  [7:0] RegBus_Dout = 8'd0;

	// cpu_export (record VHDL pexport): non usabile da Verilog senza wrapper
	// dedicato. Il VHDL `cpu` lo dichiara come output `cpu_export : out cpu_export_type`.
	// Soluzione: NON connettere — Quartus permette output VHDL non collegati.
	// In SystemVerilog non possiamo dichiarare un wire del tipo record.
	// Workaround: l'istanza qui sotto LASCIA cpu_export floating.
	// (Se Quartus si lamenta serve un piccolo wrapper VHDL intermedio.)

	// Output unused (M72 port)
	wire        cpu_done_unused;
	wire        irqrequest_ack_unused;
	wire  [7:0] cpu_export_opcode_unused;
	wire [15:0] cpu_export_reg_cs_unused;
	wire [15:0] cpu_export_reg_ip_unused;

	// ─── Istanza VHDL cpu (M72 port set) ────────────────────────────────────
	cpu u_cpu (
		.clk               (clk),
		.ce                (ce),
		.ce_4x             (ce_4x),
		.reset             (cpu_reset),
		.turbo             (turbo),
		.SLOWTIMING        (SLOWTIMING),

		.cpu_idle          (cpu_idle),
		.cpu_halt          (cpu_halt),
		.cpu_irqrequest    (cpu_irqrequest),
		.cpu_prefix        (cpu_prefix),

		.bus_read          (bus_read),
		.bus_write         (bus_write),
		.bus_be            (bus_be),
		.bus_addr          (bus_addr),
		.bus_datawrite     (bus_dout),
		.bus_dataread      (bus_din_to_cpu),

		.irqrequest_in     (irq_req),
		.irqvector_in      (irq_vector),
		.irqrequest_ack    (irqrequest_ack_unused),

		.load_savestate    (load_savestate),

		.cpu_done          (cpu_done_unused),
		.cpu_export_opcode (cpu_export_opcode_unused),
		.cpu_export_reg_cs (cpu_export_reg_cs_unused),
		.cpu_export_reg_ip (cpu_export_reg_ip_unused),

		.RegBus_Din        (RegBus_Din_unused),
		.RegBus_Adr        (RegBus_Adr_unused),
		.RegBus_wren       (RegBus_wren_unused),
		.RegBus_rden       (RegBus_rden_unused),
		.RegBus_Dout       (RegBus_Dout),

		.sleep_savestate   (sleep_savestate),
		.SSBUS_Din         (SSBUS_Din),
		.SSBUS_Adr         (SSBUS_Adr),
		.SSBUS_wren        (SSBUS_wren),
		.SSBUS_rst         (SSBUS_rst),
		.SSBUS_Dout        (SSBUS_Dout)
	);

endmodule
