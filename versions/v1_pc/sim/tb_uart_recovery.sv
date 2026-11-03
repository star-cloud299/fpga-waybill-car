`timescale 1ns/1ps
// File-driven pin-level UART fault injection. Accelerated UART, 50MHz clock.
module tb_uart_recovery;
 parameter integer DIV=8;
 reg clk=0,rst_n=0,rx=1;always #10 clk=~clk;
 wire tx,busy,packet_error;
 integer plan,bytes_file,out_file,nframes,total_expected,received=0,cycles=0;
 integer index,i,length,expected,action,word,target=0,rc;
 reg [7:0] observed;
 uart_official_v2_top #(.MAX_WIDTH(192),.MAX_HEIGHT(96),.CLKS_PER_BIT(DIV),
  .RX_TIMEOUT_CLKS(10000),.SILENCE_CLKS(1000)) dut(
  .clk(clk),.rst_n(rst_n),.uart_rxd(rx),.uart_txd(tx),.busy(busy),.packet_error(packet_error));
 task automatic send_byte(input [7:0] value,input bad_stop);
  integer b;
  begin
   @(negedge clk);rx=0;repeat(DIV) @(negedge clk);
   for(b=0;b<8;b=b+1) begin rx=value[b];repeat(DIV) @(negedge clk);end
   rx=bad_stop?0:1;repeat(DIV) @(negedge clk);
   rx=1;repeat(DIV) @(negedge clk);
  end
 endtask
 initial begin : receive_pin
  integer bit_no;
  forever begin
   @(negedge tx);#(DIV*10);
   if(tx!==0) $fatal(1,"TX_START");
   for(bit_no=0;bit_no<8;bit_no=bit_no+1) begin #(DIV*20);observed[bit_no]=tx;end
   #(DIV*20);if(tx!==1) $fatal(1,"TX_STOP");
   $fwrite(out_file,"%02x\n",observed);received=received+1;
   if(received>total_expected) $fatal(1,"EXTRA_RESPONSE");
  end
 end
 always @(posedge clk) begin
  cycles=cycles+1;if(cycles>12000000) $fatal(1,"RECOVERY_WATCHDOG received=%0d target=%0d case=%0d",received,target,index);
 end
 initial begin
  plan=$fopen("recovery_plan.txt","r");bytes_file=$fopen("recovery_requests.hex","r");
  out_file=$fopen("recovery_responses.hex","w");
  if(!plan || !bytes_file || !out_file) $fatal(1,"FILE_OPEN");
  rc=$fscanf(plan,"%d %d\n",nframes,total_expected);
  repeat(10) @(negedge clk);rst_n=1;repeat(30) @(negedge clk);
  for(index=0;index<nframes;index=index+1) begin
   rc=$fscanf(plan,"%d %d %d\n",length,expected,action);
   if(rc!=3) $fatal(1,"PLAN_UNDERRUN");
   for(i=0;i<length;i=i+1) begin
    rc=$fscanf(bytes_file,"%h\n",word);if(rc!=1) $fatal(1,"INPUT_UNDERRUN");
    send_byte(word[7:0],action==1 && i==length-1);
   end
   target=target+expected;
   if(action==2) begin
    @(negedge clk);rst_n=0;repeat(20) @(negedge clk);rst_n=1;
   end
   if(expected==0) begin
    repeat(24000) @(negedge clk);
    if(received!=target) $fatal(1,"UNEXPECTED_REPLY_WITHOUT_SEQUENCE_OR_AFTER_RESET");
   end else wait(received==target);
   repeat(100) @(negedge clk);
   if(busy) $fatal(1,"BUSY_AFTER_RECOVERY case=%0d",index);
  end
  $fclose(out_file);$display("UART_RECOVERY_PASS scenarios=%0d bytes=%0d",nframes,received);$finish;
 end
endmodule
