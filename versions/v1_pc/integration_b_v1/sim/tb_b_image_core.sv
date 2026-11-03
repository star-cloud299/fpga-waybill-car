`timescale 1ns/1ps
module tb_b_image_core;
 reg clk=0; always #10 clk=~clk;
 reg rst=1,frame_start=0,s_valid=0,m_ready=0;
 wire frame_ready,cfg_error,busy,done,s_ready,m_valid,m_uncertain,m_last;
 reg [8:0] cfg_width,cfg_height;
 reg [2:0] cfg_mode;
 reg [7:0] cfg_threshold,cfg_bias,cfg_t1,cfg_t2,cfg_cflat,cfg_cmid,cfg_cedge,cfg_delta;
 reg [15:0] s_rgb565;
 wire [7:0] m_data,m_margin,m_mean,m_range;
 wire [8:0] out_width,out_height,m_x,m_y;
 wire [31:0] uncertain_count,process_cycles;
 b_image_core dut(.*);
 integer fc,fi,fe,fa,rc,nframes,f,p,n,failures=0,checked=0,cycles=0;
 integer ww,hh,mm,th,bb,t1,t2,cf,cm,ce,dd,word;
 integer ed,eu,em,emean,er,ex,ey,el,frame_uncertain=0;
 reg [31:0] rng=32'hcafe1234;
 reg [51:0] held;
 reg stalled=0,monitor=0;
 wire [51:0] payload={m_data,m_uncertain,m_margin,m_mean,m_range,m_x,m_y,m_last};
 string dir,vcd;
 always @(negedge clk) begin
  rng = {rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
  m_ready = (rng[3:0] > 4);
 end
 always @(posedge clk) begin
  cycles=cycles+1;
  if(cycles>20000000) $fatal(1,"WATCHDOG");
  if(rst) stalled=0;
  else if(monitor) begin
   if(stalled && (!m_valid || payload !== held)) $fatal(1,"OUTPUT_CHANGED_WHILE_STALLED");
   stalled=m_valid && !m_ready;
   held=payload;
   if(m_valid && m_ready) begin
    rc=$fscanf(fe,"%d %d %d %d %d %d %d %d\n",ed,eu,em,emean,er,ex,ey,el);
    if(rc!=8) $fatal(1,"EXPECTED_FILE_UNDERRUN");
    if(m_data!==ed[7:0] || m_uncertain!==eu[0] || m_margin!==em[7:0] ||
       m_mean!==emean[7:0] || m_range!==er[7:0] || m_x!==ex[8:0] ||
       m_y!==ey[8:0] || m_last!==el[0]) begin
     failures=failures+1;
     if(failures<8) $display("MISMATCH pixel=%0d xy=%0d,%0d got=%0d,%0d,%0d,%0d,%0d expected=%0d,%0d,%0d,%0d,%0d",checked,m_x,m_y,m_data,m_uncertain,m_margin,m_mean,m_range,ed,eu,em,emean,er);
    end
    frame_uncertain=frame_uncertain+m_uncertain;
    checked=checked+1;
    if(m_last) begin
     if(uncertain_count!==frame_uncertain) $fatal(1,"UNCERTAIN_COUNT");
     frame_uncertain=0;
    end
   end
  end
 end
 task launch;
 begin
  @(negedge clk);frame_start=1;
  @(posedge clk); #1;
  @(negedge clk);frame_start=0;
 end
 endtask
 initial begin
  if(!$value$plusargs("DIR=%s",dir)) dir="evidence/run";
  if($value$plusargs("VCD=%s",vcd)) begin $dumpfile(vcd);$dumpvars(0,tb_b_image_core);end
  fc=$fopen({dir,"/config.txt"},"r");fi=$fopen({dir,"/input.txt"},"r");
  fe=$fopen({dir,"/expected.txt"},"r");fa=$fopen({dir,"/actual_summary.txt"},"w");
  if(!fc || !fi || !fe || !fa) $fatal(1,"FILE_OPEN");
  rc=$fscanf(fc,"%d\n",nframes);
  cfg_width=15;cfg_height=15;cfg_mode=0;
  cfg_threshold=128;cfg_bias=12;cfg_t1=24;cfg_t2=80;
  cfg_cflat=18;cfg_cmid=12;cfg_cedge=6;cfg_delta=8;
  repeat(4) @(negedge clk);rst=0;
  // Reject mode zero, too-small window, oversized width and invalid thresholds.
  launch(); if(!cfg_error || !frame_ready || busy) $fatal(1,"BAD_MODE_ACCEPTED");
  cfg_mode=4;cfg_width=14;launch();if(!cfg_error || busy) $fatal(1,"BAD_SIZE_ACCEPTED");
  cfg_width=257;launch();if(!cfg_error || busy) $fatal(1,"BAD_WIDTH_ACCEPTED");
  cfg_width=15;cfg_mode=5;cfg_t1=80;cfg_t2=80;
  launch();if(!cfg_error || busy) $fatal(1,"BAD_T1_T2_ACCEPTED");
  // Abort a partially received frame; next frame must not inherit cached rows.
  cfg_mode=4;cfg_t1=24;cfg_t2=80;launch();
  for(p=0;p<17;p=p+1) begin
   @(negedge clk);s_valid=1;s_rgb565=16'hffff;
   @(posedge clk);while(!s_ready) @(posedge clk);
   @(negedge clk);s_valid=0;
  end
  rst=1;repeat(2) @(negedge clk);rst=0;monitor=1;
  for(f=0;f<nframes;f=f+1) begin
   rc=$fscanf(fc,"%d %d %d %d %d %d %d %d %d %d %d\n",ww,hh,mm,th,bb,t1,t2,cf,cm,ce,dd);
   if(rc!=11) $fatal(1,"CONFIG_UNDERRUN");
   cfg_width=ww;cfg_height=hh;cfg_mode=mm;cfg_threshold=th;cfg_bias=bb;
   cfg_t1=t1;cfg_t2=t2;cfg_cflat=cf;cfg_cmid=cm;cfg_cedge=ce;cfg_delta=dd;
   launch();if(!busy) $fatal(1,"VALID_CONFIG_REJECTED");
   if(out_width !== ww-((mm<=2)?0:((mm==3)?2:14)) ||
      out_height !== hh-((mm<=2)?0:((mm==3)?2:14))) $fatal(1,"OUTPUT_DIMENSIONS");
   // The frame configuration must remain latched despite later bus changes.
   cfg_width=1;cfg_height=1;cfg_mode=0;cfg_threshold=0;cfg_bias=255;
   cfg_t1=255;cfg_t2=0;cfg_cflat=255;cfg_cmid=255;cfg_cedge=255;cfg_delta=0;
   @(negedge clk);frame_start=1;
   @(posedge clk);#1;if(cfg_error || !busy) $fatal(1,"BUSY_START_NOT_IGNORED");
   @(negedge clk);frame_start=0;
   for(p=0;p<ww*hh;p=p+1) begin
    rc=$fscanf(fi,"%h\n",word);if(rc!=1) $fatal(1,"INPUT_UNDERRUN");
    @(negedge clk);s_valid=0;
    while(rng[7:6]==0) @(negedge clk);
    s_valid=1;s_rgb565=word;
    @(posedge clk);while(!s_ready) @(posedge clk);
    @(negedge clk);s_valid=0;
   end
   wait(done);@(negedge clk);
   $fdisplay(fa,"frame=%0d mode=%0d input=%0dx%0d cycles=%0d uncertain=%0d",f,mm,ww,hh,process_cycles,uncertain_count);
  end
  rc=$fscanf(fe,"%d",word);if(rc==1) $fatal(1,"OUTPUTS_MISSING");
  if(failures) $fatal(1,"FAIL mismatches=%0d checked=%0d",failures,checked);
  $display("PASS frames=%0d checked=%0d mismatches=0 cycles=%0d",nframes,checked,cycles);
  $fclose(fc);$fclose(fi);$fclose(fe);$fclose(fa);$finish;
 end
endmodule
