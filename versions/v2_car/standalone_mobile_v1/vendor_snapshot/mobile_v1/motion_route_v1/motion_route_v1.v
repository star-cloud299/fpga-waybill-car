`timescale 1ns/1ps
// Two straight legs. Count one rising edge of each wheel's encoder A per pulse.
// Encoder B is wired to J9 for a later direction-aware revision, but not used here.
module motion_route_v1 #(
    parameter integer PWM_PERIOD = 2500,
    parameter integer PWM_ON = 625,
    parameter integer LEG_PULSES = 728,
    parameter integer STALL_CYCLES = 25000000,
    parameter integer MAX_RUN_CYCLES = 500000000,
    parameter integer START_DEBOUNCE_CYCLES = 250000,
    parameter integer MOTOR1_REVERSE = 0,
    parameter integer MOTOR2_REVERSE = 0
)(
    input wire clk,
    input wire reset_n,
    input wire key1_n,
    input wire key2_n,
    input wire enc1_a,
    input wire enc1_b,
    input wire enc2_a,
    input wire enc2_b,
    output wire stby,
    output wire ain1,
    output wire ain2,
    output wire pwma,
    output wire bin1,
    output wire bin2,
    output wire pwmb,
    output wire [3:0] led_n
);
    localparam [2:0] WAIT_1=0, RUN_1=1, WAIT_2=2, RUN_2=3, DONE=4, FAULT=5;
    localparam integer PWM_W = (PWM_PERIOD > 1) ? $clog2(PWM_PERIOD) : 1;
    localparam integer DB_W = (START_DEBOUNCE_CYCLES > 1) ?
                              $clog2(START_DEBOUNCE_CYCLES) : 1;
    reg [2:0] state = WAIT_1;
    (* ASYNC_REG = "TRUE" *) reg [1:0] start_sync = 2'b00;
    (* ASYNC_REG = "TRUE" *) reg [1:0] stop_sync = 2'b11;
    // Start in the pressed state, requiring a release before the first start.
    reg start_stable_n = 1'b0, start_prev_n = 1'b0;
    reg [DB_W-1:0] start_db_count = 0;
    (* ASYNC_REG = "TRUE" *) reg [1:0] e1a_sync = 0;
    (* ASYNC_REG = "TRUE" *) reg [1:0] e2a_sync = 0;
    reg e1a_prev = 0, e2a_prev = 0;
    reg [31:0] count1 = 0, count2 = 0;
    reg [31:0] stall1 = 0, stall2 = 0, run_time = 0;
    reg [PWM_W-1:0] pwm_count = 0;

    wire running = (state == RUN_1 || state == RUN_2);
    // Raw KEY2 gates outputs immediately; the synchronized copy latches FAULT.
    wire enabled = reset_n && key2_n && stop_sync[1];
    wire pulse1 = e1a_sync[1] && !e1a_prev;
    wire pulse2 = e2a_sync[1] && !e2a_prev;
    wire motor1_on = enabled && running && count1 < LEG_PULSES;
    wire motor2_on = enabled && running && count2 < LEG_PULSES;
    wire reached1 = count1 >= LEG_PULSES ||
                    (motor1_on && pulse1 && count1 == LEG_PULSES-1);
    wire reached2 = count2 >= LEG_PULSES ||
                    (motor2_on && pulse2 && count2 == LEG_PULSES-1);
    wire start_edge = start_prev_n && !start_stable_n;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state <= WAIT_1;
            start_sync <= 2'b00;
            stop_sync <= 2'b11;
            start_stable_n <= 1'b0;
            start_prev_n <= 1'b0;
            start_db_count <= 0;
            e1a_sync <= 0; e2a_sync <= 0;
            e1a_prev <= 0; e2a_prev <= 0;
            count1 <= 0; count2 <= 0;
            stall1 <= 0; stall2 <= 0; run_time <= 0;
            pwm_count <= 0;
        end else begin
            start_sync <= {start_sync[0], key1_n};
            stop_sync <= {stop_sync[0], key2_n};
            e1a_sync <= {e1a_sync[0], enc1_a};
            e2a_sync <= {e2a_sync[0], enc2_a};
            e1a_prev <= e1a_sync[1];
            e2a_prev <= e2a_sync[1];
            start_prev_n <= start_stable_n;

            if (start_sync[1] == start_stable_n) start_db_count <= 0;
            else if (start_db_count == START_DEBOUNCE_CYCLES-1) begin
                start_stable_n <= start_sync[1];
                start_db_count <= 0;
            end else start_db_count <= start_db_count + 1'b1;

            if (!running || pwm_count == PWM_PERIOD-1) pwm_count <= 0;
            else pwm_count <= pwm_count + 1'b1;

            if (!stop_sync[1]) state <= FAULT;
            else case (state)
                WAIT_1, WAIT_2: begin
                    if (start_edge) begin
                        count1 <= 0; count2 <= 0;
                        stall1 <= 0; stall2 <= 0; run_time <= 0;
                        state <= state == WAIT_1 ? RUN_1 : RUN_2;
                    end
                end
                RUN_1, RUN_2: begin
                    if (motor1_on && pulse1) count1 <= count1 + 1'b1;
                    if (motor2_on && pulse2) count2 <= count2 + 1'b1;
                    if (motor1_on) stall1 <= pulse1 ? 0 : stall1 + 1'b1;
                    if (motor2_on) stall2 <= pulse2 ? 0 : stall2 + 1'b1;
                    run_time <= run_time + 1'b1;
                    // Reaching the last pulse wins a simultaneous timeout.
                    if (reached1 && reached2)
                        state <= state == RUN_1 ? WAIT_2 : DONE;
                    else if ((motor1_on && !pulse1 &&
                              stall1 >= STALL_CYCLES-1) ||
                             (motor2_on && !pulse2 &&
                              stall2 >= STALL_CYCLES-1) ||
                             run_time >= MAX_RUN_CYCLES-1)
                        state <= FAULT;
                end
                default: begin end
            endcase
        end
    end

    assign stby = motor1_on || motor2_on;
    assign ain1 = motor1_on && !MOTOR1_REVERSE;
    assign ain2 = motor1_on && MOTOR1_REVERSE;
    assign pwma = motor1_on && pwm_count < PWM_ON;
    assign bin1 = motor2_on && !MOTOR2_REVERSE;
    assign bin2 = motor2_on && MOTOR2_REVERSE;
    assign pwmb = motor2_on && pwm_count < PWM_ON;
    // Active-low board LEDs: waiting for leg 1, station 1, final station, fault.
    assign led_n = ~{state == FAULT, state == DONE, state == WAIT_2, state == WAIT_1};
endmodule
