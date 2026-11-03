`timescale 1ns/1ps
// One OV5640 16-bit-register SCCB transaction. Only 0/Z on both pins.
module sccb_master #(
    parameter integer PHASE_CYCLES = 500
)(
    input wire clk, input wire reset_n,
    input wire start, input wire read_not_write,
    input wire [15:0] reg_addr, input wire [7:0] write_data,
    inout wire scl, inout wire sda,
    output reg busy = 0, output reg done = 0, output reg error = 0,
    output reg [7:0] read_data = 0,
    output reg [3:0] error_detail = 0
);
    localparam IDLE=0, START0=1, START1=2, START2=3,
        TX0=4,TX1=5,TX2=6,TX3=7, ACK0=8,ACK1=9,ACK2=10,ACK3=11,
        RX0=12,RX1=13,RX2=14,RX3=15, NACK0=16,NACK1=17,NACK2=18,NACK3=19,
        STOP0=20,STOP1=21,STOP2=22,STOP3=23;
    reg [4:0] state=IDLE;
    reg [31:0] phase_count=0;
    wire tick=(phase_count==PHASE_CYCLES-1);
    reg scl_release=1, sda_release=1;
    reg reading=0;
    reg [15:0] address=0;
    reg [7:0] data_out=0,tx_byte=0;
    reg [2:0] bit_index=0,seq=0;
    reg ack_bad=0;
    assign scl=scl_release ? 1'bz : 1'b0;
    assign sda=sda_release ? 1'bz : 1'b0;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state<=IDLE; phase_count<=0; busy<=0; done<=0; error<=0;
            read_data<=0; error_detail<=0; scl_release<=1; sda_release<=1; reading<=0;
            address<=0; data_out<=0; tx_byte<=0; bit_index<=0; seq<=0; ack_bad<=0;
        end else begin
            done<=0;
            phase_count<=tick ? 0 : phase_count+1'b1;
            if (state==IDLE) begin
                phase_count<=0;
                if(start) begin
                    reading<=read_not_write; address<=reg_addr; data_out<=write_data;
                    seq<=0; busy<=1; error<=0; error_detail<=0; read_data<=0;
                    scl_release<=1; sda_release<=1; state<=START0;
                end
            end else if(tick) case(state)
                START0: begin scl_release<=1; sda_release<=1; state<=START1; end
                START1: if(!scl || !sda) begin
                    error<=1; error_detail<=!scl ? 4'h1 : 4'h2; state<=STOP0;
                end else begin sda_release<=0; state<=START2; end
                START2: begin
                    scl_release<=0; tx_byte<=(seq==3) ? 8'h79 : 8'h78;
                    bit_index<=7; state<=TX0;
                end
                TX0: begin sda_release<=tx_byte[bit_index]; state<=TX1; end
                TX1: begin scl_release<=1; state<=TX2; end
                TX2: state<=TX3;
                TX3: begin
                    scl_release<=0;
                    if(bit_index==0) state<=ACK0;
                    else begin bit_index<=bit_index-1'b1; state<=TX0; end
                end
                ACK0: begin sda_release<=1; state<=ACK1; end
                ACK1: begin scl_release<=1; state<=ACK2; end
                ACK2: begin ack_bad<=sda; state<=ACK3; end
                ACK3: begin
                    scl_release<=0;
                    if(ack_bad) begin
                        error<=1; state<=STOP0;
                        case(seq)
                            0:error_detail<=4'h3; // slave write address NACK
                            1:error_detail<=4'h4; // register high byte NACK
                            2:error_detail<=4'h5; // register low byte NACK
                            3:error_detail<=4'h6; // slave read address NACK
                            default:error_detail<=4'h7; // write data NACK
                        endcase
                    end
                    else case(seq)
                        0: begin tx_byte<=address[15:8]; bit_index<=7; seq<=1; state<=TX0; end
                        1: begin tx_byte<=address[7:0]; bit_index<=7; seq<=2; state<=TX0; end
                        2: if(reading) begin seq<=3; state<=START0; end
                           else begin tx_byte<=data_out; bit_index<=7; seq<=4; state<=TX0; end
                        3: begin bit_index<=7; state<=RX0; end
                        default: state<=STOP0;
                    endcase
                end
                RX0: begin sda_release<=1; state<=RX1; end
                RX1: begin scl_release<=1; state<=RX2; end
                RX2: begin read_data[bit_index]<=sda; state<=RX3; end
                RX3: begin
                    scl_release<=0;
                    if(bit_index==0) state<=NACK0;
                    else begin bit_index<=bit_index-1'b1; state<=RX0; end
                end
                NACK0: begin sda_release<=1; state<=NACK1; end
                NACK1: begin scl_release<=1; state<=NACK2; end
                NACK2: state<=NACK3;
                NACK3: begin scl_release<=0; state<=STOP0; end
                STOP0: begin scl_release<=0; sda_release<=0; state<=STOP1; end
                STOP1: begin scl_release<=1; state<=STOP2; end
                STOP2: begin sda_release<=1; state<=STOP3; end
                STOP3: begin busy<=0; done<=1; state<=IDLE; end
                default: begin error<=1; error_detail<=4'hf; state<=STOP0; end
            endcase
        end
    end
endmodule
