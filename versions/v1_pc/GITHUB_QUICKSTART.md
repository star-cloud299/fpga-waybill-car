# V1：电脑联机图像处理版

此目录从 `waybill_complete_final_20261026.zip` 选取重建和演示所需文件，源文件逐字节保留。原始完整 ZIP 建议另放 GitHub Releases。历史 README 和 baseline 中的清单描述原完整交接包，不等同于当前裁剪目录。

在本目录打开 PowerShell，执行：

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.lock.txt
.\.venv\Scripts\python.exe tools/foundation.py gui-basic
```

如需原实拍/自动 ROI 界面，使用：

```powershell
.\.venv\Scripts\python.exe run.py gui
```

电脑文件选图不要求连接板卡；真正的板端处理需要连接对应 FPGA 位流与串口。模式和验证边界见原版说明。

Python 依赖版本由 `requirements.lock.txt` 固定。`data/formal_v3` 是程序生成的合成条码样例，整目录与 `results/frozen_profile.json` 配套，不能随意删除或重新生成；配置会核对数据、算法源文件和依赖版本。不要运行历史完整包安装/全清单校验入口，裁剪目录不包含所有旧证据文件。冻结样例仍可用于 GUI 和图像流程。

Vivado 2019.1 重建（Vivado 已在 PATH 时）：

```powershell
vivado -mode batch -source tools/build_current.tcl
```

生成到 `builds/<时间戳>/`，该命令不会自动下载 FPGA 或写 Flash。第三方及原作者信息保留在原文件中。
