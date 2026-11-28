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
    reg  pal_reg_we;

    reg [7:0]  pal_write_addr;
    reg [7:0]  pal_commit_addr;
    reg [23:0] pal_write_data;
    reg        reg_wr_d;
    wire       reg_wr_now   = reg_cs && reg_we;
    wire       reg_wr_pulse = reg_wr_now && !reg_wr_d;

    // CDC from clk_sys (28.57 MHz) -> clk_render (85.59 MHz) for DMA registers & video strobes
    reg [3:0]  dma_wr_addr_sys;
    reg [15:0] dma_wr_data_sys;
    reg        dma_wr_tgl_sys;
    (* syn_preserve = 1 *) reg dma_wr_s1, dma_wr_s2;
    reg        dma_wr_s3;
    (* syn_preserve = 1 *) reg vbl_s1, vbl_s2;
    reg        vbl_s3;
    (* syn_preserve = 1 *) reg sol_s1, sol_s2;
    reg        sol_s3, sol_s4;
    reg signed [11:0] scanline_y_latched_sys;
    reg signed [11:0] scanline_y_r1, scanline_y_r2;

    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            pal_write_addr         <= 8'h00;
            pal_commit_addr        <= 8'h00;
            pal_write_data         <= 24'h000000;
            pal_reg_we             <= 1'b0;
            reg_wr_d               <= 1'b0;
            dma_wr_addr_sys        <= 4'd0;
            dma_wr_data_sys        <= 16'd0;
            dma_wr_tgl_sys         <= 1'b0;
            scanline_y_latched_sys <= 12'sd0;
        end else begin
            reg_wr_d   <= reg_wr_now;
            pal_reg_we <= 1'b0;
            if (line_swap_pulse)
                scanline_y_latched_sys <= scanline_y;
            if (reg_wr_pulse) begin
                if (reg_addr <= 4'd2) begin
                    dma_wr_addr_sys <= reg_addr;
                    dma_wr_data_sys <= reg_wdata;
                    dma_wr_tgl_sys  <= ~dma_wr_tgl_sys;
                end else if (reg_addr == 4'd3) begin
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

    always @(posedge clk_render or negedge rst_n) begin
        if (!rst_n) begin
            dma_wr_s1     <= 1'b0;
            dma_wr_s2     <= 1'b0;
            dma_wr_s3     <= 1'b0;
            vbl_s1        <= 1'b0;
            vbl_s2        <= 1'b0;
            vbl_s3        <= 1'b0;
            sol_s1        <= 1'b0;
            sol_s2        <= 1'b0;
            sol_s3        <= 1'b0;
            sol_s4        <= 1'b0;
            scanline_y_r1 <= 12'sd0;
            scanline_y_r2 <= 12'sd0;
        end else begin
            dma_wr_s1     <= dma_wr_tgl_sys;
            dma_wr_s2     <= dma_wr_s1;
            dma_wr_s3     <= dma_wr_s2;
            vbl_s1        <= vblank_pulse;
            vbl_s2        <= vbl_s1;
            vbl_s3        <= vbl_s2;
            sol_s1        <= line_swap_pulse;
            sol_s2        <= sol_s1;
            sol_s3        <= sol_s2;
            sol_s4        <= sol_s3;
            scanline_y_r1 <= scanline_y_latched_sys;
            scanline_y_r2 <= scanline_y_r1;
        end
    end

    wire dma_reg_we_render = (dma_wr_s2 != dma_wr_s3);
    wire vbl_render        = vbl_s2 && !vbl_s3;
    wire sol_render        = sol_s3 && !sol_s4;

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
    wire signed [15:0] spr_x;
    wire [4:0]  spr_fmt;
    wire [7:0]  spr_prio;
    wire [7:0]  spr_alpha;
    wire [1:0]  spr_blend_mode;
    wire [8:0]  spr_x_scale;
    wire        spr_smooth;
    wire        spr_h_flip;
    wire [14:0] spr_w_px;
    wire        spr_start_line;

    wire [63:0] stream_word64;
    wire        stream_valid;
    wire        stream_ack;
    wire        line_done;

    sprite_engine_dma u_dma (
        .clk               (clk_render),
        .rst_n             (rst_n),

        .reg_we            (dma_reg_we_render),
        .reg_addr          (dma_reg_we_render ? dma_wr_addr_sys : dma_addr_mux),
        .reg_wdata         (dma_wr_data_sys),
        .reg_rdata         (dma_reg_rdata),

        .vblank_pulse      (vbl_render),
        .start_line        (sol_render),
        .cur_y             (scanline_y_r2),

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
        .render_ready      (render_ready),
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

    // 5-Cycle Read-Modify-Write Pipeline for Blend Modes (breaks DOA -> diff -> DSP -> DIA at 85.6 MHz)
    wire is_blend = (spr_blend_mode != 2'b00);
    reg [2:0]  rmw_phase;
    reg [23:0] old_rgb_r;
    reg [7:0]  old_prio_r;
    reg signed [16:0] blend_prod_r_r, blend_prod_g_r, blend_prod_b_r;
    reg [15:0] blend_pempty_r_r, blend_pempty_g_r, blend_pempty_b_r;
    reg [8:0]  blend_add_r_r, blend_add_g_r, blend_add_b_r;
    reg        blend_reg_we;
    reg [7:0]  blend_reg_prio;
    reg [23:0] blend_reg_rgb;

    wire [7:0] old_r_w = old_rgb_r[23:16];
    wire [7:0] old_g_w = old_rgb_r[15:8];
    wire [7:0] old_b_w = old_rgb_r[7:0];

    wire signed [8:0] diff_r_w = $signed({1'b0, scale_dst_r}) - $signed({1'b0, old_r_w});
    wire signed [8:0] diff_g_w = $signed({1'b0, scale_dst_g}) - $signed({1'b0, old_g_w});
    wire signed [8:0] diff_b_w = $signed({1'b0, scale_dst_b}) - $signed({1'b0, old_b_w});

    wire signed [16:0] prod_r_w = diff_r_w * $signed({1'b0, scale_dst_alpha});
    wire signed [16:0] prod_g_w = diff_g_w * $signed({1'b0, scale_dst_alpha});
    wire signed [16:0] prod_b_w = diff_b_w * $signed({1'b0, scale_dst_alpha});

    wire [15:0] pempty_r_w = scale_dst_r * scale_dst_alpha;
    wire [15:0] pempty_g_w = scale_dst_g * scale_dst_alpha;
    wire [15:0] pempty_b_w = scale_dst_b * scale_dst_alpha;

    wire [8:0] add_r_w = {1'b0, scale_dst_r} + {1'b0, old_r_w};
    wire [8:0] add_g_w = {1'b0, scale_dst_g} + {1'b0, old_g_w};
    wire [8:0] add_b_w = {1'b0, scale_dst_b} + {1'b0, old_b_w};

    wire [8:0] alpha_dest_r_w = $signed({1'b0, old_r_w}) + (blend_prod_r_r >>> 8);
    wire [8:0] alpha_dest_g_w = $signed({1'b0, old_g_w}) + (blend_prod_g_r >>> 8);
    wire [8:0] alpha_dest_b_w = $signed({1'b0, old_b_w}) + (blend_prod_b_r >>> 8);

    reg        blend_comb_we;
    reg [7:0]  blend_comb_prio;
    reg [7:0]  blend_comb_r, blend_comb_g, blend_comb_b;

    always @(*) begin
        if (!scale_dst_opaque) begin
            blend_comb_we   = 1'b0;
            blend_comb_prio = 8'h00;
            blend_comb_r    = 8'h00;
            blend_comb_g    = 8'h00;
            blend_comb_b    = 8'h00;
        end else begin
            case (spr_blend_mode)
                2'b00: begin
                    blend_comb_we   = 1'b1;
                    blend_comb_prio = spr_prio;
                    blend_comb_r    = scale_dst_r;
                    blend_comb_g    = scale_dst_g;
                    blend_comb_b    = scale_dst_b;
                end
                2'b01: begin
                    blend_comb_we   = 1'b1;
                    blend_comb_prio = (old_prio_r != 8'h00) ? ((spr_prio > old_prio_r) ? spr_prio : old_prio_r) : spr_prio;
                    if (old_prio_r == 8'h00) begin
                        blend_comb_r = scale_dst_r;
                        blend_comb_g = scale_dst_g;
                        blend_comb_b = scale_dst_b;
                    end else begin
                        blend_comb_r = blend_add_r_r[8] ? 8'hFF : blend_add_r_r[7:0];
                        blend_comb_g = blend_add_g_r[8] ? 8'hFF : blend_add_g_r[7:0];
                        blend_comb_b = blend_add_b_r[8] ? 8'hFF : blend_add_b_r[7:0];
                    end
                end
                2'b10: begin
                    blend_comb_we   = 1'b1;
                    blend_comb_prio = (old_prio_r != 8'h00) ? ((spr_prio > old_prio_r) ? spr_prio : old_prio_r) : spr_prio;
                    if (old_prio_r == 8'h00) begin
                        blend_comb_r = scale_dst_r;
                        blend_comb_g = scale_dst_g;
                        blend_comb_b = scale_dst_b;
                    end else begin
                        blend_comb_r = blend_add_r_r[8:1];
                        blend_comb_g = blend_add_g_r[8:1];
                        blend_comb_b = blend_add_b_r[8:1];
                    end
                end
                2'b11: begin
                    if (scale_dst_alpha == 8'h00) begin
                        blend_comb_we   = 1'b0;
                        blend_comb_prio = old_prio_r;
                        blend_comb_r    = old_r_w;
                        blend_comb_g    = old_g_w;
                        blend_comb_b    = old_b_w;
                    end else if (scale_dst_alpha == 8'hFF) begin
                        blend_comb_we   = 1'b1;
                        blend_comb_prio = (spr_prio > old_prio_r) ? spr_prio : old_prio_r;
                        blend_comb_r    = scale_dst_r;
                        blend_comb_g    = scale_dst_g;
                        blend_comb_b    = scale_dst_b;
                    end else if (old_prio_r == 8'h00) begin
                        blend_comb_we   = 1'b1;
                        blend_comb_prio = spr_prio;
                        blend_comb_r    = blend_pempty_r_r[15:8];
                        blend_comb_g    = blend_pempty_g_r[15:8];
                        blend_comb_b    = blend_pempty_b_r[15:8];
                    end else begin
                        blend_comb_we   = 1'b1;
                        blend_comb_prio = (spr_prio > old_prio_r) ? spr_prio : old_prio_r;
                        blend_comb_r    = alpha_dest_r_w[8] ? 8'h00 : alpha_dest_r_w[7:0];
                        blend_comb_g    = alpha_dest_g_w[8] ? 8'h00 : alpha_dest_g_w[7:0];
                        blend_comb_b    = alpha_dest_b_w[8] ? 8'h00 : alpha_dest_b_w[7:0];
                    end
                end
            endcase
        end
    end

    always @(posedge clk_render or negedge rst_n) begin
        if (!rst_n) begin
            rmw_phase        <= 3'd0;
            old_rgb_r        <= 24'h000000;
            old_prio_r       <= 8'h00;
            blend_prod_r_r   <= 17'sd0;
            blend_prod_g_r   <= 17'sd0;
            blend_prod_b_r   <= 17'sd0;
            blend_pempty_r_r <= 16'd0;
            blend_pempty_g_r <= 16'd0;
            blend_pempty_b_r <= 16'd0;
            blend_add_r_r    <= 9'd0;
            blend_add_g_r    <= 9'd0;
            blend_add_b_r    <= 9'd0;
            blend_reg_we     <= 1'b0;
            blend_reg_prio   <= 8'h00;
            blend_reg_rgb    <= 24'h000000;
        end else if (spr_start_line) begin
            rmw_phase    <= 3'd0;
            blend_reg_we <= 1'b0;
        end else if (is_blend && scale_dst_valid) begin
            case (rmw_phase)
                3'd0: rmw_phase <= 3'd1;
                3'd1: begin
                    old_rgb_r  <= eff_old_rgb;
                    old_prio_r <= eff_old_prio;
                    rmw_phase  <= 3'd2;
                end
                3'd2: begin
                    blend_prod_r_r   <= prod_r_w;
                    blend_prod_g_r   <= prod_g_w;
                    blend_prod_b_r   <= prod_b_w;
                    blend_pempty_r_r <= pempty_r_w;
                    blend_pempty_g_r <= pempty_g_w;
                    blend_pempty_b_r <= pempty_b_w;
                    blend_add_r_r    <= add_r_w;
                    blend_add_g_r    <= add_g_w;
                    blend_add_b_r    <= add_b_w;
                    rmw_phase        <= 3'd3;
                end
                3'd3: begin
                    blend_reg_we   <= blend_comb_we;
                    blend_reg_prio <= blend_comb_prio;
                    blend_reg_rgb  <= {blend_comb_r, blend_comb_g, blend_comb_b};
                    rmw_phase      <= 3'd4;
                end
                default: rmw_phase <= 3'd0;
            endcase
        end else begin
            rmw_phase    <= 3'd0;
            blend_reg_we <= 1'b0;
        end
    end

    wire scale_step_en = !is_blend || (rmw_phase == 3'd4) || !scale_dst_valid;
    wire render_wr_en  = is_blend ? (scale_dst_valid && (rmw_phase == 3'd4) && blend_reg_we)
                                  : (scale_dst_valid && scale_dst_opaque);

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
    // Submodule 5: Hardware Alpha-Blender (pipelined in RMW above)
    // ----------------------------------------------------------------
    wire [7:0]  eff_old_prio;
    wire [23:0] eff_old_rgb;

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
        .wr_prio         (is_blend ? blend_reg_prio : spr_prio),
        .wr_rgb          (is_blend ? blend_reg_rgb  : {scale_dst_r, scale_dst_g, scale_dst_b}),

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
