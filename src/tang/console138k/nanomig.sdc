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
# mcu_spi_sync: req_85 -> req_28/strobe_28 (negedge clk28) is left UNEXEMPTED and checked synchronously (3.5 ns)!
# spi_target/spi_in_data/req_start -> posedge clk28 consumers are guaranteed >= 21 ns (3 clk_hdmi cycles)
# stable before strobe_28 fires on negedge->posedge clk28; -setup -end 2 (14 ns) is conservative.
set_multicycle_path -from [get_regs {mcu/spi_target_* mcu/spi_in_data_* mcu/req_start*}] -to [get_clocks {clk28}] -setup -end 2
set_multicycle_path -from [get_regs {mcu/spi_target_* mcu/spi_in_data_* mcu/req_start*}] -to [get_clocks {clk28}] -hold -end 1
# int_ack_tgl_85 -> int_ack_s1 only (first stage of 2-FF toggle synchronizer)
set_false_path -from [get_regs {int_ack_tgl_85*}] -to [get_regs {int_ack_s1*}]

# SDRAM I/O timing constraints (W9825G6KH-6: tS=1.5ns, tH=0.8ns, tAC=5.4ns, tOH=2.5ns; O_sdram_clk @ 270 deg):
# Bounded with both min (hold) and max (setup) delays; removed over-tight set_max_delay 4.5 which caused input hold failures.
set_input_delay  -clock clk85 -max 6.0 [get_ports {IO_sdram_dq[*]}]
set_input_delay  -clock clk85 -min 2.5 [get_ports {IO_sdram_dq[*]}]
set_output_delay -clock clk85 -max 4.5 [get_ports {IO_sdram_dq[*] O_sdram_addr[*] O_sdram_ba[*] O_sdram_dqm[*] O_sdram_cs_n O_sdram_ras_n O_sdram_cas_n O_sdram_wen_n}]
set_output_delay -clock clk85 -min -1.0 [get_ports {IO_sdram_dq[*] O_sdram_addr[*] O_sdram_ba[*] O_sdram_dqm[*] O_sdram_cs_n O_sdram_ras_n O_sdram_cas_n O_sdram_wen_n}]

# BL616 SPI signals: mcu_spi_sync + sysctrl run on clk_hdmi (142.86 MHz) -> -14 ns sync latency,
# 144/144 XML PASS up to 20 MHz SPI. Bound inputs <= 5.5 ns and MISO <= 14.5 ns to U13 pad.
set_max_delay 5.5  -from [get_ports {spi_sclk spi_dat spi_csn}] -to [get_clocks {clk_hdmi}]
set_max_delay 14.5 -from [get_clocks {clk_hdmi}] -to [get_ports {spi_dir}]

# sysctrl runs on clk85 for 16 MHz zero-gap SPI XML reads; its static config outputs feed clk28 logic
set_false_path -from [get_regs {sysctrl/system_*}]

# pll_hdmi/u_pll_init drives static power-on PLL lock/reset status from clk_osc into clk28/clk85
set_false_path -from [get_regs {pll_hdmi/u_pll_init/*}]
