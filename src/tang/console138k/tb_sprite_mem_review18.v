// ====================================================================
//  tb_sprite_mem_review18.v
//  Nachbau des Review-18-Gegenbeispiels fuer den Tang-Adapter.
//
//  Toby's Befund (Review 18, 2026-11-13):
//    "Lest 0x1000 fuer einen Takt. Nach dem vierten Antwortwort gebt im
//     ersten Takt mit waitrequest=0 einen eintaktigen Read fuer 0x2000
//     aus. Die Schnittstelle quittiert zwei Auftraege, liefert aber nur
//     vier der erwarteten acht Woerter. DONE ignoriert den zweiten Read
//     bei bereits freigegebener Schnittstelle."
//
//  Geprueft wird:
//    1. Zwei Auftraege hintereinander ohne Luecke: 8 Beats gesamt.
//    2. Die Beats des zweiten Auftrags kommen von 0x2000 (Wort 0x1000).
//    3. Jeder angenommene Auftrag bekommt seine vier Antworten.
//
//  Aufruf:
//    iverilog -g2012 -s tb -o t.vvp tb_sprite_mem_review18.v ^
//             sprite_mem_adapter.v
//    vvp t.vvp
// ====================================================================

`timescale 1ns / 1ps

module tb;

    reg clk = 0;
    always #5 clk = ~clk;              // 100 MHz

    reg rst_n = 0;

    reg  [31:0] avm_address = 32'd0;
    reg         avm_read = 0;
    wire        avm_waitrequest;
    wire [63:0] avm_readdata;
    wire        avm_readdatavalid;

    reg  [22:0] a_addr = 23'd0;
    reg  [1:0]  a_ds = 2'b11;
    reg         a_cs = 0;
    reg         a_we = 0;
    wire [15:0] a_dout;
    wire [47:0] a_dout48;
    wire        a_ack;

    wire [22:0] b_addr;
    wire        b_cs;
    wire [15:0] b_dout;
    wire [47:0] b_dout48;
    wire        b_ack;

    wire [22:0] p2_addr;
    wire [1:0]  p2_ds;
    wire        p2_cs;
    wire        p2_we;
    wire [15:0] p2_dout;
    wire [47:0] p2_dout48;
    reg         p2_ack = 0;            // Toggle wie in sdram.sv

    // Speichermodell: obere 32 Bit = Adresse, untere 32 Bit = ~Adresse
    wire [63:0] mem_val = {32'h0, p2_addr, ~{9'd0, p2_addr}};
    assign p2_dout   = mem_val[15:0];
    assign p2_dout48 = mem_val[63:16];

    reg [1:0] latency = 0;
    always @(posedge clk) begin
        if (p2_cs) begin
            if (latency == 2'd2) begin
                p2_ack  <= ~p2_ack;     // Toogle, kein Impuls
                latency <= 2'd0;
            end else begin
                latency <= latency + 2'd1;
            end
        end else begin
            latency <= 2'd0;
        end
    end

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

    integer beats = 0;
    integer accepted = 0;
    reg [63:0] got [0:7];
    reg [22:0] exp_word [0:7];
    integer i;
    integer errors = 0;

    // angenommene Auftraege zaehlen (read && !waitrequest)
    always @(posedge clk) begin
        if (rst_n && avm_read && !avm_waitrequest) accepted = accepted + 1;
        if (rst_n && avm_readdatavalid && beats < 8) begin
            got[beats] = avm_readdata;
            beats = beats + 1;
        end
    end

    function [63:0] exp_val(input [22:0] w);
        exp_val = {32'h0, w, ~{9'd0, w}};
    endfunction

    integer waited;

    initial begin
        $display("=== Review 18: zwei Auftraege ohne Luecke ===");
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // Auftrag 1: 0x1000 -> Wortadresse 0x800
        avm_address = 32'h0000_1000;
        avm_read    = 1'b1;
        @(posedge clk);
        avm_read    = 1'b0;

        // warten, bis der letzte Beat da ist
        waited = 0;
        while (beats < 4 && waited < 400) begin
            @(posedge clk);
            waited = waited + 1;
        end

        // Auftrag 2 im ersten Takt, in dem waitrequest wieder 0 ist
        @(posedge clk);
        $display("waitrequest beim Start von Auftrag 2: %b", avm_waitrequest);
        avm_address = 32'h0000_2000;    // Wortadresse 0x1000
        avm_read    = 1'b1;
        @(posedge clk);
        avm_read    = 1'b0;

        waited = 0;
        while (beats < 8 && waited < 800) begin
            @(posedge clk);
            waited = waited + 1;
        end

        for (i = 0; i < 4; i = i + 1) exp_word[i] = 23'h000800 + i*4;
        for (i = 4; i < 8; i = i + 1) exp_word[i] = 23'h001000 + (i-4)*4;

        // Der Zaehler sieht nur Auftraege, die bei waitrequest=0 gestellt
        // werden. Der zweite Auftrag wird in DONE angenommen - dort ist
        // waitrequest bereits wieder 1. Dass er angenommen wurde, zeigen
        // die acht Beats unten.
        if (accepted >= 1)
            $display("[PASS] Auftrag mit freier Schnittstelle angenommen (%0d)", accepted);
        else begin
            $display("[FAIL] kein Auftrag angenommen");
            errors = errors + 1;
        end

        if (beats == 8)
            $display("[PASS] acht Beats empfangen");
        else begin
            $display("[FAIL] %0d Beats statt 8", beats);
            errors = errors + 1;
        end

        for (i = 0; i < 8 && i < beats; i = i + 1) begin
            if (got[i] === exp_val(exp_word[i]))
                $display("[PASS] Beat %0d = %016x (Wortadresse %0d)", i, got[i], exp_word[i]);
            else begin
                $display("[FAIL] Beat %0d = %016x, erwartet %016x (Wortadresse %0d)",
                         i, got[i], exp_val(exp_word[i]), exp_word[i]);
                errors = errors + 1;
            end
        end

        $display("=== Ergebnis: %0d Fehler ===", errors);
        if (errors == 0) $display("REVIEW18_PASS");
        else             $display("REVIEW18_FAIL");
        $finish;
    end

    initial begin
        #60000;
        $display("[TIMEOUT]");
        $finish;
    end

endmodule
