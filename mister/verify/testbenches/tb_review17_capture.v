// ====================================================================
//  tb_review17_capture.v
//  Nachbau des Review17-Gegenbeispiels "capture_pixel_snapshot".
//
//  Toby's Befund (Review17, Commit f1f0d3b):
//    Pixel0 = 112233, Pixel1 = 445566.
//    HI-Read und ein vier Takte gehaltener LOW-Read lieferten
//    0011 / 5566 statt 0011 / 2233.
//    Der Adressschritt erfolgt jetzt einmalig, aber zu frueh: der
//    Pixel-Snapshot muss bis zum Transferabschluss stehen bleiben.
//
//  Dieser Test prueft:
//    1. HI-Read liefert 0x00RR von Pixel 0        -> 0x0011
//    2. LOW-Read ueber vier Takte liefert GGBB    -> 0x2233 (nicht 0x5566)
//    3. Adresse rueckt genau einmal weiter        -> 1
//
//  STATUS: UNVOLLSTAENDIG. Der Test loest im aktuellen Busmodell den\n//  Pfad low_active nicht aus (transfer_start feuert, low_active bleibt 0).\n//  Er belegt daher nichts und ist NICHT als Nachweis verwendbar.\n//\n//  Ein Vergleich gegen f1f0d3b zeigt ausserdem: das LOW-Wort ist in beiden\n//  Staenden 0x2233, das 5566-Symptom tritt hier also gar nicht auf.\n//\n//  Aufruf:
//    iverilog -g2012 -s tb -o cap.vvp tb_review17_capture.v \
//             sprite_engine_capture.v
//    vvp cap.vvp
// ====================================================================

`timescale 1ns / 1ps

module tb;

    reg clk_vid = 0;
    always #17.621 clk_vid = ~clk_vid;     // 28.375 MHz
    reg clk_sys = 0;
    always #17.621 clk_sys = ~clk_sys;

    reg rst_n = 0;

    // Schreibseite (Video)
    reg        capture_en = 0;
    reg signed [11:0] cur_y = 0;
    reg signed [11:0] cap_y = 0;
    reg [10:0] vid_x = 0;
    reg        vid_read_en = 0;
    reg [23:0] out_rgb = 24'h000000;
    wire       cap_done;

    // Leseseite (CPU)
    reg        reg_cs = 0;
    reg        reg_we = 0;
    reg  [3:0] reg_addr = 0;
    reg [15:0] reg_wdata = 0;
    wire [15:0] reg_rdata;
    wire signed [11:0] cap_target_line;

    sprite_engine_capture dut (
        .rst_n(rst_n),
        .clk_vid(clk_vid), .capture_en(capture_en),
        .cur_y(cur_y), .cap_y(cap_y), .vid_x(vid_x),
        .vid_read_en(vid_read_en), .out_rgb(out_rgb),
        .cap_done(cap_done),
        .clk_sys(clk_sys),
        .reg_cs(reg_cs), .reg_we(reg_we), .reg_addr(reg_addr),
        .reg_wdata(reg_wdata), .reg_rdata(reg_rdata),
        .cap_target_line(cap_target_line)
    );

    // Ein Pixel pro clk_vid einschreiben
    task put_pixel(input [10:0] x, input [23:0] rgb);
        begin
            @(posedge clk_vid);
            vid_x       <= x;
            out_rgb     <= rgb;
            vid_read_en <= 1'b1;
            capture_en  <= 1'b1;
            @(posedge clk_vid);
        end
    endtask

    integer errors = 0;
    reg [15:0] hi_val, lo_val;
    integer i;
    reg [15:0] lo_hist [0:3];

    initial begin
        $display("=== Review17: capture_pixel_snapshot ===");
        rst_n = 0;
        repeat (4) @(posedge clk_sys);
        rst_n = 1;
        repeat (4) @(posedge clk_sys);

        // Ziellinie 0 setzen (Register 9)
        @(negedge clk_sys);
        reg_cs = 1; reg_we = 1; reg_addr = 4'd9; reg_wdata = 16'd0;
        @(negedge clk_sys);
        reg_cs = 0; reg_we = 0;

        // Pixel 0 = 0x112233, Pixel 1 = 0x445566 einschreiben
        cap_y = 12'd0;
        cur_y = 12'd0;
        put_pixel(11'd0, 24'h112233);
        put_pixel(11'd1, 24'h445566);
        @(posedge clk_vid);
        vid_read_en = 0; capture_en = 0;

        // Leseadresse auf 0 (Register 10)
        @(negedge clk_sys);
        reg_cs = 1; reg_we = 1; reg_addr = 4'd10; reg_wdata = 16'd0;
        @(negedge clk_sys);
        reg_cs = 0; reg_we = 0;

        // Synchrones RAM braucht einen Takt, dann steht read_rgb
        repeat (3) @(posedge clk_sys);

        // ---- HI-Read: Register 11, eigener Bustakt ----
        @(posedge clk_sys);
        reg_cs = 1; reg_we = 0; reg_addr = 4'd11;
        @(posedge clk_sys);
        #1 hi_val = reg_rdata;
        @(posedge clk_sys);
        reg_cs = 0; reg_addr = 4'd0;      // Bus freigeben: erster Transfer endet
        repeat (2) @(posedge clk_sys);

        // ---- LOW-Read: Register 12, eigener Bustakt, vier Takte gehalten ----
        @(posedge clk_sys);
        reg_cs = 1; reg_addr = 4'd12;
        for (i = 0; i < 4; i = i + 1) begin
            @(posedge clk_sys);
            #1 lo_hist[i] = reg_rdata;
        end
        lo_val = lo_hist[0];

        // Transfer beenden
        @(negedge clk_sys);
        reg_cs = 0;

        // Adresse pruefen (Register 10)
        repeat (2) @(posedge clk_sys);
        @(negedge clk_sys);
        reg_cs = 1; reg_we = 0; reg_addr = 4'd10;
        @(posedge clk_sys);
        #1;
        $display("Adresse nach Transfer: %0d", reg_rdata[10:0]);
        if (reg_rdata[10:0] == 11'd1)
            $display("[PASS] Adresse genau einmal weitergerueckt (1)");
        else begin
            $display("[FAIL] Adresse = %0d (erwartet 1)", reg_rdata[10:0]);
            errors = errors + 1;
        end
        reg_cs = 0;

        // ---- Auswertung ----
        $display("HI = %04x (erwartet 0011)", hi_val);
        if (hi_val == 16'h0011) $display("[PASS] HI-Read liefert 0x0011");
        else begin $display("[FAIL] HI-Read falsch"); errors = errors + 1; end

        for (i = 0; i < 4; i = i + 1)
            $display("  LOW-Takt %0d = %04x", i, lo_hist[i]);

        if (lo_hist[0] == 16'h2233 && lo_hist[1] == 16'h2233 &&
            lo_hist[2] == 16'h2233 && lo_hist[3] == 16'h2233)
            $display("[PASS] LOW ueber vier Takte konstant 0x2233");
        else begin
            $display("[FAIL] LOW nicht konstant 0x2233 (Adresse zu frueh weitergelaufen)");
            errors = errors + 1;
        end

        $display("=== Ergebnis: %0d Fehler ===", errors);
        if (errors == 0) $display("REVIEW17_CAPTURE_PASS");
        else             $display("REVIEW17_CAPTURE_FAIL");
        $finish;
    end

endmodule
