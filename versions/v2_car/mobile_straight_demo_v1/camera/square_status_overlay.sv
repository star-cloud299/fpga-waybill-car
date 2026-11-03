`timescale 1ns/1ps
// Original 5x7 ASCII status overlay, combinational: no extra RGB latency/RAM.
module square_status_overlay(
 input wire [9:0] x,y,input wire [23:0] base_rgb,
 input wire [2:0] station,target,verdict,input wire [3:0] phase,completed,
 input wire [47:0] text_bcd,input wire text_valid,frozen,
 output reg [23:0] rgb
);
 function automatic [34:0] glyph(input [7:0] c);
  begin case(c)
   8'd48:glyph=35'h3a33ae62e;
   8'd49:glyph=35'h11842108e;
   8'd50:glyph=35'h3a211111f;
   8'd51:glyph=35'h78217043e;
   8'd52:glyph=35'h08ca97c42;
   8'd53:glyph=35'h7e10f043e;
   8'd54:glyph=35'h3a10f462e;
   8'd55:glyph=35'h7c2222108;
   8'd56:glyph=35'h3a317462e;
   8'd57:glyph=35'h3a317842e;
   8'd65:glyph=35'h3a31fc631;
   8'd66:glyph=35'h7a31f463e;
   8'd67:glyph=35'h3e108420f;
   8'd68:glyph=35'h7a318c63e;
   8'd69:glyph=35'h7e10f421f;
   8'd70:glyph=35'h7e10f4210;
   8'd71:glyph=35'h3e10bc62f;
   8'd72:glyph=35'h4631fc631;
   8'd73:glyph=35'h38842108e;
   8'd74:glyph=35'h1c4214a4c;
   8'd75:glyph=35'h4654c5251;
   8'd76:glyph=35'h42108421f;
   8'd77:glyph=35'h4775ac631;
   8'd78:glyph=35'h47359c631;
   8'd79:glyph=35'h3a318c62e;
   8'd80:glyph=35'h7a31f4210;
   8'd81:glyph=35'h3a318d64d;
   8'd82:glyph=35'h7a31f5251;
   8'd83:glyph=35'h3e107043e;
   8'd84:glyph=35'h7c8421084;
   8'd85:glyph=35'h46318c62e;
   8'd86:glyph=35'h46318c544;
   8'd87:glyph=35'h4631ad6aa;
   8'd88:glyph=35'h462a22a31;
   8'd89:glyph=35'h462a21084;
   8'd90:glyph=35'h7c222221f;
   8'd58:glyph=35'h008401080;
   8'd45:glyph=35'h0000f8000;
   8'd47:glyph=35'h042222210;
   default:glyph=0;
  endcase end
 endfunction
 function automatic [7:0] phase_char(input integer c);
  reg [63:0] s;
  begin
   case(phase)
    0:s="IDLE    ";1:s="SETTLE  ";2:s="SCAN    ";3:s="DRIVE   ";
    4:s="TURN    ";5:s="REVIEW  ";6:s="DONE    ";7:s="FAULT   ";default:s="PAUSE   ";
   endcase
   phase_char=(c<8)?(s>>((7-c)*8)):8'h20;
  end
 endfunction
 function automatic [7:0] verdict_char(input integer c);
  reg [95:0] s;
  begin
   case(verdict)
    0:s="WAIT        ";1:s="MATCH       ";2:s="WRONG REGION";3:s="UNKNOWN     ";
    4:s="DUPLICATE   ";5:s="UNREADABLE  ";default:s="COMM ERROR  ";
   endcase
   verdict_char=(c<12)?(s>>((11-c)*8)):8'h20;
  end
 endfunction
 function automatic [7:0] text_char(input integer row,input integer c);
  begin
   text_char=" ";
   case(row)
    0:case(c)
     0:text_char="S";1:text_char="T";2:text_char="A";3:text_char="T";4:text_char="I";
     5:text_char="O";6:text_char="N";7:text_char=":";8:text_char=(station>=1 && station<=2)?8'd64+station:8'h2d;
     10:text_char="M";11:text_char="O";12:text_char="D";13:text_char="E";14:text_char=":";
     default:if(c>=15 && c<23)text_char=phase_char(c-15);
    endcase
    1:begin
     case(c)
      0:text_char="I";1:text_char="D";2:text_char=":";
      17:text_char="T";18:text_char="O";19:text_char=":";
      20:text_char=(target>=1 && target<=2)?8'd64+target:8'h2d;
      default:if(c>=3 && c<15)text_char=text_valid?(8'd48+((text_bcd>>((14-c)*4))&4'hf)):8'h2d;
     endcase
    end
    2:begin
     case(c)
      0:text_char="R";1:text_char="E";2:text_char="S";3:text_char="U";4:text_char="L";5:text_char="T";6:text_char=":";
      default:if(c>=7 && c<19)text_char=verdict_char(c-7);
     endcase
    end
    3:begin
     case(c)
      0:text_char="D";1:text_char="O";2:text_char="N";3:text_char="E";4:text_char=":";
      default:if(c>=5 && c<7)text_char=completed[c-5]?(8'd65+c-5):8'h2d;
     endcase
    end
    4:begin
     case(c)
      0:text_char="O";1:text_char="R";2:text_char="I";3:text_char="G";4:text_char="I";5:text_char="N";6:text_char="A";7:text_char="L";
      22:text_char="B";23:text_char="I";24:text_char="N";25:text_char="A";26:text_char="R";27:text_char="Y";
     endcase
    end
   endcase
  end
 endfunction
 integer row,c,gx,gy,origin_x,origin_y;
 reg draw_row;
 reg [34:0] bits;
 reg [23:0] ink;
 always_comb begin
  rgb=base_rgb;draw_row=0;row=0;origin_x=16;origin_y=8;
  ink=(verdict==1)?24'h40ff60:((verdict==0)?24'hffe040:24'hff5050);
  if(y<56 || y>=432)rgb=24'h102030;
  if(y>=8 && y<24)begin draw_row=1;row=0;origin_y=8;end
  else if(y>=32 && y<48)begin draw_row=1;row=1;origin_y=32;end
  else if(y>=436 && y<452)begin draw_row=1;row=2;origin_y=436;end
  else if(y>=460 && y<476)begin draw_row=1;row=3;origin_y=460;end
  else if(frozen && y>=116 && y<132)begin draw_row=1;row=4;origin_y=116;origin_x=64;end
  c=(x-origin_x)/12;gx=((x-origin_x)%12)/2;gy=(y-origin_y)/2;
  bits=glyph(text_char(row,c));
  if(draw_row && x>=origin_x && c>=0 && c<40 && gx<5 && gy<7)
   if(bits[34-gy*5-gx])rgb=(row==2)?ink:24'hffffff;
 end
endmodule
