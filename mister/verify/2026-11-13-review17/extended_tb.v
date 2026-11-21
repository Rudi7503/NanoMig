`timescale 1ns/1ps
// Independent adversarial simulation; original RTL files remain unchanged.
module extended_tb;
reg clk=0; always #5 clk=~clk;
reg rst=0,cs=0,we=0,vb=0,sol=0,mv=0;
reg [3:0] ra=0; reg [15:0] wd=0; reg [63:0] md=0;
wire [15:0] rq; wire [31:0] ma; wire [3:0] bc;wire mr;wire [23:0] rgb;
sprite_engine dut(.clk_render(clk),.clk_sys(clk),.clk_vid(clk),.rst_n(rst),
 .reg_cs(cs),.reg_we(we),.reg_addr(ra),.reg_wdata(wd),.reg_rdata(rq),
 .vblank_pulse(vb),.line_swap_pulse(sol),.scanline_y(12'sd0),.vid_x(11'd0),.vid_read_en(1'b0),.clip_xmax(11'd2047),
 .amiga_rgb(24'h123456),.sprsel_aligned(1'b0),.pf_front_opaque(1'b0),.pf_any_opaque(1'b0),.blank_n(1'b1),
 .avm_address(ma),.avm_burstcount(bc),.avm_read(mr),.avm_waitrequest(1'b0),.avm_readdata(md),.avm_readdatavalid(mv),.out_rgb(rgb));
task tick;begin @(posedge clk);#1;end endtask
task wr;input[3:0] a;input[15:0] d;begin @(negedge clk);cs=1;we=1;ra=a;wd=d;tick;@(negedge clk);cs=0;we=0;end endtask
task send;input[63:0] b;begin @(negedge clk);md=b;mv=1;tick;end endtask
task stop;begin @(negedge clk);mv=0;end endtask
task boot;begin
 tick;@(negedge clk);rst=1;tick;wr(0,0);wr(1,16'h1000);wr(2,1);
 @(negedge clk);vb=1;tick;@(negedge clk);vb=0;sol=1;tick;@(negedge clk);sol=0;
 wait(dut.u_dma.state==2);
end endtask
integer tc=0,n=0,i;reg[31:0] codes[0:63];
always @(posedge clk) if(rst && dut.dec_in_valid)begin codes[n]=dut.dec_raw_code;n=n+1;end
initial begin
 if(!$value$plusargs("CASE=%d",tc))$fatal(1,"CASE missing");
 boot;
 if(tc==1) begin
  // Deliberately isolated descriptor fixture: only one response per descriptor.
  // Pixel burst itself is real four consecutive valid beats, with natural consumer stalls.
  send({12'd0,12'd0,8'd0,32'h2000});stop;
  wait(dut.u_dma.state==4);
  send({12'd1,12'd32,8'd7,8'hC0,8'hFF,8'd64,8'd64});stop;
  wait(dut.u_dma.state==7);
  send(64'h0102030405060708);send(64'h090a0b0c0d0e0f10);
  send(64'h1112131415161718);send(64'h191a1b1c1d1e1f20);stop;
  repeat(80)tick;
  $display("four consecutive CLUT8 beats: extracted=%0d expected=32",n);
  for(i=0;i<n;i=i+1)$display("code[%0d]=%h",i,codes[i]);
  if(n!=32)$fatal(1,"DMA ignores stream_ack; burst words lost before unpacker");
  for(i=0;i<32;i=i+1)if(codes[i]!==i+1)$fatal(1,"pixel ordering mismatch");
 end else if(tc==2)begin
  // Honor advertised BURSTCOUNT=4: two descriptors in one 32-byte return.
  send({12'd0,12'd0,8'd0,32'h2000});
  send({12'd1,12'd32,8'd7,8'hC0,8'hFF,8'd64,8'd64});
  send(64'd0);send(64'd0);stop;repeat(4)tick;
  $display("descriptor BL4: height=%0d width=%0d state=%0d (first descriptor expected height1,width32)",dut.u_dma.d_height,dut.u_dma.d_width_px,dut.u_dma.state);
  if(dut.u_dma.d_height!==12'd1 || dut.u_dma.d_width_px!==12'd32)$fatal(1,"descriptor burst tail misinterpreted/discarded");
 end else if(tc==4)begin
  // One BL4 descriptor command, but legal gaps before its two trailing beats.
  send({12'd0,12'd0,8'd0,32'h2000});
  send({12'd1,12'd32,8'd7,8'hC0,8'hFF,8'd64,8'd64});stop;
  repeat(8)tick;
  send(64'h9192939495969798);send(64'ha1a2a3a4a5a6a7a8);stop;
  repeat(30)tick;
  $display("delayed descriptor tail: pixel codes=%0d expected0 before any pixel response",n);
  if(n!=0)$fatal(1,"descriptor burst tail enters pixel stream");
 end else if(tc==3)begin
  // External register bus writes, checking actual RAM contents (not just increment).
  wr(3,16'd5);wr(4,16'h0011);wr(5,16'h2233);repeat(3)tick;
  $display("palette write slot5=%h slot6=%h expected slot5=112233",dut.u_palette.pal_ram[5],dut.u_palette.pal_ram[6]);
  if(dut.u_palette.pal_ram[5]!==24'h112233)$fatal(1,"palette commit uses incremented address");
 end
 $display("PASS extended %0d",tc);$finish;
end
initial begin #40000;$fatal(1,"timeout");end
endmodule

module palette_tb;
reg clk=0;always #5 clk=~clk;
reg rst=0,we=0,iv=0;reg[7:0] a=0;reg[23:0] d=0;reg[31:0] code=0;
wire[23:0] pa,pb;wire[7:0] address,r,g,b,alpha;wire ov,op;
sprite_engine_palette p(.clk_a(clk),.we_a(we),.addr_a(a),.data_a(d),.q_a(pa),.clk_b(clk),.addr_b(address),.q_b(pb));
sprite_engine_decoder dec(.clk(clk),.rst_n(rst),.in_valid(iv),.clr_acc(1'b0),.fmt(5'd7),.bw(6'd8),.raw_code(code),.pal_offset(8'd0),.desc_alpha(8'hFF),.pal_addr(address),.pal_data(pb),.out_valid(ov),.out_r(r),.out_g(g),.out_b(b),.out_alpha(alpha),.out_opaque(op));
task tick;begin @(posedge clk);#1;end endtask
initial begin
 tick;@(negedge clk);rst=1;we=1;a=0;d=24'h010203;tick;
 @(negedge clk);a=1;d=24'h112233;tick;
 @(negedge clk);a=2;d=24'h445566;tick;
 @(negedge clk);we=0;repeat(3)tick;
 @(negedge clk);iv=1;code=1;tick;
 $display("CLUT first pixel valid=%b rgb=%h expected112233",ov,{r,g,b});
 if(!ov || {r,g,b}!==24'h112233)$fatal(1,"palette RGB not aligned to current code/valid");
 $display("PASS palette");$finish;
end
endmodule

module capture_tb;
reg clk=0;always #5 clk=~clk;
reg rst=0,en=0,cs=0,we=0,ve=0;reg[10:0] x=0;reg signed[11:0] y=0;
reg[3:0] a=0;reg[15:0] data=0;wire[15:0] q;wire done;wire signed[11:0] target;
sprite_engine_capture c(.rst_n(rst),.clk_vid(clk),.capture_en(en),.cur_y(y),.cap_y(target),.vid_x(x),.vid_read_en(ve),.out_rgb(24'h123456),.cap_done(done),.clk_sys(clk),.reg_cs(cs),.reg_we(we),.reg_addr(a),.reg_wdata(data),.reg_rdata(q),.cap_target_line(target));
task tick;begin @(posedge clk);#1;end endtask
integer i,tc;reg[15:0] hi,lo;
initial begin
 if(!$value$plusargs("CASE=%d",tc))$fatal(1,"CASE missing");
 tick;@(negedge clk);rst=1;tick;
 if(tc==1)begin
  @(negedge clk);en=1;ve=1;
  for(i=0;i<1816;i=i+1)begin x=i;tick;@(negedge clk);end
  ve=0;y=1;tick;
  $display("capture after complete1816-dot line: done=%b",done);
  if(!done)$fatal(1,"capture completion requires nonexistent dot2047");
 end else if(tc==3)begin
  // Distinct RAM fixture pixels. No RTL change: initialize memory as input data.
  c.cap_mem[0]=24'h112233;c.cap_mem[1]=24'h445566;
  repeat(3)tick;
  @(negedge clk);a=11;cs=1;repeat(3)tick;hi=q;
  @(negedge clk);cs=0;tick;
  @(negedge clk);a=12;cs=1;repeat(4)tick;lo=q;
  $display("stable bus sample HI=%h LO=%h expected0011/2233",hi,lo);
  if(hi!==16'h0011 || lo!==16'h2233)$fatal(1,"capture HI/LO combines different pixels during one held read");
 end else begin
  @(negedge clk);a=12;cs=1;we=0;repeat(4)tick;
  @(negedge clk);cs=0;tick;
  $display("one low-word read held4cycles: read_addr=%0d expected1",c.read_addr);
  if(c.read_addr!==11'd1)$fatal(1,"capture address increments per clock instead of per bus read");
 end
 $display("PASS capture");$finish;
end
endmodule
