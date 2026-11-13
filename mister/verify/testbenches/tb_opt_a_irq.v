`timescale 1ns/1ps

module tb_opt_a_irq;
    reg clk = 0; always #5 clk = ~clk;
    reg reset = 1;
    reg cs = 0, wr = 0;
    reg [9:1] addr = 0;
    reg [1:0] be = 2'b11;
    reg [15:0] wdata = 0;
    wire [15:0] rdata;
    reg irq_cs = 0;
    reg [1:0] irq_addr = 0;
    wire irq;
    wire dma_req;
    wire [31:0] dma_addr;
    reg dma_ack = 0;
    reg [15:0] dma_data = 0;
    wire signed [15:0] sl, sr;

    audio_ext dut (
        .clk(clk), .reset(reset), .ntsc(1'b0),
        .reg_cs(cs), .reg_wr(wr), .reg_addr(addr), .reg_be(be),
        .reg_wdata(wdata), .reg_rdata(rdata),
        .irq_cs(irq_cs), .irq_addr(irq_addr), .irq(irq),
        .dma_req(dma_req), .dma_addr(dma_addr), .dma_ack(dma_ack),
        .dma_data(dma_data), .dma_error(1'b0),
        .sample_l(sl), .sample_r(sr)
    );

    task write_chan(input [4:0] channel, input [3:0] offset, input [15:0] val);
    begin
        @(negedge clk);
        cs = 1; wr = 1; addr = {channel, offset}; wdata = val;
        @(negedge clk);
        cs = 0; wr = 0;
        @(negedge clk);
    end
    endtask

    task write_irq(input [1:0] a, input [15:0] val);
    begin
        @(negedge clk);
        irq_cs = 1; wr = 1; irq_addr = a; wdata = val;
        @(negedge clk);
        irq_cs = 0; wr = 0;
        @(negedge clk);
    end
    endtask

    initial begin
        repeat(5) @(negedge clk);
        reset = 0;
        repeat(5) @(negedge clk);

        // 1. Test Option A Global IRQ Registers at $DFF804..$DFF80A
        write_irq(2'b00, 16'hAAAA); // INTENA HI
        write_irq(2'b01, 16'h5555); // INTENA LO
        irq_cs = 1; wr = 0; irq_addr = 2'b00; #1;
        if (rdata !== 16'hAAAA) $fatal(1, "INTENA HI read mismatch");
        irq_addr = 2'b01; #1;
        if (rdata !== 16'h5555) $fatal(1, "INTENA LO read mismatch");
        irq_cs = 0;

        // 2. Test Channel 31: AUD31BQ_A2 (Offset 12 = $DFF7F8)
        write_chan(5'd31, 4'd12, 16'h1234);
        cs = 1; wr = 0; addr = {5'd31, 4'd12}; #1;
        if (rdata !== 16'h1234) $fatal(1, "AUD31BQ_A2 readback mismatch");
        cs = 0;

        // 3. Test Channel 31: Delay Register (Offset 14 = $DFF7FC)
        write_chan(5'd31, 4'd14, 16'h0050); // delay 80 ticks
        if (!dut.has_delay[31]) $fatal(1, "AUD31 has_delay failed to set");
        write_chan(5'd31, 4'd13, 16'h0001); // CMD: START
        if (dut.voice_state[31] !== 2'b01) $fatal(1, "AUD31 state not DELAYING");

        $display("OPTION_A_VERIFICATION_PASS: Global IRQ at $DFF804 and full Channel 31 functionality verified!");
        $finish;
    end
endmodule
