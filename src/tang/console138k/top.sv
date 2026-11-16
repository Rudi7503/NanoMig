/*
    top.sv - Minimig on tang console 138k toplevel
*/ 

`define ENABLE_TG68K
`define ENABLE_AGA   // offer the AGA chipset in the menu
`define CPU_SLOW14   // run TG68K at 14MHz effective (A1200 speed) for timing closure
`define ENABLE_CACHE // MiSTer cpu cache between the cpu and the sdram (cached kickstart + fast ram)
`define CHIPRAM_CACHE 

/* we need two copies in case of 256k kickroms
     openFPGALoader --external-flash -o 0x600000 kick13.rom
     openFPGALoader --external-flash -o 0x640000 kick13.rom
   or a single copy of e.g. a 512k diag rom
     openFPGALoader --external-flash -o 0x600000 DiagROM
*/

// LED usage:
// RGB led1, CFG:  G = ready, R = power/sys_act, B = done
// RGB led2, VBUS: G = power, R = charge, B = stdby

// on som, done and ready

module top(
  input			clk, // 50 MHz in

  input			reset_n, // S2
  input			user_n, // S1
  input			key_som, // SOM button

  output [2:0]	leds,

  // spi flash interface
  output		mspi_cs,
  output		mspi_clk,
  inout			mspi_di,
  inout			mspi_hold,
  inout			mspi_wp,
  inout			mspi_do,

  // MiSTer SDRAM module
  output		O_sdram_clk,
  output		O_sdram_cs_n, // chip select
  output		O_sdram_cas_n, // columns address select
  output		O_sdram_ras_n, // row address select
  output		O_sdram_wen_n, // write enable
  inout [15:0]	IO_sdram_dq, // 16 bit bidirectional data bus
  output [12:0]	O_sdram_addr, // 13 bit multiplexed address bus
  output [1:0]	O_sdram_ba, // two banks
  output [1:0]	O_sdram_dqm, // 16/2

  // give explicit connections for pmod0 as it's being used for the
  // FPGA Companion and this allows for clock buffering. Clock glitches
  // were observed when using inouts for the companion
  input			pmod_companion_din,
  output		pmod_companion_dout,
  input			pmod_companion_clk,
  input			pmod_companion_ss,
  output		pmod_companion_intn,

  // PMOD1 closer to the HDMI
  inout [7:0]	pmod1,

  output		jtagseln,
  input			bl616_jtagsel,
  input			bl616_tx,
  output		uart_ext_tx,

  // interface to onboard BL616 µC
  input			spi_sclk, 
  input			spi_csn,
  output		spi_dir,
  input			spi_dat,
  output		spi_irqn,

  // SD card slot
  output		sd_clk,
  inout			sd_cmd, // MOSI
  inout [3:0]	sd_dat, // 0: MISO
           
  output		lcd_clk,
  output        lcd_en,
  output		lcd_hs,
  output		lcd_vs,
  output [7:0]	lcd_r, //lcd red
  output [7:0]	lcd_g, //lcd green
  output [7:0]	lcd_b, //lcd blue
  output		lcd_bl, //drive low to turn bl off

  // I2S DAC
  output		i2s_bclk,
  output		i2s_lrck,
  output		i2s_din,
  output		pa_en,
           
  // hdmi/tdms
  output		tmds_clk_n,
  output		tmds_clk_p,
  output [2:0]	tmds_d_n,
  output [2:0]	tmds_d_p
);

// pmod 1 is unused
assign pmod1 = 8'hzz;
      
// physcial dsub9 joystick & mouse port 1 is unused
wire [5:0] db9_joy = { 6'b000000 };

// physcial dsub9 joystick port 2 ís unused
wire [5:0] db9_joy2 = { 6'b000000 };
   
wire [1:0]	drv_leds;
wire		pwr_led; 

// ============================== clock generation ===========================

// current pll settings according to src/gowin_pll_parser.py

/*
  Input clock: 50 Mhz
  pf: 850.0 Mhz
  Output0:
    Freq: 141.66666666666666 Mhz
    Phase: 0.0°
  Output1:
    Freq: 85.0 Mhz
    Phase: 0.0°
  Output2:
    Freq: 85.0 Mhz
    Phase: 216.0°
  Output2:
    Freq: 85.0 Mhz
    Phase: 
*/

// 180° barely boots, crashes early
// 216° boots
// 252° boots, DiagROM reports some rom checksum errors

// Pixel clock if derived from 141 2/3 MHz
`define PIXEL_CLOCK 28333333

wire clk_pixel_x5;   
wire clk_85m;   
wire clk_85m_shifted;   
wire pll_lock;   
pll_142m pll_hdmi (
    .clkout0(clk_pixel_x5),
    .clkout1(clk_85m),
    .clkout2(clk_85m_shifted), // 216 deg phase shifted
    .clkout3(), //mspi_clk),        // 180 deg phase shifted
    .init_clk(clk),
    .lock(pll_lock),
    .clkin(clk)
);

assign O_sdram_clk = clk_85m_shifted;

wire clk_pixel;
Gowin_CLKDIV clk_div_5 (
    .hclkin(clk_pixel_x5), // input hclkin
    .resetn(pll_lock),   // input resetn
    .clkout(clk_pixel)     // output clkout
);

wire	clk_28m = clk_pixel;
wire	clk7_en;   
wire	clk7n_en;   

// ========================== Startup control ===========================

// The startup control detects whether one of the user buttons (usually
// used for reset or OSD open/close) is pressed during core startup. 

   
// The MiSTle project makes extensive use of various components of the
// gowin FPGAs:
// 1) They use the FPGAs flash memory as program storage using runtime
   
// The gowin programmer is unable to write to a flash that is in dspi
// mode. With any of the two buttons pressed during powerup, the flash
// driver will thus be kept in reset forever, leaving the flash memory
// in regular SPI mode to make sure the programmer can access it.

wire spi_ext = 1'b0;       // Tang Console uses onboard BL616 only
reg boot_button_detected = 1'b1;
always @(posedge pll_lock)
  boot_button_detected <= !user_n || !reset_n;   

// led 2 is the green component of the CFG RGB led
// (controlled below by diagnostic blinker)
// enable JTAG if any button has been pressed during boot and also once
// the external FPGA Companion has been seen
wire	sys_jtagsel;
assign jtagseln = pll_lock && !sys_jtagsel;
assign uart_ext_tx = bl616_tx;   // from BL616 to PMOD

// control signals generated by the user via the OSD
wire 	   osd_reset;   
wire [1:0] osd_chipmem;         // 0=512k, 1=1M, 2=1.5M, 3=2M
wire [1:0] osd_slowmem;         // 0=None, 1=512k, 2=1M, 3=1.5M
wire [1:0] osd_fastmem;         // 0=None, 1=2M, 2=4M
wire [1:0] osd_floppy_drives;
wire       osd_floppy_wrprot;
wire       osd_floppy_turbo;
wire       osd_ide_enable;
wire [2:0] osd_chipset;         // 0=OCS-A500, 1=OCS-A1000, 2=ECS, 6=AGA
wire [1:0] osd_cpu;             // 0=68000, 1=68010, 3=68020
wire [2:0] osd_turbo;           // turbo config
wire       osd_video_mode;      // PAL (0=PAL, 1=NTSC)
wire [1:0] osd_video_screen;    // 0=normal, 1=overscan, 2=wide screen (jailbars)
wire [1:0] osd_video_filter;
wire [1:0] osd_video_scanlines;
wire       osd_joy_swap;        // 0=off, 1=on
wire [2:0] osd_volume;          // Mute=0, 1=25%, 2=50%, 3=75%, 4=100%
wire       osd_stereo_mix;      // 0=off, 1=on

wire       rom_done;

// generate a reset for some time after rom has been initialized
reg [15:0] reset_cnt;
always @(posedge clk_28m) begin
    if(!pll_lock || !rom_done || kbd_reset)
        reset_cnt <= 16'hffff;
    else if(reset_cnt != 0)
        reset_cnt <= reset_cnt - 16'd1;
end

// this is the reset that goes into the nanomig itself
wire cpu_reset = |reset_cnt;
wire sdram_ready;

// -------------------------- FPGA Companion MCU interface -----------------------

// map output data onto both spi outputs
wire spi_io_dout;
wire spi_intn;

// intn and dout are outputs driven by the FPGA to the MCU
// din, ss and clk are inputs coming from the MCU
assign spi_dir = spi_io_dout;
assign spi_irqn = spi_intn;

assign pmod_companion_dout = spi_io_dout;
assign pmod_companion_intn = spi_intn;
   
// On Tang Console, the onboard BL616 is always used
// (PMOD companion port is unconnected and must not override)

// filter companion SPI clock
wire [15:0] pmod_companion_clk_D = { pmod_companion_clk_D[14:0], pmod_companion_clk } /* synthesis syn_keep=1 */ /* synthesis syn_dont_touch=1 */;
wire pmod_companion_clk_F = ( pmod_companion_clk && pmod_companion_clk_D != 16'h0000) ||
	                        (!pmod_companion_clk && pmod_companion_clk_D == 16'hffff);

// switch between internal SPI connected to the on-board bl616
// or to the external one possibly connected to a FPGA Companion
wire spi_io_din = spi_dat;
wire spi_io_ss = spi_csn;
wire spi_io_clk = spi_sclk;

// interface to FPGA Companion
wire       mcu_sys_strobe;        // mcu message byte valid for sysctrl
wire       mcu_hid_strobe;        // -"- hid
wire       mcu_osd_strobe;        // -"- osd
wire       mcu_sdc_strobe;        // -"- sdc
wire       mcu_start;             // first byte of MCU message

wire [7:0] mcu_data_out;  

wire [7:0] sys_data_out;  
wire [7:0] hid_data_out;  
wire [7:0] osd_data_out = 8'h55;  // OSD actually has no data output
wire [7:0] sdc_data_out;
   
mcu_spi mcu (
	 .clk(clk_28m),
	 .reset(!pll_lock),

	 // SPI interface to FPGA Companion
     .spi_io_ss(spi_io_ss),
     .spi_io_clk(spi_io_clk),
     .spi_io_din(spi_io_din),
     .spi_io_dout(spi_io_dout),

	 // byte wide data in/out to the submodules
     .mcu_sys_strobe(mcu_sys_strobe),
     .mcu_hid_strobe(mcu_hid_strobe),
     .mcu_osd_strobe(mcu_osd_strobe),
     .mcu_sdc_strobe(mcu_sdc_strobe),
     .mcu_start(mcu_start),
     .mcu_dout(mcu_data_out),
     .mcu_sys_din(sys_data_out),
     .mcu_hid_din(hid_data_out),
     .mcu_osd_din(osd_data_out),
     .mcu_sdc_din(sdc_data_out)
);

// decode SPI/MCU data received for human input devices (HID) and
// convert into Amiga compatible mouse and keyboard signals
wire [7:0] int_ack;
wire hid_int;
wire hid_iack = int_ack[1];
wire sdc_iack = int_ack[3];
wire sdc_int;
wire [7:0] hid_joy0;
wire [7:0] hid_joy1;
   
// signals to wire the floppy controller to the sd card
wire [7:0]  sd_rd;
wire [7:0]  sd_wr;
wire [7:0]  sd_rd_data;
wire [7:0]  sd_wr_data;
wire [31:0] sd_sector;  
wire [8:0]  sd_byte_index;
wire        sd_rd_byte_strobe;
wire        sd_busy, sd_done;
wire [63:0] sd_img_size;
wire [7:0]  sd_img_mounted;
reg         sd_ready;
   
sd_card #(
    .CLK_DIV(3'd0)                   // for 28 Mhz clock
) sd_card (
    .rstn(pll_lock),                 // rstn active-low, 1:working, 0:reset
    .clk(clk_28m),                   // clock
  
    // SD card signals
    .sdclk(sd_clk),
    .sdcmd(sd_cmd),
    .sddat(sd_dat),

    // mcu interface
    .data_strobe(mcu_sdc_strobe),
    .data_start(mcu_start),
    .data_in(mcu_data_out),
    .data_out(sdc_data_out),

    // output file/image information. Image size is e.g. used by fdc to 
    // translate between sector/track/side and lba sector
    .image_mounted(sd_img_mounted),
    .image_size(sd_img_size),           // length of image file

    // interrupt to signal communication request
    .irq(sdc_int),
    .iack(sdc_iack),

    // user read sector command interface (sync with clk32)
    .rstart(sd_rd), 
    .wstart(sd_wr), 
    .rsector(sd_sector),
    .rbusy(sd_busy),
    .rdone(sd_done),

    // sector data output interface (sync with clk32)
    .inbyte(sd_wr_data),
    .outen(sd_rd_byte_strobe), // when outen=1, a byte of sector content is read out from outbyte
    .outaddr(sd_byte_index),   // outaddr from 0 to 511, because the sector size is 512
    .outbyte(sd_rd_data)       // a byte of sector content
);

// keyboard and mouse interface to Minimig
wire [2:0] mouse_buttons; // mouse buttons
wire	   kbd_mouse_level;  
wire [1:0] kbd_mouse_type;  
wire [7:0] kbd_mouse_data;  
wire       kbd_reset;      // keyboard reset (Ctrl+LAmiga+RAmiga)

wire keyboard_ack;

hid hid (
        .clk(clk_28m),
        .reset(!pll_lock),

         // interface to receive user data from MCU (mouse, kbd, ...)
        .data_in_strobe(mcu_hid_strobe),
        .data_in_start(mcu_start),
        .data_in(mcu_data_out),
        .data_out(hid_data_out),

        // input local db9 port events to be sent to MCU. Changes also trigger
        // an interrupt, so the MCU doesn't have to poll for joystick events
        .db9_port( db9_joy ),
        .irq( hid_int ),
        .iack( hid_iack ),

        // keyboard & mouse
        .mouse_buttons(mouse_buttons), // mouse buttons
        .kbd_mouse_level(kbd_mouse_level),
        .kbd_mouse_type(kbd_mouse_type),
        .kbd_mouse_data(kbd_mouse_data),
        .keyboard_ack(keyboard_ack),
        .vsync_n(vs_n),

        .kbd_reset(kbd_reset),
        .joystick0(hid_joy0),
        .joystick1(hid_joy1)
);

sysctrl #(
`ifdef ENABLE_AGA
    .AGA(1)
`else
    .AGA(0)
`endif
) sysctrl (
        .clk(clk_28m),
        .reset(!pll_lock),

         // interface to send and receive generic system control
        .data_in_strobe(mcu_sys_strobe),
        .data_in_start(mcu_start),
        .data_in(mcu_data_out),
        .data_out(sys_data_out),

        // values controlled by the OSD
		.system_reset(osd_reset),
		.system_floppy_drives(osd_floppy_drives),
		.system_floppy_turbo(osd_floppy_turbo),
		.system_floppy_wrprot(osd_floppy_wrprot),
		.system_ide_enable(osd_ide_enable),
	    .system_chipset(osd_chipset),
	    .system_cpu(osd_cpu),
	    .system_turbo(osd_turbo),
		.system_video_mode(osd_video_mode),
		.system_video_screen(osd_video_screen),
		.system_video_filter(osd_video_filter),
		.system_video_scanlines(osd_video_scanlines),
		.system_chipmem(osd_chipmem),
		.system_slowmem(osd_slowmem),
		.system_fastmem(osd_fastmem),
        .system_joy_swap(osd_joy_swap),
        .system_volume(osd_volume),
        .system_stereo_mix(osd_stereo_mix),
				 
        .int_out_n(spi_intn),
        .int_in( { 4'b0000, sdc_int, 1'b0, hid_int, 1'b0 }),
        .int_ack( int_ack ),

        .buttons( { !user_n, !reset_n } ),
        .leds(),
		.jtagsel(sys_jtagsel),
        .color()
);
   
// digital video from Minimig (4 bits per color)
wire hs_n, vs_n;
wire [3:0] red;
wire [3:0] green;
wire [3:0] blue;
   
wire [5:0] video_red;
wire [5:0] video_green;
wire [5:0] video_blue;   

osd_u8g2 osd_u8g2 (
        .clk(clk_28m),
        .reset(!pll_lock),

        .data_in_strobe(mcu_osd_strobe),
        .data_in_start(mcu_start),
        .data_in(mcu_data_out),

        .hs(hs_n),
        .vs(vs_n),

        .r_in({red,   red[3:2]}),
        .g_in({green, green[3:2]}),
        .b_in({blue,  blue[3:2]}),

        .r_out(video_red),
        .g_out(video_green),
        .b_out(video_blue)
);   

// map to internal lcd
assign lcd_r = {video_red, 2'b00};
assign lcd_g = {video_green, 2'b00};
assign lcd_b = {video_blue, 2'b00};
   
/* ---------------------- Minimig chipset ----------------------- */

// two 15 bit audio channels
wire [14:0] audio_left;
wire [14:0] audio_right;   

// map first HID/USB joystick into second amiga joystick port
// wire in db9 joystick
wire [7:0] physical_port_1 = { 
               hid_joy0[7], 
               hid_joy0[6], 
              (hid_joy0[5] | db9_joy[5]), 
              (hid_joy0[4] | db9_joy[4]),
              (hid_joy0[3] | db9_joy[3]), 
              (hid_joy0[2] | db9_joy[2]),
              (hid_joy0[1] | db9_joy[1]),
              (hid_joy0[0] | db9_joy[0]) };   

            // map second HID/USB joystick into second amiga joystick port
            // wire in db9 joystick
wire [7:0] physical_port_2 = { 
               hid_joy1[7], 
               hid_joy1[6], 
              (hid_joy1[5] | db9_joy2[5]),
              (hid_joy1[4] | db9_joy2[4]),
              (hid_joy1[3] | db9_joy2[3]), 
              (hid_joy1[2] | db9_joy2[2]),
              (hid_joy1[1] | db9_joy2[1]),
              (hid_joy1[0] | db9_joy2[0]) }; 
              
wire [7:0] joystick0;
wire [7:0] joystick1;

// Swap Joysticks 

assign joystick0 = osd_joy_swap ? physical_port_1 : physical_port_2;
assign joystick1 = osd_joy_swap ? physical_port_2 : physical_port_1;

wire [23:1] cpu_a;
wire cpu_as_n, cpu_lds_n, cpu_uds_n;
wire cpu_rw, cpu_dtack_n;
wire [2:0] ipl_n;
wire [15:0] cpu_din, cpu_dout;       

// Minimig ram/rom interface
wire [23:1] ram_a;
wire [15:0] ram_din;
wire [15:0] ram_dout;
wire 	    ram_we_n;
wire [1:0]  ram_be;
wire 	    ram_oe_n;
wire		ram_refresh;   
   
wire fastram_sel;
wire [22:1] fastram_addr;
wire fastram_lds;
wire fastram_uds;
wire [15:0] fastram_dout;
wire [15:0] fastram_din;
wire [1:0] fastram_be = {fastram_uds,fastram_lds};
wire fastram_wr;
wire fastram_ready;

wire [15:0] sdram_dout;
wire [47:0] chip48;
wire [47:0] fastram_dout48;

// Sprite-Engine: eigener Speicher-Master (Avalon-MM, 64 Bit, Burst 4).
// Der Adapter unten uebersetzt ihn auf den 16-Bit-SDRAM-Anschluss p2.
wire [31:0] spr_mem_address;
wire [3:0]  spr_mem_burstcount;
wire        spr_mem_read;
wire [63:0] spr_mem_readdata;
wire        spr_mem_readdatavalid;
wire        spr_mem_waitrequest;
wire        diag_cpu_rst_n;
wire        diag_cpu_rd_ack;
wire [2:0]  diag_bus_stage;
wire [127:0] diag_snap;

// Einziger physischer p2-Anschluss, vom Arbiter verwaltet
wire [22:0] p2_addr;
wire [1:0]  p2_ds;
wire        p2_cs;
wire        p2_we;
wire [15:0] p2_dout;
wire [47:0] p2_dout48;
wire        p2_ack;

// Engine-Seite des Arbiters
wire [22:0] spr_sd_addr;
wire        spr_sd_cs;
wire [15:0] spr_sd_dout;
wire [47:0] spr_sd_dout48;
wire        spr_sd_ack;

assign ram_din = sdram_dout;

// pack config values into minimig config
wire [5:0] chipset_config = { 1'b0, osd_chipset, osd_video_mode, 1'b0 };
wire [1:0] cpu_config     = osd_cpu;
wire [2:0] turbo_config   = osd_turbo;
wire [7:0] memory_config  = { 4'b0_000, osd_slowmem, osd_chipmem };   
wire [2:0] fastram_config = { 1'b0, osd_fastmem };   
wire [3:0] floppy_config  = { osd_floppy_drives, osd_floppy_wrprot, osd_floppy_turbo };
wire [3:0] video_config   = { osd_video_filter, osd_video_scanlines };   
wire [5:0] ide_config     = { 5'b10000, osd_ide_enable };   
   
nanomig nanomig
(
 .clk_sys(clk_28m),
 .reset(cpu_reset),
 .por(!pll_lock),

 .clk7_en(clk7_en),
 .clk7n_en(clk7n_en),

 .pwr_led(pwr_led),
 .fdd_led(drv_leds[0]),
 .hdd_led(drv_leds[1]),
 
 .memory_config(memory_config),
 .fastram_config(fastram_config),
 .cpu_config(cpu_config),
 .turbo_config(turbo_config),
 .chipset_config(chipset_config),
 .floppy_config(floppy_config),
 .video_config(video_config),
 .ide_config(ide_config),

 // video
 .hs(hs_n), // horizontal sync
 .vs(vs_n), // vertical sync
 .r(red),
 .g(green),
 .b(blue),

 .audio_left(audio_left),
 .audio_right(audio_right),

 // uart interface 
 .uart_rx(1'b0),
 .uart_tx(),
 
 // keyboard & mouse				 
 .mouse_buttons(mouse_buttons), // mouse buttons
 .kbd_mouse_level(kbd_mouse_level),  
 .kbd_mouse_type(kbd_mouse_type),  
 .kbd_mouse_data(kbd_mouse_data),
 .keyboard_ack(keyboard_ack),
 .joystick0(joystick0),
 .joystick1(joystick1),
				 
 // sd card interface for floppy disk and hdd emulation
 .sdc_img_size(sd_img_size),
 .sdc_img_mounted(sd_img_mounted), 
 .sdc_rd(sd_rd),
 .sdc_wr(sd_wr),
 .sdc_sector(sd_sector),
 .sdc_busy(sd_busy),
 .sdc_done(sd_done), 
 .sdc_byte_in_strobe(sd_rd_byte_strobe),
 .sdc_byte_addr(sd_byte_index),
 .sdc_byte_in_data(sd_rd_data),
 .sdc_byte_out_data(sd_wr_data),
 
 // (s)ram interface
 .ram_data(ram_dout),       // sram data bus
 .ram_address(ram_a),       // sram address bus
 .ramdata_in(ram_din),      // sram data bus in
 ._ram_bhe(ram_be[1]),      // sram upper byte select
 ._ram_ble(ram_be[0]),      // sram lower byte select
 ._ram_we(ram_we_n),        // sram write enable
 ._ram_oe(ram_oe_n),        // sram output enable
`ifdef ENABLE_AGA
 .chip48(chip48),
`else
 .chip48(48'd0),
`endif
 .refresh(ram_refresh),

 .fastram_sel(fastram_sel),
 .fastram_addr(fastram_addr),
 .fastram_lds(fastram_lds),
 .fastram_uds(fastram_uds),
 .fastram_dout(fastram_dout),
`ifdef ENABLE_CACHE
 .fastram_dout48(fastram_dout48),
`else
 .fastram_dout48(48'b0),
`endif
 .fastram_din(fastram_din),
 .fastram_wr(fastram_wr),
 .fastram_ready(fastram_ready),

 // Sprite-Engine: Speicher-Master zum Adapter
 .spr_mem_address(spr_mem_address),
 .spr_mem_burstcount(spr_mem_burstcount),
 .spr_mem_read(spr_mem_read),
 .spr_mem_readdata(spr_mem_readdata),
 .spr_mem_readdatavalid(spr_mem_readdatavalid),
 .spr_mem_waitrequest(spr_mem_waitrequest),

 .diag_cpu_rst_n(diag_cpu_rst_n),
 .diag_cpu_rd_ack(diag_cpu_rd_ack),
 .diag_bus_stage(diag_bus_stage),
 .diag_snap(diag_snap)
);

wire           flash_ready;  
wire           mem_ready = sdram_ready && flash_ready && pll_lock;  
   
reg            start_rom_copy;
reg            mem_ready_D;

// geneate a start_rom_copy signal once flash and SDRAM are initialized
always @(posedge clk_28m or negedge pll_lock) begin
 if(!pll_lock) begin
      start_rom_copy <= 1'b0;
      mem_ready_D <= 1'b0;
         
   end else begin
      mem_ready_D <= mem_ready;  
      start_rom_copy <= 1'b0;         

      if(mem_ready && !mem_ready_D)
          start_rom_copy <= 1'b1;     
   end
end

/* -------------- state machine copying data from flash to sdram ---------------- */
reg [22:0]  flash_addr;  
wire [15:0] flash_dout;
reg [15:0]  flash_doutD;
reg		    flash_cs;  
reg [21:0]  word_count;
wire        flash_data_strobe;
wire        flash_busy;   

reg [21:0]  flash_ram_addr;   
reg         flash_ram_cs;
reg         flash_ram_we;
reg         flash_ram_sync;
reg         flash_p2_cs;
reg         verify_ack_prev;
reg         flash_busy_s1;
reg         flash_busy_s2;
reg         flash_busy_seen;
reg [63:0]  diag_flash_64;
reg [63:0]  diag_sdram_64;
reg [15:0]  write_din_lat;
reg [1:0]   write_crc_cnt;
reg         write_crc_done;
reg [21:0]  diag_write_cnt;
reg         diag_bad_wr_cnt;
reg [3:0]   loader_sync_cnt;
reg [63:0]  verify_shift;
reg [3:0]   verify_crc_cnt;
reg [21:0]  verify_addr;
reg         verify_phase;
reg [5:0]   flash_cnt;  
reg [6:0]   ram_cnt;
reg [2:0]   fsm_state;
reg         rom_done_reg;

function automatic [63:0] crc64_byte(input [63:0] crc_in, input [7:0] d);
    reg [63:0] c;
    integer i;
    begin
        c = crc_in ^ {d, 56'd0};
        for (i = 0; i < 8; i = i + 1)
            c = c[63] ? ({c[62:0], 1'b0} ^ 64'h42F0E1EBA9EA3693) : {c[62:0], 1'b0};
        crc64_byte = c;
    end
endfunction

assign rom_done = rom_done_reg;

localparam FSM_INIT       = 3'd0;
localparam FSM_READ_FLASH = 3'd1;
localparam FSM_WAIT_FLASH = 3'd2;
localparam FSM_WRITE_RAM  = 3'd3;
localparam FSM_NEXT_WORD  = 3'd4;
localparam FSM_DONE       = 3'd5;
localparam FSM_VERIFY_RAM = 3'd6;
localparam FSM_VERIFY_P1  = 3'd7;

always @(posedge clk_85m) begin
    if (!mem_ready) begin
        flash_addr      <= 23'h300000;          // 6MB byte-address = 0x600000
        flash_ram_addr  <= { 4'hf, 18'h0 };     // 512k SDRAM segment 15
        word_count      <= 22'd262144;          // FULL 512 KiB Kickstart ROM copy with periodic refresh during flash wait
        flash_cs        <= 1'b0;
        flash_ram_cs    <= 1'b0;
        flash_ram_we    <= 1'b0;
        flash_ram_sync  <= 1'b0;
        flash_p2_cs     <= 1'b0;
        verify_ack_prev <= 1'b0;
        flash_busy_s1   <= 1'b0;
        flash_busy_s2   <= 1'b0;
        flash_busy_seen <= 1'b0;
        diag_flash_64   <= 64'd0;
        diag_sdram_64   <= 64'd0;
        write_din_lat   <= 16'd0;
        write_crc_cnt   <= 2'd0;
        write_crc_done  <= 1'b0;
        diag_write_cnt  <= 22'd0;
        diag_bad_wr_cnt <= 1'b0;
        loader_sync_cnt <= 4'd0;
        verify_shift    <= 64'd0;
        verify_crc_cnt  <= 4'd0;
        verify_addr     <= 22'h3C0000;
        verify_phase    <= 1'b0;
        flash_cnt       <= 6'd0;
        ram_cnt         <= 7'd0;
        rom_done_reg    <= 1'b0;
        fsm_state       <= FSM_INIT;
    end else begin
        flash_busy_s1   <= flash_busy;
        flash_busy_s2   <= flash_busy_s1;
        loader_sync_cnt <= (loader_sync_cnt == 4'd11) ? 4'd0 : (loader_sync_cnt + 4'd1);
        flash_ram_sync  <= (fsm_state != FSM_DONE) && (loader_sync_cnt >= 4'd9);

        case (fsm_state)
            FSM_INIT: begin
                flash_cs        <= 1'b1;
                flash_busy_seen <= 1'b0;
                ram_cnt         <= 7'd0;
                fsm_state       <= FSM_WAIT_FLASH;
            end

            FSM_READ_FLASH: begin
                flash_cs        <= 1'b1;
                flash_busy_seen <= 1'b0;
                ram_cnt         <= 7'd0;
                fsm_state       <= FSM_WAIT_FLASH;
            end

            FSM_WAIT_FLASH: begin
                // Continuous 7.09 MHz loader_sync_cnt keeps SDRAM refreshed (>8192/64ms)
                ram_cnt <= ram_cnt + 7'd1;

                if (flash_busy_s2) begin
                    flash_cs        <= 1'b0;
                    flash_busy_seen <= 1'b1;
                end

                if (flash_busy_seen && !flash_busy_s2) begin
                    flash_cs       <= 1'b0;
                    flash_doutD    <= flash_dout;
                    write_crc_cnt  <= 2'd0;
                    write_crc_done <= 1'b0;
                    ram_cnt        <= 7'd0;
                    fsm_state      <= FSM_WRITE_RAM;
                end
            end

            FSM_WRITE_RAM: begin
                ram_cnt <= ram_cnt + 7'd1;
                // Hold flash_ram_cs/we until actual CMD_WRITE executes (even if PORT_REFRESH preempts one 12-cycle slot)
                if (!write_crc_done && !diag_cmd_write) begin
                    flash_ram_cs <= 1'b1;
                    flash_ram_we <= 1'b1;
                end
                if (diag_cmd_write) begin
                    flash_ram_cs   <= 1'b0;
                    flash_ram_we   <= 1'b0;
                    write_crc_done <= 1'b1;
                    diag_write_cnt <= diag_write_cnt + 22'd1;
                end
                if (write_crc_done && !diag_cmd_write) begin
                    flash_ram_addr <= flash_ram_addr + 22'd1;
                    fsm_state      <= FSM_NEXT_WORD;
                end else if (ram_cnt == 7'd127) begin
                    flash_ram_cs   <= 1'b0;
                    flash_ram_we   <= 1'b0;
                    flash_ram_addr <= flash_ram_addr + 22'd1;
                    fsm_state      <= FSM_NEXT_WORD;
                end
            end

            FSM_NEXT_WORD: begin
                flash_addr <= flash_addr + 23'd1;

                if (word_count <= 22'd1) begin
                    diag_bad_wr_cnt <= (diag_write_cnt != 22'd262144);
                    diag_flash_64   <= (diag_write_cnt != 22'd262144) ? {16'hBAD0, 26'd0, diag_write_cnt} : 64'd0;
                    word_count      <= 22'd0;
                    ram_cnt         <= 7'd0;
                    verify_addr     <= 22'h3C0000;
                    verify_phase    <= 1'b0;
                    flash_ram_cs    <= 1'b0;
                    flash_ram_we    <= 1'b0;
                    flash_p2_cs     <= 1'b0;
                    flash_ram_sync  <= 1'b0;
                    verify_ack_prev <= p2_ack;
                    fsm_state       <= FSM_VERIFY_RAM;
                end else begin
                    word_count   <= word_count - 22'd1;
                    fsm_state    <= FSM_READ_FLASH;
                end
            end

            FSM_VERIFY_RAM: begin
                if (verify_crc_cnt != 4'd0) begin
                    if (!verify_phase) begin
                        if (!diag_bad_wr_cnt)
                            diag_flash_64 <= crc64_byte(diag_flash_64, verify_shift[63:56]);
                    end else
                        diag_sdram_64 <= crc64_byte(diag_sdram_64, verify_shift[63:56]);
                    verify_shift   <= {verify_shift[55:0], 8'd0};
                    verify_crc_cnt <= verify_crc_cnt - 4'd1;
                    if (verify_crc_cnt == 4'd1) begin
                        if (verify_addr == 22'h3FFFFC) begin
                            if (!verify_phase) begin
                                verify_phase    <= 1'b1;
                                verify_addr     <= 22'h3C0000;
                                ram_cnt         <= 7'd0;
                                verify_ack_prev <= p2_ack;
                            end else begin
                                rom_done_reg <= 1'b1;
                                fsm_state    <= FSM_DONE;
                            end
                        end else begin
                            verify_addr     <= verify_addr + 22'd4;
                            ram_cnt         <= 7'd0;
                            verify_ack_prev <= p2_ack;
                        end
                    end
                end else begin
                    ram_cnt <= ram_cnt + 7'd1;
                    if (ram_cnt == 7'd4) flash_p2_cs <= 1'b1;

                    if (ram_cnt >= 7'd20 && (p2_ack != verify_ack_prev)) begin
                        verify_shift   <= {p2_dout, p2_dout48};
                        verify_crc_cnt <= 4'd8;
                        flash_p2_cs    <= 1'b0;
                    end else if (ram_cnt == 7'd127) begin
                        diag_sdram_64 <= 64'hDEAD_BEEF_DEAD_BEEF;
                        flash_p2_cs   <= 1'b0;
                        rom_done_reg  <= 1'b1;
                        fsm_state     <= FSM_DONE;
                    end
                end
            end

            FSM_DONE: begin
                rom_done_reg    <= 1'b1;
                flash_cs        <= 1'b0;
                flash_ram_cs    <= 1'b0;
                flash_ram_sync  <= 1'b0;
                flash_p2_cs     <= 1'b0;
            end

            default: fsm_state <= FSM_INIT;
        endcase
    end
end

// ----------------------------- SDRAM ---------------------------------

// there's a total of 16 sdram segments of 512kBytes. The last
// one is being used to store the kick rom

// run a counter at 28Mhz synchonous to the 7Mhz bus cycle
reg	    [1:0] cyc;   
always @(posedge clk_28m)
  if(clk7_en) cyc <= 2'd0;
  else        cyc <= cyc + 2'd1;

wire        sdram_access  = (!ram_oe_n || !ram_we_n);  
wire	    sdram_rw      = !ram_we_n;
   
wire		sdram_cs      = rom_done ? sdram_access : flash_ram_cs;

wire        sdram_sync    = rom_done ? !cyc         : flash_ram_sync;
   
wire		sdram_refresh = rom_done ? ram_refresh  : 1'b0;
   
wire [21:0] sdram_addr    = rom_done ? ram_a[22:1]  : flash_ram_addr;
wire [15:0] sdram_din     = rom_done ? ram_dout     : flash_doutD;
wire [1:0]  sdram_be      = rom_done ? ram_be       : 2'b00;
wire        minimig_is_accessing_rom = (ram_a[22:19] == 4'b1111);
wire		sdram_we      = rom_done ? (sdram_rw && !minimig_is_accessing_rom) : flash_ram_we; 

localparam CHIP48_BURST = 0
`ifdef ENABLE_AGA
    | 1
`endif
`ifdef ENABLE_CACHE
    | 1
`endif
    ;

wire        diag_cmd_write;
wire [15:0] diag_write_din;
wire  [1:0] diag_write_dqm;

sdram #(
    .CHIP48_BURST(CHIP48_BURST)
) sdram (
	.sd_data    ( IO_sdram_dq   ), // 32 bit bidirectional data bus
	.sd_addr    ( O_sdram_addr  ), // 11 bit multiplexed address bus
	.sd_dqm     ( O_sdram_dqm   ), // two byte masks
	.sd_ba      ( O_sdram_ba    ), // two banks
	.sd_cs      ( O_sdram_cs_n  ), // a single chip select
	.sd_we      ( O_sdram_wen_n ), // write enable
	.sd_ras     ( O_sdram_ras_n ), // row address select
	.sd_cas     ( O_sdram_cas_n ), // columns address select

	// cpu/chipset interface
	.clk        ( clk_85m       ), // sdram is accessed at 85MHz
	.reset_n    ( pll_lock      ), // init signal after FPGA config to initialize RAM

	.ready      ( sdram_ready   ), // ram is ready and has been initialized
	.sync       ( sdram_sync    ), // rising edge of sync is begin of a memory cycle
	.refresh    ( sdram_refresh ), // refresh cycle
	.din        ( sdram_din     ), // data input from chipset/cpu
	.dout       ( sdram_dout    ),
	.dout48     ( chip48        ),
	.addr       ( sdram_addr    ), // 22 bit word address
	.ds         ( sdram_be      ), // upper/lower data strobe
	.cs         ( sdram_cs      ), // cpu/chipset requests read/wrie
	.we         ( sdram_we      ), // cpu/chipset requests write
			 
	.p2_din        ( fastram_din     ), // data input from chipset/cpu
	.p2_dout       ( p2_dout         ),
	.p2_dout48     ( p2_dout48       ),
	.p2_addr       ( p2_addr         ), // 23 bit word address
	.p2_ds         ( p2_ds           ), // upper/lower data strobe
	.p2_cs         ( p2_cs           ), // cpu/chipset requests read/wrie
	.p2_we         ( p2_we           ), // cpu/chipset requests write
	.p2_ack        ( p2_ack          ),

	.diag_cmd_write( diag_cmd_write  ),
	.diag_write_din( diag_write_din  ),
	.diag_write_dqm( diag_write_dqm  )
);

// --------------------------------------------------------------------
//  Sprite-Engine am SDRAM-Anschluss p2
//  Der Arbiter teilt sich den einen Anschluss mit dem Prozessor.
//
//  Fehlersuche 2026-11-13: Mit `SPR_MEM_DISABLE wird die Engine vom
//  Speicher getrennt und der Prozessor haengt wie vorher direkt am
//  SDRAM. Bootet dieser Stand, liegt der Fehler im Arbiter.
// --------------------------------------------------------------------
`define SPR_BRAM_TEST
// `define USE_SPR_ARB

`ifdef USE_SPR_ARB

// --------------------------------------------------------------------
//  Sprite-Engine am SDRAM-Anschluss p2
//  Der Arbiter teilt sich den einen Anschluss mit dem Prozessor.
// --------------------------------------------------------------------
sdram_p2_arbiter spr_arb (
	.clk        ( clk_85m       ),
	.rst_n      ( pll_lock      ),

	.a_addr     ( fastram_addr  ),
	.a_ds       ( fastram_be    ),
	.a_cs       ( fastram_sel   ),
	.a_we       ( fastram_wr    ),
	.a_dout     ( fastram_dout  ),
	.a_dout48   ( fastram_dout48),
	.a_ack      ( fastram_ready ),

	.b_addr     ( spr_sd_addr   ),
	.b_cs       ( spr_sd_cs     ),
	.b_dout     ( spr_sd_dout   ),
	.b_dout48   ( spr_sd_dout48 ),
	.b_ack      ( spr_sd_ack    ),

	.p2_addr    ( p2_addr       ),
	.p2_ds      ( p2_ds         ),
	.p2_cs      ( p2_cs         ),
	.p2_we      ( p2_we         ),
	.p2_dout    ( p2_dout       ),
	.p2_dout48  ( p2_dout48     ),
	.p2_ack     ( p2_ack        )
);

sprite_mem_adapter spr_adapter (
	.clk                ( clk_85m ),
	.rst_n              ( pll_lock ),

	.avm_address        ( spr_mem_address       ),
	.avm_read           ( spr_mem_read          ),
	.avm_waitrequest    ( spr_mem_waitrequest   ),
	.avm_readdata       ( spr_mem_readdata      ),
	.avm_readdatavalid  ( spr_mem_readdatavalid ),

	.sd_addr            ( spr_sd_addr   ),
	.sd_cs              ( spr_sd_cs     ),
	.sd_dout            ( spr_sd_dout   ),
	.sd_dout48          ( spr_sd_dout48 ),
	.sd_ack             ( spr_sd_ack    )
);

`else

// Prozessor haengt direkt am SDRAM-Anschluss p2 (kein Arbiter)
assign p2_addr       = rom_done ? {1'b0, fastram_addr} : {1'b0, verify_addr};
assign p2_ds         = rom_done ? fastram_be           : 2'b00;
assign p2_cs         = rom_done ? fastram_sel          : flash_p2_cs;
assign p2_we         = rom_done ? fastram_wr           : 1'b0;
assign fastram_dout   = p2_dout;
assign fastram_dout48 = p2_dout48;
assign fastram_ready  = p2_ack;

`ifdef SPR_BRAM_TEST
// Block-RAM-Testmuster fuer die Sprite-Engine (Toby, 2026-11-13)
spr_test_pattern spr_bram_test (
	.clk               ( clk_28m               ),
	.rst_n             ( !cpu_reset            ),
	.avm_address       ( spr_mem_address       ),
	.avm_read          ( spr_mem_read          ),
	.avm_waitrequest   ( spr_mem_waitrequest   ),
	.avm_readdata      ( spr_mem_readdata      ),
	.avm_readdatavalid ( spr_mem_readdatavalid )
);
`else
// Engine ohne Speicher: sie kann nichts holen und bleibt stumm
assign spr_mem_readdata      = 64'd0;
assign spr_mem_readdatavalid = 1'b0;
assign spr_mem_waitrequest   = 1'b0;
`endif

`endif


// run the flash at 28MHz for clean DSPI timing during power-up kickstart copy
assign mspi_clk = clk_28m;
flash #(.READ_DELAY(0)) flash (
    .clk       ( clk_28m     ),
    .resetn    ( !(!pll_lock) ),
    .ready     ( flash_ready ),

    .address   ( flash_addr  ),
    .cs        ( flash_cs    ),
    .dout      ( flash_dout  ),
	.busy      ( flash_busy  ),

    .mspi_cs   ( mspi_cs     ),
    .mspi_di   ( mspi_di     ),
    .mspi_hold ( mspi_hold   ),
    .mspi_wp   ( mspi_wp     ),
    .mspi_do   ( mspi_do     )
);

/* -------------------- LCD video and audio -------------------- */

wire vreset, vpal, interlace, short_frame;
video_analyzer video_analyzer (
    .clk         ( clk_28m   ),
    .hs          ( hs_n      ),
    .vs          ( vs_n      ),
    .pal         ( vpal      ),
    .short_frame ( short_frame ),
    .screen      ( osd_video_screen ),
    .interlace   ( interlace ),
    .vreset      ( vreset    )
);

assign lcd_clk = clk_pixel;
assign lcd_hs = hs_n;   // no syncs on this lcd
assign lcd_vs = vs_n;
assign lcd_bl = !cpu_reset;   // enable display backlight once cpu is out of reset

reg [9:0] hcnt;   // max 1023
reg [9:0] vcnt;   // max 626

// generate the 800x480 pixel display enable signal 
assign lcd_en = (hcnt < 10'd800) && (vcnt < 10'd480);

always @(posedge clk_pixel) begin
   reg       last_vs_n, last_hs_n;

   last_hs_n <= hs_n;   

   // rising edge/end of hsync
   if(hs_n && !last_hs_n) begin
      hcnt <= 10'd980;

      last_vs_n <= vs_n;   
      if(vs_n && !last_vs_n) begin
         vcnt <= 10'd946;                
      end else
        vcnt <= vcnt + 10'd1;    
   end else
      hcnt <= hcnt + 10'd1;    
end
/* ------------------- audio processing --------------- */

reg [14:0] scaled_audio_left;
reg [14:0] scaled_audio_right;

// MAX98357A
   
// EN is actually the /SD_MODE of the MAX98357A and driving it high selects
// left channel only. For stereo mixing there would have to be a "large" 
// resistor as a pullup which isn't there on the TN20k

assign pa_en = !cpu_reset;   // simply enable amplifier with left channel

reg i2s_clk;
reg [7:0] i2s_clk_cnt;
always @(posedge clk_28m) begin
    if(i2s_clk_cnt < 28375160 / (24000*32) / 2 - 1)
        i2s_clk_cnt <= i2s_clk_cnt + 8'd1;
    else begin
        i2s_clk_cnt <= 8'd0;
        i2s_clk <= ~i2s_clk;
    end
end

// sign expand and add both channels
wire [15:0] audio_mix = { scaled_audio_left[14], scaled_audio_left} + { scaled_audio_right[14], scaled_audio_right };
   
// shift audio down to reduce amp output volume to a sane range
localparam AUDIO_SHIFT = 2;   
wire [15:0] audio_scaled = { { AUDIO_SHIFT+1{audio_mix[15]}}, audio_mix[14:AUDIO_SHIFT] };   
   
// count 32 bits, 16 left and 16 right channel. MAX samples
// on rising edge
reg [15:0] audio;
reg [4:0] audio_bit_cnt;
always @(posedge i2s_clk) begin
   if(cpu_reset) audio_bit_cnt <= 5'd0;
   else          audio_bit_cnt <= audio_bit_cnt + 5'd1;

   // latch data so it's stable during transmission
   if(audio_bit_cnt == 5'd31)
	 audio <= audio_scaled;   
end

// generate i2s signals
assign i2s_bclk = !i2s_clk;
assign i2s_lrck = cpu_reset?1'b0:audio_bit_cnt[4];
assign i2s_din = cpu_reset?1'b0:audio[15-audio_bit_cnt[3:0]];

/* -------------------- HDMI video and audio -------------------- */

// latch audio, so it's stable during 48khz transfer
reg [15:0] audio_reg [2]; // 16 bit signed audio for HDMI

// Sign-extend inputs to 16-bit BEFORE mixing – intermediate sum
// cannot overflow, result always fits back in 15 bit.
wire signed [15:0] audio_left_s  = {{1{audio_left[14]}},  audio_left};
wire signed [15:0] audio_right_s = {{1{audio_right[14]}}, audio_right};

reg signed [14:0] mixed_audio_left;
reg signed [14:0] mixed_audio_right;
reg signed [14:0] scaled_audio_left;
reg signed [14:0] scaled_audio_right;

// generate 48khz audio clock
// An integer divider cannot land on 48kHz, and the truncation leaves the
// stream running fast, so sinks drop a chunk of audio every few seconds. A
// phase accumulator keeps the fractional part.
localparam [31:0] AUDIO_INC = (64'd48000 <<< 32) / `PIXEL_CLOCK;
reg [31:0] aclk_acc;
reg        clk_audio;
reg        aclk_tick;

always @(posedge clk_pixel) begin
    aclk_acc  <= aclk_acc + AUDIO_INC;
    clk_audio <= aclk_acc[31];                 // msb of the accumulator = 48kHz
    aclk_tick <= (clk_audio != aclk_acc[31]);  // high the cycle after each edge

    // The sample word must not change on the same clk_pixel edge that toggles
    // clk_audio: the hdmi module latches it on that very edge, so data and
    // clock would race and the captured word could pick up wrong bits, which
    // is audible as noisy samples. Updating one cycle later leaves the word
    // stable for a full audio half period before it is sampled.
    if(aclk_tick) begin

        // --- Stereo Mix (75/25)-------------------------------------------
        // 16-bit signed wires prevent any overflow; the result
        // always fits in 15 bit and is truncated safely on assignment. 
	    case (osd_stereo_mix)
            1'b0: begin   // no mix
                mixed_audio_left  <= audio_left;
                mixed_audio_right <= audio_right;
            end
            default: begin  // 75 / 25 blend
                mixed_audio_left  <= (audio_left_s  - (audio_left_s  >>> 2))
                                   + (audio_right_s >>> 2);
                mixed_audio_right <= (audio_right_s - (audio_right_s >>> 2))
                                   + (audio_left_s  >>> 2);
            end
        endcase

    // --- Volume scaling ----------------------------------------
        // mixed_audio_* are reg signed [14:0], so >>> is always
        // arithmetic – no $signed() wrapper required.
        case (osd_volume) 
            3'b100: begin // 100%
                scaled_audio_left  <= mixed_audio_left;
                scaled_audio_right <= mixed_audio_right;
            end
            3'b011: begin // 75%
                scaled_audio_left  <= (mixed_audio_left  >>> 1) + (mixed_audio_left  >>> 2);
                scaled_audio_right <= (mixed_audio_right >>> 1) + (mixed_audio_right >>> 2);
            end
            3'b010: begin // 50%
                scaled_audio_left  <= mixed_audio_left  >>> 1;
                scaled_audio_right <= mixed_audio_right >>> 1;
            end
            3'b001: begin // 25%
                scaled_audio_left  <= mixed_audio_left  >>> 2;
                scaled_audio_right <= mixed_audio_right >>> 2;
            end
            3'b000: begin // Mute
                scaled_audio_left  <= 15'd0;
                scaled_audio_right <= 15'd0;
            end
            default: begin // fallback 50 %
                scaled_audio_left  <= mixed_audio_left  >>> 1;
                scaled_audio_right <= mixed_audio_right >>> 1;
            end
        endcase

        // --- HDMI audio register ----------------------------------
        // Convert signed two's complement → offset binary:
        // flip sign bit (bit 14).  Bit 15 = 0 (15-bit audio in 16-bit slot).
        // Explicit per-element assignment avoids unpacked-array ambiguity.
        audio_reg[0] <= {scaled_audio_left[14], scaled_audio_left[14:0]};
        audio_reg[1] <= {scaled_audio_right[14], scaled_audio_right[14:0]};	

    end
end
   
wire [2:0] tmds;
wire tmds_clock;

// HDMI-Diagnose-Overlay: 4x32 Bit Schnappschuss des 1. ROM/FastRAM-Linefills (hdmi_cx 96..607, hdmi_cy 64..191)
wire [10:0] hdmi_cx;
wire [9:0]  hdmi_cy;
wire diag_ovl_x = (hdmi_cx >= 11'd96) && (hdmi_cx < 11'd608);
wire diag_ovl_y = (hdmi_cy >= 10'd64) && (hdmi_cy < 10'd192) && (hdmi_cy[4:0] < 5'd20);
wire [10:0] diag_x_rel  = hdmi_cx - 11'd96;
wire [4:0] diag_bit_pos = diag_x_rel[8:4];
wire [1:0] diag_row     = hdmi_cy[6:5] - 2'd2;
wire [31:0] diag_row_word = (diag_row == 2'd0) ? diag_flash_64[63:32] :
                            (diag_row == 2'd1) ? diag_flash_64[31:0]  :
                            (diag_row == 2'd2) ? diag_sdram_64[63:32] : diag_sdram_64[31:0];
wire diag_bit_val = diag_row_word[5'd31 - diag_bit_pos];
wire diag_tick    = (diag_bit_pos[1:0] == 2'b11) && (diag_x_rel[3:0] >= 4'd14);
wire diag_bar     = (diag_x_rel[3:0] < 4'd12);
wire [23:0] diag_hdmi_rgb =
    (diag_ovl_x && diag_ovl_y) ? (
        diag_bar  ? (diag_bit_val ? 24'h00FF00 : 24'h181860) :
        diag_tick ? 24'hFFFFFF : 24'h000000
    ) : { video_red, 2'b00, video_green, 2'b00, video_blue, 2'b00 };

hdmi #(
    .AUDIO_RATE(48000), .AUDIO_BIT_WIDTH(16),
    .VENDOR_NAME( { "MiSTle", 16'd0} ),
    .PRODUCT_DESCRIPTION( {"Nanomig", 72'd0} )
) hdmi(
  .clk_pixel_x5(clk_pixel_x5),
  .clk_pixel(clk_pixel),
  .clk_audio(clk_audio),
  .audio_sample_word( audio_reg ),
  .tmds(tmds),
  .tmds_clock(tmds_clock),
  .cx_out(hdmi_cx),
  .cy_out(hdmi_cy),

  .pal_mode(vpal),
  .short_frame ( short_frame ),
  .screen ( osd_video_screen ),
  .interlace(interlace),
  .reset(vreset),    // signal to synchronize HDMI

  .rgb( diag_hdmi_rgb )
);

// differential output
ELVDS_OBUF tmds_bufds [3:0] (
        .I({tmds_clock, tmds}),
        .O({tmds_clk_p, tmds_d_p}),
        .OB({tmds_clk_n, tmds_d_n})
);
   
// ==================== 3-Farben-LED-Diagnose (Toby, PR #11) ====================
// Startkennzeichnung (erste 1,6 s): 2x kurz Weiss AN (0,4s an / 0,4s aus x2)
// Danach (Active-low: 0 = AN, 1 = AUS):
//   Rot   (leds[1]): AN solange tatsaechlicher CPU-Reset anliegt (!diag_cpu_rst_n)
//   Gruen (leds[2]): AN sobald rom_done einmal erreicht (gespeichert bis !pll_lock)
//   Blau  (leds[0]): AUS bis zum ersten CPU-Leseabschluss; danach im 250ms-Fenster:
//                    blinkt (2 Hz) bei laufenden Reads, DAUERLICHT bei Stillstand

reg diag_rd_tgl = 1'b0;
always @(posedge clk_28m) begin
    if (diag_cpu_rd_ack)
        diag_rd_tgl <= ~diag_rd_tgl;
end

reg [1:0] diag_rst_sync = 2'b00;
reg [1:0] diag_rom_sync = 2'b00;
reg [1:0] diag_pll_sync = 2'b00;
reg [2:0] diag_rd_sync  = 3'b000;

reg        diag_rom_latched = 1'b0;
reg        diag_seen_rd     = 1'b0;
reg        diag_rd_in_win   = 1'b0;
reg        diag_rd_active   = 1'b0;
reg        diag_blue_phase  = 1'b0;
reg [23:0] diag_win_cnt     = 24'd0; // 250 ms = 12_500_000 @ 50 MHz
reg [26:0] diag_boot_cnt    = 27'd0; // 1,6 s  = 80_000_000 @ 50 MHz
reg [23:0] diag_slot_cnt    = 24'd0; // 300 ms = 15_000_000 @ 50 MHz
reg [4:0]  diag_slot        = 5'd0;  // 0..29 = 9,0 s Periode
reg [2:0]  diag_stage_sync  = 3'd0;
reg [1:0]  diag_cpu_cfg_sync = 2'b11;

wire diag_rd_edge = (diag_rd_sync[2] != diag_rd_sync[1]);

always @(posedge clk) begin
    diag_rst_sync   <= {diag_rst_sync[0], diag_cpu_rst_n};
    diag_rom_sync   <= {diag_rom_sync[0], rom_done};
    diag_pll_sync   <= {diag_pll_sync[0], pll_lock};
    diag_rd_sync      <= {diag_rd_sync[1:0], diag_rd_tgl};
    diag_stage_sync   <= diag_bus_stage;
    diag_cpu_cfg_sync <= cpu_config;

    if (diag_boot_cnt < 27'd80_000_000)
        diag_boot_cnt <= diag_boot_cnt + 27'd1;

    if (diag_slot_cnt >= 24'd14_999_999) begin
        diag_slot_cnt <= 24'd0;
        diag_slot     <= (diag_slot >= 5'd29) ? 5'd0 : (diag_slot + 5'd1);
    end else begin
        diag_slot_cnt <= diag_slot_cnt + 24'd1;
    end

    if (!diag_pll_sync[1]) begin
        diag_rom_latched <= 1'b0;
        diag_seen_rd     <= 1'b0;
        diag_rd_in_win   <= 1'b0;
        diag_rd_active   <= 1'b0;
    end else begin
        if (diag_rom_sync[1])
            diag_rom_latched <= 1'b1;

        if (!diag_rst_sync[1]) begin
            // Im CPU-Reset Read-Detektor fuer den frischen Anlauf zuruecksetzen
            diag_seen_rd   <= 1'b0;
            diag_rd_in_win <= 1'b0;
            diag_rd_active <= 1'b0;
        end else if (diag_rd_edge) begin
            diag_seen_rd   <= 1'b1;
            diag_rd_in_win <= 1'b1;
        end
    end

    if (diag_win_cnt >= 24'd12_499_999) begin
        diag_win_cnt    <= 24'd0;
        diag_blue_phase <= ~diag_blue_phase;
        diag_rd_active  <= diag_rd_in_win;
        diag_rd_in_win  <= 1'b0;
    end else begin
        diag_win_cnt <= diag_win_cnt + 24'd1;
    end
end

wire diag_boot_sig = (diag_boot_cnt < 27'd80_000_000);
wire diag_boot_on  = (diag_boot_cnt < 27'd20_000_000) ||
                     (diag_boot_cnt >= 27'd40_000_000 && diag_boot_cnt < 27'd60_000_000);

// Eindeutige Blau -> Rot -> Gruen Abfolge auf den 3 Einzel-LEDs (keine Mischfarben):
//   Boot-Signatur (erste 2 s): Blau 3x schnell
//   !rom_done                : Rot 5 Hz schnell
//   !diag_cpu_rst_n (Reset)  : Rot Dauer-AN
//   !diag_seen_rd (0 Reads)  :
//     Stage 1 (TG68K Reset=1)          : 1x Blau -> Pause
//     Stage 2 (clkena_lw=0)            : 1x Blau -> 1x Rot -> Pause
//     Stage 3 (setstate="01")          : 1x Blau -> 1x Rot -> 1x Gruen -> Pause
//     Stage 4 (cpustate!="01", Bus)    : 2x Blau -> 1x Gruen -> Pause
//     Stage 5 (ACK ohne diag_seen_rd)  : 3x Blau -> 1x Gruen -> Pause
//   diag_seen_rd == 1:
//     Aktiv (Reads laufen)             : Gruen 1 Hz blinkend (25% PWM)
//     Stillstand nach erstem Read      : Gruen Dauer-AN (25% PWM)
reg diag_blue_code, diag_red_code, diag_green_code;
always @(*) begin
    diag_blue_code  = 1'b0;
    diag_red_code   = 1'b0;
    diag_green_code = 1'b0;
    if (diag_boot_sig) begin
        diag_blue_code = diag_boot_on;
    end else if (!diag_rom_latched) begin
        diag_red_code = diag_slot[0];
    end else if (!diag_rst_sync[1]) begin
        diag_red_code = 1'b1;
    end else if (diag_cpu_cfg_sync != 2'b11 && !diag_seen_rd) begin
        // fx68k (68000/68010) aktiv statt TG68K (68020): Rot -> Gruen -> Pause
        diag_red_code   = (diag_slot == 5'd0 || diag_slot == 5'd1);
        diag_green_code = (diag_slot == 5'd4 || diag_slot == 5'd5);
    end else if (!diag_seen_rd || diag_stage_sync != 3'd5) begin
        case (diag_stage_sync)
            3'd1: begin
                diag_blue_code = (diag_slot == 5'd0 || diag_slot == 5'd1);
            end
            3'd2: begin
                diag_blue_code = (diag_slot == 5'd0 || diag_slot == 5'd1);
                diag_red_code  = (diag_slot == 5'd4 || diag_slot == 5'd5);
            end
            3'd3: begin
                diag_blue_code  = (diag_slot == 5'd0 || diag_slot == 5'd1);
                diag_red_code   = (diag_slot == 5'd4 || diag_slot == 5'd5);
                diag_green_code = (diag_slot == 5'd8 || diag_slot == 5'd9);
            end
            3'd4: begin
                diag_blue_code  = (diag_slot == 5'd0 || diag_slot == 5'd1 || diag_slot == 5'd4 || diag_slot == 5'd5);
                diag_green_code = (diag_slot == 5'd8 || diag_slot == 5'd9);
            end
            default: begin
                diag_blue_code  = (diag_slot == 5'd0 || diag_slot == 5'd1 || diag_slot == 5'd4 || diag_slot == 5'd5 || diag_slot == 5'd8 || diag_slot == 5'd9);
                diag_green_code = (diag_slot == 5'd12 || diag_slot == 5'd13);
            end
        endcase
    end else if (diag_rd_active) begin
        diag_green_code = (diag_slot < 5'd10);
    end else begin
        diag_green_code = 1'b1;
    end
end

// Gruen (V13 hat keinen Vorwiderstand) auf 25% PWM dimmen, damit es nicht ueberstrahlt
wire diag_green_pwm = (diag_slot_cnt[15:14] == 2'b00);

wire diag_blue_on  = diag_blue_code;
wire diag_red_on   = diag_red_code;
wire diag_green_on = diag_green_code && diag_green_pwm;

// Tang Console 138K LED-Polaritaet (hardware-verifiziert):
// leds[0] (G11/Blau) & leds[1] (U12/Rot): Active-HIGH (1 = AN, 0 = AUS)
// leds[2] (V13/Gruen):                    Active-LOW  (0 = AN, 1 = AUS)
assign leds[0] = diag_blue_on;
assign leds[1] = diag_red_on;
assign leds[2] = !diag_green_on;

endmodule

// To match emacs with gw_ide default
// Local Variables:
// tab-width: 4
// End:
