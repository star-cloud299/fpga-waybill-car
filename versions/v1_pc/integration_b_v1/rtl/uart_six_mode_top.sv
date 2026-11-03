`timescale 1ns/1ps
// Separate V2 board top. Never accepts a V1 (A5 5A) request.
// Request: A5 5B, LE width/height, mode, threshold, bias, t1, t2,
//          cflat, cmid, cedge, delta, RGB565 big-endian pixels, CRC16 LE.
// Reply:   5B A5, LE output width/height, mode, (value, uncertain)*N,
//          CRC16 LE. CRC covers everything between magic and CRC.
module uart_six_mode_top #(
    parameter integer WIDTH=64,
    parameter integer HEIGHT=64,
    parameter integer CLKS_PER_BIT=434,
    parameter integer RX_TIMEOUT_CLKS=50000000
)(
    input wire clk, input wire rst_n, input wire uart_rxd,
    output wire uart_txd, output wire busy, output reg packet_error
);
    localparam integer N=WIDTH*HEIGHT;
    localparam integer AW=(N<=1)?1:$clog2(N);
    localparam [8:0] CORE_WIDTH=WIDTH, CORE_HEIGHT=HEIGHT;
    localparam [3:0] IDLE=0, MAGIC=1, HEADER=2, PIXELS=3,
                     CRC_LOW=4, CRC_HIGH=5, START=6, RUN=7,
                     TX_HEADER=8, TX_FETCH=9, TX_VALUE=10,
                     TX_FLAG=11, TX_CRC_LOW=12, TX_CRC_HIGH=13,
                     TX_DONE=14;
    reg [3:0] state;
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

    reg [15:0] req_width,req_height,rx_crc,received_crc,tx_crc;
    reg [7:0] req_mode;
    reg [7:0] threshold,bias,t1,t2,cflat,cmid,cedge,delta;
    reg [3:0] header_index;
    reg [7:0] high_byte;
    reg low_byte;
    reg [AW:0] rx_count,feed_index,out_count,send_index;
    reg [25:0] timeout_count;
    (* ram_style="block" *) reg [15:0] input_mem [0:N-1];
    (* ram_style="block" *) reg [8:0] output_mem [0:N-1];
    reg [15:0] feed_data;
    reg feed_valid;
    reg [8:0] send_word;
    reg [2:0] tx_header_index;
    wire frame_ready,cfg_error,core_busy,core_done;
    wire [8:0] out_width,out_height;
    wire s_ready,m_valid,m_uncertain,m_last;
    wire [7:0] m_data,m_margin,m_mean,m_range;
    wire [8:0] m_x,m_y;
    wire [31:0] uncertain_count,process_cycles;
    wire [AW:0] expected_outputs=out_width*out_height;
    wire [3:0] crop=(req_mode<=2)?0:((req_mode==3)?2:14);
    wire [15:0] reply_width=WIDTH-crop,reply_height=HEIGHT-crop;

    b_image_core #(.MAX_WIDTH(WIDTH)) core(
        .clk(clk),.rst(!rst_n),.frame_start(state==START),
        .frame_ready(frame_ready),
        .cfg_width(CORE_WIDTH),.cfg_height(CORE_HEIGHT),
        .cfg_mode(req_mode[2:0]),
        .cfg_threshold(threshold),.cfg_bias(bias),.cfg_t1(t1),.cfg_t2(t2),
        .cfg_cflat(cflat),.cfg_cmid(cmid),.cfg_cedge(cedge),.cfg_delta(delta),
        .cfg_error(cfg_error),.busy(core_busy),.done(core_done),
        .out_width(out_width),.out_height(out_height),
        .s_valid(feed_valid),.s_ready(s_ready),.s_rgb565(feed_data),
        .m_valid(m_valid),.m_ready(state==RUN),.m_data(m_data),
        .m_uncertain(m_uncertain),.m_margin(m_margin),.m_mean(m_mean),
        .m_range(m_range),.m_x(m_x),.m_y(m_y),.m_last(m_last),
        .uncertain_count(uncertain_count),.process_cycles(process_cycles));

    always @* begin
        tx_valid=0;
        tx_data=0;
        case(state)
            TX_HEADER: begin
                tx_valid=1;
                case(tx_header_index)
                    0:tx_data=8'h5b;
                    1:tx_data=8'ha5;
                    2:tx_data=reply_width[7:0];
                    3:tx_data=reply_width[15:8];
                    4:tx_data=reply_height[7:0];
                    5:tx_data=reply_height[15:8];
                    6:tx_data=req_mode;
                    default:tx_data=0;
                endcase
            end
            TX_VALUE: begin tx_valid=1;tx_data=send_word[7:0];end
            TX_FLAG: begin tx_valid=1;tx_data={7'd0,send_word[8]};end
            TX_CRC_LOW: begin tx_valid=1;tx_data=tx_crc[7:0];end
            TX_CRC_HIGH: begin tx_valid=1;tx_data=tx_crc[15:8];end
        endcase
    end

    always @(posedge clk) begin
        if(!rst_n) begin
            state<=IDLE;packet_error<=0;req_width<=0;req_height<=0;
            req_mode<=0;threshold<=128;bias<=12;t1<=24;t2<=80;
            cflat<=18;cmid<=12;cedge<=6;delta<=8;
            header_index<=0;high_byte<=0;low_byte<=0;
            rx_crc<=16'hffff;received_crc<=0;tx_crc<=16'hffff;
            rx_count<=0;feed_index<=0;out_count<=0;send_index<=0;
            timeout_count<=0;feed_data<=0;feed_valid<=0;
            send_word<=0;tx_header_index<=0;
        end else begin
            packet_error<=0;
            if(state>=HEADER && state<=CRC_HIGH) begin
                if(rx_valid) timeout_count<=0;
                else timeout_count<=timeout_count+1'b1;
            end else timeout_count<=0;

            if(state==RUN) begin
                if(feed_valid && s_ready) begin
                    feed_valid<=0;
                    feed_index<=feed_index+1'b1;
                end else if(!feed_valid && feed_index<N) begin
                    feed_data<=input_mem[feed_index[AW-1:0]];
                    feed_valid<=1;
                end
                if(m_valid) begin
                    if(out_count<N) begin
                        output_mem[out_count[AW-1:0]]<={m_uncertain,m_data};
                        out_count<=out_count+1'b1;
                    end else begin state<=IDLE;packet_error<=1;end
                end
            end

            if(state>=HEADER && state<=CRC_HIGH &&
               (rx_error || (!rx_valid && timeout_count>=RX_TIMEOUT_CLKS-1))) begin
                state<=IDLE;packet_error<=1;
            end else case(state)
                IDLE: if(rx_valid && rx_data==8'ha5) state<=MAGIC;
                MAGIC: if(rx_valid) begin
                    if(rx_data==8'h5b) begin
                        state<=HEADER;header_index<=0;rx_crc<=16'hffff;
                        rx_count<=0;low_byte<=0;
                    end else if(rx_data!=8'ha5) state<=IDLE;
                end
                HEADER: if(rx_valid) begin
                    rx_crc<=crc_byte(rx_crc,rx_data);
                    header_index<=header_index+1'b1;
                    case(header_index)
                        0:req_width[7:0]<=rx_data;
                        1:req_width[15:8]<=rx_data;
                        2:req_height[7:0]<=rx_data;
                        3:req_height[15:8]<=rx_data;
                        4:req_mode<=rx_data;
                        5:threshold<=rx_data;
                        6:bias<=rx_data;
                        7:t1<=rx_data;
                        8:t2<=rx_data;
                        9:cflat<=rx_data;
                        10:cmid<=rx_data;
                        11:cedge<=rx_data;
                        12:begin
                            delta<=rx_data;
                            if(req_width==WIDTH && req_height==HEIGHT &&
                               req_mode>=1 && req_mode<=6 &&
                               (req_mode<5 || t1<t2)) state<=PIXELS;
                            else begin state<=IDLE;packet_error<=1;end
                        end
                    endcase
                end
                PIXELS: if(rx_valid) begin
                    rx_crc<=crc_byte(rx_crc,rx_data);
                    if(!low_byte) begin high_byte<=rx_data;low_byte<=1;end
                    else begin
                        input_mem[rx_count[AW-1:0]]<={high_byte,rx_data};
                        low_byte<=0;rx_count<=rx_count+1'b1;
                        if(rx_count==N-1) state<=CRC_LOW;
                    end
                end
                CRC_LOW: if(rx_valid) begin
                    received_crc[7:0]<=rx_data;state<=CRC_HIGH;
                end
                CRC_HIGH: if(rx_valid) begin
                    if({rx_data,received_crc[7:0]}==rx_crc) begin
                        state<=START;feed_index<=0;out_count<=0;feed_valid<=0;
                    end else begin state<=IDLE;packet_error<=1;end
                end
                START: if(frame_ready) state<=RUN;
                RUN: begin
                    if(cfg_error) begin state<=IDLE;packet_error<=1;end
                    else if(core_done) begin
                        if(out_count==expected_outputs) begin
                            state<=TX_HEADER;tx_header_index<=0;tx_crc<=16'hffff;
                        end else begin state<=IDLE;packet_error<=1;end
                    end
                end
                TX_HEADER: if(tx_ready) begin
                    if(tx_header_index>=2) tx_crc<=crc_byte(tx_crc,tx_data);
                    if(tx_header_index==6) begin state<=TX_FETCH;send_index<=0;end
                    else tx_header_index<=tx_header_index+1'b1;
                end
                TX_FETCH: begin
                    send_word<=output_mem[send_index[AW-1:0]];
                    state<=TX_VALUE;
                end
                TX_VALUE: if(tx_ready) begin
                    tx_crc<=crc_byte(tx_crc,tx_data);state<=TX_FLAG;
                end
                TX_FLAG: if(tx_ready) begin
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
