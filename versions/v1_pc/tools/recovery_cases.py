"""Prepare expected pin-level recovery responses; no board evidence is generated."""
from dataclasses import replace
import struct
from protocol import Config,crc16,make_request,output_geometry


def prepare():
    pixels=[0xA66A if i%13==0 else (i*721)&65535 for i in range(256)]
    cfg=Config(sequence=901,mode=3,width=16,height=16)
    good=make_request(pixels,cfg)
    def recalc(p):return p[:-2]+struct.pack('<H',crc16(p[2:-2]))
    bad_crc=good[:-1]+bytes([good[-1]^1])
    bad_mode=bytearray(good);bad_mode[5]=6;bad_mode=recalc(bytes(bad_mode))
    bad_length=good[2:17]+struct.pack('<I',510)+good[21:21+510]
    bad_length=b'\xa6\x6a'+bad_length+struct.pack('<H',crc16(bad_length))
    # Keep declared length consistent so dimension status 1 is isolated from length status 2.
    bad_dims=make_request([0]*(193*16),replace(cfg,width=193))
    scenarios=[]
    def add(name,packet,status,action=0,request=cfg,values=pixels):
        ow,oh,*_=output_geometry(request)
        length=0 if status is None else 23+(ow*oh if status==0 else 0)
        scenarios.append(dict(name=name,packet=packet,status=status,action=action,
                              cfg=request,pixels=values,response_bytes=length))
    add('payload_contains_magic',good,0)
    for name,packet,status in [('bad_crc',bad_crc,3),('bad_mode',bad_mode,1),
                               ('bad_length',bad_length,2),('oversize_width',bad_dims,1)]:
        add(name,packet,status);add('recover_'+name,good,0)
    add('bad_uart_stop_known_sequence',good[:5]+b'\x03',5,action=1)
    add('recover_bad_stop',good,0)
    add('interrupted_header_known_sequence',good[:5],4)
    add('recover_timeout',good,0)
    add('unknown_sequence_timeout_no_reply',good[:3],None)
    add('recover_unknown_sequence',good,0)
    add('reset_partial_payload_no_reply',good[:100],None,action=2)
    add('recover_reset',good,0)
    # Consecutive dimension/mode switches with no reset.
    for seq,(w,h,mode) in enumerate(((3,3,1),(17,19,4),(15,15,5)),start=910):
        c=Config(sequence=seq,mode=mode,width=w,height=h)
        v=[(i*1379)&65535 for i in range(w*h)]
        add('size_switch_'+str(seq),make_request(v,c),0,request=c,values=v)
    return scenarios
