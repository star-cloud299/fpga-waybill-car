`timescale 1ns/1ps
// Team baseline V2, five modes, RAW8 reply. The proven six-mode prototype
// remains untouched in integration_b_v1. This build is parameterized for
// different *maximum* frame sizes, with width/height selected per request.
module uart_official_v2_top #(
    parameter integer MAX_WIDTH=192,
    parameter integer MAX_HEIGHT=96,
    parameter integer CLKS_PER_BIT=434,
    parameter integer RX_TIMEOUT_CLKS=50000000,
    parameter integer SILENCE_CLKS=50000000
)(
    input wire clk, input wire rst_n, input wire uart_rxd,
    output wire uart_txd, output wire busy, output reg packet_error
);
    localparam integer MAX_N=MAX_WIDTH*MAX_HEIGHT;
    localparam integer AW=(MAX_N<=1)?1:$clog2(MAX_N);
    localparam [4:0] IDLE=0, MAGIC=1, HEADER=2, PIXELS=3,
        CRC_LOW=4, CRC_HIGH=5, DRAIN=6, QUIET=7, START=8,
        RUN=9, TX_HEADER=10, TX_FETCH=11, TX_VALUE=12,
        TX_CRC_LOW=13, TX_CRC_HIGH=14, TX_DONE=15;
    reg [4:0] state;
    assign busy=(state!=IDLE && state!=MAGIC);
    wire rx_valid,rx_error,tx_ready;
    wire [7:0] rx_data;
    reg tx_valid;
    reg [7:0] tx_data;
    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) rx_unit(
        .clk(clk),.rst_n(rst_n),.rx(uart_rxd),.valid(rx_valid),
        .data(rx_data),.frame_error(rx_error));
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) tx_unit(
        .clk(clk),.rst_n(rst_n),.valid(tx_valid),
        .data(tx_data),.ready(tx_ready),.tx(uart_txd));

    function automatic [15:0] crc_byte(input [15:0] crc,input [7:0] value);
        reg [15:0] c;
        integer bit_no;
        begin
            c=crc^{value,8'b0};
            for(bit_no=0;bit_no<8;bit_no=bit_no+1)
                c=c[15] ? (c<<1)^16'h1021 : c<<1;
            crc_byte=c;
        end
    endfunction

    reg [15:0] seq_id,req_width,req_height,req_crc,received_crc,tx_crc;
    reg [7:0] req_version,req_mode;
    reg [7:0] threshold,bias,t1,t2,cflat,cmid,cedge;
    reg [31:0] payload_length;
    reg [4:0] header_index,tx_header_index;
    reg [7:0] high_byte,send_value;
    reg low_byte,sequence_known;
    reg [15:0] rx_count,feed_index,out_count,send_index;
    reg [16:0] drain_remaining;
    reg [31:0] idle_clks,cycle_timer,reply_cycles;
    reg first_pixel_seen;
    reg [7:0] response_status;
    (* ram_style="block" *) reg [15:0] input_mem [0:MAX_N-1];
    (* ram_style="block" *) reg [7:0] output_mem [0:MAX_N-1];
    reg [15:0] feed_data;
    reg feed_valid;
    wire [15:0] input_pixels=req_width*req_height;
    wire [31:0] input_bytes={16'd0,input_pixels}<<1;
    wire dims_ok=(req_width>=3 && req_height>=3 &&
                  req_width<=MAX_WIDTH && req_height<=MAX_HEIGHT &&
                  (req_mode<=3 || (req_width>=15 && req_height>=15)));
    wire config_ok=(req_version==8'h02 && req_mode>=1 && req_mode<=5 &&
                    dims_ok && t1<t2);
    wire [7:0] offset=(req_mode<=2)?0:((req_mode==3)?1:7);
    wire [15:0] reply_width=(response_status==0)?req_width-({8'd0,offset}<<1):0;
    wire [15:0] reply_height=(response_status==0)?req_height-({8'd0,offset}<<1):0;
    wire [15:0] expected_outputs=reply_width*reply_height;
    wire [31:0] reply_length={16'd0,expected_outputs};

    wire frame_ready,cfg_error,core_busy,core_done;
    wire [8:0] out_width,out_height;
    wire s_ready,m_valid,m_uncertain,m_last;
    wire [7:0] m_data,m_margin,m_mean,m_range;
    wire [8:0] m_x,m_y;
    wire [31:0] uncertain_count,core_cycles;
    b_image_core #(.MAX_WIDTH(MAX_WIDTH)) core(
        .clk(clk),.rst(!rst_n),.frame_start(state==START),
        .frame_ready(frame_ready),.cfg_width(req_width[8:0]),
        .cfg_height(req_height[8:0]),.cfg_mode(req_mode[2:0]),
        .cfg_threshold(threshold),.cfg_bias(bias),.cfg_t1(t1),.cfg_t2(t2),
        .cfg_cflat(cflat),.cfg_cmid(cmid),.cfg_cedge(cedge),.cfg_delta(8'd0),
        .cfg_error(cfg_error),.busy(core_busy),.done(core_done),
        .out_width(out_width),.out_height(out_height),
        .s_valid(feed_valid),.s_ready(s_ready),.s_rgb565(feed_data),
        .m_valid(m_valid),.m_ready(state==RUN),.m_data(m_data),
        .m_uncertain(m_uncertain),.m_margin(m_margin),.m_mean(m_mean),
        .m_range(m_range),.m_x(m_x),.m_y(m_y),.m_last(m_last),
        .uncertain_count(uncertain_count),.process_cycles(core_cycles));

    always @* begin
        tx_valid=0;
        tx_data=0;
        case(state)
            TX_HEADER: begin
                tx_valid=1;
                case(tx_header_index)
                    0:tx_data=8'h6a;
                    1:tx_data=8'ha6;
                    2:tx_data=8'h02;
                    3:tx_data=seq_id[7:0];
                    4:tx_data=seq_id[15:8];
                    5:tx_data=response_status;
                    6:tx_data=req_mode;
                    7:tx_data=reply_width[7:0];
                    8:tx_data=reply_width[15:8];
                    9:tx_data=reply_height[7:0];
                    10:tx_data=reply_height[15:8];
                    11:tx_data=(response_status==0)?offset:0;
                    12:tx_data=(response_status==0)?offset:0;
                    13:tx_data=reply_length[7:0];
                    14:tx_data=reply_length[15:8];
                    15:tx_data=reply_length[23:16];
                    16:tx_data=reply_length[31:24];
                    17:tx_data=reply_cycles[7:0];
                    18:tx_data=reply_cycles[15:8];
                    19:tx_data=reply_cycles[23:16];
                    20:tx_data=reply_cycles[31:24];
                    default:tx_data=0;
                endcase
            end
            TX_VALUE: begin tx_valid=1;tx_data=send_value;end
            TX_CRC_LOW: begin tx_valid=1;tx_data=tx_crc[7:0];end
            TX_CRC_HIGH: begin tx_valid=1;tx_data=tx_crc[15:8];end
        endcase
    end

    always @(posedge clk) begin
        if(!rst_n) begin
            state<=IDLE;packet_error<=0;seq_id<=0;sequence_known<=0;
            req_version<=0;req_mode<=0;req_width<=0;req_height<=0;
            threshold<=128;bias<=12;t1<=24;t2<=80;
            cflat<=18;cmid<=12;cedge<=6;payload_length<=0;
            req_crc<=16'hffff;received_crc<=0;tx_crc<=16'hffff;
            header_index<=0;tx_header_index<=0;high_byte<=0;low_byte<=0;
            rx_count<=0;feed_index<=0;out_count<=0;send_index<=0;
            drain_remaining<=0;idle_clks<=0;cycle_timer<=0;
            reply_cycles<=0;first_pixel_seen<=0;response_status<=0;
            feed_data<=0;feed_valid<=0;send_value<=0;
        end else begin
            packet_error<=0;
            if(state==HEADER || state==PIXELS || state==CRC_LOW ||
               state==CRC_HIGH || state==DRAIN) begin
                if(rx_valid || rx_error) idle_clks<=0;
                else idle_clks<=idle_clks+1'b1;
            end else if(state==QUIET) begin
                if(rx_valid || rx_error) idle_clks<=0;
                else if(idle_clks<SILENCE_CLKS) idle_clks<=idle_clks+1'b1;
            end else idle_clks<=0;

            if(state==RUN) begin
                if(first_pixel_seen) cycle_timer<=cycle_timer+1'b1;
                if(feed_valid && s_ready) begin
                    feed_valid<=0;feed_index<=feed_index+1'b1;
                    if(!first_pixel_seen) begin
                        first_pixel_seen<=1;cycle_timer<=0;
                    end
                end else if(!feed_valid && feed_index<input_pixels) begin
                    feed_data<=input_mem[feed_index[AW-1:0]];
                    feed_valid<=1;
                end
                if(m_valid) begin
                    if(out_count<expected_outputs) begin
                        output_mem[out_count[AW-1:0]]<=m_data;
                        out_count<=out_count+1'b1;
                        if(m_last) reply_cycles<=cycle_timer;
                    end else begin
                        state<=QUIET;response_status<=1;packet_error<=1;
                    end
                end
            end

            if(state>=HEADER && state<=DRAIN &&
               (rx_error || (!rx_valid && idle_clks>=RX_TIMEOUT_CLKS-1))) begin
                state<=QUIET;response_status<=rx_error?8'd5:8'd4;
                packet_error<=1;idle_clks<=0;
            end else case(state)
                IDLE: if(rx_valid && rx_data==8'ha6) state<=MAGIC;
                MAGIC: if(rx_valid) begin
                    if(rx_data==8'h6a) begin
                        state<=HEADER;header_index<=0;req_crc<=16'hffff;
                        sequence_known<=0;rx_count<=0;low_byte<=0;
                        response_status<=0;reply_cycles<=0;
                    end else if(rx_data!=8'ha6) state<=IDLE;
                end
                HEADER: if(rx_valid) begin
                    req_crc<=crc_byte(req_crc,rx_data);
                    header_index<=header_index+1'b1;
                    case(header_index)
                        0:req_version<=rx_data;
                        1:seq_id[7:0]<=rx_data;
                        2:begin seq_id[15:8]<=rx_data;sequence_known<=1;end
                        3:req_mode<=rx_data;
                        4:req_width[7:0]<=rx_data;
                        5:req_width[15:8]<=rx_data;
                        6:req_height[7:0]<=rx_data;
                        7:req_height[15:8]<=rx_data;
                        8:threshold<=rx_data;
                        9:bias<=rx_data;
                        10:t1<=rx_data;
                        11:t2<=rx_data;
                        12:cflat<=rx_data;
                        13:cmid<=rx_data;
                        14:cedge<=rx_data;
                        15:payload_length[7:0]<=rx_data;
                        16:payload_length[15:8]<=rx_data;
                        17:payload_length[23:16]<=rx_data;
                        18:begin
                            payload_length[31:24]<=rx_data;
                            if({rx_data,payload_length[23:0]}>32'd65536) begin
                                response_status<=2;packet_error<=1;state<=QUIET;
                            end else if({rx_data,payload_length[23:0]}!=input_bytes) begin
                                response_status<=2;packet_error<=1;
                                drain_remaining<=payload_length[16:0]+17'd2;
                                state<=DRAIN;
                            end else if(!config_ok) begin
                                response_status<=1;packet_error<=1;
                                drain_remaining<=payload_length[16:0]+17'd2;
                                state<=DRAIN;
                            end else state<=PIXELS;
                        end
                    endcase
                end
                PIXELS: if(rx_valid) begin
                    req_crc<=crc_byte(req_crc,rx_data);
                    if(!low_byte) begin high_byte<=rx_data;low_byte<=1;end
                    else begin
                        input_mem[rx_count[AW-1:0]]<={high_byte,rx_data};
                        low_byte<=0;rx_count<=rx_count+1'b1;
                        if(rx_count==input_pixels-1) state<=CRC_LOW;
                    end
                end
                CRC_LOW: if(rx_valid) begin
                    received_crc[7:0]<=rx_data;state<=CRC_HIGH;
                end
                CRC_HIGH: if(rx_valid) begin
                    if({rx_data,received_crc[7:0]}==req_crc) begin
                        state<=START;feed_index<=0;out_count<=0;
                        feed_valid<=0;first_pixel_seen<=0;cycle_timer<=0;
                    end else begin
                        packet_error<=1;response_status<=3;
                        state<=TX_HEADER;tx_header_index<=0;tx_crc<=16'hffff;
                    end
                end
                DRAIN: if(rx_valid) begin
                    if(drain_remaining==1) begin
                        state<=TX_HEADER;tx_header_index<=0;tx_crc<=16'hffff;
                    end else drain_remaining<=drain_remaining-1'b1;
                end
                QUIET: if(idle_clks>=SILENCE_CLKS) begin
                    if(sequence_known) begin
                        state<=TX_HEADER;tx_header_index<=0;tx_crc<=16'hffff;
                    end else state<=IDLE;
                end
                START: if(frame_ready) state<=RUN;
                RUN: begin
                    if(cfg_error) begin
                        state<=QUIET;response_status<=1;packet_error<=1;
                    end else if(core_done) begin
                        if(out_count==expected_outputs) begin
                            state<=TX_HEADER;tx_header_index<=0;tx_crc<=16'hffff;
                        end else begin
                            state<=QUIET;response_status<=1;packet_error<=1;
                        end
                    end
                end
                TX_HEADER: if(tx_ready) begin
                    if(tx_header_index>=2) tx_crc<=crc_byte(tx_crc,tx_data);
                    if(tx_header_index==20) begin
                        if(response_status==0) begin
                            state<=TX_FETCH;send_index<=0;
                        end else state<=TX_CRC_LOW;
                    end else tx_header_index<=tx_header_index+1'b1;
                end
                TX_FETCH: begin
                    send_value<=output_mem[send_index[AW-1:0]];
                    state<=TX_VALUE;
                end
                TX_VALUE: if(tx_ready) begin
                    tx_crc<=crc_byte(tx_crc,tx_data);
                    if(send_index==expected_outputs-1) state<=TX_CRC_LOW;
                    else begin send_index<=send_index+1'b1;state<=TX_FETCH;end
                end
                TX_CRC_LOW: if(tx_ready) state<=TX_CRC_HIGH;
                TX_CRC_HIGH: if(tx_ready) state<=TX_DONE;
                TX_DONE: if(tx_ready) state<=IDLE;
                default:state<=IDLE;
            endcase
        end
    end
endmodule
