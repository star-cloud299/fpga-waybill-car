`timescale 1ns/1ps
module rgb565_adaptive_pipeline #(
    parameter WIDTH=64, parameter HEIGHT=64
)(
    input wire clk, input wire rst_n,
    input wire in_valid, input wire in_sof,
    input wire [15:0] rgb565,
    input wire [7:0] bias,
    output wire out_valid,
    output wire [15:0] out_x, out_y,
    output wire [7:0] center_gray, local_mean, binary,
    output wire [11:0] window_sum
);
    wire gray_valid;
    wire [7:0] gray;
    reg sof_d;
    reg [7:0] bias_d;
    // Metadata must advance through the same register stage as the pixel.
    always @(posedge clk) begin
        if (!rst_n) begin
            sof_d <= 0;
            bias_d <= 0;
        end else begin
            sof_d <= in_valid && in_sof;
            if (in_valid) bias_d <= bias;
        end
    end
    rgb565_gray_threshold gray_stage (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .rgb565(rgb565),
        .threshold(8'd128), .out_valid(gray_valid), .gray(gray), .binary()
    );
    adaptive_threshold_3x3 #(.WIDTH(WIDTH), .HEIGHT(HEIGHT)) adaptive_stage (
        .clk(clk), .rst_n(rst_n), .in_valid(gray_valid), .in_sof(sof_d),
        .in_gray(gray), .bias(bias_d), .out_valid(out_valid),
        .out_x(out_x), .out_y(out_y), .center_gray(center_gray),
        .local_mean(local_mean), .binary(binary), .window_sum(window_sum)
    );
endmodule
