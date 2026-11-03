`timescale 1ns/1ps
// Continuous DVP capture with two buffers and a vertical-blank ownership swap.
// RGB565 wire order: high byte followed by low byte. Read latency: one pixel_clk.
module live_frame_buffer #(
    parameter integer SOURCE_WIDTH=320,
    parameter integer SOURCE_HEIGHT=240,
    parameter integer CROP_WIDTH=256,
    parameter integer CROP_HEIGHT=192,
    parameter integer CROP_LEFT=32,
    parameter integer CROP_TOP=24
)(
    input wire cam_pclk, reset_n,
    input wire cam_vsync, cam_href,
    input wire [7:0] cam_data,
    input wire pixel_clk,
    input wire [7:0] read_x, read_y,
    input wire read_swap,
    output wire [15:0] pixel_rgb565,
    output reg frame_valid,
    output reg frame_error
);
    localparam integer LINE_BYTES=SOURCE_WIDTH*2;
    localparam integer FRAME_BYTES=LINE_BYTES*SOURCE_HEIGHT;
    localparam integer WORDS=CROP_WIDTH*CROP_HEIGHT;
    localparam integer AW=(WORDS<2)?1:$clog2(WORDS);
    localparam integer BCW=$clog2(FRAME_BYTES+2);
    localparam integer LCW=$clog2(SOURCE_HEIGHT+2);
    localparam integer LBW=$clog2(LINE_BYTES+2);
    localparam integer CCW=$clog2(WORDS+1);
    localparam [1:0] WAIT_VSYNC=0, CAPTURE=1, WAIT_ACK=2;

    // 49152 words must occupy 24 x 2048-word RAMB36s per bank, not a
    // rounded 65536-word memory. Explicit tiles prevent Vivado from moving an
    // over-rounded bank into LUT RAM when the device's 50 RAMB36 limit is hit.
    localparam integer TILE_WORDS=2048;
    localparam integer TILES=(WORDS+TILE_WORDS-1)/TILE_WORDS;
    localparam integer TW=(TILES<2)?1:$clog2(TILES);
    wire [15:0] tile_q0 [0:TILES-1];
    wire [15:0] tile_q1 [0:TILES-1];
    reg [TW-1:0] read_tile_d;
    wire [15:0] q0=tile_q0[read_tile_d];
    wire [15:0] q1=tile_q1[read_tile_d];
    wire read_in_range=(read_x<CROP_WIDTH && read_y<CROP_HEIGHT);
    wire [AW-1:0] read_address=read_y*CROP_WIDTH+read_x;
    reg read_in_range_d;
    reg display_buffer;
    always @(posedge pixel_clk) begin
        read_tile_d<=read_address/TILE_WORDS;
        read_in_range_d<=read_in_range;
    end
    assign pixel_rgb565=(frame_valid && read_in_range_d) ? (display_buffer?q1:q0) : 16'h0000;

    (* ASYNC_REG="TRUE" *) reg [1:0] camera_reset_pipe,pixel_reset_pipe;
    always @(posedge cam_pclk or negedge reset_n)
        if(!reset_n) camera_reset_pipe<=0;
        else camera_reset_pipe<={camera_reset_pipe[0],1'b1};
    always @(posedge pixel_clk or negedge reset_n)
        if(!reset_n) pixel_reset_pipe<=0;
        else pixel_reset_pipe<={pixel_reset_pipe[0],1'b1};

    // A toggle also encodes its bank: ready=1 is bank0, ready=0 is bank1.
    // There is only one outstanding publication, and the camera holds still
    // until pixel_clk accepts it at read_swap and acknowledges that same toggle.
    reg ready_toggle,ack_toggle;
    (* ASYNC_REG="TRUE" *) reg [1:0] ready_sync,ack_sync;
    reg ready_seen,pending,pending_buffer,pending_toggle;
    always @(posedge pixel_clk) begin
        if(!pixel_reset_pipe[1]) begin
            ready_sync<=0;ready_seen<=0;pending<=0;
            pending_buffer<=0;pending_toggle<=0;ack_toggle<=0;
            display_buffer<=1;frame_valid<=0;
        end else begin
            ready_sync<={ready_sync[0],ready_toggle};
            if(ready_sync[1]!=ready_seen) begin
                ready_seen<=ready_sync[1];
                pending<=1;
                pending_buffer<=~ready_sync[1];
                pending_toggle<=ready_sync[1];
            end
            if(read_swap && pending) begin
                display_buffer<=pending_buffer;
                frame_valid<=1;
                ack_toggle<=pending_toggle;
                pending<=0;
            end
        end
    end

    reg [1:0] state;
    reg write_buffer,previous_vsync,previous_href,current_error;
    reg [BCW-1:0] byte_count;
    reg [LCW-1:0] line_count;
    reg [LBW-1:0] line_bytes;
    reg [CCW-1:0] crop_count;
    reg [7:0] high_byte;
    wire vsync_rising=cam_vsync && !previous_vsync;
    wire [LBW-1:0] source_x=line_bytes>>1;
    wire [LCW-1:0] source_y=line_count-1'b1;
    wire inside_crop=(source_x>=CROP_LEFT && source_x<CROP_LEFT+CROP_WIDTH &&
                      source_y>=CROP_TOP && source_y<CROP_TOP+CROP_HEIGHT);
    wire store_enable=(state==CAPTURE && !cam_vsync && cam_href &&
                       previous_href && line_bytes[0] && inside_crop && crop_count<WORDS);
    wire [AW-1:0] write_address=(source_y-CROP_TOP)*CROP_WIDTH+(source_x-CROP_LEFT);
    // Independent write/read clocks, no resets on RAM data or its read port.
    genvar tile;
    generate for(tile=0;tile<TILES;tile=tile+1) begin: bram_tile
        (* ram_style="block" *) reg [15:0] ram0 [0:TILE_WORDS-1];
        (* ram_style="block" *) reg [15:0] ram1 [0:TILE_WORDS-1];
        reg [15:0] read0,read1;
        always @(posedge cam_pclk) begin
            if(store_enable && !write_buffer && write_address/TILE_WORDS==tile)
                ram0[write_address%TILE_WORDS]<={high_byte,cam_data};
            if(store_enable && write_buffer && write_address/TILE_WORDS==tile)
                ram1[write_address%TILE_WORDS]<={high_byte,cam_data};
        end
        always @(posedge pixel_clk) begin
            read0<=ram0[read_address%TILE_WORDS];
            read1<=ram1[read_address%TILE_WORDS];
        end
        assign tile_q0[tile]=read0;
        assign tile_q1[tile]=read1;
    end endgenerate
    wire valid_geometry=(!current_error && byte_count==FRAME_BYTES &&
        line_count==SOURCE_HEIGHT && crop_count==WORDS && !cam_href &&
        !(previous_href && line_bytes!=LINE_BYTES));

    always @(posedge cam_pclk) begin
        if(!camera_reset_pipe[1]) begin
            ack_sync<=0;ready_toggle<=0;write_buffer<=0;state<=WAIT_VSYNC;
            previous_vsync<=0;previous_href<=0;current_error<=0;frame_error<=0;
            byte_count<=0;line_count<=0;line_bytes<=0;crop_count<=0;high_byte<=0;
        end else begin
            ack_sync<={ack_sync[0],ack_toggle};
            previous_vsync<=cam_vsync;
            case(state)
                WAIT_VSYNC: if(vsync_rising) begin
                    state<=CAPTURE;previous_href<=0;current_error<=0;
                    byte_count<=0;line_count<=0;line_bytes<=0;crop_count<=0;
                end
                CAPTURE: begin
                    if(vsync_rising) begin
                        frame_error<=~valid_geometry;
                        previous_href<=0;current_error<=0;
                        byte_count<=0;line_count<=0;line_bytes<=0;crop_count<=0;
                        if(valid_geometry) begin
                            ready_toggle<=~ready_toggle;
                            state<=WAIT_ACK;
                        end
                        // A bad frame is discarded; the same boundary arms the
                        // following frame in the existing free buffer.
                    end else if(!cam_vsync) begin
                        previous_href<=cam_href;
                        if(cam_href) begin
                            if(!previous_href) begin
                                high_byte<=cam_data;line_bytes<=1;
                                if(line_count<SOURCE_HEIGHT+1) line_count<=line_count+1'b1;
                                if(line_count>=SOURCE_HEIGHT) current_error<=1;
                            end else begin
                                if(!line_bytes[0]) high_byte<=cam_data;
                                if(line_bytes<LINE_BYTES+1) line_bytes<=line_bytes+1'b1;
                                if(line_bytes>=LINE_BYTES) current_error<=1;
                            end
                            if(byte_count<FRAME_BYTES+1) byte_count<=byte_count+1'b1;
                            if(byte_count>=FRAME_BYTES) current_error<=1;
                            if(store_enable) crop_count<=crop_count+1'b1;
                        end else if(previous_href && line_bytes!=LINE_BYTES) current_error<=1;
                    end else begin
                        previous_href<=0;
                        if(cam_href) current_error<=1;
                    end
                end
                WAIT_ACK: if(ack_sync[1]==ready_toggle) begin
                    write_buffer<=~write_buffer;
                    state<=WAIT_VSYNC;previous_href<=0;
                end
                default: state<=WAIT_VSYNC;
            endcase
        end
    end
endmodule
