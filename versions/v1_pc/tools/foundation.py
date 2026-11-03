"""Foundation checks, evidence audit, stability and component comparison.

No command except explicit `stability --port` opens a serial port.
"""
from pathlib import Path
import argparse,csv,hashlib,io,json,shutil,subprocess,sys,tempfile,zipfile
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'host'),str(ROOT/'tools')]
import numpy as np
from PIL import Image
from common import Config,reference,common_crop,decode,make_request,parse_response,dump_json,sha256,rgb565
from experiment import fresh_run,load_profile,load_manifest,load_pixels

def check():
    profile=load_profile(ROOT/'data/formal_v3',ROOT/'results/frozen_profile.json')
    bit=ROOT/'official_v2/board_reports/uart_official_v2_top.bit'
    assert sha256(bit)=='fc794482f76bbf222b8e4ac96462d4332a196e6381af522d0f9539fc0f239488'
    import unittest
    result=unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.discover(str(ROOT/'tests')))
    if not result.wasSuccessful():raise RuntimeError('workflow tests failed')
    from audit_baseline import audit
    folder=fresh_run('foundation_check');folder.mkdir(parents=True)
    audit(folder/'historical_board_audit.json')
    dump_json(folder/'check.json',{'status':'PASS','test_count':result.testsRun,
        'formal_modes':[1,2,3,4],'board_max_verified':[192,96],
        'bit_sha256':sha256(bit),'new_board_run':False,'new_vivado_build':False})
    print('FOUNDATION_CHECK_PASS',folder)

def audit_records(source,output=None):
    if not __debug__:raise RuntimeError('Do not use python -O for evidence checks')
    source=Path(source);archive=None
    if source.is_file():
        archive=zipfile.ZipFile(source)
        if archive.testzip() is not None:raise ValueError('ZIP CRC failure')
        names=set(archive.namelist());read=archive.read
    else:
        names={p.relative_to(source).as_posix() for p in source.rglob('*') if p.is_file()}
        read=lambda name:(source/name).read_bytes()
    rows=[];total_pixels=0;board=0
    try:
        if 'COLLECTION_MANIFEST.json' in names:
            manifest=json.loads(read('COLLECTION_MANIFEST.json'))
            entries=manifest if isinstance(manifest,list) else manifest.get('files',[])
            for item in entries:
                path=item['path']
                if path not in names and path.startswith('local_board_runs/'):
                    path=path[len('local_board_runs/'):]
                if path not in names:raise ValueError('manifest member missing: '+path)
                data=read(path)
                assert len(data)==item['bytes'],'manifest length differs'
                assert hashlib.sha256(data).hexdigest()==item['sha256'],'manifest hash differs'
        for name in sorted(names):
            if not name.endswith('/config.json'):continue
            prefix=name[:-len('config.json')]
            if prefix+'rgb565.bin' not in names:continue
            cfg=Config(**json.loads(read(name)))
            raw=read(prefix+'rgb565.bin')
            pixels=np.frombuffer(raw,dtype='>u2').astype(np.uint16).reshape(cfg.height,cfg.width)
            if prefix+'roi.png' in names:
                assert np.array_equal(rgb565(Image.open(io.BytesIO(read(prefix+'roi.png')))),pixels),'ROI/RGB565 mismatch'
            assert read(prefix+'request.bin')==make_request(pixels.reshape(-1).tolist(),cfg),'request differs'
            golden=reference(pixels,cfg)
            saved=np.asarray(Image.open(io.BytesIO(read(prefix+'reference.png'))))
            assert np.array_equal(golden,saved),'saved reference differs'
            recorded=json.loads(read(prefix+'report.json'))
            measured=prefix+'response.bin' in names
            if measured:
                parsed=parse_response(read(prefix+'response.bin'),cfg)
                assert parsed.status==0,'response failure status'
                native=np.frombuffer(parsed.payload,dtype=np.uint8).reshape(parsed.height,parsed.width)
                assert np.array_equal(native,golden),'board/golden differs'
                assert recorded.get('mismatch_count')==0
                board+=1;total_pixels+=native.size
            else:
                assert recorded.get('mismatch_count') is None
                assert recorded.get('evidence_type')=='pc_reference_only'
            expected=recorded.get('expected_text','')
            result=decode(common_crop(golden,cfg.mode),expected)
            if expected:
                assert result['exact_match']==recorded['exact_match'],'decode label differs'
                assert result['decoded_texts']==recorded['decoded_texts'],'decoded text differs'
            rows.append({'path':prefix,'mode':cfg.mode,'measured':measured,
                         'expected_text':expected,'exact_match':result['exact_match'] if expected else None,
                         'native_pixels':int(golden.size),'mismatch_count':0 if measured else None})
        if not rows:raise ValueError('no complete frame evidence found')
        summary={'status':'PASS','source':str(source),'frames':len(rows),'board_frames':board,
                 'verified_board_pixels':total_pixels,'new_board_run':False,'rows':rows}
        if output:dump_json(output,summary)
        print('EVIDENCE_AUDIT_PASS',len(rows),'frames',board,'board',total_pixels,'board pixels')
        return summary
    finally:
        if archive:archive.close()

def stability(port,count=100,output=None):
    from runner import BoardSession,run_one
    if count<1 or count>10000:raise ValueError('count must be 1..10000')
    profile=load_profile(ROOT/'data/formal_v3',ROOT/'results/frozen_profile.json')
    data=ROOT/'data/formal_v3'
    item=load_manifest(data)[0];a=load_pixels(data,item)
    pixels=a[np.arange(64)*a.shape[0]//64][:,np.arange(64)*a.shape[1]//64]
    folder=Path(output) if output else fresh_run('single_connection_stability')
    folder.mkdir(parents=True,exist_ok=False)
    rows=[];failure=None
    try:
        with BoardSession(port) as session:
            for i in range(count):
                mode=i%4+1
                parameters=profile['selected_parameters'].get(str(mode),profile['selected_parameters']['4'])
                cfg=Config(sequence=1000+i,mode=mode,width=64,height=64,**parameters)
                row=run_one(pixels,cfg,folder/f'frame_{i:04d}',session=session)
                rows.append(row)
                print(f'{i+1}/{count} mode={mode} mismatch={row["mismatch_count"]}',flush=True)
                if row['error']:raise RuntimeError(row['error'])
    except Exception as exc:failure=f'{type(exc).__name__}: {exc}'
    finally:
        dump_json(folder/'session.json',{'status':'FAIL' if failure else 'PASS','port':port,
            'requested_frames':count,'completed_frames':len(rows),'single_connection':True,
            'sizes':[64,64],'modes':[1,2,3,4],'failure':failure,'rows':rows,
            'note':'Correctness/stability, not a barcode recognition benchmark.'})
    if failure:raise RuntimeError(failure+'; evidence: '+str(folder))
    print('SINGLE_CONNECTION_STABILITY_PASS',folder)

def benchmark(compiler='iverilog',runtime='vvp',base=None,output=None):
    compiler=shutil.which(compiler);runtime=shutil.which(runtime)
    if not compiler or not runtime:raise RuntimeError('Icarus is required for component comparison')
    folder=Path(output) if output else fresh_run('component_compare')
    folder.mkdir(parents=True,exist_ok=False);frames=[]
    with tempfile.TemporaryDirectory(prefix='waybill_bench_') as temp:
        temp=Path(temp)
        shutil.copy2(ROOT/'integration_b_v1/rtl/window_stats.sv',temp/'window_stats.sv')
        for name in ['window_stats_naive.sv','tb_compare.sv']:shutil.copy2(ROOT/'benchmark'/name,temp/name)
        for k in [3,15]:
            command=[compiler]+(['-B',str(base)] if base else [])+['-g2012','-s','tb_compare',f'-Ptb_compare.K={k}',
                '-o','compare.vvp','window_stats.sv','window_stats_naive.sv','tb_compare.sv']
            build=subprocess.run(command,cwd=temp,capture_output=True,text=True)
            (folder/f'k{k}_compile.log').write_text(build.stdout+build.stderr)
            if build.returncode:raise RuntimeError('component compile failed')
            sim=subprocess.run([runtime,'compare.vvp'],cwd=temp,capture_output=True,text=True,timeout=120)
            (folder/f'k{k}_sim.log').write_text(sim.stdout+sim.stderr)
            if sim.returncode or f'COMPARE_PASS K={k}' not in sim.stdout:raise RuntimeError('component simulation failed')
            for f,(w,h) in enumerate([(k,k),(17,19),(32,24)]):
                n=np.arange(w*h).reshape(h,w);image=((n*37+(n//w)*19+f*53)&255).astype(np.uint8)
                windows=np.lib.stride_tricks.sliding_window_view(image,(k,k))
                means=windows.sum(axis=(-2,-1))//(k*k)
                records=[line.split()[1:] for line in sim.stdout.splitlines() if line.startswith(f'PIX {f} ')]
                assert len(records)==(w-k+1)*(h-k+1)
                for index,values in enumerate(records):
                    ff,x,y,mean,center,spread,cycle=map(int,values)
                    assert (x,y)==(index%(w-k+1),index//(w-k+1))
                    cy,cx=y+k//2,x+k//2;near=image[cy-1:cy+2,cx-1:cx+2]
                    assert (mean,center,spread)==(int(means[y,x]),int(image[cy,cx]),int(near.max())-int(near.min()))
                frames.append({'k':k,'width':w,'height':h,'pixels':len(records),'mismatches':0})
    result={'status':'PASS','evidence_type':'RTL_simulation','frames':frames,
        'both_architectures_same_output':True,'both_same_handshake':True,
        'resource_comparison_measured':False,'new_board_run':False,
        'next_command':'vivado -mode batch -source benchmark/compare.tcl',
        'note':'Direct K*K baseline vs existing sliding implementation; component OOC only. No LUT saving or speedup claimed before Vivado.'}
    dump_json(folder/'comparison.json',result);print('COMPONENT_COMPARE_PASS',sum(r['pixels'] for r in frames),'pixels',folder)

def gui_basic():
    import tkinter as tk
    import gui
    original=gui.MODES
    try:
        gui.MODES={m:s for m,s in original.items() if m<=4}
        root=tk.Tk();app=gui.App(root)
        app.auto_roi_enabled.set(False);app.load_standard_example()
        root.title('快递面单预处理 · 基础验收版 v5 · 模式1至4')
        root.mainloop()
    finally:gui.MODES=original

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['check','audit-runs','stability','benchmark','gui-basic'])
    parser.add_argument('--source',type=Path);parser.add_argument('--output',type=Path)
    parser.add_argument('--port');parser.add_argument('--count',type=int,default=100)
    parser.add_argument('--iverilog',default='iverilog');parser.add_argument('--vvp',default='vvp');parser.add_argument('--iverilog-base')
    a=parser.parse_args()
    if a.action=='check':check()
    elif a.action=='audit-runs':
        if not a.source:parser.error('audit-runs requires --source')
        audit_records(a.source,a.output)
    elif a.action=='stability':
        if not a.port:parser.error('stability requires --port; no serial device is opened automatically')
        stability(a.port,a.count,a.output)
    elif a.action=='benchmark':benchmark(a.iverilog,a.vvp,a.iverilog_base,a.output)
    else:gui_basic()

if __name__=='__main__':main()
