import importlib.util
import json
from pathlib import Path
import random
import struct
import sys
import tempfile
import unittest
import numpy as np
from PIL import Image
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'host'))
from common import (Config,common_crop,gray565,load_manifest,metrics,prepare_roi,reference,rgb565,decode)
from protocol import crc16,make_request,parse_response
from runner import run_one
spec=importlib.util.spec_from_file_location('b_golden',ROOT/'integration_b_v1/tools/golden.py')
b=importlib.util.module_from_spec(spec);sys.modules['b_golden']=b;spec.loader.exec_module(b)

class WorkflowTests(unittest.TestCase):
    def test_exhaustive_rgb565_gray(self):
        pixels=np.arange(65536,dtype=np.uint16)
        expected=np.array([b.gray565(int(v)) for v in pixels],dtype=np.uint8)
        np.testing.assert_array_equal(gray565(pixels),expected)

    def test_models_all_modes_and_extreme_bias(self):
        rng=random.Random(20261023)
        for w,h in [(15,15),(17,19)]:
            pixels=[rng.randrange(65536) for _ in range(w*h)]
            for mode in range(1,6):
                for bias in (0,12,255):
                    cfg=Config(mode=mode,width=w,height=h,bias=bias,cflat=bias,cmid=bias,cedge=bias)
                    bc=b.Config(w,h,mode,bias=bias,cflat=bias,cmid=bias,cedge=bias)
                    direct=bytes(r[0] for r in b.process(pixels,bc))
                    self.assertEqual(reference(pixels,cfg).tobytes(),direct)

    def test_roi_letterbox_and_guard(self):
        prepared,geometry=prepare_roi(Image.new('RGB',(400,100),'black'))
        self.assertEqual(prepared.size,(192,96))
        self.assertEqual(geometry['resized_size'],[178,44])
        arr=np.asarray(prepared)
        self.assertTrue(np.all(arr[:7]==255));self.assertTrue(np.all(arr[-7:]==255))
        self.assertTrue(np.all(arr[:,:7]==255));self.assertTrue(np.all(arr[:,-7:]==255))
        with self.assertRaises(ValueError):prepare_roi(prepared,box=(10,10,1,1))
        with self.assertRaises(ValueError):prepare_roi(prepared,width=256,height=128)

    def test_common_roi_coordinates(self):
        a=np.arange(192*96).reshape(96,192)
        for mode,border in ((1,0),(2,0),(3,1),(4,7),(5,7)):
            native=a if not border else a[border:-border,border:-border]
            np.testing.assert_array_equal(common_crop(native,mode),a[7:-7,7:-7])

    def test_metrics_undefined_is_none(self):
        white=np.full((4,4),255,np.uint8)
        m=metrics(white,white)
        self.assertIsNone(m['precision']);self.assertIsNone(m['recall'])
        self.assertIsNone(m['f1']);self.assertIsNone(m['iou'])
        self.assertEqual(metrics(np.zeros((4,4),np.uint8),np.zeros((4,4),np.uint8))['f1'],1)

    def test_request_endianness_crc_and_params(self):
        cfg=Config(sequence=0x1234,mode=1,width=3,height=3)
        packet=make_request([0xF800,0x07E0,0x001F]+[0]*6,cfg)
        self.assertEqual(packet[:5],b'\xa6\x6a\x02\x34\x12')
        self.assertEqual(packet[21:27],b'\xf8\x00\x07\xe0\x00\x1f')
        self.assertEqual(crc16(b'123456789'),0x29B1)
        self.assertEqual(struct.unpack('<H',packet[-2:])[0],crc16(packet[2:-2]))
        with self.assertRaises(ValueError):make_request([0]*9,Config(width=3,height=3,t1=80,t2=80))
        # Archived response: changed CRC or sequence must fail.
        path=ROOT/'official_v2/evidence/board_sweep_20261023/64x64_mode1/response.bin'
        raw=path.read_bytes();parse_response(raw,Config(sequence=201,mode=1,width=64,height=64))
        with self.assertRaises(ValueError):parse_response(raw[:-1]+bytes([raw[-1]^1]))
        with self.assertRaises(ValueError):parse_response(raw,Config(sequence=202,mode=1,width=64,height=64))

    def test_offline_never_creates_board_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp)/'中文目录'
            row=run_one(np.zeros((15,15),np.uint16),Config(mode=4,width=15,height=15),folder)
            self.assertIsNone(row['mismatch_count']);self.assertIsNone(row['processing_cycles'])
            self.assertIsNone(row['round_trip_s']);self.assertTrue((folder/'reference.png').exists())
            for name in ('response.bin','fpga_result.png','diff.png'):self.assertFalse((folder/name).exists())

    def test_failed_board_preserves_response_and_error(self):
        class FailedSession:
            partial=b'broken'
            def exchange(self,*args):raise TimeoutError('test timeout')
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp)/'failed'
            row=run_one(np.zeros((15,15),np.uint16),Config(mode=4,width=15,height=15),folder,session=FailedSession())
            self.assertEqual((folder/'response.bin').read_bytes(),b'broken')
            self.assertIn('TimeoutError',row['error']);self.assertFalse((folder/'fpga_result.png').exists())

    def test_port_open_failure_is_not_board_success(self):
        from unittest.mock import patch
        from experiment import evaluate
        with tempfile.TemporaryDirectory() as tmp:
            output=Path(tmp)/'new_record'
            with patch('runner.BoardSession.__enter__',side_effect=OSError('unavailable COM port')):
                with self.assertRaises(OSError):
                    evaluate(ROOT/'data/formal_v3',ROOT/'results/frozen_profile.json',output,port='TEST_NO_DEVICE')
            report=json.loads((output/'report.json').read_text())
            self.assertEqual(report['status'],'FAIL')
            self.assertFalse(report['board_tested_in_this_run'])
            self.assertTrue(report['board_connection_requested'])
            self.assertIn('unavailable COM port',report['failure'])
            self.assertFalse(list(output.rglob('fpga_result.png')))

    def test_frozen_profile_has_no_heldout_selection(self):
        from experiment import load_profile
        frozen=load_profile(ROOT/'data/formal_v3',ROOT/'results/frozen_profile.json')
        items=load_manifest(ROOT/'data/formal_v3')
        tuning={r['image_id'] for r in items if r['split']=='tuning'}
        self.assertEqual(set(frozen['tuning_image_ids']),tuning)
        self.assertEqual(frozen['test_image_ids_used_for_selection'],[])
        for candidate in frozen['search_results']:
            self.assertEqual({r['image_id'] for r in candidate['sample_results']},tuning)

    def test_dataset_split_and_leading_zero_clean_gate(self):
        data=ROOT/'data/formal_v3';items=load_manifest(data)
        self.assertEqual(len(items),30)
        self.assertEqual(sum(r['split']=='tuning' for r in items),12)
        self.assertEqual(sum(r['split']=='test' for r in items),18)
        tuning={r['base_id'] for r in items if r['split']=='tuning'}
        testing={r['base_id'] for r in items if r['split']=='test'}
        self.assertFalse(tuning&testing)
        for r in items:
            self.assertTrue(r['expected_text'].startswith('0000'))
            image=np.asarray(Image.open(data/r['ground_truth_path']))[7:-7,7:-7]
            self.assertTrue(decode(image,r['expected_text'])['exact_match'])

if __name__=='__main__':unittest.main(verbosity=2)
