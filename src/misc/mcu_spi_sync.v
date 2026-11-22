/*
    mcu_spi_sync.v

    100% synchronous SPI interface to BL616 FPGA Companion (oversampled on clk_fast = 85.59 MHz).
    Eliminates spi_sclk_d generic-routing clock skew (Gowin WARN PR1014) completely and cuts
    byte-to-sysctrl response latency from 140..175 ns down to 35..82 ns.

    SPI MODE 1: idle SCLK low, MISO updated early after previous falling edge,
    MOSI & MISO sampled on falling edge.
*/

module mcu_spi_sync (
  input        clk,          // local core clock (28.53 MHz, phase-locked 1:3 to clk_fast)
  input        clk_fast,     // fast global clock (85.59 MHz) for SPI oversampling
  input        reset,

  // SPI interface to MCU
  input        spi_io_ss,
  input        spi_io_clk,
  input        spi_io_din,
  output       spi_io_dout,

  // byte interface to the various core components (clk domain)
  output       mcu_sys_strobe,
  output       mcu_hid_strobe,
  output       mcu_osd_strobe,
  output       mcu_sdc_strobe,
  output       mcu_start,
  input  [7:0] mcu_sys_din,
  input  [7:0] mcu_hid_din,
  input  [7:0] mcu_osd_din,
  input  [7:0] mcu_sdc_din,
  output [7:0] mcu_dout
);

// 2-FF synchronizers in clk_fast domain (85.59 MHz)
reg [2:0] ss_s   = 3'b111;
reg [2:0] sclk_s = 3'b000;
reg [1:0] din_s  = 2'b00;

always @(posedge clk_fast) begin
    ss_s   <= { ss_s[1:0],   spi_io_ss  };
    sclk_s <= { sclk_s[1:0], spi_io_clk };
    din_s  <= { din_s[0],    spi_io_din };
end

wire ss_high   = ss_s[1];
wire sclk_fall = (sclk_s[2:1] == 2'b10);

// bit counter and MOSI shift register in clk_fast domain
reg [2:0] spi_cnt     = 3'd0;
reg [6:0] spi_sr_in   = 7'd0;
reg [7:0] spi_target  = 8'd0;
reg [7:0] spi_in_data = 8'd0;
reg [3:0] spi_in_cnt  = 4'd0;
reg       req_85      = 1'b0;
reg       req_start   = 1'b0;

always @(posedge clk_fast) begin
    if (ss_high) begin
        spi_cnt    <= 3'd0;
        spi_in_cnt <= 4'd0;
    end else if (sclk_fall) begin
        spi_cnt   <= spi_cnt + 3'd1;
        spi_sr_in <= { spi_sr_in[5:0], din_s[1] };

        if (spi_cnt == 3'd7) begin
            if (spi_in_cnt == 4'd0) begin
                spi_target <= { spi_sr_in, din_s[1] };
            end else begin
                spi_in_data <= { spi_sr_in, din_s[1] };
                req_start   <= (spi_in_cnt == 4'd1);
                req_85      <= ~req_85;
            end
            if (spi_in_cnt != 4'd15)
                spi_in_cnt <= spi_in_cnt + 4'd1;
        end
    end
end

// Race-free synchronous handoff from clk_fast (85.59 MHz) to clk (28.53 MHz):
// Sample req_85 on negedge clk so strobe_28 is registered and stable for a full
// half-cycle (17.5 ns) before posedge clk consumes it in sysctrl/hid/osd/sd_card.
reg req_28 = 1'b0;
reg strobe_28 = 1'b0;
always @(negedge clk) begin
    req_28    <= req_85;
    strobe_28 <= (req_85 != req_28);
end

assign mcu_start      = req_start;
assign mcu_dout       = spi_in_data;
assign mcu_sys_strobe = strobe_28 && (spi_target == 8'd0);
assign mcu_hid_strobe = strobe_28 && (spi_target == 8'd1);
assign mcu_osd_strobe = strobe_28 && (spi_target == 8'd2);
assign mcu_sdc_strobe = strobe_28 && (spi_target == 8'd3);

wire [7:0] in_byte =
    (spi_target == 8'd0) ? mcu_sys_din :
    (spi_target == 8'd1) ? mcu_hid_din :
    (spi_target == 8'd2) ? mcu_osd_din :
    (spi_target == 8'd3) ? mcu_sdc_din :
    8'h00;

// MISO output directly muxed from registered ss_high, spi_target, spi_cnt, and mcu_*_din:
// Saves 1 full clk_fast cycle (11.7 ns) so new MSB is valid immediately after sysctrl/sd_card
// updates data_out on posedge clk, while bits 6..0 switch cleanly 23..35 ns after sclk_fall.
assign spi_io_dout = ss_high ? 1'b0 : in_byte[~spi_cnt];

endmodule
