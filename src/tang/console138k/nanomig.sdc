create_clock -name clk_osc -period 20 -waveform {0 10} [get_ports {clk}] -add
create_clock -name clk85 -period 11.684 -waveform {0 5.842} [get_pins {pll_hdmi/u_pll/PLL_inst/CLKOUT1}] -add
# CLKOUT2 drives O_sdram_clk at 270 deg phase shift (PE_COARSE=7, PE_FINE=4 -> 7.5/10 * 11.684 ns = 8.763 ns)
create_clock -name clk85_shift -period 11.684 -waveform {8.763 14.605} [get_pins {pll_hdmi/u_pll/PLL_inst/CLKOUT2}] -add
create_clock -name clk_flash -period 11.684 -waveform {0 5.842} [get_ports {mspi_clk}] -add
create_clock -name clk_hdmi -period 7 -waveform {0 3} [get_nets {clk_pixel_x5}] -add
create_clock -name i2s_clk -period 500 -waveform {0 3} [get_nets {i2s_clk}] -add
create_clock -name clk_audio -period 500 -waveform {0 3} [get_nets {clk_audio}] -add
create_generated_clock -name clk28 -source [get_pins {pll_hdmi/u_pll/PLL_inst/CLKOUT0}] -master_clock clk_hdmi -divide_by 5 [get_pins {clk_div_5/clkdiv_inst/CLKOUT}]
set_multicycle_path -from [get_clocks {clk28}] -to [get_clocks {clk85}]  -setup -start 2
set_multicycle_path -from [get_clocks {clk28}] -to [get_clocks {clk85}]  -hold -start 2

# SDRAM I/O timing constraints (W9825G6KH-6: tS=1.5ns, tH=0.8ns, tAC=5.4ns, tOH=2.5ns; O_sdram_clk @ 270 deg):
# Bounded with both min (hold) and max (setup) delays; removed over-tight set_max_delay 4.5 which caused input hold failures.
set_input_delay  -clock clk85 -max 6.0 [get_ports {IO_sdram_dq[*]}]
set_input_delay  -clock clk85 -min 2.5 [get_ports {IO_sdram_dq[*]}]
set_output_delay -clock clk85 -max 4.5 [get_ports {IO_sdram_dq[*] O_sdram_addr[*] O_sdram_ba[*] O_sdram_dqm[*] O_sdram_cs_n O_sdram_ras_n O_sdram_cas_n O_sdram_wen_n}]
set_output_delay -clock clk85 -min -1.0 [get_ports {IO_sdram_dq[*] O_sdram_addr[*] O_sdram_ba[*] O_sdram_dqm[*] O_sdram_cs_n O_sdram_ras_n O_sdram_cas_n O_sdram_wen_n}]

# BL616 SPI signals: inputs 2-FF synchronized into clk85; bound MISO <= 16.0 ns to U13 pad
# (with -23.4 ns mcu_spi_sync latency reduction, <= 16 ns passes 12/12 XML even at 16 MHz SPI
#  without starving the timing-driven router on clk85 SDRAM paths)
set_false_path -from [get_ports {spi_sclk spi_dat spi_csn}] -to [get_clocks {clk85}]
set_max_delay 16.0 -from [get_clocks {clk85}] -to [get_ports {spi_dir}]

# sysctrl runs on clk85 for 16 MHz zero-gap SPI XML reads; its static config outputs feed clk28 logic
set_false_path -from [get_regs {sysctrl/system_*}]

# pll_hdmi/u_pll_init drives static power-on PLL lock/reset status from clk_osc into clk28/clk85
set_false_path -from [get_regs {pll_hdmi/u_pll_init/*}]
