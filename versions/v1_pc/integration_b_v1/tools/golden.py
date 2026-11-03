"""Independent direct-window integer reference; standard library only."""
from dataclasses import dataclass, asdict

@dataclass(frozen=True)
class Config:
    width: int
    height: int
    mode: int
    threshold: int = 128
    bias: int = 12
    t1: int = 24
    t2: int = 80
    cflat: int = 18
    cmid: int = 12
    cedge: int = 6
    delta: int = 8

    def validate(self):
        k = 1 if self.mode <= 2 else 3 if self.mode == 3 else 15
        if not 1 <= self.mode <= 6:
            raise ValueError('mode must be 1..6')
        if not k <= self.width <= 256 or not k <= self.height <= 128:
            raise ValueError('invalid image dimensions for selected window')
        if any(not 0 <= v <= 255 for key, v in asdict(self).items()
               if key not in ('width', 'height', 'mode')):
            raise ValueError('all algorithm parameters must be unsigned bytes')
        if self.mode >= 5 and self.t1 >= self.t2:
            raise ValueError('t1 must be less than t2')
        return k


def gray565(p):
    r, g, b = (p >> 11) & 31, (p >> 5) & 63, p & 31
    r, g, b = (r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)
    return (77 * r + 150 * g + 29 * b + 128) >> 8


def process(pixels, cfg):
    """Return tuples: value, uncertain, saturated_margin, mean, D, x, y, last.

    Coordinates index cropped output. Original center is (x+k//2,y+k//2).
    Saturation applies ONLY to debug margin; uncertainty uses full 9-bit value.
    """
    k = cfg.validate()
    if len(pixels) != cfg.width * cfg.height:
        raise ValueError('input pixel count mismatch')
    if any(not 0 <= p <= 65535 for p in pixels):
        raise ValueError('RGB565 must be unsigned 16-bit')
    gray = [gray565(p) for p in pixels]
    w, h, mid = cfg.width, cfg.height, k // 2
    ow, oh = w - k + 1, h - k + 1
    out = []
    for y in range(oh):
        for x in range(ow):
            if k == 1:
                v = gray[y*w+x]
                value = v if cfg.mode == 1 else 0 if v < cfg.threshold else 255
                row = value, 0, 0, 0, 0
            else:
                # Deliberately direct nested sum, independent of RTL sliding sums.
                mean = sum(gray[(y+dy)*w+x+dx]
                           for dy in range(k) for dx in range(k)) // (k*k)
                cx, cy = x+mid, y+mid
                center = gray[cy*w+cx]
                nine = [gray[(cy+dy)*w+cx+dx] for dy in (-1,0,1) for dx in (-1,0,1)]
                d = max(nine) - min(nine)
                c = cfg.bias if cfg.mode < 5 else (cfg.cflat if d < cfg.t1 else
                    cfg.cmid if d < cfg.t2 else cfg.cedge)
                decision = center + c
                margin = abs(decision - mean)
                row = (0 if decision < mean else 255,
                       int(cfg.mode == 6 and margin < cfg.delta), min(255, margin), mean, d)
            out.append((*row, x, y, int(x == ow-1 and y == oh-1)))
    return out
