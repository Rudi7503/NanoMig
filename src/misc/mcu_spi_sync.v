/*
    mcu_spi_sync.v

    100% synchronous SPI interface to BL616 FPGA Companion (oversampled on clk_fast = 85 MHz).
    Eliminates spi_sclk_d generic-routing clock skew (Gowin WARN PR1014) completely.
    SPI MODE 1: idle SCLK low, MISO updated on rising edge, MOSI & MISO sampled on falling edge.
*/

module mcu_spi_sync (
  input        clk,          // local core clock (28.57 MHz)
  input        clk_fast,     // fast global clock (85.59 MHz) for SPI oversampling
  input        reset,

  // SPI interface to MCU
  input        spi_io_ss,
  input        spi_io_clk,
  input        spi_io_din,
  output reg   spi_io_dout,

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
wire sclk_rise = (sclk_s[2:1] == 2'b01);
wire sclk_fall = (sclk_s[2:1] == 2'b10);

// bit counter and MOSI shift register in clk_fast domain
reg [3:0] spi_cnt = 4'd0;
reg [7:0] spi_data_in = 8'd0;
reg [6:0] spi_sr_in = 7'd0;
reg       spi_data_in_ready = 1'b0;

always @(posedge clk_fast) begin
    if (ss_high) begin
        spi_cnt <= 4'd0;
        spi_data_in_ready <= 1'b0;
    end else if (sclk_fall) begin
        spi_cnt <= spi_cnt + 4'd1;
        spi_sr_in <= { spi_sr_in[5:0], din_s[1] };

        if (spi_cnt[2:0] == 3'd7) begin
            spi_data_in <= { spi_sr_in, din_s[1] };
            spi_data_in_ready <= 1'b1;
        end
        if (spi_cnt[2:0] == 3'd3)
            spi_data_in_ready <= 1'b0;
    end
end

// bring received byte into local clk (28 MHz) domain
reg       spi_in_strobe = 1'b0;
reg [7:0] spi_target = 8'd0;
assign mcu_sys_strobe = spi_in_strobe && (spi_target == 8'd0);
assign mcu_hid_strobe = spi_in_strobe && (spi_target == 8'd1);
assign mcu_osd_strobe = spi_in_strobe && (spi_target == 8'd2);
assign mcu_sdc_strobe = spi_in_strobe && (spi_target == 8'd3);

reg [3:0] spi_in_cnt = 4'd0;
reg [7:0] spi_in_data = 8'd0;
assign mcu_start = (spi_in_cnt == 4'd2);
assign mcu_dout  = spi_in_data;

// clk_fast (85.59 MHz) and clk (28.57 MHz) are synchronous from pll_hdmi -> 1-stage edge detect
reg spi_data_in_ready_prev = 1'b0;

always @(posedge clk) begin
    spi_data_in_ready_prev <= spi_data_in_ready;

    if (ss_high)
        spi_in_cnt <= 4'd0;

    if (spi_data_in_ready && !spi_data_in_ready_prev) begin
        if (spi_in_cnt == 4'd0)
            spi_target <= spi_data_in;
        else begin
            spi_in_strobe <= 1'b1;
            spi_in_data <= spi_data_in;
        end

        if (spi_in_cnt != 4'd15)
            spi_in_cnt <= spi_in_cnt + 4'd1;
    end else
        spi_in_strobe <= 1'b0;
end

wire [7:0] in_byte =
    (spi_target == 8'd0) ? mcu_sys_din :
    (spi_target == 8'd1) ? mcu_hid_din :
    (spi_target == 8'd2) ? mcu_osd_din :
    (spi_target == 8'd3) ? mcu_sdc_din :
    8'h00;

// MISO output updated on negedge clk_fast when sclk_s[1] rises (17.5..29.2 ns after SCLK rise,
// leaving >= 8.3 ns setup margin before BL616's falling-edge sample at 37.5 ns @ 13.33 MHz)
always @(negedge clk_fast) begin
    if (ss_high)
        spi_io_dout <= 1'b0; // bl616 EN_CHIP fix
    else if (sclk_s[1] && !sclk_s[2])
        spi_io_dout <= in_byte[~spi_cnt[2:0]];
end

endmodule
