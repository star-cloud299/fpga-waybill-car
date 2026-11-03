`timescale 1ns/1ps
module straight_demo_top(
    input wire clk,reset_n,key1_n,key2_n,
    input wire enc1_a,enc1_b,enc2_a,enc2_b,
    output wire stby,ain1,ain2,pwma,bin1,bin2,pwmb,
    inout wire cam_scl,cam_sda,cam_rst_n,
    input wire cam_pclk,cam_vsync,cam_href,input wire [7:0] cam_data,
    output wire tmds_clk_p,tmds_clk_n,output wire [2:0] tmds_data_p,tmds_data_n,
    output wire hdmi_out_en,uart_txd,
    input wire esp_rxd,output wire esp_txd,
    output wire [3:0] led_n
);
    wire config_ready,display_valid,frame_tick;
    reg seen_frame=0;reg [25:0] frame_age=0;
    always @(posedge clk)begin
        if(!reset_n)begin seen_frame<=0;frame_age<=0;end
        else if(frame_tick)begin seen_frame<=1;frame_age<=0;end
        else if(frame_age<50000000)frame_age<=frame_age+1'b1;
    end
    wire video_ok=config_ready && display_valid && seen_frame && frame_age<50000000;
    wire link_ok,scan_request,scan_done;
    wire [2:0] scan_status,station_id,verdict,target_station;
    wire [3:0] phase,completed_mask;
    wire [47:0] text_bcd;wire text_valid;
    wire capture_req,capture_release,capture_busy,capture_ready,capture_error;
    wire read_req,read_plane,read_ready,read_valid;
    wire [15:0] read_addr,read_data;
    reg [3:0] previous_phase=0;
    always @(posedge clk)if(!reset_n)previous_phase<=0;else previous_phase<=phase;
    wire abort_scan=phase==7 && previous_phase!=7;
    straight_route_controller route_unit(
        .clk(clk),.reset_n(reset_n),.key1_n(key1_n),.key2_n(key2_n),
        .enc1_a(enc1_a),.enc1_b(enc1_b),.enc2_a(enc2_a),.enc2_b(enc2_b),
        .video_ok(video_ok),.link_ok(link_ok),.scan_done(scan_done),.scan_status(scan_status),
        .stby(stby),.ain1(ain1),.ain2(ain2),.pwma(pwma),.bin1(bin1),.bin2(bin2),.pwmb(pwmb),
        .scan_request(scan_request),.station_id(station_id),.phase(phase),.verdict(verdict),
        .completed_mask(completed_mask),.led_n(led_n));
    square_link link_unit(.clk(clk),.reset_n(reset_n),.rx(esp_rxd),.tx(esp_txd),.link_ok(link_ok),
        .scan_request(scan_request),.abort_scan(abort_scan),.station_id(station_id),
        .phase(phase),.completed_mask(completed_mask),.verdict(verdict),
        .scan_done(scan_done),.scan_status(scan_status),.text_bcd(text_bcd),.text_valid(text_valid),.target_station(target_station),
        .capture_req(capture_req),.capture_release(capture_release),.capture_busy(capture_busy),.capture_ready(capture_ready),.capture_error(capture_error),
        .read_req(read_req),.read_plane(read_plane),.read_addr(read_addr),.read_ready(read_ready),.read_valid(read_valid),.read_data(read_data));
    square_camera_core camera_unit(.clk(clk),.reset_n(reset_n),.cam_scl(cam_scl),.cam_sda(cam_sda),.cam_rst_n(cam_rst_n),
        .cam_pclk(cam_pclk),.cam_vsync(cam_vsync),.cam_href(cam_href),.cam_data(cam_data),
        .tmds_clk_p(tmds_clk_p),.tmds_clk_n(tmds_clk_n),.tmds_data_p(tmds_data_p),.tmds_data_n(tmds_data_n),
        .hdmi_out_en(hdmi_out_en),.uart_txd(uart_txd),
        .capture_req(capture_req),.capture_release(capture_release),.read_req(read_req),.read_plane(read_plane),.read_addr(read_addr),
        .ui_station(station_id),.ui_phase(phase),.ui_verdict(verdict),.ui_completed(completed_mask),
        .ui_text_bcd(text_bcd),.ui_text_valid(text_valid),.ui_target(target_station),
        .capture_busy(capture_busy),.capture_ready(capture_ready),.capture_error(capture_error),
        .read_ready(read_ready),.read_valid(read_valid),.read_data(read_data),
        .video_config_ready(config_ready),.video_display_valid(display_valid),.video_frame_tick(frame_tick));
endmodule
