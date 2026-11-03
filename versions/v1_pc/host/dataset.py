"""Deterministic 30-sample synthetic dataset. Generation never reads tuning results."""
from __future__ import annotations
import argparse
import csv
from collections import Counter
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw
import barcode
from common import ROOT, common_crop, decode, dump_json, prepare_roi, rgb565, sha256, versions, DECODER_OPTIONS

SCENES=[('normal',5),('shadow',6),('lowlight',5),('glare',5),('gradient',5),('noise',4)]


def clean_roi(text):
    bits=barcode.Code128(text).build()[0]
    # 12-module quiet zone on each side, separate from the 7px algorithm guard.
    arr=np.full((82,178),255,np.uint8)
    left=(178-len(bits))//2
    if left<12:raise ValueError('barcode too wide for preserved quiet zones')
    for x,v in enumerate(bits):
        if v=='1':arr[12:70,x+left]=0
    return Image.fromarray(arr).convert('RGB').resize((712,328),Image.Resampling.NEAREST)


def degrade(a,scene,seed):
    rng=np.random.default_rng(seed);a=np.asarray(a).astype(np.float32)
    h,w=a.shape[:2];yy,xx=np.mgrid[:h,:w];u=xx/max(1,w-1);v=yy/max(1,h-1)
    params={'scene':scene,'seed':seed,'domain':'original ROI before letterbox'}
    if scene=='normal':
        a=a*.94+6+rng.normal(0,1,a.shape);params.update(gain=.94,offset=6,noise_sigma=1)
    elif scene=='shadow':
        mask=np.exp(-((u-.52)/.22)**8)
        gain=1-.76*mask
        a=a*gain[:,:,None]+9;params.update(shadow_depth=.76,center=.52,width=.22,offset=9)
    elif scene=='lowlight':
        a=a*.22+14+rng.normal(0,3,a.shape);params.update(gain=.22,offset=14,noise_sigma=3)
    elif scene=='glare':
        mask=np.exp(-((u-.56)/.12)**2)*np.exp(-((v-.5)/.48)**2)
        a=a*.78+145*mask[:,:,None]+12;params.update(gain=.78,glare_amplitude=145,offset=12)
    elif scene=='gradient':
        a=a*(.18+.82*u[:,:,None])+9;params.update(gain_left=.18,gain_right=1,offset=9)
    elif scene=='noise':
        a=a*.72+22+rng.normal(0,14,a.shape)
        marked=rng.random((h,w))<.003;a[marked]=rng.choice([0,255],size=(int(marked.sum()),1))
        params.update(gain=.72,offset=22,noise_sigma=14,salt_pepper_probability=.003)
    return Image.fromarray(np.clip(np.rint(a),0,255).astype(np.uint8)),params


def generate(output):
    output=Path(output)
    if output.exists():raise FileExistsError('dataset directory already exists; no overwrite')
    output.mkdir(parents=True)
    for name in ('source','roi','clean','truth','rgb565'):(output/name).mkdir()
    rows=[];clean_gate=[];index=0
    for scene,count in SCENES:
        for n in range(1,count+1):
            index+=1;image_id=f'{scene}_{n:02d}';base=f'base_{index:03d}'
            text=f'000026{index:06d}'  # fixed 12-digit fictional text; keep leading zeros
            seed=2026102300+index;split='tuning' if n<=2 else 'test'
            pristine=clean_roi(text);damaged,params=degrade(pristine,scene,seed)
            page=Image.new('RGB',(800,500),'white');draw=ImageDraw.Draw(page)
            draw.text((40,40),'FPGA EXPRESS - FICTIONAL WAYBILL',fill='black')
            draw.text((40,70),'No real personal information',fill='black')
            page.paste(damaged,(44,100));draw.text((44,450),text,fill='black')
            box=(44,100,44+pristine.width,100+pristine.height)
            roi,geometry=prepare_roi(page,box=box)
            # Matched geometry, with nearest sampling for exact binary truth.
            clean_page=page.copy();clean_page.paste(pristine,(44,100))
            clean,_=prepare_roi(clean_page,box=box,nearest=True)
            truth=Image.fromarray(np.where(np.asarray(clean.convert('L'))<128,0,255).astype(np.uint8))
            gate=decode(np.asarray(truth)[7:-7,7:-7],text)
            clean_gate.append({'image_id':image_id,**gate})
            page.save(output/'source'/f'{image_id}.png');roi.save(output/'roi'/f'{image_id}.png')
            clean.save(output/'clean'/f'{image_id}.png');truth.save(output/'truth'/f'{image_id}.png')
            (output/'rgb565'/f'{image_id}.bin').write_bytes(rgb565(roi).astype('>u2').tobytes())
            rows.append(dict(image_id=image_id,base_id=base,split=split,scene=scene,
                source_type='synthetic',expected_text=text,width=192,height=96,
                source_path=f'source/{image_id}.png',roi_path=f'roi/{image_id}.png',
                rgb565_path=f'rgb565/{image_id}.bin',clean_path=f'clean/{image_id}.png',
                ground_truth_path=f'truth/{image_id}.png',seed=seed,
                degradation_params=__import__('json').dumps(params,separators=(',',':')),
                roi_geometry=__import__('json').dumps(geometry,separators=(',',':')),
                notes='Unique base per sample; software synthetic; not a camera capture'))
    with (output/'manifest.csv').open('w',encoding='utf-8-sig',newline='') as f:
        writer=csv.DictWriter(f,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)
    files={str(p.relative_to(output)):sha256(p) for p in output.rglob('*') if p.is_file()}
    report={'schema':'single-pc-dataset-v3','samples':len(rows),
            'split_counts':dict(Counter(r['split'] for r in rows)),
            'scene_counts':dict(Counter(r['scene'] for r in rows)),
            'manifest_sha256':sha256(output/'manifest.csv'),'file_sha256':files,
            'decoder':DECODER_OPTIONS,'versions':versions(),'clean_common_roi_checks':clean_gate,
            'clean_gate_pass':all(r['exact_match'] for r in clean_gate),
            'note':'All generated samples retained; clean gate failure aborts evaluation, no sample deletion'}
    dump_json(output/'dataset_lock.json',report)
    if not report['clean_gate_pass']:raise RuntimeError('Clean common-area Code128 decoding failed; dataset not eligible')
    print('DATASET_PASS',len(rows),'tuning=12 test=18 clean_exact_match=30')
    return report

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,default=ROOT/'data'/'formal_v3')
    generate(p.parse_args().output)
