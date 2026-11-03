`timescale 1ns/1ps
// Passive DVP geometry observer. No dependency on the capture FSM or RAM.
// A held mailbox plus request/ack toggles transfers one coherent snapshot.
module geometry_monitor(
    input wire cam_pclk,sys_clk,reset_n,cam_vsync,cam_href,
    output reg valid=0,update=0,
    output reg [31:0] frame_number=0,total_bytes=0,blank_href_samples=0,
    output reg [15:0] lines=0,min_line_bytes=0,max_line_bytes=0
);
    (* ASYNC_REG="TRUE" *) reg [1:0] cam_reset=0;
    always @(posedge cam_pclk or negedge reset_n)
        if(!reset_n)cam_reset<=0;
        else cam_reset<={cam_reset[0],1'b1};
    reg previous_vs=0,armed=0,line_open=0;
    reg [31:0] frame_seq=0,active_bytes=0,overlap_count=0;
    reg [15:0] line_count=0,line_bytes=0,line_min=16'hffff,line_max=0;
    reg [143:0] mailbox=0;
    reg request_toggle=0,ack_toggle=0;
    (* ASYNC_REG="TRUE" *) reg [1:0] ack_sync=0,request_sync=0;
    wire vs_rise=cam_vsync && !previous_vs;
    wire [15:0] final_min=(line_open && line_bytes<line_min)?line_bytes:line_min;
    wire [15:0] final_max=(line_open && line_bytes>line_max)?line_bytes:line_max;
    always @(posedge cam_pclk or negedge reset_n)begin
        // Clear the mailbox/request even when the sensor's PCLK has stopped.
        // The synchronous guard below still holds the observer reset for two
        // camera edges after reset_n is released.
        if(!reset_n)begin
            previous_vs<=0;armed<=0;line_open<=0;frame_seq<=0;
            active_bytes<=0;overlap_count<=0;line_count<=0;line_bytes<=0;
            line_min<=16'hffff;line_max<=0;mailbox<=0;request_toggle<=0;ack_sync<=0;
        end else if(!cam_reset[1])begin
            previous_vs<=0;armed<=0;line_open<=0;frame_seq<=0;
            active_bytes<=0;overlap_count<=0;line_count<=0;line_bytes<=0;
            line_min<=16'hffff;line_max<=0;mailbox<=0;request_toggle<=0;ack_sync<=0;
        end else begin
            previous_vs<=cam_vsync;
            ack_sync<={ack_sync[0],ack_toggle};
            if(vs_rise)begin
                if(armed)begin
                    frame_seq<=frame_seq+1'b1;
                    if(request_toggle==ack_sync[1])begin
                        mailbox<={frame_seq+32'd1,line_count,active_bytes,
                                  (line_count==0?16'd0:final_min),final_max,overlap_count};
                        request_toggle<=~request_toggle;
                    end
                end
                armed<=1;line_open<=0;line_bytes<=0;line_count<=0;
                active_bytes<=0;line_min<=16'hffff;line_max<=0;
                // Boundary sample belongs to the new frame interval.
                overlap_count<=cam_href?32'd1:32'd0;
            end else if(armed)begin
                if(cam_vsync)begin
                    if(cam_href && overlap_count!=32'hffffffff)overlap_count<=overlap_count+1'b1;
                    // An active line cut off by VS is still included in min/max.
                    if(line_open)begin
                        if(line_bytes<line_min)line_min<=line_bytes;
                        if(line_bytes>line_max)line_max<=line_bytes;
                        line_open<=0;line_bytes<=0;
                    end
                end else if(cam_href)begin
                    if(active_bytes!=32'hffffffff)active_bytes<=active_bytes+1'b1;
                    if(!line_open)begin
                        line_open<=1;line_bytes<=1;
                        if(line_count!=16'hffff)line_count<=line_count+1'b1;
                    end else if(line_bytes!=16'hffff)line_bytes<=line_bytes+1'b1;
                end else if(line_open)begin
                    if(line_bytes<line_min)line_min<=line_bytes;
                    if(line_bytes>line_max)line_max<=line_bytes;
                    line_open<=0;line_bytes<=0;
                end
            end
        end
    end
    reg request_seen=0,copy_pending=0;
    always @(posedge sys_clk or negedge reset_n)begin
        if(!reset_n)begin
            request_sync<=0;request_seen<=0;copy_pending<=0;ack_toggle<=0;
            valid<=0;update<=0;frame_number<=0;lines<=0;total_bytes<=0;
            min_line_bytes<=0;max_line_bytes<=0;blank_href_samples<=0;
        end else begin
            request_sync<={request_sync[0],request_toggle};
            update<=0;
            if(copy_pending)begin
                {frame_number,lines,total_bytes,min_line_bytes,max_line_bytes,blank_href_samples}<=mailbox;
                valid<=1;update<=1;copy_pending<=0;ack_toggle<=request_seen;
            end else if(request_sync[1]!=request_seen)begin
                request_seen<=request_sync[1];copy_pending<=1;
            end
        end
    end
endmodule
