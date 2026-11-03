`timescale 1ns/1ps
// Accepted OV5640/HDMI preview plus coherent snapshot, binary frame and UI.
// Sensor SCCB/PLL/register table and active-low physical HREF are unchanged.
module square_camera_core(
 input wire clk,reset_n,
 inout wire cam_scl,cam_sda,cam_rst_n,
 input wire cam_pclk,cam_vsync,cam_href,input wire [7:0] cam_data,
 output wire tmds_clk_p,tmds_clk_n,output wire [2:0] tmds_data_p,tmds_data_n,
 output wire hdmi_out_en,uart_txd,output wire [3:0] led_n,
 input wire capture_req,capture_release,read_req,read_plane,input wire [15:0] read_addr,
 output wire capture_busy,capture_ready,output reg capture_error=0,
 output wire read_ready,read_valid,output wire [15:0] read_data,
 input wire [2:0] ui_station,ui_verdict,ui_target,input wire [3:0] ui_phase,ui_completed,
 input wire [47:0] ui_text_bcd,input wire ui_text_valid,
 output wire video_config_ready,video_display_valid,video_frame_tick
);
    (* ASYNC_REG="TRUE" *) reg [2:0] reset_pipe=0;
    always @(posedge clk or negedge reset_n)
        if(!reset_n)reset_pipe<=0;
        else reset_pipe<={reset_pipe[1:0],1'b1};
    wire rst_n=reset_pipe[2];
    wire config_ready,config_error,id_ok;
    wire [79:0] diag_values;
    wire [9:0] diag_ack;
    wire diag_done;
    wire [3:0] debug_state,debug_bus_error;
    wire [15:0] debug_register,debug_id;
    ov5640_config #(.READBACK_ENABLE(1)) config_unit(.clk(clk),.reset_n(rst_n),
        .cam_scl(cam_scl),.cam_sda(cam_sda),.cam_rst_n(cam_rst_n),
        .ready(config_ready),.error(config_error),.id_ok(id_ok),
        .diag_values(diag_values),.diag_ack(diag_ack),.diag_done(diag_done),
        .debug_state(debug_state),.debug_bus_error(debug_bus_error),
        .debug_register(debug_register),.debug_id(debug_id));

 wire pixel_clk,pixel_reset_n,active_video;
 wire [9:0] x,y;
 wire [23:0] rgb;
 live_video_out video_unit(.clk50(clk),.reset_n(rst_n),
  .pixel_clk(pixel_clk),.pixel_reset_n(pixel_reset_n),.active_video(active_video),.x(x),.y(y),.rgb(rgb),
  .tmds_clk_p(tmds_clk_p),.tmds_clk_n(tmds_clk_n),.tmds_data_p(tmds_data_p),.tmds_data_n(tmds_data_n),.hdmi_out_en(hdmi_out_en));
 wire frame_valid,frame_error;
 (* ASYNC_REG="TRUE" *) reg [1:0] display_valid_sync=0,ready_sync=0,frozen_sync=0;
 reg capture_level=0;
 wire pixel_ready,pixel_frozen;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin capture_level<=0;capture_error<=0;display_valid_sync<=0;ready_sync<=0;frozen_sync<=0;end
  else begin
   display_valid_sync<={display_valid_sync[0],frame_valid};ready_sync<={ready_sync[0],pixel_ready};frozen_sync<={frozen_sync[0],pixel_frozen};
   if(capture_release)begin capture_level<=0;capture_error<=0;end
   else if(capture_req && !capture_level && !frozen_sync[1] && !ready_sync[1])begin
    if(video_config_ready && display_valid_sync[1])begin capture_level<=1;capture_error<=0;end
    else begin capture_error<=1;capture_level<=0;end
   end
  end
 end
 assign video_display_valid=display_valid_sync[1];
 assign capture_ready=capture_level && ready_sync[1] && !capture_error;
 assign capture_busy=(capture_level && !capture_ready) || (!capture_level && frozen_sync[1]);
 (* ASYNC_REG="TRUE" *) reg [1:0] capture_sync=0;
 always @(posedge pixel_clk or negedge pixel_reset_n)
  if(!pixel_reset_n)capture_sync<=0;
  else capture_sync<={capture_sync[0],capture_level};
 wire read_swap=(x==0 && y==480);
 wire raw_region=(pixel_frozen ?
       (x>=64 && x<320 && y>=144 && y<336):
       (x>=64 && x<576 && y>=48 && y<432));
 wire binary_region=pixel_frozen && x>=320 && x<576 && y>=144 && y<336;
 wire raw_view=active_video && raw_region;
 wire binary_view=active_video && binary_region;
 // Address arbitration depends on synchronous raster positions, never on
 // active_video's asynchronous reset qualifier (preserves BRAM read inference).
 wire service_slot=!(raw_region || binary_region);
 wire [7:0] preview_x=pixel_frozen?(x-64):((x-64)>>1);
 wire [7:0] preview_y=pixel_frozen?(y-144):((y-48)>>1);
 wire [7:0] service_x,service_y;
 wire frame_override;
 wire [7:0] frame_read_x=frame_override?service_x:preview_x;
 wire [7:0] frame_read_y=frame_override?service_y:preview_y;
 wire [15:0] pixel565;
 wire capture_href=~cam_href;
 live_frame_buffer frame_unit(.cam_pclk(cam_pclk),.reset_n(rst_n),
  .cam_vsync(cam_vsync),.cam_href(capture_href),.cam_data(cam_data),
  .pixel_clk(pixel_clk),.read_x(frame_read_x),.read_y(frame_read_y),
  .read_swap(read_swap && !capture_sync[1] && !pixel_frozen),
  .pixel_rgb565(pixel565),.frame_valid(frame_valid),.frame_error(frame_error));
 wire request_src_ready,request_event;
 wire [16:0] request_packet;
 reg read_outstanding=0;
 assign read_ready=capture_ready && !capture_release && !read_outstanding && request_src_ready;
 square_cdc_mailbox #(.WIDTH(17)) request_bridge(
  .src_clk(clk),.src_reset_n(rst_n),.src_send(read_req && read_ready),.src_data({read_plane,read_addr}),
  .src_ready(request_src_ready),.dst_clk(pixel_clk),.dst_reset_n(pixel_reset_n),
  .dst_valid(request_event),.dst_data(request_packet));
 wire response_send,response_src_ready,response_event;
 wire [15:0] response_packet;
 square_cdc_mailbox #(.WIDTH(16)) response_bridge(
  .src_clk(pixel_clk),.src_reset_n(pixel_reset_n),.src_send(response_send),.src_data(response_packet),
  .src_ready(response_src_ready),.dst_clk(clk),.dst_reset_n(rst_n),.dst_valid(response_event),.dst_data(read_data));
 assign read_valid=response_event && capture_ready;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)read_outstanding<=0;
  else if(capture_release)read_outstanding<=0;
  else begin
   if(read_req && read_ready)read_outstanding<=1;
   if(response_event)read_outstanding<=0;
  end
 end
 wire [7:0] binary_x=x-320;
 wire [7:0] binary_y=y-144;
 wire [15:0] binary_pixel_address={binary_y,binary_x};
 wire [7:0] binary_byte;
 square_snapshot_engine snapshot_unit(.clk(pixel_clk),.reset_n(pixel_reset_n),
  .capture_level(capture_sync[1]),.frame_valid(frame_valid),.frame_boundary(read_swap),.service_slot(service_slot),
  .frame_data(pixel565),.frozen(pixel_frozen),.ready(pixel_ready),.frame_override(frame_override),
  .frame_read_x(service_x),.frame_read_y(service_y),
  .external_request(request_event),.external_plane(request_packet[16]),.external_address(request_packet[15:0]),
  .external_response(response_send),.external_data(response_packet),.external_response_ready(response_src_ready),
  .display_binary_address(binary_pixel_address[15:3]),.display_binary_data(binary_byte));
 reg raw_view_d=0,binary_view_d=0;
 reg [2:0] binary_bit_d=0;
 reg [9:0] x_d=0,y_d=0;
 reg [23:0] background_d=0;
 reg [23:0] color_bar;
 always @*begin
  if(x<80)color_bar=24'hffffff;else if(x<160)color_bar=24'hffff00;
  else if(x<240)color_bar=24'h00ffff;else if(x<320)color_bar=24'h00ff00;
  else if(x<400)color_bar=24'hff00ff;else if(x<480)color_bar=24'hff0000;
  else if(x<560)color_bar=24'h0000ff;else color_bar=24'h000000;
 end
 always @(posedge pixel_clk)begin
  if(!pixel_reset_n)begin raw_view_d<=0;binary_view_d<=0;binary_bit_d<=0;x_d<=0;y_d<=0;background_d<=0;end
  else begin raw_view_d<=raw_view;binary_view_d<=binary_view;binary_bit_d<=binary_x[2:0];x_d<=x;y_d<=y;background_d<=color_bar;end
 end
 wire [23:0] expanded565={pixel565[15:11],pixel565[15:13],pixel565[10:5],pixel565[10:9],pixel565[4:0],pixel565[4:2]};
 wire binary_luma=binary_byte[7-binary_bit_d];
 wire [23:0] base_rgb=frame_valid?(raw_view_d?expanded565:
     ((binary_view_d && pixel_ready)?(binary_luma?24'hffffff:24'h000000):24'h000000)):background_d;
 wire [65:0] ui_packet_src={ui_station,ui_phase,ui_verdict,ui_completed,ui_text_bcd,ui_text_valid,ui_target};
 wire [65:0] ui_packet_pixel;
 wire ui_ready,ui_event;
 reg [15:0] ui_timer=0;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)ui_timer<=0;
  else ui_timer<=(ui_timer==49999)?0:ui_timer+1'b1;
 square_cdc_mailbox #(.WIDTH(66)) ui_bridge(
  .src_clk(clk),.src_reset_n(rst_n),.src_send(ui_timer==0 && ui_ready),.src_data(ui_packet_src),.src_ready(ui_ready),
  .dst_clk(pixel_clk),.dst_reset_n(pixel_reset_n),.dst_valid(ui_event),.dst_data(ui_packet_pixel));
 square_status_overlay overlay_unit(.x(x_d),.y(y_d),.base_rgb(base_rgb),
  .station(ui_packet_pixel[65:63]),.phase(ui_packet_pixel[62:59]),.verdict(ui_packet_pixel[58:56]),
  .completed(ui_packet_pixel[55:52]),.text_bcd(ui_packet_pixel[51:4]),.text_valid(ui_packet_pixel[3]),
  .target(ui_packet_pixel[2:0]),.frozen(pixel_frozen),.rgb(rgb));
    wire geo_valid,geo_update;
    wire [31:0] geo_frame,geo_bytes,geo_overlap;
    wire [15:0] geo_lines,geo_min,geo_max;
    assign video_config_ready=config_ready && !config_error;
    assign video_frame_tick=geo_update && geo_valid && geo_lines==240 &&
        geo_bytes==153600 && geo_min==640 && geo_max==640 && geo_overlap==0;
    geometry_monitor geometry_unit(.cam_pclk(cam_pclk),.sys_clk(clk),.reset_n(rst_n),
        .cam_vsync(cam_vsync),.cam_href(capture_href),.valid(geo_valid),.update(geo_update),
        .frame_number(geo_frame),.total_bytes(geo_bytes),.blank_href_samples(geo_overlap),
        .lines(geo_lines),.min_line_bytes(geo_min),.max_line_bytes(geo_max));

    camera_diagnostics diagnostics(
        .clk(clk),.reset_n(rst_n),.cam_pclk(cam_pclk),
        .cam_vsync(cam_vsync),.cam_href(cam_href),
        .config_ready(config_ready),.config_error(config_error),.id_ok(id_ok),
        .frame_valid(frame_valid),.frame_error(frame_error),
        .diag_values(diag_values),.diag_ack(diag_ack),.diag_done(diag_done),
        .cam_scl(cam_scl),.cam_sda(cam_sda),.cam_rst_n(cam_rst_n),
        .bus_error(debug_bus_error),.config_state(debug_state),
        .config_register(debug_register),.observed_id(debug_id),
        .geo_valid(geo_valid),.geo_frame(geo_frame),.geo_bytes(geo_bytes),
        .geo_overlap(geo_overlap),.geo_lines(geo_lines),.geo_min(geo_min),.geo_max(geo_max),
        .uart_txd(uart_txd),.led_n(led_n));

endmodule
