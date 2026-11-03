"""Portable Icarus regression, isolated ASCII working files, never overwrite baseline evidence."""
from __future__ import annotations
from dataclasses import asdict
import importlib.util
import json
from pathlib import Path
import random
import shutil
import subprocess
import sys
import tempfile
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'host'))
from common import Config,dump_json,reference,sha256
from protocol import make_request,parse_response
from experiment import fresh_run


def execute(cmd,cwd,log):
    p=subprocess.run([str(v) for v in cmd],cwd=cwd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                     text=True,encoding='utf-8',errors='replace')
    log.write_text(p.stdout,encoding='utf-8')
    if p.returncode:raise RuntimeError(f'RTL command failed: see {log}\n{p.stdout[-2000:]}')
    return p.stdout


def run(compiler='iverilog',runtime='vvp',base=None,output=None):
    compiler=shutil.which(compiler);runtime=shutil.which(runtime)
    if not compiler or not runtime:raise RuntimeError('Install Icarus (iverilog and vvp), or pass explicit executable paths')
    output=Path(output) if output else fresh_run('rtl')
    if output.exists():raise FileExistsError('RTL evidence output directory already exists')
    output.mkdir(parents=True)
    # Python handles Unicode source paths; the old Windows simulator receives only
    # short ASCII relative paths in a separate temporary working directory.
    with tempfile.TemporaryDirectory(prefix='fpga_v3_') as tmp:
        work=Path(tmp)
        if not str(work).isascii():raise RuntimeError('TEMP directory has non-ASCII characters; set TEMP to an ASCII directory')
        rtl=ROOT/'integration_b_v1/rtl'
        snapshot=ROOT/'team_v1_20261022/team_design_20261022/source_snapshot/rtl'
        for name in ('window_stats.sv','b_image_core.sv'):shutil.copy2(rtl/name,work/name)
        shutil.copy2(ROOT/'integration_b_v1/sim/tb_b_image_core.sv',work/'tb_b_image_core.sv')
        for name in ('uart_rx.v','uart_tx.v'):shutil.copy2(snapshot/name,work/name)
        shutil.copy2(ROOT/'official_v2/uart_official_v2_top.sv',work/'uart_official_v2_top.sv')
        shutil.copy2(ROOT/'official_v2/tb_uart_official_v2_top.sv',work/'tb_uart_official_v2_top.sv')
        spec=importlib.util.spec_from_file_location('v3_rtl_golden',ROOT/'integration_b_v1/tools/golden.py')
        golden=importlib.util.module_from_spec(spec);sys.modules[spec.name]=golden;spec.loader.exec_module(golden)
        rng=random.Random(20261023);cases=[]
        for w,h in ((15,15),(17,19),(64,64),(192,96),(256,128)):
            for mode in range(1,7):
                cfg=golden.Config(w,h,mode)
                pixels=[rng.randrange(65536) for _ in range(w*h)]
                cases.append((cfg,pixels))
        def vectors(folder,selected):
            folder.mkdir();count=0
            with (folder/'config.txt').open('w') as fc,(folder/'input.txt').open('w') as fi,(folder/'expected.txt').open('w') as fe:
                fc.write(f'{len(selected)}\n')
                for cfg,pixels in selected:
                    fc.write(' '.join(map(str,asdict(cfg).values()))+'\n')
                    fi.write(''.join(f'{p:04x}\n' for p in pixels))
                    expected=golden.process(pixels,cfg);count+=len(expected)
                    fe.write(''.join(' '.join(map(str,row))+'\n' for row in expected))
            return count
        count=vectors(work/'vectors',cases)
        compile_args=[compiler]+(['-B',str(base)] if base else [])+['-g2012','-s']
        execute(compile_args+['tb_b_image_core','-o','core.vvp','window_stats.sv','b_image_core.sv','tb_b_image_core.sv'],work,output/'core_compile.log')
        core_log=execute([runtime,'core.vvp','+DIR=vectors'],work,output/'core_simulation.log')
        if f'PASS frames={len(cases)} checked={count} mismatches=0' not in core_log:raise RuntimeError('missing full core PASS marker')
        vectors(work/'wave_vectors',cases[:6])
        execute([runtime,'core.vvp','+DIR=wave_vectors','+VCD=core_wave.vcd'],work,output/'wave_simulation.log')
        shutil.copy2(work/'core_wave.vcd',output/'core_wave.vcd')
        shutil.copy2(work/'vectors/actual_summary.txt',output/'core_actual_summary.txt')
        # Official UART baseline regression: 5 modes, bad CRC, good recovery.
        sim=work/'official_v2/sim_vectors';sim.mkdir(parents=True)
        pixels=[((x*3+y*11)&31)<<11|((x*5+y*7)&63)<<5|((x*13+y*2)&31) for y in range(16) for x in range(16)]
        requests=[make_request(pixels,Config(sequence=100+m,mode=m,width=16,height=16)) for m in range(1,6)]
        bad=bytearray(requests[0]);bad[-1]^=1;requests += [bytes(bad),requests[0]]
        (sim/'requests.hex').write_text(''.join(f'{b:02x}\n' for p in requests for b in p),encoding='ascii')
        execute(compile_args+['tb_uart_official_v2_top','-o','uart.vvp','window_stats.sv','b_image_core.sv','uart_rx.v','uart_tx.v','uart_official_v2_top.sv','tb_uart_official_v2_top.sv'],work,output/'uart_compile.log')
        uart_log=execute([runtime,'uart.vvp'],work,output/'uart_simulation.log')
        if 'OFFICIAL_V2_UART_PASS frames=7' not in uart_log:raise RuntimeError('missing UART PASS marker')
        raw=bytes(int(x,16) for x in (sim/'responses.hex').read_text().split())
        cursor=0;uart_rows=[]
        for i in range(7):
            mode=i+1 if i<5 else 1
            cfg=Config(sequence=100+mode,mode=mode,width=16,height=16)
            length=int.from_bytes(raw[cursor+13:cursor+17],'little')
            packet=raw[cursor:cursor+23+length];parsed=parse_response(packet,cfg)
            if parsed.status!=(3 if i==5 else 0):raise RuntimeError('UART wrong status')
            if not parsed.status and parsed.payload!=reference(pixels,cfg).tobytes():raise RuntimeError('UART payload mismatch')
            cursor+=len(packet);uart_rows.append({'mode':mode,'status':parsed.status,'pixels':len(parsed.payload),'mismatches':0})
        if cursor!=len(raw):raise RuntimeError('UART trailing bytes')
        (output/'uart_responses.bin').write_bytes(raw)
        # Additional pin-level errors and reset/partial-frame recovery.
        from recovery_cases import prepare
        scenarios=prepare()
        (work/'recovery_plan.txt').write_text(f"{len(scenarios)} {sum(x['response_bytes'] for x in scenarios)}\n"+
            ''.join(f"{len(x['packet'])} {x['response_bytes']} {x['action']}\n" for x in scenarios))
        (work/'recovery_requests.hex').write_text(''.join(f'{byte:02x}\n' for x in scenarios for byte in x['packet']))
        shutil.copy2(ROOT/'sim/tb_uart_recovery.sv',work/'tb_uart_recovery.sv')
        execute(compile_args+['tb_uart_recovery','-o','recovery.vvp','window_stats.sv','b_image_core.sv',
            'uart_rx.v','uart_tx.v','uart_official_v2_top.sv','tb_uart_recovery.sv'],work,output/'recovery_compile.log')
        recovery_log=execute([runtime,'recovery.vvp'],work,output/'recovery_simulation.log')
        if 'UART_RECOVERY_PASS' not in recovery_log:raise RuntimeError('missing recovery PASS marker')
        raw_recovery=bytes(int(x,16) for x in (work/'recovery_responses.hex').read_text().split())
        (output/'recovery_responses.bin').write_bytes(raw_recovery)
        cursor=0;recovery_rows=[]
        for case in scenarios:
            if case['status'] is None:
                recovery_rows.append({'name':case['name'],'expected_reply':False,'passed':True});continue
            packet=raw_recovery[cursor:cursor+case['response_bytes']];cursor+=len(packet)
            c=case['cfg']
            result=parse_response(packet,c if case['name']!='bad_mode' else None)
            if result.sequence!=c.sequence or result.status!=case['status']:raise RuntimeError(f"recovery mismatch {case['name']}: seq={result.sequence} status={result.status} expected={case['status']}")
            if not result.status and result.payload!=reference(case['pixels'],c).tobytes():raise RuntimeError('recovery pixel mismatch')
            recovery_rows.append({'name':case['name'],'status':result.status,'passed':True})
        if cursor!=len(raw_recovery):raise RuntimeError('recovery response boundary mismatch')
        (output/'recovery_responses.bin').write_bytes(raw_recovery)
        report={'status':'PASS','evidence_type':'RTL_simulation','new_board_test':False,
            'core_frames':len(cases),'core_pixels':count,'core_mismatches':0,
            'core_sizes':[[15,15],[17,19],[64,64],[192,96],[256,128]],
            'kernel_256x128_is_not_board_acceptance':True,
            'official_uart_frames':7,'official_uart_pixels':sum(r['pixels'] for r in uart_rows),'uart_rows':uart_rows,
            'uart_recovery_scenarios':len(recovery_rows),'recovery_rows':recovery_rows,
            'source_sha256':{str(p.relative_to(ROOT)):sha256(p) for p in
                [rtl/'window_stats.sv',rtl/'b_image_core.sv',ROOT/'official_v2/uart_official_v2_top.sv']}}
        dump_json(output/'report.json',report)
    print('RTL_REGRESSION_PASS',f'core_frames={len(cases)} core_pixels={count} uart_frames=7',output)
    return report
