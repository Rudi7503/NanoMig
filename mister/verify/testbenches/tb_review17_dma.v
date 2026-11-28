// ====================================================================
//  tb_review17_dma.v
//  Nachbau des Review17-Gegenbeispiels "descriptor_gapped_tail".
//
//  Toby's Befund (Review17, Commit f1f0d3b):
//    Deskriptor BL4 liefert Wort0/1, 8 Takte Pause, dann 2 Restbeats.
//    Ergebnis: 16 Pixelcodes, obwohl noch keine Pixeldaten geliefert
//    wurden. Alle vier Deskriptorbeats zaehlen/zuordnen und vollstaendig
//    drainen, auch bei Antwortluecken.
//
//  Dieser Test prueft genau das:
//    - waehrend der Deskriptor-Burst laeuft, darf KEIN stream_valid kommen
//    - nach dem Drain muss der Deskriptor ausgewertet sein (spr_w_px > 0)
//    - erst die Pixeldaten duerfen stream_valid erzeugen
//
//  Aufruf:
//    iverilog -g2012 -s tb -o tb_review17_dma.vvp tb_review17_dma.v \
//             sprite_engine_dma.v
//    vvp tb_review17_dma.vvp
// ====================================================================

`timescale 1ns / 1ps

module tb;

    reg clk = 0;
    always #4.357 clk = ~clk;          // 114.75 MHz Render-Takt

    reg rst_n = 0;

    // Registerbus
    reg        reg_we = 0;
    reg  [3:0] reg_addr = 0;
    reg [15:0] reg_wdata = 0;
    wire [15:0] reg_rdata;

    // Video-Timing
    reg        vblank_pulse = 0;
    reg        start_line = 0;
    reg signed [11:0] cur_y = 0;

    // Avalon-MM
    wire [31:0] avm_address;
    wire [3:0]  avm_burstcount;
    wire        avm_read;
    reg         avm_waitrequest = 0;
    reg  [63:0] avm_readdata = 64'd0;
    reg         avm_readdatavalid = 0;

    // Descriptor-Ausgaenge
    wire        sprite_active;
    wire signed [11:0] spr_x;
    wire [4:0]  spr_fmt;
    wire [7:0]  spr_prio;
    wire [7:0]  spr_alpha;
    wire [1:0]  spr_blend_mode;
    wire [7:0]  spr_x_scale;
    wire        spr_smooth;
    wire        spr_h_flip;
    wire [10:0] spr_w_px;
    wire        spr_start_line;

    // Datenstrom
    wire [63:0] stream_word64;
    wire        stream_valid;
    // Der nachgelagerte Dekoder ist immer aufnahmebereit
    reg         stream_ack = 1'b1;

    wire        line_done;
    wire        engine_en_out;
    wire        cap_en_out;

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

    // ------------------------------------------------------------------
    // Speichermodell
    //   Deskriptor-Liste bei 0x1000, Pixeldaten bei 0x2000.
    //   Der Deskriptor-Burst wird absichtlich mit 8 Takten Luecke zwischen
    //   Beat 1 und Beat 2 geliefert (Toby's Gegenbeispiel).
    // ------------------------------------------------------------------
    localparam [31:0] DESC_ADDR = 32'h0000_1000;
    localparam [31:0] DATA_ADDR = 32'h0000_2000;

    // Deskriptor 0: y=0, x=0, data_ptr=0x2000
    wire [63:0] DESC_W0 = {12'd0, 12'd0, 8'd0, 32'h0000_2000};
    // height=1, width_px=32, fmt=7 (CLUT8), prio=0x80, alpha=0, scale 1x
    wire [63:0] DESC_W1 = {12'd1, 12'd32, 8'd7, 8'h80, 8'd0, 8'd0, 8'd0};
    // Sentinel: height = 0
    wire [63:0] DESC_W2 = 64'd0;
    wire [63:0] DESC_W3 = 64'd0;

    reg [63:0] pix_w0 = 64'h1111_1111_2222_2222;
    reg [63:0] pix_w1 = 64'h3333_3333_4444_4444;
    reg [63:0] pix_w2 = 64'h5555_5555_6666_6666;
    reg [63:0] pix_w3 = 64'h7777_7777_8888_8888;

    reg        cmd_active = 0;
    reg [31:0] cmd_addr = 0;
    reg [1:0]  beat = 0;
    reg [5:0]  wait_cnt = 0;
    reg        in_gap = 0;

    // Laeuft gerade ein Deskriptor-Burst? (fuer die Ueberwachung)
    reg        desc_burst_active = 0;
    integer    stream_during_desc = 0;
    integer    data_stream_words  = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_active         <= 1'b0;
            beat               <= 2'd0;
            wait_cnt           <= 6'd0;
            in_gap             <= 1'b0;
            avm_readdatavalid  <= 1'b0;
            avm_readdata       <= 64'd0;
            desc_burst_active  <= 1'b0;
        end else begin
            avm_readdatavalid <= 1'b0;

            if (!cmd_active) begin
                if (avm_read && !avm_waitrequest) begin
                    cmd_active <= 1'b1;
                    cmd_addr   <= avm_address;
                    beat       <= 2'd0;
                    wait_cnt   <= 6'd2;            // 2 Takte bis Beat 0
                    in_gap     <= 1'b0;
                    desc_burst_active <= (avm_address[15:4] == DESC_ADDR[15:4]);
                end
            end else if (in_gap) begin
                if (wait_cnt != 0) begin
                    wait_cnt <= wait_cnt - 6'd1;
                end else begin
                    in_gap    <= 1'b0;
                    beat      <= beat + 2'd1;      // Beat 2 liefern
                    wait_cnt  <= 6'd1;
                end
            end else if (wait_cnt != 0) begin
                wait_cnt <= wait_cnt - 6'd1;
            end else begin
                // einen Beat liefern
                avm_readdatavalid <= 1'b1;
                if (cmd_addr[15:4] == DESC_ADDR[15:4]) begin
                    case (beat)
                        2'd0: avm_readdata <= DESC_W0;
                        2'd1: avm_readdata <= DESC_W1;
                        2'd2: avm_readdata <= DESC_W2;
                        default: avm_readdata <= DESC_W3;
                    endcase
                end else begin
                    case (beat)
                        2'd0: avm_readdata <= pix_w0;
                        2'd1: avm_readdata <= pix_w1;
                        2'd2: avm_readdata <= pix_w2;
                        default: avm_readdata <= pix_w3;
                    endcase
                end

                if (beat == 2'd3) begin
                    cmd_active        <= 1'b0;
                    desc_burst_active <= 1'b0;
                    beat              <= 2'd0;
                end else if (beat == 2'd1 && cmd_addr[15:4] == DESC_ADDR[15:4]) begin
                    // Toby's Luecke: nach Beat 1 acht Takte Pause
                    beat     <= beat;
                    in_gap   <= 1'b1;
                    wait_cnt <= 6'd8;
                end else begin
                    beat     <= beat + 2'd1;
                    wait_cnt <= 6'd1;
                end
            end
        end
    end

    // Ueberwachung: stream_valid waehrend Deskriptor-Burst = Fehler
    always @(posedge clk) begin
        if (rst_n) begin
            if (desc_burst_active && stream_valid)
                stream_during_desc <= stream_during_desc + 1;
            if (!desc_burst_active && stream_valid)
                data_stream_words <= data_stream_words + 1;
        end
    end

    // ------------------------------------------------------------------
    // Ablauf
    // ------------------------------------------------------------------
    integer errors = 0;
    integer cmd_count = 0;
    always @(posedge clk) if (avm_read && !avm_waitrequest) cmd_count <= cmd_count + 1;

    task wr(input [3:0] a, input [15:0] d);
        begin
            @(posedge clk);
            reg_we = 1; reg_addr = a; reg_wdata = d;
            @(posedge clk);
            reg_we = 0;
        end
    endtask

    initial begin
        $display("=== Review17: descriptor_gapped_tail ===");
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        // Liste bei 0x1000, Engine an
        wr(4'd0, 16'h0000);          // PTR_H
        wr(4'd1, 16'h1000);          // PTR_L  -> staged_ptr = 0x1000
        wr(4'd2, 16'h0001);          // CTRL: engine_en

        // VBlank: Zeiger wird atomar uebernommen
        @(posedge clk); vblank_pulse = 1;
        @(posedge clk); vblank_pulse = 0;
        repeat (2) @(posedge clk);

        // Zeilenstart fuer Y=0
        cur_y = 12'd0;
        @(posedge clk); start_line = 1;
        @(posedge clk); start_line = 0;

        // Laufen lassen: Deskriptor mit Luecke + Pixeldaten
        repeat (400) @(posedge clk);

        // ---- Auswertung ----
        if (stream_during_desc != 0) begin
            $display("[FAIL] %0d stream_valid-Takte waehrend des Deskriptor-Bursts (erwartet 0)",
                     stream_during_desc);
            errors = errors + 1;
        end else begin
            $display("[PASS] kein stream_valid waehrend des Deskriptor-Bursts");
        end

        if (spr_w_px > 0)
            $display("[PASS] Deskriptor ausgewertet, spr_w_px = %0d", spr_w_px);
        else begin
            $display("[FAIL] Deskriptor nicht ausgewertet (spr_w_px = 0)");
            errors = errors + 1;
        end

        if (spr_fmt == 5'd7)
            $display("[PASS] Format CLUT8 erkannt (spr_fmt = %0d)", spr_fmt);
        else begin
            $display("[FAIL] Format falsch: spr_fmt = %0d (erwartet 7)", spr_fmt);
            errors = errors + 1;
        end

        if (data_stream_words > 0)
            $display("[PASS] Pixeldaten stroemen nach dem Drain (%0d Woerter)", data_stream_words);
        else begin
            $display("[FAIL] keine Pixeldaten gestreamt");
            errors = errors + 1;
        end

        $display("Diagnose: %0d Speicherkommandos, %0d Datenwoerter", cmd_count, data_stream_words);
        $display("=== Ergebnis: %0d Fehler ===", errors);
        if (errors == 0) $display("REVIEW17_DMA_PASS");
        else             $display("REVIEW17_DMA_FAIL");
        $finish;
    end

endmodule
