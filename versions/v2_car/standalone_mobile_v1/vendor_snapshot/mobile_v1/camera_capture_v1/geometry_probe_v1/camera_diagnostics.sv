`timescale 1ns/1ps
// PCLK-domain heartbeat plus independent sys-clock VS/HREF observers.
// Reports are read-only diagnostics. They do not imply a valid image.
module camera_diagnostics #(
    parameter integer REPORT_CYCLES=50000000,
    parameter integer UART_CLKS_PER_BIT=434,
    parameter integer PCLK_DIV_BIT=9,
    parameter integer PCLK_ALIVE_CYCLES=5000000,
    parameter integer VS_ALIVE_CYCLES=25000000
)(
    input wire clk,reset_n,cam_pclk,cam_vsync,cam_href,
    input wire config_ready,config_error,id_ok,frame_valid,frame_error,
    input wire [79:0] diag_values,
    input wire [9:0] diag_ack,
    input wire diag_done,
    input wire cam_scl,cam_sda,cam_rst_n,
    input wire [3:0] bus_error,config_state,
    input wire [15:0] config_register,observed_id,
    input wire geo_valid,
    input wire [31:0] geo_frame,geo_bytes,geo_overlap,
    input wire [15:0] geo_lines,geo_min,geo_max,
    output wire uart_txd,
    output wire [3:0] led_n
);
    reg [PCLK_DIV_BIT:0] pclk_div=0;
    always @(posedge cam_pclk or negedge reset_n)
        if(!reset_n)pclk_div<=0;
        else pclk_div<=pclk_div+1'b1;
    (* ASYNC_REG="TRUE" *) reg [2:0] pclk_sync=0,vs_sync=0,hs_sync=0,raw_pclk_sync=0;
    (* ASYNC_REG="TRUE" *) reg [1:0] valid_sync=0,error_sync=0;
    reg [31:0] pc_count=0,vs_count=0,hs_count=0;
    reg [31:0] pclk_age=0,vs_age=0,hs_age=0;
    reg pclk_alive=0,vs_alive=0,hs_alive=0;
    always @(posedge clk) begin
        if(!reset_n)begin
            pclk_sync<=0;vs_sync<=0;hs_sync<=0;raw_pclk_sync<=0;
            valid_sync<=0;error_sync<=0;pc_count<=0;vs_count<=0;hs_count<=0;
            pclk_age<=0;vs_age<=0;hs_age<=0;pclk_alive<=0;vs_alive<=0;hs_alive<=0;
        end else begin
            pclk_sync<={pclk_sync[1:0],pclk_div[PCLK_DIV_BIT]};
            raw_pclk_sync<={raw_pclk_sync[1:0],cam_pclk};
            vs_sync<={vs_sync[1:0],cam_vsync};
            hs_sync<={hs_sync[1:0],cam_href};
            valid_sync<={valid_sync[0],frame_valid};
            error_sync<={error_sync[0],frame_error};
            if(pclk_sync[2]!=pclk_sync[1])begin
                pc_count<=pc_count+1'b1;pclk_age<=0;pclk_alive<=1;
            end else if(pclk_age>=PCLK_ALIVE_CYCLES)pclk_alive<=0;
            else pclk_age<=pclk_age+1'b1;
            if(vs_sync[1] && !vs_sync[2])begin
                vs_count<=vs_count+1'b1;vs_age<=0;vs_alive<=1;
            end else if(vs_age>=VS_ALIVE_CYCLES)vs_alive<=0;
            else vs_age<=vs_age+1'b1;
            if(hs_sync[1] && !hs_sync[2])begin
                hs_count<=hs_count+1'b1;hs_age<=0;hs_alive<=1;
            end else if(hs_age>=PCLK_ALIVE_CYCLES)hs_alive<=0;
            else hs_age<=hs_age+1'b1;
        end
    end
    assign led_n=~{valid_sync[1],vs_alive,pclk_alive,config_ready};
    localparam integer MESSAGE_BYTES=324;
    localparam [MESSAGE_BYTES*8-1:0] TEMPLATE="LIVE cfg=0 id=0 pclk=0 vs=0 href=0 frame=0 err=0 pc=00000000 vsn=00000000 hsn=00000000 pins=0\015\012REG done=0 ack=000 3008=00 3003=00 3007=00 300E=00 3017=00 3018=00 3035=00 3036=00 3103=00 4740=00\015\012BUS scl=0 sda=0 rst=0 err=0 st=0 reg=0000 id=0000\015\012GEO valid=0 n=00000000 ln=0000 bytes=00000000 min=0000 max=0000 vsh=00000000\015\012";
    reg [31:0] timer=0;
    reg reporting=0;
    reg [8:0] char_index=0;
    reg [7:0] flags_snapshot=0;
    reg [31:0] pc_snapshot=0,vs_snapshot=0,hs_snapshot=0;
    reg [3:0] pins_snapshot=0;
    reg [11:0] ack_snapshot=0;
    reg [79:0] regs_snapshot=0;
    (* ASYNC_REG="TRUE" *) reg [1:0] scl_sync=0,sda_sync=0,rst_sync=0;
    reg [2:0] bus_pins_snapshot=0;
    reg [3:0] bus_error_snapshot=0,state_snapshot=0;
    reg [15:0] register_snapshot=0,id_snapshot=0;
    always @(posedge clk) begin
        if(!reset_n) begin scl_sync<=0;sda_sync<=0;rst_sync<=0;end
        else begin
            scl_sync<={scl_sync[0],cam_scl};sda_sync<={sda_sync[0],cam_sda};
            rst_sync<={rst_sync[0],cam_rst_n};
        end
    end
    reg geo_valid_snapshot=0;
    reg [31:0] geo_frame_snapshot=0,geo_bytes_snapshot=0,geo_overlap_snapshot=0;
    reg [15:0] geo_lines_snapshot=0,geo_min_snapshot=0,geo_max_snapshot=0;
    reg [7:0] tx_data;
    wire tx_ready;
    function automatic [7:0] hex_ascii(input [3:0] nibble);
        hex_ascii=nibble<10 ? 8'h30+nibble : 8'h41+nibble-10;
    endfunction
    uart_tx #(.CLKS_PER_BIT(UART_CLKS_PER_BIT)) tx_unit(
        .clk(clk),.rst_n(reset_n),.valid(reporting),.data(tx_data),
        .ready(tx_ready),.tx(uart_txd));
    always @* begin
        tx_data=TEMPLATE[(MESSAGE_BYTES-1-char_index)*8+:8];
        case(char_index)
            9:tx_data=8'h30+flags_snapshot[0];
            14:tx_data=8'h30+flags_snapshot[1];
            21:tx_data=8'h30+flags_snapshot[2];
            26:tx_data=8'h30+flags_snapshot[3];
            33:tx_data=8'h30+flags_snapshot[4];
            41:tx_data=8'h30+flags_snapshot[5];
            47:tx_data=8'h30+flags_snapshot[6];
            104:tx_data=8'h30+flags_snapshot[7];
            52:tx_data=hex_ascii(pc_snapshot[28+:4]);
            53:tx_data=hex_ascii(pc_snapshot[24+:4]);
            54:tx_data=hex_ascii(pc_snapshot[20+:4]);
            55:tx_data=hex_ascii(pc_snapshot[16+:4]);
            56:tx_data=hex_ascii(pc_snapshot[12+:4]);
            57:tx_data=hex_ascii(pc_snapshot[8+:4]);
            58:tx_data=hex_ascii(pc_snapshot[4+:4]);
            59:tx_data=hex_ascii(pc_snapshot[0+:4]);
            65:tx_data=hex_ascii(vs_snapshot[28+:4]);
            66:tx_data=hex_ascii(vs_snapshot[24+:4]);
            67:tx_data=hex_ascii(vs_snapshot[20+:4]);
            68:tx_data=hex_ascii(vs_snapshot[16+:4]);
            69:tx_data=hex_ascii(vs_snapshot[12+:4]);
            70:tx_data=hex_ascii(vs_snapshot[8+:4]);
            71:tx_data=hex_ascii(vs_snapshot[4+:4]);
            72:tx_data=hex_ascii(vs_snapshot[0+:4]);
            78:tx_data=hex_ascii(hs_snapshot[28+:4]);
            79:tx_data=hex_ascii(hs_snapshot[24+:4]);
            80:tx_data=hex_ascii(hs_snapshot[20+:4]);
            81:tx_data=hex_ascii(hs_snapshot[16+:4]);
            82:tx_data=hex_ascii(hs_snapshot[12+:4]);
            83:tx_data=hex_ascii(hs_snapshot[8+:4]);
            84:tx_data=hex_ascii(hs_snapshot[4+:4]);
            85:tx_data=hex_ascii(hs_snapshot[0+:4]);
            92:tx_data=hex_ascii(pins_snapshot[0+:4]);
            110:tx_data=hex_ascii(ack_snapshot[8+:4]);
            111:tx_data=hex_ascii(ack_snapshot[4+:4]);
            112:tx_data=hex_ascii(ack_snapshot[0+:4]);
            119:tx_data=hex_ascii(regs_snapshot[4+:4]);
            120:tx_data=hex_ascii(regs_snapshot[0+:4]);
            127:tx_data=hex_ascii(regs_snapshot[12+:4]);
            128:tx_data=hex_ascii(regs_snapshot[8+:4]);
            135:tx_data=hex_ascii(regs_snapshot[20+:4]);
            136:tx_data=hex_ascii(regs_snapshot[16+:4]);
            143:tx_data=hex_ascii(regs_snapshot[28+:4]);
            144:tx_data=hex_ascii(regs_snapshot[24+:4]);
            151:tx_data=hex_ascii(regs_snapshot[36+:4]);
            152:tx_data=hex_ascii(regs_snapshot[32+:4]);
            159:tx_data=hex_ascii(regs_snapshot[44+:4]);
            160:tx_data=hex_ascii(regs_snapshot[40+:4]);
            167:tx_data=hex_ascii(regs_snapshot[52+:4]);
            168:tx_data=hex_ascii(regs_snapshot[48+:4]);
            175:tx_data=hex_ascii(regs_snapshot[60+:4]);
            176:tx_data=hex_ascii(regs_snapshot[56+:4]);
            183:tx_data=hex_ascii(regs_snapshot[68+:4]);
            184:tx_data=hex_ascii(regs_snapshot[64+:4]);
            191:tx_data=hex_ascii(regs_snapshot[76+:4]);
            192:tx_data=hex_ascii(regs_snapshot[72+:4]);
            203:tx_data=8'h30+bus_pins_snapshot[0];
            209:tx_data=8'h30+bus_pins_snapshot[1];
            215:tx_data=8'h30+bus_pins_snapshot[2];
            221:tx_data=hex_ascii(bus_error_snapshot[0+:4]);
            226:tx_data=hex_ascii(state_snapshot[0+:4]);
            232:tx_data=hex_ascii(register_snapshot[12+:4]);
            233:tx_data=hex_ascii(register_snapshot[8+:4]);
            234:tx_data=hex_ascii(register_snapshot[4+:4]);
            235:tx_data=hex_ascii(register_snapshot[0+:4]);
            240:tx_data=hex_ascii(id_snapshot[12+:4]);
            241:tx_data=hex_ascii(id_snapshot[8+:4]);
            242:tx_data=hex_ascii(id_snapshot[4+:4]);
            243:tx_data=hex_ascii(id_snapshot[0+:4]);
            256:tx_data=8'h30+geo_valid_snapshot;
            260:tx_data=hex_ascii(geo_frame_snapshot[28+:4]);
            261:tx_data=hex_ascii(geo_frame_snapshot[24+:4]);
            262:tx_data=hex_ascii(geo_frame_snapshot[20+:4]);
            263:tx_data=hex_ascii(geo_frame_snapshot[16+:4]);
            264:tx_data=hex_ascii(geo_frame_snapshot[12+:4]);
            265:tx_data=hex_ascii(geo_frame_snapshot[8+:4]);
            266:tx_data=hex_ascii(geo_frame_snapshot[4+:4]);
            267:tx_data=hex_ascii(geo_frame_snapshot[0+:4]);
            272:tx_data=hex_ascii(geo_lines_snapshot[12+:4]);
            273:tx_data=hex_ascii(geo_lines_snapshot[8+:4]);
            274:tx_data=hex_ascii(geo_lines_snapshot[4+:4]);
            275:tx_data=hex_ascii(geo_lines_snapshot[0+:4]);
            283:tx_data=hex_ascii(geo_bytes_snapshot[28+:4]);
            284:tx_data=hex_ascii(geo_bytes_snapshot[24+:4]);
            285:tx_data=hex_ascii(geo_bytes_snapshot[20+:4]);
            286:tx_data=hex_ascii(geo_bytes_snapshot[16+:4]);
            287:tx_data=hex_ascii(geo_bytes_snapshot[12+:4]);
            288:tx_data=hex_ascii(geo_bytes_snapshot[8+:4]);
            289:tx_data=hex_ascii(geo_bytes_snapshot[4+:4]);
            290:tx_data=hex_ascii(geo_bytes_snapshot[0+:4]);
            296:tx_data=hex_ascii(geo_min_snapshot[12+:4]);
            297:tx_data=hex_ascii(geo_min_snapshot[8+:4]);
            298:tx_data=hex_ascii(geo_min_snapshot[4+:4]);
            299:tx_data=hex_ascii(geo_min_snapshot[0+:4]);
            305:tx_data=hex_ascii(geo_max_snapshot[12+:4]);
            306:tx_data=hex_ascii(geo_max_snapshot[8+:4]);
            307:tx_data=hex_ascii(geo_max_snapshot[4+:4]);
            308:tx_data=hex_ascii(geo_max_snapshot[0+:4]);
            314:tx_data=hex_ascii(geo_overlap_snapshot[28+:4]);
            315:tx_data=hex_ascii(geo_overlap_snapshot[24+:4]);
            316:tx_data=hex_ascii(geo_overlap_snapshot[20+:4]);
            317:tx_data=hex_ascii(geo_overlap_snapshot[16+:4]);
            318:tx_data=hex_ascii(geo_overlap_snapshot[12+:4]);
            319:tx_data=hex_ascii(geo_overlap_snapshot[8+:4]);
            320:tx_data=hex_ascii(geo_overlap_snapshot[4+:4]);
            321:tx_data=hex_ascii(geo_overlap_snapshot[0+:4]);
            default:begin end
        endcase
    end
    always @(posedge clk)begin
        if(!reset_n)begin
            timer<=0;reporting<=0;char_index<=0;flags_snapshot<=0;
            pc_snapshot<=0;vs_snapshot<=0;hs_snapshot<=0;pins_snapshot<=0;
            geo_valid_snapshot<=0;geo_frame_snapshot<=0;geo_bytes_snapshot<=0;geo_overlap_snapshot<=0;
            geo_lines_snapshot<=0;geo_min_snapshot<=0;geo_max_snapshot<=0;
            ack_snapshot<=0;regs_snapshot<=0;bus_pins_snapshot<=0;bus_error_snapshot<=0;state_snapshot<=0;register_snapshot<=0;id_snapshot<=0;
        end else if(reporting)begin
            if(tx_ready)begin
                if(char_index==MESSAGE_BYTES-1)begin reporting<=0;char_index<=0;end
                else char_index<=char_index+1'b1;
            end
        end else if(timer>=REPORT_CYCLES-1)begin
            timer<=0;reporting<=1;char_index<=0;
            flags_snapshot<={diag_done,config_error|error_sync[1],valid_sync[1],
                            hs_alive,vs_alive,pclk_alive,id_ok,config_ready};
            pc_snapshot<=pc_count;vs_snapshot<=vs_count;hs_snapshot<=hs_count;
            pins_snapshot<={1'b0,vs_sync[2],hs_sync[2],raw_pclk_sync[2]};
            ack_snapshot<={2'b00,diag_ack};regs_snapshot<=diag_values;
            bus_pins_snapshot<={rst_sync[1],sda_sync[1],scl_sync[1]};
            bus_error_snapshot<=bus_error;state_snapshot<=config_state;
            register_snapshot<=config_register;id_snapshot<=observed_id;
            geo_valid_snapshot<=geo_valid;geo_frame_snapshot<=geo_frame;geo_bytes_snapshot<=geo_bytes;
            geo_overlap_snapshot<=geo_overlap;geo_lines_snapshot<=geo_lines;
            geo_min_snapshot<=geo_min;geo_max_snapshot<=geo_max;
        end else timer<=timer+1'b1;
    end
endmodule
