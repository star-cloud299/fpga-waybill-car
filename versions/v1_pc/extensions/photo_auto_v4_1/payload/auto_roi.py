"""Geometry-only Code128 ROI detector; never uses expected text or decode success."""
from __future__ import annotations
import numpy as np
from PIL import Image, ImageOps

VERSION = 'photo-roi-v4.1'

def runs(mask):
    v = np.pad(np.asarray(mask, dtype=np.int8), (1, 1))
    starts = np.flatnonzero(np.diff(v) == 1)
    ends = np.flatnonzero(np.diff(v) == -1)
    return list(zip(starts.tolist(), ends.tolist()))

def locate_barcode(image):
    """Find a long band of repeated vertical edges, then use its middle 45%.

    Designed for a single horizontal printed barcode. Does not search crop
    candidates against a decoder. Fail explicitly when evidence is inadequate.
    """
    image = ImageOps.exif_transpose(image).convert('RGB')
    scale = min(1., 1200 / max(image.size))
    small = image.resize((round(image.width*scale), round(image.height*scale)))
    a = np.asarray(small.convert('L'), dtype=np.float32)
    dx = np.abs(np.diff(a, axis=1))
    # Local edge strength makes a gradual illumination gradient largely irrelevant.
    threshold = max(12., float(np.percentile(dx, 98)) * .35)
    counts = (dx > threshold).sum(axis=1).astype(float)
    smooth = np.convolve(counts, np.ones(9)/9, mode='same')
    bands = [(lo, hi) for lo, hi in runs(smooth > max(22., smooth.max()*.55))
             if hi-lo >= max(18, small.height*.07)]
    if not bands:
        raise ValueError('未找到完整横向条码。请让条码水平、清晰且只包含一个条码；也可关闭自动定位后手动框选。')
    top, bottom = max(bands, key=lambda b: (b[1]-b[0])*float(smooth[b[0]:b[1]].mean()))
    central = dx[top:bottom]
    support = (central > threshold).mean(axis=0)
    edges = np.flatnonzero(support > .3)
    if len(edges) < 25:
        raise ValueError('条码边缘不足，自动定位已停止；请检查对焦和遮挡。')
    groups = np.split(edges, np.flatnonzero(np.diff(edges) > small.width*.08)+1)
    edges = max(groups, key=len)
    left, right = int(edges[0]), int(edges[-1])+2
    if right-left < small.width*.15:
        raise ValueError('条码区域过小，请靠近拍摄。')
    quiet = round((right-left)*.10)
    left = max(0, left-quiet); right = min(small.width, right+quiet)
    middle = (top+bottom)/2
    half = (bottom-top)*.225
    box = (int(left/scale), int((middle-half)/scale),
           min(image.width, int(np.ceil(right/scale))),
           min(image.height, int(np.ceil((middle+half)/scale))))
    return box, {'version': VERSION, 'method': 'vertical-edge-band-middle-45pct',
                 'selection_uses_expected_text': False, 'selection_uses_decoder': False,
                 'barcode_band': [int(left/scale), int(top/scale),
                                  int(right/scale), int(bottom/scale)],
                 'roi_box': list(box), 'quiet_zone_fraction': .10}

def auto_select_roi(image, parameters):
    """Decoder-assisted experimental ROI selection; no expected text is read.

    All modes receive ONE winning crop. Frozen hardware formulas stay intact.
    This is an explicit new host pipeline, not the frozen formal benchmark.
    """
    from common import prepare_roi, rgb565, Config, reference, common_crop
    import zxingcpp
    _, detection = locate_barcode(image)
    l,t,r,b = detection['barcode_band']
    barw = (r-l)/1.2
    cx,cy = (l+r)/2,(t+b)/2
    candidates = []
    for pad in [.06,.08,.10,.12,.14,.16,.18,.20]:
        for fraction in [.40,.55,.70,1.0]:
            w,h = barw*(1+2*pad),(b-t)*fraction
            box = (max(0,round(cx-w/2)),max(0,round(cy-h/2)),
                   min(image.width,round(cx+w/2)),min(image.height,round(cy+h/2)))
            roi,_ = prepare_roi(image,box=box)
            pixels = rgb565(roi)
            texts = {}
            for mode in range(1,6):
                cfg = Config(mode=mode,width=192,height=96,**parameters[mode])
                output = np.ascontiguousarray(common_crop(reference(pixels,cfg),mode))
                found = zxingcpp.read_barcodes(output,formats=zxingcpp.BarcodeFormat.Code128,
                            try_rotate=False,try_downscale=False,try_invert=False)
                values = sorted(set(item.text for item in found if item.valid))
                texts[str(mode)] = values
            single = [v[0] for v in texts.values() if len(v)==1]
            consensus = max((single.count(v) for v in set(single)),default=0)
            score = (consensus, len(single))
            candidates.append({'box':list(box),'texts':texts,'score':list(score),
                               'padding_fraction':pad,'height_fraction':fraction})
    winner = max(candidates,key=lambda row: tuple(row['score']))
    info = dict(detection,method='decoder-assisted-common-roi-v4.1',
                selection_uses_decoder=True,selection_uses_expected_text=False,
                formal_benchmark_compatible=False,
                warning='Exploratory real-photo pipeline; do not pool with frozen benchmark.',
                candidates=candidates,selected=winner,roi_box=winner['box'])
    return tuple(winner['box']),info
