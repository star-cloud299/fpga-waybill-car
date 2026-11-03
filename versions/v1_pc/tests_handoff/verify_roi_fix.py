"""Test exact-ROI callbacks without display and reproduce actual Code128 outcomes."""
from pathlib import Path
import argparse
import json
import sys
from types import SimpleNamespace
from PIL import Image


def verify(root,output):
    root=Path(root).resolve();sys.path.insert(0,str(root/'host'))
    from common import Config,prepare_roi,rgb565,dump_json
    from experiment import load_profile
    from runner import run_one
    from roi_controls import parse_roi,standard_sample
    from gui import App
    assert parse_roi('44,100,756,428',(800,500))==(44,100,756,428)
    assert parse_roi('[44，100，756，428]',(800,500))==(44,100,756,428)
    for invalid in ('44,100,756','44,100,801,428','756,100,44,428','-1,100,756,428'):
        try:parse_roi(invalid,(800,500))
        except ValueError:pass
        else:raise AssertionError('invalid ROI accepted')
    class Var:
        def __init__(self,v=''):self.v=v
        def get(self):return self.v
        def set(self,v):self.v=v
    fake=SimpleNamespace(busy=False,image=None,roi_box=None,expected=Var(),status=Var(),roi_text=Var())
    def set_image(image):fake.image=image;fake.roi_box=None
    def refresh_roi():
        canvas,meta=prepare_roi(fake.image,box=fake.roi_box)
        fake.last_meta=meta;fake.roi_text.set(','.join(map(str,meta['roi_box'])))
    fake.set_image=set_image;fake.refresh_image=lambda:None;fake.refresh_roi=refresh_roi
    App.load_standard_example(fake)
    assert fake.expected.get()=='000026000008' and fake.roi_box==(44,100,756,428)
    assert fake.last_meta['resized_size']==[178,82]
    fake.roi_text.set('44,100,756,428');App.apply_exact_roi(fake)
    assert fake.roi_box==(44,100,756,428)
    frozen=load_profile(root/'data/formal_v3',root/'results/frozen_profile.json')
    output=Path(output);output.mkdir(parents=True,exist_ok=False)
    results=[]
    for name,box,expected_match in [('screenshot_roi',(0,86,800,443),False),
                                  ('declared_standard_roi',(44,100,756,428),True)]:
        canvas,geometry=prepare_roi(fake.image,box=box)
        for mode in (4,5):
            cfg=Config(width=192,height=96,mode=mode,**frozen['selected_parameters'][str(mode)])
            row=run_one(rgb565(canvas),cfg,output/f'{name}_m{mode}',fake.expected.get())
            assert row['error'] is None and row['exact_match'] is expected_match
            assert row['mismatch_count'] is None and row['processing_cycles'] is None
            results.append({'roi':list(box),'resized_size':geometry['resized_size'],'mode':mode,
                            'decoded_texts':row['decoded_texts'],'exact_match':row['exact_match']})
    report={'status':'PASS','roi_validation':True,'standard_sample_callback':True,'apply_roi_callback':True,
            'real_decoder_checks':results,'parameters_changed':False,'algorithm_changed':False,
            'gui_display_tested':False,'board_tested':False}
    dump_json(output/'verification_report.json',report)
    print('ROI_FIX_VERIFIED: callbacks and real decoder checks passed; standard ROI modes 4/5 exact_match=True')
    return report

if __name__=='__main__':
    cli=argparse.ArgumentParser();cli.add_argument('--project',type=Path,default=Path.cwd())
    cli.add_argument('--output',type=Path,required=True);args=cli.parse_args();verify(args.project,args.output)
