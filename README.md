# Arcade-Raiden_MiSTer

FPGA core for **Raiden** (Seibu Kaihatsu, 1990) targeting the
[MiSTer FPGA](https://github.com/MiSTer-devel) platform (Terasic DE10-Nano).

Raiden runs on **Seibu Kaihatsu hardware** — a vertical arcade board with
two NEC V30 CPUs (main + sub), a Z80 sound CPU, background / foreground
tilemaps, a text layer, a Seibu sprite generator, and YM3812 + OKI M6295
audio driven through the Seibu SEI80BU.

This core reimplements the hardware in SystemVerilog/VHDL from MAME
references and hardware observation.

> **This repository holds only the GPL-covered material — the source code.**
> No bitstream (`.rbf`) or `.mra` is included here. While the core is in
> testing, compiled builds are distributed separately; a final public release
> will follow. You can also build the core yourself with Quartus (see
> *Building from source*) and supply or create the MRA for your ROM set.

## About the game

**Raiden** is a vertically scrolling shoot-'em-up: you fly the Raiden
Supersonic Attack Fighter against an alien invasion, alternating between a
spread vulcan cannon and a homing laser while dodging dense enemy fire. Its
solid feel, the trademark bending "Toothpaste" laser and the two-player
co-op made it a coin-op landmark and the start of a long series. The board
runs the game on twin NEC V30 CPUs — a main CPU for game logic and a sub CPU
for video and background work.

## Status

**Current version: 0.9 — testing / pre-release** (July 2026).

This is a **pre-release build meant for testing**: the core runs the game
end-to-end and is being validated before a final release. Expect rough edges
and please report anything you find.

**Recent work:**
- Score display glitch (score shown as ×100, two extra trailing digits):
  root-caused to a **timing** issue — a setup violation on the V30 ALU
  datapath that had been masked by an incorrect SDC multicycle. Addressed in
  this build (the ALU is given a real two-cycle window and the constraint is
  corrected); under testing to confirm it is gone. The value stored in RAM was
  always correct.
- Savestate: the sub work RAM is saved via a dedicated dual-port (fresh-build
  safe); background layer position right after a state load still being polished.
- Audio and accuracy polish.

**Features**
- Two NEC V30 main/sub CPUs @ 10 MHz — encrypted opcodes decrypted on board
  during ROM download (no pre-decrypted ROMs needed)
- Z80 sound CPU (T80) with the Seibu SEI80BU sound interface
- Background + Foreground tilemaps and a text layer
- Sprite renderer with priority and flip
- Audio: YM3812 (OPL2, jtopl) + OKI M6295 ADPCM (jt6295)
- Tile ROM streaming through SDRAM; sprite ROM and ADPCM ROM backed by DDR3
- TATE / vertical rotation support for the analog output
- VBlank-synchronized pause (frame-aligned, no race conditions)
- **CRT H-Size / H-Position** and **Analog VGA H-Shift / V-Shift** OSD options
  for fine alignment on CRTs
- MiSTer OSD with video and DIP options
- Pause overlay with logo + supporters scroll
- Savestate (save/restore) infrastructure

**ROM sets supported**
- Raiden (`raiden`, World set 1) — parent
- Raiden (Japan)
- Raiden (USA, Fabtek)
- Raiden (Taiwan)
- Raiden (Korea)

## Hardware emulated

| Component        | Spec                                                |
|------------------|-----------------------------------------------------|
| Main CPU         | NEC V30 @ 10 MHz (encrypted opcodes)                |
| Sub CPU          | NEC V30 @ 10 MHz (encrypted opcodes)                |
| Sound CPU        | Zilog Z80 (T80)                                     |
| Sound chip 1     | Yamaha YM3812 OPL2 (jtopl)                          |
| Sound chip 2     | OKI M6295 ADPCM (jt6295)                            |
| Sound interface  | Seibu SEI80BU                                       |
| Video            | Background + Foreground tilemaps + text layer       |
| Sprites          | Seibu sprite generator                              |

## Hardware requirements

- Terasic DE10-Nano
- MiSTer I/O board (recommended)
- SDRAM module (32 MB or 64 MB)
- DDR3 memory (built into DE10-Nano, used for sprite ROM and OKI ADPCM ROM)
- Works on HDMI displays and on CRTs via the analog video output

## Building from source

Requires Quartus Prime 17.0 (free Lite Edition).

```
Open Raiden.qpf in Quartus → Processing → Start Compilation
```

Output bitstream is generated in `output_files/Raiden.rbf`.

## Running on MiSTer

This repository ships sources only — there is no prebuilt bitstream or MRA.
To run the core you build it yourself and provide the MRA and ROMs:

1. Build `Raiden.rbf` from source (see *Building from source* above).
2. Copy the `.rbf` to `_Arcade/cores/` on the MiSTer SD card.
3. Create or obtain an `.mra` for your ROM set and copy it to `_Arcade/`.
4. Provide your legally-owned ROM files where the MRA expects them
   (usually in `games/mame/`).

**Neither the bitstream, the MRA, nor the ROMs are included in this
repository.** You must build/provide them yourself.

## Repository layout

```
Arcade-Raiden_MiSTer/
├── rtl/
│   ├── Raiden/      Raiden-specific core RTL (buses, tilemaps, sprites,
│   │   │            shared RAM, decrypt, audio glue)
│   │   └── v30/     NEC V30 main/sub CPU core
│   ├── common/      shared logic: savestate, DDR gate, bridges
│   ├── jtframe/     JTFRAME framework modules
│   ├── sound/       jtopl (YM3812), jt6295 (OKI M6295), t80 (Z80), mixer
│   ├── pll/         Clock PLL
│   └── sdram.sv     SDRAM controller (Sorgelig)
├── sys/             MiSTer framework (Sorgelig / MiSTer-devel)
├── logo/            Pause overlay assets (font, logo, supporter list)
├── Raiden.qpf       Quartus project
├── Raiden.qsf       Quartus assignments
├── Raiden.sv        Top-level core wrapper
├── Template.sdc     Timing constraints
├── files.qip        HDL file list
└── README.md        This file
```

## Acknowledgements

- **Martin Donlon** ([wickerwaka](https://github.com/wickerwaka)) for the
  **NEC V30** CPU core, taken (and modified) from his R-Type MiSTer core —
  original WonderSwan V30 by **Robert Peip**
  ([@RobertPeip](https://github.com/RobertPeip), FPGAzumSpass).
- **Jose Tejada** ([@jotego](https://github.com/jotego)) for JTOPL (YM3812),
  JT6295 (OKI M6295) and the JTFRAME framework.
- **Daniel Wallner** for the **T80** Z80 CPU core.
- **Martin Donlon** ([wickerwaka](https://github.com/wickerwaka)) for the
  savestate infrastructure.
- The **MAMEDev team** for the invaluable reference on the Seibu hardware,
  memory maps, ROM decryption and timing.
- **Sorgelig** and the **MiSTer-devel team** for the framework, SDRAM
  controller and Template.

## Support this project

If you enjoy this core and want to support its development:

- [Ko-fi](https://ko-fi.com/ibecerivideoludici) — one-time support
- [Patreon](https://www.patreon.com/IBeceriVideoludici) — monthly support
- [PayPal](https://www.paypal.me/IBeceriVideoludici) — one-time donation

## Follow

- [GitHub](https://github.com/rmonic79)
- [Twitch](https://twitch.tv/ibecerivideoludici) — live streams
- [YouTube](https://www.youtube.com/c/IBeceriVideoludici) — playlists and videos
- [X / Twitter](https://x.com/rmonic79)

## License

The RTL source code in this repository is provided as-is for educational
and preservation purposes under **GNU GPL v3 or later**. Original ROM data
is not included; users must provide their own legally obtained copies.

Original *Raiden* arcade hardware © Seibu Kaihatsu, 1990.
