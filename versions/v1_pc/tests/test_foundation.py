from pathlib import Path
import importlib.util,json,sys,tempfile,unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'tools'),str(ROOT/'host')]
import foundation

class FoundationTests(unittest.TestCase):
    def test_stability_one_connection_and_new_evidence(self):
        calls=[]
        class Session:
            def __init__(self,port):calls.append(('open',port))
            def __enter__(self):return self
            def __exit__(self,*args):calls.append(('close',None))
        def run(pixels,cfg,folder,**kwargs):
            calls.append(('frame',cfg.mode))
            return {'mode':cfg.mode,'mismatch_count':0,'error':None}
        with tempfile.TemporaryDirectory() as temp:
            output=Path(temp)/'test'
            with patch('runner.BoardSession',Session),patch('runner.run_one',run):
                foundation.stability('TEST_ONLY',8,output)
            record=json.loads((output/'session.json').read_text())
            self.assertEqual(record['status'],'PASS')
            self.assertEqual(record['completed_frames'],8)
            self.assertEqual(calls,[('open','TEST_ONLY')]+[('frame',i%4+1) for i in range(8)]+[('close',None)])
            with self.assertRaises(FileExistsError):foundation.stability('TEST_ONLY',8,output)

    def test_stability_open_failure_is_not_success(self):
        class Fail:
            def __init__(self,port):pass
            def __enter__(self):raise OSError('test port unavailable')
            def __exit__(self,*args):pass
        with tempfile.TemporaryDirectory() as temp:
            output=Path(temp)/'test'
            with patch('runner.BoardSession',Fail),self.assertRaises(RuntimeError):
                foundation.stability('TEST_ONLY',2,output)
            record=json.loads((output/'session.json').read_text())
            self.assertEqual(record['status'],'FAIL')
            self.assertEqual(record['completed_frames'],0)
            self.assertIn('port unavailable',record['failure'])

    def test_empty_evidence_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(ValueError):foundation.audit_records(Path(temp))

    def test_corrupt_response_rejected(self):
        from common import Config,reference,make_request,dump_json
        import numpy as np
        from PIL import Image
        with tempfile.TemporaryDirectory() as temp:
            frame=Path(temp)/'mode1';frame.mkdir()
            cfg=Config(mode=1,width=16,height=16)
            pixels=np.zeros((16,16),dtype=np.uint16)
            from dataclasses import asdict
            dump_json(frame/'config.json',asdict(cfg));dump_json(frame/'report.json',{'mismatch_count':0})
            (frame/'rgb565.bin').write_bytes(pixels.astype('>u2').tobytes())
            (frame/'request.bin').write_bytes(make_request(pixels.ravel().tolist(),cfg))
            Image.fromarray(reference(pixels,cfg)).save(frame/'reference.png')
            (frame/'response.bin').write_bytes(b'CORRUPT RESPONSE')
            with self.assertRaises(ValueError):foundation.audit_records(Path(temp))

if __name__=='__main__':unittest.main()
