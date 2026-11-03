`timescale 1ns/1ps
// Input is accepted only when valid && ready; 8N1, LSB first.
module uart_tx #(parameter CLKS_PER_BIT=434)(
    input wire clk, input wire rst_n,
    input wire valid, input wire [7:0] data,
    output wire ready, output reg tx
);
    localparam CW=$clog2(CLKS_PER_BIT+1);
    reg busy;
    reg [CW-1:0] count;
    reg [3:0] bit_index;
    reg [9:0] shift;
    assign ready=!busy;
    always @(posedge clk) begin
        if(!rst_n) begin
            busy<=0; count<=0; bit_index<=0; shift<=10'h3ff; tx<=1;
        end else if(!busy) begin
            tx<=1;
            if(valid) begin
                shift<={1'b1,data,1'b0}; tx<=0;
                busy<=1; count<=CLKS_PER_BIT-1; bit_index<=0;
            end
        end else if(count!=0) count<=count-1;
        else if(bit_index==9) begin busy<=0; tx<=1; end
        else begin
            shift<={1'b1,shift[9:1]}; tx<=shift[1];
            bit_index<=bit_index+1; count<=CLKS_PER_BIT-1;
        end
    end
endmodule
