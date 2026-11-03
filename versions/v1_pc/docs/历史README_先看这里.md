> 2026-10-25更新：界面修复已合并，最新60条调参与90条测试原始目录已补齐并独立复核，2517480输出像素差异0。当前状态以顶层START_HERE_交接必读.md和reports/实板批量复核报告_20261025.pdf为准。下文早期阶段说明保留作历史。

# 快递面单条码识别：A/B/C 共用电脑续做版

版本：single-pc-v3，2026-10-23。以你提供的 `handoff_20261023_official_v2.zip` 为已验收基线，结合融合创新方案及包内更详细的 `design_spec.pdf` 继续开发。A/B/C 是任务分工，同一台电脑共用这一份源码、参数和证据目录即可。

## 你现在先做什么

1. 解压到英文目录，例如 `C:\fpga_waybill\single_pc_v3`。进入同时包含 `run.py`、`host`、`official_v2` 的那层目录。
2. 在资源管理器地址栏输入 `powershell` 并回车，依次运行：

```powershell
python -m pip install -r requirements.lock.txt
python run.py selftest
python run.py gui
```

也可以在装好依赖后双击 `start_gui.bat`。现有 Python 若可安装这些依赖，无需为了角色 A/B/C 分别安装三套 Python。开发验证环境为 Python 3.12；原现场使用 Python 3.11、Vivado 2019.1，保留原 Vivado 即可。

## 界面怎么用

1. 先保持“PC参考”，点击“读取图片”。可先用 `data/formal_v3/source/shadow_03.png`。
2. 鼠标拖框选条码，保留左右安静区。示例图的条码 ROI 是 `(44,100,756,428)`；框选后右侧显示保持比例并补白的输入。
3. 期望文本可查 `data/formal_v3/manifest.csv`。这是字符串，前导零不能去掉。没有标签时可留空，仅显示解码内容。
4. 勾选“依次比较五模式”，保留“使用已冻结参数”，点击“开始处理并保存”。结果按模式分标签页显示。
5. 上板时先用 Vivado 确认 FPGA 已下载正确程序，再选“FPGA实测”和实际 COM 口。115200、8N1，不要让串口助手同时占用该端口。
6. 取消会等待当前帧处理结束再停止后续模式。关闭窗口时也会先等当前任务结束。

界面代码已完成语法检查；当前执行环境无法连接图形显示，因此Windows实际启动、摄像头和COM操作仍需在你电脑上验收，详情见 `results/gui_validation.json`。

GUI 的“PC参考”只保存 reference 图，没有 response.bin、fpga_result.png 或伪造的零差异统计。只有真实串口回包验证后才保存 FPGA 图和差异图。界面会显示状态与结果路径。

摄像头为可选依赖：

```powershell
python -m pip install -r requirements-camera.txt
python run.py gui
```

输入摄像头序号（通常0），点击预览、拍摄并冻结，再框选。相机打不开时改用文件；拍摄功能不等于已完成真实相机实验。本交付没有访问你电脑上的摄像头或串口。

## 同一台电脑的共用入口

| 命令 | 做什么 |
|---|---|
| `python run.py selftest` | 软件自检，包括所有65536种RGB565灰度编码 |
| `python run.py audit` | 重查上传的旧实板记录，不接板、不覆盖旧记录 |
| `python run.py gui` | 文件/摄像头、ROI、五模式参考或实板操作 |
| `python run.py demo` | 用已经冻结的参数运行18张测试集的PC参考 |
| `python run.py board --port COM10` | 实际开发板上的18张测试集×五模式，COM号需改为实际值 |
| `python run.py board --port COM10 --split tuning` | 实板12张调参集复核，不重新选择参数 |
| `python run.py rtl-test` | 新一轮Icarus算法和串口仿真，需iverilog/vvp |

命令可从其他工作目录调用，脚本按自身路径找文件。每次 `demo`、`offline`、`board`、GUI 和 `rtl-test` 都创建新的 `runs/时间戳_类型` 目录。请保留每次失败记录。

串口连续批量只开一个连接，一问一答，不自动重试。`board`运行约需数分钟，期间不要用其他程序打开同一COM口。返回PASS需全部记录正确；任何CRC、状态、尺寸或像素差异问题都会保存现场并中止，不用电脑结果替代。

## 当前正式协议和硬件

- 只使用正式 V2：请求 `A6 6A`、响应 `6A A6`，version=02，RAW8，模式1..5。
- RGB565像素高字节先发送；其他多字节字段小端；CRC-16/CCITT-FALSE。
- 正式已验收 bitstream：`official_v2/board_reports/uart_official_v2_top.bit`，192×96上限。该文件与上传包完全相同。
- **断电后需重新通过Vivado下载**，没有写Flash。无法从旧日志断言当前板上程序仍在。
- 不用早期 `55 AA` 客户端，也不用六模式试验版 `A5 5B` 客户端发送正式帧。
- 模式6与BIT1仍是可选增强，没有混入本次正式协议。256×128仅补了算法核仿真，没有作为已验收板级上限开放。

本轮没有改动已验收RTL，因此原bitstream可继续用于新PC工具。若要重建，在Vivado Tcl环境运行 `source tools/build_current.tcl`，或在Vivado配置好的命令行运行：

```powershell
vivado -mode batch -source tools/build_current.tcl
```

新报告和bit写入 `builds/新时间戳/`，不改旧的board_reports。当前运行环境没有Vivado，因此本轮未新构建bitstream。重建后必须核对时序/DRC并重新做板上验证。

## 数据、参数和结果

`data/formal_v3/` 为30张**合成虚构**条码数据：12张调参、18张测试，30个独立base_id；场景数量为正常5、阴影6、低照5、反光5、渐变5、噪声4。每张有源面单、准备后的ROI、对齐真值和RGB565，清单保存所有种子、退化和ROI参数。

30张干净真值在共同裁边区域都能精确解码。所有模式的主指标都在原图四边各裁7像素的同一区域计算，不直接比较不同尺寸的原生输出。

已提供冻结文件 `results/frozen_profile.json`，只用12张调参数据选择各模式参数。模式4/5调参精确识别数相同，因此暂定默认仍为模式4，需实板确认。不要用测试集反复选参数；重新实验请另建版本化的数据目录和参数文件。

- 已运行的PC独立测试：`results/offline_test_20261023/report.json`、`metrics.csv`。
- 新的RTL证据：`results/verified_rtl_20261023/`。
- 旧实板记录复核：`results/baseline_reaudit.json`。
- 完成项和剩余验收：`docs/本轮完成与下一步.md`。
- 精确接口差异：`docs/接口版本与证据口径.md`。

## 原始基线保存方式

原ZIP不改写。此续做版保留正式V2代码/bitstream/实板回包、依赖的B核、V1 UART、输入向量和正式设计PDF的原始字节；不重复带入已编译的xsim缓存、Vivado临时目录和早期55AA探索工程。

`baseline/`内保留原交接页、原SHA清单及原包1407项文件校验结果。原清单描述的是原始完整ZIP，不是此精简续做版的文件列表。续做版另有自己的 `CONTINUATION_SHA256.csv`。
