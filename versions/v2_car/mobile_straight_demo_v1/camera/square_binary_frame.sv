`timescale 1ns/1ps
// Two explicit 4096x8 tiles: at most two RAMB36, never a rounded 8192-word bank.
module square_binary_frame #(parameter BYTES=6144)(
 input wire clk,input wire write_enable,input wire [12:0] write_address,
 input wire [7:0] write_data,input wire [12:0] read_address,
 output wire [7:0] read_data
);
 localparam TILES=(BYTES+4095)/4096;
 wire [7:0] q[0:TILES-1];
 reg select_d=0,in_range_d=0;
 always @(posedge clk)begin select_d<=read_address[12];in_range_d<=read_address<BYTES;end
 genvar t;
 generate for(t=0;t<TILES;t=t+1)begin: tile
  (* ram_style="block" *) reg [7:0] ram[0:4095];
  reg [7:0] read_q;
  always @(posedge clk)begin
   if(write_enable && write_address<BYTES && write_address[12]==t)
    ram[write_address[11:0]]<=write_data;
   read_q<=ram[read_address[11:0]];
  end
  assign q[t]=read_q;
 end endgenerate
 generate if(TILES==1)begin: one
  assign read_data=in_range_d?q[0]:8'hff;
 end else begin: two
  assign read_data=in_range_d?q[select_d]:8'hff;
 end endgenerate
endmodule
