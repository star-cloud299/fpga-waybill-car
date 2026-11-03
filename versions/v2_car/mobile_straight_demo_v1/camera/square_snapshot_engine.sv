`timescale 1ns/1ps
// Frozen frame processing/read arbiter. All activity is in pixel_clk domain.
// Nine sequential reads per 3x3 output avoid additional line/frame memories.
module square_snapshot_engine #(
 parameter WIDTH=256,HEIGHT=192
)(
 input wire clk,reset_n,capture_level,frame_valid,frame_boundary,service_slot,
 input wire [15:0] frame_data,
 output reg frozen=0,output reg ready=0,
 output wire frame_override,output wire [7:0] frame_read_x,frame_read_y,
 input wire external_request,input wire external_plane,input wire [15:0] external_address,
 output reg external_response=0,output reg [15:0] external_data=0,
 input wire external_response_ready,
 input wire [12:0] display_binary_address,output wire [7:0] display_binary_data
);
 localparam IDLE=0,PREPARE=1,NEIGHBOR=2,NEIGHBOR_WAIT=3,WRITE_BIT=4,
            AVAILABLE=5,SERVICE=6,SERVICE_WAIT=7,RESPONSE=8;
 reg [3:0] state=IDLE;
 reg [7:0] px=0,py=0;
 reg [3:0] neighbor=0;
 reg [11:0] sum=0;
 reg [7:0] center_gray=0,pack=0;
 reg bit_value=1;
 reg ext_pending=0,ext_plane=0;
 reg [15:0] ext_address=0;
 wire [15:0] center_address=py*WIDTH+px;
 reg [15:0] neighbor_address;
 always @*begin
  case(neighbor)
   0:neighbor_address=center_address-WIDTH-1;
   1:neighbor_address=center_address-WIDTH;
   2:neighbor_address=center_address-WIDTH+1;
   3:neighbor_address=center_address-1;
   4:neighbor_address=center_address;
   5:neighbor_address=center_address+1;
   6:neighbor_address=center_address+WIDTH-1;
   7:neighbor_address=center_address+WIDTH;
   default:neighbor_address=center_address+WIDTH+1;
  endcase
 end
 wire process_read=(state==NEIGHBOR && service_slot);
 wire service_read=(state==SERVICE && service_slot);
 assign frame_override=process_read || (service_read && !ext_plane);
 wire [15:0] selected_address=process_read?neighbor_address:ext_address;
 assign frame_read_x=selected_address%WIDTH;
 assign frame_read_y=selected_address/WIDTH;
 wire binary_write=state==WRITE_BIT && px[2:0]==7;
 wire [12:0] binary_write_address=center_address>>3;
 wire [7:0] binary_write_data={pack[6:0],bit_value};
 wire [12:0] binary_read_address=(service_read && ext_plane)?ext_address[12:0]:display_binary_address;
 wire [7:0] binary_q;
 square_binary_frame #(.BYTES(WIDTH*HEIGHT/8)) binary_frame(
  .clk(clk),.write_enable(binary_write),.write_address(binary_write_address),
  .write_data(binary_write_data),.read_address(binary_read_address),.read_data(binary_q));
 assign display_binary_data=binary_q;
 function automatic [7:0] gray565(input [15:0] pixel);
  reg [7:0] r,g,b;
  reg [16:0] weighted;
  begin
   r={pixel[15:11],pixel[15:13]};g={pixel[10:5],pixel[10:9]};b={pixel[4:0],pixel[4:2]};
   weighted=77*r+150*g+29*b+128;gray565=weighted>>8;
  end
 endfunction
 wire [7:0] fetched_gray=gray565(frame_data);
 wire [11:0] sum_with_last=sum+fetched_gray;
 wire [11:0] threshold_times9=({4'b0,center_gray}+12'd13)*9;
 always @(posedge clk or negedge reset_n)begin
  if(!reset_n)begin
   state<=IDLE;frozen<=0;ready<=0;px<=0;py<=0;neighbor<=0;sum<=0;
   center_gray<=0;pack<=0;bit_value<=1;ext_pending<=0;ext_plane<=0;ext_address<=0;
   external_response<=0;external_data<=0;
  end else begin
   external_response<=0;
   if(external_request && !ext_pending)begin
    ext_pending<=1;ext_plane<=external_plane;ext_address<=external_address;
   end
   if(frozen && !capture_level && frame_boundary)begin
    state<=IDLE;frozen<=0;ready<=0;ext_pending<=0;
   end else case(state)
    IDLE:if(capture_level && frame_boundary && frame_valid)begin
     frozen<=1;ready<=0;px<=0;py<=0;pack<=0;state<=PREPARE;
    end
    PREPARE:begin
     if(px==0 || py==0 || px==WIDTH-1 || py==HEIGHT-1)begin bit_value<=1;state<=WRITE_BIT;end
     else begin sum<=0;neighbor<=0;center_gray<=0;state<=NEIGHBOR;end
    end
    NEIGHBOR:if(service_slot)state<=NEIGHBOR_WAIT;
    NEIGHBOR_WAIT:begin
     sum<=sum_with_last;
     if(neighbor==4)center_gray<=fetched_gray;
     if(neighbor==8)begin
      // T >= floor(S/9) iff S < 9*(T+1), exact integer equivalence.
      bit_value<=sum_with_last<threshold_times9;state<=WRITE_BIT;
     end else begin neighbor<=neighbor+1'b1;state<=NEIGHBOR;end
    end
    WRITE_BIT:begin
     pack<={pack[6:0],bit_value};
     if(px==WIDTH-1)begin
      px<=0;
      if(py==HEIGHT-1)begin ready<=1;state<=AVAILABLE;end
      else begin py<=py+1'b1;state<=PREPARE;end
     end else begin px<=px+1'b1;state<=PREPARE;end
    end
    AVAILABLE:if(ext_pending)state<=SERVICE;
    SERVICE:if(service_slot)state<=SERVICE_WAIT;
    SERVICE_WAIT:begin external_data<=ext_plane?{8'b0,binary_q}:frame_data;state<=RESPONSE;end
    RESPONSE:if(external_response_ready)begin
     external_response<=1;ext_pending<=0;state<=AVAILABLE;
    end
    default:begin state<=IDLE;frozen<=0;ready<=0;end
   endcase
  end
 end
endmodule
