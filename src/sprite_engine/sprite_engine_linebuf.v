// ====================================================================
//
//  sprite_engine_linebuf.v
//  NanoMig Sprite Engine Dual Ping-Pong Line Buffer (2 x 2048 x 32-Bit)
//
//  Cyclone V M10K implementation (16 M10K blocks total):
//    - Buffer 0 & Buffer 1: 2048 words x 32 bits each
//        Bits [31:24] : BUF_PRIO (8-Bit Priority, 0 = empty)
//        Bits [23:16] : Red [7:0]
//        Bits [15:8]  : Green [7:0]
//        Bits [7:0]   : Blue [7:0]
//    - Ping-Pong Swap on scanline boundary (line_swap_pulse)
//    - Clear-on-Read during Denise video display readout
//    - Fast hardware clear-sweep for unread/overscan columns
//    - 1-cycle write-forwarding bypass logic (eff_old_prio, eff_old_rgb)
//
// ====================================================================

`timescale 1ns / 1ps

module sprite_engine_linebuf (
    input  wire        rst_n,

    // --- Write/Render Domain (clk_114) ---
    input  wire        clk_render,
    input  wire        line_swap_pulse,   // Toggles active ping-pong buffers
    input  wire [10:0] clip_xmax,         // Active line width limit (e.g. 320, 640, 1920)

    // Render write port
    input  wire        wr_en,
    input  wire [10:0] wr_x,
    input  wire [7:0]  wr_prio,
    input  wire [23:0] wr_rgb,

    // Render destination read port (for blending / priority check)
    input  wire [10:0] rd_render_x,
    output wire [7:0]  eff_old_prio,
    output wire [23:0] eff_old_rgb,

    // Status
    output wire        render_ready,      // High when sweep clear is done

    // --- Display/Video Domain (clk_vid) ---
    input  wire        clk_vid,
    input  wire [10:0] vid_x,
    input  wire        vid_read_en,
    output reg  [7:0]  vid_prio,
    output reg  [23:0] vid_rgb
);

    // Ping-pong buffer selection: 0 = render buf 0, display buf 1; 1 = render buf 1, display buf 0
    reg buf_sel;

    // Cross line_swap_pulse into clk_render
    always @(posedge clk_render or negedge rst_n) begin
        if (!rst_n) begin
            buf_sel <= 1'b0;
        end else if (line_swap_pulse) begin
            buf_sel <= ~buf_sel;
        end
    end

    // ----------------------------------------------------------------
    // Sweep-Clear FSM on clk_render for unread columns
    // ----------------------------------------------------------------
    reg [10:0] sweep_col;
    reg        sweeping;

    always @(posedge clk_render or negedge rst_n) begin
        if (!rst_n) begin
            sweep_col <= 11'd0;
            sweeping  <= 1'b1;
        end else if (line_swap_pulse) begin
            sweep_col <= clip_xmax; // Start clearing above clip_xmax
            sweeping  <= 1'b1;
        end else if (sweeping) begin
            if (sweep_col == 11'd2047) begin
                sweeping <= 1'b0;
            end else begin
                sweep_col <= sweep_col + 1'b1;
            end
        end
    end

    assign render_ready = ~sweeping;

    // ----------------------------------------------------------------
    // 1-Cycle Write-Forwarding Bypass Logic (clk_render)
    // ----------------------------------------------------------------
    reg        last_wr_valid;
    reg [10:0] last_wr_x;
    reg [7:0]  last_wr_prio;
    reg [23:0] last_wr_rgb;

    always @(posedge clk_render or negedge rst_n) begin
        if (!rst_n) begin
            last_wr_valid <= 1'b0;
            last_wr_x     <= 11'd0;
            last_wr_prio  <= 8'h00;
            last_wr_rgb   <= 24'h000000;
        end else if (line_swap_pulse) begin
            last_wr_valid <= 1'b0;
        end else if (wr_en) begin
            last_wr_valid <= 1'b1;
            last_wr_x     <= wr_x;
            last_wr_prio  <= wr_prio;
            last_wr_rgb   <= wr_rgb;
        end
    end

    // M10K raw read outputs
    wire [31:0] ram0_render_q;
    wire [31:0] ram1_render_q;

    wire [31:0] ram_render_q = (buf_sel == 1'b0) ? ram0_render_q : ram1_render_q;
    wire [7:0]  ram_old_prio = ram_render_q[31:24];
    wire [23:0] ram_old_rgb  = ram_render_q[23:0];

    // Bypass mux
    wire forward_match = last_wr_valid && (rd_render_x == last_wr_x);
    assign eff_old_prio = forward_match ? last_wr_prio : ram_old_prio;
    assign eff_old_rgb  = forward_match ? last_wr_rgb  : ram_old_rgb;

    // ----------------------------------------------------------------
    // Dual-Port RAM 0 (2048 x 32)
    // ----------------------------------------------------------------
    wire [31:0] ram0_vid_q;
    wire        ram0_render_we = (buf_sel == 1'b0) ? (wr_en || sweeping) : 1'b0;
    wire [10:0] ram0_render_addr = sweeping ? sweep_col : (wr_en ? wr_x : rd_render_x);
    wire [31:0] ram0_render_d = sweeping ? 32'h00000000 : {wr_prio, wr_rgb};
    wire        ram0_vid_we = (buf_sel == 1'b1) && vid_read_en;

    sprite_linebuf_dpram #(
        .DATA_WIDTH(32),
        .ADDR_WIDTH(11)
    ) u_ram0 (
        .clk_a (clk_render),
        .we_a  (ram0_render_we),
        .addr_a(ram0_render_addr),
        .data_a(ram0_render_d),
        .q_a   (ram0_render_q),

        .clk_b (clk_vid),
        .we_b  (ram0_vid_we),
        .addr_b(vid_x),
        .data_b(32'h00000000),
        .q_b   (ram0_vid_q)
    );

    // ----------------------------------------------------------------
    // Dual-Port RAM 1 (2048 x 32)
    // ----------------------------------------------------------------
    wire [31:0] ram1_vid_q;
    wire        ram1_render_we = (buf_sel == 1'b1) ? (wr_en || sweeping) : 1'b0;
    wire [10:0] ram1_render_addr = sweeping ? sweep_col : (wr_en ? wr_x : rd_render_x);
    wire [31:0] ram1_render_d = sweeping ? 32'h00000000 : {wr_prio, wr_rgb};
    wire        ram1_vid_we = (buf_sel == 1'b0) && vid_read_en;

    sprite_linebuf_dpram #(
        .DATA_WIDTH(32),
        .ADDR_WIDTH(11)
    ) u_ram1 (
        .clk_a (clk_render),
        .we_a  (ram1_render_we),
        .addr_a(ram1_render_addr),
        .data_a(ram1_render_d),
        .q_a   (ram1_render_q),

        .clk_b (clk_vid),
        .we_b  (ram1_vid_we),
        .addr_b(vid_x),
        .data_b(32'h00000000),
        .q_b   (ram1_vid_q)
    );

    // ----------------------------------------------------------------
    // Video output multiplexer
    // ----------------------------------------------------------------
    always @(posedge clk_vid) begin
        if (buf_sel == 1'b0) begin
            vid_prio <= ram1_vid_q[31:24];
            vid_rgb  <= ram1_vid_q[23:0];
        end else begin
            vid_prio <= ram0_vid_q[31:24];
            vid_rgb  <= ram0_vid_q[23:0];
        end
    end

endmodule
