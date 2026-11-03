"""Exact ROI input and declared dataset sample loading. No decoder/algorithm edits."""
import json
import re
from pathlib import Path
from common import load_manifest,sha256


def parse_roi(text,size):
    cleaned=text.strip().strip('[]()（）【】')
    values=[v for v in re.split(r'[,，;；\s]+',cleaned) if v]
    if len(values)!=4 or any(not re.fullmatch(r'[0-9]+',v) for v in values):
        raise ValueError('请输入4个整数坐标，例如：44,100,756,428')
    x0,y0,x1,y1=map(int,values);w,h=size
    if not (0<=x0<x1<=w and 0<=y0<y1<=h):
        raise ValueError(f'坐标必须满足 0≤x0<x1≤{w}，0≤y0<y1≤{h}')
    return x0,y0,x1,y1


def standard_sample(root,image_id='shadow_03'):
    data=Path(root)/'data/formal_v3'
    lock=json.loads((data/'dataset_lock.json').read_text(encoding='utf-8'))
    if sha256(data/'manifest.csv')!=lock['manifest_sha256']:
        raise ValueError('数据清单已变化，不能自动套用原ROI和期望文本')
    items=load_manifest(data)
    matches=[r for r in items if r['image_id']==image_id]
    if len(matches)!=1:raise ValueError('找不到标准示例或示例不唯一')
    item=matches[0];source=data/item['source_path']
    if sha256(source)!=lock['file_sha256'].get(item['source_path']):
        raise ValueError('示例源图片已变化，不能套用原ROI和期望文本')
    geometry=json.loads(item['roi_geometry'])
    box=parse_roi(','.join(map(str,geometry['roi_box'])),geometry['source_size'])
    return source,box,item['expected_text']
