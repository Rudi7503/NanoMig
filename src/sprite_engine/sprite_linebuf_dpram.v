// ====================================================================
//
//  sprite_linebuf_dpram.v
//  Canonical Dual-Clock True Dual-Port 2048 x 32 M10K RAM block
//
// ====================================================================

`timescale 1ns / 1ps

module sprite_linebuf_dpram #(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 11
)(
    // Port A: Render Domain (clk_render)
    input  wire                  clk_a,
    input  wire                  we_a,
    input  wire [ADDR_WIDTH-1:0] addr_a,
    input  wire [DATA_WIDTH-1:0] data_a,
    output reg  [DATA_WIDTH-1:0] q_a,

    // Port B: Video Display Domain (clk_vid)
    input  wire                  clk_b,
    input  wire                  we_b,
    input  wire [ADDR_WIDTH-1:0] addr_b,
    input  wire [DATA_WIDTH-1:0] data_b,
    output reg  [DATA_WIDTH-1:0] q_b
);

    (* ramstyle = "no_rw_check, M10K" *) reg [DATA_WIDTH-1:0] mem [(1 << ADDR_WIDTH)-1:0];

    always @(posedge clk_a) begin
        if (we_a)
            mem[addr_a] <= data_a;
        q_a <= mem[addr_a];
    end

    always @(posedge clk_b) begin
        if (we_b)
            mem[addr_b] <= data_b;
        q_b <= mem[addr_b];
    end

endmodule
