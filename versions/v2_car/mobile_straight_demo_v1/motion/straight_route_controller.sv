`timescale 1ns/1ps
// S -> A -> B: two forward 80cm legs, check A and B, then stop.
// Position is a route step, never inferred from the barcode response.
module straight_route_controller #(
    parameter integer STRAIGHT_PULSES = 1426,
    parameter integer TURN_PULSES = 217,
    parameter integer PWM_PERIOD = 2500,
    parameter integer PWM_ON = 625,
    parameter integer START_DEBOUNCE_CYCLES = 250000,
    parameter integer PAUSE_CYCLES = 7500000,
    parameter integer RESULT_HOLD_CYCLES = 100000000,
    parameter integer SETTLE_CYCLES = 50000000,
    parameter integer STALL_CYCLES = 25000000,
    parameter integer MAX_RUN_CYCLES = 500000000,
    parameter integer SCAN_TIMEOUT_CYCLES = 2000000000
)(
    input wire clk, reset_n, key1_n, key2_n,
    input wire enc1_a, enc1_b, enc2_a, enc2_b,
    input wire video_ok, link_ok,
    input wire scan_done,
    input wire [2:0] scan_status,
    output wire stby, ain1, ain2, pwma, bin1, bin2, pwmb,
    output reg scan_request,
    output reg [2:0] station_id,
    output reg [3:0] phase,
    output reg [2:0] verdict,
    output reg [3:0] completed_mask,
    output wire [3:0] led_n
);
    localparam [3:0] IDLE=0, SETTLE=1, SCAN=2, DRIVE=3, TURN=4,
                     REVIEW=5, DONE=6, FAULT=7, PAUSE=8;
    localparam [2:0] WAIT_RESULT=0, MATCH=1, WRONG_REGION=2, UNKNOWN=3,
                     DUPLICATE=4, UNREADABLE=5, COMM_ERROR=6;
    localparam [1:0] NEXT_TURN=0, NEXT_SETTLE=1, NEXT_DONE=2, NEXT_DRIVE=3;
    localparam integer PWM_W=(PWM_PERIOD>1)?$clog2(PWM_PERIOD):1;
    localparam integer DB_W=(START_DEBOUNCE_CYCLES>1)?$clog2(START_DEBOUNCE_CYCLES):1;

    (* ASYNC_REG="TRUE" *) reg [1:0] start_sync,stop_sync,e1_sync,e2_sync;
    reg start_stable_n,start_previous_n,e1_previous,e2_previous;
    reg [DB_W-1:0] debounce_count;
    reg [PWM_W-1:0] pwm_count;
    reg [31:0] count1,count2,stall1,stall2,run_time,wait_count;
    reg retry_used,review_released;
    reg [1:0] pause_next;

    wire running=(phase==DRIVE);
    wire active_cycle=(phase!=IDLE && phase!=DONE && phase!=FAULT);
    wire enabled=reset_n && key2_n && stop_sync[1] && video_ok && link_ok;
    wire [31:0] target=STRAIGHT_PULSES;
    wire pulse1=e1_sync[1] && !e1_previous;
    wire pulse2=e2_sync[1] && !e2_previous;
    wire motor1_on=enabled && running && count1<target;
    wire motor2_on=enabled && running && count2<target;
    wire reached1=(count1>=target) || (motor1_on && pulse1 && count1==target-1);
    wire reached2=(count2>=target) || (motor2_on && pulse2 && count2==target-1);
    wire start_edge=start_previous_n && !start_stable_n;
    wire [31:0] pause_target=(pause_next==NEXT_DRIVE || pause_next==NEXT_DONE)?RESULT_HOLD_CYCLES:PAUSE_CYCLES;

    // Raw KEY2 and reset gate the outputs without waiting for a clock. The
    // synchronized copy independently latches FAULT, so release cannot restart.
    assign stby=motor1_on || motor2_on;
    assign ain1=motor1_on;
    assign ain2=1'b0;
    assign pwma=motor1_on && pwm_count<PWM_ON;
    assign bin1=motor2_on;
    assign bin2=1'b0;
    assign pwmb=motor2_on && pwm_count<PWM_ON;
    assign led_n=~{phase==FAULT,phase==DONE,
                   (phase==SETTLE || phase==SCAN || phase==REVIEW),phase==IDLE};

    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            start_sync<=0; stop_sync<=2'b11; e1_sync<=0; e2_sync<=0;
            start_stable_n<=0; start_previous_n<=0; debounce_count<=0;
            e1_previous<=0; e2_previous<=0; pwm_count<=0;
            count1<=0;count2<=0;stall1<=0;stall2<=0;run_time<=0;wait_count<=0;
            phase<=IDLE;station_id<=1;verdict<=WAIT_RESULT;completed_mask<=0;
            scan_request<=0;retry_used<=0;review_released<=0;pause_next<=NEXT_TURN;
        end else begin
            scan_request<=0;
            start_sync<={start_sync[0],key1_n};
            stop_sync<={stop_sync[0],key2_n};
            e1_sync<={e1_sync[0],enc1_a};
            e2_sync<={e2_sync[0],enc2_a};
            e1_previous<=e1_sync[1];e2_previous<=e2_sync[1];
            start_previous_n<=start_stable_n;
            if(start_sync[1]==start_stable_n) debounce_count<=0;
            else if(debounce_count==START_DEBOUNCE_CYCLES-1) begin
                start_stable_n<=start_sync[1];debounce_count<=0;
            end else debounce_count<=debounce_count+1'b1;
            if(!running || pwm_count==PWM_PERIOD-1) pwm_count<=0;
            else pwm_count<=pwm_count+1'b1;

            if(!stop_sync[1]) begin phase<=FAULT;verdict<=WAIT_RESULT;end
            else if(active_cycle && (!video_ok || !link_ok)) begin
                phase<=FAULT;verdict<=COMM_ERROR;
            end else case(phase)
                IDLE: if(start_edge && video_ok && link_ok) begin
                    phase<=DRIVE;wait_count<=0;verdict<=WAIT_RESULT;
                    count1<=0;count2<=0;stall1<=0;stall2<=0;run_time<=0;
                    retry_used<=0;review_released<=0;
                end
                SETTLE: if(wait_count>=SETTLE_CYCLES-1) begin
                    phase<=SCAN;wait_count<=0;scan_request<=1;
                end else wait_count<=wait_count+1'b1;
                SCAN: begin
                    if(scan_done) begin
                        wait_count<=0;
                        if(scan_status==MATCH) begin
                            verdict<=MATCH;
                            completed_mask<=completed_mask | (4'b0001 << (station_id-1));
                            phase<=PAUSE;pause_next<=(station_id==2)?NEXT_DONE:NEXT_DRIVE;count1<=0;count2<=0;
                            stall1<=0;stall2<=0;run_time<=0;
                        end else if(scan_status==WRONG_REGION || scan_status==UNKNOWN ||
                                    scan_status==DUPLICATE) begin
                            verdict<=scan_status;phase<=REVIEW;review_released<=0;
                        end else if(!retry_used) begin
                            verdict<=(scan_status==COMM_ERROR)?COMM_ERROR:UNREADABLE;
                            retry_used<=1;phase<=SETTLE;
                        end else begin
                            verdict<=(scan_status==COMM_ERROR)?COMM_ERROR:UNREADABLE;
                            phase<=REVIEW;review_released<=0;
                        end
                    end else if(wait_count>=SCAN_TIMEOUT_CYCLES-1) begin
                        verdict<=COMM_ERROR;wait_count<=0;
                        if(!retry_used) begin retry_used<=1;phase<=SETTLE;end
                        else begin phase<=REVIEW;review_released<=0;end
                    end else wait_count<=wait_count+1'b1;
                end
                DRIVE: begin
                    if(motor1_on && pulse1) count1<=count1+1'b1;
                    if(motor2_on && pulse2) count2<=count2+1'b1;
                    if(motor1_on) stall1<=pulse1?0:stall1+1'b1;
                    if(motor2_on) stall2<=pulse2?0:stall2+1'b1;
                    run_time<=run_time+1'b1;
                    // Completion wins a simultaneous per-segment timeout.
                    if(reached1 && reached2) begin
                        phase<=PAUSE;wait_count<=0;
                        pause_next<=NEXT_SETTLE;
                    end else if((motor1_on && !pulse1 && stall1>=STALL_CYCLES-1) ||
                                (motor2_on && !pulse2 && stall2>=STALL_CYCLES-1) ||
                                run_time>=MAX_RUN_CYCLES-1) begin
                        phase<=FAULT;verdict<=WAIT_RESULT;
                    end
                end
                PAUSE: if(wait_count>=pause_target-1) begin
                    wait_count<=0;
                    case(pause_next)
                        NEXT_SETTLE: begin
                            phase<=SETTLE;verdict<=WAIT_RESULT;retry_used<=0;
                        end
                        NEXT_DRIVE: begin
                            station_id<=2;
                            phase<=DRIVE;verdict<=WAIT_RESULT;count1<=0;count2<=0;
                            stall1<=0;stall2<=0;run_time<=0;
                        end
                        default: phase<=DONE;
                    endcase
                end else wait_count<=wait_count+1'b1;
                REVIEW: begin
                    // A held button from before the error is not a retry.
                    if(start_stable_n && start_sync[1]) review_released<=1;
                    if(review_released && start_edge) begin
                        phase<=SETTLE;wait_count<=0;verdict<=WAIT_RESULT;
                        retry_used<=0;review_released<=0;
                    end
                end
                DONE,FAULT: begin end
                default: begin phase<=FAULT;verdict<=WAIT_RESULT;end
            endcase
        end
    end
    // enc1_b/enc2_b remain connected, as in the accepted A-rising motion core.
endmodule
