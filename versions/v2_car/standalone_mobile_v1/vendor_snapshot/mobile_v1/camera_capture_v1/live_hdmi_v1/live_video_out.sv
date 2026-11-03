`timescale 1ns/1ps
// 640x480p60 RGB video over HDMI1 using the locally supplied BSD-licensed
// Digilent rgb2dvi core. This wrapper is original project code.
module live_video_out #(
    parameter integer RGB_LATENCY=1
)(
    input  wire        clk50,
    input  wire        reset_n,
    output wire        pixel_clk,
    output wire        pixel_reset_n,
    output wire        active_video,
    output wire [9:0]  x,
    output wire [9:0]  y,
    input  wire [23:0] rgb,
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_data_p,
    output wire [2:0]  tmds_data_n,
    output wire        hdmi_out_en
);
    localparam integer H_ACTIVE=640, H_FRONT=16, H_SYNC=96, H_BACK=48;
    localparam integer V_ACTIVE=480, V_FRONT=10, V_SYNC=2, V_BACK=33;
    localparam integer H_TOTAL=H_ACTIVE+H_FRONT+H_SYNC+H_BACK;
    localparam integer V_TOTAL=V_ACTIVE+V_FRONT+V_SYNC+V_BACK;

    wire feedback_raw,feedback,serial_raw,pixel_raw,serial_clk,clock_locked;
    // 50 MHz / 5 * 63 = 630 MHz VCO; /25 = 25.2 MHz; /5 = 126 MHz.
    // 25.2 MHz / 800 / 525 = exactly 60 Hz.
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(20.0),
        .DIVCLK_DIVIDE(5),
        .CLKFBOUT_MULT_F(63.0),
        .CLKOUT0_DIVIDE_F(25.0),
        .CLKOUT1_DIVIDE(5),
        .STARTUP_WAIT("FALSE")
    ) video_clock_mmcm (
        .CLKIN1(clk50),.CLKFBIN(feedback),.CLKFBOUT(feedback_raw),
        .CLKOUT0(pixel_raw),.CLKOUT1(serial_raw),
        .LOCKED(clock_locked),.PWRDWN(1'b0),.RST(~reset_n)
    );
    BUFG feedback_buffer(.I(feedback_raw),.O(feedback));
    BUFG pixel_buffer(.I(pixel_raw),.O(pixel_clk));
    BUFG serial_buffer(.I(serial_raw),.O(serial_clk));

    wire pixel_async_reset=~reset_n || ~clock_locked;
    (* ASYNC_REG="TRUE" *) reg [2:0] reset_pipe=0;
    always @(posedge pixel_clk or posedge pixel_async_reset)
        if(pixel_async_reset) reset_pipe<=0;
        else reset_pipe<={reset_pipe[1:0],1'b1};
    assign pixel_reset_n=reset_pipe[2];

    reg [9:0] h_count=0,v_count=0;
    always @(posedge pixel_clk) begin
        if(!pixel_reset_n) begin h_count<=0;v_count<=0;end
        else if(h_count==H_TOTAL-1) begin
            h_count<=0;
            if(v_count==V_TOTAL-1) v_count<=0;
            else v_count<=v_count+1'b1;
        end else h_count<=h_count+1'b1;
    end
    assign x=h_count;
    assign y=v_count;
    assign active_video=pixel_reset_n && h_count<H_ACTIVE && v_count<V_ACTIVE;
    wire hsync_n=~(h_count>=H_ACTIVE+H_FRONT && h_count<H_ACTIVE+H_FRONT+H_SYNC);
    wire vsync_n=~(v_count>=V_ACTIVE+V_FRONT && v_count<V_ACTIVE+V_FRONT+V_SYNC);
    // Match the external synchronous frame-RAM read latency. Raw x/y/DE remain
    // available for addressing; the encoder receives controls aligned to rgb.
    wire encoded_de,encoded_hsync_n,encoded_vsync_n;
    generate if(RGB_LATENCY==0) begin: direct_controls
        assign encoded_de=active_video;
        assign encoded_hsync_n=hsync_n;
        assign encoded_vsync_n=vsync_n;
    end else begin: delayed_controls
        reg [RGB_LATENCY-1:0] de_pipe=0;
        reg [RGB_LATENCY-1:0] hs_pipe={RGB_LATENCY{1'b1}};
        reg [RGB_LATENCY-1:0] vs_pipe={RGB_LATENCY{1'b1}};
        integer stage;
        always @(posedge pixel_clk) begin
            if(!pixel_reset_n) begin
                de_pipe<=0;
                hs_pipe<={RGB_LATENCY{1'b1}};
                vs_pipe<={RGB_LATENCY{1'b1}};
            end else begin
                de_pipe[0]<=active_video;
                hs_pipe[0]<=hsync_n;
                vs_pipe[0]<=vsync_n;
                for(stage=1;stage<RGB_LATENCY;stage=stage+1) begin
                    de_pipe[stage]<=de_pipe[stage-1];
                    hs_pipe[stage]<=hs_pipe[stage-1];
                    vs_pipe[stage]<=vs_pipe[stage-1];
                end
            end
        end
        assign encoded_de=de_pipe[RGB_LATENCY-1];
        assign encoded_hsync_n=hs_pipe[RGB_LATENCY-1];
        assign encoded_vsync_n=vs_pipe[RGB_LATENCY-1];
    end endgenerate
    // The local Digilent v1.2 interface explicitly packs video as R,B,G.
    wire [23:0] digilent_rbg={rgb[23:16],rgb[7:0],rgb[15:8]};
    rgb2dvi #(.kGenerateSerialClk(1'b0),.kRstActiveHigh(1'b1)) dvi_output(
        .TMDS_Clk_p(tmds_clk_p),.TMDS_Clk_n(tmds_clk_n),
        .TMDS_Data_p(tmds_data_p),.TMDS_Data_n(tmds_data_n),
        .aRst(~pixel_reset_n),.aRst_n(pixel_reset_n),
        .vid_pData(digilent_rbg),.vid_pVDE(encoded_de),
        .vid_pHSync(encoded_hsync_n),.vid_pVSync(encoded_vsync_n),
        .PixelClk(pixel_clk),.SerialClk(serial_clk)
    );
    // HDMI1's on-board switch supplies the connector +5 V when this is high.
    // The monitor still uses its own rated external power supply.
    assign hdmi_out_en=1'b1;
endmodule
