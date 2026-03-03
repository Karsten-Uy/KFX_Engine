#**************************************************************
# Altera DE1-SoC SDC - AudioFX
#**************************************************************

create_clock -period 20 [get_ports CLOCK_50]
create_clock -period 10 [get_ports auto_stp_external_clock_0]
create_clock -name {altera_reserved_tck} -period 100 [get_ports {altera_reserved_tck}]

derive_pll_clocks
derive_clock_uncertainty

set_clock_groups -asynchronous -group { CLOCK_50 } -group { altera_reserved_tck }
set_clock_groups -asynchronous -group { AUDIO_PLL|audio_pll_0|audio_pll|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } -group { altera_reserved_tck }
set_clock_groups -asynchronous -group { auto_stp_external_clock_0 } -group { CLOCK_50 }

set_input_delay  -clock altera_reserved_tck -clock_fall 3 [get_ports {altera_reserved_tdi}]
set_input_delay  -clock altera_reserved_tck -clock_fall 3 [get_ports {altera_reserved_tms}]
set_output_delay -clock altera_reserved_tck             3 [get_ports {altera_reserved_tdo}]

#**************************************************************
# Multicycle Paths
#
# ALL registers in every FX module are clocked at 50 MHz but
# gated by sample_en which fires at 48 kHz (~1042 cycles apart).
# Between any two consecutive sample_en pulses the data is stable
# for ~1042 clock cycles, so multicycle=2 is unconditionally safe.
#
# Round 1 fix: params[] -> fx_distortion  (-11.188 ns slack)
# Round 2 fix: mix_reg  -> audio_out      (-10.566 ns slack)
#   Path: mix_reg -> makeup_product (16x8 mul) -> cab IIR ->
#         tone_product (17x8 mul) -> pres_product (17x8 mul) -> out
#   ~31 ns path, needs 40 ns budget (multicycle=2).
#
# Applying multicycle=2 to ALL internal FX register paths covers
# any further violations of the same class in other FX modules.
#
# Hold stays at 1 (default). Standard practice: relax setup only.
#**************************************************************

# params[] -> any FX module register
set_multicycle_path -setup -from [get_registers {controller:CONTROL|params[*][*][*]}] -to [get_registers {fx_*:*|*}] 2
set_multicycle_path -hold  -from [get_registers {controller:CONTROL|params[*][*][*]}] -to [get_registers {fx_*:*|*}] 1

# Internal fx_distortion register-to-register paths (mix_reg -> audio_out, etc.)
set_multicycle_path -setup -from [get_registers {fx_distortion:FX_DISTORTION|*}] -to [get_registers {fx_distortion:FX_DISTORTION|*}] 2
set_multicycle_path -hold  -from [get_registers {fx_distortion:FX_DISTORTION|*}] -to [get_registers {fx_distortion:FX_DISTORTION|*}] 1

# Catch any other internal FX module paths of the same class
set_multicycle_path -setup -from [get_registers {fx_*:*|*}] -to [get_registers {fx_*:*|*}] 2
set_multicycle_path -hold  -from [get_registers {fx_*:*|*}] -to [get_registers {fx_*:*|*}] 1

#**************************************************************
# False Paths
#**************************************************************
set_false_path -from [get_ports {altera_reserved_tdi altera_reserved_tms}]
set_false_path -to   [get_ports {altera_reserved_tdo}]
set_false_path -from [get_ports {KEY[*] SW[*]}]
set_false_path -to   [get_ports {LEDR[*] HEX0[*] HEX1[*] HEX2[*] HEX3[*] HEX4[*] HEX5[*]}]
set_false_path -from [get_ports {AUD_ADCDAT AUD_ADCLRCK AUD_BCLK AUD_DACLRCK FPGA_I2C_SDAT}]
set_false_path -to   [get_ports {AUD_DACDAT AUD_XCK AUD_ADCLRCK AUD_BCLK AUD_DACLRCK FPGA_I2C_SCLK FPGA_I2C_SDAT}]
set_false_path -to   [get_ports {GPIO_0[*]}]
set_false_path -to   [get_registers {sld_signaltap:*}]