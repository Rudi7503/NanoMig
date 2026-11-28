`timescale 1ns/1ps

module tb_test_bypass;
    reg clk = 0;
    always #17.6 clk = ~clk; // 28.375 MHz

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
    reg [15:0] audio_dma_data = 16'sh4000;
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

    // Simple DMA responder
    always @(posedge clk) begin
        if (audio_dma_req && !audio_dma_ack) begin
            audio_dma_ack <= 1'b1;
            audio_dma_data <= 16'sh4000; // Positive constant sample
        end else begin
            audio_dma_ack <= 1'b0;
        end
    end

    task write_reg(input [4:0] ch, input [3:0] off, input [15:0] val);
        begin
            @(negedge clk);
            reg_cs = 1; reg_wr = 1;
            reg_addr = {ch, off};
            reg_wdata = val;
            repeat(3) @(negedge clk);
            reg_cs = 0; reg_wr = 0;
            repeat(2) @(negedge clk);
        end
    endtask

    integer v;
    initial begin
        $display("=== STARTING BYPASS VS FILTER TESTBENCH ===");
        reset = 1;
        repeat(20) @(posedge clk);
        reset = 0;
        repeat(20) @(posedge clk);

        // Initialize all 32 voices
        for (v = 0; v < 32; v = v + 1) begin
            write_reg(v, 13, 16'h0002); // CMD = STOP
            write_reg(v, 4,  16'h0000); // VOL = 0
            write_reg(v, 0,  16'h0000); // PTRH
            write_reg(v, 1,  16'h1000); // PTRL
            write_reg(v, 2,  16'h0000); // LENH
            write_reg(v, 3,  16'h0000); // LENL
            write_reg(v, 5,  16'd521);  // PER
            write_reg(v, 6,  16'h0005); // CTRL
        end

        // 1. Setup Voice 0: NO FILTER (AUD_CTRL = 16BIT | STEREO = 0x0005)
        write_reg(0, 3,  16'h03C0); // LENL = 960 bytes
        write_reg(0, 4,  16'hFFFF); // VOL = 100%
        write_reg(0, 6,  16'h0005); // CTRL = 16BIT | STEREO (NO FILTER!)
        write_reg(0, 13, 16'h0001); // CMD = START

        // Run for 10000 cycles
        repeat(10000) @(posedge clk);
        $display("NO FILTER (CTRL=0x0005): sample_l = %0d, sample_r = %0d", sample_l, sample_r);

        // 2. Now enable FILTER on Voice 0 (AUD_CTRL = 16BIT | STEREO | FILTER = 0x0185)
        write_reg(0, 8,  16'h0006); // BQ_B0
        write_reg(0, 9,  16'h000C); // BQ_B1
        write_reg(0, 10, 16'h0006); // BQ_B2
        write_reg(0, 11, 16'h838E); // BQ_A1
        write_reg(0, 12, 16'h3C8B); // BQ_A2
        write_reg(0, 6,  16'h0185); // CTRL = 16BIT | STEREO | FILTER

        repeat(10000) @(posedge clk);
        $display("WITH FILTER (CTRL=0x0185): sample_l = %0d, sample_r = %0d", sample_l, sample_r);

        $finish;
    end
endmodule
