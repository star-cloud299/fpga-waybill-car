#!/usr/bin/env python3
"""Single-PC entry point; invoke from any working directory."""
import argparse
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'host'))


def main():
    cli=argparse.ArgumentParser(description=__doc__)
    cli.add_argument('action',choices=['selftest','audit','dataset','tune','offline','board','gui','rtl-test','demo'])
    cli.add_argument('--data',type=Path,default=ROOT/'data/formal_v3')
    cli.add_argument('--profile',type=Path,default=ROOT/'results/frozen_profile.json')
    cli.add_argument('--output',type=Path)
    cli.add_argument('--port',help='Required only for an intentional real-board run, e.g. COM10')
    cli.add_argument('--split',choices=['tuning','test'],default='test')
    cli.add_argument('--iverilog',default='iverilog');cli.add_argument('--vvp',default='vvp')
    cli.add_argument('--iverilog-base',help='Optional Icarus lib/ivl directory for local unpacked installations')
    args=cli.parse_args()
    if args.action=='selftest':
        import unittest
        tests=unittest.defaultTestLoader.discover(str(ROOT/'tests'))
        result=unittest.TextTestRunner(verbosity=2).run(tests)
        if not result.wasSuccessful():raise SystemExit(1)
    elif args.action=='audit':
        sys.path.insert(0,str(ROOT/'tools'));from audit_baseline import audit
        audit(args.output or ROOT/'results/baseline_reaudit.json')
    elif args.action=='dataset':
        from dataset import generate
        generate(args.data)
    elif args.action=='tune':
        from experiment import tune
        tune(args.data,args.profile)
    elif args.action in ('offline','board'):
        from experiment import evaluate,fresh_run
        if args.action=='board' and not args.port:cli.error('board requires --port COMx; check Device Manager')
        if args.action=='offline' and args.port:cli.error('offline does not open a serial port; use board explicitly')
        evaluate(args.data,args.profile,args.output or fresh_run(args.action),args.split,
                 port=args.port if args.action=='board' else None,progress=print)
    elif args.action=='gui':
        from gui import launch
        launch()
    elif args.action=='rtl-test':
        sys.path.insert(0,str(ROOT/'tools'));from run_rtl import run
        run(args.iverilog,args.vvp,args.iverilog_base,args.output)
    elif args.action=='demo':
        # Existing package already has a frozen dataset/profile; never silently retune.
        from experiment import evaluate,fresh_run,load_profile
        if not args.profile.is_file():cli.error('frozen profile missing; explicitly run dataset/tune first')
        load_profile(args.data,args.profile)
        evaluate(args.data,args.profile,args.output or fresh_run('offline_demo'),args.split,progress=print)

if __name__=='__main__':main()
