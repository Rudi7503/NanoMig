// ====================================================================
//
//  sprite_engine_capture.v
//  NanoMig Sprite Engine Diagnostic Scanline Raw Pixel Capture Buffer
//
//  Allows Amiga CPU to read back bit-accurate 24-bit RGB pixel data
//  directly from FPGA without needing video grabber hardware.
//
//  Port A (Write, clk_vid):
//    - Captures final composited out_rgb (24-bit) during active scanline
//    - Sets cap_done at actual scanline end (falling edge of vid_read_en or Y change)
//
//  Port B (Read, clk_sys):
//    - Amiga CPU readback via registers SPRENG_CAP_ADDR / SPRENG_CAP_DATA
//    - Hardware auto-increment on low-word read with bus transfer strobe
//
// ====================================================================

`timescale 1ns / 1ps

module sprite_engine_capture (
    input  wire        rst_n,

    // Video Write Domain (clk_vid)
    input  wire        clk_vid,
    input  wire        capture_en,
    input  wire signed [11:0] cur_y,
    input  wire signed [11:0] cap_y,
    input  wire [10:0] vid_x,
    input  wire        vid_read_en,
    input  wire [23:0] out_rgb,
    output reg         cap_done,

    // Amiga CPU Read Domain (clk_sys)
    input  wire        clk_sys,
    input  wire        reg_cs,
    input  wire        reg_we,
    input  wire [3:0]  reg_addr,        // 9=CAP_LINE, 10=CAP_ADDR, 11=CAP_DATA_H, 12=CAP_DATA_L
    input  wire [15:0] reg_wdata,
    output reg  [15:0] reg_rdata,
    output reg  signed [11:0] cap_target_line
);

    // 2048 x 24-bit True Dual-Port Block RAM
    (* ramstyle = "no_rw_check" *) reg [23:0] cap_mem [0:2047];

    reg [10:0] read_addr;
    reg [23:0] read_rgb;

    // Capture Write Logic (clk_vid)
    wire line_match = (cur_y == cap_target_line);
    reg line_capturing;

    always @(posedge clk_vid or negedge rst_n) begin
        if (!rst_n) begin
            cap_done       <= 1'b0;
            line_capturing <= 1'b0;
        end else begin
            if (capture_en && line_match && vid_read_en) begin
                cap_mem[vid_x] <= out_rgb;
                line_capturing <= 1'b1;
                if (vid_x == 11'd2047) begin
                    cap_done <= 1'b1;
                end
            end else if (line_capturing && (!vid_read_en || !line_match)) begin
                cap_done       <= 1'b1;
                line_capturing <= 1'b0;
            end else if (!capture_en) begin
                cap_done       <= 1'b0;
                line_capturing <= 1'b0;
            end
        end
    end

    // CPU Read & Control Logic (clk_sys)
    reg        reg_cs_d;
    reg        reg_we_d;
    reg [3:0]  reg_addr_d;
    reg        low_active;
    reg        snap_valid;
    reg [23:0] snap_rgb;

    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            reg_cs_d   <= 1'b0;
            reg_we_d   <= 1'b0;
            reg_addr_d <= 4'd0;
        end else begin
            reg_cs_d   <= reg_cs;
            reg_we_d   <= reg_we;
            reg_addr_d <= reg_addr;
        end
    end

    wire transfer_start = (reg_cs && !reg_cs_d) || (reg_cs && (reg_addr != reg_addr_d || reg_we != reg_we_d));
    wire low_transfer_end = low_active && (!reg_cs || reg_we || (reg_addr != 4'd12));

    always @(posedge clk_sys or negedge rst_n) begin
        if (!rst_n) begin
            cap_target_line <= 12'sd0;
            read_addr       <= 11'd0;
            read_rgb        <= 24'h000000;
            snap_rgb        <= 24'h000000;
            snap_valid      <= 1'b0;
            low_active      <= 1'b0;
        end else begin
            read_rgb <= cap_mem[read_addr];

            if (reg_cs && reg_we) begin
                low_active <= 1'b0;
                case (reg_addr)
                    4'd9:  cap_target_line <= reg_wdata[11:0];
                    4'd10: begin
                        read_addr  <= reg_wdata[10:0];
                        snap_valid <= 1'b0;
                    end
                    default: ;
                endcase
            end else begin
                if (transfer_start && !reg_we) begin
                    if (reg_addr == 4'd11) begin
                        // HI-Read starts: capture 24-bit snapshot from valid synchronous RAM output
                        snap_rgb   <= read_rgb;
                        snap_valid <= 1'b1;
                        low_active <= 1'b0;
                    end else if (reg_addr == 4'd12) begin
                        // LOW-Read starts
                        low_active <= 1'b1;
                        if (!snap_valid) begin
                            // LOW without preceding HI: capture once and hold
                            snap_rgb   <= read_rgb;
                            snap_valid <= 1'b1;
                        end
                    end
                end

                if (low_transfer_end) begin
                    low_active <= 1'b0;
                    read_addr  <= read_addr + 11'd1;
                    snap_valid <= 1'b0;
                end
            end
        end
    end

    // Read Mux
    always @(*) begin
        case (reg_addr)
            4'd9:  reg_rdata = {4'd0, cap_target_line};
            4'd10: reg_rdata = {5'd0, read_addr};
            4'd11: reg_rdata = {8'h00, (snap_valid ? snap_rgb[23:16] : read_rgb[23:16])}; // Red
            4'd12: reg_rdata = (snap_valid ? snap_rgb[15:0] : read_rgb[15:0]);           // Green/Blue
            default: reg_rdata = 16'h0000;
        endcase
    end

endmodule
