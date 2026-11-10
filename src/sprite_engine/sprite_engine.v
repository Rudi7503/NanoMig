// ====================================================================
//
//  sprite_engine.v
//  NanoMig Sprite Engine Top-Level Controller (Revision 4.1 Specification)
//
//  Cyclone V FPGA Implementation for MiSTer / Minimig-AGA:
//    - Multi-Format Sprite & HighColor / TrueColor Overlay Engine
//    - 16-Byte Descriptor Fast-RAM List Traversal with Y-Sorting Contract
//    - Avalon-MM DDR3-BL8 Burst Master (256-Bit Bursts)
//    - 1-Cycle Hardware Zero-Word-Skip
//    - Dual Ping-Pong Line Buffer (2 x 2048 x 32-Bit) with Clear-on-Read
//    - Dedicated 256x24-Bit Palette RAM (Port A: CPU, Port B: Renderer)
//    - Universal 20-Format Decoder (CLUT 1..8, HAM, Direct, Pure Deltas)
//    - Q6 Hardware X-Scaler with Linear Interpolation & Box Filtering
//    - 4 Hardware Intra-Sprite Blend Modes (Opak, Additiv, 50/50, 8-Bit Alpha)
//    - 4 Denise Priority Layers (PRIO[7:6])
//
// ====================================================================

`timescale 1ns / 1ps

(* syn_noprune = 1 *)
module sprite_engine (
    // Clocks and reset
    input  wire        clk_render,       // 114.75 MHz Memory/Render Domain
    input  wire        clk_sys,          // 28.375 MHz Amiga Bus Domain
    input  wire        clk_vid,          // Video Dot Clock Domain
    input  wire        rst_n,

    // Amiga Custom Register Bus Interface ($DFF820..$DFF83E)
    input  wire        reg_cs,           // Active when address matches $DFF820..$DFF83E
    input  wire        reg_we,
    input  wire [3:0]  reg_addr,         // 0..15 (word offsets)
    input  wire [15:0] reg_wdata,
    output reg  [15:0] reg_rdata,

    // Video Timing Inputs from Agnus/Denise
    input  wire        vblank_pulse,     // Vertical Blank strobe
    input  wire        line_swap_pulse,  // Scanline boundary toggle strobe
    input  wire signed [11:0] scanline_y,// Current scanline to render (-2048..+2047)
    input  wire [10:0] vid_x,            // Current video dot X coordinate (0..2047)
    input  wire        vid_read_en,      // Video active fetch
    input  wire [10:0] clip_xmax,        // Active line width limit

    // Denise Native Video Tap
    input  wire [23:0] amiga_rgb,
    input  wire        sprsel_aligned,
    input  wire        pf_front_opaque,
    input  wire        pf_any_opaque,
    input  wire        blank_n,

    // Avalon-MM DDR3 Memory Master Interface
    output wire [31:0] avm_address,
    output wire [3:0]  avm_burstcount,
    output wire        avm_read,
    input  wire        avm_waitrequest,
    input  wire [63:0] avm_readdata,
    input  wire        avm_readdatavalid,

    // Final Composited Video Output
    output wire [23:0] out_rgb
);

    // ----------------------------------------------------------------
    // Register Bus Decoding & Palette Interface
    // ----------------------------------------------------------------
    wire dma_reg_we = reg_cs && reg_we && (reg_addr <= 4'd2);
    reg  pal_reg_we;

    reg [7:0]  pal_write_addr;
    reg [23:0] pal_write_data;

    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            pal_write_addr <= 8'h00;
            pal_write_data <= 24'h000000;
            pal_reg_we     <= 1'b0;
        end else begin
            pal_reg_we <= 1'b0;
            if (reg_cs && reg_we) begin
                if (reg_addr == 4'd3) begin
                    pal_write_addr <= reg_wdata[7:0];
                end else if (reg_addr == 4'd4) begin
                    pal_write_data[23:16] <= reg_wdata[7:0];
                end else if (reg_addr == 4'd5) begin
                    pal_write_data[15:0] <= reg_wdata;
                    pal_reg_we <= 1'b1;
                    pal_write_addr <= pal_write_addr + 8'd1;
                end
            end
        end
    end

    wire [15:0] dma_reg_rdata;
    always @(*) begin
        case (reg_addr)
            4'd0: reg_rdata = dma_reg_rdata;
            4'd1: reg_rdata = dma_reg_rdata;
            4'd2: reg_rdata = dma_reg_rdata;
            4'd3: reg_rdata = {8'h00, pal_write_addr};
            4'd4: reg_rdata = {8'h00, pal_qa[23:16]};
            4'd5: reg_rdata = pal_qa[15:0];
            default: reg_rdata = 16'h0000;
        endcase
    end

    // ----------------------------------------------------------------
    // Submodule 1: Dedicated Banked Sprite Palette (256 x 24)
    // ----------------------------------------------------------------
    wire [7:0]  dec_pal_addr;
    wire [23:0] dec_pal_data;
    wire [23:0] pal_qa;

    sprite_engine_palette u_palette (
        .clk_a   (clk_sys),
        .we_a    (pal_reg_we),
        .addr_a  (pal_write_addr),
        .data_a  (pal_write_data),
        .q_a     (pal_qa),

        .clk_b   (clk_render),
        .addr_b  (dec_pal_addr),
        .q_b     (dec_pal_data)
    );

    // ----------------------------------------------------------------
    // Submodule 2: DMA Descriptor Scanner & DDR3 Burst Master
    // ----------------------------------------------------------------
    wire        sprite_active;
    wire signed [11:0] spr_x;
    wire [4:0]  spr_fmt;
    wire [7:0]  spr_prio;
    wire [7:0]  spr_alpha;
    wire [1:0]  spr_blend_mode;
    wire [7:0]  spr_x_scale;
    wire        spr_smooth;
    wire        spr_h_flip;
    wire [10:0] spr_w_px;
    wire        spr_start_line;

    wire [63:0] stream_word64;
    wire        stream_valid;
    wire        stream_ack;
    wire        line_done;

    sprite_engine_dma u_dma (
        .clk               (clk_render),
        .rst_n             (rst_n),

        .reg_we            (dma_reg_we),
        .reg_addr          (reg_addr),
        .reg_wdata         (reg_wdata),
        .reg_rdata         (dma_reg_rdata),

        .vblank_pulse      (vblank_pulse),
        .start_line        (line_swap_pulse),
        .cur_y             (scanline_y),

        .avm_address       (avm_address),
        .avm_burstcount    (avm_burstcount),
        .avm_read          (avm_read),
        .avm_waitrequest   (avm_waitrequest),
        .avm_readdata      (avm_readdata),
        .avm_readdatavalid (avm_readdatavalid),

        .sprite_active     (sprite_active),
        .spr_x             (spr_x),
        .spr_fmt           (spr_fmt),
        .spr_prio          (spr_prio),
        .spr_alpha         (spr_alpha),
        .spr_blend_mode    (spr_blend_mode),
        .spr_x_scale       (spr_x_scale),
        .spr_smooth        (spr_smooth),
        .spr_h_flip        (spr_h_flip),
        .spr_w_px          (spr_w_px),
        .spr_start_line    (spr_start_line),

        .stream_word64     (stream_word64),
        .stream_valid      (stream_valid),
        .stream_ack        (stream_ack),
        .line_done         (line_done)
    );

    // ----------------------------------------------------------------
    // Submodule 3: Universal Multi-Format Pipelined Decoder
    // ----------------------------------------------------------------
    wire [7:0] dec_r;
    wire [7:0] dec_g;
    wire [7:0] dec_b;
    wire [7:0] dec_alpha;
    wire       dec_opaque;

    (* syn_noprune = 1 *) sprite_engine_decoder u_decoder (
        .clk        (clk_render),
        .rst_n      (rst_n),

        .clr_acc    (spr_start_line),
        .fmt        (spr_fmt),
        .bw         (6'd8), // Default 8-bit stream word width
        .raw_code   (stream_word64[31:0]),
        .pal_offset (spr_alpha),
        .desc_alpha (spr_alpha),

        .pal_addr   (dec_pal_addr),
        .pal_data   (dec_pal_data),

        .out_r      (dec_r),
        .out_g      (dec_g),
        .out_b      (dec_b),
        .out_alpha  (dec_alpha),
        .out_opaque (dec_opaque)
    );

    // Decoder stream ack handshake
    assign stream_ack = 1'b1;

    // ----------------------------------------------------------------
    // Submodule 4: Q6 Hardware Scaler
    // ----------------------------------------------------------------
    wire        scale_dst_valid;
    wire [10:0] scale_dst_x;
    wire [7:0]  scale_dst_r;
    wire [7:0]  scale_dst_g;
    wire [7:0]  scale_dst_b;
    wire [7:0]  scale_dst_alpha;
    wire        scale_dst_opaque;
    wire        scale_src_ack;

    sprite_engine_scaler u_scaler (
        .clk        (clk_render),
        .rst_n      (rst_n),

        .start_line (spr_start_line),
        .x_pos      (spr_x),
        .x_scale    (spr_x_scale),
        .smooth_en  (spr_smooth),
        .h_flip     (spr_h_flip),
        .orig_w_px  (spr_w_px),

        .src_valid  (stream_valid),
        .src_r      (dec_r),
        .src_g      (dec_g),
        .src_b      (dec_b),
        .src_alpha  (dec_alpha),
        .src_opaque (dec_opaque),
        .src_ack    (scale_src_ack),

        .dst_valid  (scale_dst_valid),
        .dst_x      (scale_dst_x),
        .dst_r      (scale_dst_r),
        .dst_g      (scale_dst_g),
        .dst_b      (scale_dst_b),
        .dst_alpha  (scale_dst_alpha),
        .dst_opaque (scale_dst_opaque)
    );

    // ----------------------------------------------------------------
    // Submodule 5: Hardware Alpha-Blender
    // ----------------------------------------------------------------
    wire [7:0]  blend_out_r;
    wire [7:0]  blend_out_g;
    wire [7:0]  blend_out_b;
    wire [7:0]  blend_out_prio;
    wire        blend_out_we;

    wire [7:0]  eff_old_prio;
    wire [23:0] eff_old_rgb;

    (* syn_noprune = 1 *) sprite_engine_blender u_blender (
        .blend_mode (spr_blend_mode),
        .src_alpha  (scale_dst_alpha),
        .src_r      (scale_dst_r),
        .src_g      (scale_dst_g),
        .src_b      (scale_dst_b),
        .src_prio   (spr_prio),
        .src_opaque (scale_dst_opaque && scale_dst_valid),

        .dst_r      (eff_old_rgb[23:16]),
        .dst_g      (eff_old_rgb[15:8]),
        .dst_b      (eff_old_rgb[7:0]),
        .dst_prio   (eff_old_prio),

        .out_r      (blend_out_r),
        .out_g      (blend_out_g),
        .out_b      (blend_out_b),
        .out_prio   (blend_out_prio),
        .out_we     (blend_out_we)
    );

    // ----------------------------------------------------------------
    // Submodule 6: Dual Ping-Pong Line Buffer (2 x 2048 x 32)
    // ----------------------------------------------------------------
    wire        render_ready;
    wire [7:0]  vid_prio;
    wire [23:0] vid_rgb;

    (* syn_noprune = 1 *) sprite_engine_linebuf u_linebuf (
        .rst_n           (rst_n),

        .clk_render      (clk_render),
        .line_swap_pulse (line_swap_pulse),
        .clip_xmax       (clip_xmax),

        .wr_en           (blend_out_we),
        .wr_x            (scale_dst_x),
        .wr_prio         (blend_out_prio),
        .wr_rgb          ({blend_out_r, blend_out_g, blend_out_b}),

        .rd_render_x     (scale_dst_x),
        .eff_old_prio    (eff_old_prio),
        .eff_old_rgb     (eff_old_rgb),

        .render_ready    (render_ready),

        .clk_vid         (clk_vid),
        .vid_x           (eff_vid_x),
        .vid_read_en     (eff_vid_read_en),
        .vid_prio        (vid_prio),
        .vid_rgb         (vid_rgb)
    );

    // Auto vid_x horizontal pixel counter when external vid_x is unattached
    reg [10:0] vid_x_counter;
    wire [10:0] eff_vid_x = (|vid_x) ? vid_x : vid_x_counter;
    wire eff_vid_read_en  = vid_read_en | blank_n;

    always @(posedge clk_vid or negedge rst_n) begin
        if (!rst_n) begin
            vid_x_counter <= 11'd0;
        end else if (line_swap_pulse) begin
            vid_x_counter <= 11'd0;
        end else if (eff_vid_read_en) begin
            vid_x_counter <= vid_x_counter + 11'd1;
        end
    end

    // ----------------------------------------------------------------
    // Submodule 7: Denise Video Output Compositor
    // ----------------------------------------------------------------
    sprite_engine_compositor u_compositor (
        .clk              (clk_vid),
        .rst_n            (rst_n),

        .amiga_rgb        (amiga_rgb),
        .sprsel_aligned   (sprsel_aligned),
        .pf_front_opaque  (pf_front_opaque),
        .pf_any_opaque    (pf_any_opaque),
        .blank_n          (blank_n),

        .sprite_rgb       (vid_rgb),
        .sprite_prio      (vid_prio),
        .sprite_engine_en (1'b1),

        .out_rgb          (out_rgb)
    );

endmodule
