`timescale 1ns/1ps
// One registered stage. threshold is sampled with each valid pixel.
module rgb565_gray_threshold (
    input wire clk,
    input wire rst_n,
    input wire in_valid,
    input wire [15:0] rgb565,
    input wire [7:0] threshold,
    output reg out_valid,
    output reg [7:0] gray,
    output reg [7:0] binary
);
    wire [7:0] r = {rgb565[15:11], rgb565[15:13]};
    wire [7:0] g = {rgb565[10:5], rgb565[10:9]};
    wire [7:0] b = {rgb565[4:0], rgb565[4:2]};
    wire [17:0] weighted = ({10'b0,r} * 18'd77)
                         + ({10'b0,g} * 18'd150)
                         + ({10'b0,b} * 18'd29) + 18'd128;
    wire [7:0] next_gray = weighted[15:8];
    always @(posedge clk) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            gray <= 8'd0;
            binary <= 8'd0;
        end else begin
            out_valid <= in_valid;
            if (in_valid) begin
                gray <= next_gray;
                binary <= (next_gray >= threshold) ? 8'hff : 8'h00;
            end
        end
    end
endmodule
