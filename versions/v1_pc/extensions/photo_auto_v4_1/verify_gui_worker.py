"""Exercise real GUI worker logic without display or real serial hardware."""
from pathlib import Path
import argparse
import json
from queue import Queue
import sys
import tempfile
import threading
from types import SimpleNamespace
from unittest.mock import patch
from PIL import Image


def verify(root):
    sys.path.insert(0,str(Path(root).resolve()/'host'))
    import gui
    from gui_status import completion_message
    from common import DEFAULTS
    class Var:
        def __init__(self,v):self.v=v
        def get(self):return self.v
        def set(self,v):self.v=v
    class Label:
        def configure(self,**kwargs):pass
    class ImmediateThread:
        def __init__(self,target,**kwargs):self.target=target
        def start(self):self.target()
    class OpenFailure:
        def __init__(self,port):self.port=port
        def __enter__(self):raise OSError('TEST could not open port TEST_COM')
        def __exit__(self,*args):pass
    class ReceiveTimeout:
        partial=b''
        def __init__(self,port):pass
        def __enter__(self):return self
        def __exit__(self,*args):pass
        def exchange(self,*args):raise TimeoutError('TEST received 0/21 response bytes')
    checks={}
    for name,session,transport,expected_status in [('port_open_failure',OpenFailure,'board','FAIL'),
        ('receive_timeout',ReceiveTimeout,'board','FAIL'),('reference_success',None,'offline','PASS')]:
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp)/'run'
            fake=SimpleNamespace(auto_roi_enabled=Var(False),auto_roi_info=None,busy=False,compare=Var(False),mode=Var('4 自适应15x15'),
                params={k:Var(str(v)) for k,v in DEFAULTS.items()},frozen=Var(True),
                transport=Var(transport),port=Var('TEST_COM'),
                image=Image.open(Path(root)/'data/formal_v3/source/shadow_03.png').convert('RGB'),
                roi_box=(44,100,756,428),expected=Var('000026000008'),camera_stop=threading.Event(),
                stop=threading.Event(),result_labels={4:(Label(),Label())},status=Var(''),queue=Queue(),
                close_after=False,root=SimpleNamespace(after=lambda *a:None))
            def busy(value):fake.busy=value
            fake.set_busy=busy;fake.poll=lambda:None
            with patch.object(gui,'fresh_run',return_value=out),patch.object(gui.threading,'Thread',ImmediateThread),patch.object(gui,'BoardSession',session):
                gui.App.start(fake)
            report=json.loads((out/'report.json').read_text(encoding='utf-8'))
            assert report['status']==expected_status and report['expected_text']=='000026000008'
            assert '未填写期望文本' not in report['summary']
            if expected_status=='FAIL':
                assert report['failure'] and (out/'error.log').is_file()
                assert not list(out.rglob('fpga_result.png'))
                if name=='port_open_failure':
                    assert 'could not open port' in report['summary'] and report['rows']==[]
                    with patch.object(gui.messagebox,'showerror') as dialog:
                        gui.App.poll(fake)
                        dialog.assert_called_once()
                    assert 'could not open port' in fake.status.get()
                else:assert '0/21' in report['summary']
            else:
                assert report['rows'][0]['exact_match'] is True
                assert report['summary']=='流程完成；精确匹配 1/1 个模式'
            checks[name]=True
    from auto_roi import auto_select_roi
    with tempfile.TemporaryDirectory() as tmp:
        out=Path(tmp)/'auto_run'
        fake=SimpleNamespace(busy=False,compare=Var(True),mode=Var('4 自适应15x15'),
            params={k:Var(str(v)) for k,v in DEFAULTS.items()},frozen=Var(True),
            auto_roi_enabled=Var(True),auto_roi_info=None,auto_error=None,
            transport=Var('offline'),port=Var(''),
            image=Image.open(Path(__file__).resolve().parent/'test_photos/07.jpg').convert('RGB'),
            roi_box=None,expected=Var('000026000003'),camera_stop=threading.Event(),
            stop=threading.Event(),result_labels={m:(Label(),Label()) for m in range(1,6)},
            status=Var(''),queue=Queue(),close_after=False,
            root=SimpleNamespace(after=lambda *a:None))
        fake.set_busy=lambda value:setattr(fake,'busy',value)
        fake.clear_results=lambda:gui.App.clear_results(fake)
        fake.photo_parameters=lambda:gui.App.photo_parameters(fake)
        fake.refresh_image=lambda:None
        fake.refresh_roi=lambda:None
        fake.auto_locate=lambda:gui.App.auto_locate(fake)
        with patch.object(gui,'fresh_run',return_value=out),patch.object(gui.threading,'Thread',ImmediateThread):
            gui.App.start(fake)
        report=json.loads((out/'report.json').read_text())
        assert report['status']=='PASS'
        assert [r['exact_match'] for r in report['rows']]==[True,True,False,True,True]
        assert report['roi_geometry']['auto_roi']['selection_uses_expected_text'] is False
        assert report['roi_geometry']['host_pipeline']=='experimental_photo_auto_v4.1'
        assert not list(out.rglob('response.bin'))
        assert all(r['mismatch_count'] is None for r in report['rows'])
        fake.busy=False
        fake.image=Image.open(Path(__file__).resolve().parent/'test_photos/04.jpg').convert('RGB')
        gui.App.auto_locate(fake)
        assert fake.roi_box==(280,390,1130,550)
        checks.update(auto_reference_worker=True,automatic_relocation=True,
                      single_common_roi=True,no_fake_board_evidence=True)
    assert '未填写期望文本' in completion_message('PASS','',[])
    assert '未填写期望文本' not in completion_message('PASS','000026000008',[])
    assert 'TEST' in completion_message('FAIL','',[{'error':'TEST'}])
    checks.update(genuine_empty_expected_label=True,provided_label_with_no_result=True,error_priority=True)
    print('GUI_STATUS_FIX_PASS',json.dumps(checks))
    return {'status':'PASS','checks':checks,'real_serial_tested':False,'gui_display_tested':False,
            'algorithm_changed':False,'frozen_parameters_changed':False}

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--project',type=Path,required=True);p.add_argument('--report',type=Path)
    args=p.parse_args();report=verify(args.project)
    if args.report:args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
