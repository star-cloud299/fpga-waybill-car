`timescale 1ns/1ps
// New standalone B implementation. One input every >=2 clocks; valid/ready.
// No RAM reset: y masks stale rows, x masks stale horizontal history.
module window_stats #(parameter integer K=15, MAX_WIDTH=256)(
 input wire clk,rst,clear,
 input wire [8:0] width,
 input wire s_valid, output wire s_ready, input wire [7:0] s_data,
 output reg m_valid, input wire m_ready,
 output reg [7:0] mean,center,range3,
 output reg [8:0] out_x,out_y
);
 localparam integer MID=K/2;
 (* ram_style="block" *) reg [(K-1)*8-1:0] rows[0:MAX_WIDTH-1];
 reg [(K-1)*8-1:0] rd;
 reg [7:0] pix;
 reg [8:0] x,y;
 reg work;
 reg [11:0] col_hist[0:K-1];
 reg [7:0] tap_hist[0:2][0:K-2];
 reg [15:0] hsum;
 reg [7:0] col[0:K-1];
 reg [11:0] colsum;
 reg [16:0] total;
 reg [7:0] lo,hi,v;
 integer i,j,t,dx;
 assign s_ready = !work && (!m_valid || m_ready);
 always @* begin
  col[0]=pix;
  for(i=1;i<K;i=i+1) col[i]=(y>=i) ? rd[(i-1)*8+:8] : 8'd0;
  colsum=0;
  for(i=0;i<K;i=i+1) colsum=colsum+{4'd0,col[i]};
  total=((x==0)?17'd0:{1'b0,hsum})+{5'd0,colsum};
  if(x>=K) total=total-{5'd0,col_hist[K-1]};
  lo=255; hi=0; v=0;
  for(t=0;t<3;t=t+1) begin
   for(j=0;j<3;j=j+1) begin
    dx=MID-1+j;
    if(dx==0) v=col[MID-1+t];
    else v=tap_hist[t][dx-1];
    if(v<lo) lo=v;
    if(v>hi) hi=v;
   end
  end
 end
 always @(posedge clk) begin
  if(rst || clear) begin
   x<=0; y<=0; work<=0; m_valid<=0; hsum<=0;
   mean<=0; center<=0; range3<=0; out_x<=0; out_y<=0;
   // Histories and rows are intentionally not reset for RAM inference.
  end else begin
   if(m_valid && m_ready) m_valid<=0;
   if(s_valid && s_ready) begin
    rd<=rows[x]; pix<=s_data; work<=1;
   end
   if(work) begin
    rows[x]<={rd[(K-2)*8-1:0],pix};
    hsum<=total[15:0];
    for(integer a=K-1;a>0;a=a-1) col_hist[a]<=col_hist[a-1];
    col_hist[0]<=colsum;
    for(integer b=0;b<3;b=b+1) begin
     for(integer c=K-2;c>0;c=c-1) tap_hist[b][c]<=tap_hist[b][c-1];
     tap_hist[b][0]<=col[MID-1+b];
    end
    if(x>=K-1 && y>=K-1) begin
     m_valid<=1; mean<=total/(K*K);
     center<=tap_hist[1][MID-1]; range3<=hi-lo;
     out_x<=x-(K-1); out_y<=y-(K-1);
    end
    if(x==width-1) begin x<=0; y<=y+1'b1; end
    else x<=x+1'b1;
    work<=0;
   end
  end
 end
endmodule
