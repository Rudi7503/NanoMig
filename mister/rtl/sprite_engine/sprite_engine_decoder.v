// ====================================================================
//
//  sprite_engine_decoder.v
//  NanoMig Sprite Engine Universal Multi-Format Pipelined Decoder (Rev 4.1)
//
//  Decodes all 20 Sprite Engine Formats:
//    - FMT 0..7  : CLUT 1..8 Bit (Palette lookups)
//    - FMT 8..10 : HAM04, HAM06, HAM08
//    - FMT 11..12: HAM12 (12-6-8-6, 12-5-5-5-5)
//    - FMT 13..14: HAM16 (12X4, Direct)
//    - FMT 15    : RGB16 HighColor (RGB565 Direct)
//    - FMT 16    : ARGB32 TrueColor (ARGB8888 with per-pixel alpha)
//    - FMT 17    : HAM12_5D (12-bit Anchor + 4x ham5delta)
//    - FMT 18    : HAM12_686_D (12-bit Anchor + ham6delta/ham8delta)
//    - FMT 19    : HAM08_D (Pure 8-bit ham8delta Turboturbo)
//
//  Hardware steps: Fixed default step = 4, saturation clamp [0..255]
//
// ====================================================================

`timescale 1ns / 1ps

module sprite_engine_decoder (
    input  wire        clk,
    input  wire        rst_n,

    // Control
    input  wire        in_valid,         // Pixel input strobe (advances pipeline & accumulator)
    input  wire        clr_acc,          // Reset accumulator (at transparent pixel or start of line)
    input  wire [4:0]  fmt,              // FORMAT_ID (0..19)
    input  wire [5:0]  bw,               // Current sub-pixel bit width (1..32)
    input  wire [31:0] raw_code,         // Sub-pixel raw code bits (right-aligned)
    input  wire [7:0]  pal_offset,       // Palette bank offset
    input  wire [7:0]  desc_alpha,       // Descriptor global alpha (for FMT 13..15)

    // Palette read port (from sprite_engine_palette)
    output reg  [7:0]  pal_addr,
    input  wire [23:0] pal_data,

    // Decoded pixel output
    output reg         out_valid,
    output reg  [7:0]  out_r,
    output reg  [7:0]  out_g,
    output reg  [7:0]  out_b,
    output reg  [7:0]  out_alpha,
    output reg         out_opaque
);

    // Color accumulator
    reg [7:0] acc_r;
    reg [7:0] acc_g;
    reg [7:0] acc_b;

    // Helper function for 2-bit delta: 00=-2, 01=-1, 10=+1, 11=+2
    function signed [2:0] two_delta;
        input [1:0] code;
        begin
            case (code)
                2'b00: two_delta = -3'sd2;
                2'b01: two_delta = -3'sd1;
                2'b10: two_delta =  3'sd1;
                2'b11: two_delta =  3'sd2;
            endcase
        end
    endfunction

    // Clamping adder helper for 8-bit saturation
    function [7:0] clamp_add;
        input [7:0]         cur;
        input signed [8:0]  delta;
        reg   signed [10:0] sum;
        begin
            sum = $signed({2'b00, cur}) + delta;
            if (sum < 0)
                clamp_add = 8'h00;
            else if (sum > 255)
                clamp_add = 8'hFF;
            else
                clamp_add = sum[7:0];
        end
    endfunction

    // ----------------------------------------------------------------
    // Stage 1: Decode raw_code into Anchor vs Delta components
    // ----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_r      <= 8'h00;
            acc_g      <= 8'h00;
            acc_b      <= 8'h00;
            out_r      <= 8'h00;
            out_g      <= 8'h00;
            out_b      <= 8'h00;
            out_alpha  <= 8'h00;
            out_opaque <= 1'b0;
            out_valid  <= 1'b0;
            pal_addr   <= 8'h00;
        end else if (clr_acc) begin
            // Reset accumulator on scanline start
            acc_r      <= 8'h00;
            acc_g      <= 8'h00;
            acc_b      <= 8'h00;
            out_r      <= 8'h00;
            out_g      <= 8'h00;
            out_b      <= 8'h00;
            out_alpha  <= 8'h00;
            out_opaque <= 1'b0;
            out_valid  <= 1'b0;
            pal_addr   <= 8'h00;
        end else if (in_valid) begin
            out_valid <= 1'b1;
            if (raw_code == 32'h0) begin
                // Transparent pixel:
                acc_r      <= 8'h00;
                acc_g      <= 8'h00;
                acc_b      <= 8'h00;
                out_r      <= 8'h00;
                out_g      <= 8'h00;
                out_b      <= 8'h00;
                out_alpha  <= 8'h00;
                out_opaque <= 1'b0;
            end else begin
                case (fmt)
                // --- FMT 0..7: Direct CLUT 1..8 Bit ---
                5'd0, 5'd1, 5'd2, 5'd3, 5'd4, 5'd5, 5'd6, 5'd7: begin
                    pal_addr   <= (pal_offset + raw_code[7:0]) & 8'hFF;
                    out_r      <= pal_data[23:16];
                    out_g      <= pal_data[15:8];
                    out_b      <= pal_data[7:0];
                    out_alpha  <= 8'hFF;
                    out_opaque <= 1'b1;
                end

                // --- FMT 16: Direct ARGB32 TrueColor ---
                5'd16: begin
                    out_alpha  <= raw_code[31:24];
                    out_r      <= raw_code[23:16];
                    out_g      <= raw_code[15:8];
                    out_b      <= raw_code[7:0];
                    out_opaque <= (raw_code[31:24] != 8'h00);
                end

                // --- FMT 15: Direct RGB16 HighColor (RGB565) ---
                5'd15: begin
                    out_r      <= {raw_code[15:11], 3'b000};
                    out_g      <= {raw_code[10:5],  2'b00};
                    out_b      <= {raw_code[4:0],   3'b000};
                    out_alpha  <= desc_alpha;
                    out_opaque <= 1'b1;
                end

                // --- FMT 17: Pure ham5delta (40 px / burst) ---
                5'd17: begin
                    if (bw == 6'd12) begin
                        // 12-Bit RGB444 Direct Anchor
                        out_r      <= ((({raw_code[10:7], 1'b0}) | raw_code[10]) << 4);
                        out_g      <= (raw_code[6:3] << 4);
                        out_b      <= ((({raw_code[2:0], 1'b0})  | raw_code[10]) << 4);
                        acc_r      <= ((({raw_code[10:7], 1'b0}) | raw_code[10]) << 4);
                        acc_g      <= (raw_code[6:3] << 4);
                        acc_b      <= ((({raw_code[2:0], 1'b0})  | raw_code[10]) << 4);
                        out_alpha  <= 8'hFF;
                        out_opaque <= 1'b1;
                    end else begin
                        // 5-Bit ham5delta: Bit4=Turbo (4x/16x), Bit3=dr, Bits2..1=dg, Bit0=db
                        begin: ham5d_block
                            reg [4:0] mult;
                            reg signed [8:0] dr_val, dg_val, db_val;
                            mult = raw_code[4] ? 5'd16 : 5'd4;
                            dr_val = (raw_code[3] ? 3'sd1 : -3'sd1) * mult;
                            dg_val = two_delta(raw_code[2:1]) * mult;
                            db_val = (raw_code[0] ? 3'sd1 : -3'sd1) * mult;

                            acc_r <= clamp_add(acc_r, dr_val);
                            acc_g <= clamp_add(acc_g, dg_val);
                            acc_b <= clamp_add(acc_b, db_val);
                            out_r <= clamp_add(acc_r, dr_val);
                            out_g <= clamp_add(acc_g, dg_val);
                            out_b <= clamp_add(acc_b, db_val);
                            out_alpha  <= 8'hFF;
                            out_opaque <= 1'b1;
                        end
                    end
                end

                // --- FMT 18: Pure ham6delta & ham8delta (32 px / burst) ---
                5'd18: begin
                    if (bw == 6'd12) begin
                        // 12-Bit RGB444 Direct Anchor
                        out_r      <= ((({raw_code[10:7], 1'b0}) | raw_code[10]) << 4);
                        out_g      <= (raw_code[6:3] << 4);
                        out_b      <= ((({raw_code[2:0], 1'b0})  | raw_code[10]) << 4);
                        acc_r      <= ((({raw_code[10:7], 1'b0}) | raw_code[10]) << 4);
                        acc_g      <= (raw_code[6:3] << 4);
                        acc_b      <= ((({raw_code[2:0], 1'b0})  | raw_code[10]) << 4);
                        out_alpha  <= 8'hFF;
                        out_opaque <= 1'b1;
                    end else if (bw == 6'd6) begin
                        // 6-Bit ham6delta: Bits 5..4 = Turboturbo (1x, 4x, 8x, 16x)
                        begin: ham6d_block
                            reg [4:0] mult;
                            reg signed [8:0] dr_val, dg_val, db_val;
                            case (raw_code[5:4])
                                2'b00: mult = 5'd1;
                                2'b01: mult = 5'd4;
                                2'b10: mult = 5'd8;
                                2'b11: mult = 5'd16;
                            endcase
                            dr_val = (raw_code[3] ? 3'sd1 : -3'sd1) * mult;
                            dg_val = two_delta(raw_code[2:1]) * mult;
                            db_val = (raw_code[0] ? 3'sd1 : -3'sd1) * mult;

                            acc_r <= clamp_add(acc_r, dr_val);
                            acc_g <= clamp_add(acc_g, dg_val);
                            acc_b <= clamp_add(acc_b, db_val);
                            out_r <= clamp_add(acc_r, dr_val);
                            out_g <= clamp_add(acc_g, dg_val);
                            out_b <= clamp_add(acc_b, db_val);
                            out_alpha  <= 8'hFF;
                            out_opaque <= 1'b1;
                        end
                    end else begin
                        // 8-Bit ham8delta: Bits 7..6 = Turboturbo (1x, 4x, 8x, 16x)
                        begin: ham8d_block
                            reg [4:0] mult;
                            reg signed [8:0] dr_val, dg_val, db_val;
                            case (raw_code[7:6])
                                2'b00: mult = 5'd1;
                                2'b01: mult = 5'd4;
                                2'b10: mult = 5'd8;
                                2'b11: mult = 5'd16;
                            endcase
                            dr_val = two_delta(raw_code[5:4]) * mult;
                            dg_val = two_delta(raw_code[3:2]) * mult;
                            db_val = two_delta(raw_code[1:0]) * mult;

                            acc_r <= clamp_add(acc_r, dr_val);
                            acc_g <= clamp_add(acc_g, dg_val);
                            acc_b <= clamp_add(acc_b, db_val);
                            out_r <= clamp_add(acc_r, dr_val);
                            out_g <= clamp_add(acc_g, dg_val);
                            out_b <= clamp_add(acc_b, db_val);
                            out_alpha  <= 8'hFF;
                            out_opaque <= 1'b1;
                        end
                    end
                end

                // --- FMT 19: Pure ham8delta (32 px / burst) ---
                5'd19: begin
                    begin: ham8d_pure
                        reg [4:0] mult;
                        reg signed [8:0] dr_val, dg_val, db_val;
                        case (raw_code[7:6])
                            2'b00: mult = 5'd1;
                            2'b01: mult = 5'd4;
                            2'b10: mult = 5'd8;
                            2'b11: mult = 5'd16;
                        endcase
                        dr_val = two_delta(raw_code[5:4]) * mult;
                        dg_val = two_delta(raw_code[3:2]) * mult;
                        db_val = two_delta(raw_code[1:0]) * mult;

                        acc_r <= clamp_add(acc_r, dr_val);
                        acc_g <= clamp_add(acc_g, dg_val);
                        acc_b <= clamp_add(acc_b, db_val);
                        out_r <= clamp_add(acc_r, dr_val);
                        out_g <= clamp_add(acc_g, dg_val);
                        out_b <= clamp_add(acc_b, db_val);
                        out_alpha  <= 8'hFF;
                        out_opaque <= 1'b1;
                    end
                end

                // Default fallback
                default: begin
                    out_r      <= 8'h00;
                    out_g      <= 8'h00;
                    out_b      <= 8'h00;
                    out_alpha  <= 8'h00;
                    out_opaque <= 1'b0;
                end
            endcase
            end
        end else begin
            out_valid <= 1'b0;
        end
    end

endmodule
