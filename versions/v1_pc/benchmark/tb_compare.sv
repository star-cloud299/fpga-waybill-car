`timescale 1ns/1ps
module tb_compare;
 parameter K=15;
 reg clk=0;always #10 clk=~clk;
 reg rst=1,clear=0,sv=0,mr=0;
 reg [8:0] width=32;
 reg [7:0] data;
 wire r0,r1,v0,v1;wire [7:0] a0,b0,c0,a1,b1,c1;
 wire [8:0] x0,y0,x1,y1;
 integer cycle=0,n=0,seen=0,f=0,w=0,h=0,i=0,expected=0;
 window_stats #(.K(K),.MAX_WIDTH(192)) opt(clk,rst,clear,width,sv,r0,data,v0,mr,a0,b0,c0,x0,y0);
 window_stats_naive #(.K(K),.MAX_WIDTH(192)) naive(clk,rst,clear,width,sv,r1,data,v1,mr,a1,b1,c1,x1,y1);
 always @(posedge clk)begin
  cycle=cycle+1;
  if(!rst && !clear)begin
   if(r0!==r1 || v0!==v1)$fatal(1,"handshake differs");
   if(v0 && mr)begin
    if({a0,b0,c0,x0,y0}!=={a1,b1,c1,x1,y1})$fatal(1,"outputs differ");
    $display("PIX %0d %0d %0d %0d %0d %0d %0d",f,x0,y0,a0,b0,c0,cycle);
    seen=seen+1;
   end
  end
  if(cycle>2000000)$fatal(1,"timeout");
 end
 initial begin
  repeat(4)@(negedge clk);rst=0;
  for(f=0;f<3;f=f+1)begin
   w=(f==0)?K:((f==1)?17:32);h=(f==0)?K:((f==1)?19:24);
   @(negedge clk);sv=0;clear=1;width=w;
   @(negedge clk);clear=0;n=0;seen=0;
   expected=(w-K+1)*(h-K+1);
   while(n<w*h || seen<expected)begin
    @(negedge clk);mr=(cycle%7!=0 && cycle%11!=0);
    sv=(n<w*h && cycle%5!=0);
    data=(n*37+(n/w)*19+f*53)&255;
    @(posedge clk);if(sv && r0)n=n+1;
   end
   @(negedge clk);sv=0;mr=1;
   $display("FRAME %0d %0d %0d %0d",f,w,h,seen);
  end
  $display("COMPARE_PASS K=%0d",K);$finish;
 end
endmodule
