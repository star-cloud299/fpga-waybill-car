"""Export latest 20 GUI runs without opening hardware or changing source."""
from pathlib import Path
from datetime import datetime
import hashlib,json,os,subprocess,zipfile
ROOT=Path(__file__).resolve().parents[1]

def export():
    candidates=[p.parent for p in (ROOT/'runs').glob('*/report.json')
                if p.parent.name.endswith(('_gui_reference','_gui_board'))]
    selected=sorted(candidates,key=lambda p:(p/'report.json').stat().st_mtime,reverse=True)[:20]
    if not selected:raise ValueError('No saved GUI runs found in this project. Run and save a PC/FPGA experiment first.')
    target=ROOT/'exports';target.mkdir(exist_ok=True)
    out=target/('waybill_runs_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f')+'.zip')
    entries=[]
    with zipfile.ZipFile(out,'x',zipfile.ZIP_DEFLATED) as z:
        for folder in selected:
            for file in sorted(folder.rglob('*')):
                if not file.is_file() or file.is_symlink():continue
                name=file.relative_to(ROOT).as_posix();data=file.read_bytes()
                z.writestr(name,data);entries.append({'path':name,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()})
        z.writestr('EXPORT_MANIFEST.json',json.dumps({'selection':'latest 20 saved GUI runs, including failures',
            'folders':[p.name for p in selected],'files':entries},ensure_ascii=False,indent=2))
    with zipfile.ZipFile(out) as z:
        if z.testzip():raise RuntimeError('ZIP integrity failure')
    print('EXPORTED:',out)
    if os.name=='nt':subprocess.Popen(['explorer.exe','/select,',str(out)])
    return out

if __name__=='__main__':export()
