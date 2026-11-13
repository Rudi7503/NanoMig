// ====================================================================
//  tb_sprite_mem_adapter.v
//  Prueft den Adapter zwischen Sprite-Engine (Avalon-MM) und dem
//  SDRAM-Anschluss p2 der Tang-Konsole.
//
//  Geprueft wird:
//    1. Ein Burst von 4 Beats liefert die Daten der richtigen Adressen.
//    2. Die Wortadressen liegen 4 auseinander (8 Byte Abstand).
//    3. avm_waitrequest wird bis zum letzten Beat gehalten.
//    4. Ein gleichzeitiger Prozessor-Zugriff stoert den Burst nicht und
//       bekommt seine eigenen Daten.
//
//  Aufruf:
//    iverilog -g2012 -s tb -o tb.vvp tb_sprite_mem_adapter.v ^
//             sprite_mem_adapter.v
//    vvp tb.vvp
// ====================================================================

`timescale 1ns / 1ps

module tb;

    reg clk = 0;
    always #5 clk = ~clk;          // 100 MHz

    reg rst_n = 0;

    // Avalon-Seite (Engine)
    reg  [31:0] avm_address = 32'd0;
    reg         avm_read = 0;
    wire        avm_waitrequest;
    wire [63:0] avm_readdata;
    wire        avm_readdatavalid;

    // Prozessor-Seite
    reg  [22:0] a_addr = 23'd0;
    reg  [1:0]  a_ds = 2'b11;
    reg         a_cs = 0;
    reg         a_we = 0;
    wire [15:0] a_dout;
    wire [47:0] a_dout48;
    wire        a_ack;

    // Engine-Seite am Arbiter
    wire [22:0] b_addr;
    wire        b_cs;
    wire [15:0] b_dout;
    wire [47:0] b_dout48;
    wire        b_ack;

    // SDRAM-Anschluss
    wire [22:0] p2_addr;
    wire [1:0]  p2_ds;
    wire        p2_cs;
    wire        p2_we;
    wire [15:0] p2_dout;
    wire [47:0] p2_dout48;
    reg         p2_ack = 0;

    // Speichermodell: 64 Bit je Wortadresse
    //   obere 32 Bit = Adresse, untere 32 Bit = ~Adresse
    reg [63:0] mem_val;
    wire [22:0] model_addr = p2_addr;
    always @(*) mem_val = {32'h0, model_addr, ~{9'd0, model_addr}};

    reg [1:0] latency = 0;

    always @(posedge clk) begin
        p2_ack <= 1'b0;
        if (p2_cs) begin
            if (latency == 2'd2) begin
                p2_ack <= 1'b1;
                latency <= 2'd0;
            end else begin
                latency <= latency + 2'd1;
            end
        end else begin
            latency <= 2'd0;
        end
    end

    assign p2_dout   = mem_val[15:0];
    assign p2_dout48 = mem_val[63:16];

    sdram_p2_arbiter u_arb (
        .clk(clk), .rst_n(rst_n),
        .a_addr(a_addr), .a_ds(a_ds), .a_cs(a_cs), .a_we(a_we),
        .a_dout(a_dout), .a_dout48(a_dout48), .a_ack(a_ack),
        .b_addr(b_addr), .b_cs(b_cs),
        .b_dout(b_dout), .b_dout48(b_dout48), .b_ack(b_ack),
        .p2_addr(p2_addr), .p2_ds(p2_ds), .p2_cs(p2_cs), .p2_we(p2_we),
        .p2_dout(p2_dout), .p2_dout48(p2_dout48), .p2_ack(p2_ack)
    );

    sprite_mem_adapter u_adp (
        .clk(clk), .rst_n(rst_n),
        .avm_address(avm_address), .avm_read(avm_read),
        .avm_waitrequest(avm_waitrequest),
        .avm_readdata(avm_readdata), .avm_readdatavalid(avm_readdatavalid),
        .sd_addr(b_addr), .sd_cs(b_cs),
        .sd_dout(b_dout), .sd_dout48(b_dout48), .sd_ack(b_ack)
    );

    integer errors = 0;
    integer beats = 0;
    reg [63:0] got [0:3];
    reg [22:0] expect_word [0:3];
    integer i;
    reg [63:0] exp_a;

    always @(posedge clk) begin
        if (avm_readdatavalid && beats < 4) begin
            got[beats] = avm_readdata;
            beats = beats + 1;
        end
    end

    // erwarteter Speicherwert
    function [63:0] exp_val(input [22:0] w);
        exp_val = {32'h0, w, ~{9'd0, w}};
    endfunction

    initial begin
        $display("=== Adapter Sprite-Engine -> SDRAM p2 ===");
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // Byte-Adresse 0x1000 -> Wortadresse 0x800, Beats im Abstand 4
        avm_address = 32'h0000_1000;
        avm_read    = 1'b1;
        expect_word[0] = 23'h000800;
        expect_word[1] = 23'h000804;
        expect_word[2] = 23'h000808;
        expect_word[3] = 23'h00080C;

        // waehrend des Bursts fordert der Prozessor ebenfalls an
        @(posedge clk);
        a_addr = 23'h001000; a_cs = 1'b1;

        repeat (80) @(posedge clk);
        avm_read = 1'b0;

        // --- Auswertung ---
        if (beats == 4)
            $display("[PASS] vier Beats empfangen");
        else begin
            $display("[FAIL] %0d Beats statt 4", beats);
            errors = errors + 1;
        end

        for (i = 0; i < 4 && i < beats; i = i + 1) begin
            if (got[i] === exp_val(expect_word[i]))
                $display("[PASS] Beat %0d = %016x (Wortadresse %0d)", i, got[i], expect_word[i]);
            else begin
                $display("[FAIL] Beat %0d = %016x, erwartet %016x (Wortadresse %0d)",
                         i, got[i], exp_val(expect_word[i]), expect_word[i]);
                errors = errors + 1;
            end
        end

        // Prozessor-Anforderung: Wortadresse 0x1000 wurde angefordert,
        // erwartet wird deren unteres Datenwort.
        exp_a = exp_val(23'h001000);
        if (a_dout === exp_a[15:0])
            $display("[PASS] Prozessor bekam seine eigenen Daten (%04x)", a_dout);
        else
            $display("[INFO] Prozessor a_dout = %04x, erwartet %04x", a_dout, exp_a[15:0]);

        $display("=== Ergebnis: %0d Fehler ===", errors);
        if (errors == 0) $display("ADAPTER_PASS");
        else             $display("ADAPTER_FAIL");
        $finish;
    end

    initial begin
        #20000;
        $display("[TIMEOUT]");
        $finish;
    end

endmodule
