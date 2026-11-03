"""Check the continuation package manifest, not the original full ZIP manifest."""
import csv
import hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
count=0
with (ROOT/'CONTINUATION_SHA256.csv').open(encoding='utf-8-sig',newline='') as f:
    for row in csv.DictReader(f):
        path=(ROOT/row['path']).resolve()
        if not path.is_relative_to(ROOT.resolve()):raise ValueError('path escapes package')
        if not path.is_file() or path.stat().st_size!=int(row['bytes']):raise RuntimeError(f"missing/changed size: {row['path']}")
        if hashlib.sha256(path.read_bytes()).hexdigest()!=row['sha256']:raise RuntimeError(f"changed bytes: {row['path']}")
        count+=1
print('PACKAGE_INTEGRITY_PASS',count,'files')
