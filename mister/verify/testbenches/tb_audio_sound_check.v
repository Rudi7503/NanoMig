`timescale 1ns/1ps

module tb_audio_sound_check;
    reg clk_sys = 0;
    always #17.6 clk_sys = ~clk_sys; // 28.375 MHz

    reg clk_7m = 0;
    always #70.5 clk_7m = ~clk_7m; // 7.09 MHz

    reg reset = 1;

    // CPU register bus for audio_ext
    reg reg_cs = 0, reg_wr = 0;
    reg [9:1] reg_addr = 0;
    reg [1:0] reg_be = 2'b11;
    reg [15:0] reg_wdata = 0;
    wire [15:0] ext_rdata;
    wire ext_irq;

    // Wires between audio_ext and audio_dma_master
    wire audio_dma_req, audio_dma_ack, audio_dma_error;
    wire [31:0] audio_dma_addr;
    wire [15:0] audio_dma_data;
    wire signed [15:0] sample_l, sample_r;

    // Wires between audio_dma_master and chipdma_arb
    wire chip_dma_req, chip_dma_ack, chip_dma_error;
    wire [31:0] chip_dma_addr;
    wire [15:0] chip_dma_data;

    wire [28:1] audio_ddr_addr;
    wire audio_ddr_cs, audio_ddr_we, audio_ddr_l, audio_ddr_u;
    wire [15:0] audio_ddr_wr;

    wire [24:1] arb_chip_addr;
    wire arb_chip_l, arb_chip_u, arb_chip_rw, arb_chip_dma;
    wire [15:0] arb_chip_wr;
    reg [15:0] sram_data_out = 16'h55AA;

    reg _ram_oe = 1;
    reg _ram_we = 1;

    audio_ext u_audio_ext (
        .clk(clk_sys),
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
        .dma_error(audio_dma_error),
        .sample_l(sample_l),
        .sample_r(sample_r)
    );

    audio_dma_master u_dma_master (
        .clk(clk_sys),
        .reset(reset),
        .audio_dma_req(audio_dma_req),
        .audio_dma_addr(audio_dma_addr),
        .audio_dma_ack(audio_dma_ack),
        .audio_dma_data(audio_dma_data),
        .audio_dma_error(audio_dma_error),
        .z2ram_ena(1'b0),
        .z3ram_base0(5'd0),
        .z3ram_ena0(1'b0),
        .z3ram_base1(4'd0),
        .z3ram_ena1(1'b0),
        .ddr_addr(audio_ddr_addr),
        .ddr_cs(audio_ddr_cs),
        .ddr_we(audio_ddr_we),
        .ddr_l(audio_ddr_l),
        .ddr_u(audio_ddr_u),
        .ddr_wr(audio_ddr_wr),
        .ddr_ack(1'b0),
        .ddr_rd(16'd0),
        .chip_dma_req(chip_dma_req),
        .chip_dma_addr(chip_dma_addr),
        .chip_dma_ack(chip_dma_ack),
        .chip_dma_data(chip_dma_data),
        .chip_dma_error(chip_dma_error)
    );

    chipdma_arb u_chipdma (
        .clk(clk_sys),
        .reset(reset),
        .c_7m(clk_7m),
        .chip_in_addr(24'd0),
        .chip_in_l(1'b1),
        .chip_in_u(1'b1),
        .chip_in_rw(_ram_we),
        .chip_in_dma(_ram_oe),
        .chip_in_wr(16'd0),
        .chip_in_long(1'b0),
        .chip_in_wr2(16'd0),
        .akiko_dma_req(1'b0),
        .akiko_dma_we(1'b0),
        .akiko_dma_baddr(24'd0),
        .akiko_dma_wbyte(8'd0),
        .akiko_dma_rbyte(),
        .akiko_dma_ack(),
        .akiko_arm(),
        .cdtv_dma_req(1'b0),
        .cdtv_dma_we(1'b0),
        .cdtv_dma_baddr(32'd0),
        .cdtv_dma_wbyte(8'd0),
        .cdtv_dma_rbyte(),
        .cdtv_dma_ack(),
        .audio_dma_req(chip_dma_req),
        .audio_dma_addr(chip_dma_addr),
        .audio_dma_data(chip_dma_data),
        .audio_dma_ack(chip_dma_ack),
        .audio_dma_error(chip_dma_error),
        .chip_out_addr(arb_chip_addr),
        .sdram_addon_addr(),
        .sdram_addon_claim(),
        .chip_out_l(arb_chip_l),
        .chip_out_u(arb_chip_u),
        .chip_out_rw(arb_chip_rw),
        .chip_out_dma(arb_chip_dma),
        .chip_out_wr(arb_chip_wr),
        .chip_out_long(),
        .chip_out_wr2(),
        .chip_in_rd(sram_data_out),
        .z2ram_ena(1'b0),
        .z3ram_base0(5'd0),
        .z3ram_ena0(1'b0),
        .z3ram_base1(4'd0),
        .z3ram_ena1(1'b0),
        .ddr_out_addr(),
        .ddr_out_l(),
        .ddr_out_u(),
        .ddr_out_we(),
        .ddr_out_cs(),
        .ddr_out_wr(),
        .ddr_in_ack(1'b0),
        .ddr_in_rd(16'd0)
    );

    task write_ext_reg(input integer voice, input integer byteaddr, input [15:0] val);
        begin
            @(negedge clk_sys);
            reg_cs = 1; reg_wr = 1;
            reg_addr = (byteaddr + 32 * voice) >> 1;
            reg_wdata = val;
            repeat(3) @(negedge clk_sys);
            reg_cs = 0; reg_wr = 0;
            repeat(2) @(negedge clk_sys);
        end
    endtask

    // 200 Hz Square wave generator in Chip-RAM (48 kHz / 200 Hz = 240 samples per period: 120 high, 120 low)
    integer dma_ack_count = 0;
    always @(posedge clk_sys) begin
        if (audio_dma_ack) begin
            dma_ack_count <= dma_ack_count + 1;
            // High = +0x6000, Low = -0x6000 (standard 16-bit audio amplitude)
            sram_data_out <= ((dma_ack_count % 240) < 120) ? 16'sh6000 : -16'sh6000;
        end
    end

    // Track audio output samples
    integer sample_count = 0;
    integer min_sample = 32767;
    integer max_sample = -32768;
    integer zero_crossings = 0;
    reg signed [15:0] prev_sample = 0;

    always @(posedge clk_sys) begin
        if (!reset && u_audio_ext.cur_voice == 0) begin
            sample_count <= sample_count + 1;
            if (sample_l < min_sample) min_sample <= sample_l;
            if (sample_l > max_sample) max_sample <= sample_l;
            if ((prev_sample < 0 && sample_l >= 0) || (prev_sample >= 0 && sample_l < 0)) begin
                zero_crossings <= zero_crossings + 1;
            end
            prev_sample <= sample_l;

            // Print first 20 samples once signal starts
            if (sample_count >= 1500 && sample_count < 1520) begin
                $display("Sample #%0d: L = %6d, R = %6d", sample_count, sample_l, sample_r);
            end
        end
    end

    integer v;
    initial begin
        $display("=== SIMULATION: TON-AUSGABE DER 32-STUFIGEN KASKADE ===");
        reset = 1;
        repeat(20) @(posedge clk_sys);
        reset = 0;
        repeat(20) @(posedge clk_sys);

        // 1. Setup Voices 0..31 wie in rechteck.s
        for (v = 0; v < 32; v = v + 1) begin
            write_ext_reg(v, 26, 16'h0002); // CMD = STOP
            write_ext_reg(v, 8,  (v == 31) ? 16'h8080 : 16'h0000); // Nur Voice 31 hat Volume!
            write_ext_reg(v, 0,  16'h0004); // PTRH
            write_ext_reg(v, 2,  16'h1000); // PTRL
            write_ext_reg(v, 4,  16'h0000); // LENH
            write_ext_reg(v, 6,  (v == 0) ? 16'h03C0 : 16'h0000); // Voice 0 spielt 960 Bytes / 480 Words
            write_ext_reg(v, 10, 16'd521);  // PER = 48 kHz
            write_ext_reg(v, 16, 16'h0006); // BQ_B0
            write_ext_reg(v, 18, 16'h000C); // BQ_B1
            write_ext_reg(v, 20, 16'h0006); // BQ_B2
            write_ext_reg(v, 22, 16'h838E); // BQ_A1
            write_ext_reg(v, 24, 16'h3C8B); // BQ_A2
            if (v == 0)
                write_ext_reg(v, 12, 16'h0185); // Root: 16BIT | STEREO | FILTER
            else
                write_ext_reg(v, 12, 16'h0585); // Chain: 16BIT | STEREO | FILTER | CHAIN_POST
        end

        // 2. Start all voices
        for (v = 0; v < 32; v = v + 1) write_ext_reg(v, 26, 16'h0001); // CMD = START

        // Run for 1.000.000 cycles (~35 ms of audio, enough for 32 stages group delay ~17 ms)
        repeat(1000000) @(posedge clk_sys);

        $display("\n=== ERGEBNIS DER TON-AUSWERTUNG ===");
        $display("  Gesamtzahl Audio-Samples ausgegeben: %0d", sample_count);
        $display("  DMA Transfers aus Chip-RAM:          %0d", dma_ack_count);
        $display("  Minimale Amplitude (Peak-Min):       %0d", min_sample);
        $display("  Maximale Amplitude (Peak-Max):       %0d", max_sample);
        $display("  Peak-to-Peak Amplitude:              %0d", max_sample - min_sample);
        $display("  Anzahl Nulldurchgaenge:              %0d", zero_crossings);

        if (max_sample - min_sample > 100) begin
            $display(">>> BESTAETIGT: ECHTER HOERBARER TON WIRD ERZEUGT! (Amplitude: %0d) <<<", max_sample - min_sample);
        end else begin
            $display(">>> FEHLER: Kein ausreichender Tonpegel vorhanden! <<<");
        end

        $finish;
    end
endmodule
