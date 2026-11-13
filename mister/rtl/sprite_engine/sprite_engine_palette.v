// ====================================================================
//
//  sprite_engine_palette.v
//  NanoMig Sprite Engine Dedicated Banked 256 x 24-Bit Palette RAM
//
//  Cyclone V M10K-inferred True Dual-Port RAM:
//    - Port A (clk_sys): Write/Read interface for CPU / Amiga registers
//    - Port B (clk_114): 1-cycle latency read port for Sprite Renderer
//
// ====================================================================

`timescale 1ns / 1ps

module sprite_engine_palette (
    // Port A: CPU / Register interface
    input  wire        clk_a,
    input  wire        we_a,
    input  wire [7:0]  addr_a,
    input  wire [23:0] data_a,
    output reg  [23:0] q_a,

    // Port B: High-Speed Sprite Pipeline Read Port
    input  wire        clk_b,
    input  wire [7:0]  addr_b,
    output reg  [23:0] q_b
);

    // 256 entries x 24-bit RGB
    (* ramstyle = "M10K" *) reg [23:0] pal_ram [0:255];

    // Port A: CPU / Register interface (Write-Through mode for Gowin GW5A WRITE_MODE = 2'b01)
    always @(posedge clk_a) begin
        if (we_a) begin
            pal_ram[addr_a] <= data_a;
            q_a <= data_a;
        end else begin
            q_a <= pal_ram[addr_a];
        end
    end

    // Port B (Synchronous 1-cycle read)
    always @(posedge clk_b) begin
        q_b <= pal_ram[addr_b];
    end

endmodule
