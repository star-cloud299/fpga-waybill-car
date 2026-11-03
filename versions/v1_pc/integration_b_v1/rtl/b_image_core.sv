`timescale 1ns/1ps
// Proposal interface: freeze with A/C before replacing an existing pipeline.
// RGB565 bit replication; gray=(77R+150G+29B+128)>>8; black iff center+C<mean.
module b_image_core #(parameter integer MAX_WIDTH=256)(
 input wire clk,rst,
 input wire frame_start, output wire frame_ready,
 input wire [8:0] cfg_width,cfg_height,
 input wire [2:0] cfg_mode,
 input wire [7:0] cfg_threshold,cfg_bias,cfg_t1,cfg_t2,
 input wire [7:0] cfg_cflat,cfg_cmid,cfg_cedge,cfg_delta,
 output reg cfg_error,output reg busy,output reg done,
 output wire [8:0] out_width,out_height,
 input wire s_valid,output wire s_ready,input wire [15:0] s_rgb565,
 output reg m_valid,input wire m_ready,output reg [7:0] m_data,
 output reg m_uncertain,output reg [7:0] m_margin,m_mean,m_range,
 output reg [8:0] m_x,m_y,output reg m_last,
 output reg [31:0] uncertain_count,output reg [31:0] process_cycles
);
 reg [8:0] w,h,ix,iy;
 reg [2:0] mode;
 reg [7:0] threshold,bias,t1,t2,cf,cm,ce,delta;
 reg [31:0] n_in,n_out;
 wire accept_frame=frame_start && frame_ready;
 wire [8:0] requested_k=(cfg_mode<=2)?1:((cfg_mode==3)?3:15);
 wire config_ok=cfg_mode>=1 && cfg_mode<=6 && cfg_width>=requested_k &&
   cfg_height>=requested_k && cfg_width<=MAX_WIDTH && cfg_height<=128 &&
   (cfg_mode<5 || cfg_t1<cfg_t2);
 wire [8:0] k=(mode<=2)?1:((mode==3)?3:15);
 assign out_width=w-k+1'b1;
 assign out_height=h-k+1'b1;
 assign frame_ready=!busy;
 wire slot=!m_valid || m_ready;
 wire [7:0] red={s_rgb565[15:11],s_rgb565[15:13]};
 wire [7:0] green={s_rgb565[10:5],s_rgb565[10:9]};
 wire [7:0] blue={s_rgb565[4:0],s_rgb565[4:2]};
 wire [15:0] weighted=red*16'd77+green*16'd150+blue*16'd29+16'd128;
 wire [7:0] gray=weighted[15:8];
 wire r3,r15,v3,v15;
 wire [7:0] mean3,center3,range3,mean15,center15,range15;
 wire [8:0] x3,y3,x15,y15;
 wire inputs_left=n_in<({23'd0,w}*{23'd0,h});
 assign s_ready=busy && inputs_left && ((mode<=2)?slot:((mode==3)?r3:r15));
 wire input_fire=s_valid && s_ready;
 window_stats #(.K(3),.MAX_WIDTH(MAX_WIDTH)) win3(
  .clk(clk),.rst(rst),.clear(accept_frame),.width(w),
  .s_valid(input_fire && mode==3),.s_ready(r3),.s_data(gray),
  .m_valid(v3),.m_ready(slot && mode==3),.mean(mean3),.center(center3),
  .range3(range3),.out_x(x3),.out_y(y3));
 window_stats #(.K(15),.MAX_WIDTH(MAX_WIDTH)) win15(
  .clk(clk),.rst(rst),.clear(accept_frame),.width(w),
  .s_valid(input_fire && mode>=4),.s_ready(r15),.s_data(gray),
  .m_valid(v15),.m_ready(slot && mode>=4),.mean(mean15),.center(center15),
  .range3(range15),.out_x(x15),.out_y(y15));
 wire [7:0] local_mean=(mode==3)?mean3:mean15;
 wire [7:0] local_center=(mode==3)?center3:center15;
 wire [7:0] local_range=(mode==3)?range3:range15;
 wire [7:0] chosen_bias=(mode<5)?bias:((local_range<t1)?cf:((local_range<t2)?cm:ce));
 wire [8:0] decision={1'b0,local_center}+{1'b0,chosen_bias};
 wire [8:0] margin9=(decision>={1'b0,local_mean})?
   decision-{1'b0,local_mean}:{1'b0,local_mean}-decision;
 wire window_fire=slot && busy && ((mode==3 && v3)||(mode>=4 && v15));
 wire uncertain=(mode==6 && margin9<{1'b0,delta});
 always @(posedge clk) begin
  if(rst) begin
   busy<=0; done<=0; cfg_error<=0; m_valid<=0; m_last<=0;
   w<=1;h<=1;mode<=1;ix<=0;iy<=0;n_in<=0;n_out<=0;
   threshold<=128;bias<=12;t1<=24;t2<=80;cf<=18;cm<=12;ce<=6;delta<=8;
   m_data<=0;m_uncertain<=0;m_margin<=0;m_mean<=0;m_range<=0;m_x<=0;m_y<=0;
   uncertain_count<=0;process_cycles<=0;
  end else begin
   done<=0;cfg_error<=0;
   if(busy) process_cycles<=process_cycles+1'b1;
   if(m_valid && m_ready) begin
    m_valid<=0; n_out<=n_out+1'b1;
    if(m_last) begin busy<=0;done<=1;end
   end
   if(accept_frame) begin
    if(!config_ok) cfg_error<=1;
    else begin
     w<=cfg_width;h<=cfg_height;mode<=cfg_mode;
     threshold<=cfg_threshold;bias<=cfg_bias;t1<=cfg_t1;t2<=cfg_t2;
     cf<=cfg_cflat;cm<=cfg_cmid;ce<=cfg_cedge;delta<=cfg_delta;
     ix<=0;iy<=0;n_in<=0;n_out<=0;m_valid<=0;m_last<=0;
     uncertain_count<=0;process_cycles<=0;busy<=1;
    end
   end
   if(input_fire) begin
    n_in<=n_in+1'b1;
    if(ix==w-1) begin ix<=0;iy<=iy+1'b1;end else ix<=ix+1'b1;
    if(mode<=2) begin
     m_valid<=1;m_data<=(mode==1)?gray:((gray<threshold)?0:255);
     m_uncertain<=0;m_margin<=0;m_mean<=0;m_range<=0;m_x<=ix;m_y<=iy;
     m_last<=(ix==w-1 && iy==h-1);
    end
   end
   if(window_fire) begin
    m_valid<=1;m_data<=(decision<{1'b0,local_mean})?0:255;
    m_uncertain<=uncertain;m_margin<=(margin9>255)?255:margin9[7:0];
    m_mean<=local_mean;m_range<=local_range;
    m_x<=(mode==3)?x3:x15;m_y<=(mode==3)?y3:y15;
    m_last<=((mode==3)?(x3==out_width-1 && y3==out_height-1):
                             (x15==out_width-1 && y15==out_height-1));
    if(uncertain) uncertain_count<=uncertain_count+1'b1;
   end
  end
 end
endmodule
