`timescale 1ns/1ps
module tb;
reg clk=0; always #5 clk=~clk;
reg reset=1,cs=0,wr=0;
reg [9:1] addr=0;
reg [15:0] wdata=0;
wire [15:0] rdata,sl,sr;
wire req,irq; wire [31:0] dma_addr;
reg ack=0; reg [15:0] data=0;
audio_ext dut(.clk(clk),.reset(reset),.ntsc(1'b0),.reg_cs(cs),.reg_wr(wr),.reg_addr(addr),.reg_be(2'b11),.reg_wdata(wdata),.reg_rdata(rdata),.irq(irq),.dma_req(req),.dma_addr(dma_addr),.dma_ack(ack),.dma_data(data),.dma_error(1'b0),.sample_l(sl),.sample_r(sr));
// Ideal memory only, NOT the real chipdma_arb/SDRAM. One accepted beat per request.
always @(negedge clk) begin
 ack=0;
 if(!req)holdcount=0;
 else if(holdcount>=delay_cycles) begin ack=1;data=dma_addr[1] ? 16'hd000:16'h3000;end
 else holdcount=holdcount+1;
end
task write_reg(input integer byteaddr,input [15:0] value);
 begin
 @(negedge clk);cs=1;wr=1;addr=(byteaddr+32*selected)>>1;wdata=value;
 repeat(3) @(negedge clk);
 cs=0;wr=0;repeat(3) @(negedge clk);
 end
endtask
integer pos=0,neg=0,zero=0,lo=32767,hi=-32768;
integer selected=0,expected_bad=0,delay_cycles=0,holdcount=0;
integer i,beats=0,decodes=0,pcm_nonzero=0,out_nonzero=0,wrong_fifo=0;
initial begin
 if($value$plusargs("VOICE=%d",selected)) begin end
 if($value$plusargs("DELAY=%d",delay_cycles)) begin end
 // Explicit zero-power-up RAM model. RTL lacks resets on these RAM arrays.
 for(i=0;i<32;i=i+1) begin
 dut.cfg_ptr_hi[i]=0;dut.cfg_ptr_lo[i]=0;dut.cfg_len_hi[i]=0;dut.cfg_len_lo[i]=0;
 dut.ram_ptr[i]=0;dut.ram_len[i]=0;dut.ram_wrptr[i]=0;dut.ram_rdptr[i]=0;
 dut.ram_vol[i]=0;dut.ram_per[i]=1000;dut.ram_ctrl[i]=0;dut.ram_pred0[i]=0;
 dut.sdpb_pcm_idx[i]=0;dut.sdpb_timer_bc[i]=0;dut.sdpb_res[i]=0;dut.del_cnt[i]=0;
 end
 for(i=0;i<2048;i=i+1)dut.fifo_ram[i]=0;
 for(i=0;i<16;i=i+1) begin
 dut.biquad_inst0.y_held_l[i]=0;dut.biquad_inst0.y_held_r[i]=0;
 dut.biquad_inst1.y_held_l[i]=0;dut.biquad_inst1.y_held_r[i]=0;
 end
 repeat(10) @(negedge clk);reset=0;repeat(100) @(negedge clk);
 write_reg(0,0);write_reg(2,16'h1000);write_reg(4,0);write_reg(6,256);
 write_reg(8,16'h3030);write_reg(10,1000);write_reg(16,16'h4000);write_reg(18,0);write_reg(20,0);write_reg(22,0);write_reg(24,0);write_reg(12,16'h0181);write_reg(28,0);write_reg(26,1);
 repeat(200000) @(negedge clk);
 $display("RESULT beats=%0d decodes=%0d pcm_nonzero=%0d output_nonzero=%0d fifo_mismatch=%0d state=%0d expected_bad=%0d voice=%0d delay=%0d",beats,decodes,pcm_nonzero,out_nonzero,wrong_fifo,dut.voice_state[selected],expected_bad,selected,delay_cycles);
 $display("MIX pos=%0d neg=%0d zero=%0d min=%0d max=%0d",pos,neg,zero,lo,hi);
 if(expected_bad || wrong_fifo || lo!=-2304 || hi!=2304 || pos==0 || neg==0)$fatal(1,"integrated unity mismatch");
 if(dut.biquad_inst0.pending_overflow || dut.biquad_inst1.pending_overflow)$fatal(1,"filter queue overflow");
 $display("INTEGRATED_UNITY_PASS");$finish;
end
always @(posedge clk) if(!reset) begin
 if(req&&ack)beats=beats+1;
 if(dut.cur_voice==selected && dut.do_refill) begin
 if(dut.fifo_dout !== dut.fifo_ram[selected*64+dut.ram_rdptr[selected]])wrong_fifo=wrong_fifo+1;
 end
 if(dut.cur_voice==selected && dut.do_decode) begin
 if(decodes<8)$display("TRACE decode=%0d pcm=%04x res=%06x fifo=%04x",decodes,dut.new_pcm,dut.v_res,dut.fifo_dout);
 if(dut.new_pcm !== (decodes%2 ? 16'hd000:16'h3000))expected_bad=expected_bad+1;
 decodes=decodes+1;
 if(decodes<8)$display("TRACE decode=%0d pcm=%04x res=%06x fifo=%04x",decodes,dut.new_pcm,dut.v_res,dut.fifo_dout);
 if(dut.new_pcm !== 16'd0 && (^dut.new_pcm)!==1'bx)pcm_nonzero=pcm_nonzero+1;
 end
 if((^sl)!==1'bx && sl!=0)out_nonzero=out_nonzero+1;
 if((^sl)!==1'bx && dut.cur_voice==1 && decodes>8) begin
 if($signed(sl)>0)pos=pos+1;else if($signed(sl)<0)neg=neg+1;else zero=zero+1;
 if($signed(sl)<lo)lo=$signed(sl);if($signed(sl)>hi)hi=$signed(sl);
 end
end
endmodule
