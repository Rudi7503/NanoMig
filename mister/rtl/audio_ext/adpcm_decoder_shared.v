// SPDX-License-Identifier: GPL-3.0-or-later
// Purely Combinatorial Zero-Latency ADPCM Engine for NanoMig TDM Ringbuffer Architecture.
// Takes {in_pcm, in_index, code, bits_per_code} -> outputs {out_pcm, out_index} in 0 clock cycles!

module adpcm_decoder_shared (
    input  wire               clk,           // Kept for interface compatibility
    input  wire               rst,           // Kept for interface compatibility
    
    // Cycle 0 Input
    input  wire               req_valid,
    input  wire signed [15:0] in_pcm,
    input  wire [6:0]         in_index,
    input  wire [4:0]         code,
    input  wire [2:0]         bits_per_code,

    // Combinatorial 0-latency Output (direct synchronous write into Ringbuffer RAM)
    output wire signed [15:0] out_pcm,
    output wire [6:0]         out_index
);

    // Constant ROM: 89 unsigned 16-bit step sizes
    function [15:0] get_step;
        input [6:0] idx;
        case (idx)
            7'd0:  get_step = 16'd7;     7'd1:  get_step = 16'd8;     7'd2:  get_step = 16'd9;
            7'd3:  get_step = 16'd10;    7'd4:  get_step = 16'd11;    7'd5:  get_step = 16'd12;
            7'd6:  get_step = 16'd13;    7'd7:  get_step = 16'd14;    7'd8:  get_step = 16'd16;
            7'd9:  get_step = 16'd17;    7'd10: get_step = 16'd19;    7'd11: get_step = 16'd21;
            7'd12: get_step = 16'd23;    7'd13: get_step = 16'd25;    7'd14: get_step = 16'd28;
            7'd15: get_step = 16'd31;    7'd16: get_step = 16'd34;    7'd17: get_step = 16'd37;
            7'd18: get_step = 16'd41;    7'd19: get_step = 16'd45;    7'd20: get_step = 16'd50;
            7'd21: get_step = 16'd55;    7'd22: get_step = 16'd60;    7'd23: get_step = 16'd66;
            7'd24: get_step = 16'd73;    7'd25: get_step = 16'd80;    7'd26: get_step = 16'd88;
            7'd27: get_step = 16'd97;    7'd28: get_step = 16'd107;   7'd29: get_step = 16'd118;
            7'd30: get_step = 16'd130;   7'd31: get_step = 16'd143;   7'd32: get_step = 16'd157;
            7'd33: get_step = 16'd173;   7'd34: get_step = 16'd190;   7'd35: get_step = 16'd209;
            7'd36: get_step = 16'd230;   7'd37: get_step = 16'd253;   7'd38: get_step = 16'd279;
            7'd39: get_step = 16'd307;   7'd40: get_step = 16'd337;   7'd41: get_step = 16'd371;
            7'd42: get_step = 16'd408;   7'd43: get_step = 16'd449;   7'd44: get_step = 16'd494;
            7'd45: get_step = 16'd544;   7'd46: get_step = 16'd598;   7'd47: get_step = 16'd658;
            7'd48: get_step = 16'd724;   7'd49: get_step = 16'd796;   7'd50: get_step = 16'd876;
            7'd51: get_step = 16'd963;   7'd52: get_step = 16'd1060;  7'd53: get_step = 16'd1166;
            7'd54: get_step = 16'd1282;  7'd55: get_step = 16'd1411;  7'd56: get_step = 16'd1552;
            7'd57: get_step = 16'd1707;  7'd58: get_step = 16'd1878;  7'd59: get_step = 16'd2066;
            7'd60: get_step = 16'd2272;  7'd61: get_step = 16'd2499;  7'd62: get_step = 16'd2749;
            7'd63: get_step = 16'd3024;  7'd64: get_step = 16'd3327;  7'd65: get_step = 16'd3660;
            7'd66: get_step = 16'd4026;  7'd67: get_step = 16'd4428;  7'd68: get_step = 16'd4871;
            7'd69: get_step = 16'd5358;  7'd70: get_step = 16'd5894;  7'd71: get_step = 16'd6484;
            7'd72: get_step = 16'd7132;  7'd73: get_step = 16'd7845;  7'd74: get_step = 16'd8630;
            7'd75: get_step = 16'd9493;  7'd76: get_step = 16'd10442; 7'd77: get_step = 16'd11487;
            7'd78: get_step = 16'd12635; 7'd79: get_step = 16'd13899; 7'd80: get_step = 16'd15289;
            7'd81: get_step = 16'd16818; 7'd82: get_step = 16'd18500; 7'd83: get_step = 16'd20350;
            7'd84: get_step = 16'd22385; 7'd85: get_step = 16'd24623; 7'd86: get_step = 16'd27086;
            7'd87: get_step = 16'd29794; default: get_step = 16'd32767;
        endcase
    endfunction

    wire [15:0] step = get_step(in_index);
    wire [2:0] sh = (bits_per_code == 3'd2) ? 3'd1 :
                    (bits_per_code == 3'd3) ? 3'd2 :
                    (bits_per_code == 3'd4) ? 3'd3 : 3'd4;
    wire negative = (bits_per_code == 3'd2) ? code[1] :
                    (bits_per_code == 3'd3) ? code[2] :
                    (bits_per_code == 3'd4) ? code[3] : code[4];
    wire [3:0] mag = (bits_per_code == 3'd2) ? {3'b0, code[0]} :
                     (bits_per_code == 3'd3) ? {2'b0, code[1:0]} :
                     (bits_per_code == 3'd4) ? {1'b0, code[2:0]} : code[3:0];

    // Multiplier for exact delta: delta = (step * ((mag << 1) | 1)) >> sh
    wire [20:0] mult_val = step * {mag, 1'b1};
    wire [16:0] delta = mult_val >> sh;

    reg signed [5:0] index_delta;
    always @* begin
        case (bits_per_code)
            3'd2: index_delta = code[0] ? 6'sd2 : -6'sd1;
            3'd3: case (code[1:0])
                2: index_delta = 6'sd1;
                3: index_delta = 6'sd2;
                default: index_delta = -6'sd1;
            endcase
            3'd4: case (code[2:0])
                4: index_delta = 6'sd2;
                5: index_delta = 6'sd4;
                6: index_delta = 6'sd6;
                7: index_delta = 6'sd8;
                default: index_delta = -6'sd1;
            endcase
            3'd5: case (code[3:0])
                8:  index_delta = 6'sd1;
                9:  index_delta = 6'sd2;
                10: index_delta = 6'sd4;
                11: index_delta = 6'sd6;
                12: index_delta = 6'sd8;
                13: index_delta = 6'sd10;
                14: index_delta = 6'sd13;
                15: index_delta = 6'sd16;
                default: index_delta = -6'sd1;
            endcase
            default: index_delta = -6'sd1;
        endcase
    end

    wire signed [8:0] next_index = $signed({2'b00, in_index}) + index_delta;
    wire signed [17:0] next_pcm = negative ?
        ($signed({{2{in_pcm[15]}}, in_pcm}) - $signed({1'b0, delta})) :
        ($signed({{2{in_pcm[15]}}, in_pcm}) + $signed({1'b0, delta}));

    wire pos_ovf = !next_pcm[17] && (|next_pcm[16:15]);
    wire neg_ovf =  next_pcm[17] && (!(&next_pcm[16:15]));
    wire signed [15:0] sat_pcm = pos_ovf ? 16'sh7fff : (neg_ovf ? 16'sh8000 : next_pcm[15:0]);

    reg [6:0] sat_index;
    always @* begin
        if (next_index[8]) sat_index = 7'd0;
        else if (next_index > 88) sat_index = 7'd88;
        else sat_index = next_index[6:0];
    end

    assign out_pcm   = sat_pcm;
    assign out_index = sat_index;

endmodule
