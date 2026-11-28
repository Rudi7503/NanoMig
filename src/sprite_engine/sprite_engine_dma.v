// ====================================================================
//
//  sprite_engine_dma.v
//  NanoMig Sprite Engine Hardware Descriptor Scanner & DDR3 DMA Master
//
//  Features (Revision 4.1 Specification):
//    - 16-Byte Descriptor List in Fast-RAM
//    - Y-Sorting Contract: Ascending Y_POS, terminates at HEIGHT == 0
//    - Atomic VBlank Pointer Latching with shadow staging buffer
//    - Avalon-MM DDR3-BL8 Burst Master (BURSTCNT = 4, 32 Bytes = 256 Bits)
//    - Hardware 1-Cycle Zero-Word-Skip (64'h0 skips without pipeline stalls)
//    - Vertical flip (V_FLIP) & Q6 vertical scaling (Y_SCALE)
//
// ====================================================================

`timescale 1ns / 1ps

// `define SPR_BRAM_TEST

module sprite_engine_dma (
    input  wire        clk,
    input  wire        rst_n,

    // Amiga register bus interface
    input  wire        reg_we,
    input  wire [3:0]  reg_addr,        // 0=PTR_H, 1=PTR_L, 2=CTRL, 3=STATUS
    input  wire [15:0] reg_wdata,
    output reg  [15:0] reg_rdata,

    // Video timing
    input  wire        vblank_pulse,    // Frame boundary: atomic pointer swap
    input  wire        start_line,      // Scanline boundary: start processing line Y+1
    input  wire signed [11:0] cur_y,    // Scanline to render (-2048..+2047)

    // Avalon-MM DDR3 Memory Master interface
    output reg  [31:0] avm_address,
    output wire [3:0]  avm_burstcount,
    output reg         avm_read,
    input  wire        avm_waitrequest,
    input  wire [63:0] avm_readdata,
    input  wire        avm_readdatavalid,

    // Decoded sprite descriptor output for current active sprite
    output reg         sprite_active,
    output reg  signed [15:0] spr_x,
    output reg  [4:0]  spr_fmt,
    output reg  [7:0]  spr_prio,
    output reg  [7:0]  spr_alpha,
    output reg  [1:0]  spr_blend_mode,
    output reg  [8:0]  spr_x_scale,
    output reg         spr_smooth,
    output reg         spr_h_flip,
    output reg  [14:0] spr_w_px,
    output reg         spr_start_line,

    // Data stream to un-packer / decoder
    output reg  [63:0] stream_word64,
    output reg         stream_valid,
    input  wire        stream_ack,

    // Status
    input  wire        render_ready,    // Linebuf sweep-clear finished
    output reg         line_done,       // All sprites for this line finished
    output wire        engine_en_out,
    output wire        cap_en_out
);

    assign avm_burstcount = 4'd4; // Always 4 beats = 256 bits (32 bytes)
    assign engine_en_out  = engine_en;
    assign cap_en_out     = cap_en;

    // ----------------------------------------------------------------
    // Registers & Staging
    // ----------------------------------------------------------------
    reg [15:0] reg_ptr_h;
    reg [31:0] staged_ptr;
    reg [31:0] active_ptr;
    reg        ptr_updated;
    reg        engine_en;
    reg        zero_skip_en;
    reg        cap_en;

    // Register Write Logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_ptr_h    <= 16'h0000;
`ifdef SPR_BRAM_TEST
            // Testbetrieb: Liste fest auf 0x1000, Engine dauerhaft an.
            // Damit laesst sich das Block-RAM-Muster ohne Amiga-Software
            // anzeigen (Toby, 2026-11-13).
            staged_ptr   <= 32'h0000_1000;
            active_ptr   <= 32'h0000_1000;
            ptr_updated  <= 1'b1;
            engine_en    <= 1'b1;
`else
            staged_ptr   <= 32'h0000_0000;
            active_ptr   <= 32'h0000_0000;
            ptr_updated  <= 1'b0;
            engine_en    <= 1'b0;
`endif
            zero_skip_en <= 1'b0;
            cap_en       <= 1'b0;
        end else begin
            if (reg_we) begin
                case (reg_addr)
                    4'd0: reg_ptr_h <= reg_wdata;
                    4'd1: begin
                        // Writing low word latches full 32-bit staged pointer!
                        staged_ptr  <= {reg_ptr_h, reg_wdata};
                        ptr_updated <= 1'b1;
                    end
                    4'd2: begin
                        engine_en    <= reg_wdata[0];
                        zero_skip_en <= reg_wdata[1];
                        cap_en       <= reg_wdata[2];
                    end
                endcase
            end

            // Atomic handoff at VBlank
            if (vblank_pulse && ptr_updated) begin
                active_ptr  <= staged_ptr;
                ptr_updated <= 1'b0;
            end
        end
    end

    // Register Read Logic
    always @(*) begin
        case (reg_addr)
            4'd0: reg_rdata = active_ptr[31:16];
            4'd1: reg_rdata = active_ptr[15:0];
            4'd2: reg_rdata = {13'd0, cap_en, zero_skip_en, engine_en};
            4'd3: reg_rdata = {15'd0, line_done};
            default: reg_rdata = 16'h0000;
        endcase
    end

    // ----------------------------------------------------------------
    // Descriptor Scanner & Burst Fetch FSM
    // ----------------------------------------------------------------
    localparam S_IDLE        = 4'd0;
    localparam S_FETCH_DESC0 = 4'd1;
    localparam S_WAIT_DESC0  = 4'd2;
    localparam S_FETCH_DESC1 = 4'd3;
    localparam S_WAIT_DESC1  = 4'd4;
    localparam S_DESC_DRAIN  = 4'd10;
    localparam S_EVAL_DESC   = 4'd5;
    localparam S_FETCH_DATA  = 4'd6;
    localparam S_STREAM_DATA = 4'd7;
    localparam S_NEXT_DESC   = 4'd8;
    localparam S_DONE        = 4'd9;
    localparam S_WAIT_CLEAR  = 4'd11;
    localparam S_EVAL_PREP   = 4'd12;
    localparam S_EVAL_PREP2  = 4'd13;

    reg [3:0]  state;
    reg signed [15:0] eval_dy;
    reg [7:0]         eval_eff_w;
    reg               eval_vis;
    reg [15:0]        eval_rel_y;
    reg [31:0] cur_desc_addr;

    // Latched descriptor fields (Motorola Big-Endian Revision 4: 16 Bytes)
    reg signed [15:0] d_y_pos;
    reg signed [15:0] d_x_pos;
    reg [31:0]        d_data_ptr;
    reg [15:0]        d_height;
    reg [7:0]         d_width_b;       // Width in 256-bit / 32-byte bursts (1..64)
    reg [7:0]         d_fmt;
    reg [7:0]         d_prio;
    reg [7:0]         d_alpha;
    reg [15:0]        d_ctrl;

    function [8:0] get_burst_px(input [4:0] fmt);
        case (fmt)
            5'd0:    get_burst_px = 9'd256; // CLUT01
            5'd1:    get_burst_px = 9'd128; // CLUT02
            5'd2:    get_burst_px = 9'd85;  // CLUT03
            5'd3:    get_burst_px = 9'd64;  // CLUT04
            5'd4:    get_burst_px = 9'd51;  // CLUT05
            5'd5:    get_burst_px = 9'd42;  // CLUT06
            5'd6:    get_burst_px = 9'd36;  // CLUT07
            5'd7:    get_burst_px = 9'd32;  // CLUT08
            5'd8:    get_burst_px = 9'd64;  // HAM04
            5'd9:    get_burst_px = 9'd64;  // HAM06
            5'd10:   get_burst_px = 9'd32;  // HAM08
            5'd11:   get_burst_px = 9'd32;  // HAM12 12_686
            5'd12:   get_burst_px = 9'd40;  // HAM12 12_5555
            5'd13:   get_burst_px = 9'd20;  // HAM16 12x4
            5'd14:   get_burst_px = 9'd16;  // HAM16 Direct
            5'd15:   get_burst_px = 9'd16;  // RGB16 Direct
            5'd16:   get_burst_px = 9'd8;   // ARGB32
            5'd17:   get_burst_px = 9'd40;  // HAM12 12_5555_DELTA
            5'd18:   get_burst_px = 9'd32;  // HAM12 12_686_DELTA
            5'd19:   get_burst_px = 9'd32;  // HAM08_DELTA
            default: get_burst_px = 9'd32;
        endcase
    endfunction

    reg [11:0] bursts_needed;
    reg [11:0] burst_cnt;
    reg [1:0]  beat_cnt;
    reg [1:0]  drain_cnt;
    reg [5:0]  drain_timeout;
    reg [31:0] cur_line_data_addr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= S_IDLE;
            cur_desc_addr      <= 32'h0;
            avm_address        <= 32'h0;
            avm_read           <= 1'b0;
            sprite_active      <= 1'b0;
            spr_start_line     <= 1'b0;
            stream_valid       <= 1'b0;
            stream_word64      <= 64'h0;
            line_done          <= 1'b1;
            burst_cnt          <= 12'd0;
            beat_cnt           <= 2'd0;
            drain_cnt          <= 2'd0;
            drain_timeout      <= 6'd0;
            cur_line_data_addr <= 32'h0;
        end else begin
            stream_valid   <= 1'b0;
            spr_start_line <= 1'b0;

            case (state)
                S_IDLE: begin
                    line_done <= 1'b1;
                    if (start_line && engine_en && active_ptr != 32'h0) begin
                        cur_desc_addr <= active_ptr;
                        line_done     <= 1'b0;
                        state         <= S_FETCH_DESC0;
                    end
                end

                // --- Read Descriptor 64-bit Word 0 ---
                S_FETCH_DESC0: begin
                    avm_address <= cur_desc_addr;
                    avm_read    <= 1'b1;
                    if (avm_read && !avm_waitrequest) begin
                        avm_read <= 1'b0;
                        state    <= S_WAIT_DESC0;
                    end
                end

                S_WAIT_DESC0: begin
                    if (avm_readdatavalid) begin
                        d_y_pos    <= avm_readdata[63:48]; // int16_t (signed)
                        d_x_pos    <= avm_readdata[47:32]; // int16_t (signed)
                        d_data_ptr <= avm_readdata[31:0];  // uint32_t clean pointer
                        state      <= S_WAIT_DESC1;
                    end
                end

                // --- Read Descriptor 64-bit Word 1 (Supplied by BL4 beat 1) ---
                S_FETCH_DESC1: begin
                    state <= S_WAIT_DESC1;
                end

                S_WAIT_DESC1: begin
                    if (avm_readdatavalid) begin
                        d_height      <= avm_readdata[63:48]; // uint16_t (0 = Sentinel)
                        d_width_b     <= avm_readdata[47:40]; // uint8_t bursts (1..64)
                        d_fmt         <= avm_readdata[39:32]; // uint8_t format (0..19)
                        d_prio        <= avm_readdata[31:24]; // uint8_t prio (1..255)
                        d_alpha       <= avm_readdata[23:16]; // uint8_t alpha / pal_offset
                        d_ctrl        <= avm_readdata[15:0];  // uint16_t ctrl flags
                        drain_cnt     <= 2'd2;
                        drain_timeout <= 6'd0;
                        state         <= S_DESC_DRAIN;
                    end
                end

                // --- Drain Remaining 2 Words of BL4 Descriptor Burst ---
                S_DESC_DRAIN: begin
                    if (avm_readdatavalid) begin
                        if (drain_cnt == 2'd1) begin
                            state <= S_EVAL_PREP;
                        end else begin
                            drain_cnt <= drain_cnt - 2'd1;
                        end
                    end else begin
                        drain_timeout <= drain_timeout + 6'd1;
                        if (drain_timeout == 6'd32) begin
                            // Fallback for legacy fixtures omitting trailing beats
                            state <= S_EVAL_PREP;
                        end
                    end
                end

                // --- Pipeline Y visibility check to break scanline_y -> CE path at 85.6 MHz ---
                S_EVAL_PREP: begin
                    eval_dy    <= {{4{cur_y[11]}}, cur_y} - d_y_pos;
                    eval_eff_w <= (d_width_b > 8'd64) ? 8'd64 : d_width_b;
                    state      <= S_EVAL_PREP2;
                end

                S_EVAL_PREP2: begin
                    begin: eval_prep2_blk
                        reg [15:0] src_y;
                        case (d_ctrl[5:3])
                            3'd1:    src_y = eval_dy >> 1; // 2x Zoom
                            3'd2:    src_y = eval_dy >> 2; // 4x Zoom
                            3'd3:    src_y = eval_dy << 1; // 1/2 Shrink
                            3'd4:    src_y = eval_dy << 2; // 1/4 Shrink
                            default: src_y = eval_dy;      // 1x Normal
                        endcase
                        eval_vis   <= (d_height != 16'd0) && (d_prio != 8'h00) && (d_width_b != 8'd0) && !eval_dy[15] && (src_y < d_height);
                        eval_rel_y <= d_ctrl[7] ? (d_height - 16'd1 - src_y) : src_y;
                    end
                    state <= S_EVAL_DESC;
                end

                // --- Evaluate Descriptor against current Scanline Y ---
                S_EVAL_DESC: begin
                    if (d_height == 16'd0) begin
                        // Sentinel: End of descriptor list!
                        state <= S_DONE;
                    end else if (eval_vis) begin
                        bursts_needed      <= {4'd0, eval_eff_w};
                        cur_line_data_addr <= d_data_ptr + ({16'd0, eval_rel_y} * {24'd0, eval_eff_w} * 32);

                        // Latch sprite output parameters
                        sprite_active  <= 1'b1;
                        spr_x          <= d_x_pos;
                        spr_fmt        <= d_fmt[4:0];
                        spr_prio       <= d_prio;
                        spr_alpha      <= d_alpha;
                        spr_blend_mode <= d_ctrl[10:9];
                        case (d_ctrl[2:0]) // X_SCALE
                            3'd1:    spr_x_scale <= 9'd32;  // 2x Zoom
                            3'd2:    spr_x_scale <= 9'd16;  // 4x Zoom
                            3'd3:    spr_x_scale <= 9'd128; // 1/2 Shrink
                            3'd4:    spr_x_scale <= 9'd256; // 1/4 Shrink
                            default: spr_x_scale <= 9'd64;  // 1x Normal
                        endcase
                        spr_smooth     <= d_ctrl[8];
                        spr_h_flip     <= d_ctrl[6];
                        spr_w_px       <= {7'd0, eval_eff_w} * {6'd0, get_burst_px(d_fmt[4:0])};
                        spr_start_line <= 1'b1;

                        burst_cnt <= 12'd0;
                        if (render_ready)
                            state <= S_FETCH_DATA;
                        else
                            state <= S_WAIT_CLEAR;
                    end else begin
                        state <= S_NEXT_DESC;
                    end
                end

                S_WAIT_CLEAR: begin
                    if (render_ready)
                        state <= S_FETCH_DATA;
                end

                // --- Issue DDR3 BL8 Burst Read for Sprite Pixels ---
                S_FETCH_DATA: begin
                    if (stream_ack) begin
                        avm_address <= cur_line_data_addr + (burst_cnt * 32);
                        avm_read    <= 1'b1;
                        if (avm_read && !avm_waitrequest) begin
                            avm_read <= 1'b0;
                            beat_cnt <= 2'd0;
                            state    <= S_STREAM_DATA;
                        end
                    end
                end

                // --- Stream DDR3 Burst Beats (4x 64-Bit Words) ---
                S_STREAM_DATA: begin
                    if (avm_readdatavalid) begin
                        if (zero_skip_en && avm_readdata == 64'h0) begin
                            // 1-Cycle Zero-Word-Skip!
                            if (beat_cnt == 2'd3) begin
                                if (burst_cnt + 12'd1 >= bursts_needed) begin
                                    state <= S_NEXT_DESC;
                                end else begin
                                    burst_cnt <= burst_cnt + 12'd1;
                                    state     <= S_FETCH_DATA;
                                end
                            end else begin
                                beat_cnt <= beat_cnt + 1'b1;
                            end
                        end else begin
                            stream_word64 <= avm_readdata;
                            stream_valid  <= 1'b1;
                            if (beat_cnt == 2'd3) begin
                                if (burst_cnt + 12'd1 >= bursts_needed) begin
                                    state <= S_NEXT_DESC;
                                end else begin
                                    burst_cnt <= burst_cnt + 12'd1;
                                    state     <= S_FETCH_DATA;
                                end
                            end else begin
                                beat_cnt <= beat_cnt + 1'b1;
                            end
                        end
                    end
                end

                // --- Advance to Next 16-Byte Descriptor ---
                S_NEXT_DESC: begin
                    sprite_active <= 1'b0;
                    cur_desc_addr <= cur_desc_addr + 32'd16;
                    state         <= S_FETCH_DESC0;
                end

                S_DONE: begin
                    sprite_active <= 1'b0;
                    line_done     <= 1'b1;
                    state         <= S_IDLE;
                end
            endcase
        end
    end

endmodule
