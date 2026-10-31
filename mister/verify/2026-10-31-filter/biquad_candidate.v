// SPDX-License-Identifier: GPL-3.0-or-later
// 16-Channel 2nd-Order Biquad IIR Filter Engine with Simple Dual-Port RAM Architecture & Single-DSP Sharing.
// Supports independent Left/Right channel filtering (AUDxCTRL bits 8..7: 00=off, 01=R, 10=L, 11=both).
// Portable Standard Verilog implementation for Altera/Intel Cyclone V (MiSTer).

module biquad_iir_ringbuffer (
    input wire clk,
    input wire reset,

    // CPU Configuration Interface (off 8..12 -> b0, b1, b2, a1, a2)
    input wire        reg_cs,
    input wire        reg_wr,
    input wire [6:0]  reg_addr, // ch [6:3], coeff_idx [2:0]
    input wire [1:0]  reg_be,
    input wire [15:0] reg_wdata,
    output wire [15:0] reg_rdata,

    // Audio TDM Interface
    input wire [3:0]          cur_voice,
    input wire                filter_en_l, // from v_ctrl[8]
    input wire                filter_en_r, // from v_ctrl[7]
    input wire                is_stereo,   // from v_ctrl[2]
    input wire                req_strobe,  // do_decode pulse
    input wire signed [15:0]  in_pcm_l,    // new_pcm Left
    input wire signed [15:0]  in_pcm_r,    // new_pcm Right
    output wire signed [15:0] out_pcm_l,   // filtered Left
    output wire signed [15:0] out_pcm_r    // filtered Right
);

    wire [3:0] ch = reg_addr[6:3];
    wire [2:0] coeff_idx = reg_addr[2:0];

    // CPU word address for coefficients: 16 voices x 8 words (0..4 used) = 128 words
    wire [6:0] cpu_coeff_addr = {ch, coeff_idx[2:0]};

    // A pending sample per voice decouples adjacent TDM requests from
    // the multi-cycle DSP. Sustained offered load must remain below service
    // capacity; pending_overflow records an overwritten pending sample.
    reg [15:0] pending;
    reg [15:0] pending_l[0:15], pending_r[0:15];
    reg [2:0] pending_flags[0:15];
    reg [3:0] scan_start;
    reg pending_overflow;
    reg have_pending;
    reg [3:0] selected;
    integer scan;
    // Two fixed-index priority passes implement circular first-pending
    // selection without truncated adders or variable pending-bit indexing.
    always @* begin
        have_pending = |pending;
        selected = scan_start;
        for (scan=15; scan>=0; scan=scan-1)
            if (pending[scan]) selected = scan[3:0];
        for (scan=15; scan>=0; scan=scan-1)
            if (pending[scan] && scan_start <= scan[3:0])
                selected = scan[3:0];
    end
    wire take_pending=(state==0) && have_pending;
    always @(posedge clk) begin
        if(reset) begin pending<=0;scan_start<=0;pending_overflow<=0;end
        else begin
            if(take_pending) begin
                pending[selected]<=0;scan_start<=selected+1'b1;
            end
            if(req_strobe && (filter_en_l || filter_en_r)) begin
                if(pending[cur_voice] && !(take_pending && selected==cur_voice))
                    pending_overflow<=1'b1;
                pending[cur_voice]<=1'b1;
                pending_l[cur_voice]<=in_pcm_l;
                pending_r[cur_voice]<=in_pcm_r;
                pending_flags[cur_voice]<={is_stereo,filter_en_l,filter_en_r};
            end
        end
    end

    // Sequential Biquad FSM
    reg [3:0] state;
    reg [3:0] proc_ch;
    reg       proc_side;     // 0 = Left (or Mono), 1 = Right
    reg       proc_stereo;
    reg       proc_flt_r;
    reg signed [15:0] proc_x;
    reg signed [15:0] proc_x_r;
    reg signed [33:0] acc;

    // Latches for state pipeline
    reg signed [15:0] lat_x1, lat_y1;

    // Saturation logic for Biquad output (Q2.14)
    wire signed [19:0] y_sc = acc[33:14];
    wire signed [15:0] y_sat = (!y_sc[19] && |y_sc[18:15]) ? 16'sh7FFF :
                               ( y_sc[19] && !(&y_sc[18:15])) ? 16'sh8000 : y_sc[15:0];

    // 16 Output values stored in register array
    reg signed [15:0] y_held_l [0:15];
    reg signed [15:0] y_held_r [0:15];

    wire we_l = (state == 4'd13) && (proc_side == 1'b0);
    wire we_r = (state == 4'd13) && (proc_side == 1'b1 || !proc_stereo);

    always @(posedge clk) begin
        if (we_l) y_held_l[proc_ch] <= y_sat;
        if (we_r) y_held_r[proc_ch] <= y_sat;
    end

    // --- 1. Coefficient RAM (Simple Dual-Port: CPU writes, FSM reads) ---
    // 128 entries of 16-bit
    reg [15:0] coeff_ram [0:127];
    reg [15:0] cpu_rdata_raw;
    reg [15:0] fsm_coeff_rdata;

    // Issue synchronous RAM reads one clock before consuming their outputs.
    wire [2:0] read_coeff = (state == 0 || state >= 10) ? 3'd0 :
                            (state <= 2) ? 3'd1 : (state <= 4) ? 3'd2 :
                            (state <= 6) ? 3'd3 : 3'd4;
    wire [6:0] fsm_coeff_addr = {(state == 0 ? selected : proc_ch), read_coeff};

    always @(posedge clk) begin
        if (reg_cs && reg_wr) begin
            if (reg_be[1]) coeff_ram[cpu_coeff_addr][15:8] <= reg_wdata[15:8];
            if (reg_be[0]) coeff_ram[cpu_coeff_addr][ 7:0] <= reg_wdata[ 7:0];
        end
        cpu_rdata_raw   <= coeff_ram[cpu_coeff_addr];
        fsm_coeff_rdata <= coeff_ram[fsm_coeff_addr];
    end
    assign reg_rdata = cpu_rdata_raw;

    // --- 2. State RAM (Simple Dual-Port: FSM writes, FSM reads) ---
    // 128 entries of 16-bit: {side, ch[3:0], var[1:0]}
    // var: 0=x1, 1=x2, 2=y1, 3=y2
    reg [15:0] state_ram [0:127];
    reg [15:0] fsm_state_rdata;
    reg [31:0] history_valid;
    wire history_ready = history_valid[{proc_side,proc_ch}];
    always @(posedge clk) begin
        if (reset) history_valid <= 0;
        else if (state == 13) history_valid[{proc_side,proc_ch}] <= 1'b1;
    end

    wire [1:0] read_var = (state <= 2 || state >= 10) ? 2'd0 :
                          (state <= 4) ? 2'd1 : (state <= 6) ? 2'd2 : 2'd3;
    wire [6:0] fsm_state_rd_addr = {proc_side, proc_ch, read_var};

    wire [1:0] fsm_wr_var = (state == 4'd10) ? 2'd1 : // x2 <= lat_x1
                            (state == 4'd11) ? 2'd0 : // x1 <= proc_x
                            (state == 4'd12) ? 2'd3 : // y2 <= lat_y1
                                               2'd2;  // y1 <= y_sat
    wire [6:0] fsm_state_wr_addr = {proc_side, proc_ch, fsm_wr_var};
    wire [15:0] fsm_state_wdata  = (state == 4'd10) ? lat_x1 :
                                   (state == 4'd11) ? proc_x  :
                                   (state == 4'd12) ? lat_y1  :
                                                      y_sat;
    wire fsm_state_we = (state >= 4'd10 && state <= 4'd13);

    always @(posedge clk) begin
        if (fsm_state_we) begin
            state_ram[fsm_state_wr_addr] <= fsm_state_wdata;
        end
        fsm_state_rdata <= state_ram[fsm_state_rd_addr];
    end

    // Registered operands feed the multiplier; the following even state
    // consumes the product. RAM outputs must never be interchanged.
    reg signed [15:0] dsp_a;
    reg signed [15:0] dsp_b;
    wire signed [31:0] mul_prod = dsp_a * dsp_b;
    wire signed [33:0] prod_ext = {{2{mul_prod[31]}}, mul_prod};
    always @(posedge clk) begin
        if (state == 1) begin
            dsp_a <= proc_x;
            dsp_b <= fsm_coeff_rdata;
        end else if (state == 3 || state == 5 || state == 7 || state == 9) begin
            dsp_a <= history_ready ? fsm_state_rdata : 16'd0;
            dsp_b <= fsm_coeff_rdata;
        end
    end

    // Accumulator: Only 3 active states
    always @(posedge clk) begin
        if (reset) acc <= 34'd0;
        else case (state)
            4'd2: acc <= prod_ext;
            4'd4, 4'd6: acc <= acc + prod_ext;
            4'd8, 4'd10: acc <= acc - prod_ext;
            default: ;
        endcase
    end

    // FSM State Transition: 4-bit Counter with dual-pass for Stereo
    always @(posedge clk) begin
        if (reset) begin
            state       <= 4'd0;
            proc_ch     <= 4'd0;
            proc_side   <= 1'b0;
            proc_stereo <= 1'b0;
            proc_flt_r  <= 1'b0;
            proc_x      <= 16'd0;
            proc_x_r    <= 16'd0;
            lat_x1      <= 16'd0;
            lat_y1      <= 16'd0;
        end else begin
            case (state)
                4'd0: begin
                    if (have_pending) begin
                        proc_ch     <= selected;
                        proc_stereo <= pending_flags[selected][2];
                        proc_flt_r  <= pending_flags[selected][0];
                        proc_x_r    <= pending_r[selected];
                        if (pending_flags[selected][1]) begin
                            proc_side <= 1'b0;
                            proc_x    <= pending_l[selected];
                            state     <= 4'd1;
                        end else begin
                            proc_side <= 1'b1;
                            proc_x    <= pending_r[selected];
                            state     <= 4'd1;
                        end
                    end
                end

                4'd1, 4'd2, 4'd3, 4'd4, 4'd5, 4'd6, 4'd7, 4'd8, 4'd9: begin
                    if (state == 4'd3) lat_x1 <= history_ready ? fsm_state_rdata : 16'd0;
                    if (state == 4'd7) lat_y1 <= history_ready ? fsm_state_rdata : 16'd0;
                    state <= state + 1'b1;
                end

                4'd10, 4'd11, 4'd12: begin
                    state <= state + 1'b1;
                end

                4'd13: begin
                    if (!proc_side && proc_stereo && proc_flt_r) begin
                        proc_side <= 1'b1;
                        proc_x    <= proc_x_r;
                        state     <= 4'd1; // Second pass for Right Stereo channel
                    end else begin
                        state <= 4'd0;     // Finished processing
                    end
                end

                default: state <= 4'd0;
            endcase
        end
    end

    // Direct bypass selection: If filter disabled, pass raw in_pcm directly
    assign out_pcm_l = filter_en_l ? (history_valid[{1'b0,cur_voice}] ? y_held_l[cur_voice] : 16'sd0) : in_pcm_l;
    assign out_pcm_r = filter_en_r ? ((is_stereo ? history_valid[{1'b1,cur_voice}] : (history_valid[{1'b0,cur_voice}] || history_valid[{1'b1,cur_voice}])) ? y_held_r[cur_voice] : 16'sd0) : in_pcm_r;

endmodule
