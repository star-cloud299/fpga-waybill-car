`timescale 1ns/1ps
// Continuous camera preview with a held last-good frame and startup color bars.
module camera_live_top(
    input wire clk,reset_n,
    inout wire cam_scl,cam_sda,
    inout wire cam_rst_n,
    input wire cam_pclk,cam_vsync,cam_href,
    input wire [7:0] cam_data,
    output wire tmds_clk_p,tmds_clk_n,
    output wire [2:0] tmds_data_p,tmds_data_n,
    output wire hdmi_out_en,uart_txd,
    output wire [3:0] led_n
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
        .pixel_clk(pixel_clk),.pixel_reset_n(pixel_reset_n),
        .active_video(active_video),.x(x),.y(y),.rgb(rgb),
        .tmds_clk_p(tmds_clk_p),.tmds_clk_n(tmds_clk_n),
        .tmds_data_p(tmds_data_p),.tmds_data_n(tmds_data_n),.hdmi_out_en(hdmi_out_en));

    wire [15:0] pixel565;
    wire frame_valid,frame_error;
    wire inside_view=active_video && x>=64 && x<576 && y>=48 && y<432;
    // Raster counters have synchronous reset. Do not gate RAM addresses with
    // active_video/pixel_reset_n, which contain an asynchronous reset signal.
    wire [7:0] read_x=(x-64)>>1;
    wire [7:0] read_y=(y-48)>>1;
    wire read_swap=(x==0 && y==480);
    // Isolated polarity trial based on measured line/frame geometry.
    wire capture_href=~cam_href;
    live_frame_buffer frame_unit(.cam_pclk(cam_pclk),.reset_n(rst_n),
        .cam_vsync(cam_vsync),.cam_href(capture_href),.cam_data(cam_data),
        .pixel_clk(pixel_clk),.read_x(read_x),.read_y(read_y),.read_swap(read_swap),
        .pixel_rgb565(pixel565),.frame_valid(frame_valid),.frame_error(frame_error));
    reg inside_d=0;
    reg [23:0] background_d=0;
    reg [23:0] color_bar;
    always @* begin
        if(x<80)color_bar=24'hffffff;
        else if(x<160)color_bar=24'hffff00;
        else if(x<240)color_bar=24'h00ffff;
        else if(x<320)color_bar=24'h00ff00;
        else if(x<400)color_bar=24'hff00ff;
        else if(x<480)color_bar=24'hff0000;
        else if(x<560)color_bar=24'h0000ff;
        else color_bar=24'h000000;
    end
    always @(posedge pixel_clk) begin
        if(!pixel_reset_n)begin inside_d<=0;background_d<=0;end
        else begin inside_d<=inside_view;background_d<=color_bar;end
    end
    wire [23:0] expanded565={pixel565[15:11],pixel565[15:13],
        pixel565[10:5],pixel565[10:9],pixel565[4:0],pixel565[4:2]};
    assign rgb=frame_valid ? (inside_d ? expanded565 : 24'h000000) : background_d;

    wire geo_valid;
    wire [31:0] geo_frame,geo_bytes,geo_overlap;
    wire [15:0] geo_lines,geo_min,geo_max;
    geometry_monitor geometry_unit(.cam_pclk(cam_pclk),.sys_clk(clk),.reset_n(rst_n),
        .cam_vsync(cam_vsync),.cam_href(capture_href),.valid(geo_valid),
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

