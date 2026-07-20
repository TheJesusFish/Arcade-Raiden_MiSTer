derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# ============================================================
# Audio subsystem runs at ce_4m (96MHz/24 = 4MHz)
# All internal paths are CE-gated with 24 cycles between active edges.
# Multicycle = 24 for setup, 23 for hold.
# Target everything under Raiden_audio_z80 module (jt51, T80, mixer, jt6295...).
# FIX residuo Darius: il target era *darius_audio_z80* (nome pre-fork) che NON
# matchava il modulo reale Raiden_audio_z80 → multicycle audio MAI applicato →
# path audio valutati single-cycle → timing negativo. Trovato anche in altri core.
# ============================================================
set_multicycle_path -setup -from [get_registers {*Raiden_audio_z80*}] -to [get_registers {*Raiden_audio_z80*}] 24
set_multicycle_path -hold  -from [get_registers {*Raiden_audio_z80*}] -to [get_registers {*Raiden_audio_z80*}] 23

# ============================================================
# Raiden V30 CPUs (Main + Sub) running at 10 MHz on clk_sys 96 MHz
# CE generator emits 5/48 → media 9.6 cicli clk_sys tra due CE attivi
# Path interni cpu.vhd (memFetchValue/ALU/regs/Flag*) sono CE-gated
# Multicycle 9 setup / 8 hold (conservativo)
# Path verso esterno (main_top RAM/ROM I/O) NON multicycle-ati: bus_*
# è già gestito dal mux registrato del main_top.
# ============================================================
set_multicycle_path -setup -from [get_registers {*Raiden_main_top*u_cpu*cpu*}] -to [get_registers {*Raiden_main_top*u_cpu*cpu*}] 9
set_multicycle_path -hold  -from [get_registers {*Raiden_main_top*u_cpu*cpu*}] -to [get_registers {*Raiden_main_top*u_cpu*cpu*}] 8
set_multicycle_path -setup -from [get_registers {*Raiden_sub_top*u_cpu*cpu*}]  -to [get_registers {*Raiden_sub_top*u_cpu*cpu*}]  9
set_multicycle_path -hold  -from [get_registers {*Raiden_sub_top*u_cpu*cpu*}]  -to [get_registers {*Raiden_sub_top*u_cpu*cpu*}]  8

# ============================================================
# Video timing → palette RAM address.
# hpos avanza a ce_pix (clk_sys/16), quindi resta STABILE per 16 clk_sys.
# Il path hpos → composite_pen → pal_b_addr → palette RAM portb ha 16 clk
# reali per stabilizzarsi (la sorgente hpos non cambia tra due ce_pix).
# Quartus lo valuta single-cycle (worst -1.3 ns) ma e' un multicycle di
# fatto. Multicycle 4 (conservativo, 4 << 16) chiude il timing senza
# nascondere path realmente lenti.
# ============================================================
set_multicycle_path -setup -from [get_registers {*Raiden_video_timing*hpos*}] -to [get_registers {*raiden_video_subbus*pal_*}] 4
set_multicycle_path -hold  -from [get_registers {*Raiden_video_timing*hpos*}] -to [get_registers {*raiden_video_subbus*pal_*}] 3
# stesso path verso il registro pal_b_addr (indirizzo palette lato emu) e
# ctrl_flipscreen (stabile per frame): anch'essi hpos/ce_pix-paced.
set_multicycle_path -setup -from [get_registers {*Raiden_video_timing*hpos*}] -to [get_registers {*pal_b_addr*}] 4
set_multicycle_path -hold  -from [get_registers {*Raiden_video_timing*hpos*}] -to [get_registers {*pal_b_addr*}] 3
# ctrl_reg[6] = flip_screen (DIP): STABILE per l'intero frame (cambia solo su
# scrittura CPU rara). Il path flip_screen → hpos_for_read (255-hpos) →
# pal_b_addr era il worst (-0.238 ns) valutato single-cycle. Multicycle 4.
set_multicycle_path -setup -from [get_registers {*Raiden_main_top*ctrl_reg[6]*}] -to [get_registers {*pal_b_addr*}] 4
set_multicycle_path -hold  -from [get_registers {*Raiden_main_top*ctrl_reg[6]*}] -to [get_registers {*pal_b_addr*}] 3
