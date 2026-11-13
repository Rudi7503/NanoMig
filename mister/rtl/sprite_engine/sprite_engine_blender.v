// ====================================================================
//
//  sprite_engine_blender.v
//  NanoMig Sprite Engine Hardware Alpha-Blender (Revision 4.1)
//
//  Implements the 4 Hardware Blend Modes:
//    2'b00 : Normal / Replace (C_out = S)
//    2'b01 : Additive Blending (C_out = min(255, S + D))
//    2'b10 : 50/50 Translucent (C_out = (S + D) >> 1)
//    2'b11 : Full 8-Bit Alpha Blending (C_out = D + (alpha * (S - D)) >> 8)
//
//  Special contracts:
//    - Alpha 0 (mode 11, alpha == 0): WE = 0 (completely transparent)
//    - Alpha 255 (mode 11, alpha == 255): C_out = S without rounding loss
//    - Empty destination (dst_prio == 0):
//        * Mode 01 & 10: write S directly
//        * Mode 11: write (alpha * S) >> 8 (or S if alpha == 255)
//
// ====================================================================

`timescale 1ns / 1ps

module sprite_engine_blender (
    input  wire [1:0]  blend_mode,    // 00=Normal, 01=Additive, 10=50/50, 11=Alpha
    input  wire [7:0]  src_alpha,     // Effective alpha (0..255)
    input  wire [7:0]  src_r,         // Source pixel (S)
    input  wire [7:0]  src_g,
    input  wire [7:0]  src_b,
    input  wire [7:0]  src_prio,      // Source priority
    input  wire        src_opaque,    // 1 if source pixel is opaque/active

    input  wire [7:0]  dst_r,         // Destination pixel in line buffer (D)
    input  wire [7:0]  dst_g,
    input  wire [7:0]  dst_b,
    input  wire [7:0]  dst_prio,      // Destination priority (0 = empty)

    output reg  [7:0]  out_r,         // Blended result
    output reg  [7:0]  out_g,
    output reg  [7:0]  out_b,
    output reg  [7:0]  out_prio,      // Result priority
    output reg         out_we         // Write enable to line buffer
);

    // Intermediate wires for Additive (clamp at 255)
    wire [8:0] add_r = {1'b0, src_r} + {1'b0, dst_r};
    wire [8:0] add_g = {1'b0, src_g} + {1'b0, dst_g};
    wire [8:0] add_b = {1'b0, src_b} + {1'b0, dst_b};

    // Intermediate wires for 50/50 Translucent
    wire [7:0] half_r = add_r[8:1];
    wire [7:0] half_g = add_g[8:1];
    wire [7:0] half_b = add_b[8:1];

    // Intermediate wires for 8-Bit Alpha Blending
    // Formula: C_out = D + floor((alpha * (S - D)) / 256)
    // S - D is signed 9-bit [-255..+255]
    wire signed [8:0] diff_r = $signed({1'b0, src_r}) - $signed({1'b0, dst_r});
    wire signed [8:0] diff_g = $signed({1'b0, src_g}) - $signed({1'b0, dst_g});
    wire signed [8:0] diff_b = $signed({1'b0, src_b}) - $signed({1'b0, dst_b});

    wire signed [16:0] prod_r = diff_r * $signed({1'b0, src_alpha});
    wire signed [16:0] prod_g = diff_g * $signed({1'b0, src_alpha});
    wire signed [16:0] prod_b = diff_b * $signed({1'b0, src_alpha});

    wire [8:0] alpha_dest_r = $signed({1'b0, dst_r}) + (prod_r >>> 8);
    wire [8:0] alpha_dest_g = $signed({1'b0, dst_g}) + (prod_g >>> 8);
    wire [8:0] alpha_dest_b = $signed({1'b0, dst_b}) + (prod_b >>> 8);

    // Alpha blend against empty background (dst_prio == 0): C_out = (alpha * S) >> 8
    wire [15:0] prod_empty_r = src_r * src_alpha;
    wire [15:0] prod_empty_g = src_g * src_alpha;
    wire [15:0] prod_empty_b = src_b * src_alpha;

    always @(*) begin
        if (!src_opaque) begin
            // Source is completely transparent: no write
            out_we   = 1'b0;
            out_prio = 8'h00;
            out_r    = 8'h00;
            out_g    = 8'h00;
            out_b    = 8'h00;
        end else begin
            case (blend_mode)
                2'b00: begin
                    // Normal / Replace
                    out_we   = 1'b1;
                    out_prio = src_prio;
                    out_r    = src_r;
                    out_g    = src_g;
                    out_b    = src_b;
                end

                2'b01: begin
                    // Additive Blending
                    out_we   = 1'b1;
                    out_prio = (dst_prio != 8'h00) ? ((src_prio > dst_prio) ? src_prio : dst_prio) : src_prio;
                    if (dst_prio == 8'h00) begin
                        out_r = src_r;
                        out_g = src_g;
                        out_b = src_b;
                    end else begin
                        out_r = (add_r[8]) ? 8'hFF : add_r[7:0];
                        out_g = (add_g[8]) ? 8'hFF : add_g[7:0];
                        out_b = (add_b[8]) ? 8'hFF : add_b[7:0];
                    end
                end

                2'b10: begin
                    // 50/50 Translucent
                    out_we   = 1'b1;
                    out_prio = (dst_prio != 8'h00) ? ((src_prio > dst_prio) ? src_prio : dst_prio) : src_prio;
                    if (dst_prio == 8'h00) begin
                        out_r = src_r;
                        out_g = src_g;
                        out_b = src_b;
                    end else begin
                        out_r = half_r;
                        out_g = half_g;
                        out_b = half_b;
                    end
                end

                2'b11: begin
                    // Full 8-Bit Alpha Blending
                    if (src_alpha == 8'h00) begin
                        // Alpha == 0: strictly transparent, no write!
                        out_we   = 1'b0;
                        out_prio = dst_prio;
                        out_r    = dst_r;
                        out_g    = dst_g;
                        out_b    = dst_b;
                    end else if (src_alpha == 8'hFF) begin
                        // Alpha == 255: saturated exact source
                        out_we   = 1'b1;
                        out_prio = (src_prio > dst_prio) ? src_prio : dst_prio;
                        out_r    = src_r;
                        out_g    = src_g;
                        out_b    = src_b;
                    end else if (dst_prio == 8'h00) begin
                        // Empty destination
                        out_we   = 1'b1;
                        out_prio = src_prio;
                        out_r    = prod_empty_r[15:8];
                        out_g    = prod_empty_g[15:8];
                        out_b    = prod_empty_b[15:8];
                    end else begin
                        // Blended against existing line buffer content
                        out_we   = 1'b1;
                        out_prio = (src_prio > dst_prio) ? src_prio : dst_prio;
                        out_r    = (alpha_dest_r[8]) ? 8'h00 : alpha_dest_r[7:0];
                        out_g    = (alpha_dest_g[8]) ? 8'h00 : alpha_dest_g[7:0];
                        out_b    = (alpha_dest_b[8]) ? 8'h00 : alpha_dest_b[7:0];
                    end
                end
            endcase
        end
    end

endmodule
