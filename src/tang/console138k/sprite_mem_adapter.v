// ====================================================================
//
//  sprite_mem_adapter.v
//  Bruecke zwischen der Sprite-Engine (Avalon-MM, 64 Bit, Burst 4) und
//  dem SDRAM-Anschluss p2 der Tang-Konsole.
//
//  Warum das noetig ist
//  --------------------
//  Die Sprite-Engine fordert 32-Byte-Bursts mit 64-Bit-Breite an. Der
//  SDRAM-Baustein der Tang-Konsole haengt an einem 16-Bit-Anschluss. Er
//  liefert bei einem ausgerichteten 8-Byte-Lesezugriff aber bereits
//  64 Bit: {p2_dout48, p2_dout}. Genau darauf setzt dieser Adapter auf.
//
//  Der p2-Anschluss ist der CPU-/Fast-RAM-Anschluss und kann nur von
//  einem Teilnehmer benutzt werden. Der Arbiter teilt ihn zwischen dem
//  Prozessor und der Engine. Beide Seiten arbeiten mit einem
//  Anforderungs-/Bestaetigungs-Handshake (cs -> ack), deshalb darf eine
//  Anforderung warten, ohne dass Daten verloren gehen.
//
//  Adressen
//  --------
//  Die Engine arbeitet mit Amiga-Byte-Adressen. Der SDRAM-Anschluss will
//  Wortadressen (p2_addr = byte >> 1). Ein Burst von 4 Beats a 8 Byte
//  sind also 4 Wortadressen im Abstand von 4.
//
// ====================================================================

`timescale 1ns / 1ps

// --------------------------------------------------------------------
//  Arbiter: ein SDRAM-Anschluss, zwei Teilnehmer
// --------------------------------------------------------------------
module sdram_p2_arbiter (
    input  wire        clk,
    input  wire        rst_n,

    // Teilnehmer A: Prozessor / Fast-RAM (bestehender Pfad)
    input  wire [22:0] a_addr,
    input  wire [1:0]  a_ds,
    input  wire        a_cs,
    input  wire        a_we,
    output reg  [15:0] a_dout,
    output reg  [47:0] a_dout48,
    output reg         a_ack,

    // Teilnehmer B: Sprite-Engine (nur lesend)
    input  wire [22:0] b_addr,
    input  wire        b_cs,
    output reg  [15:0] b_dout,
    output reg  [47:0] b_dout48,
    output reg         b_ack,

    // SDRAM-Anschluss
    output reg  [22:0] p2_addr,
    output reg  [1:0]  p2_ds,
    output reg         p2_cs,
    output reg         p2_we,
    input  wire [15:0] p2_dout,
    input  wire [47:0] p2_dout48,
    input  wire        p2_ack
);

    localparam OWNER_NONE = 2'd0;
    localparam OWNER_A    = 2'd1;
    localparam OWNER_B    = 2'd2;

    reg [1:0] owner;
    reg       last_was_b;      // Fairness: bei Gleichzeitigkeit abwechseln

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            owner      <= OWNER_NONE;
            last_was_b <= 1'b0;
            p2_addr    <= 23'd0;
            p2_ds      <= 2'b00;
            p2_cs      <= 1'b0;
            p2_we      <= 1'b0;
            a_ack      <= 1'b0;
            b_ack      <= 1'b0;
            a_dout     <= 16'd0;
            a_dout48   <= 48'd0;
            b_dout     <= 16'd0;
            b_dout48   <= 48'd0;
        end else begin
            a_ack <= 1'b0;
            b_ack <= 1'b0;

            case (owner)
                OWNER_NONE: begin
                    p2_cs <= 1'b0;
                    if (a_cs && b_cs) begin
                        if (last_was_b) begin
                            owner   <= OWNER_A;
                            p2_addr <= a_addr;
                            p2_ds   <= a_ds;
                            p2_we   <= a_we;
                            p2_cs   <= 1'b1;
                        end else begin
                            owner   <= OWNER_B;
                            p2_addr <= b_addr;
                            p2_ds   <= 2'b11;
                            p2_we   <= 1'b0;
                            p2_cs   <= 1'b1;
                        end
                    end else if (a_cs) begin
                        owner   <= OWNER_A;
                        p2_addr <= a_addr;
                        p2_ds   <= a_ds;
                        p2_we   <= a_we;
                        p2_cs   <= 1'b1;
                    end else if (b_cs) begin
                        owner   <= OWNER_B;
                        p2_addr <= b_addr;
                        p2_ds   <= 2'b11;
                        p2_we   <= 1'b0;
                        p2_cs   <= 1'b1;
                    end
                end

                OWNER_A: begin
                    if (p2_ack) begin
                        a_dout   <= p2_dout;
                        a_dout48 <= p2_dout48;
                        a_ack    <= 1'b1;
                        p2_cs    <= 1'b0;
                        owner    <= OWNER_NONE;
                        last_was_b <= 1'b0;
                    end
                end

                OWNER_B: begin
                    if (p2_ack) begin
                        b_dout   <= p2_dout;
                        b_dout48 <= p2_dout48;
                        b_ack    <= 1'b1;
                        p2_cs    <= 1'b0;
                        owner    <= OWNER_NONE;
                        last_was_b <= 1'b1;
                    end
                end

                default: owner <= OWNER_NONE;
            endcase
        end
    end

endmodule


// --------------------------------------------------------------------
//  Adapter: Avalon-MM-Master der Engine  ->  SDRAM-Anschluss
// --------------------------------------------------------------------
module sprite_mem_adapter (
    input  wire        clk,
    input  wire        rst_n,

    // Avalon-MM Master der Sprite-Engine (so wie die Engine ihn sieht)
    input  wire [31:0] avm_address,
    input  wire        avm_read,
    output reg         avm_waitrequest,
    output reg  [63:0] avm_readdata,
    output reg         avm_readdatavalid,

    // SDRAM-Seite des Arbiters (Teilnehmer B)
    output reg  [22:0] sd_addr,
    output reg         sd_cs,
    input  wire [15:0] sd_dout,
    input  wire [47:0] sd_dout48,
    input  wire        sd_ack
);

    localparam IDLE   = 3'd0;
    localparam ISSUE  = 3'd1;
    localparam WAIT   = 3'd2;
    localparam BEAT   = 3'd3;
    localparam DONE   = 3'd4;

    reg [2:0]  state;
    reg [22:0] base_word;      // Wortadresse des ersten Beats
    reg [1:0]  beat;

    // Byte-Adresse -> Wortadresse; die Engine liefert 8-Byte-Bursts
    wire [22:0] beat_word = base_word + {beat, 2'b00};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= IDLE;
            base_word         <= 23'd0;
            beat              <= 2'd0;
            sd_addr           <= 23'd0;
            sd_cs             <= 1'b0;
            avm_waitrequest   <= 1'b0;
            avm_readdata      <= 64'd0;
            avm_readdatavalid <= 1'b0;
        end else begin
            avm_readdatavalid <= 1'b0;

            case (state)
                IDLE: begin
                    sd_cs           <= 1'b0;
                    avm_waitrequest <= 1'b0;
                    if (avm_read) begin
                        base_word       <= avm_address[23:1];
                        beat            <= 2'd0;
                        avm_waitrequest <= 1'b1;
                        state           <= ISSUE;
                    end
                end

                ISSUE: begin
                    sd_addr <= beat_word;
                    sd_cs   <= 1'b1;
                    state   <= WAIT;
                end

                WAIT: begin
                    if (sd_ack) begin
                        avm_readdata      <= {sd_dout48, sd_dout};
                        avm_readdatavalid <= 1'b1;
                        sd_cs             <= 1'b0;
                        state             <= BEAT;
                    end
                end

                BEAT: begin
                    if (beat == 2'd3) begin
                        avm_waitrequest <= 1'b0;
                        state           <= DONE;
                    end else begin
                        beat  <= beat + 2'd1;
                        state <= ISSUE;
                    end
                end

                DONE: begin
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
