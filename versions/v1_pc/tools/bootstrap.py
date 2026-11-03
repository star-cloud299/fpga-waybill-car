"""Install the locked environment locally; never alters global packages."""
from pathlib import Path
import argparse,os,subprocess,sys,venv
ROOT=Path(__file__).resolve().parents[1]

def environment_python(folder):
    return folder/('Scripts/python.exe' if os.name=='nt' else 'bin/python')

def setup(folder=None):
    if sys.version_info<(3,11):raise RuntimeError('Python 3.11 or newer is required. Python 3.11/3.12/3.13 64-bit recommended.')
    if sys.maxsize<=2**32:raise RuntimeError('Please install 64-bit Python.')
    folder=Path(folder) if folder else ROOT/'.venv'
    interpreter=environment_python(folder)
    if folder.exists() and not interpreter.is_file():
        raise RuntimeError(f'Incomplete environment: {folder}. Rename that folder and retry; no files were deleted.')
    if not interpreter.exists():venv.EnvBuilder(with_pip=True).create(folder)
    log=ROOT/'setup_log.txt'
    commands=[
        [str(interpreter),'-m','pip','install','-r',str(ROOT/'requirements.lock.txt')],
        [str(interpreter),'-c','import tkinter; from PIL import ImageTk; print("GUI_IMPORT_PASS")'],
        [str(interpreter),str(ROOT/'tools/verify_package.py')],
        [str(interpreter),str(ROOT/'tools/foundation.py'),'check']]
    with log.open('w',encoding='utf-8') as record:
        record.write('LOCAL ENVIRONMENT SETUP; no FPGA connection or programming\n')
        for cmd in commands:
            print('RUN:', ' '.join(cmd),flush=True)
            record.write('RUN: '+' '.join(cmd)+'\n');record.flush()
            process=subprocess.Popen(cmd,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
                text=True,encoding='utf-8',errors='replace',env={**os.environ,'PYTHONUTF8':'1','PYTHONIOENCODING':'utf-8'})
            for line in process.stdout:
                print(line,end='');record.write(line)
            if process.wait():raise RuntimeError('Setup/check failed; see '+str(log))
        record.write('SETUP_PASS\n')
    print('SETUP_PASS. Start: 02_start_menu.bat')

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--environment',type=Path)
    args=parser.parse_args()
    try:setup(args.environment)
    except Exception as error:print('SETUP_FAILED:',error);sys.exit(1)
