`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg reset=1,cs=0,wr=0,req=0,el=1,er=1,st=1;
reg[1:0] be=3;reg[6:0] addr=0;reg[15:0] data=0;reg[3:0] voice=0;
reg signed[15:0] xl=0,xr=0;wire signed[15:0] yl,yr;wire[15:0]rd;
biquad_iir_ringbuffer dut(clk,reset,cs,wr,addr,be,data,rd,voice,el,er,st,req,xl,xr,yl,yr);
integer ch,k,round,errors=0,count=0;
task write_coeff(input[6:0] a,input[15:0] v,input[1:0] mask);begin
 @(negedge clk);addr=a;data=v;be=mask;cs=1;wr=1;
 @(negedge clk);cs=0;wr=0;be=3;
end endtask
initial begin
 repeat(4)@(negedge clk);reset=0;
 for(ch=0;ch<16;ch=ch+1) begin
 voice=ch;#1;if(yl!==0 || yr!==0)$fatal(1,"undefined initial output");
 for(k=0;k<5;k=k+1)write_coeff(ch*8+k,k==0?16'h4000:0,3);
 end
 // Preserve opposite byte under partial writes and verify CPU readback.
 write_coeff(0,16'h00aa,1);write_coeff(0,16'h4000,2);
 repeat(2)@(negedge clk);if(rd!==16'h40aa)$fatal(1,"byte enables/readback");
 write_coeff(0,0,1);
 for(round=0;round<8;round=round+1)begin
 st=round%2;
 for(ch=0;ch<16;ch=ch+1)begin
 @(negedge clk);voice=ch;xl=1000+31*ch+round;xr=-2000-17*ch-round;req=1;
 end
 @(negedge clk);req=0;
 repeat(600)@(negedge clk);
 for(ch=0;ch<16;ch=ch+1)begin
 voice=ch;#1;count=count+1;
 if(yl!==(1000+31*ch+round) || yr!==(st?(-2000-17*ch-round):(1000+31*ch+round)))begin
 errors=errors+1;$display("burst mismatch round=%0d ch=%0d got=%0d/%0d",round,ch,yl,yr);end
 end
 if(dut.pending_overflow)$fatal(1,"burst overflow");
 end
 @(negedge clk);reset=1;@(negedge clk);reset=0;
 for(ch=0;ch<16;ch=ch+1)begin voice=ch;#1;if(yl!==0 || yr!==0)$fatal(1,"warm reset output");end
 $display("BURST comparisons=%0d errors=%0d byte-enable/reset PASS",count,errors);
 if(errors)$fatal(1,"burst failed");$finish;
end
endmodule
