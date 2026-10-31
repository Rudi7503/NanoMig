`timescale 1ns/1ps
module tb;
reg clk=0;
biquad_iir_ringbuffer dut(.clk(clk),.reset(1'b0));
integer mask,start,k,idx,expected,found;
initial begin
for(start=0;start<16;start=start+1)
for(mask=0;mask<65536;mask=mask+1) begin
 dut.pending=mask; dut.scan_start=start;
 expected=start;found=0;
 for(k=0;k<16;k=k+1) begin
  idx=(start+k)%16;
  if(!found && ((mask>>idx)&1))begin expected=idx;found=1;end
 end
 #1;
 if(dut.selected!==expected[3:0] || dut.have_pending!==found[0])
  $fatal(1,"scheduler mismatch mask=%h start=%d",mask,start);
end
$display("PASS 1048576 scheduler combinations");$finish;
end
endmodule
