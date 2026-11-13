// ====================================================================
//  spr_test_pattern.v
//  Sprite-Testmuster aus internem Block-RAM (Toby, 2026-11-13).
//
//  Warum
//  -----
//  Die Sprite-Engine am SDRAM der Tang-Konsole hat den Boot zerstört:
//  sobald der Arbiter im Prozessorpfad lag, blieb das Bild schwarz.
//  Toby's Vorschlag: das Muster aus internem Speicher lesen und den
//  Prozessor direkt am SDRAM lassen. Dann lassen sich Boot und
//  Sprite-Anzeige gemeinsam prüfen, ohne den CPU-Pfad anzufassen.
//
//  Aufbau
//  ------
//  Dieses Modul antwortet auf der Avalon-MM-Schnittstelle der Engine
//  mit einem fest eingebauten Muster. Es liest nie etwas Echtes.
//
//  Speicherbild (Byte-Adressen):
//    0x1000  Deskriptor 0, 16 Byte   (ein Sprite, RGB16, 64x32)
//    0x1010  Deskriptor 1, 16 Byte   (Sentinel, Hoehe 0)
//    0x2000  Pixeldaten, 4 Bursts a 32 Byte, Format RGB16
//
//  Descriptor-Bitlayout (wie sprite_engine_dma.v es liest):
//    Wort 0: [63:52] y_pos, [51:40] x_pos, [39:32] flags, [31:0] data_ptr
//    Wort 1: [63:52] height, [51:40] width_px, [39:32] fmt,
//            [31:24] prio, [23:16] alpha, [15:8] x_scale, [7:0] y_scale
//
//  Antwortzeit: zwei Takte, dann readdatavalid fuer einen Takt.
//
// ====================================================================

`timescale 1ns / 1ps

module spr_test_pattern (
    input  wire        clk,
    input  wire        rst_n,

    // Avalon-MM Master der Engine
    input  wire [31:0] avm_address,
    input  wire        avm_read,
    output reg         avm_waitrequest,
    output reg  [63:0] avm_readdata,
    output reg         avm_readdatavalid
);

    // ----------------------------------------------------------------
    // Deskriptor 0: ein Sprite bei x=64, y=32, 64x32 Pixel, RGB16
    // ----------------------------------------------------------------
    localparam [63:0] DESC0_W0 = {12'd32, 12'd64, 8'h00, 32'h0000_2000};
    localparam [63:0] DESC0_W1 = {12'd32, 12'd64, 8'd15, 8'h80, 8'd255, 8'd0, 8'd0};
    localparam [63:0] DESC1_W0 = 64'd0;
    localparam [63:0] DESC1_W1 = 64'd0;

    // ----------------------------------------------------------------
    // Pixeldaten: ein farbiger Balken, RGB16 (5-6-5)
    //   Wort 0..3 = erste Zeile-Burst, danach wiederholt es sich
    // ----------------------------------------------------------------
    function [63:0] pix_word(input [22:0] word_addr);
        reg [15:0] px;
        begin
            // vier Pixel je 64-Bit-Wort, Muster aus der Wortadresse
            px = {5'd31, 6'd0, 5'd0};                       // rot
            if (word_addr[1:0] == 2'd1) px = {5'd0, 6'd63, 5'd0};   // gruen
            if (word_addr[1:0] == 2'd2) px = {5'd0, 6'd0, 5'd31};   // blau
            if (word_addr[1:0] == 2'd3) px = {5'd31, 6'd63, 5'd31}; // weiss
            pix_word = {px, px, px, px};
        end
    endfunction

    reg [2:0]  state;
    reg [22:0] base_word;
    reg [1:0]  beat;

    // Das Kommando ist immer ein Burst von 4 Beats (BURSTCNT = 4).
    // Ein 64-Bit-Beat sind vier 16-Bit-Woerter, also +4 je Beat
    wire [22:0] beat_word = base_word + {beat, 2'b00};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= 3'd0;
            avm_waitrequest   <= 1'b0;
            avm_readdata      <= 64'd0;
            avm_readdatavalid <= 1'b0;
            base_word         <= 23'd0;
            beat              <= 2'd0;
        end else begin
            avm_readdatavalid <= 1'b0;

            case (state)
                3'd0: begin
                    avm_waitrequest <= 1'b0;
                    if (avm_read) begin
                        base_word       <= avm_address[23:1];
                        beat            <= 2'd0;
                        avm_waitrequest <= 1'b1;
                        state           <= 3'd1;
                    end
                end

                3'd1: state <= 3'd2;      // eine Taktstufe Latenz

                3'd2: begin
                    if (beat_word == 23'h000800)      avm_readdata <= DESC0_W0;
                    else if (beat_word == 23'h000804) avm_readdata <= DESC0_W1;
                    else if (beat_word == 23'h000808) avm_readdata <= DESC1_W0;
                    else if (beat_word == 23'h00080C) avm_readdata <= DESC1_W1;
                    else                              avm_readdata <= pix_word(beat_word);
                    avm_readdatavalid <= 1'b1;
                    if (beat == 2'd3) begin
                        avm_waitrequest <= 1'b0;
                        state           <= 3'd0;
                    end else begin
                        beat  <= beat + 2'd1;
                        state <= 3'd2;     // naechster Beat, ein Takt je Beat
                    end
                end

                default: state <= 3'd0;
            endcase
        end
    end
endmodule
