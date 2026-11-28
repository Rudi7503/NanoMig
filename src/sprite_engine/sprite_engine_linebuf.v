// ====================================================================
//
//  sprite_engine_linebuf.v
//  NanoMig Sprite Engine Dual Ping-Pong Scanline Buffer
//
//  Stores 2048 pixels x 32-bit ({prio[7:0], r[7:0], g[7:0], b[7:0]})
//  per bank.
//
//  Architecture (Single-Clock 85.59 MHz BRAM + 8-Entry FF Prefetch FIFO):
//    - Both Port A (Render Write/Blend Read) and Port B (Video Prefetch
//      & Clear-on-Read) run on clk_render (85.59 MHz).
//    - Port B prefetches pixels into an 8x32-bit FF FIFO and clears
//      each read BRAM address to 0 immediately in the next clk_render
//      cycle (0 us sweep-clear overhead; full 63.5 us render time).
//    - clk_vid (28.57 MHz) pops pixels from the 8-entry FF FIFO via
//      a glitch-free Gray-coded pointer CDC.
//
// ====================================================================

`timescale 1ns / 1ps

module sprite_engine_linebuf (
    input  wire        rst_n,

    // --- Render / Write Domain (clk_render = 85.59 MHz) ---
    input  wire        clk_render,
    input  wire        line_swap_pulse,   // Scanline boundary pulse (clk_vid)
    input  wire [10:0] clip_xmax,         // Retained for interface compatibility

    // Write from Scaler/Blender
    input  wire        wr_en,
    input  wire [10:0] wr_x,
    input  wire [7:0]  wr_prio,
    input  wire [23:0] wr_rgb,

    // Read-Modify-Write read for Alpha-Blender
    input  wire [10:0] rd_render_x,
    output wire [7:0]  eff_old_prio,
    output wire [23:0] eff_old_rgb,

    // Status
    output wire        render_ready,      // Always ready (Clear-on-Read on Port B)

    // --- Display/Video Domain (clk_vid = 28.57 MHz) ---
    input  wire        clk_vid,
    input  wire [10:0] vid_x,
    input  wire        vid_read_en,
    output reg  [7:0]  vid_prio,
    output reg  [23:0] vid_rgb
);

    // ----------------------------------------------------------------
    // clk_vid Domain: Line-Swap Toggle & 8-Entry FF-FIFO Read Pointer
    // ----------------------------------------------------------------
    reg        line_swap_d;
    reg        swap_tgl_vid;
    reg [2:0]  fifo_rd_ptr_vid;
    reg [2:0]  fifo_rd_gray_vid;

    function [2:0] bin2gray3(input [2:0] b);
        bin2gray3 = b ^ {1'b0, b[2:1]};
    endfunction

    function [2:0] gray2bin3(input [2:0] g);
        gray2bin3 = {g[2], g[2]^g[1], g[2]^g[1]^g[0]};
    endfunction

    wire [2:0] next_rd_ptr_vid = fifo_rd_ptr_vid + 3'd1;

    always @(posedge clk_vid or negedge rst_n) begin
        if (!rst_n) begin
            line_swap_d      <= 1'b0;
            swap_tgl_vid     <= 1'b0;
            fifo_rd_ptr_vid  <= 3'd0;
            fifo_rd_gray_vid <= 3'd0;
        end else begin
            line_swap_d <= line_swap_pulse;
            if (line_swap_pulse && !line_swap_d) begin
                swap_tgl_vid     <= ~swap_tgl_vid;
                fifo_rd_ptr_vid  <= 3'd0;
                fifo_rd_gray_vid <= 3'd0;
            end else if (vid_read_en) begin
                fifo_rd_ptr_vid  <= next_rd_ptr_vid;
                fifo_rd_gray_vid <= bin2gray3(next_rd_ptr_vid);
            end
        end
    end

    // ----------------------------------------------------------------
    // clk_render Domain: CDC Sync for Line-Swap & Gray Read Pointer
    // ----------------------------------------------------------------
    (* syn_preserve = 1 *) reg swap_s1, swap_s2;
    reg swap_s3;
    (* syn_preserve = 1 *) reg [2:0] rd_gray_s1, rd_gray_s2;

    always @(posedge clk_render or negedge rst_n) begin
        if (!rst_n) begin
            swap_s1    <= 1'b0;
            swap_s2    <= 1'b0;
            swap_s3    <= 1'b0;
            rd_gray_s1 <= 3'd0;
            rd_gray_s2 <= 3'd0;
        end else begin
            swap_s1    <= swap_tgl_vid;
            swap_s2    <= swap_s1;
            swap_s3    <= swap_s2;
            rd_gray_s1 <= fifo_rd_gray_vid;
            rd_gray_s2 <= rd_gray_s1;
        end
    end

    wire       swap_edge_85   = (swap_s2 != swap_s3);
    wire [2:0] rd_ptr_sync_85 = gray2bin3(rd_gray_s2);

    // Ping-pong bank selection (entirely in clk_render!)
    // 0 = render buf 0, display buf 1; 1 = render buf 1, display buf 0
    reg buf_sel;
    assign render_ready = 1'b1;

    // ----------------------------------------------------------------
    // 8 x 32-Bit Flip-Flop Prefetch FIFO + Port B Clear-on-Read FSM
    // ----------------------------------------------------------------
    reg [31:0] fifo_mem [0:7];
    reg [2:0]  fifo_wr_ptr_85;
    reg [10:0] prefetch_col;
    reg        pb_phase;         // 0 = read BRAM, 1 = latch FIFO + clear BRAM to 0
    reg        prefetch_active;

    wire [2:0] fifo_used = fifo_wr_ptr_85 - rd_ptr_sync_85;
    wire       pb_clear_we = prefetch_active && (pb_phase == 1'b1);

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
        end else if (swap_edge_85) begin
            last_wr_valid <= 1'b0;
        end else if (wr_en) begin
            last_wr_valid <= 1'b1;
            last_wr_x     <= wr_x;
            last_wr_prio  <= wr_prio;
            last_wr_rgb   <= wr_rgb;
        end
    end

    // Raw BRAM outputs (both ports on clk_render!)
    wire [31:0] ram0_render_q, ram0_vid_q;
    wire [31:0] ram1_render_q, ram1_vid_q;

    wire [31:0] ram_render_q = (buf_sel == 1'b0) ? ram0_render_q : ram1_render_q;
    wire [31:0] ram_vid_q    = (buf_sel == 1'b0) ? ram1_vid_q    : ram0_vid_q;

    wire [7:0]  ram_old_prio = ram_render_q[31:24];
    wire [23:0] ram_old_rgb  = ram_render_q[23:0];

    // Bypass mux
    wire forward_match = last_wr_valid && (rd_render_x == last_wr_x);
    assign eff_old_prio = forward_match ? last_wr_prio : ram_old_prio;
    assign eff_old_rgb  = forward_match ? last_wr_rgb  : ram_old_rgb;

    always @(posedge clk_render or negedge rst_n) begin
        if (!rst_n) begin
            buf_sel         <= 1'b0;
            fifo_wr_ptr_85  <= 3'd0;
            prefetch_col    <= 11'd0;
            pb_phase        <= 1'b0;
            prefetch_active <= 1'b0;
        end else if (swap_edge_85) begin
            buf_sel         <= ~buf_sel;
            fifo_wr_ptr_85  <= 3'd0;
            prefetch_col    <= 11'd0;
            pb_phase        <= 1'b0;
            prefetch_active <= 1'b1;
        end else if (prefetch_active) begin
            if (pb_phase == 1'b0) begin
                if (fifo_used < 3'd6) begin
                    pb_phase <= 1'b1;
                end
            end else begin
                fifo_mem[fifo_wr_ptr_85] <= ram_vid_q;
                fifo_wr_ptr_85           <= fifo_wr_ptr_85 + 3'd1;
                if (prefetch_col == 11'd2047) begin
                    prefetch_active <= 1'b0;
                end else begin
                    prefetch_col <= prefetch_col + 11'd1;
                end
                pb_phase <= 1'b0;
            end
        end
    end

    // ----------------------------------------------------------------
    // Dual-Port RAM 0 (2048 x 32, Single-Clock clk_render)
    // ----------------------------------------------------------------
    wire        ram0_render_we   = (buf_sel == 1'b0) && wr_en;
    wire [10:0] ram0_render_addr = wr_en ? wr_x : rd_render_x;
    wire [31:0] ram0_render_d    = {wr_prio, wr_rgb};
    wire        ram0_vid_we      = (buf_sel == 1'b1) && pb_clear_we;

    sprite_linebuf_dpram #(
        .DATA_WIDTH(32),
        .ADDR_WIDTH(11)
    ) u_ram0 (
        .clk_a (clk_render),
        .we_a  (ram0_render_we),
        .addr_a(ram0_render_addr),
        .data_a(ram0_render_d),
        .q_a   (ram0_render_q),

        .clk_b (clk_render),
        .we_b  (ram0_vid_we),
        .addr_b(prefetch_col),
        .data_b(32'h00000000),
        .q_b   (ram0_vid_q)
    );

    // ----------------------------------------------------------------
    // Dual-Port RAM 1 (2048 x 32, Single-Clock clk_render)
    // ----------------------------------------------------------------
    wire        ram1_render_we   = (buf_sel == 1'b1) && wr_en;
    wire [10:0] ram1_render_addr = wr_en ? wr_x : rd_render_x;
    wire [31:0] ram1_render_d    = {wr_prio, wr_rgb};
    wire        ram1_vid_we      = (buf_sel == 1'b0) && pb_clear_we;

    sprite_linebuf_dpram #(
        .DATA_WIDTH(32),
        .ADDR_WIDTH(11)
    ) u_ram1 (
        .clk_a (clk_render),
        .we_a  (ram1_render_we),
        .addr_a(ram1_render_addr),
        .data_a(ram1_render_d),
        .q_a   (ram1_render_q),

        .clk_b (clk_render),
        .we_b  (ram1_vid_we),
        .addr_b(prefetch_col),
        .data_b(32'h00000000),
        .q_b   (ram1_vid_q)
    );

    // ----------------------------------------------------------------
    // clk_vid Domain: Output from 8-Entry Prefetch FIFO
    // ----------------------------------------------------------------
    always @(posedge clk_vid or negedge rst_n) begin
        if (!rst_n) begin
            vid_prio <= 8'h00;
            vid_rgb  <= 24'h000000;
        end else if (vid_read_en) begin
            vid_prio <= fifo_mem[fifo_rd_ptr_vid][31:24];
            vid_rgb  <= fifo_mem[fifo_rd_ptr_vid][23:0];
        end
    end

endmodule
