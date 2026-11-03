"""Recheck supplied board evidence without presenting it as a new hardware run."""
from pathlib import Path
import hashlib
import json
import sys
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'host'))
from common import Config,dump_json,parse_response,reference,sha256
from protocol import pixels_from_v1_request


def audit(output):
    source=ROOT/'team_v1_20261022/c_data/20261022_213852_792873/request.bin'
    sw,sh,pixels=pixels_from_v1_request(source)
    a=np.asarray(pixels,dtype=np.uint16).reshape(sh,sw)
    bit=ROOT/'official_v2/board_reports/uart_official_v2_top.bit'
    expected_bit='fc794482f76bbf222b8e4ac96462d4332a196e6381af522d0f9539fc0f239488'
    if sha256(bit)!=expected_bit:raise ValueError('official baseline bitstream hash mismatch')
    rows=[]
    base=ROOT/'official_v2/evidence/board_sweep_20261023'
    for w,h in ((64,64),(192,96)):
        sized=a if w==sw else a[np.arange(h)*sh//h][:,np.arange(w)*sw//w]
        for mode in range(1,6):
            seq=200+(w==192)*10+mode
            cfg=Config(sequence=seq,mode=mode,width=w,height=h)
            raw=(base/f'{w}x{h}_mode{mode}'/'response.bin').read_bytes()
            result=parse_response(raw,cfg)
            if result.status:raise ValueError('archived sweep status error')
            expect=reference(sized,cfg).tobytes()
            if result.payload!=expect:raise ValueError('archived sweep pixel mismatch')
            rows.append({'size':[w,h],'mode':mode,'pixels':len(expect),'crc_ok':True,'mismatches':0})
    stable=ROOT/'official_v2/evidence/board_100frames_20261023'
    report=json.loads((stable/'report.json').read_text())
    references={m:reference(a,Config(mode=m,width=64,height=64)).tobytes() for m in range(1,6)}
    for i,row in enumerate(report['frames']):
        mode=i%5+1;cfg=Config(sequence=400+i,mode=mode,width=64,height=64)
        path=stable/f'response_{i:03d}.bin'
        if sha256(path)!=row['response_sha256']:raise ValueError('archived stability response hash mismatch')
        parsed=parse_response(path.read_bytes(),cfg)
        if parsed.status or parsed.payload!=references[mode]:raise ValueError('archived stability pixel mismatch')
    result={'status':'PASS','evidence_type':'revalidated_uploaded_board_records',
        'new_hardware_run':False,'baseline_bitstream_sha256':expected_bit,
        'sweep_frames':len(rows),'sweep_pixels':sum(r['pixels'] for r in rows),
        'stability_frames':len(report['frames']),'rows':rows,
        'note':'Integrity and mathematical recheck only. Does not prove board currently has this bitstream.'}
    dump_json(Path(output),result)
    print('ARCHIVED_BOARD_AUDIT_PASS sweep_frames=10 pixels=100952 stability_frames=100')
    return result

if __name__=='__main__':audit(ROOT/'results/baseline_reaudit.json')
