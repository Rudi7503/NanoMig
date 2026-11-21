// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ps

module tb_master_mixer_limiter;

    reg clk_sys = 0;
    always #17.62 clk_sys = ~clk_sys; // 28.375 MHz

    reg clk_audio = 0;
    always #20.345 clk_audio = ~clk_audio; // 24.576 MHz

    reg reset = 1;

    // Sources feeding into the master mixer
    reg signed [15:0] aud_l = 0, aud_r = 0;                     // Paula (4 channels)
    reg signed [15:0] toccata_l = 0, toccata_r = 0;             // Toccata 16-bit
    reg signed [15:0] mt32_l = 0, mt32_r = 0;                   // MT32
    reg signed [15:0] cdda_l = 0, cdda_r = 0;                   // CDDA
    reg signed [15:0] dsnd_l = 0, dsnd_r = 0;                   // Drive sounds
    reg signed [20:0] audio_ext_l = 0, audio_ext_r = 0;         // 32-Voice Extension (+18 dB headroom)

    // 42-bit Mailbox CDC (clk_sys -> CLK_AUDIO)
    reg [41:0] ext_mailbox;
    reg ext_toggle, ext_ack;
    reg [1:0] ext_ack_sync, ext_toggle_sync;
    reg signed [20:0] ext_audio_l, ext_audio_r;

    always @(posedge clk_sys or posedge reset) begin
        if (reset) begin
            ext_mailbox <= 0;
            ext_toggle <= 0;
            ext_ack_sync <= 0;
        end else begin
            ext_ack_sync <= {ext_ack_sync[0], ext_ack};
            if (ext_ack_sync[1] == ext_toggle) begin
                ext_mailbox <= {audio_ext_l, audio_ext_r};
                ext_toggle <= ~ext_toggle;
            end
        end
    end

    always @(posedge clk_audio or posedge reset) begin
        if (reset) begin
            ext_toggle_sync <= 0;
            ext_ack <= 0;
            ext_audio_l <= 0;
            ext_audio_r <= 0;
        end else begin
            ext_toggle_sync <= {ext_toggle_sync[0], ext_toggle};
            if (ext_toggle_sync[1] != ext_ack) begin
                {ext_audio_l, ext_audio_r} <= ext_mailbox;
                ext_ack <= ext_toggle_sync[1];
            end
        end
    end

    // Master 22-Bit Summer
    reg signed [21:0] tmp_l, tmp_r;
    reg [8:0] audio_strobe_div;
    wire master_sample_strobe = (audio_strobe_div == 9'd0);

    always @(posedge clk_audio) begin
        if (reset) begin
            audio_strobe_div <= 9'd0;
            tmp_l <= 22'sd0;
            tmp_r <= 22'sd0;
        end else begin
            audio_strobe_div <= audio_strobe_div + 1'b1;

            tmp_l <= {{6{aud_l[15]}}, aud_l} + 
                     {{6{toccata_l[15]}}, toccata_l} + 
                     {{6{mt32_l[15]}}, mt32_l} + 
                     {{6{cdda_l[15]}}, cdda_l} + 
                     {{6{dsnd_l[15]}}, dsnd_l} + 
                     {{1{ext_audio_l[20]}}, ext_audio_l};

            tmp_r <= {{6{aud_r[15]}}, aud_r} + 
                     {{6{toccata_r[15]}}, toccata_r} + 
                     {{6{mt32_r[15]}}, mt32_r} + 
                     {{6{cdda_r[15]}}, cdda_r} + 
                     {{6{dsnd_r[15]}}, dsnd_r} + 
                     {{1{ext_audio_r[20]}}, ext_audio_r};
        end
    end

    // Master AGC Limiter
    wire signed [15:0] out_l, out_r;
    wire master_agc_active;
    wire [15:0] master_peak_hold;

    audio_agc_limiter #(
        .CEILING(22'sd30720)   // -0.5 dBFS margin
    ) master_agc_limiter (
        .clk(clk_audio),
        .reset(reset),
        .sample_strobe(master_sample_strobe),
        .in_l(tmp_l),
        .in_r(tmp_r),
        .out_l(out_l),
        .out_r(out_r),
        .agc_active(master_agc_active),
        .peak_hold(master_peak_hold)
    );

    integer i;
    reg signed [15:0] max_peak = 0;
    integer hard_clips = 0;

    initial begin
        $display("==================================================================");
        $display("SIMULATION: FULL AMIGA MASTER MIXER WITH UNIFIED AGC LIMITER");
        $display("==================================================================");

        reset = 1;
        #100;
        @(posedge clk_audio);
        reset = 0;
        #100;

        // TEST 1: Simultaneous Multi-Source Super Overload
        // Paula: 30,000
        // 32-Voices: 120,000 (extreme formant peak!)
        // CDDA: 25,000
        // Toccata: 20,000
        // Drive Sounds: 15,000
        // Total Unconstrained Sum = 30k + 120k + 25k + 20k + 15k = 210,000 (+17 dB above 0 dBFS)
        aud_l = 16'sd30000;
        aud_r = 16'sd30000;
        cdda_l = 16'sd25000;
        cdda_r = 16'sd25000;
        toccata_l = 16'sd20000;
        toccata_r = 16'sd20000;
        dsnd_l = 16'sd15000;
        dsnd_r = 16'sd15000;
        audio_ext_l = 21'sd120000;
        audio_ext_r = 21'sd120000;

        // Run for 50,000 cycles (~2 ms of audio, ~100 master samples)
        for (i = 0; i < 50000; i = i + 1) begin
            @(posedge clk_audio);
            if (out_l > max_peak) max_peak = out_l;
            if (out_l >= 16'sh7FFF || out_l <= -16'sh8000) hard_clips = hard_clips + 1;
        end

        $display("Unconstrained Master Sum: 210,000 (+17 dB overload)");
        $display("Max Limited Output Peak:  %0d (Target Ceiling = 30,720)", max_peak);
        $display("Hard Clips:               %0d", hard_clips);
        $display("Master AGC Active:        %0d", master_agc_active);

        if (max_peak <= 30720 && hard_clips == 0 && master_agc_active == 1) begin
            $display(">>> [PASS] Master mixer cleanly limited multi-source overload without clipping! <<<");
        end else begin
            $display(">>> [FAIL] Master limiter failed to contain overload! <<<");
            $stop;
        end

        // TEST 2: Return to Normal Below Ceiling (Paula = 15,000, 32-Voices = 10,000 -> Sum = 25,000)
        aud_l = 16'sd15000;
        aud_r = 16'sd15000;
        cdda_l = 0; cdda_r = 0;
        toccata_l = 0; toccata_r = 0;
        dsnd_l = 0; dsnd_r = 0;
        audio_ext_l = 21'sd10000;
        audio_ext_r = 21'sd10000;

        // Wait for full release decay (~160 ms = ~4,500,000 cycles)
        repeat(5000000) @(posedge clk_audio);

        $display("\nAfter Release Decay:");
        $display("Master AGC Active:        %0d (expected 0)", master_agc_active);
        $display("Master Output L:          %0d (expected bit-exact 25,000)", out_l);

        if (master_agc_active == 0 && out_l == 16'sd25000) begin
            $display(">>> [PASS] Master limiter released smoothly to 100%% bit-exact passthrough! <<<");
        end else begin
            $display(">>> [FAIL] Release did not return to bit-exact! <<<");
            $stop;
        end

        $display("\n==================================================================");
        $display("ALL MASTER MIXER + AGC LIMITER SYSTEM TESTS PASSED SUCCESSFULLY!");
        $display("==================================================================");
        $finish;
    end

endmodule
