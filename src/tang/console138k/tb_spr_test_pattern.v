// ====================================================================
//  tb_spr_test_pattern.v
//  Prueft das Block-RAM-Muster gegen den echten DMA-Automaten.
//
//  Der Test verbindet sprite_engine_dma mit spr_test_pattern und zwingt
//  den Listenzeiger auf 0x1000 (wie es sonst die Software ueber $DFF580
//  tut). Erwartet: der Deskriptor wird als RGB16 mit 64x32 erkannt und
//  es kommen Pixeldaten.
// ====================================================================

`timescale 1ns / 1ps

module tb;

    reg clk = 0;
    always #17.621 clk = ~clk;

    reg rst_n = 0;

    reg        reg_we = 0;
    reg  [3:0] reg_addr = 0;
    reg [15:0] reg_wdata = 0;
    wire [15:0] reg_rdata;

    reg        vblank_pulse = 0;
    reg        start_line = 0;
    reg signed [11:0] cur_y = 0;

    wire [31:0] avm_address;
    wire [3:0]  avm_burstcount;
    wire        avm_read;
    wire        avm_waitrequest;
    wire [63:0] avm_readdata;
    wire        avm_readdatavalid;

    wire        sprite_active;
    wire signed [11:0] spr_x;
    wire [4:0]  spr_fmt;
    wire [7:0]  spr_prio, spr_alpha;
    wire [1:0]  spr_blend_mode;
    wire [7:0]  spr_x_scale;
    wire        spr_smooth, spr_h_flip;
    wire [10:0] spr_w_px;
    wire        spr_start_line;

    wire [63:0] stream_word64;
    wire        stream_valid;
    reg         stream_ack = 1'b1;

    wire        line_done, engine_en_out, cap_en_out;

    sprite_engine_dma dut (
        .clk(clk), .rst_n(rst_n),
        .reg_we(reg_we), .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_rdata(reg_rdata),
        .vblank_pulse(vblank_pulse), .start_line(start_line), .cur_y(cur_y),
        .avm_address(avm_address), .avm_burstcount(avm_burstcount), .avm_read(avm_read),
        .avm_waitrequest(avm_waitrequest), .avm_readdata(avm_readdata),
        .avm_readdatavalid(avm_readdatavalid),
        .sprite_active(sprite_active), .spr_x(spr_x), .spr_fmt(spr_fmt), .spr_prio(spr_prio),
        .spr_alpha(spr_alpha), .spr_blend_mode(spr_blend_mode), .spr_x_scale(spr_x_scale),
        .spr_smooth(spr_smooth), .spr_h_flip(spr_h_flip), .spr_w_px(spr_w_px),
        .spr_start_line(spr_start_line),
        .stream_word64(stream_word64), .stream_valid(stream_valid), .stream_ack(stream_ack),
        .line_done(line_done), .engine_en_out(engine_en_out), .cap_en_out(cap_en_out)
    );

    spr_test_pattern rom (
        .clk(clk), .rst_n(rst_n),
        .avm_address(avm_address), .avm_read(avm_read),
        .avm_waitrequest(avm_waitrequest),
        .avm_readdata(avm_readdata), .avm_readdatavalid(avm_readdatavalid)
    );

    integer words = 0;
    always @(posedge clk) if (rst_n && stream_valid) words = words + 1;

    task wr(input [3:0] a, input [15:0] d);
        begin
            @(posedge clk); reg_we = 1; reg_addr = a; reg_wdata = d;
            @(posedge clk); reg_we = 0;
        end
    endtask

    integer errors = 0;

    initial begin
        $display("=== Testmuster aus Block-RAM ===");
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // Liste auf 0x1000 zeigen lassen und Engine einschalten
        wr(4'd0, 16'h0000);
        wr(4'd1, 16'h1000);
        wr(4'd2, 16'h0001);

        @(posedge clk); vblank_pulse = 1;
        @(posedge clk); vblank_pulse = 0;
        repeat (2) @(posedge clk);

        cur_y = 12'd32;
        @(posedge clk); start_line = 1;
        @(posedge clk); start_line = 0;

        repeat (600) @(posedge clk);

        $display("sprite_active=%b  spr_fmt=%0d  spr_w_px=%0d  spr_x=%0d",
                 sprite_active, spr_fmt, spr_w_px, spr_x);
        $display("Pixeldaten-Woerter: %0d", words);

        if (spr_w_px == 11'd64) $display("[PASS] Breite 64 erkannt");
        else begin $display("[FAIL] Breite %0d statt 64", spr_w_px); errors = errors + 1; end

        if (spr_fmt == 5'd15) $display("[PASS] Format RGB16 erkannt");
        else begin $display("[FAIL] Format %0d statt 15", spr_fmt); errors = errors + 1; end

        if (words > 0) $display("[PASS] Pixeldaten stroemen");
        else begin $display("[FAIL] keine Pixeldaten"); errors = errors + 1; end

        $display("=== Ergebnis: %0d Fehler ===", errors);
        $finish;
    end

    initial begin
        #200000;
        $display("[TIMEOUT]");
        $finish;
    end

endmodule
