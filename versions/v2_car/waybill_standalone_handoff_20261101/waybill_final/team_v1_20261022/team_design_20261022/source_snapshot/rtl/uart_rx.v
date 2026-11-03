`timescale 1ns/1ps
// 8N1, two-flop asynchronous-input synchronizer, center-of-bit sampling.
module uart_rx #(parameter CLKS_PER_BIT=434)(
    input wire clk, input wire rst_n, input wire rx,
    output reg valid, output reg [7:0] data, output reg frame_error
);
    localparam CW=$clog2(CLKS_PER_BIT+1);
    reg meta,sync_rx;
    reg [CW-1:0] count;
    reg [1:0] state;
    reg [2:0] bit_index;
    reg [7:0] shift;
    always @(posedge clk) begin
        if(!rst_n) begin meta<=1; sync_rx<=1; end
        else begin meta<=rx; sync_rx<=meta; end
    end
    always @(posedge clk) begin
        if(!rst_n) begin
            state<=0; count<=0; bit_index<=0; shift<=0;
            valid<=0; data<=0; frame_error<=0;
        end else begin
            valid<=0; frame_error<=0;
            case(state)
                0: if(!sync_rx) begin state<=1; count<=(CLKS_PER_BIT-1)/2; end
                1: if(count!=0) count<=count-1;
                   else if(sync_rx) state<=0;
                   else begin state<=2; count<=CLKS_PER_BIT-1; bit_index<=0; end
                2: if(count!=0) count<=count-1;
                   else begin
                       shift[bit_index]<=sync_rx;
                       count<=CLKS_PER_BIT-1;
                       if(bit_index==7) state<=3;
                       else bit_index<=bit_index+1;
                   end
                3: if(count!=0) count<=count-1;
                   else begin
                       state<=0;
                       if(sync_rx) begin data<=shift; valid<=1; end
                       else frame_error<=1;
                   end
            endcase
        end
    end
endmodule
