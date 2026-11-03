`timescale 1ns/1ps

module tb_rechteck_sim;
    reg clk = 0;
    always #17.6 clk = ~clk;

    reg reset = 1;
    reg cs = 0, wr = 0;
    reg [9:1] addr = 0;
    reg [1:0] be = 2'b11;
    reg [15:0] wdata = 0;
    wire [15:0] rdata;
    wire irq;

    wire dma_req;
    wire [31:0] dma_addr;
    reg dma_ack = 0;
    reg [15:0] dma_data = 16'h1FFF;

    wire signed [15:0] sample_l, sample_r;

    audio_ext dut (
        .clk(clk),
        .reset(reset),
        .ntsc(1'b0),
        .reg_cs(cs),
        .reg_wr(wr),
        .reg_addr(addr),
        .reg_be(be),
        .reg_wdata(wdata),
        .reg_rdata(rdata),
        .irq(irq),
        .irq_cs(1'b0),
        .irq_addr(2'b00),
        .dma_req(dma_req),
        .dma_addr(dma_addr),
        .dma_ack(dma_ack),
        .dma_data(dma_data),
        .dma_error(1'b0),
        .sample_l(sample_l),
        .sample_r(sample_r)
    );

    integer dma_count = 0;
    always @(posedge clk) begin
        dma_ack <= 0;
        if (dma_req && !dma_ack) begin
            dma_ack <= 1;
            // square wave alternating +0x1FFF and -0x1FFF
            dma_data <= (dma_count[4]) ? 16'h1FFF : -16'sh1FFF;
            dma_count <= dma_count + 1;
        end
    end

    task wreg(input integer voice, input integer byteaddr, input [15:0] value);
        begin
            @(negedge clk);
            cs = 1; wr = 1;
            addr = (byteaddr + 32 * voice) >> 1;
            wdata = value;
            repeat(3) @(negedge clk);
            cs = 0; wr = 0;
            repeat(3) @(negedge clk);
        end
    endtask

    integer v;
    initial begin
        reset = 1;
        repeat(10) @(posedge clk);
        reset = 0;
        repeat(20) @(posedge clk);

        for (v = 0; v < 32; v = v + 1) begin
            wreg(v, 26, 16'h0002); // CMD = STOP
            wreg(v, 8,  16'h0000); // VOL = 0
            wreg(v, 0,  16'h0000); // PTRH
            wreg(v, 2,  16'h1000); // PTRL
            wreg(v, 4,  16'h0000); // LENH
            wreg(v, 6,  (v == 0) ? 16'h2580 : 16'h0000); // ONLY VOICE 0 HAS DMA LEN!
            wreg(v, 10, 16'd521);  // PER
            wreg(v, 16, 16'h0006); // BQ_B0
            wreg(v, 18, 16'h000C); // BQ_B1
            wreg(v, 20, 16'h0006); // BQ_B2
            wreg(v, 22, 16'h838E); // BQ_A1
            wreg(v, 24, 16'h3C8B); // BQ_A2
            if (v == 0)
                wreg(v, 12, 16'h0185); // Root: 16BIT | STEREO | FILTER
            else
                wreg(v, 12, 16'h0385); // Chain
        end

        for (v = 0; v < 32; v = v + 1) wreg(v, 26, 16'h0001); // CMD = START
        wreg(31, 8, 16'h8080); // Voice 31 VOL

        repeat(100000) @(posedge clk);

        $display("FINAL STATUS:");
        $display("voice_state[0] = %b, voice_state[31] = %b", dut.voice_state[0], dut.voice_state[31]);
        $display("sample_l = %d, sample_r = %d", sample_l, sample_r);
        $finish;
    end

    integer nonzero_samples = 0;
    always @(posedge clk) begin
        if (sample_l != 0 || sample_r != 0) begin
            nonzero_samples = nonzero_samples + 1;
            if (nonzero_samples < 10) begin
                $display("[Sample #%0d] L = %d, R = %d", nonzero_samples, sample_l, sample_r);
            end
        end
    end
endmodule
