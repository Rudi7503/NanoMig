// ====================================================================
//
//  sprite_mem_adapter.v
//  Bruecke zwischen der Sprite-Engine (Avalon-MM, 64 Bit, Burst 4) und
//  dem SDRAM-Anschluss p2 der Tang-Konsole.
//
//  Aufbau
//  ------
//  Der p2-Anschluss gehoert dem Prozessor. Die Engine darf ihn nur
//  zwischen zwei Prozessortransaktionen benutzen.
//
//  Fassung 2 (2026-11-13)
//  ----------------------
//  Die erste Fassung hat den Bus fuer beide Seiten registriert und das
//  Ack als Ein-Takt-Impuls erzeugt. Auf der Konsole bootete der Core
//  damit nicht: LED gruen, Bild schwarz. Ursache:
//
//    sdram.sv erzeugt p2_ack als TOGGLE  (p2_ack_i <= ~p2_ack_i),
//    nanomig erkennt den Abschluss per Flankenvergleich
//    (fastram_ready != fastram_ready_d).
//
//  Aus einem Impuls werden damit zwei Flanken - der Cache-Automat
//  springt pro Transfer zweimal weiter. Jetzt spiegelt der Arbiter die
//  Toggle-Semantik je Teilnehmer, und der Prozessorpfad wird
//  kombinatorisch durchgereicht, solange die Engine ruht.
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
    output wire        a_ack,

    // Teilnehmer B: Sprite-Engine (nur lesend)
    input  wire [22:0] b_addr,
    input  wire        b_cs,
    output reg  [15:0] b_dout,
    output reg  [47:0] b_dout48,
    output reg         b_ack,

    // SDRAM-Anschluss
    output wire [22:0] p2_addr,
    output wire [1:0]  p2_ds,
    output wire        p2_cs,
    output wire        p2_we,
    input  wire [15:0] p2_dout,
    input  wire [47:0] p2_dout48,
    input  wire        p2_ack
);

    // Wer besitzt den Anschluss gerade? Nur die Engine muss ihn
    // uebernehmen, der Prozessor hat Vorrang und wird nie verzoegert.
    reg b_active;

    // ------------------------------------------------------------------
    // Bus-Multiplexer: ohne Engine-Aktivitaet sieht der Prozessor den
    // Anschluss unveraendert - kein zusaetzlicher Takt, keine Flanke.
    // ------------------------------------------------------------------
    assign p2_addr = b_active ? b_addr : a_addr;
    assign p2_ds   = b_active ? 2'b11  : a_ds;
    assign p2_cs   = b_active ? b_cs   : a_cs;
    assign p2_we   = b_active ? 1'b0   : a_we;

    // Daten fliessen immer zu beiden Seiten; jede nimmt nur, was sie
    // angefordert hat.
    always @(*) begin
        a_dout   = p2_dout;
        a_dout48 = p2_dout48;
        b_dout   = p2_dout;
        b_dout48 = p2_dout48;
    end

    // ------------------------------------------------------------------
    // Ack: Toggle-Semantik wie sdram.sv, aber je Teilnehmer getrennt.
    // Der Prozessor darf keine Flanke sehen, die von der Engine stammt.
    // ------------------------------------------------------------------
    reg p2_ack_d;
    reg a_ack_hold;   // letzter Stand, bevor die Engine den Bus uebernahm

    // WICHTIG: Solange der Prozessor den Anschluss hat, bekommt er das
    // Ack UNVERAENDERT - nicht registriert. nanomig wertet es phasenkritisch
    // aus (ram_ready = cpu_ph1 && flanke). Ein Takt Verzoegerung verschiebt
    // es aus dem Fenster, der Prozessor wartet ewig - schwarzes Bild.
    assign a_ack = b_active ? a_ack_hold : p2_ack;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_active   <= 1'b0;
            a_ack_hold <= 1'b0;
            b_ack      <= 1'b0;
            p2_ack_d   <= 1'b0;
        end else begin
            p2_ack_d <= p2_ack;

            if (!b_active) a_ack_hold <= p2_ack;

            // Flanke am SDRAM-Anschluss: gehoert sie dem Prozessor oder
            // der Engine? Nur der jeweilige Teilnehmer bekommt sie.
            if (b_active && (p2_ack != p2_ack_d)) b_ack <= ~b_ack;

            // Engine uebernimmt den Anschluss nur, wenn der Prozessor
            // gerade nichts will.
            if (!b_active) begin
                if (b_cs && !a_cs) b_active <= 1'b1;
            end else begin
                // Ende des Engine-Zugriffs: cs faellt, nachdem das Ack kam.
                if (!b_cs) b_active <= 1'b0;
            end
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
    reg        ack_d;

    // Byte-Adresse -> Wortadresse; die Engine liefert 8-Byte-Bursts
    wire [22:0] beat_word = base_word + {beat, 2'b00};

    // Das Ack ist ein Toggle: auf Flankenwechsel reagieren.
    wire ack_edge = (sd_ack != ack_d);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= IDLE;
            base_word         <= 23'd0;
            beat              <= 2'd0;
            sd_addr           <= 23'd0;
            sd_cs             <= 1'b0;
            ack_d             <= 1'b0;
            avm_waitrequest   <= 1'b0;
            avm_readdata      <= 64'd0;
            avm_readdatavalid <= 1'b0;
        end else begin
            avm_readdatavalid <= 1'b0;
            ack_d             <= sd_ack;

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
                    if (ack_edge) begin
                        avm_readdata      <= {sd_dout48, sd_dout};
                        avm_readdatavalid <= 1'b1;
                        sd_cs             <= 1'b0;
                        state             <= BEAT;
                    end
                end

                BEAT: begin
                    if (beat == 2'd3) begin
                        avm_waitrequest <= 1'b0;
                        state           <= IDLE;   // Toby: direkt nach IDLE, nicht ueber DONE
                    end else begin
                        beat  <= beat + 2'd1;
                        state <= ISSUE;
                    end
                end

                // Review 18: Nach dem letzten Beat faellt waitrequest, und
                // der Master darf im naechsten Takt einen neuen Auftrag
                // stellen. Wird er hier nicht angenommen, geht er verloren.
                // DONE nimmt deshalb genauso an wie IDLE.
                DONE: begin
                    if (avm_read) begin
                        base_word       <= avm_address[23:1];
                        beat            <= 2'd0;
                        avm_waitrequest <= 1'b1;
                        state           <= ISSUE;
                    end else begin
                        state <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
