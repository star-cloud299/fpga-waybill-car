# V2：两段直线智能车版（保留的 3×3 版本）

## 功能与状态

路线为 S → 80 cm → A → 80 cm → B。A 对应 `000026000003`，B 对应 `000026000008`。车载摄像头采图，FPGA 输出 HDMI 预览及 3×3 处理图，经 ESP 无线发给电脑后台核验。两个货物摆在停车位置左侧，摄像头固定朝左；标签和路线图在 `mobile_straight_demo_v1/assets/`。

这是按用户要求保留的版本，没有纳入已取消的同步控制和 15×15 更新。已记录预览、采图、起步及 Flash 编程/校验；左右轮停止不同步、偏转和 COMM ERROR 仍待解决，整条两站路线未验收。整理上传副本没有改变运动、图像或通信逻辑，也没有更新硬件。

## 电脑后台

在当前 `versions/v2_car` 目录打开 PowerShell：

```powershell
py -3.12 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r mobile_straight_demo_v1/host/requirements.txt
.\.venv\Scripts\python.exe mobile_straight_demo_v1/host/app.py --autostart
```

电脑与 ESP 使用同一个可互通的 2.4 GHz Wi-Fi；后台监听 TCP 8266，ESP 的目标地址须使用该电脑当前 IPv4。电脑地址改变后须重新配置 ESP。仓库没有携带热点密码或原设备网络配置。`runtime.py` 中的旧 `.deps312` 搜索路径不存在时，会使用正常安装的 Python 包。

原 `START_BACKEND.cmd` 优先使用原作者本机的 Python 环境；在其他电脑推荐上面的虚拟环境命令。

## FPGA 重建

请保持这三个目录同级：

```text
mobile_straight_demo_v1/
standalone_mobile_v1/vendor_snapshot/
waybill_standalone_handoff_20261101/waybill_final/.../source_snapshot/rtl/uart_rx.v
```

Vivado 2019.1，器件 `xc7a35tfgg484-2`；在当前目录执行（Vivado 已在 PATH 时）：

```powershell
vivado -mode batch -source mobile_straight_demo_v1/build_straight.tcl
```

输出 `mobile_straight_demo_v1/build/straight_demo_ax7035b.bit`。构建 Tcl 只综合、实现和生成文件，不操作硬件。复制时已核对所需 RTL/VHDL/XDC 和相对依赖；本次整理未重新运行 Vivado 或实车测试。历史 `motion/run_sim.ps1` 内的 Vivado 安装路径须按本机修改。

## 已有固件

从 `v2.0-car` Release 下载 `waybill_car_v2_source_firmware_20261104.zip`。它含与仓库对应的源码和：

- `versions/v2_car/mobile_straight_demo_v1/build/straight_demo_ax7035b.bit`
- `versions/v2_car/mobile_straight_demo_v1/boot/straight_demo_spix1_16MiB.mcs`

BIT SHA256：`21891a48290aab242f8b4edabf172b59d89de85d82b48109fab7632e6d78f073`

MCS SHA256：`2f24e09efe61edc714666899cc2995665abee53a59c1a1fa440c433abcbd761e`

仅适用于对应硬件和引脚。`program_sram.tcl -tclargs straight` 为手动 SRAM 下载入口；它会操作硬件。Flash 固化建议用 Vivado Hardware Manager 按实际板载 Flash 选择器件；本次上传不执行任何下载。

历史 Flash 脚本锁定原板备份与旧构建日志，历史 ESP 恢复脚本绑定原电脑/旧串口桥，未把它们作为通用启动入口收入本目录。原完整交接档仍在原目录保存。ESP 初次 AT 配置需要可用的串口桥或 USB-TTL，不能仅运行后台代替。

## 上电与运行

原接线中相机和 ESP 均由 D153C 驱动板供电，关闭驱动板 12V 会使相机和无线一起断电。正常启动先打开驱动板/相机/ESP 电源，等约 5 秒，再打开稳定的 FPGA 5V 电源。等待 HDMI 实时画面与后台新一轮 `0/2` 待命后，KEY1 启动，KEY2 停止。实车存在上述已知问题，当前版本状态按记录保留。
