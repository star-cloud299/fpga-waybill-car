`timescale 1ns/1ps
module tb_straight_route_controller;
    reg clk=0;always #10 clk=~clk;
    reg reset_n=0,key1_n=1,key2_n=1,video_ok=1,link_ok=1;
    reg enc1_a=0,enc2_a=0,scan_done=0;
    reg [2:0] scan_status=0;
    wire stby,ain1,ain2,pwma,bin1,bin2,pwmb,scan_request;
    wire [2:0] station_id,verdict;
    wire [3:0] phase,completed_mask,led_n;
    reg simulate_enc1=1,simulate_enc2=1;
    integer divider1=0,divider2=0,drives=0,scans=0;
    reg [3:0] previous_phase=0;
    localparam IDLE=0,SETTLE=1,SCAN=2,DRIVE=3,TURN=4,REVIEW=5,DONE=6,FAULT=7,PAUSE=8;
    straight_route_controller #(.STRAIGHT_PULSES(7),
        .PWM_PERIOD(8),.PWM_ON(3),.START_DEBOUNCE_CYCLES(3),
        .PAUSE_CYCLES(5),.RESULT_HOLD_CYCLES(4),.SETTLE_CYCLES(8),
        .STALL_CYCLES(80),.MAX_RUN_CYCLES(1000),.SCAN_TIMEOUT_CYCLES(25)) dut(
        .clk(clk),.reset_n(reset_n),.key1_n(key1_n),.key2_n(key2_n),
        .enc1_a(enc1_a),.enc1_b(1'b0),.enc2_a(enc2_a),.enc2_b(1'b0),
        .video_ok(video_ok),.link_ok(link_ok),.scan_done(scan_done),.scan_status(scan_status),
        .stby(stby),.ain1(ain1),.ain2(ain2),.pwma(pwma),.bin1(bin1),.bin2(bin2),.pwmb(pwmb),
        .scan_request(scan_request),.station_id(station_id),.phase(phase),.verdict(verdict),
        .completed_mask(completed_mask),.led_n(led_n));
    always @(negedge clk) begin
        if(!reset_n)begin enc1_a=0;enc2_a=0;divider1=0;divider2=0;end
        else begin
            if(simulate_enc1 && ain1)begin
                if(divider1==2)begin enc1_a=~enc1_a;divider1=0;end
                else divider1=divider1+1;
            end else begin enc1_a=0;divider1=0;end
            if(simulate_enc2 && bin1)begin
                if(divider2==3)begin enc2_a=~enc2_a;divider2=0;end
                else divider2=divider2+1;
            end else begin enc2_a=0;divider2=0;end
        end
    end
    // Independent invariants apply to every test, including all fault cases.
    always @(posedge clk)begin
        #1;
        if(!reset_n)begin
            drives=0;scans=0;previous_phase=IDLE;
        end
        else begin
            if(phase==TURN)$fatal(1,"straight route entered TURN");
            if(ain2 || bin2)$fatal(1,"straight route asserted reverse direction");
            if(phase!=DRIVE && stby)$fatal(1,"motors enabled outside forward DRIVE");
            if(scan_request && (stby || pwma || pwmb))$fatal(1,"scan requested while motors active");
            if(phase==DRIVE && previous_phase!=DRIVE)drives=drives+1;
            if(scan_request)scans=scans+1;
            if(station_id!=1 && station_id!=2)$fatal(1,"station outside A/B");
            previous_phase=phase;
        end
    end
    task automatic tick(input integer cycles);
        integer j;begin for(j=0;j<cycles;j=j+1)begin @(posedge clk);#2;end end
    endtask
    task automatic wait_phase(input integer wanted,input integer limit);
        integer n;begin
            n=0;while(phase!=wanted && n<limit)begin tick(1);n=n+1;end
            if(phase!=wanted)$fatal(1,"phase timeout wanted=%0d actual=%0d station=%0d",wanted,phase,station_id);
        end
    endtask
    task automatic reset_case(input bit held);
        begin
            @(negedge clk);reset_n=0;key1_n=!held;key2_n=1;video_ok=1;link_ok=1;
            scan_done=0;scan_status=0;simulate_enc1=1;simulate_enc2=1;
            tick(4);@(negedge clk);reset_n=1;tick(14);
        end
    endtask
    task automatic press_start;
        begin @(negedge clk);key1_n=1;tick(10);@(negedge clk);key1_n=0;tick(10);@(negedge clk);key1_n=1;end
    endtask
    task automatic answer(input [2:0] status);
        begin @(negedge clk);scan_status=status;scan_done=1;tick(1);@(negedge clk);scan_done=0;end
    endtask
    task automatic assert_off;
        begin if(stby || pwma || pwmb || ain1 || ain2 || bin1 || bin2)$fatal(1,"expected every motor output off");end
    endtask
    task automatic reach_first_scan;
        begin
            press_start();wait_phase(DRIVE,30);
            if(scans!=0 || drives!=1 || station_id!=1)$fatal(1,"S must drive first, not scan at start");
            wait_phase(SCAN,260);
            if(scans!=1 || drives!=1 || station_id!=1)$fatal(1,"A scan ordering incorrect");
            assert_off();
        end
    endtask
    initial begin
        // S -> 80cm-equivalent pulses -> A scan -> hold -> second leg -> B scan -> hold -> DONE.
        reset_case(0);reach_first_scan();answer(1);
        wait_phase(PAUSE,10);tick(2);
        if(phase!=PAUSE || verdict!=1 || completed_mask!=1)$fatal(1,"A MATCH display hold missing");
        assert_off();wait_phase(DRIVE,15);
        if(station_id!=2 || drives!=2 || scans!=1)$fatal(1,"second leg did not target B");
        wait_phase(SCAN,260);
        if(station_id!=2 || scans!=2 || drives!=2)$fatal(1,"B scan ordering incorrect");
        answer(1);wait_phase(PAUSE,10);tick(2);
        if(phase!=PAUSE || verdict!=1 || completed_mask!=3)$fatal(1,"B MATCH display hold missing");
        assert_off();wait_phase(DONE,15);tick(30);press_start();tick(40);
        if(phase!=DONE || drives!=2 || scans!=2 || completed_mask!=4'b0011 || station_id!=2)
            $fatal(1,"completion totals drives=%0d scans=%0d mask=%h station=%0d",drives,scans,completed_mask,station_id);
        assert_off();
        $display("CASE two_forward_legs_two_station_checks_no_turn_or_reverse PASS");
        $display("CASE both_MATCH_display_holds_and_final_DONE_stays_stopped PASS");

        reset_case(1);tick(40);
        if(phase!=IDLE || scans!=0 || drives!=0)$fatal(1,"held KEY1 started at powerup");
        assert_off();reach_first_scan();
        $display("CASE release_before_start PASS");

        // Holding KEY1 from before the failure cannot become a retry edge.
        @(negedge clk);key1_n=0;tick(10);answer(2);wait_phase(REVIEW,10);tick(40);
        if(scans!=1 || drives!=1 || station_id!=1 || completed_mask!=0)$fatal(1,"wrong-region advanced route");
        assert_off();press_start();wait_phase(SCAN,50);
        if(scans!=2 || drives!=1 || station_id!=1)$fatal(1,"retry must rescan A without moving");
        answer(1);wait_phase(DRIVE,20);
        if(station_id!=2)$fatal(1,"retry MATCH did not advance to B");
        $display("CASE wrong_region_stopped_fresh_KEY1_retry PASS");

        reset_case(0);reach_first_scan();answer(3);wait_phase(REVIEW,10);tick(40);
        if(drives!=1 || scans!=1 || verdict!=3)$fatal(1,"unknown cargo advanced route");
        assert_off();press_start();wait_phase(SCAN,50);
        if(station_id!=1 || drives!=1 || scans!=2)$fatal(1,"unknown cargo retry moved");
        $display("CASE unknown_cargo_stopped_retry PASS");

        reset_case(0);reach_first_scan();answer(4);wait_phase(REVIEW,10);tick(40);
        if(drives!=1 || scans!=1 || verdict!=4)$fatal(1,"duplicate cargo advanced route");
        assert_off();$display("CASE duplicate_cargo_stays_stopped PASS");

        reset_case(0);reach_first_scan();answer(5);
        wait_phase(SETTLE,10);wait_phase(SCAN,30);answer(5);wait_phase(REVIEW,10);tick(80);
        if(scans!=2 || drives!=1 || station_id!=1 || verdict!=5)$fatal(1,"unreadable retry bound wrong");
        assert_off();$display("CASE unreadable_one_automatic_retry_only PASS");

        reset_case(0);reach_first_scan();wait_phase(SETTLE,40);wait_phase(SCAN,30);wait_phase(REVIEW,40);tick(40);
        if(scans!=2 || drives!=1 || verdict!=6)$fatal(1,"scan timeout retry bound wrong");
        assert_off();$display("CASE scan_timeout_one_retry_only PASS");

        reset_case(0);press_start();wait_phase(DRIVE,30);
        @(negedge clk);key2_n=0;#1;assert_off();
        tick(6);wait_phase(FAULT,10);@(negedge clk);key2_n=1;tick(20);press_start();tick(25);
        if(phase!=FAULT)$fatal(1,"KEY2 release or KEY1 cleared fault");
        assert_off();$display("CASE KEY2_immediate_and_latched_until_RESET PASS");

        reset_case(0);simulate_enc1=0;simulate_enc2=0;press_start();wait_phase(DRIVE,30);wait_phase(FAULT,120);
        assert_off();$display("CASE no_encoder_stall_stop PASS");

        reset_case(0);simulate_enc2=0;press_start();wait_phase(DRIVE,30);wait_phase(FAULT,150);
        assert_off();$display("CASE single_wheel_stall_stop PASS");

        reset_case(0);press_start();wait_phase(DRIVE,30);
        @(negedge clk);link_ok=0;#1;assert_off();tick(3);wait_phase(FAULT,10);
        @(negedge clk);link_ok=1;tick(30);
        if(phase!=FAULT)$fatal(1,"link restoration restarted route");
        assert_off();$display("CASE link_loss_immediate_gate_and_fault_latch PASS");

        reset_case(0);press_start();wait_phase(DRIVE,30);
        @(negedge clk);video_ok=0;#1;assert_off();tick(3);wait_phase(FAULT,10);
        @(negedge clk);video_ok=1;tick(30);
        if(phase!=FAULT)$fatal(1,"video restoration restarted route");
        assert_off();$display("CASE video_loss_immediate_gate_and_fault_latch PASS");

        reset_case(0);reach_first_scan();@(negedge clk);link_ok=0;tick(3);answer(1);tick(20);
        if(phase!=FAULT || completed_mask!=0 || drives!=1)$fatal(1,"late result after link failure restarted route");
        assert_off();$display("CASE result_after_link_failure_ignored PASS");

        reset_case(0);@(negedge clk);link_ok=0;press_start();tick(30);
        if(phase!=IDLE || drives!=0 || scans!=0)$fatal(1,"started without link");
        @(negedge clk);link_ok=1;tick(30);
        if(phase!=IDLE)$fatal(1,"link readiness created start");
        @(negedge clk);video_ok=0;press_start();tick(30);
        if(phase!=IDLE || drives!=0)$fatal(1,"started without video");
        @(negedge clk);video_ok=1;tick(30);
        if(phase!=IDLE)$fatal(1,"video readiness created start");
        assert_off();$display("CASE readiness_start_inhibit PASS");

        $display("STRAIGHT_ROUTE_SIM_PASS");$finish;
    end
    initial begin #1000000;$fatal(1,"global timeout");end
endmodule
