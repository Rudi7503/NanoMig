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
//    - 64-Bit Big-Endian Sub-Pixel Stream Unpacker (CLUT1..8, RGB565, ARGB32, HAM)
//    - Dual Ping-Pong Line Buffer (2 x 2048 x 32-Bit) with Clear-on-Read
//    - Dedicated 256x24-Bit Palette RAM (Port A: CPU, Port B: Renderer)
//    - Universal 20-Format Decoder (CLUT 1..8, HAM, Direct, Pure Deltas)
//    - Q6 Hardware X-Scaler with Linear Interpolation & Box Filtering
//    - 4 Hardware Intra-Sprite Blend Modes (Opak, Additiv, 50/50, 8-Bit Alpha)
//    - 4 Denise Priority Layers (PRIO[7:6])
//    - 2-Cycle Video Delay Pipeline for Denise / Sprite Pixel Alignment
//    - 2048 x 24-Bit Diagnostic Scanline Raw Pixel Capture Buffer
//
// ====================================================================

`timescale 1ns / 1ps

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
    wire dma_engine_en;
    wire dma_cap_en;
    wire [3:0] dma_addr_mux = (reg_addr == 4'd6) ? 4'd3 : reg_addr;
    wire dma_reg_we = reg_cs && reg_we && (reg_addr <= 4'd2);
    reg  pal_reg_we;

    reg [7:0]  pal_write_addr;
    reg [7:0]  pal_commit_addr;
    reg [23:0] pal_write_data;

    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            pal_write_addr  <= 8'h00;
            pal_commit_addr <= 8'h00;
            pal_write_data  <= 24'h000000;
            pal_reg_we      <= 1'b0;
        end else begin
            pal_reg_we <= 1'b0;
            if (reg_cs && reg_we) begin
                if (reg_addr == 4'd3) begin
                    pal_write_addr  <= reg_wdata[7:0];
                    pal_commit_addr <= reg_wdata[7:0];
                end else if (reg_addr == 4'd4) begin
                    pal_write_data[23:16] <= reg_wdata[7:0];
                end else if (reg_addr == 4'd5) begin
                    pal_write_data[15:0] <= reg_wdata;
                    pal_commit_addr      <= pal_write_addr;
                    pal_reg_we           <= 1'b1;
                    pal_write_addr       <= pal_write_addr + 8'd1;
                end
            end
        end
    end

    wire [15:0] dma_reg_rdata;
    wire [15:0] cap_reg_rdata;
    wire        cap_done;

    always @(*) begin
        case (reg_addr)
            4'd0: reg_rdata = dma_reg_rdata;          // PTR_H
            4'd1: reg_rdata = dma_reg_rdata;          // PTR_L
            4'd2: reg_rdata = dma_reg_rdata;          // CTRL
            4'd3: reg_rdata = {8'h00, pal_write_addr};
            4'd4: reg_rdata = {8'h00, pal_qa[23:16]};
            4'd5: reg_rdata = pal_qa[15:0];
            4'd6: reg_rdata = dma_reg_rdata;          // STATUS (line_done)
            4'd7: reg_rdata = 16'h0000;
            4'd8: reg_rdata = 16'h0000;
            4'd9, 4'd10, 4'd11, 4'd12: reg_rdata = cap_reg_rdata;
            4'd13: reg_rdata = {15'd0, cap_done};
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
        .addr_a  (pal_commit_addr),
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
        .reg_addr          (dma_addr_mux),
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
        .line_done         (line_done),
        .engine_en_out     (dma_engine_en),
        .cap_en_out        (dma_cap_en)
    );

    // ----------------------------------------------------------------
    // Submodule 2b: 64-Bit Burst FIFO & Pixel Unpacker Shift Register
    // ----------------------------------------------------------------
    reg [63:0] burst_fifo [0:7];
    reg [2:0]  fifo_wr_ptr;
    reg [2:0]  fifo_rd_ptr;
    reg [3:0]  fifo_count;

    reg [2:0]  sub_px_cnt;

    always @(posedge clk_render or negedge rst_n) begin
        if (!rst_n) begin
            sub_px_cnt <= 3'd0;
        end else if (spr_start_line) begin
            sub_px_cnt <= 3'd0;
        end else if (scale_src_ack) begin
            case (spr_fmt)
                5'd9:  sub_px_cnt <= (sub_px_cnt == 3'd3) ? 3'd0 : (sub_px_cnt + 3'd1);
                5'd11, 5'd18: sub_px_cnt <= (sub_px_cnt == 3'd3) ? 3'd0 : (sub_px_cnt + 3'd1);
                5'd12, 5'd17: sub_px_cnt <= (sub_px_cnt == 3'd4) ? 3'd0 : (sub_px_cnt + 3'd1);
                5'd13: sub_px_cnt <= (sub_px_cnt == 3'd4) ? 3'd0 : (sub_px_cnt + 3'd1);
                default: sub_px_cnt <= 3'd0;
            endcase
        end
    end

    reg [63:0] shreg_data;
    reg [6:0]  shreg_bits;
    reg [5:0]  dec_bw;
    reg [31:0] dec_raw_code;
    reg        dec_in_valid;
    wire       scale_src_ack;

    always @(*) begin
        case (spr_fmt)
            5'd0:    dec_bw = 6'd1;  // 1-bit CLUT
            5'd1:    dec_bw = 6'd2;  // 2-bit CLUT
            5'd2:    dec_bw = 6'd3;  // 3-bit CLUT
            5'd3:    dec_bw = 6'd4;  // 4-bit CLUT
            5'd4:    dec_bw = 6'd5;  // 5-bit CLUT
            5'd5:    dec_bw = 6'd6;  // 6-bit CLUT
            5'd6:    dec_bw = 6'd7;  // 7-bit CLUT
            5'd7:    dec_bw = 6'd8;  // 8-bit CLUT
            5'd8:    dec_bw = 6'd4;  // HAM04
            5'd9: begin              // HAM06: 6, 3, 4, 3
                case (sub_px_cnt[1:0])
                    2'd0: dec_bw = 6'd6;
                    2'd1: dec_bw = 6'd3;
                    2'd2: dec_bw = 6'd4;
                    2'd3: dec_bw = 6'd3;
                endcase
            end
            5'd10:   dec_bw = 6'd8;  // HAM08
            5'd11, 5'd18: begin      // HAM12 12_686: 12, 6, 8, 6
                case (sub_px_cnt[1:0])
                    2'd0: dec_bw = 6'd12;
                    2'd1: dec_bw = 6'd6;
                    2'd2: dec_bw = 6'd8;
                    2'd3: dec_bw = 6'd6;
                endcase
            end
            5'd12, 5'd17: begin      // HAM12 12_5555: 12, 5, 5, 5, 5
                dec_bw = (sub_px_cnt == 3'd0) ? 6'd12 : 6'd5;
            end
            5'd13: begin             // HAM16 12x4: 16, 12, 12, 12, 12
                dec_bw = (sub_px_cnt == 3'd0) ? 6'd16 : 6'd12;
            end
            5'd14:   dec_bw = 6'd16; // HAM16 Direct
            5'd15:   dec_bw = 6'd16; // RGB16 (RGB565)
            5'd16:   dec_bw = 6'd32; // ARGB32
            5'd19:   dec_bw = 6'd8;  // HAM08_D
            default: dec_bw = 6'd8;  // HAM / default 8-bit
        endcase
    end

    // DMA flow control: accept next burst when FIFO has room for at least 4 beats
    assign stream_ack = (fifo_count <= 4'd4) || spr_start_line;

    wire fifo_push = stream_valid;
    wire fifo_pop  = (shreg_bits < {1'b0, dec_bw}) && (fifo_count > 4'd0);

    always @(posedge clk_render or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wr_ptr  <= 3'd0;
            fifo_rd_ptr  <= 3'd0;
            fifo_count   <= 4'd0;
            shreg_data   <= 64'd0;
            shreg_bits   <= 7'd0;
            dec_raw_code <= 32'd0;
            dec_in_valid <= 1'b0;
        end else if (spr_start_line) begin
            fifo_wr_ptr  <= 3'd0;
            fifo_rd_ptr  <= 3'd0;
            fifo_count   <= 4'd0;
            shreg_data   <= 64'd0;
            shreg_bits   <= 7'd0;
            dec_raw_code <= 32'd0;
            dec_in_valid <= 1'b0;
        end else begin
            dec_in_valid <= 1'b0;

            // FIFO write
            if (fifo_push) begin
                burst_fifo[fifo_wr_ptr] <= stream_word64;
                fifo_wr_ptr <= fifo_wr_ptr + 3'd1;
            end

            // FIFO count tracking
            case ({fifo_push, fifo_pop})
                2'b10:   fifo_count <= fifo_count + 4'd1;
                2'b01:   fifo_count <= fifo_count - 4'd1;
                default: fifo_count <= fifo_count;
            endcase

            // Pixel unpacker shift register
            if (shreg_bits >= {1'b0, dec_bw}) begin
                if (scale_src_ack) begin
                    case (dec_bw)
                        6'd1:  dec_raw_code <= {31'd0, shreg_data[63]};
                        6'd2:  dec_raw_code <= {30'd0, shreg_data[63:62]};
                        6'd3:  dec_raw_code <= {29'd0, shreg_data[63:61]};
                        6'd4:  dec_raw_code <= {28'd0, shreg_data[63:60]};
                        6'd5:  dec_raw_code <= {27'd0, shreg_data[63:59]};
                        6'd6:  dec_raw_code <= {26'd0, shreg_data[63:58]};
                        6'd7:  dec_raw_code <= {25'd0, shreg_data[63:57]};
                        6'd8:  dec_raw_code <= {24'd0, shreg_data[63:56]};
                        6'd16: dec_raw_code <= {16'd0, shreg_data[63:48]};
                        6'd32: dec_raw_code <= shreg_data[63:32];
                        default: dec_raw_code <= {24'd0, shreg_data[63:56]};
                    endcase
                    dec_in_valid <= 1'b1;
                    shreg_data   <= shreg_data << dec_bw;
                    shreg_bits   <= shreg_bits - {1'b0, dec_bw};
                end
            end else if (fifo_pop) begin
                shreg_data  <= burst_fifo[fifo_rd_ptr];
                shreg_bits  <= 7'd64;
                fifo_rd_ptr <= fifo_rd_ptr + 3'd1;
            end
        end
    end

    // ----------------------------------------------------------------
    // Submodule 3: Universal Multi-Format Pipelined Decoder
    // ----------------------------------------------------------------
    wire       dec_out_valid;
    wire [7:0] dec_r;
    wire [7:0] dec_g;
    wire [7:0] dec_b;
    wire [7:0] dec_alpha;
    wire       dec_opaque;

    sprite_engine_decoder u_decoder (
        .clk        (clk_render),
        .rst_n      (rst_n),

        .in_valid   (dec_in_valid),
        .clr_acc    (spr_start_line),
        .fmt        (spr_fmt),
        .bw         (dec_bw),
        .raw_code   (dec_raw_code),
        .pal_offset (8'h00),
        .desc_alpha (spr_alpha),

        .pal_addr   (dec_pal_addr),
        .pal_data   (dec_pal_data),

        .out_valid  (dec_out_valid),
        .out_r      (dec_r),
        .out_g      (dec_g),
        .out_b      (dec_b),
        .out_alpha  (dec_alpha),
        .out_opaque (dec_opaque)
    );

    // 2-Cycle Read-Modify-Write Pipeline for Blend Modes (Additive, 50/50, Alpha)
    wire is_blend = (spr_blend_mode != 2'b00);
    reg  rmw_phase;

    always @(posedge clk_render or negedge rst_n) begin
        if (!rst_n) begin
            rmw_phase <= 1'b0;
        end else if (spr_start_line) begin
            rmw_phase <= 1'b0;
        end else if (is_blend && scale_dst_valid) begin
            rmw_phase <= ~rmw_phase;
        end else begin
            rmw_phase <= 1'b0;
        end
    end

    wire scale_step_en = !is_blend || (rmw_phase == 1'b1) || !scale_dst_valid;
    wire render_wr_en  = scale_dst_valid && blend_out_we && (!is_blend || rmw_phase == 1'b1);

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

    sprite_engine_scaler u_scaler (
        .clk        (clk_render),
        .rst_n      (rst_n),

        .start_line (spr_start_line),
        .step_en    (scale_step_en),
        .x_pos      (spr_x),
        .x_scale    (spr_x_scale),
        .smooth_en  (spr_smooth),
        .h_flip     (spr_h_flip),
        .orig_w_px  (spr_w_px),

        .src_valid  (dec_out_valid),
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

    sprite_engine_blender u_blender (
        .blend_mode   (spr_blend_mode),
        .src_alpha    (scale_dst_alpha),
        .src_r        (scale_dst_r),
        .src_g        (scale_dst_g),
        .src_b        (scale_dst_b),
        .src_prio     (spr_prio),
        .src_opaque   (scale_dst_opaque),

        .dst_r        (eff_old_rgb[23:16]),
        .dst_g        (eff_old_rgb[15:8]),
        .dst_b        (eff_old_rgb[7:0]),
        .dst_prio     (eff_old_prio),

        .out_r        (blend_out_r),
        .out_g        (blend_out_g),
        .out_b        (blend_out_b),
        .out_prio     (blend_out_prio),
        .out_we       (blend_out_we)
    );

    // ----------------------------------------------------------------
    // Submodule 6: Dual Ping-Pong Scanline Buffer
    // ----------------------------------------------------------------
    wire        render_ready;
    wire [7:0]  vid_prio;
    wire [23:0] vid_rgb;

    reg [10:0] vid_x_counter;
    wire [10:0] eff_vid_x = (vid_x != 11'd0) ? vid_x : vid_x_counter;
    wire        eff_vid_read_en = vid_read_en;

    always @(posedge clk_vid or negedge rst_n) begin
        if (!rst_n) begin
            vid_x_counter <= 11'd0;
        end else if (line_swap_pulse) begin
            vid_x_counter <= 11'd0;
        end else if (eff_vid_read_en) begin
            vid_x_counter <= vid_x_counter + 11'd1;
        end
    end

    sprite_engine_linebuf u_linebuf (
        .rst_n           (rst_n),

        // Render Write Domain (clk_render)
        .clk_render      (clk_render),
        .line_swap_pulse (line_swap_pulse),
        .clip_xmax       (clip_xmax),

        .wr_en           (render_wr_en),
        .wr_x            (scale_dst_x),
        .wr_prio         (blend_out_prio),
        .wr_rgb          ({blend_out_r, blend_out_g, blend_out_b}),

        .rd_render_x     (scale_dst_x),
        .eff_old_prio    (eff_old_prio),
        .eff_old_rgb     (eff_old_rgb),
        .render_ready    (render_ready),

        // Video Read Domain (clk_vid)
        .clk_vid         (clk_vid),
        .vid_x           (eff_vid_x),
        .vid_read_en     (eff_vid_read_en),
        .vid_prio        (vid_prio),
        .vid_rgb         (vid_rgb)
    );

    // ----------------------------------------------------------------
    // 2-Cycle Pipeline Delay for Denise Video & Occlusion Tap
    // ----------------------------------------------------------------
    reg [23:0] amiga_rgb_d1, amiga_rgb_d2;
    reg        sprsel_d1, sprsel_d2;
    reg        pf_front_d1, pf_front_d2;
    reg        pf_any_d1, pf_any_d2;

    always @(posedge clk_vid or negedge rst_n) begin
        if (!rst_n) begin
            amiga_rgb_d1 <= 24'h000000;
            amiga_rgb_d2 <= 24'h000000;
            sprsel_d1    <= 1'b0;
            sprsel_d2    <= 1'b0;
            pf_front_d1  <= 1'b0;
            pf_front_d2  <= 1'b0;
            pf_any_d1    <= 1'b0;
            pf_any_d2    <= 1'b0;
        end else begin
            amiga_rgb_d1 <= amiga_rgb;
            amiga_rgb_d2 <= amiga_rgb_d1;
            sprsel_d1    <= sprsel_aligned;
            sprsel_d2    <= sprsel_d1;
            pf_front_d1  <= pf_front_opaque;
            pf_front_d2  <= pf_front_d1;
            pf_any_d1    <= pf_any_opaque;
            pf_any_d2    <= pf_any_d1;
        end
    end

    // ----------------------------------------------------------------
    // Submodule 7: Denise Video Output Compositor
    // ----------------------------------------------------------------
    wire [23:0] comp_out_rgb;

    sprite_engine_compositor u_compositor (
        .clk              (clk_vid),
        .rst_n            (rst_n),

        .amiga_rgb        (amiga_rgb_d2),
        .sprsel_aligned   (sprsel_d2),
        .pf_front_opaque  (pf_front_d2),
        .pf_any_opaque    (pf_any_d2),
        .blank_n          (blank_n),

        .sprite_rgb       (vid_rgb),
        .sprite_prio      (vid_prio),
        .sprite_engine_en (dma_engine_en),

        .out_rgb          (comp_out_rgb)
    );

    // ----------------------------------------------------------------
    // Submodule 8: Diagnostic Scanline Raw Pixel Capture Buffer
    // ----------------------------------------------------------------
    wire signed [11:0] cap_target_line;

    // 3-Cycle Pipeline Delay for Scanline Capture alignment with comp_out_rgb
    reg [10:0] cap_x_d1, cap_x_d2, cap_x_d3;
    reg        cap_read_en_d1, cap_read_en_d2, cap_read_en_d3;

    always @(posedge clk_vid or negedge rst_n) begin
        if (!rst_n) begin
            cap_x_d1       <= 11'd0;
            cap_x_d2       <= 11'd0;
            cap_x_d3       <= 11'd0;
            cap_read_en_d1 <= 1'b0;
            cap_read_en_d2 <= 1'b0;
            cap_read_en_d3 <= 1'b0;
        end else begin
            cap_x_d1       <= eff_vid_x;
            cap_x_d2       <= cap_x_d1;
            cap_x_d3       <= cap_x_d2;
            cap_read_en_d1 <= eff_vid_read_en;
            cap_read_en_d2 <= cap_read_en_d1;
            cap_read_en_d3 <= cap_read_en_d2;
        end
    end

    sprite_engine_capture u_capture (
        .rst_n           (rst_n),

        // Video Write Domain (clk_vid)
        .clk_vid         (clk_vid),
        .capture_en      (dma_cap_en),
        .cur_y           (scanline_y),
        .cap_y           (cap_target_line),
        .vid_x           (cap_x_d3),
        .vid_read_en     (cap_read_en_d3),
        .out_rgb         (comp_out_rgb),
        .cap_done        (cap_done),

        // CPU Read Domain (clk_sys)
        .clk_sys         (clk_sys),
        .reg_cs          (reg_cs),
        .reg_we          (reg_we),
        .reg_addr        (reg_addr),
        .reg_wdata       (reg_wdata),
        .reg_rdata       (cap_reg_rdata),
        .cap_target_line (cap_target_line)
    );

    assign out_rgb = comp_out_rgb;

endmodule
