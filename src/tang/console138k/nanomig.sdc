create_clock -name clk_osc -period 20 -waveform {0 10} [get_ports {clk}] -add
create_clock -name clk85 -period 11.684 -waveform {0 5.842} [get_pins {pll_hdmi/u_pll/PLL_inst/CLKOUT1}] -add
# CLKOUT2 drives O_sdram_clk with 216 deg phase shift (6/10 * 11.684 ns = 7.010 ns)
create_clock -name clk85_shift -period 11.684 -waveform {7.010 12.852} [get_pins {pll_hdmi/u_pll/PLL_inst/CLKOUT2}] -add
create_generated_clock -name sdram_clk_out -source [get_pins {pll_hdmi/u_pll/PLL_inst/CLKOUT2}] -master_clock clk85_shift -divide_by 1 [get_ports {O_sdram_clk}] -add
create_clock -name clk_flash -period 11.684 -waveform {0 5.842} [get_ports {mspi_clk}] -add
create_clock -name clk_hdmi -period 7 -waveform {0 3} [get_nets {clk_pixel_x5}] -add
create_clock -name i2s_clk -period 500 -waveform {0 3} [get_nets {i2s_clk}] -add
create_clock -name clk_audio -period 500 -waveform {0 3} [get_nets {clk_audio}] -add
create_generated_clock -name clk28 -source [get_pins {pll_hdmi/u_pll/PLL_inst/CLKOUT0}] -master_clock clk_hdmi -divide_by 5 [get_pins {clk_div_5/clkdiv_inst/CLKOUT}]
set_multicycle_path -from [get_clocks {clk28}] -to [get_clocks {clk85}]  -setup -start 2
set_multicycle_path -from [get_clocks {clk28}] -to [get_clocks {clk85}]  -hold -start 2

# SDRAM I/O timing referenced to O_sdram_clk port (sdram_clk_out @ 216 deg = 7.010 ns + OBUF delay):
# - Outputs (W9825G6KH-6: tS=1.5ns, tH=0.8ns + 0.5ns board margin): launched on clk85 (0ns), sampled on sdram_clk_out (7.010ns)
# - Inputs  (W9825G6KH-6: tAC=5.4ns max, tOH=2.5ns min): launched on sdram_clk_out (7.010ns), captured on clk85 (23.368ns, MCP=2)
set_output_delay -clock sdram_clk_out -max 2.0  [get_ports {IO_sdram_dq[*] O_sdram_addr[*] O_sdram_ba[*] O_sdram_dqm[*] O_sdram_cs_n O_sdram_ras_n O_sdram_cas_n O_sdram_wen_n}]
set_output_delay -clock sdram_clk_out -min -1.0 [get_ports {IO_sdram_dq[*] O_sdram_addr[*] O_sdram_ba[*] O_sdram_dqm[*] O_sdram_cs_n O_sdram_ras_n O_sdram_cas_n O_sdram_wen_n}]
set_input_delay  -clock sdram_clk_out -max 5.4  [get_ports {IO_sdram_dq[*]}]
set_input_delay  -clock sdram_clk_out -min 2.5  [get_ports {IO_sdram_dq[*]}]
set_multicycle_path -setup 2 -from [get_clocks {sdram_clk_out}] -to [get_clocks {clk85}]
set_multicycle_path -hold  1 -from [get_clocks {sdram_clk_out}] -to [get_clocks {clk85}]

# BL616 SPI signals: inputs 2-FF synchronized into clk85; registered MISO bounded <= 10 ns to U13 pad
set_false_path -from [get_ports {spi_sclk spi_dat spi_csn}] -to [get_clocks {clk85}]
set_max_delay 10.0 -from [get_clocks {clk85}] -to [get_ports {spi_dir}]

# sysctrl runs on clk85 for 16 MHz zero-gap SPI XML reads; its static config outputs feed clk28 logic
set_false_path -from [get_regs {sysctrl/system_*}]
