`timescale 1ns/1ps

module tb_audio_dma_sys;
    reg clk_sys = 0;
    always #17.6 clk_sys = ~clk_sys; // 28.375 MHz

    reg clk_7m = 0;
    always begin
        #70.5 clk_7m = ~clk_7m; // 7.09 MHz
    end

    reg reset = 1;

    // CPU register bus for audio_ext & audio_capture
    reg reg_cs = 0, reg_wr = 0;
    reg [9:1] reg_addr = 0;
    reg [1:0] reg_be = 2'b11;
    reg [15:0] reg_wdata = 0;
    wire [15:0] ext_rdata;
    wire ext_irq;

    // Capture registers ($DFF802)
    reg cap_reg_cs = 0;
    wire [15:0] cap_reg_rdata;
    wire cap_irq;

    // Wires between audio_ext and audio_dma_master
    wire audio_dma_req, audio_dma_ack, audio_dma_error;
    wire [31:0] audio_dma_addr;
    wire [15:0] audio_dma_data;
    wire signed [15:0] sample_l, sample_r;

    // Wires between audio_dma_master and chipdma_arb
    wire chip_dma_req, chip_dma_ack, chip_dma_error;
    wire [31:0] chip_dma_addr;
    wire [15:0] chip_dma_data;

    // DDR wires (unused for Chip-RAM, but present)
    wire [28:1] audio_ddr_addr;
    wire audio_ddr_cs, audio_ddr_we, audio_ddr_l, audio_ddr_u;
    wire [15:0] audio_ddr_wr;

    // chipdma_arb chip bus wires
    wire [24:1] arb_chip_addr;
    wire arb_chip_l, arb_chip_u, arb_chip_rw, arb_chip_dma;
    wire [15:0] arb_chip_wr;
    reg [15:0] sram_data_out = 16'h55AA;

    // Agnus / Minimig RAM control signals (idle when high)
    reg _ram_oe = 1;
    reg _ram_we = 1;

    // Instantiate audio_ext
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

    // Instantiate audio_dma_master
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

    // Instantiate chipdma_arb
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

    // Audio capture strobe divider (48 kHz from 28 MHz)
    reg [9:0] cap_strobe_div = 0;
    reg cap_sample_strobe = 0;
    always @(posedge clk_sys) begin
        if (reset) begin
            cap_strobe_div <= 0;
            cap_sample_strobe <= 0;
        end else begin
            if (cap_strobe_div >= 10'd590) begin
                cap_strobe_div <= 0;
                cap_sample_strobe <= 1;
            end else begin
                cap_strobe_div <= cap_strobe_div + 1;
                cap_sample_strobe <= 0;
            end
        end
    end

    // Instantiate audio_capture
    audio_capture u_capture (
        .clk(clk_sys),
        .reset(reset),
        .sample_strobe(cap_sample_strobe),
        .in_l(sample_l),
        .in_r(sample_r),
        .buf_cs(1'b0),
        .buf_addr(12'd0),
        .buf_rdata(),
        .reg_cs(cap_reg_cs),
        .reg_wr(reg_wr),
        .reg_be(reg_be),
        .reg_wdata(reg_wdata),
        .reg_rdata(cap_reg_rdata),
        .irq(cap_irq)
    );

    // Helper task to write audio_ext register
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

    // Helper task to write capture register ($DFF802)
    task write_cap_reg(input [15:0] val);
        begin
            @(negedge clk_sys);
            cap_reg_cs = 1; reg_wr = 1;
            reg_wdata = val;
            repeat(3) @(negedge clk_sys);
            cap_reg_cs = 0; reg_wr = 0;
            repeat(2) @(negedge clk_sys);
        end
    endtask

    integer v;
    integer dma_ack_count = 0;
    always @(posedge clk_sys) begin
        if (audio_dma_ack) begin
            dma_ack_count <= dma_ack_count + 1;
            // Return alternating square wave samples from simulated Chip-RAM
            sram_data_out <= (dma_ack_count[3]) ? 16'h2000 : -16'sh2000;
        end
    end

    initial begin
        $display("=== STARTING SIMULATION OF AUDIO EXT + DMA MASTER + CHIPDMA + CAPTURE ===");
        reset = 1;
        repeat(20) @(posedge clk_sys);
        reset = 0;
        repeat(20) @(posedge clk_sys);

        // 1. Setup Voices 0..31 like in rechteck.s
        $display("[SIM] Setting up voices 0..31...");
        for (v = 0; v < 32; v = v + 1) begin
            write_ext_reg(v, 26, 16'h0002); // CMD = STOP
            write_ext_reg(v, 8,  16'h0000); // VOL = 0
            // Set sample pointer in Chip-RAM (< $02000000): e.g. $00041000
            write_ext_reg(v, 0,  16'h0004); // PTRH = $0004
            write_ext_reg(v, 2,  16'h1000); // PTRL = $1000
            write_ext_reg(v, 4,  16'h0000); // LENH = 0
            write_ext_reg(v, 6,  (v == 0) ? 16'h0100 : 16'h0000); // LENL = 256 words
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
        $display("[SIM] Starting voices...");
        for (v = 0; v < 32; v = v + 1) write_ext_reg(v, 26, 16'h0001); // CMD = START
        write_ext_reg(31, 8, 16'h8080); // Voice 31 VOL full

        // 3. Start Hardware Capture ($DFF802)
        $display("[SIM] Starting hardware capture with $0017 to $DFF802...");
        write_cap_reg(16'h0017);

        // 4. Run simulation for several milliseconds to see DMA and Capture in action
        $display("[SIM] Running simulation...");
        repeat(50000) @(posedge clk_sys);

        $display("[SIM] Status after 50000 cycles:");
        $display("  audio_dma_req: %b, audio_dma_ack: %b, addr: %h", audio_dma_req, audio_dma_ack, audio_dma_addr);
        $display("  chip_dma_req: %b, chip_dma_ack: %b, chip_addr: %h", chip_dma_req, chip_dma_ack, chip_dma_addr);
        $display("  Total DMA transfers completed: %0d", dma_ack_count);
        $display("  audio_dma_master state: %0d", u_dma_master.state);
        $display("  chipdma_arb state: %0d", u_chipdma.state);
        $display("  sample_l: %d, sample_r: %d", sample_l, sample_r);
        $display("  cap_reg_rdata: %h (capture_en=%b, flag_a=%b, flag_b=%b, pos=%0d)",
                 cap_reg_rdata, cap_reg_rdata[0], cap_reg_rdata[1], cap_reg_rdata[2], cap_reg_rdata[15:6]);

        if (dma_ack_count == 0) begin
            $display(">>> FEHLER: Kein einziger Chip-RAM DMA Transfer durchgefuehrt! <<<");
        end else begin
            $display(">>> ERFOLG: Chip-RAM DMA laeuft! Transfers: %0d <<<", dma_ack_count);
        end

        $finish;
    end

    initial begin
        #5000000;
        $display("TIMEOUT!");
        $finish;
    end
endmodule
