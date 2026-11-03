// SPDX-License-Identifier: GPL-3.0-or-later
// ==============================================================================
// MiSTer FPGA Minimig-AGA: Dedicated Audio DMA Master (Full 32-bit Memory Access)
// Independent direct DDR3 Fast-RAM (114 MHz) and SDRAM (Chip/Slow) access without Agnus.
// ==============================================================================

module audio_dma_master (
    input  wire        clk,            // System clock (clk_sys, 28.375 MHz)
    input  wire        reset,          // System reset
    input  wire        c_7m,           // 7.09 MHz CCK clock enable

    // Interface to audio_ext (32 channels)
    input  wire        audio_dma_req,
    input  wire [31:0] audio_dma_addr,
    output reg         audio_dma_ack,
    output reg  [15:0] audio_dma_data,
    output reg         audio_dma_error,

    // Memory router configuration for 32-bit Amiga address space
    input  wire        z2ram_ena,
    input  wire [4:0]  z3ram_base0,
    input  wire        z3ram_ena0,
    input  wire [3:0]  z3ram_base1,
    input  wire        z3ram_ena1,

    // Interface to ddram_ctrl (DDR3 Fast-RAM / Zorro RAM, 114 MHz CDC)
    output reg  [28:1] ddr_addr,
    output reg         ddr_cs,
    output wire        ddr_we,
    output wire        ddr_l,
    output wire        ddr_u,
    output wire [15:0] ddr_wr,
    input  wire        ddr_ack,
    input  wire [15:0] ddr_rd,

    // Interface to sdram_ctrl (SDRAM ChipRAM / SlowRAM)
    output reg  [24:1] sdr_addr,
    output reg         sdr_claim,
    input  wire [15:0] sdr_rd
);

    // ==========================================================================
    // Full 32-bit Address Translation via Memory Router
    // ==========================================================================
    wire [28:1] router_ramaddr;
    wire        sel_chipram, sel_kickram, sel_kicklower;
    wire        sel_z2ram, sel_z3ram0, sel_z3ram1, sel_zram, sel_dd, sel_rtg;

    memory_router u_audio_router (
        .cpu_addr      (audio_dma_addr),
        .cchip         (1'b0),
        .ckick         (1'b0),
        .wr            (1'b0),
        .bootrom       (1'b0),
        .cdtv_mode     (1'b0),
        .z2ram_ena     (z2ram_ena),
        .z3ram_base0   (z3ram_base0),
        .z3ram_ena0    (z3ram_ena0),
        .z3ram_base1   (z3ram_base1),
        .z3ram_ena1    (z3ram_ena1),
        .sel_chipram   (sel_chipram),
        .sel_kickram   (sel_kickram),
        .sel_kicklower (sel_kicklower),
        .sel_z2ram     (sel_z2ram),
        .sel_z3ram0    (sel_z3ram0),
        .sel_z3ram1    (sel_z3ram1),
        .sel_zram      (sel_zram),
        .sel_dd        (sel_dd),
        .sel_rtg       (sel_rtg),
        .ramaddr       (router_ramaddr)
    );

    wire is_ddr = |router_ramaddr[28:26]; // Zorro II FastRAM, Zorro III FastRAM, RTG
    wire addr_error = audio_dma_addr[0] | (|audio_dma_addr[31:24] & ~is_ddr);

    // Static DDR control signals (Audio is always 16-bit word read)
    assign ddr_we = 1'b0;  // 0 = Read
    assign ddr_l  = 1'b0;  // active low (lower byte enabled)
    assign ddr_u  = 1'b0;  // active low (upper byte enabled)
    assign ddr_wr = 16'd0;

    // ==========================================================================
    // Clock Domain Crossing (114 MHz ddram_ctrl -> 28 MHz clk_sys)
    // ==========================================================================
    reg ddr_ack_s1, ddr_ack_s2;
    always @(posedge clk) begin
        if (reset) begin
            ddr_ack_s1 <= 1'b0;
            ddr_ack_s2 <= 1'b0;
        end else begin
            ddr_ack_s1 <= ddr_ack;
            ddr_ack_s2 <= ddr_ack_s1;
        end
    end
    wire ddr_ack_safe = ddr_ack_s2;

    reg c_7m_d;
    always @(posedge clk) c_7m_d <= c_7m;
    wire c_7m_rise = c_7m & ~c_7m_d;

    // ==========================================================================
    // State Machine
    // ==========================================================================
    localparam [2:0]
        S_IDLE      = 3'd0,
        S_DDR_WAIT  = 3'd1,
        S_SDR_ARM   = 3'd2,
        S_SDR_READ  = 3'd3,
        S_ACK       = 3'd4,
        S_DRAIN     = 3'd5;

    reg [2:0] state;
    reg [2:0] slot_cnt;

    always @(posedge clk) begin
        if (reset) begin
            state           <= S_IDLE;
            slot_cnt        <= 3'd0;
            audio_dma_ack   <= 1'b0;
            audio_dma_data  <= 16'd0;
            audio_dma_error <= 1'b0;
            ddr_cs          <= 1'b0;
            ddr_addr        <= 28'd0;
            sdr_claim       <= 1'b0;
            sdr_addr        <= 24'd0;
        end else begin
            audio_dma_ack   <= 1'b0;
            audio_dma_error <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (audio_dma_req) begin
                        if (addr_error) begin
                            audio_dma_data  <= 16'd0;
                            audio_dma_error <= 1'b1;
                            state           <= S_ACK;
                        end else if (is_ddr) begin
                            // Direct DDR3 Fast-RAM: Zero Agnus overhead, 114 MHz burst
                            ddr_addr <= router_ramaddr;
                            ddr_cs   <= 1'b1;
                            state    <= S_DDR_WAIT;
                        end else begin
                            // Direct SDRAM: ChipRAM / SlowRAM
                            sdr_addr <= {1'b0, audio_dma_addr[23:1]};
                            state    <= S_SDR_ARM;
                        end
                    end
                end

                S_DDR_WAIT: begin
                    if (ddr_ack_safe) begin
                        audio_dma_data <= ddr_rd;
                        ddr_cs         <= 1'b0;
                        state          <= S_ACK;
                    end
                end

                S_SDR_ARM: begin
                    if (c_7m_rise) begin
                        sdr_claim <= 1'b1;
                        slot_cnt  <= 3'd0;
                        state     <= S_SDR_READ;
                    end
                end

                S_SDR_READ: begin
                    slot_cnt <= slot_cnt + 3'd1;
                    if (slot_cnt == 3'd3) begin
                        audio_dma_data <= sdr_rd;
                        sdr_claim      <= 1'b0;
                        state          <= S_ACK;
                    end
                end

                S_ACK: begin
                    audio_dma_ack <= 1'b1;
                    state         <= S_DRAIN;
                end

                S_DRAIN: begin
                    if (!audio_dma_req && !ddr_ack_safe) begin
                        state <= S_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
