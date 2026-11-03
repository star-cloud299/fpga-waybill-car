`timescale 1ns/1ps
// Original control RTL. Register values/overrides are traced in CONFIG_SOURCES.md.
module ov5640_config #(
    parameter integer CLK_HZ=50_000_000,
    parameter integer SCCB_PHASE_CYCLES=500,
    parameter integer READBACK_ENABLE=0
)(
    input wire clk, input wire reset_n,
    inout wire cam_scl, inout wire cam_sda, inout wire cam_rst_n,
    output reg ready=0, output reg error=0, output reg id_ok=0,
    output reg [79:0] diag_values=0,
    output reg [9:0] diag_ack=0,
    output reg diag_done=0,
    output wire [3:0] debug_state,debug_bus_error,
    output wire [15:0] debug_register,
    output reg [15:0] debug_id=0
);
    localparam integer CYCLES_MS=CLK_HZ/1000;
    localparam RESET_HOLD=0,RESET_WAIT=1,ID_START=2,ID_WAIT=3,
        TABLE=4,WRITE_WAIT=5,DELAY_WAIT=6,FINISHED=7,FAILED=8,
        READBACK_START=9,READBACK_WAIT=10;
    reg [3:0] state=RESET_HOLD;
    reg [31:0] delay_count=0;
    reg rst_low=1;
    assign cam_rst_n=rst_low ? 1'b0 : 1'bz;
    reg master_start=0,master_read=0;
    reg [15:0] master_addr=0;
    reg [7:0] master_data=0;
    wire master_done,master_error;
    wire [7:0] master_rx;
    wire master_busy;
    assign debug_state=state;
    assign debug_register=master_addr;
    reg id_low=0;
    reg [7:0] id_high=0;
    reg [8:0] table_index=0;
    reg [3:0] readback_index=0;
    function automatic [15:0] readback_address(input [3:0] index);
        case(index)
            0:readback_address=16'h3008; 1:readback_address=16'h3003;
            2:readback_address=16'h3007; 3:readback_address=16'h300e;
            4:readback_address=16'h3017; 5:readback_address=16'h3018;
            6:readback_address=16'h3035; 7:readback_address=16'h3036;
            8:readback_address=16'h3103; default:readback_address=16'h4740;
        endcase
    endfunction
    sccb_master #(.PHASE_CYCLES(SCCB_PHASE_CYCLES)) bus(
        .clk(clk),.reset_n(reset_n),.start(master_start),.read_not_write(master_read),
        .reg_addr(master_addr),.write_data(master_data),.scl(cam_scl),.sda(cam_sda),
        .busy(master_busy),.done(master_done),.error(master_error),.read_data(master_rx),.error_detail(debug_bus_error)
    );

    // BEGIN GENERATED REGISTER TABLE
    localparam integer TABLE_COUNT=258;
    function automatic [23:0] config_entry(input [8:0] index);
        case(index)
            9'd0: config_entry=24'h310311;
            9'd1: config_entry=24'h300882;
            9'd2: config_entry=24'hffff0a;
            9'd3: config_entry=24'h300842;
            9'd4: config_entry=24'h310303;
            9'd5: config_entry=24'h3017ff;
            9'd6: config_entry=24'h3018ff;
            9'd7: config_entry=24'h30341a;
            9'd8: config_entry=24'h303713;
            9'd9: config_entry=24'h310801;
            9'd10: config_entry=24'h363036;
            9'd11: config_entry=24'h36310e;
            9'd12: config_entry=24'h3632e2;
            9'd13: config_entry=24'h363312;
            9'd14: config_entry=24'h3621e0;
            9'd15: config_entry=24'h3704a0;
            9'd16: config_entry=24'h37035a;
            9'd17: config_entry=24'h371578;
            9'd18: config_entry=24'h371701;
            9'd19: config_entry=24'h370b60;
            9'd20: config_entry=24'h37051a;
            9'd21: config_entry=24'h390502;
            9'd22: config_entry=24'h390610;
            9'd23: config_entry=24'h39010a;
            9'd24: config_entry=24'h373112;
            9'd25: config_entry=24'h360008;
            9'd26: config_entry=24'h360133;
            9'd27: config_entry=24'h302d60;
            9'd28: config_entry=24'h362052;
            9'd29: config_entry=24'h371b20;
            9'd30: config_entry=24'h471c50;
            9'd31: config_entry=24'h3a1343;
            9'd32: config_entry=24'h3a1800;
            9'd33: config_entry=24'h3a19f8;
            9'd34: config_entry=24'h363513;
            9'd35: config_entry=24'h363603;
            9'd36: config_entry=24'h363440;
            9'd37: config_entry=24'h362201;
            9'd38: config_entry=24'h3c0134;
            9'd39: config_entry=24'h3c0428;
            9'd40: config_entry=24'h3c0598;
            9'd41: config_entry=24'h3c0600;
            9'd42: config_entry=24'h3c0708;
            9'd43: config_entry=24'h3c0800;
            9'd44: config_entry=24'h3c091c;
            9'd45: config_entry=24'h3c0a9c;
            9'd46: config_entry=24'h3c0b40;
            9'd47: config_entry=24'h381000;
            9'd48: config_entry=24'h381110;
            9'd49: config_entry=24'h381200;
            9'd50: config_entry=24'h370864;
            9'd51: config_entry=24'h400102;
            9'd52: config_entry=24'h40051a;
            9'd53: config_entry=24'h300000;
            9'd54: config_entry=24'h3004ff;
            9'd55: config_entry=24'h300e58;
            9'd56: config_entry=24'h302e00;
            9'd57: config_entry=24'h430030;
            9'd58: config_entry=24'h501f00;
            9'd59: config_entry=24'h440e00;
            9'd60: config_entry=24'h5000a7;
            9'd61: config_entry=24'h3a0f30;
            9'd62: config_entry=24'h3a1028;
            9'd63: config_entry=24'h3a1b30;
            9'd64: config_entry=24'h3a1e26;
            9'd65: config_entry=24'h3a1160;
            9'd66: config_entry=24'h3a1f14;
            9'd67: config_entry=24'h580023;
            9'd68: config_entry=24'h580114;
            9'd69: config_entry=24'h58020f;
            9'd70: config_entry=24'h58030f;
            9'd71: config_entry=24'h580412;
            9'd72: config_entry=24'h580526;
            9'd73: config_entry=24'h58060c;
            9'd74: config_entry=24'h580708;
            9'd75: config_entry=24'h580805;
            9'd76: config_entry=24'h580905;
            9'd77: config_entry=24'h580a08;
            9'd78: config_entry=24'h580b0d;
            9'd79: config_entry=24'h580c08;
            9'd80: config_entry=24'h580d03;
            9'd81: config_entry=24'h580e00;
            9'd82: config_entry=24'h580f00;
            9'd83: config_entry=24'h581003;
            9'd84: config_entry=24'h581109;
            9'd85: config_entry=24'h581207;
            9'd86: config_entry=24'h581303;
            9'd87: config_entry=24'h581400;
            9'd88: config_entry=24'h581501;
            9'd89: config_entry=24'h581603;
            9'd90: config_entry=24'h581708;
            9'd91: config_entry=24'h58180d;
            9'd92: config_entry=24'h581908;
            9'd93: config_entry=24'h581a05;
            9'd94: config_entry=24'h581b06;
            9'd95: config_entry=24'h581c08;
            9'd96: config_entry=24'h581d0e;
            9'd97: config_entry=24'h581e29;
            9'd98: config_entry=24'h581f17;
            9'd99: config_entry=24'h582011;
            9'd100: config_entry=24'h582111;
            9'd101: config_entry=24'h582215;
            9'd102: config_entry=24'h582328;
            9'd103: config_entry=24'h582446;
            9'd104: config_entry=24'h582526;
            9'd105: config_entry=24'h582608;
            9'd106: config_entry=24'h582726;
            9'd107: config_entry=24'h582864;
            9'd108: config_entry=24'h582926;
            9'd109: config_entry=24'h582a24;
            9'd110: config_entry=24'h582b22;
            9'd111: config_entry=24'h582c24;
            9'd112: config_entry=24'h582d24;
            9'd113: config_entry=24'h582e06;
            9'd114: config_entry=24'h582f22;
            9'd115: config_entry=24'h583040;
            9'd116: config_entry=24'h583142;
            9'd117: config_entry=24'h583224;
            9'd118: config_entry=24'h583326;
            9'd119: config_entry=24'h583424;
            9'd120: config_entry=24'h583522;
            9'd121: config_entry=24'h583622;
            9'd122: config_entry=24'h583726;
            9'd123: config_entry=24'h583844;
            9'd124: config_entry=24'h583924;
            9'd125: config_entry=24'h583a26;
            9'd126: config_entry=24'h583b28;
            9'd127: config_entry=24'h583c42;
            9'd128: config_entry=24'h583dce;
            9'd129: config_entry=24'h5180ff;
            9'd130: config_entry=24'h5181f2;
            9'd131: config_entry=24'h518200;
            9'd132: config_entry=24'h518314;
            9'd133: config_entry=24'h518425;
            9'd134: config_entry=24'h518524;
            9'd135: config_entry=24'h518609;
            9'd136: config_entry=24'h518709;
            9'd137: config_entry=24'h518809;
            9'd138: config_entry=24'h518975;
            9'd139: config_entry=24'h518a54;
            9'd140: config_entry=24'h518be0;
            9'd141: config_entry=24'h518cb2;
            9'd142: config_entry=24'h518d42;
            9'd143: config_entry=24'h518e3d;
            9'd144: config_entry=24'h518f56;
            9'd145: config_entry=24'h519046;
            9'd146: config_entry=24'h5191f8;
            9'd147: config_entry=24'h519204;
            9'd148: config_entry=24'h519370;
            9'd149: config_entry=24'h5194f0;
            9'd150: config_entry=24'h5195f0;
            9'd151: config_entry=24'h519603;
            9'd152: config_entry=24'h519701;
            9'd153: config_entry=24'h519804;
            9'd154: config_entry=24'h519912;
            9'd155: config_entry=24'h519a04;
            9'd156: config_entry=24'h519b00;
            9'd157: config_entry=24'h519c06;
            9'd158: config_entry=24'h519d82;
            9'd159: config_entry=24'h519e38;
            9'd160: config_entry=24'h548001;
            9'd161: config_entry=24'h548108;
            9'd162: config_entry=24'h548214;
            9'd163: config_entry=24'h548328;
            9'd164: config_entry=24'h548451;
            9'd165: config_entry=24'h548565;
            9'd166: config_entry=24'h548671;
            9'd167: config_entry=24'h54877d;
            9'd168: config_entry=24'h548887;
            9'd169: config_entry=24'h548991;
            9'd170: config_entry=24'h548a9a;
            9'd171: config_entry=24'h548baa;
            9'd172: config_entry=24'h548cb8;
            9'd173: config_entry=24'h548dcd;
            9'd174: config_entry=24'h548edd;
            9'd175: config_entry=24'h548fea;
            9'd176: config_entry=24'h54901d;
            9'd177: config_entry=24'h53811e;
            9'd178: config_entry=24'h53825b;
            9'd179: config_entry=24'h538308;
            9'd180: config_entry=24'h53840a;
            9'd181: config_entry=24'h53857e;
            9'd182: config_entry=24'h538688;
            9'd183: config_entry=24'h53877c;
            9'd184: config_entry=24'h53886c;
            9'd185: config_entry=24'h538910;
            9'd186: config_entry=24'h538a01;
            9'd187: config_entry=24'h538b98;
            9'd188: config_entry=24'h558006;
            9'd189: config_entry=24'h558340;
            9'd190: config_entry=24'h558410;
            9'd191: config_entry=24'h558910;
            9'd192: config_entry=24'h558a00;
            9'd193: config_entry=24'h558bf8;
            9'd194: config_entry=24'h501d40;
            9'd195: config_entry=24'h530008;
            9'd196: config_entry=24'h530130;
            9'd197: config_entry=24'h530210;
            9'd198: config_entry=24'h530300;
            9'd199: config_entry=24'h530408;
            9'd200: config_entry=24'h530530;
            9'd201: config_entry=24'h530608;
            9'd202: config_entry=24'h530716;
            9'd203: config_entry=24'h530908;
            9'd204: config_entry=24'h530a30;
            9'd205: config_entry=24'h530b04;
            9'd206: config_entry=24'h530c06;
            9'd207: config_entry=24'h502500;
            9'd208: config_entry=24'h303521;
            9'd209: config_entry=24'h303646;
            9'd210: config_entry=24'h3c0708;
            9'd211: config_entry=24'h382041;
            9'd212: config_entry=24'h382107;
            9'd213: config_entry=24'h381431;
            9'd214: config_entry=24'h381531;
            9'd215: config_entry=24'h380000;
            9'd216: config_entry=24'h380100;
            9'd217: config_entry=24'h380200;
            9'd218: config_entry=24'h380304;
            9'd219: config_entry=24'h38040a;
            9'd220: config_entry=24'h38053f;
            9'd221: config_entry=24'h380607;
            9'd222: config_entry=24'h38079b;
            9'd223: config_entry=24'h380801;
            9'd224: config_entry=24'h380940;
            9'd225: config_entry=24'h380a00;
            9'd226: config_entry=24'h380bf0;
            9'd227: config_entry=24'h380c07;
            9'd228: config_entry=24'h380d68;
            9'd229: config_entry=24'h380e03;
            9'd230: config_entry=24'h380fd8;
            9'd231: config_entry=24'h381306;
            9'd232: config_entry=24'h361800;
            9'd233: config_entry=24'h361229;
            9'd234: config_entry=24'h370952;
            9'd235: config_entry=24'h370c03;
            9'd236: config_entry=24'h3a0203;
            9'd237: config_entry=24'h3a03d8;
            9'd238: config_entry=24'h3a1403;
            9'd239: config_entry=24'h3a15d8;
            9'd240: config_entry=24'h400402;
            9'd241: config_entry=24'h30021c;
            9'd242: config_entry=24'h3006c3;
            9'd243: config_entry=24'h471303;
            9'd244: config_entry=24'h440704;
            9'd245: config_entry=24'h460b35;
            9'd246: config_entry=24'h460c22;
            9'd247: config_entry=24'h483722;
            9'd248: config_entry=24'h382402;
            9'd249: config_entry=24'h5001a3;
            9'd250: config_entry=24'h350300;
            9'd251: config_entry=24'h430061;
            9'd252: config_entry=24'h501f01;
            9'd253: config_entry=24'h474022;
            9'd254: config_entry=24'h503d00;
            9'd255: config_entry=24'hffff0a;
            9'd256: config_entry=24'h300802;
            9'd257: config_entry=24'hfffffa;
            default: config_entry=24'hffff01;
        endcase
    endfunction
    // END GENERATED REGISTER TABLE

    wire [23:0] entry=config_entry(table_index);
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state<=RESET_HOLD; delay_count<=0; rst_low<=1;
            ready<=0; error<=0; id_ok<=0; master_start<=0; master_read<=0;
            master_addr<=0; master_data<=0; id_low<=0; id_high<=0; table_index<=0;
            readback_index<=0;diag_values<=0;diag_ack<=0;diag_done<=0;debug_id<=0;
        end else begin
            master_start<=0;
            case(state)
                RESET_HOLD: if(delay_count>=50*CYCLES_MS-1) begin
                    delay_count<=0; rst_low<=0; state<=RESET_WAIT;
                end else delay_count<=delay_count+1'b1;
                RESET_WAIT: if(delay_count>=20*CYCLES_MS-1) begin
                    delay_count<=0; state<=ID_START;
                end else delay_count<=delay_count+1'b1;
                ID_START: begin
                    master_addr<=id_low ? 16'h300b : 16'h300a;
                    master_read<=1; master_start<=1; state<=ID_WAIT;
                end
                ID_WAIT: if(master_done) begin
                    if(!master_error) begin
                        if(id_low) debug_id[7:0]<=master_rx;
                        else debug_id[15:8]<=master_rx;
                    end
                    if(master_error) begin error<=1; state<=FAILED; end
                    else if(!id_low) begin
                        id_high<=master_rx; id_low<=1; state<=ID_START;
                    end else if(id_high!=8'h56 || master_rx!=8'h40) begin
                        error<=1; state<=FAILED;
                    end else begin id_ok<=1; state<=TABLE; end
                end
                TABLE: if(table_index==TABLE_COUNT) begin
                    if(READBACK_ENABLE) begin readback_index<=0;state<=READBACK_START;end
                    else begin ready<=1;state<=FINISHED;end
                end else if(entry[23:8]==16'hffff) begin
                    delay_count<=entry[7:0]*CYCLES_MS-1;
                    state<=DELAY_WAIT;
                end else begin
                    master_read<=0; master_addr<=entry[23:8]; master_data<=entry[7:0];
                    master_start<=1; state<=WRITE_WAIT;
                end
                WRITE_WAIT: if(master_done) begin
                    if(master_error) begin error<=1; state<=FAILED; end
                    else begin table_index<=table_index+1'b1; state<=TABLE; end
                end
                DELAY_WAIT: if(delay_count==0) begin
                    table_index<=table_index+1'b1; state<=TABLE;
                end else delay_count<=delay_count-1'b1;
                READBACK_START: begin
                    master_addr<=readback_address(readback_index);
                    master_read<=1;master_start<=1;state<=READBACK_WAIT;
                end
                READBACK_WAIT: if(master_done) begin
                    diag_values[readback_index*8+:8]<=master_rx;
                    diag_ack[readback_index]<=!master_error;
                    if(readback_index==9) begin
                        diag_done<=1;ready<=1;state<=FINISHED;
                    end else begin readback_index<=readback_index+1'b1;state<=READBACK_START;end
                end
                FINISHED: ready<=1;
                FAILED: begin ready<=0; error<=1; end
                default: begin ready<=0; error<=1; state<=FAILED; end
            endcase
        end
    end
endmodule
