"""Developer GUI smoke test. Requires a real or virtual display; never opens a camera/COM port."""
from pathlib import Path
import json
import sys
import time
import tkinter as tk
from PIL import Image,ImageGrab
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'host'))
from gui import App
from common import dump_json

root=tk.Tk();app=App(root)
app.set_image(Image.open(ROOT/'data/formal_v3/source/shadow_03.png'))
app.roi_box=(44,100,756,428);app.refresh_image();app.refresh_roi()
app.expected.set('000026000008')
app.transport.set('offline');app.compare.set(True)
started=time.monotonic();result={}

def wait_done():
    if time.monotonic()-started>20:
        result['error']='GUI task timeout';root.destroy();return
    if app.busy:
        root.after(80,wait_done);return
    try:
        report=json.loads((app.last_run/'report.json').read_text())
        assert report['status']=='PASS',report
        assert len(report['rows'])==5
        assert all(r['evidence_type']=='pc_reference_only' for r in report['rows'])
        assert not list(app.last_run.rglob('response.bin'))
        app.tabs.select(3);root.update_idletasks();root.update()
        x,y=root.winfo_rootx(),root.winfo_rooty();w,h=root.winfo_width(),root.winfo_height()
        ImageGrab.grab().crop((x,y,x+w,y+h)).save(ROOT/'results/gui_smoke.png')
        result.update(status='PASS',type='Tkinter virtual-display file/ROI/five-mode reference test',
                      camera_tested=False,serial_tested=False,windows_tested=False,
                      output_directory=str(app.last_run.relative_to(ROOT)))
    except Exception as e:result['error']=str(e)
    finally:
        dump_json(ROOT/'results/gui_smoke.json',result);root.destroy()

def start():
    app.start();root.after(100,wait_done)
root.after(200,start);root.mainloop()
if result.get('status')!='PASS':raise RuntimeError(result)
print('GUI_SMOKE_PASS input/ROI/five-mode threaded reference/results; no camera or COM')
