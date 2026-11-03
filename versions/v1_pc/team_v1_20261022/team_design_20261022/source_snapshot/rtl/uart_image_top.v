`timescale 1ns/1ps
// Fixed compile-time dimensions. Stop-and-wait framed protocol; see stage 4 docs.
module uart_image_top #(
    parameter WIDTH=64, HEIGHT=64,
    parameter CLKS_PER_BIT=434,
    parameter RX_TIMEOUT_CLKS=50000000
)(
    input wire clk, input wire rst_n, input wire uart_rxd,
    output wire uart_txd,
    output wire busy,
    output reg packet_error
);
    localparam S0=0,S1=1,HDR=2,PAY=3,CRCLO=4,CRCHI=5,
               DRAIN=6,THDR=7,TDATA=8,TCRCLO=9,TCRCHI=10,FINISH=11;
    localparam N=WIDTH*HEIGHT, OW=WIDTH-2, OH=HEIGHT-2, ON=OW*OH;
    localparam AW=(ON<=1)?1:$clog2(ON);
    reg [3:0] state;
    assign busy=(state!=S0 && state!=S1);
    wire rx_valid,rx_error,tx_ready;
    wire [7:0] rx_data;
    reg tx_valid;
    reg [7:0] tx_data;
    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) rx_unit(
        .clk(clk),.rst_n(rst_n),.rx(uart_rxd),.valid(rx_valid),.data(rx_data),.frame_error(rx_error));
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) tx_unit(
        .clk(clk),.rst_n(rst_n),.valid(tx_valid),.data(tx_data),.ready(tx_ready),.tx(uart_txd));

    function [15:0] crc_byte;
        input [15:0] crc;
        input [7:0] value;
        reg [15:0] c;
        integer k;
        begin
            c=crc^{value,8'b0};
            for(k=0;k<8;k=k+1) c=c[15] ? (c<<1)^16'h1021 : c<<1;
            crc_byte=c;
        end
    endfunction

    reg [2:0] header_index;
    reg [15:0] request_width,request_height,rx_crc,received_crc,tx_crc;
    reg [7:0] bias,pixel_high;
    reg low_byte;
    reg [31:0] pixels_received,stored,timeout_count;
    reg [AW-1:0] send_index;
    reg [7:0] result_mem [0:ON-1];
    reg pixel_valid,pixel_sof;
    reg [15:0] pixel;
    wire result_valid;
    wire [7:0] result_binary;
    wire pipe_reset=rst_n && state!=S0 && state!=S1;
    rgb565_adaptive_pipeline #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) pipeline(
        .clk(clk),.rst_n(pipe_reset),.in_valid(pixel_valid),.in_sof(pixel_sof),
        .rgb565(pixel),.bias(bias),.out_valid(result_valid),
        .out_x(),.out_y(),.center_gray(),.local_mean(),.binary(result_binary),.window_sum());

    always @* begin
        tx_valid=0; tx_data=0;
        if(state==THDR) begin
            tx_valid=1;
            case(header_index)
                0:tx_data=8'h5a;
                1:tx_data=8'ha5;
                2:tx_data=OW%256;
                3:tx_data=OW/256;
                4:tx_data=OH%256;
                5:tx_data=OH/256;
                default:tx_data=0;
            endcase
        end else if(state==TDATA) begin tx_valid=1; tx_data=result_mem[send_index]; end
        else if(state==TCRCLO) begin tx_valid=1; tx_data=tx_crc[7:0]; end
        else if(state==TCRCHI) begin tx_valid=1; tx_data=tx_crc[15:8]; end
    end

    always @(posedge clk) begin
        if(!rst_n) begin
            state<=S0; packet_error<=0; header_index<=0;
            request_width<=0; request_height<=0; rx_crc<=16'hffff;
            received_crc<=0; tx_crc<=16'hffff; bias<=0;
            pixel_high<=0; low_byte<=0; pixels_received<=0;
            stored<=0; timeout_count<=0; send_index<=0;
            pixel_valid<=0; pixel_sof<=0; pixel<=0;
        end else begin
            packet_error<=0; pixel_valid<=0; pixel_sof<=0;
            if(result_valid && state>=HDR && state<=DRAIN && stored<ON) begin
                result_mem[stored[AW-1:0]]<=result_binary;
                stored<=stored+1;
            end
            if(state>=HDR && state<=CRCHI) begin
                if(rx_valid) timeout_count<=0;
                else timeout_count<=timeout_count+1;
            end else timeout_count<=0;

            if((state>=HDR && state<=CRCHI) &&
               (rx_error || (!rx_valid && timeout_count>=RX_TIMEOUT_CLKS-1))) begin
                state<=S0; packet_error<=1; pixel_valid<=0;
            end else case(state)
                S0: if(rx_valid && rx_data==8'ha5) state<=S1;
                S1: if(rx_valid) begin
                    if(rx_data==8'h5a) begin
                        state<=HDR; header_index<=0; rx_crc<=16'hffff;
                        pixels_received<=0; stored<=0; low_byte<=0;
                    end else if(rx_data!=8'ha5) state<=S0;
                end
                HDR: if(rx_valid) begin
                    rx_crc<=crc_byte(rx_crc,rx_data);
                    header_index<=header_index+1;
                    case(header_index)
                        0:request_width[7:0]<=rx_data;
                        1:request_width[15:8]<=rx_data;
                        2:request_height[7:0]<=rx_data;
                        3:request_height[15:8]<=rx_data;
                        4:begin
                            bias<=rx_data;
                            if(request_width==WIDTH && request_height==HEIGHT) state<=PAY;
                            else begin state<=S0; packet_error<=1; end
                        end
                    endcase
                end
                PAY: if(rx_valid) begin
                    rx_crc<=crc_byte(rx_crc,rx_data);
                    if(!low_byte) begin pixel_high<=rx_data; low_byte<=1; end
                    else begin
                        pixel<={pixel_high,rx_data}; pixel_valid<=1;
                        pixel_sof<=(pixels_received==0); low_byte<=0;
                        pixels_received<=pixels_received+1;
                        if(pixels_received==N-1) state<=CRCLO;
                    end
                end
                CRCLO: if(rx_valid) begin received_crc[7:0]<=rx_data; state<=CRCHI; end
                CRCHI: if(rx_valid) begin
                    if({rx_data,received_crc[7:0]}==rx_crc) state<=DRAIN;
                    else begin state<=S0; packet_error<=1; end
                end
                DRAIN: if(stored==ON) begin
                    state<=THDR; header_index<=0; tx_crc<=16'hffff;
                end
                THDR: if(tx_ready) begin
                    if(header_index>=2) tx_crc<=crc_byte(tx_crc,tx_data);
                    if(header_index==5) begin state<=TDATA; send_index<=0; end
                    else header_index<=header_index+1;
                end
                TDATA: if(tx_ready) begin
                    tx_crc<=crc_byte(tx_crc,tx_data);
                    if(send_index==ON-1) state<=TCRCLO;
                    else send_index<=send_index+1;
                end
                TCRCLO: if(tx_ready) state<=TCRCHI;
                TCRCHI: if(tx_ready) state<=FINISH;
                FINISH: if(tx_ready) state<=S0;
                default:state<=S0;
            endcase
        end
    end
endmodule
