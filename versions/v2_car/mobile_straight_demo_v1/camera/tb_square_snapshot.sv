`timescale 1ns/1ps
module tb_square_snapshot #(parameter W=256,H=192);
 reg clk=0;always #5 clk=~clk;
 reg rst=0,level=0,frame_valid=0,boundary=0;
 reg [4:0] ticks=0;
 always @(posedge clk)ticks<=ticks+1'b1;
 wire slot=(ticks[2:0]>=3);
 wire frozen,ready,override_read;
 wire [7:0] rx,ry;
 reg [15:0] frame_q=0;
 reg [15:0] source[0:W*H-1];
 reg request=0,plane=0,response_ready=1;
 reg [15:0] address=0;
 wire response;
 wire [15:0] response_data;
 wire [7:0] display_byte;
 integer i,j,x,y,n,ss,rr,gg,bb,yy,expected,bit_index;
 reg [7:0] golden[0:W*H/8-1];
 always @(posedge clk)begin
  if(override_read)frame_q<=source[ry*W+rx];
  else frame_q<=16'h6bad;
  if(override_read && !slot)$fatal(1,"frame service collided with visible slot");
 end
 square_snapshot_engine #(.WIDTH(W),.HEIGHT(H)) dut(
  .clk(clk),.reset_n(rst),.capture_level(level),.frame_valid(frame_valid),.frame_boundary(boundary),
  .service_slot(slot),.frame_data(frame_q),.frozen(frozen),.ready(ready),
  .frame_override(override_read),.frame_read_x(rx),.frame_read_y(ry),
  .external_request(request),.external_plane(plane),.external_address(address),
  .external_response(response),.external_data(response_data),.external_response_ready(response_ready),
  .display_binary_address(13'd0),.display_binary_data(display_byte));
 function integer gray(input [15:0] p);
  integer r,g,b;
  begin r=((p>>11)&31)*8+((p>>13)&7);g=((p>>5)&63)*4+((p>>9)&3);b=(p&31)*8+((p>>2)&7);
   gray=(77*r+150*g+29*b+128)/256;
  end
 endfunction
 task pulse_boundary;
  begin @(negedge clk);boundary=1;@(negedge clk);boundary=0;end
 endtask
 task read_word(input reg p,input integer a,input integer value);
  begin
   @(negedge clk);plane=p;address=a;request=1;response_ready=0;
   @(negedge clk);request=0;
   repeat(12)@(negedge clk);
   if(response)$fatal(1,"response ignored ready/backpressure");
   response_ready=1;
   wait(response);#1;
   if(response_data!==value[15:0])$fatal(1,"read mismatch p=%0d addr=%0d got=%h want=%h",p,a,response_data,value);
   @(negedge clk);
  end
 endtask
 reg src_clk=0,dst_clk=0,mb_rst=0,send=0;
 always #7 src_clk=~src_clk;
 always #11 dst_clk=~dst_clk;
 reg [31:0] mb_data=0;
 wire mb_ready,mb_valid;wire [31:0] mb_received;
 square_cdc_mailbox #(.WIDTH(32)) mb(.src_clk(src_clk),.src_reset_n(mb_rst),.src_send(send),.src_data(mb_data),
  .src_ready(mb_ready),.dst_clk(dst_clk),.dst_reset_n(mb_rst),.dst_valid(mb_valid),.dst_data(mb_received));
 reg mailbox_done=0;
 initial begin
  #39;mb_rst=1;
  repeat(12)begin
   wait(mb_ready);@(negedge src_clk);mb_data=32'h51a123ef;send=1;
   @(negedge src_clk);send=0;mb_data=32'hdeadbeef;
   wait(mb_valid);#1;if(mb_received!==32'h51a123ef)$fatal(1,"mailbox data not coherent");
   @(negedge dst_clk);wait(mb_ready);
  end
  mailbox_done=1;
 end
 initial begin
  for(y=0;y<H;y=y+1)for(x=0;x<W;x=x+1)begin
   source[y*W+x]=(((x*11+y*3)%32)<<11)|(((x*9+y*13)%64)<<5)|((x*7+y*5)%32);
  end
  for(i=0;i<W*H/8;i=i+1)golden[i]=0;
  for(y=0;y<H;y=y+1)for(x=0;x<W;x=x+1)begin
   ss=0;
   if(x==0 || y==0 || x==W-1 || y==H-1)expected=1;
   else begin
    for(j=-1;j<=1;j=j+1)for(i=-1;i<=1;i=i+1)ss=ss+gray(source[(y+j)*W+x+i]);
    expected=gray(source[y*W+x])+12>=ss/9;
   end
   bit_index=y*W+x;
   if(expected)golden[bit_index/8]=golden[bit_index/8]|(1<<(7-bit_index%8));
  end
  #31;rst=1;level=1;
  pulse_boundary();repeat(5)@(negedge clk);
  if(frozen || ready)$fatal(1,"captured an invalid display frame");
  frame_valid=1;pulse_boundary();wait(ready);#1;
  if(!frozen)$fatal(1,"capture did not freeze");
  for(n=0;n<W*H;n=n+1)read_word(0,n,source[n]);
  for(n=0;n<W*H/8;n=n+1)read_word(1,n,golden[n]);
  // Readback must continue to address the held frame while capture remains high.
  pulse_boundary();repeat(5)@(negedge clk);
  if(!frozen || !ready)$fatal(1,"boundary released a held snapshot");
  level=0;repeat(10)@(negedge clk);
  if(!frozen)$fatal(1,"release changed display ownership mid-raster");
  pulse_boundary();#1;if(frozen || ready)$fatal(1,"release did not restore live view");
  wait(mailbox_done);
  $display("SQUARE_CAMERA_SNAPSHOT_SIM_PASS: original%0d pixels,binary%0d pixels,arbitration,freeze/release,mailbox12 transfers",W*H,W*H);
  $finish;
 end
 initial begin #2000000000;$fatal(1,"simulation timeout");end
endmodule
