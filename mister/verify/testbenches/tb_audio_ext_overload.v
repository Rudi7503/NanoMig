// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ps

module tb_audio_ext_overload;
    reg clk = 0;
    always #17.62 clk = ~clk; // 28.375 MHz

    reg reset = 1;
    reg reg_cs = 0, reg_wr = 0;
    reg [9:1] reg_addr = 0;
    reg [1:0] reg_be = 2'b11;
    reg [15:0] reg_wdata = 0;
    wire [15:0] ext_rdata;
    wire ext_irq;

    wire audio_dma_req;
    wire [31:0] audio_dma_addr;
    reg audio_dma_ack = 0;
    reg [15:0] audio_dma_data = 16'sh7000; // Large positive sample
    wire signed [15:0] sample_l, sample_r;

    audio_ext u_ext (
        .clk(clk),
        .reset(reset),
        .ntsc(1'b0),
        .reg_cs(reg_cs),
        .reg_wr(reg_wr),
        .reg_addr(reg_addr),
        .reg_be(reg_be),
        .reg_wdata(reg_wdata),
        .reg_rdata(ext_rdata),
        .irq(ext_irq),
        .irq_cs(1'b0),
        .irq_addr(2'b00),
        .dma_req(audio_dma_req),
        .dma_addr(audio_dma_addr),
        .dma_ack(audio_dma_ack),
        .dma_data(audio_dma_data),
        .dma_error(1'b0),
        .sample_l(sample_l),
        .sample_r(sample_r)
    );

    // Fast DMA responder supplying constant high-amplitude sample 0x7000 (28672)
    always @(posedge clk) begin
        if (audio_dma_req && !audio_dma_ack) begin
            audio_dma_ack <= 1'b1;
            audio_dma_data <= 16'sh7000;
        end else begin
            audio_dma_ack <= 1'b0;
        end
    end

    task write_reg(input [4:0] ch, input integer byteaddr, input [15:0] val);
        begin
            @(negedge clk);
            reg_cs = 1; reg_wr = 1;
            reg_addr = (byteaddr + 32 * ch) >> 1;
            reg_wdata = val;
            repeat(3) @(negedge clk);
            reg_cs = 0; reg_wr = 0;
            repeat(2) @(negedge clk);
        end
    endtask

    task read_reg(input [4:0] ch, input integer byteaddr, output [15:0] rval);
        begin
            @(negedge clk);
            reg_cs = 1; reg_wr = 0;
            reg_addr = (byteaddr + 32 * ch) >> 1;
            repeat(3) @(negedge clk);
            rval = ext_rdata;
            reg_cs = 0;
            repeat(2) @(negedge clk);
        end
    endtask

    integer v;
    reg signed [15:0] max_peak = 0;
    integer hard_clips = 0;
    reg [15:0] status_val;

    initial begin
        $display("==================================================================");
        $display("SIMULATION: 16-VOICE OVERLOAD ON AUDIO_EXT WITH AGC LIMITER");
        $display("==================================================================");

        reset = 1;
        repeat(20) @(posedge clk);
        reset = 0;
        repeat(20) @(posedge clk);

        // Configure 16 voices, all playing 0x7000 at maximum volume (VOL = 0xFFFF)
        // Byte 0: PTRH, Byte 2: PTRL, Byte 4: LENH, Byte 6: LENL
        // Byte 8: VOL, Byte 10: PER, Byte 12: CTRL, Byte 26: CMD
        for (v = 0; v < 32; v = v + 1) begin
            write_reg(v, 26, 16'h0002); // CMD = STOP
            write_reg(v, 8,  (v < 16) ? 16'hFFFF : 16'h0000); // 16 voices at 100% volume
            write_reg(v, 0,  16'h0000); // PTRH
            write_reg(v, 2,  16'h1000); // PTRL
            write_reg(v, 4,  16'h0000); // LENH
            write_reg(v, 6,  (v < 16) ? 16'h8000 : 16'h0000); // LENL = 32 KB
            write_reg(v, 10, 16'd521);  // PER = 48 kHz
            write_reg(v, 12, 16'h0001); // CTRL = 16-bit signed PCM
        end

        // Start all 16 voices simultaneously
        for (v = 0; v < 16; v = v + 1) begin
            write_reg(v, 26, 16'h0001); // CMD = START
        end

        // Monitor 200,000 cycles (~7 ms of audio, covering ~350 samples at 48 kHz)
        for (v = 0; v < 200000; v = v + 1) begin
            @(posedge clk);
            if (sample_l > max_peak) max_peak = sample_l;
            if (sample_l >= 16'sh7FFF || sample_l <= -16'sh8000) hard_clips = hard_clips + 1;
        end

        // Read MMIO diagnostic status register at voice 31 offset 15 ($DFF7FE)
        read_reg(31, 30, status_val);

        $display("voice_state[0]=%b acc_l=%d mul_l=%d new_pcm=%d v_silent=%b vol_factor_l=%d", u_ext.voice_state[0], u_ext.acc_l, u_ext.mul_l, u_ext.new_pcm, u_ext.v_silent, u_ext.vol_factor_l);
        $display("Unconstrained Sum: ~458,752 (+23 dB overload)");
        $display("Max Output Peak:   %0d (Target Ceiling = 30,720)", max_peak);
        $display("Hard Clips:        %0d", hard_clips);
        $display("MMIO $DFF7FE:      0x%04X (Bit 15 AGC Active = %0d)", status_val, status_val[15]);

        if (max_peak <= 30720 && hard_clips == 0 && status_val[15] == 1) begin
            $display(">>> [SUCCESS] 16-VOICE OVERLOAD FULLY & CLEANLY LIMITED BY AGC! <<<");
        end else begin
            $display(">>> [FAILURE] Overload was not contained cleanly! <<<");
            $stop;
        end

        $finish;
    end

endmodule
