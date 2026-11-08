// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ps

module tb_audio_agc_limiter;

    reg clk;
    reg reset;
    reg sample_strobe;
    reg signed [20:0] in_l, in_r;
    wire signed [15:0] out_l, out_r;
    wire agc_active;
    wire [15:0] peak_hold;

    audio_agc_limiter #(
        .CEILING(21'sd30720)
    ) dut (
        .clk(clk),
        .reset(reset),
        .sample_strobe(sample_strobe),
        .in_l(in_l),
        .in_r(in_r),
        .out_l(out_l),
        .out_r(out_r),
        .agc_active(agc_active),
        .peak_hold(peak_hold)
    );

    // 28.375 MHz clock (period ~35.24 ns)
    always #17.62 clk = ~clk;

    integer i, k;
    integer clip_count;
    reg signed [20:0] max_in, max_out;
    reg signed [20:0] s;

    task send_sample;
        input signed [20:0] sl;
        input signed [20:0] sr;
        begin
            @(posedge clk);
            #1;
            in_l = sl;
            in_r = sr;
            sample_strobe = 1'b1;
            @(posedge clk);
            #1;
            sample_strobe = 1'b0;
            // 30 idle cycles matching 32-voice TDM frame
            repeat(30) @(posedge clk);
            if (out_l >= 32767 || out_l <= -32768) clip_count = clip_count + 1;
            if (out_l > max_out) max_out = out_l;
        end
    endtask

    initial begin
        clk = 0;
        reset = 1;
        sample_strobe = 0;
        in_l = 0;
        in_r = 0;
        clip_count = 0;
        max_in = 0;
        max_out = 0;
        s = 0;

        #100;
        @(posedge clk);
        reset = 0;
        #100;

        $display("==================================================================");
        $display("TEST 1: Normal Signal Below Ceiling (Amplitude 24000 = -2 dBFS)");
        $display("==================================================================");
        for (i = 0; i < 200; i = i + 1) begin
            // 440 Hz cycle approximation
            if (i % 20 < 10) s = 21'sd24000;
            else s = -21'sd24000;
            send_sample(s, s);
            if (i > 10 && out_l != s[15:0]) begin
                $display("[FAIL] Normal signal not bit-exact at step %0d: in=%0d, out=%0d", i, s, out_l);
                $stop;
            end
        end
        $display("[PASS] Normal signal is 100%% bit-exact and unaltered (AGC active = %0d)", agc_active);

        $display("\n==================================================================");
        $display("TEST 2: Extreme Overload Signal (+6 dB Overload, Amplitude 60000)");
        $display("==================================================================");
        clip_count = 0;
        max_out = 0;
        for (i = 0; i < 500; i = i + 1) begin
            if (i % 20 < 10) s = 21'sd60000;
            else s = -21'sd60000;
            send_sample(s, s);
        end

        $display("Peak input:   60000 (+6 dB over threshold)");
        $display("Peak output:  %0d (Target Ceiling = 30720)", max_out);
        $display("Hard clips:   %0d", clip_count);
        $display("AGC Active:   %0d", agc_active);

        if (max_out <= 31000 && clip_count == 0 && agc_active == 1) begin
            $display("[PASS] Overload successfully and cleanly limited without hard clipping!");
        end else begin
            $display("[FAIL] Limiter failed to contain peak cleanly!");
            $stop;
        end

        $display("\n==================================================================");
        $display("TEST 3: Smooth Decay & Return to Unity Gain After Overload Ends");
        $display("==================================================================");
        for (i = 0; i < 35000; i = i + 1) begin
            send_sample(21'sd1000, 21'sd1000);
        end
        $display("After release decay: AGC Active = %0d (expected 0)", agc_active);
        if (agc_active == 0 && out_l == 1000) begin
            $display("[PASS] Release decay returned smoothly to unity gain (bit-exact 1000).");
        end else begin
            $display("[FAIL] Limiter did not release properly: agc_active=%0d out_l=%0d", agc_active, out_l);
            $stop;
        end

        $display("\n==================================================================");
        $display("TEST 4: Extreme Overload Signal (+18 dB Overload, Amplitude 250000)");
        $display("==================================================================");
        clip_count = 0;
        max_out = 0;
        for (i = 0; i < 500; i = i + 1) begin
            if (i % 20 < 10) s = 21'sd250000;
            else s = -21'sd250000;
            send_sample(s, s);
        end

        $display("Peak input:   250000 (+18 dB over threshold)");
        $display("Peak output:  %0d (Target Ceiling = 30720)", max_out);
        $display("Hard clips:   %0d", clip_count);
        $display("AGC Active:   %0d", agc_active);

        if (max_out <= 30720 && clip_count == 0 && agc_active == 1) begin
            $display("[PASS] Massive +18 dB overload cleanly contained below ceiling!");
        end else begin
            $display("[FAIL] Limiter failed to contain +18 dB overload!");
            $stop;
        end

        $display("\n==================================================================");
        $display("ALL AGC / TRUE-PEAK LIMITER TESTS PASSED SUCCESSFULLY!");
        $display("==================================================================");
        $finish;
    end

endmodule
