`timescale 1ns/1ps

module tb_adpcm_ref;

    reg clk = 0;
    always #5 clk = ~clk;

    reg rst = 1;
    reg req_valid = 0;
    reg signed [15:0] in_pcm = 0;
    reg [6:0] in_index = 0;
    reg [4:0] code = 0;
    reg [2:0] bits_per_code = 0;

    wire signed [15:0] out_pcm;
    wire [6:0] out_index;

    adpcm_decoder_shared dut (
        .clk(clk),
        .rst(rst),
        .req_valid(req_valid),
        .in_pcm(in_pcm),
        .in_index(in_index),
        .code(code),
        .bits_per_code(bits_per_code),
        .out_pcm(out_pcm),
        .out_index(out_index)
    );

    reg [1023:0] stim_file;
    integer total_count = 0;
    integer stim_fd;
    integer status;

    // Vectors to hold inputs and expected outputs
    // Format: in_pcm (hex 4), in_index (hex 2), code (hex 2), bps (hex 1), exp_pcm (hex 4), exp_index (hex 2)
    reg [15:0] stim_pcm;
    reg [7:0]  stim_idx;
    reg [7:0]  stim_code;
    reg [3:0]  stim_bps;
    reg [15:0] stim_exp_pcm;
    reg [7:0]  stim_exp_idx;

    // Pipelining expected outputs (inputs driven at negedge T0, latched posedge T1, output posedge T2, checked negedge T2.5)
    reg [15:0] exp_pcm_d1, exp_pcm_d2, exp_pcm_d3;
    reg [6:0]  exp_idx_d1, exp_idx_d2, exp_idx_d3;
    reg        val_d1, val_d2, val_d3;

    integer checked_count = 0;
    integer mismatch_count = 0;
    integer sent_count = 0;

    initial begin
        if (!$value$plusargs("STIM=%s", stim_file)) begin
            $display("ERROR: +STIM=<file> argument required");
            $fatal(1);
        end
        if (!$value$plusargs("COUNT=%d", total_count)) begin
            total_count = 50000;
        end

        stim_fd = $fopen(stim_file, "r");
        if (stim_fd == 0) begin
            $display("ERROR: Could not open stim file %0s", stim_file);
            $fatal(1);
        end

        // Reset sequence
        rst = 1;
        req_valid = 0;
        val_d1 = 0; val_d2 = 0; val_d3 = 0;
        repeat(5) @(posedge clk);
        @(negedge clk);
        rst = 0;
        @(negedge clk);

        // Feed inputs
        while (!$feof(stim_fd) && sent_count < total_count) begin
            status = $fscanf(stim_fd, "%x %x %x %x %x %x\n",
                             stim_pcm, stim_idx, stim_code, stim_bps, stim_exp_pcm, stim_exp_idx);
            if (status == 6) begin
                @(negedge clk);
                req_valid     <= 1;
                in_pcm        <= stim_pcm;
                in_index      <= stim_idx[6:0];
                code          <= stim_code[4:0];
                bits_per_code <= stim_bps[2:0];

                exp_pcm_d1    <= stim_exp_pcm;
                exp_idx_d1    <= stim_exp_idx[6:0];
                val_d1        <= 1;

                sent_count    <= sent_count + 1;
            end
        end

        $fclose(stim_fd);

        // Flush pipeline
        @(negedge clk);
        req_valid <= 0;
        val_d1 <= 0;
        repeat(5) @(negedge clk);

        $display("Simulation finished. Checked %0d vectors, Mismatches: %0d", checked_count, mismatch_count);
        if (mismatch_count > 0 || checked_count != sent_count) begin
            $fatal(1, "ADPCM Verification FAILED");
        end else begin
            $display("ADPCM_VERIFY_SUCCESS: %0d vectors verified with 0 errors.", checked_count);
            $finish;
        end
    end

    // Pipeline delay for expected outputs
    always @(posedge clk) begin
        exp_pcm_d2 <= exp_pcm_d1;
        exp_idx_d2 <= exp_idx_d1;
        val_d2     <= val_d1;

        exp_pcm_d3 <= exp_pcm_d2;
        exp_idx_d3 <= exp_idx_d2;
        val_d3     <= val_d2;
    end

    // Check outputs on negedge clk when val_d3 is valid
    always @(negedge clk) begin
        if (!rst && val_d3) begin
            checked_count = checked_count + 1;
            if (out_pcm !== exp_pcm_d3 || out_index !== exp_idx_d3) begin
                $display("MISMATCH at sample %0d: Expected pcm=%04x idx=%02x, Got pcm=%04x idx=%02x",
                         checked_count, exp_pcm_d3, exp_idx_d3, out_pcm, out_index);
                mismatch_count = mismatch_count + 1;
                if (mismatch_count > 10) begin
                    $fatal(1, "Too many mismatches!");
                end
            end
        end
    end

endmodule
