"""Tuning-only parameter selection and immutable held-out evaluation records."""
from __future__ import annotations
import csv
from dataclasses import replace
from datetime import datetime, timezone, timedelta
from pathlib import Path
import json
import numpy as np
from PIL import Image
from common import (ROOT, Config, DEFAULTS, DECODER_OPTIONS, common_crop, decode,
                    dump_json, load_manifest, metrics, reference, sha256, versions)

SOURCE_FILES=['host/common.py','host/dataset.py','host/experiment.py','official_v2/protocol.py','host/runner.py','integration_b_v1/tools/golden.py']


def source_hashes():return {rel:sha256(ROOT/rel) for rel in SOURCE_FILES}


def verify_data_lock(data):
    lock=json.loads((data/'dataset_lock.json').read_text(encoding='utf-8'))
    if not lock['clean_gate_pass']:raise ValueError('dataset clean decode gate did not pass')
    if sha256(data/'manifest.csv')!=lock['manifest_sha256']:raise ValueError('manifest changed after dataset freeze')
    for rel,digest in lock['file_sha256'].items():
        if sha256(data/rel)!=digest:raise ValueError(f'dataset file changed: {rel}')
    return lock


def load_pixels(data,item):
    w,h=int(item['width']),int(item['height'])
    raw=(data/item['rgb565_path']).read_bytes()
    if len(raw)!=2*w*h:raise ValueError('RGB565 file has wrong length')
    return np.frombuffer(raw,dtype='>u2').astype(np.uint16).reshape(h,w)


def candidates(mode):
    # Predeclared modest search, same 12 tuning samples for every mode.
    # Defaults first, lower ordinal wins an exact decode-count tie.
    if mode==2:return [{**DEFAULTS,'threshold':v} for v in (128,64,96,160,192)]
    if mode in (3,4):return [{**DEFAULTS,'bias':v} for v in (12,6,0,18,24)]
    return [{**DEFAULTS,**overrides} for overrides in (
        {},dict(cflat=12,cmid=12,cedge=12),dict(cflat=12,cmid=8,cedge=4),
        dict(cflat=24,cmid=16,cedge=8),dict(t1=16,t2=64,cflat=18,cmid=12,cedge=6))]


def tune(data,profile):
    data=Path(data);profile=Path(profile)
    if profile.exists():raise FileExistsError('frozen profile already exists; no overwrite or silent retuning')
    lock=verify_data_lock(data);items=load_manifest(data)
    tuning=[r for r in items if r['split']=='tuning']
    if len(tuning)!=12:raise ValueError('exactly 12 tuning samples required')
    # No test degraded image/RGB565 is loaded in this function.
    arrays={r['image_id']:load_pixels(data,r) for r in tuning}
    selected={};search=[]
    for mode in (2,3,4,5):
        results=[]
        for rank,params in enumerate(candidates(mode)):
            details=[]
            for r in tuning:
                cfg=Config(width=int(r['width']),height=int(r['height']),mode=mode,**params)
                out=common_crop(reference(arrays[r['image_id']],cfg),mode)
                details.append({'image_id':r['image_id'],**decode(out,r['expected_text'])})
            correct=sum(x['exact_match'] for x in details)
            results.append((correct,rank,params))
            search.append({'mode':mode,'candidate_rank':rank,'parameters':params,
                           'correct':correct,'total':12,'sample_results':details})
        best=sorted(results,key=lambda a:(-a[0],a[1]))[0]
        selected[str(mode)]=best[2]
        print(f'TUNE mode={mode} correct={best[0]}/12 candidate={best[1]}',flush=True)
    # Mode 5 only selected as provisional demo default on a strict tuning win.
    best4=max(r['correct'] for r in search if r['mode']==4)
    best5=max(r['correct'] for r in search if r['mode']==5)
    frozen={'schema':'single-pc-profile-v3','selection_split':'tuning',
        'tuning_image_ids':[r['image_id'] for r in tuning],
        'test_image_ids_used_for_selection':[],
        'tie_rule':'maximize exact decoded texts; then lowest predeclared candidate rank (defaults first)',
        'candidate_grid':{str(m):candidates(m) for m in (2,3,4,5)},
        'selected_parameters':selected,'provisional_default_mode':5 if best5>best4 else 4,
        'default_requires_board_confirmation':True,'dataset_lock_sha256':sha256(data/'dataset_lock.json'),
        'manifest_sha256':lock['manifest_sha256'],'source_sha256':source_hashes(),
        'versions':versions(),'decoder':DECODER_OPTIONS,'search_results':search}
    dump_json(profile,frozen)
    print('PROFILE_FROZEN',profile)
    return frozen


def load_profile(data,profile):
    verify_data_lock(data)
    frozen=json.loads(Path(profile).read_text(encoding='utf-8'))
    if frozen['dataset_lock_sha256']!=sha256(data/'dataset_lock.json'):raise ValueError('profile/dataset lock mismatch')
    if frozen['source_sha256']!=source_hashes():raise ValueError('algorithm source changed after freeze; create a versioned rerun')
    if frozen['versions']!=versions():raise ValueError('package versions differ from frozen environment; use requirements.lock.txt')
    return frozen


def fresh_run(label):
    stamp=datetime.now(timezone(timedelta(hours=8))).strftime('%Y%m%d_%H%M%S_%f')
    return ROOT/'runs'/f'{stamp}_{label}'


def summarize(rows):
    summary={}
    for mode in sorted(set(r['mode'] for r in rows)):
        group=[r for r in rows if r['mode']==mode]
        summary[str(mode)]={'samples':len(group),
            'correct':sum(r.get('decode_status')=='correct' for r in group),
            'undecodable':sum(r.get('decode_status')=='undecodable' for r in group),
            'wrong':sum(r.get('decode_status')=='wrong' for r in group),
            'errors':sum(r.get('error') is not None for r in group),
            'exact_match_rate':sum(r.get('decode_status')=='correct' for r in group)/len(group)}
        for key in ('precision','recall','f1','iou'):
            vals=[r[key] for r in group if r.get(key) is not None]
            summary[str(mode)][key+'_valid_samples']=len(vals)
            summary[str(mode)][key+'_mean']=sum(vals)/len(vals) if vals else None
    return summary


def save_table(path,rows):
    fields=['image_id','base_id','split','scene','mode','evidence_type','decode_status','exact_match',
            'expected_text','decoded_texts','mismatch_count','processing_cycles','round_trip_s',
            'tp','fp','fn','precision','recall','f1','iou','error']
    with path.open('w',encoding='utf-8-sig',newline='') as f:
        w=csv.DictWriter(f,fieldnames=fields,extrasaction='ignore');w.writeheader()
        for row in rows:
            r=dict(row)
            if 'decoded_texts' in r:r['decoded_texts']=json.dumps(r['decoded_texts'],ensure_ascii=False)
            w.writerow(r)


def evaluate(data,profile,output,split='test',port=None,progress=None):
    from runner import run_one
    data=Path(data);output=Path(output)
    frozen=load_profile(data,profile);items=[r for r in load_manifest(data) if r['split']==split]
    if output.exists():raise FileExistsError('new evidence directory required')
    output.mkdir(parents=True)
    rows=[];status='RUNNING';failure=None
    try:
        # One serial connection across the entire batch; no automatic retries.
        from runner import BoardSession
        from contextlib import nullcontext
        context=BoardSession(port) if port else nullcontext(None)
        with context as session:
            for index,r in enumerate(items):
                pixels=load_pixels(data,r)
                truth=np.asarray(Image.open(data/r['ground_truth_path']).convert('L')) if r['ground_truth_path'] else None
                for mode in (1,2,3,4,5):
                    params=DEFAULTS if mode==1 else frozen['selected_parameters'][str(mode)]
                    cfg=Config(sequence=index*5+mode,mode=mode,width=int(r['width']),height=int(r['height']),**params)
                    folder=output/r['image_id']/f'mode{mode}'
                    row=run_one(pixels,cfg,folder,r['expected_text'],session=session,
                                truth=truth,source=data/r['source_path'],roi=data/r['roi_path'])
                    row.update({key:r[key] for key in ('image_id','base_id','split','scene')})
                    rows.append(row)
                    if progress:progress(f"{r['image_id']} mode{mode}: {row.get('decode_status',row.get('error'))}")
                    if row.get('error'):raise RuntimeError(f"aborted: see {folder/'report.json'}")
        status='PASS'
    except Exception as exc:
        status='FAIL'
        failure=f'{type(exc).__name__}: {exc}'
        raise
    finally:
        save_table(output/'metrics.csv',rows)
        report={'status':status,'evidence_type':'board_current_run' if port else 'pc_reference_only',
                'board_tested_in_this_run':any(r.get('evidence_type')=='board_current_run' for r in rows),
                'board_connection_requested':bool(port),'requested_port':port,'failure':failure,'split':split,'image_count':len(items),
                'completed_mode_records':len(rows),'profile_sha256':sha256(Path(profile)),
                'dataset_lock_sha256':sha256(data/'dataset_lock.json'),
                'source_sha256':source_hashes(),'versions':versions(),'decoder':DECODER_OPTIONS,
                'common_original_roi':'[7:H-7,7:W-7] for every mode',
                'summary':summarize(rows),'rows':rows,
                'warning':'PC reference results are not FPGA measurements or proof of real-camera performance'}
        dump_json(output/'report.json',report)
    print('EVALUATION_PASS',split,'records=',len(rows),'type=',report['evidence_type'])
    return report
