`timescale 1ns/1ps
module tb_uart_six_mode_top;
    localparam integer DIV=8;
    localparam integer REQUEST_LEN=529;
    localparam integer TOTAL_REQUEST=6*REQUEST_LEN;
    localparam integer TOTAL_RESPONSE=2*521+401+3*17;
    reg clk=0,rst_n=0,rx=1;
    always #10 clk=~clk;
    wire tx,busy,packet_error;
    reg [7:0] request_bytes[0:TOTAL_REQUEST-1];
    reg [7:0] expected_bytes[0:TOTAL_RESPONSE-1];
    integer received=0,errors=0,frame_no,i,target,cycles=0;
    reg [7:0] observed;
    uart_six_mode_top #(.WIDTH(16),.HEIGHT(16),
        .CLKS_PER_BIT(DIV),.RX_TIMEOUT_CLKS(10000)) dut(
        .clk(clk),.rst_n(rst_n),.uart_rxd(rx),.uart_txd(tx),
        .busy(busy),.packet_error(packet_error));

    task automatic send_byte(input [7:0] value);
        integer bit_no;
        begin
            @(negedge clk);rx=0;
            repeat(DIV) @(negedge clk);
            for(bit_no=0;bit_no<8;bit_no=bit_no+1) begin
                rx=value[bit_no];repeat(DIV) @(negedge clk);
            end
            rx=1;repeat(DIV) @(negedge clk);
        end
    endtask

    initial begin : independent_receiver
        integer bit_no;
        forever begin
            @(negedge tx);
            #(DIV*10);
            if(tx!==0) $fatal(1,"TX_BAD_START");
            for(bit_no=0;bit_no<8;bit_no=bit_no+1) begin
                #(DIV*20);observed[bit_no]=tx;
            end
            #(DIV*20);
            if(tx!==1) $fatal(1,"TX_BAD_STOP");
            if(received>=TOTAL_RESPONSE) $fatal(1,"TX_EXTRA_BYTE");
            if(observed!==expected_bytes[received])
                $fatal(1,"TX_MISMATCH index=%0d expected=%02h got=%02h",
                       received,expected_bytes[received],observed);
            received=received+1;
        end
    end

    always @(posedge clk) begin
        cycles=cycles+1;
        if(packet_error) errors=errors+1;
        if(cycles>3000000) $fatal(1,"WATCHDOG received=%0d",received);
    end

    initial begin
        $readmemh("integration_b_v1/evidence/uart_16/requests.hex",request_bytes);
        $readmemh("integration_b_v1/evidence/uart_16/expected.hex",expected_bytes);
        repeat(10) @(negedge clk);rst_n=1;
        repeat(50) @(negedge clk);
        target=0;
        for(frame_no=0;frame_no<6;frame_no=frame_no+1) begin
            for(i=0;i<REQUEST_LEN;i=i+1)
                send_byte(request_bytes[frame_no*REQUEST_LEN+i]);
            target=target+((frame_no<2)?521:((frame_no==2)?401:17));
            wait(received==target);
            repeat(60) @(negedge clk);
            if(busy) $fatal(1,"BOARD_BUSY_AFTER_REPLY mode=%0d",frame_no+1);
        end
        if(received!=TOTAL_RESPONSE || errors)
            $fatal(1,"FAIL received=%0d errors=%0d",received,errors);
        $display("UART_V2_PASS frames=6 reply_bytes=%0d errors=0 cycles=%0d",
                 received,cycles);
        $finish;
    end
endmodule
