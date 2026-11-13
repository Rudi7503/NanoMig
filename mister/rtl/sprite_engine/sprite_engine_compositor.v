// ====================================================================
//
//  sprite_engine_compositor.v
//  NanoMig Sprite Engine Video Compositor & Denise Overlay
//
//  Composites the 24-Bit Denise/AGA video output with the Sprite Engine
//  line buffer according to the 4 Hardware Priority Layers (PRIO[7:6]):
//
//    PRIO == 0       : Empty/Transparent -> Show amiga_rgb
//    PRIO[7:6] == 00 : Background Layer (behind all Bitplanes, before Color00)
//                      Condition: (prio != 0) && !sprsel && !pf_any_opaque
//    PRIO[7:6] == 01 : Between Back and Front Dual-Playfield
//                      Condition: (prio != 0) && !sprsel && !pf_front_opaque
//    PRIO[7:6] == 10 : In front of Bitplanes, behind native Amiga Sprites 0..7
//                      Condition: (prio != 0) && !sprsel
//    PRIO[7:6] == 11 : Topmost Foreground (in front of Bitplanes & native Sprites)
//                      Condition: (prio != 0)
//
// ====================================================================

`timescale 1ns / 1ps

module sprite_engine_compositor (
    input  wire        clk,
    input  wire        rst_n,

    // Denise native Amiga video inputs
    input  wire [23:0] amiga_rgb,
    input  wire        sprsel_aligned,     // Native Amiga sprite active
    input  wire        pf_front_opaque,    // Front playfield pixel is opaque
    input  wire        pf_any_opaque,      // Either playfield pixel is opaque
    input  wire        blank_n,            // Video active (not in blanking)

    // Sprite Engine line buffer inputs
    input  wire [23:0] sprite_rgb,
    input  wire [7:0]  sprite_prio,
    input  wire        sprite_engine_en,   // Global enable bit

    // Final video output
    output reg  [23:0] out_rgb
);

    wire sprite_visible;

    assign sprite_visible = sprite_engine_en && (sprite_prio != 8'h00) && (
        (sprite_prio[7:6] == 2'b11) ? 1'b1 :
        (sprite_prio[7:6] == 2'b10) ? (!sprsel_aligned) :
        (sprite_prio[7:6] == 2'b01) ? (!sprsel_aligned && !pf_front_opaque) :
        /* 2'b00 */                   (!sprsel_aligned && !pf_any_opaque)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_rgb <= 24'h000000;
        end else if (!blank_n) begin
            out_rgb <= 24'h000000;
        end else if (sprite_visible) begin
            out_rgb <= sprite_rgb;
        end else begin
            out_rgb <= amiga_rgb;
        end
    end

endmodule
