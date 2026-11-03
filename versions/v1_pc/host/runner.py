"""One-frame evidence recording; offline and measured files are kept distinct."""
from __future__ import annotations
from dataclasses import asdict
from pathlib import Path
import shutil
import struct
import time
import numpy as np
from PIL import Image
from common import (DEFAULTS, Config, common_crop, decode, dump_json, make_request,
                    metrics, parse_response, reference, sha256, versions, DECODER_OPTIONS)


class BoardSession:
    def __init__(self,port):self.port=port;self.link=None;self.partial=b''
    def __enter__(self):
        import serial
        self.link=serial.Serial(self.port,115200,bytesize=8,parity='N',stopbits=1,
                               timeout=.1,write_timeout=5,xonxoff=False,rtscts=False,dsrdtr=False)
        self.link.reset_input_buffer()
        return self
    def __exit__(self,*exc):
        if self.link:self.link.close()
    def exchange(self,request,cfg):
        if not self.link:raise RuntimeError('serial connection is closed')
        self.partial=b''
        if self.link.write(request)!=len(request):raise RuntimeError('short UART write')
        self.link.flush()
        deadline=time.monotonic()+30
        def read_to(size):
            while len(self.partial)<size:
                if time.monotonic()>=deadline:raise TimeoutError(f'received {len(self.partial)}/{size} response bytes')
                self.partial+=self.link.read(size-len(self.partial))
        read_to(21)
        if self.partial[:2]!=b'\x6a\xa6':raise ValueError('official V2 response magic mismatch; verify programmed bitstream')
        length=struct.unpack_from('<I',self.partial,13)[0]
        if length>32768:raise ValueError('response payload exceeds protocol limit')
        read_to(23+length)
        return self.partial


def run_one(pixels,cfg,folder,expected='',session=None,truth=None,source=None,roi=None):
    folder=Path(folder)
    folder.mkdir(parents=True,exist_ok=False)
    row={'mode':cfg.mode,'expected_text':str(expected),'evidence_type':'pc_reference_only',
         'mismatch_count':None,'processing_cycles':None,'round_trip_s':None,
         'decode_status':None,'exact_match':None,'error':None}
    config=asdict(cfg)
    dump_json(folder/'config.json',config)
    try:
        if source:Image.open(source).convert('RGB').save(folder/'input.png')
        if roi:shutil.copy2(roi,folder/'roi.png')
        a=np.asarray(pixels,dtype=np.uint16).reshape(cfg.height,cfg.width)
        (folder/'rgb565.bin').write_bytes(a.astype('>u2').tobytes())
        request=make_request(a.reshape(-1).tolist(),cfg)
        (folder/'request.bin').write_bytes(request)
        ref=reference(a,cfg)
        Image.fromarray(ref).save(folder/'reference.png')
        ref_common=common_crop(ref,cfg.mode)
        Image.fromarray(ref_common).save(folder/'reference_common.png')
        evaluated=ref_common
        if session:
            row['evidence_type']='board_current_run'
            started=time.monotonic()
            try:raw=session.exchange(request,cfg)
            finally:
                # Even CRC, short-frame and timeout evidence retains received bytes.
                (folder/'response.bin').write_bytes(session.partial)
                row['round_trip_s']=time.monotonic()-started
            actual=parse_response(raw,cfg)
            row.update(status=actual.status,processing_cycles=actual.processing_cycles,crc_ok=True)
            if actual.status:raise RuntimeError(f'FPGA status={actual.status}')
            native=np.frombuffer(actual.payload,dtype=np.uint8).reshape(actual.height,actual.width)
            mismatches=int(np.count_nonzero(native!=ref))
            row['mismatch_count']=mismatches
            Image.fromarray(native).save(folder/'fpga_result.png')
            Image.fromarray(np.where(native!=ref,255,0).astype(np.uint8)).save(folder/'diff.png')
            evaluated=common_crop(native,cfg.mode)
            Image.fromarray(evaluated).save(folder/'fpga_common.png')
            if mismatches:raise RuntimeError(f'{mismatches} FPGA/reference pixel mismatches')
        if expected:row.update(decode(evaluated,str(expected)))
        else:
            # Decode without treating an unspecified expected string as a label.
            found=decode(evaluated,'')['decoded_texts']
            row.update(decoded_texts=found,decode_status='unlabeled',exact_match=None)
        if truth is not None and cfg.mode!=1:
            row.update(metrics(evaluated,np.asarray(truth)[7:-7,7:-7]))
        row['request_sha256']=sha256(folder/'request.bin')
        if session:row['response_sha256']=sha256(folder/'response.bin')
    except Exception as exc:
        row['error']=f'{type(exc).__name__}: {exc}'
        if session:row['evidence_type']='board_attempt_failed'
    finally:
        row.update(config=config,decoder=DECODER_OPTIONS,versions=versions(),
                   note='PC reference has no board mismatch/time values; no synthetic board response is generated')
        dump_json(folder/'report.json',row)
    return row
