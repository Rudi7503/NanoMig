`timescale 1ns/1ps

module tb_minimig_verified;
    reg clk = 0;
    always #17.6 clk = ~clk; // 28.375 MHz

    reg reset = 1;

    // CPU Bus signals matching minimig.v
    reg [23:1] cpu_address_out = 0;
    reg [15:0] cpu_data_out = 0;
    reg cpu_rd = 0;
    reg cpu_hwr = 0;
    reg cpu_lwr = 0;
    reg dbr = 0;
    wire [15:0] cpu_data_in;

    // Logic straight from modified minimig.v:
    wire audio_ext_selected = (cpu_address_out[23:10] == 14'b1101_1111_1111_01);
    wire audio_ext_access = audio_ext_selected && !dbr && (cpu_rd || cpu_hwr || cpu_lwr);

    // FIXED decoding in minimig.v:
    wire audio_irq_selected = (cpu_address_out[23:4] == (24'hDFF804 >> 4)) && 
                              (cpu_address_out[3:1] >= 3'd2 && cpu_address_out[3:1] <= 3'd5);
    wire audio_irq_access = audio_irq_selected && !dbr && (cpu_rd || cpu_hwr || cpu_lwr);
    wire [1:0] audio_irq_addr = cpu_address_out[3:1] - 3'd2;

    wire cap_ctrl_selected  = (cpu_address_out[23:1] == (24'hDFF802 >> 1));
    wire cap_ctrl_access    = cap_ctrl_selected && !dbr && (cpu_rd || cpu_hwr || cpu_lwr);
    wire [15:0] cap_ctrl_rdata;

    wire audio_cap_selected = (cpu_address_out[23:13] == 11'b1101_1111_100);
    wire audio_cap_access   = audio_cap_selected && !dbr && cpu_rd;
    wire [15:0] audio_cap_rdata;
    wire audio_cap_irq;

    wire ham_ext_selected = (cpu_address_out[23:1] == (24'hDFF800 >> 1));
    wire ham_ext_access = ham_ext_selected && !dbr && (cpu_rd || cpu_hwr || cpu_lwr);

    wire audio_ext_irq;
    wire [15:0] audio_ext_rdata;
    wire [15:0] audio_ext_l, audio_ext_r;

    // Instantiate audio_ext exactly as wired in minimig.v
    audio_ext AUDIO_EXT (
        .clk(clk), .reset(reset), .ntsc(1'b0),
        .reg_cs(audio_ext_access), .reg_wr(cpu_hwr || cpu_lwr),
        .reg_addr(cpu_address_out[9:1]), .reg_be({cpu_hwr, cpu_lwr}),
        .reg_wdata(cpu_data_out), .reg_rdata(audio_ext_rdata), .irq(audio_ext_irq),
        .irq_cs(audio_irq_access), .irq_addr(audio_irq_addr),
        .dma_req(), .dma_addr(), .dma_ack(1'b0), .dma_data(16'd0), .dma_error(1'b0),
        .sample_l(audio_ext_l), .sample_r(audio_ext_r)
    );

    // Strobe divider for capture
    reg [9:0] cap_strobe_div = 0;
    reg cap_sample_strobe = 0;
    always @(posedge clk) begin
        if (reset) begin
            cap_strobe_div <= 0;
            cap_sample_strobe <= 0;
        end else begin
            if (cap_strobe_div >= 10'd590) begin
                cap_strobe_div <= 0;
                cap_sample_strobe <= 1;
            end else begin
                cap_strobe_div <= cap_strobe_div + 1;
                cap_sample_strobe <= 0;
            end
        end
    end

    // Instantiate audio_capture exactly as wired in minimig.v
    audio_capture CAPTURE (
        .clk(clk),
        .reset(reset),
        .sample_strobe(cap_sample_strobe),
        .in_l(audio_ext_l),
        .in_r(audio_ext_r),
        .buf_cs(audio_cap_access),
        .buf_addr(cpu_address_out[12:1]),
        .buf_rdata(audio_cap_rdata),
        .reg_cs(cap_ctrl_access),
        .reg_wr(cpu_hwr || cpu_lwr),
        .reg_be({cpu_hwr, cpu_lwr}),
        .reg_wdata(cpu_data_out),
        .reg_rdata(cap_ctrl_rdata),
        .irq(audio_cap_irq)
    );

    // Data multiplexer straight from minimig.v
    assign cpu_data_in[15:0] = (cap_ctrl_access && cpu_rd) ? cap_ctrl_rdata :
                               (audio_cap_access && cpu_rd) ? audio_cap_rdata :
                               ((audio_ext_access || audio_irq_access) && cpu_rd) ? audio_ext_rdata : 16'hFFFF;

    // CPU write cycle task
    task cpu_write(input [23:0] addr, input [15:0] data);
        begin
            @(negedge clk);
            cpu_address_out = addr[23:1];
            cpu_data_out = data;
            cpu_hwr = 1; cpu_lwr = 1; cpu_rd = 0;
            repeat(4) @(posedge clk);
            @(negedge clk);
            cpu_hwr = 0; cpu_lwr = 0;
            repeat(2) @(posedge clk);
        end
    endtask

    // CPU read cycle task
    task cpu_read(input [23:0] addr, output [15:0] data);
        begin
            @(negedge clk);
            cpu_address_out = addr[23:1];
            cpu_rd = 1; cpu_hwr = 0; cpu_lwr = 0;
            repeat(4) @(posedge clk);
            data = cpu_data_in;
            @(negedge clk);
            cpu_rd = 0;
            repeat(2) @(posedge clk);
        end
    endtask

    reg [15:0] read_val;

    initial begin
        $display("==================================================================");
        $display("=== SIMULATION: VERIFIZIERUNG DER GEAENDERTEN MINIMIG.V LOGIK ===");
        $display("==================================================================");
        reset = 1;
        repeat(10) @(posedge clk);
        reset = 0;
        repeat(10) @(posedge clk);

        // Schritt 1: Pruefen des Ausgangszustands
        $display("\n[TEST 1] Initialzustand:");
        $display("  audio_ext_irq = %b (Erwartet: 0)", audio_ext_irq);
        $display("  voice_irq_en  = %h (Erwartet: 0)", AUDIO_EXT.voice_irq_en);
        if (audio_ext_irq != 0 || AUDIO_EXT.voice_irq_en != 0) begin
            $display(">>> FEHLER im Initialzustand! <<<");
            $finish;
        end

        // Schritt 2: Simuliere Schritt [3/4] aus rechteck.s:
        // Schreibzugriff auf AUD_CAP ($DFF802) mit $0017
        $display("\n[TEST 2] Fuehre 'MOVE.W #$0017, AUD_CAP ($DFF802)' aus...");
        cpu_write(24'hDFF802, 16'h0017);

        $display("  Nach Schreibzugriff auf $DFF802:");
        $display("  cap_ctrl_access     = %b (Erwartet: waehrend Zugriff 1)", cap_ctrl_selected);
        $display("  audio_irq_selected  = %b (Erwartet: 0)", audio_irq_selected);
        $display("  voice_irq_en        = %h (Erwartet: 00000000 - KEIN Bit gesetzt!)", AUDIO_EXT.voice_irq_en);
        $display("  audio_ext_irq       = %b (Erwartet: 0 - KEIN Interrupt!)", audio_ext_irq);
        $display("  CAPTURE.capture_en  = %b (Erwartet: 1 - Capture laeuft!)", CAPTURE.capture_en);

        if (AUDIO_EXT.voice_irq_en != 32'd0) begin
            $display(">>> KRITISCHER FEHLER: voice_irq_en wurde faelschlich beschrieben! <<<");
            $finish;
        end
        if (audio_ext_irq != 1'b0) begin
            $display(">>> KRITISCHER FEHLER: audio_ext_irq wurde faelschlich ausgeloest! <<<");
            $finish;
        end
        if (CAPTURE.capture_en != 1'b1) begin
            $display(">>> FEHLER: Capture wurde nicht aktiviert! <<<");
            $finish;
        end
        $display("  -> [TEST 2 BESTANDEN]: $DFF802 aktiviert Capture OHNE den Audio-IRQ zu beruehren!");

        // Schritt 3: Simuliere die Warteschleife aus rechteck.s:
        // Lesezugriff auf AUD_CAP ($DFF802)
        $display("\n[TEST 3] Fuehre 'MOVE.W AUD_CAP ($DFF802), D1' (Status-Lesen) aus...");
        cpu_read(24'hDFF802, read_val);
        $display("  Gelesener Wert aus $DFF802: %h", read_val);
        $display("  Bit 0 (capture_en): %b (Erwartet: 1)", read_val[0]);
        $display("  Bit 1 (flag_block_a): %b", read_val[1]);
        if (read_val[0] != 1'b1) begin
            $display(">>> FEHLER: Bit 0 (capture_en) ist nicht 1! <<<");
            $finish;
        end
        $display("  -> [TEST 3 BESTANDEN]: Statusregister lesbar!");

        // Schritt 4: Pruefen, dass die echten Interrupt-Register ($DFF804..$DFF80A) weiterhin funktionieren
        $display("\n[TEST 4] Pruefe echte Audio-IRQ-Register ($DFF804..$DFF80A):");
        
        // Schreibe $1234 nach $DFF804 (INTENA HI)
        cpu_write(24'hDFF804, 16'h1234);
        $display("  Schreibe $1234 nach $DFF804 -> voice_irq_en[31:16] = %h (Erwartet: 1234)", AUDIO_EXT.voice_irq_en[31:16]);
        
        // Schreibe $5678 nach $DFF806 (INTENA LO)
        cpu_write(24'hDFF806, 16'h5678);
        $display("  Schreibe $5678 nach $DFF806 -> voice_irq_en[15:0]  = %h (Erwartet: 5678)", AUDIO_EXT.voice_irq_en[15:0]);

        if (AUDIO_EXT.voice_irq_en != 32'h12345678) begin
            $display(">>> FEHLER: $DFF804/$DFF806 schreiben nicht die erwarteten Werte! <<<");
            $finish;
        end
        $display("  -> [TEST 4 BESTANDEN]: $DFF804 und $DFF806 funktionieren perfekt!");

        $display("\n==================================================================");
        $display("=== ALLE SIMULATIONSTESTS DER GEAENDERTEN VERSION ERFOLGREICH! ===");
        $display("==================================================================");
        $finish;
    end
endmodule
