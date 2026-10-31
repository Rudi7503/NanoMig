`timescale 1ns/1ps
module tb;
reg clk=0; always #5 clk=~clk;
reg reset=1,cs=0,wr=0,req=0;
reg [6:0] addr=0;reg [15:0] data=0;reg [3:0] voice=0;
reg signed [15:0] sample=0;
wire signed [15:0] l,r;wire [15:0] rd;
biquad_iir_ringbuffer dut(clk,reset,cs,wr,addr,2'b11,data,rd,voice,1'b1,1'b1,1'b0,req,sample,sample,l,r);
integer i,k,errors=0;reg signed [15:0] expected;
task coeff(input [6:0] a,input[15:0] v);begin
 @(negedge clk);addr=a;data=v;cs=1;wr=1;
 @(negedge clk);cs=0;wr=0;
end endtask
initial begin
 // Explicit known-zero memory model, not a proof of hardware startup state.
 for(i=0;i<128;i=i+1)begin dut.state_ram[i]=0;dut.coeff_ram[i]=0;end
 for(i=0;i<16;i=i+1)begin dut.y_held_l[i]=0;dut.y_held_r[i]=0;end
 repeat(4)@(negedge clk);reset=0;
 coeff(0,16'h4000);coeff(1,0);coeff(2,0);coeff(3,0);coeff(4,0);
 repeat(8)@(negedge clk);
 for(k=0;k<8;k=k+1)begin
  expected=(k%2)?-16'sd8192:16'sd4096;
  @(negedge clk);sample=expected;req=1;
  @(negedge clk);req=0;
  repeat(31)@(negedge clk);
  $display("unity n=%0d expected=%0d L=%0d R=%0d",k,expected,l,r);
  if(l!==expected || r!==expected)errors=errors+1;
 end
 $display("UNITY_ERRORS=%0d",errors);$finish;
end
initial begin #100000;$fatal(1,"timeout");end
endmodule
