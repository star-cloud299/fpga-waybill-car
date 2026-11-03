"""Shared image/algorithm/evaluation rules for the single-PC official V2 workflow."""
from __future__ import annotations
import hashlib
import importlib.metadata
import json
from pathlib import Path
import sys
import numpy as np
from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'official_v2'))
from protocol import Config, make_request, output_geometry, parse_response  # noqa: E402

DEFAULTS = dict(threshold=128, bias=12, t1=24, t2=80, cflat=18, cmid=12, cedge=6)
DECODER_OPTIONS = {'format': 'Code128', 'try_rotate': False, 'try_downscale': False,
                   'try_invert': False, 'preprocessing': 'none; identical decoder settings for all modes'}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def dump_json(path: Path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2, allow_nan=False)+'\n', encoding='utf-8')


def versions():
    return {n: importlib.metadata.version(n) for n in
            ('numpy','Pillow','python-barcode','zxing-cpp','pyserial')}


def prepare_roi(image: Image.Image, width=192, height=96, box=None, nearest=False):
    """EXIF oriented image, optional pixel ROI, keep aspect, white canvas, 7px guard.

    Apply the exact same returned geometry to an aligned clean ground truth.
    """
    image = ImageOps.exif_transpose(image).convert('RGB')
    if width < 15 or height < 15 or width > 192 or height > 96:
        raise ValueError('current verified board limit is 192x96; minimum ROI canvas is 15x15')
    if box is None: box=(0,0,image.width,image.height)
    x0,y0,x1,y1=map(int,box)
    if not 0<=x0<x1<=image.width or not 0<=y0<y1<=image.height:
        raise ValueError('ROI is outside the image or empty')
    roi=image.crop((x0,y0,x1,y1))
    available_w,available_h=width-14,height-14
    scale=min(available_w/roi.width,available_h/roi.height)
    rw=max(1,min(available_w,round(roi.width*scale)))
    rh=max(1,min(available_h,round(roi.height*scale)))
    px,py=(width-rw)//2,(height-rh)//2
    canvas=Image.new('RGB',(width,height),'white')
    canvas.paste(roi.resize((rw,rh),Image.Resampling.NEAREST if nearest else Image.Resampling.LANCZOS),(px,py))
    meta={'source_size':[image.width,image.height],'roi_box':[x0,y0,x1,y1],
          'canvas_size':[width,height],'resized_size':[rw,rh],'paste_xy':[px,py],
          'guard_pixels':7,'resampling':'NEAREST' if nearest else 'LANCZOS'}
    return canvas,meta


def rgb565(image):
    a=np.asarray(image.convert('RGB'),dtype=np.uint16)
    return ((a[:,:,0]>>3)<<11)|((a[:,:,1]>>2)<<5)|(a[:,:,2]>>3)


def gray565(pixels):
    p=np.asarray(pixels,dtype=np.uint16)
    r=(p>>11)&31;g=(p>>5)&63;b=p&31
    r=(r<<3)|(r>>2);g=(g<<2)|(g>>4);b=(b<<3)|(b>>2)
    return ((77*r.astype(np.uint32)+150*g.astype(np.uint32)+29*b.astype(np.uint32)+128)>>8).astype(np.uint8)


def local_stats(gray,k):
    # Integral image is independent of RTL column history and B's direct nested sum.
    a=gray.astype(np.int64)
    integral=np.pad(a,((1,0),(1,0))).cumsum(0).cumsum(1)
    sums=integral[k:,k:]-integral[:-k,k:]-integral[k:,:-k]+integral[:-k,:-k]
    mean=(sums//(k*k)).astype(np.uint16)
    mid=k//2
    center=a[mid:a.shape[0]-mid,mid:a.shape[1]-mid].astype(np.uint16)
    near=np.lib.stride_tricks.sliding_window_view(gray,(3,3))
    full_range=near.max(axis=(-2,-1)).astype(np.uint16)-near.min(axis=(-2,-1)).astype(np.uint16)
    trim=mid-1
    d=full_range if trim==0 else full_range[trim:-trim,trim:-trim]
    return mean,center,d


def reference(pixels,cfg):
    cfg.validate()
    a=np.asarray(pixels,dtype=np.uint16).reshape(cfg.height,cfg.width)
    gray=gray565(a)
    if cfg.mode==1:return gray
    if cfg.mode==2:return np.where(gray>=cfg.threshold,255,0).astype(np.uint8)
    mean,center,d=local_stats(gray,3 if cfg.mode==3 else 15)
    bias=cfg.bias if cfg.mode<5 else np.where(d<cfg.t1,cfg.cflat,np.where(d<cfg.t2,cfg.cmid,cfg.cedge))
    return np.where(center+bias>=mean,255,0).astype(np.uint8)


def common_crop(native,mode):
    """Map native outputs to original [7:H-7,7:W-7] for every mode."""
    border=7 if mode<=2 else 6 if mode==3 else 0
    return native[border:-border,border:-border] if border else native


def decode(image,expected):
    import zxingcpp
    a=np.ascontiguousarray(np.asarray(image,dtype=np.uint8))
    found=zxingcpp.read_barcodes(a,formats=zxingcpp.BarcodeFormat.Code128,
                               try_rotate=False,try_downscale=False,try_invert=False)
    texts=sorted(set(r.text for r in found if r.valid))
    # Multiple decoded texts are not accepted even if one happens to match.
    kind='correct' if texts==[str(expected)] else 'undecodable' if not texts else 'wrong'
    return {'decode_status':kind,'decoded_texts':texts,'exact_match':kind=='correct'}


def metrics(pred,truth):
    p=np.asarray(pred)==0;t=np.asarray(truth)==0
    if p.shape!=t.shape:raise ValueError('truth and prediction not aligned')
    tp=int(np.logical_and(p,t).sum());fp=int(np.logical_and(p,~t).sum());fn=int(np.logical_and(~p,t).sum())
    def div(a,b):return a/b if b else None
    return {'tp':tp,'fp':fp,'fn':fn,'precision':div(tp,tp+fp),'recall':div(tp,tp+fn),
            'f1':div(2*tp,2*tp+fp+fn),'iou':div(tp,tp+fp+fn)}


def load_manifest(data):
    import csv
    data=Path(data)
    with (data/'manifest.csv').open(encoding='utf-8-sig',newline='') as f:rows=list(csv.DictReader(f))
    groups={};texts={};ids=set()
    for r in rows:
        if r['image_id'] in ids:raise ValueError('duplicate image_id')
        ids.add(r['image_id'])
        if r['split'] not in ('tuning','test'):raise ValueError('bad split')
        if groups.setdefault(r['base_id'],r['split'])!=r['split']:raise ValueError('base_id split leakage')
        if texts.setdefault(r['expected_text'],r['split'])!=r['split']:raise ValueError('same barcode text crosses splits')
        for key in ('roi_path','rgb565_path','clean_path','source_path','ground_truth_path'):
            if not r.get(key):continue
            p=(data/r[key]).resolve()
            if not p.is_relative_to(data.resolve()) or not p.is_file():raise ValueError(f'invalid dataset path: {r[key]}')
        if int(r['width'])>192 or int(r['height'])>96:raise ValueError('dataset exceeds verified board dimensions')
    return rows
