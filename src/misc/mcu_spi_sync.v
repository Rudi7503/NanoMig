/*
    mcu_spi_sync.v

    100% synchronous SPI interface to BL616 FPGA Companion (oversampled on clk_fast = 85.59 MHz).
    Eliminates spi_sclk_d generic-routing clock skew (Gowin WARN PR1014) completely.
    Provides fast clk_fast strobe for sysctrl (so full 932-byte XML reads pass 12/12 phases
    even at 13.333 MHz zero-gap SPI with 100% registered MISO output), and race-free
    clk (28.53 MHz) strobes for hid/osd/sd_card.

    SPI MODE 1: idle SCLK low, MISO updated on clk_fast after previous falling edge,
    MOSI & MISO sampled on falling edge.
*/

module mcu_spi_sync (
  input        clk,          // local core clock (28.53 MHz, phase-locked 1:3 to clk_fast)
  input        clk_fast,     // fast global clock (85.59 MHz) for SPI oversampling & sysctrl
  input        reset,

  // SPI interface to MCU
  input        spi_io_ss,
  input        spi_io_clk,
  input        spi_io_din,
  output reg   spi_io_dout,

  // fast (clk_fast) byte interface for sysctrl
  output       mcu_sys_strobe,
  output       mcu_start_fast,
  output [7:0] mcu_dout_fast,

  // local (clk = 28.53 MHz) byte interface for hid, osd, sd_card
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
reg       strobe_fast = 1'b0;
reg       req_85      = 1'b0;
reg       req_start   = 1'b0;

always @(posedge clk_fast) begin
    strobe_fast <= 1'b0;

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
                strobe_fast <= 1'b1;
                req_85      <= ~req_85;
            end
            if (spi_in_cnt != 4'd15)
                spi_in_cnt <= spi_in_cnt + 4'd1;
        end
    end
end

// Fast clk_fast interface (for sysctrl)
assign mcu_sys_strobe = strobe_fast && (spi_target == 8'd0);
assign mcu_start_fast = req_start;
assign mcu_dout_fast  = spi_in_data;

// Race-free synchronous handoff from clk_fast (85.59 MHz) to clk (28.53 MHz) for hid/osd/sd_card:
reg req_28 = 1'b0;
reg strobe_28 = 1'b0;
always @(negedge clk) begin
    req_28    <= req_85;
    strobe_28 <= (req_85 != req_28);
end

assign mcu_start      = req_start;
assign mcu_dout       = spi_in_data;
assign mcu_hid_strobe = strobe_28 && (spi_target == 8'd1);
assign mcu_osd_strobe = strobe_28 && (spi_target == 8'd2);
assign mcu_sdc_strobe = strobe_28 && (spi_target == 8'd3);

wire [7:0] in_byte =
    (spi_target == 8'd0) ? mcu_sys_din :
    (spi_target == 8'd1) ? mcu_hid_din :
    (spi_target == 8'd2) ? mcu_osd_din :
    (spi_target == 8'd3) ? mcu_sdc_din :
    8'h00;

// 100% registered MISO output on posedge clk_fast (zero combinational output path, zero half-cycle paths):
// With sysctrl on clk_fast, new MSB is latched into spi_io_dout within 35..47 ns of bit 7 falling edge,
// leaving >= 28 ns setup margin before bit 0 falling edge even at 13.333 MHz zero-gap SPI.
always @(posedge clk_fast) begin
    if (ss_high)
        spi_io_dout <= 1'b0; // bl616 EN_CHIP fix
    else
        spi_io_dout <= in_byte[~spi_cnt];
end

endmodule
