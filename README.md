# Arcade-Raiden_MiSTer

FPGA core for **Raiden** (Seibu Kaihatsu, 1990) targeting the
[MiSTer FPGA](https://github.com/MiSTer-devel) platform (Terasic DE10-Nano).

Raiden runs on **Seibu Kaihatsu hardware** — a vertical arcade board with
two NEC V30 CPUs (main + sub), a Z80 sound CPU, background / foreground
tilemaps, a text layer, a Seibu sprite generator, and YM3812 + OKI M6295
audio driven through the Seibu SEI80BU.

This core reimplements the hardware in SystemVerilog/VHDL from MAME
references and hardware observation.

## About the game

**Raiden** is a vertically scrolling shoot-'em-up: you fly the Raiden
Supersonic Attack Fighter against an alien invasion, alternating between a
spread vulcan cannon and a homing laser while dodging dense enemy fire. Its
solid feel, the trademark bending "Toothpaste" laser and the two-player
co-op made it a coin-op landmark and the start of a long series. The board
runs the game on twin NEC V30 CPUs — a main CPU for game logic and a sub CPU
for video and background work.

## Status

**Current version: 1.0** (July 2026).

The core runs the game end-to-end with video, audio and inputs on real MiSTer
hardware, across all supported ROM sets.

**Highlights:**
- Score display glitch (score shown as ×100, two extra trailing digits):
  root-caused to a **timing** issue — a setup violation on the V30 ALU datapath
  masked by an incorrect SDC multicycle — and **fixed** (the ALU now gets a real
  two-cycle window and the constraint is corrected), validated over extended play
  testing. The value stored in RAM was always correct.
- **Player 1P / 2P** selector added — a solo player can play as player 2 with a
  single pad, chosen from the OSD.
- Both NEC V30 CPUs run at the original **10 MHz** (fixed).
- Savestate: the sub work RAM save is in place (dedicated dual-port, fresh-build
  safe), but the **OSD save/restore entries are currently disabled** — the
  sound-chip and Z80 state are not captured yet, so a restore can play back with
  wrong audio. They will be re-enabled once the audio state capture is fixed.
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
- **Player 1P / 2P** selector — play solo as player 2 with a single pad
- MiSTer OSD with video and DIP options
- Pause overlay with logo + supporters scroll
- Savestate infrastructure present (OSD save/restore entries currently disabled —
  see Status)

**ROM sets supported**
- Raiden (`raiden`, World set 1) — parent
- Raiden (Japan)
- Raiden (USA, Fabtek)
- Raiden (Taiwan)
- Raiden (Korea)

## Screenshots

**Vertical (TATE)**

| | |
|---|---|
| ![Logo](docs/RD_Logo_Tate.png) | ![Gameplay](docs/RD_Gameplay_Tate.png) |
| Logo | Gameplay |
| ![Gameplay](docs/RD_Gameplay_Tate_2.png) | |
| Gameplay | |

**Landscape**

| | |
|---|---|
| ![Two-player co-op](docs/RD_2P_Yoko.png) | ![Fade](docs/RD_Fade_Yoko.png) |
| Two-player co-op | Fade |
| ![Gameplay](docs/RD_Gameplay_Yoko.png) | ![Gameplay](docs/RD_Gameplay_Yoko_2.png) |
| Gameplay | Gameplay |
| ![Gameplay](docs/RD_Gameplay_Yoko_3.png) | |
| Gameplay | |

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

The [releases/](releases/) folder contains the MRA files and a prebuilt RBF:

- `Raiden (World).mra` — parent MRA
- `releases/_alternatives/` — MRAs for the other regions (Japan, US, Taiwan, Korea)
- `Raiden_YYYYMMDD.rbf` — prebuilt bitstream

Steps:

1. Copy the `.rbf` to `_Arcade/cores/` on the MiSTer SD card (rename to
   `Raiden.rbf` or keep the dated name and update the MRA accordingly).
2. Copy the `.mra` file(s) to `_Arcade/` on the MiSTer SD card.
3. Provide your legally-owned ROM files where the MRA expects them
   (usually in `games/mame/`).

**ROMs are NOT included in this repository.** You must provide them yourself.

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
├── docs/            In-game screenshots
├── releases/        MRA files + prebuilt RBF
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
