`timescale 1ns/1ps

module tb_biquad_direct;
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

    integer c;
    initial begin
        reset = 1;
        repeat(5) @(posedge clk);
        reset = 0;
        repeat(5) @(posedge clk);

        // Load coefficients into all 32 voices
        for (c = 0; c < 32; c = c + 1) begin
            write_coeff(c, 0, 16'h0006); // B0
            write_coeff(c, 1, 16'h000C); // B1
            write_coeff(c, 2, 16'h0006); // B2
            write_coeff(c, 3, 16'h838E); // A1
            write_coeff(c, 4, 16'h3C8B); // A2
        end

        // Simulate 200 Hz square wave cascaded through voices 0..31
        // One audio sample every 590 clocks (48 kHz)
        for (integer sample = 0; sample < 500; sample = sample + 1) begin
            reg signed [15:0] square_val = ((sample % 240) < 120) ? 16'sh6000 : -16'sh6000;
            
            // Strobe Voice 0 with square wave
            @(negedge clk);
            cur_voice = 0;
            in_pcm_l = square_val;
            req_strobe = 1;
            @(negedge clk);
            req_strobe = 0;

            // Strobe voices 1..31 with output of previous voice
            for (c = 1; c < 32; c = c + 1) begin
                @(negedge clk);
                cur_voice = c;
                in_pcm_l = dut.y_held_l[c - 1]; // Cascade from predecessor!
                req_strobe = 1;
                @(negedge clk);
                req_strobe = 0;
            end

            // Wait remaining cycles of the 48 kHz sample period
            repeat(590 - 64) @(posedge clk);

            if (sample == 499) begin
                $display("\n=== SAMPLES AFTER 500 STEPS (Cascade Output) ===");
                for (c = 0; c < 32; c = c + 1) begin
                    $display("Voice %2d output = %6d", c, dut.y_held_l[c]);
                end
            end
        end
        $finish;
    end
endmodule
