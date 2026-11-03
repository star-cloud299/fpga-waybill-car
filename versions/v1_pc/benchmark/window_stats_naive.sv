`timescale 1ns/1ps
// Deliberately direct K*K reduction baseline, same IO/latency/rounding as window_stats.
// Benchmark only. Never included in the shipped board bitstream.
module window_stats_naive #(parameter integer K=15, MAX_WIDTH=256)(
 input wire clk,rst,clear,input wire [8:0] width,
 input wire s_valid,output wire s_ready,input wire [7:0] s_data,
 output reg m_valid,input wire m_ready,
 output reg [7:0] mean,center,range3,output reg [8:0] out_x,out_y
);
 localparam MID=K/2;
 (* ram_style="block" *) reg [(K-1)*8-1:0] rows[0:MAX_WIDTH-1];
 reg [(K-1)*8-1:0] rd;
 reg [7:0] pix;
 reg [8:0] x,y;
 reg work;
 reg [7:0] history[0:K-1][0:K-2];
 reg [7:0] col[0:K-1];
 reg [16:0] total;
 reg [7:0] lo,hi,value;
 integer i,j;
 assign s_ready=!work && (!m_valid || m_ready);
 always @* begin
  col[0]=pix;
  for(i=1;i<K;i=i+1)col[i]=(y>=i)?rd[(i-1)*8+:8]:0;
  total=0;
  for(i=0;i<K;i=i+1)begin
   total=total+col[i];
   for(j=0;j<K-1;j=j+1)total=total+history[i][j];
  end
  lo=255;hi=0;value=0;
  for(i=MID-1;i<=MID+1;i=i+1)begin
   for(j=MID-1;j<=MID+1;j=j+1)begin
    value=(j==0)?col[i]:history[i][j-1];
    if(value<lo)lo=value;
    if(value>hi)hi=value;
   end
  end
 end
 always @(posedge clk)begin
  if(rst || clear)begin
   x<=0;y<=0;work<=0;m_valid<=0;
   mean<=0;center<=0;range3<=0;out_x<=0;out_y<=0;
  end else begin
   if(m_valid && m_ready)m_valid<=0;
   if(s_valid && s_ready)begin rd<=rows[x];pix<=s_data;work<=1;end
   if(work)begin
    rows[x]<={rd[(K-2)*8-1:0],pix};
    for(integer a=0;a<K;a=a+1)begin
     for(integer b=K-2;b>0;b=b-1)history[a][b]<=history[a][b-1];
     history[a][0]<=col[a];
    end
    if(x>=K-1 && y>=K-1)begin
     m_valid<=1;mean<=total/(K*K);center<=history[MID][MID-1];range3<=hi-lo;
     out_x<=x-(K-1);out_y<=y-(K-1);
    end
    if(x==width-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;
    work<=0;
   end
  end
 end
endmodule
