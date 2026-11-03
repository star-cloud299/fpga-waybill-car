# AX7035B 项目交接（2026-10-23，暂停点）

请先读本页，再读 `team_v1_20261022/team_design_20261022/documents/design_spec.pdf` 第 7–9 章。此包是单机 A/B/C 共用工程的现场快照；不要把“已做的功能验证”误写成“整个比赛项目已完成”。解压后保留以下目录的相对位置。

## 当前可复现的正式 V2 基线

- 主工程：`official_v2/`。正式协议为请求帧头 `A6 6A`、响应帧头 `6A A6`、版本 02、序号、状态、尺寸/偏移、RAW8 结果及 CRC16。仅模式 1–5。串口 115200、8N1。
- 当前板级程序：`official_v2/board_reports/uart_official_v2_top.bit`。SHA-256：`FC794482F76BBF222B8E4AC96462D4332A196E6381AF522D0F9539FC0F239488`。这是易失性 FPGA 配置；断电后须重新下载。**没有写配置 Flash。**
- 当前编译上限：192×96（正式默认尺寸），支持不超过该上限的请求尺寸；方案提出的 256×128 上限尚未编译验收。50 MHz 实现后 WNS +2.334 ns、TNS 0；BRAM 26.5/50；布线错误 0。详见 `official_v2/board_reports/`。
- 串口仿真：`official_v2/sim_vectors/verified_report.json`，7 帧（五模式、坏 CRC、恢复帧），972 输出像素与整数参考一致。
- 实板五模式：`official_v2/evidence/board_sweep_20261023/report.json`，64×64 和 192×96 各五帧，10 帧总计 100,952 像素、零差异。192×96 是由 C 的 64×64 图确定性缩放的功能向量，不是正式条码识别样本。各目录含实际 `response.bin`，不是电脑合成的回包。
- 错误恢复：`official_v2/evidence/board_faults_20261023/report.json`，CRC 错误状态 3、无效模式状态 1、长度错误状态 2、字节间超时状态 4，之后均能接收好帧。停止位错误状态 5 尚未注入实测。
- 连续稳定性：`official_v2/evidence/board_100frames_20261023/report.json`，同一 COM10 连接、100 帧、无自动重试；每帧 CRC 和像素均正确。使用同一张 64×64 输入、五模式轮流；不能代替 30 张独立条码实验。100 个原始回包逐帧保存。
- 板上当前可能仍是这个 bitstream，但不能只凭本文件断言；若断过电，重新在 Vivado Hardware Manager 下载并确认 `xc7a35t_0` 为 Programmed。

## 各目录用途，切勿混用协议

- `official_v2/`：**当前正式基线**。`protocol.py` 是电脑端正式组帧/解析工具；`uart_official_v2_top.sv` 是 FPGA 顶层；`build_board.tcl` 是板级构建；`board_sweep.py`、`board_faults.py`、`board_stability.py` 是实板验证工具。
- `integration_b_v1/`：此前已实板跑通的**六模式试验版**。帧头 `A5 5B / 5B A5`，每像素 `(value, uncertain)` 两字节，**不符合正式方案 V2**；仅供比较与回退。它的 `README.md` 中单称“V2”，此处明确解释为试验版 V2，不能用其上位机解析正式回包。
- `team_v1_20261022/`：A 的 V1 原始板级基线、C 的 `request.bin/reference.pgm`、B 的原始交付包和团队正式设计 PDF。不要覆盖这些原始证据。
- `b_ooc_ascii/`：B 核独立综合/布线检查，不能代替正式顶层实现报告。
- `waybill-fpga-preprocess/`：早期独立探索工程、合成条码图和旧 PC 客户端。其帧头 `55 AA`，**不能直接连接当前正式 V2 板级程序**；原样保留供素材/算法比较。旧客户端的图像缩放尚非正式方案要求的“保持比例并补白”。

## 新电脑上先做的最短复现

1. 将压缩包解到一个无中文、无空格的工作目录，保持上述目录并列。安装 Vivado 2019.1、Python 3.11；串口运行另需 `pyserial`。本机实测板卡为 AX7035B / XC7A35T，AL321 走 JTAG，CP210x 走 UART，供电是匹配板卡的 5V 电源。接线和极性先看板卡手册，**不得把 12V 电池直接接到 5V 输入口**。
2. 在解压根目录运行 `python official_v2/prepare_sim_vectors.py`；用 Vivado 2019.1 的 `xvlog` 编译 `integration_b_v1/rtl/window_stats.sv`、`integration_b_v1/rtl/b_image_core.sv`、`official_v2/uart_official_v2_top.sv`、`team_v1_20261022/team_design_20261022/source_snapshot/rtl/uart_rx.v`、`uart_tx.v` 和 `official_v2/tb_uart_official_v2_top.sv`；再 `xelab -top tb_uart_official_v2_top -snapshot official_v2_uart_sim`、`xsim official_v2_uart_sim -runall`、`python official_v2/verify_sim.py`。最后应显示 `OFFICIAL_V2_VERIFIED`。
3. 如需重建 bitstream，在 Vivado Tcl Console 执行 `source official_v2/build_board.tcl`（建议使用绝对路径）；检查新 `board_reports/timing_routed.rpt` 与 `route_status.rpt`。构建脚本只写当前目录下的报告和 bit 文件。
4. FPGA 断电状态下核对 JTAG 排线方向，接好后再供电；Vivado Hardware Manager 识别 `xc7a35t_0`，下载 `official_v2/board_reports/uart_official_v2_top.bit`。串口设备号不一定仍是 COM10，以设备管理器实际显示为准。不要同时让 Tera Term 占用同一 COM 口。
5. 用 C 的 64×64 测试输入做一次正式协议回读：`python official_v2/protocol.py --v1-request team_v1_20261022/c_data/20261022_213852_792873/request.bin --mode 4 --sequence 1 --port COM10 --output official_v2/evidence/新的一次测试`。`--output` 必须是尚不存在的目录，避免覆盖旧证据。成功状态下应为 50×50、2500 像素、零差异。这里 V1 文件**只提供 RGB565 像素**，实际发送会重新封装成正式 V2 帧。

## 下一位接手者的优先事项

1. A/B/C 一起确认接口版本：B 核当前采用 ready/valid，每 2 个时钟左右接收一个像素；设计 PDF 原基线是每时钟 1 像素、无反压。算法数学规则已对齐，但时序接口仍需正式签收，并补首尾/换行/停顿/复位波形。
2. C 建立**正式** 30 张以上条码数据清单和 Code128 精确文本验证；12 张调参、18 张独立测试，按 `base_id` 防止同源泄漏。完成保持比例 ROI、白边补齐、RGB565 高字节先发、同一原图四边裁 7 像素的公平比较。早期 30 张合成图和旧 GUI 不可直接作为正式 V2 验收。
3. A 对 256×128 上限、UART 停止位错误状态 5、复位/残帧及不同尺寸连续输入补测；若修改 RTL，必须重建、重新下载并重跑至少 64×64、192×96、错误恢复和 100 帧。当前 100 帧只证明同一 64×64 向量下的链路稳定性。
4. C 做参数冻结、真实条码解码率/像素指标；另一名成员从干净目录独立复现。所有对外说法区分“仿真”“实板”“识别率”，不要把下载成功或像素零差异当成识别率改善。

本交接包创建后已暂停开发。若继续工作，先复制一份新的运行目录或使用新的证据目录；不要改写包内已验收的原始文件。
