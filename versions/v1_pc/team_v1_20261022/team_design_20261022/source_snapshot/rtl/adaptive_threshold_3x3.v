`timescale 1ns/1ps
// Grayscale raster input; outputs only centers with a complete 3x3 window.
// WIDTH, HEIGHT >= 3 and <= 65535. Memories intentionally have no reset.
module adaptive_threshold_3x3 #(
    parameter WIDTH=64, parameter HEIGHT=64
)(
    input wire clk, input wire rst_n,
    input wire in_valid, input wire in_sof,
    input wire [7:0] in_gray, input wire [7:0] bias,
    output reg out_valid,
    output reg [15:0] out_x, out_y,
    output reg [7:0] center_gray, local_mean, binary,
    output reg [11:0] window_sum
);
    reg [7:0] previous_row [0:WIDTH-1];
    reg [7:0] older_row [0:WIDTH-1];
    reg [15:0] x, y;
    wire [15:0] cx = in_sof ? 16'd0 : x;
    wire [15:0] cy = in_sof ? 16'd0 : y;
    wire [7:0] middle = previous_row[cx];
    wire [7:0] top = older_row[cx];
    reg [7:0] t2,t1,m2,m1,b2,b1;
    wire [11:0] sum9 = {4'b0,t2}+{4'b0,t1}+{4'b0,top}
                        +{4'b0,m2}+{4'b0,m1}+{4'b0,middle}
                        +{4'b0,b2}+{4'b0,b1}+{4'b0,in_gray};
    wire [7:0] mean9 = sum9 / 12'd9;
    // Equivalent to center >= mean - bias, without unsigned underflow.
    wire [8:0] adjusted = {1'b0,m1}+{1'b0,bias};
    always @(posedge clk) begin
        if (!rst_n) begin
            x<=0; y<=0; out_valid<=0;
            out_x<=0; out_y<=0; center_gray<=0;
            local_mean<=0; binary<=0; window_sum<=0;
            t2<=0; t1<=0; m2<=0; m1<=0; b2<=0; b1<=0;
        end else begin
            out_valid<=0;
            if (in_valid) begin
                older_row[cx]<=middle;
                previous_row[cx]<=in_gray;
                if (cx==0) begin
                    t2<=0; m2<=0; b2<=0;
                end else begin
                    t2<=t1; m2<=m1; b2<=b1;
                end
                t1<=top; m1<=middle; b1<=in_gray;
                if (cx>=2 && cy>=2) begin
                    out_valid<=1;
                    out_x<=cx-1; out_y<=cy-1;
                    center_gray<=m1; window_sum<=sum9;
                    local_mean<=mean9;
                    binary<=(adjusted >= {1'b0,mean9}) ? 8'hff : 8'h00;
                end
                if (cx==WIDTH-1) begin
                    x<=0;
                    y<=(cy==HEIGHT-1) ? 0 : cy+1;
                end else begin
                    x<=cx+1; y<=cy;
                end
            end
        end
    end
endmodule
