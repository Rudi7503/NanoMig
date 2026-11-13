// ====================================================================
//  tb_dma_idle_read.v
//  Fordert die Sprite-Engine Speicher an, obwohl der Listenzeiger 0 ist?
//
//  Hintergrund: Auf der Tang Console bootet der Core nicht, sobald der
//  Arbiter im Speicherpfad sitzt - auch dann, wenn die Engine scheinbar
//  nichts zu tun hat (SPR_LIST_PTR = 0). Der Verdacht: der DMA-Automat
//  liest trotzdem, und zwar bei Adresse 0, mitten ins Chip-RAM.
//
//  Der Test schreibt KEIN Register. Damit ist der Listenzeiger nach dem
//  Reset 0, genau wie auf echter Hardware vor dem ersten Programmstart.
//  Dann werden vblank und Zeilenstarts gepulst, wie sie im Betrieb
//  kommen, und avm_read mitgezaehlt.
//
//  Aufruf:
//    iverilog -g2012 -s tb -o t.vvp tb_dma_idle_read.v ^
//             sprite_engine_dma.v
//    vvp t.vvp
// ====================================================================

`timescale 1ns / 1ps

module tb;

    reg clk = 0;
    always #17.621 clk = ~clk;      // 28.375 MHz Systemtakt

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
    reg         avm_waitrequest = 0;
    reg  [63:0] avm_readdata = 64'd0;
    reg         avm_readdatavalid = 0;

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

    integer reads = 0;
    integer i;
    reg [31:0] first_addr;
    reg        have_addr = 0;

    always @(posedge clk) begin
        if (rst_n && avm_read) begin
            reads = reads + 1;
            if (!have_addr) begin
                first_addr = avm_address;
                have_addr  = 1'b1;
            end
        end
    end

    initial begin
        $display("=== Fordert die Engine bei Listenzeiger 0 Speicher an? ===");
        repeat (4) @(posedge clk);
        rst_n = 1;

        // KEIN Registerzugriff - der Zeiger bleibt 0.
        repeat (5) @(posedge clk);

        // Zehn Bildwechsel mit je zwei Zeilenstarts, wie im Betrieb
        for (i = 0; i < 10; i = i + 1) begin
            @(posedge clk); vblank_pulse = 1;
            @(posedge clk); vblank_pulse = 0;
            repeat (2) @(posedge clk);

            cur_y = i[11:0];
            @(posedge clk); start_line = 1;
            @(posedge clk); start_line = 0;
            repeat (60) @(posedge clk);
        end

        repeat (200) @(posedge clk);

        $display("avm_read-Impulse: %0d", reads);
        if (have_addr) $display("erste Adresse: %08x", first_addr);

        if (reads == 0) begin
            $display("[ERGEBNIS] Die Engine fordert nichts an, solange der Zeiger 0 ist.");
            $display("            Der Arbiter kann den Boot also nicht ueber Anforderungen stoeren.");
        end else begin
            $display("[ERGEBNIS] Die Engine fordert SPEICHER AN, obwohl der Zeiger 0 ist.");
            $display("            Damit ist die Anbindung im Boot-Pfad aktiv und kann ihn blockieren.");
        end
        $finish;
    end

    initial begin
        #200000;
        $display("[TIMEOUT]");
        $finish;
    end

endmodule
