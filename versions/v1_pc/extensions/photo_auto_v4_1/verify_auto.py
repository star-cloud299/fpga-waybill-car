"""Real-photo regression and non-hardware worker checks."""
from pathlib import Path
import sys, json, argparse
from PIL import Image

def verify(project, photos):
    sys.path.insert(0,str(Path(project).resolve()/'host'))
    from auto_roi import auto_select_roi, locate_barcode
    from common import DEFAULTS, prepare_roi, rgb565, reference, common_crop, Config, decode
    profile=json.loads((Path(project)/'results/frozen_profile.json').read_text())
    parameters={m:DEFAULTS.copy() if m==1 else profile['selected_parameters'][str(m)] for m in range(1,6)}
    try:locate_barcode(Image.new('RGB',(800,500),'white'))
    except ValueError:pass
    else:raise AssertionError('Blank image must be rejected')
    rows=[]
    for photo in photos:
        image=Image.open(photo)
        box,info=auto_select_roi(image,parameters)
        roi,geometry=prepare_roi(image,box=box)
        assert info['selection_uses_expected_text'] is False
        assert info['selection_uses_decoder'] is True
        result=[]
        for m in range(1,6):
            a=common_crop(reference(rgb565(roi),Config(mode=m,width=192,height=96,**parameters[m])),m)
            row=decode(a,'000026000003')
            wrong=decode(a,'INTENTIONALLY_WRONG_LABEL')
            assert wrong['exact_match'] is False
            result.append(row)
        assert [r['exact_match'] for r in result]==[True,True,False,True,True]
        rows.append({'photo':Path(photo).name,'roi':list(box),'geometry':geometry,'results':result})
    return {'status':'PASS','real_board_tested':False,'gui_display_tested':False,
            'blank_rejected':True,'wrong_expected_text_rejected':True,'photo_results':rows}

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--project',required=True);p.add_argument('--photos',nargs='+',required=True);p.add_argument('--report')
    args=p.parse_args();result=verify(args.project,args.photos)
    if args.report:Path(args.report).write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result,ensure_ascii=False))
