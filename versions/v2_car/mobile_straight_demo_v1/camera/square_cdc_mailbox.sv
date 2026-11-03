`timescale 1ns/1ps
// Bundled data is held from request until round-trip acknowledgement.
module square_cdc_mailbox #(parameter WIDTH=16)(
 input wire src_clk,src_reset_n,src_send,input wire [WIDTH-1:0] src_data,
 output wire src_ready,input wire dst_clk,dst_reset_n,
 output reg dst_valid=0,output reg [WIDTH-1:0] dst_data=0
);
 reg [WIDTH-1:0] held=0;
 reg request=0,ack=0;
 (* ASYNC_REG="TRUE" *) reg [1:0] ack_sync=0,req_sync=0;
 reg seen=0,copy_pending=0;
 assign src_ready=(request==ack_sync[1]);
 always @(posedge src_clk or negedge src_reset_n)begin
  if(!src_reset_n)begin held<=0;request<=0;ack_sync<=0;end
  else begin
   ack_sync<={ack_sync[0],ack};
   if(src_send && src_ready)begin held<=src_data;request<=~request;end
  end
 end
 always @(posedge dst_clk or negedge dst_reset_n)begin
  if(!dst_reset_n)begin req_sync<=0;seen<=0;copy_pending<=0;ack<=0;dst_valid<=0;dst_data<=0;end
  else begin
   req_sync<={req_sync[0],request};dst_valid<=0;
   if(copy_pending)begin dst_data<=held;dst_valid<=1;ack<=seen;copy_pending<=0;end
   else if(req_sync[1]!=seen)begin seen<=req_sync[1];copy_pending<=1;end
  end
 end
endmodule
