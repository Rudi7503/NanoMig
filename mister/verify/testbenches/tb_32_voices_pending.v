`timescale 1ns/1ps
// 32 Stimmen gleichzeitig, alle mit Unity-Filter (b0=0x4000, Rest 0).
// Zweck: Auslastung der einen Filterbank pruefen. Der Vorgaengerstand hatte
// zwei Bänke fuer je 16 Stimmen; hier muss eine Bank 32 Stimmen bedienen.
module tb;
reg clk=0; always #5 clk=~clk;
reg reset=1,cs=0,wr=0;
reg [9:1] addr=0;
reg [15:0] wdata=0;
wire [15:0] rdata,sl,sr;
wire req,irq; wire [31:0] dma_addr;
reg ack=0; reg [15:0] data=0;
audio_ext dut(.clk(clk),.reset(reset),.ntsc(1'b0),.reg_cs(cs),.reg_wr(wr),.reg_addr(addr),
  .reg_be(2'b11),.reg_wdata(wdata),.reg_rdata(rdata),.irq(irq),.dma_req(req),.dma_addr(dma_addr),
  .dma_ack(ack),.dma_data(data),.dma_error(1'b0),.sample_l(sl),.sample_r(sr));

always @(negedge clk) begin
 ack=0;
 if(!req) holdcount=0;
 else if(holdcount>=delay_cycles) begin ack=1;data=dma_addr[1] ? 16'hd000:16'h3000;end
 else holdcount=holdcount+1;
end

task wreg(input integer voice, input integer byteaddr, input [15:0] value);
 begin
  @(negedge clk);cs=1;wr=1;addr=(byteaddr+32*voice)>>1;wdata=value;
  repeat(3) @(negedge clk);
  cs=0;wr=0;repeat(3) @(negedge clk);
 end
endtask

integer i,v,beats=0,decodes=0,out_nonzero=0,holdcount=0,delay_cycles=0,maxpos=0,maxneg=0,lr_diff=0,maxpend=0,pc=0,b=0;
initial begin
 if($value$plusargs("DELAY=%d",delay_cycles)) begin end
 for(i=0;i<32;i=i+1) begin
  dut.cfg_ptr_hi[i]=0;dut.cfg_ptr_lo[i]=0;dut.cfg_len_hi[i]=0;dut.cfg_len_lo[i]=0;
  dut.ram_ptr[i]=0;dut.ram_len[i]=0;dut.ram_wrptr[i]=0;dut.ram_rdptr[i]=0;
  dut.ram_vol[i]=0;dut.ram_per[i]=1000;dut.ram_ctrl[i]=0;dut.ram_pred0[i]=0;
  dut.sdpb_pcm_idx[i]=0;dut.sdpb_timer_bc[i]=0;dut.sdpb_res[i]=0;dut.del_cnt[i]=0;
  dut.biquad_inst0.y_held_l[i]=0;dut.biquad_inst0.y_held_r[i]=0;
 end
 for(i=0;i<2048;i=i+1)dut.fifo_ram[i]=0;
 repeat(10) @(negedge clk);reset=0;repeat(100) @(negedge clk);
 for(v=0;v<32;v=v+1) begin
  wreg(v,0,0);wreg(v,2,16'h1000);wreg(v,4,0);wreg(v,6,256);
  wreg(v,8,16'h3030);wreg(v,10,1000);
  wreg(v,16,16'h4000);wreg(v,18,0);wreg(v,20,0);wreg(v,22,0);wreg(v,24,0);
  wreg(v,12,16'h0185);
  wreg(v,28,0);wreg(v,26,1);
 end
 repeat(200000) @(negedge clk);
 $display("LRDIFF=%0d", lr_diff); $display("MAXPEND=%0d", maxpend); $display("RESULT32 beats=%0d decodes=%0d out_nonzero=%0d overflow=%0d pending_peaks=%0d",
   beats,decodes,out_nonzero,dut.biquad_inst0.pending_overflow,maxpos);
 if(dut.biquad_inst0.pending_overflow)$fatal(1,"filter queue overflow with 32 voices");
 if(out_nonzero==0)$fatal(1,"no output with 32 voices");
 $display("INTEGRATED32_PASS");$finish;
end

always @(posedge clk) if(!reset) begin
 if(req&&ack)beats=beats+1;
 if(dut.cur_voice==0 && dut.do_decode)decodes=decodes+1;
 if((^sl)!==1'bx && sl!=0)out_nonzero=out_nonzero+1; if(sl!==sr) lr_diff=lr_diff+1;
 pc=0; for(b=0;b<32;b=b+1) if(dut.biquad_inst0.pending[b]) pc=pc+1; if(pc>maxpend) maxpend=pc;
end
endmodule
