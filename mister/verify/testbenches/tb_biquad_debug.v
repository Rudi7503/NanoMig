`timescale 1ns/1ps

module tb_biquad_debug;
    reg clk = 0;
    always #17.6 clk = ~clk;

    reg reset = 1;
    reg reg_cs = 0, reg_wr = 0;
    reg [7:0] reg_addr = 0;
    reg [1:0] reg_be = 2'b11;
    reg [15:0] reg_wdata = 0;
    wire [15:0] reg_rdata;

    reg [4:0] cur_voice = 0;
    reg filter_en_l = 1, filter_en_r = 0, is_stereo = 0, req_strobe = 0;
    reg signed [15:0] in_pcm_l = 0, in_pcm_r = 0;
    wire signed [15:0] out_pcm_l, out_pcm_r;

    biquad_iir_ringbuffer dut (
        .clk(clk),
        .reset(reset),
        .reg_cs(reg_cs),
        .reg_wr(reg_wr),
        .reg_addr(reg_addr),
        .reg_be(reg_be),
        .reg_wdata(reg_wdata),
        .reg_rdata(reg_rdata),
        .cur_voice(cur_voice),
        .filter_en_l(filter_en_l),
        .filter_en_r(filter_en_r),
        .is_stereo(is_stereo),
        .req_strobe(req_strobe),
        .in_pcm_l(in_pcm_l),
        .in_pcm_r(in_pcm_r),
        .out_pcm_l(out_pcm_l),
        .out_pcm_r(out_pcm_r)
    );

    task write_coeff(input [4:0] ch, input [2:0] coeff_idx, input [15:0] val);
        begin
            @(negedge clk);
            reg_cs = 1; reg_wr = 1;
            reg_addr = {ch, coeff_idx};
            reg_wdata = val;
            @(negedge clk);
            reg_cs = 0; reg_wr = 0;
            @(negedge clk);
        end
    endtask

    initial begin
        reset = 1;
        repeat(5) @(posedge clk);
        reset = 0;
        repeat(5) @(posedge clk);

        // Load coefficients for Voice 0
        write_coeff(0, 0, 16'h0006); // B0
        write_coeff(0, 1, 16'h000C); // B1
        write_coeff(0, 2, 16'h0006); // B2
        write_coeff(0, 3, 16'h838E); // A1
        write_coeff(0, 4, 16'h3C8B); // A2

        $display("Coeff 0 = %h", dut.coeff_ram[0]);
        $display("Coeff 1 = %h", dut.coeff_ram[1]);
        $display("Coeff 2 = %h", dut.coeff_ram[2]);
        $display("Coeff 3 = %h", dut.coeff_ram[3]);
        $display("Coeff 4 = %h", dut.coeff_ram[4]);

        // Send 1 sample to Voice 0
        @(negedge clk);
        cur_voice = 0;
        in_pcm_l = 16'sh6000;
        req_strobe = 1;
        @(negedge clk);
        req_strobe = 0;

        // Monitor FSM
        for (integer i = 0; i < 30; i = i + 1) begin
            $display("T=%4t | state=%2d | dsp_a=%6d | dsp_b=%6d | acc=%h | y_sat=%6d",
                $time, dut.state, dut.dsp_a, dut.dsp_b, dut.acc, dut.y_sat);
            @(posedge clk);
        end

        $finish;
    end
endmodule
