`timescale 1ns/1ps
// WBQ1 transport. Images and decisions are bound to station + scan_sequence.
module square_link #(
    parameter integer CLKS_PER_BIT=434,
    parameter integer LINK_TIMEOUT=100000000,
    parameter integer ACK_TIMEOUT=100000000,
    parameter integer SCAN_TIMEOUT=2000000000
)(
    input wire clk,reset_n,rx,
    output wire tx,link_ok,
    input wire scan_request,abort_scan,
    input wire [2:0] station_id,
    input wire [3:0] phase,completed_mask,
    input wire [2:0] verdict,
    output reg scan_done,output reg [2:0] scan_status,
    output reg [47:0] text_bcd,output reg text_valid,
    output reg [2:0] target_station,
    output reg capture_req,capture_release,
    input wire capture_busy,capture_ready,capture_error,
    output reg read_req,output reg read_plane,
    output reg [15:0] read_addr,
    input wire read_ready,read_valid,input wire [15:0] read_data
);
    wire rx_valid,rx_error,tx_ready;
    wire [7:0] rx_byte;
    wire tx_valid; wire [7:0] tx_byte;
    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) uart_input(.clk(clk),.rst_n(reset_n),.rx(rx),.valid(rx_valid),.data(rx_byte),.frame_error(rx_error));
    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) uart_output(.clk(clk),.rst_n(reset_n),.valid(tx_valid),.data(tx_byte),.ready(tx_ready),.tx(tx));
    function automatic [15:0] crc_byte(input [15:0] crc,input [7:0] value);
        reg [15:0] c;integer b;
        begin c=crc^{value,8'b0};for(b=0;b<8;b=b+1)c=c[15]?(c<<1)^16'h1021:c<<1;crc_byte=c;end
    endfunction

    // Receive only small control messages; incoming image data is not supported.
    reg [2:0] rx_state=0;reg [1:0] magic_pos=0;
    reg [5:0] rx_index=0;reg [7:0] rh[0:7];
    reg [7:0] rp[0:31];reg [15:0] rx_crc=16'hffff,rx_crc_low=0;
    reg [15:0] rx_length=0;
    reg packet_event=0;reg [7:0] packet_type=0,packet_station=0;
    reg [15:0] packet_seq=0;reg [7:0] packet_length=0;
    reg [7:0] cp[0:31];integer ri;
    always @(posedge clk)begin
        if(!reset_n || rx_error)begin rx_state<=0;magic_pos<=0;rx_index<=0;rx_crc<=16'hffff;packet_event<=0;rx_length<=0;end
        else begin
            packet_event<=0;
            if(rx_valid)case(rx_state)
                0:begin
                    case(magic_pos)
                        0:magic_pos<=rx_byte=="W"?1:0;
                        1:magic_pos<=rx_byte=="B"?2:(rx_byte=="W"?1:0);
                        2:magic_pos<=rx_byte=="Q"?3:(rx_byte=="W"?1:0);
                        3:begin magic_pos<=0;if(rx_byte=="1")begin rx_state<=1;rx_index<=0;rx_crc<=16'hffff;end else if(rx_byte=="W")magic_pos<=1;end
                    endcase
                end
                1:begin
                    rh[rx_index]<=rx_byte;rx_crc<=crc_byte(rx_crc,rx_byte);
                    if(rx_index==7)begin
                        rx_length<={rx_byte,rh[6]};rx_index<=0;
                        if(rx_byte!=0 || rh[6]>32 || rh[0]!=1)rx_state<=0;
                        else rx_state<=rh[6]==0?3:2;
                    end else rx_index<=rx_index+1'b1;
                end
                2:begin
                    rp[rx_index]<=rx_byte;rx_crc<=crc_byte(rx_crc,rx_byte);
                    if(rx_index==rx_length-1)rx_state<=3;else rx_index<=rx_index+1'b1;
                end
                3:begin rx_crc_low<={8'b0,rx_byte};rx_state<=4;end
                4:begin
                    rx_state<=0;
                    if({rx_byte,rx_crc_low[7:0]}==rx_crc)begin
                        packet_event<=1;packet_type<=rh[1];packet_station<=rh[2];
                        packet_seq<={rh[5],rh[4]};packet_length<=rx_length[7:0];
                        for(ri=0;ri<32;ri=ri+1)cp[ri]<=rp[ri];
                    end
                end
                default:rx_state<=0;
            endcase
        end
    end
    reg heartbeat_seen=0,hello_pending=1;
    reg [31:0] heartbeat_age=0;
    wire heartbeat=packet_event && packet_type==1 && packet_length==0;
    assign link_ok=heartbeat_seen && heartbeat_age<LINK_TIMEOUT;
    always @(posedge clk)begin
        if(!reset_n)begin heartbeat_seen<=0;heartbeat_age<=0;end
        else if(heartbeat)begin heartbeat_seen<=1;heartbeat_age<=0;end
        else if(heartbeat_age<LINK_TIMEOUT)heartbeat_age<=heartbeat_age+1'b1;
    end

    // One outgoing packet buffer; held until ACK or bounded retry completes.
    (* ram_style="distributed" *) reg [7:0] payload[0:515];
    reg [7:0] out_type=0,out_station=0;
    reg [15:0] out_seq=0,out_length=0;
    reg tx_start=0,tx_busy=0,tx_done=0;
    reg [15:0] tx_index=0,tx_crc=16'hffff;
    reg [7:0] tx_value;
    always @*begin
        tx_value=0;
        case(tx_index)
            0:tx_value="W";1:tx_value="B";2:tx_value="Q";3:tx_value="1";
            4:tx_value=1;5:tx_value=out_type;6:tx_value=out_station;7:tx_value=0;
            8:tx_value=out_seq[7:0];9:tx_value=out_seq[15:8];
            10:tx_value=out_length[7:0];11:tx_value=out_length[15:8];
            default:begin
                if(tx_index<12+out_length)tx_value=payload[tx_index-12];
                else if(tx_index==12+out_length)tx_value=tx_crc[7:0];
                else tx_value=tx_crc[15:8];
            end
        endcase
    end
    assign tx_valid=tx_busy;
    assign tx_byte=tx_value;
    always @(posedge clk)begin
        if(!reset_n || abort_scan)begin tx_busy<=0;tx_done<=0;tx_index<=0;tx_crc<=16'hffff;end
        else begin
            tx_done<=0;
            if(tx_start && !tx_busy)begin tx_busy<=1;tx_index<=0;tx_crc<=16'hffff;end
            else if(tx_busy && tx_ready)begin
                if(tx_index>=4 && tx_index<12+out_length)tx_crc<=crc_byte(tx_crc,tx_value);
                if(tx_index==13+out_length)begin tx_busy<=0;tx_done<=1;end
                else tx_index<=tx_index+1'b1;
            end
        end
    end
    localparam [4:0] IDLE=0,HELLO_SENT=1,STATE_SENT=2,WAIT_CAPTURE=3,BEGIN_SENT=4,
        BUILD_BLOCK=5,READ_REQUEST=6,READ_WAIT=7,BLOCK_SENT=8,END_SENT=9,
        WAIT_ACK=10,RETRY_SENT=11,WAIT_RESULT=12,WAIT_CAMERA_FREE=13;
    reg [4:0] state=IDLE;
    reg scan_pending=0;reg [2:0] pending_station=0;
    reg [15:0] scan_sequence=0;
    reg [2:0] active_station=0;
    reg [31:0] offset=0,timer=0;
    reg plane=0,retried=0;
    reg [9:0] fill_index=0;
    reg [7:0] ack_type=0;
    reg [31:0] ack_offset=0;
    reg [13:0] last_ui=14'h3fff;
    wire [13:0] current_ui={phase,verdict,completed_mask,station_id};
    wire ack_match=packet_event && packet_type==2 && packet_length==5 &&
        packet_station==active_station && packet_seq==scan_sequence && cp[0]==ack_type &&
        {cp[4],cp[3],cp[2],cp[1]}==ack_offset;
    wire result_match=packet_event && packet_type==8'h20 && packet_length>=3 &&
        packet_station==active_station && packet_seq==scan_sequence && cp[2]<=24 && packet_length==cp[2]+3;
    always @(posedge clk)begin
        if(!reset_n || abort_scan)begin scan_pending<=0;pending_station<=0;end
        else if(scan_request)begin scan_pending<=1;pending_station<=station_id;end
        else if(state==IDLE && link_ok && !hello_pending && scan_pending)scan_pending<=0;
    end
    integer di;reg digits_ok;reg [47:0] parsed_digits;
    always @*begin
        digits_ok=cp[2]==12;parsed_digits=0;
        for(di=0;di<12;di=di+1)begin
            if(cp[3+di]<"0" || cp[3+di]>"9")digits_ok=0;
            parsed_digits={parsed_digits[43:0],cp[3+di][3:0]};
        end
    end
    task automatic launch_packet(input [7:0] typ,input [15:0] length);
        begin out_type<=typ;out_station<={5'b0,active_station};out_seq<=scan_sequence;out_length<=length;tx_start<=1;end
    endtask
    task automatic fail_scan;
        begin scan_done<=1;scan_status<=6;capture_release<=1;state<=IDLE;end
    endtask
    always @(posedge clk)begin
        if(!reset_n)begin
            state<=IDLE;scan_sequence<=0;active_station<=0;offset<=0;timer<=0;plane<=0;
            fill_index<=0;retried<=0;scan_done<=0;scan_status<=0;text_bcd<=0;text_valid<=0;
            target_station<=0;capture_req<=0;capture_release<=0;read_req<=0;read_addr<=0;read_plane<=0;
            out_type<=0;out_station<=0;out_seq<=0;out_length<=0;tx_start<=0;hello_pending<=1;last_ui<=14'h3fff;
        end else begin
            tx_start<=0;scan_done<=0;capture_req<=0;capture_release<=0;read_req<=0;
            if(abort_scan)begin
                if(state!=IDLE)capture_release<=1;
                state<=IDLE;timer<=0;
            end else case(state)
                IDLE:begin
                    timer<=0;
                    if(link_ok && hello_pending)begin
                        out_type<=3;out_station<=0;out_seq<=1;out_length<=0;tx_start<=1;state<=HELLO_SENT;
                    end else if(scan_pending && link_ok)begin
                        scan_sequence<=scan_sequence+1'b1;active_station<=pending_station;
                        text_valid<=0;target_station<=0;scan_status<=0;
                        if(capture_busy)state<=WAIT_CAMERA_FREE;
                        else begin capture_req<=1;state<=WAIT_CAPTURE;end
                    end else if(link_ok && current_ui!=last_ui)begin
                        last_ui<=current_ui;payload[0]<={4'b0,phase};payload[1]<={5'b0,verdict};payload[2]<={4'b0,completed_mask};
                        out_type<=8'h30;out_station<={5'b0,station_id};out_seq<=scan_sequence;out_length<=3;
                        tx_start<=1;state<=STATE_SENT;
                    end
                end
                HELLO_SENT:if(tx_done)begin hello_pending<=0;state<=IDLE;end
                STATE_SENT:if(tx_done)state<=IDLE;
                WAIT_CAMERA_FREE:begin
                    if(timer>=ACK_TIMEOUT-1)fail_scan();
                    else if(!capture_busy)begin capture_req<=1;timer<=0;state<=WAIT_CAPTURE;end
                    else timer<=timer+1'b1;
                end
                WAIT_CAPTURE:begin
                    if(capture_error || timer>=SCAN_TIMEOUT-1)fail_scan();
                    else if(capture_ready)begin
                        payload[0]<=0;payload[1]<=1;payload[2]<=192;payload[3]<=0;payload[4]<=3;payload[5]<=1;
                        launch_packet(8'h10,6);state<=BEGIN_SENT;
                    end else timer<=timer+1'b1;
                end
                BEGIN_SENT:if(tx_done)begin ack_type<=8'h10;ack_offset<=0;retried<=0;timer<=0;state<=WAIT_ACK;end
                BUILD_BLOCK:begin
                    payload[0]<=offset[7:0];payload[1]<=offset[15:8];payload[2]<=offset[23:16];payload[3]<=offset[31:24];
                    fill_index<=0;read_plane<=plane;timer<=0;state<=READ_REQUEST;
                end
                READ_REQUEST:begin
                    if(capture_error || timer>=ACK_TIMEOUT-1)fail_scan();
                    else if(read_ready)begin
                        read_req<=1;
                        read_addr<=plane?(offset+fill_index):((offset+fill_index)>>1);
                        timer<=0;state<=READ_WAIT;
                    end else timer<=timer+1'b1;
                end
                READ_WAIT:begin
                  if(capture_error || timer>=ACK_TIMEOUT-1)fail_scan();
                  else if(read_valid)begin
                    timer<=0;
                    if(plane)begin
                        payload[4+fill_index]<=read_data[7:0];
                        if(fill_index==511)begin launch_packet(8'h12,516);state<=BLOCK_SENT;end
                        else begin fill_index<=fill_index+1'b1;state<=READ_REQUEST;end
                    end else begin
                        payload[4+fill_index]<=read_data[15:8];payload[5+fill_index]<=read_data[7:0];
                        if(fill_index==510)begin launch_packet(8'h11,516);state<=BLOCK_SENT;end
                        else begin fill_index<=fill_index+2;state<=READ_REQUEST;end
                    end
                  end else timer<=timer+1'b1;
                end
                BLOCK_SENT:if(tx_done)begin
                    ack_type<=plane?8'h12:8'h11;ack_offset<=offset;retried<=0;timer<=0;state<=WAIT_ACK;
                end
                END_SENT:if(tx_done)begin ack_type<=8'h13;ack_offset<=0;retried<=0;timer<=0;state<=WAIT_ACK;end
                RETRY_SENT:if(tx_done)begin timer<=0;state<=WAIT_ACK;end
                WAIT_ACK:begin
                    if(ack_match)begin
                        timer<=0;
                        if(ack_type==8'h10)begin plane<=0;offset<=0;state<=BUILD_BLOCK;end
                        else if(ack_type==8'h11)begin
                            if(offset==98304-512)begin plane<=1;offset<=0;end else offset<=offset+512;
                            state<=BUILD_BLOCK;
                        end else if(ack_type==8'h12)begin
                            if(offset==6144-512)begin launch_packet(8'h13,0);state<=END_SENT;end
                            else begin offset<=offset+512;state<=BUILD_BLOCK;end
                        end else state<=WAIT_RESULT;
                    end else if(timer>=ACK_TIMEOUT-1)begin
                        if(retried)fail_scan();else begin retried<=1;tx_start<=1;state<=RETRY_SENT;end
                    end else timer<=timer+1'b1;
                end
                WAIT_RESULT:begin
                    if(result_match)begin
                        scan_status<=cp[0]<=6?cp[0][2:0]:3'd6;
                        if(cp[0]==1 && (cp[1]!=active_station || !digits_ok))scan_status<=6;
                        scan_done<=1;text_bcd<=parsed_digits;text_valid<=digits_ok;target_station<=cp[1][2:0];
                        capture_release<=1;state<=IDLE;
                    end else if((packet_event && packet_type==8'h21 && packet_seq==scan_sequence && packet_station==active_station) || timer>=SCAN_TIMEOUT-1)fail_scan();
                    else timer<=timer+1'b1;
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
