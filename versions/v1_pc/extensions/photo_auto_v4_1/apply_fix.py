"""Apply the GUI-only exact-ROI fix, backing up files and preserving frozen algorithms."""
from pathlib import Path
from datetime import datetime
import argparse
import csv
import hashlib
import io
import json
import shutil

HERE=Path(__file__).resolve().parent

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def install(root):
    root=Path(root).resolve()
    if not (root/'run.py').is_file() or not (root/'host/gui.py').is_file():
        raise ValueError('目录不正确：必须选择同时含run.py和host文件夹的single_pc_v3目录')
    info=json.loads((HERE/'patch_manifest.json').read_text(encoding='utf-8'))
    for name,value in info['payload_sha256'].items():
        payload=HERE/'payload'/name
        if digest(payload)!=value:raise ValueError('补丁文件校验失败，请重新解压补丁')
        compile(payload.read_text(encoding='utf-8'),name,'exec')
    if all((root/'host'/name).is_file() and digest(root/'host'/name)==value for name,value in info['payload_sha256'].items()):
        print('补丁已经安装，无需重复。');return
    if digest(root/'host/gui.py') not in info.get('accepted_gui_sha256',[info['base_gui_sha256']]):
        raise ValueError('当前gui.py不是此补丁对应版本，已停止且没有覆盖。请提供当前文件核对。')
    frozen_path=root/'results/frozen_profile.json'
    frozen=json.loads(frozen_path.read_text(encoding='utf-8'))
    before={rel:digest(root/rel) for rel in frozen['source_sha256']}
    if before!=frozen['source_sha256']:raise ValueError('原算法文件与冻结版本不同，已停止；不会重新选参或覆盖算法')
    freeze_digest=digest(frozen_path)
    backup=root/'backups'/('photo_auto_v4_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    backup.mkdir(parents=True,exist_ok=False)
    targets=[root/'host'/name for name in info['payload_sha256']]
    manifest=root/'CONTINUATION_SHA256.csv'
    paths=targets+([manifest] if manifest.exists() else [])
    existed={p:p.exists() for p in paths}
    for p in paths:
        if p.exists():
            dest=backup/p.relative_to(root);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,dest)
    try:
        for name in info['payload_sha256']:shutil.copy2(HERE/'payload'/name,root/'host'/name)
        if manifest.exists():
            with manifest.open(encoding='utf-8-sig',newline='') as f:rows=list(csv.DictReader(f))
            changes={p.relative_to(root).as_posix():p for p in targets}
            found=set()
            for row in rows:
                if row['path'] in changes:
                    p=changes[row['path']];row.update(bytes=str(p.stat().st_size),sha256=digest(p));found.add(row['path'])
            for rel,p in changes.items():
                if rel not in found:rows.append({'path':rel,'bytes':str(p.stat().st_size),'sha256':digest(p)})
            with manifest.open('w',encoding='utf-8-sig',newline='') as f:
                writer=csv.DictWriter(f,fieldnames=['path','bytes','sha256']);writer.writeheader();writer.writerows(rows)
        if before!={rel:digest(root/rel) for rel in before} or digest(frozen_path)!=freeze_digest:
            raise RuntimeError('算法或参数发生意外变化')
        (backup/'installation.json').write_text(json.dumps({'status':'PASS','patch':info['schema'],
            'algorithm_changed':False,'frozen_profile_changed':False,'gui_sha256':digest(root/'host/gui.py'),
            'backup':str(backup)},ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    except Exception:
        for p in paths:
            if existed[p]:shutil.copy2(backup/p.relative_to(root),p)
            elif p.exists():p.unlink()
        raise
    print('实拍自动定位 v4.1 安装成功。原界面和文件清单已备份到：',backup)
    print('下一步重开上位机，直接读取原始实拍图片，保持实拍自动定位勾选；先PC参考再FPGA实测。')


def main():
    cli=argparse.ArgumentParser();cli.add_argument('--project',type=Path)
    args=cli.parse_args();root=args.project
    if root is None:
        candidates=[Path.cwd(),HERE,HERE.parent,HERE.parent.parent]
        root=next((p for p in candidates if (p/'run.py').is_file() and (p/'host/gui.py').is_file()),None)
    if root is None:root=Path(input('请粘贴包含run.py的single_pc_v3文件夹完整路径：').strip().strip('"'))
    install(root)

if __name__=='__main__':main()
