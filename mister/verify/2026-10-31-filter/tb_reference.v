`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
reg reset=1,cs=0,wr=0,req=0,el=0,er=0,st=0;
reg [6:0] addr=0;reg [15:0] data=0;reg [3:0] voice=0;
reg signed[15:0] xl=0,xr=0;wire signed[15:0] yl,yr;wire[15:0] rd;
biquad_iir_ringbuffer dut(clk,reset,cs,wr,addr,2'b11,data,rd,voice,el,er,st,req,xl,xr,yl,yr);
integer f,n,op,a,b,c,d,e,g,h,i,count=0,errors=0;
initial begin
 f=$fopen("reference-vectors.txt","r");if(!f)$fatal(1,"vectors absent");
 while(!$feof(f)) begin
 n=$fscanf(f,"%d %d %d %d %d %d %d %d %d\n",op,a,b,c,d,e,g,h,i);
 if(n==9)begin
 if(op==0)begin
 @(negedge clk);reset=1;req=0;cs=0;wr=0;el=0;er=0;
 repeat(4)@(negedge clk);reset=0;
 end else if(op==1)begin
 @(negedge clk);addr=a;data=b;cs=1;wr=1;
 @(negedge clk);cs=0;wr=0;
 end else begin
 @(negedge clk);voice=a;xl=b;xr=c;el=d;er=e;st=g;req=1;
 @(negedge clk);req=0;voice=15-a;
 repeat(35)@(negedge clk);
 voice=a;#1;
 count=count+1;
 if(yl!==$signed(h[15:0]) || yr!==$signed(i[15:0]))begin
 errors=errors+1;if(errors<12)$display("FAIL n=%0d ch=%0d expected=%0d/%0d got=%0d/%0d",count,a,h,i,yl,yr);
 end
 if(dut.pending_overflow)$fatal(1,"unexpected queue overflow");
 end
 end
 end
 $display("REFERENCE pairs=%0d errors=%0d",count,errors);
 if(errors)$fatal(1,"reference mismatch");$finish;
end
endmodule
