# 保留上一次两段直线3×3版本

用户于2026-11-04明确取消新更新。当前源码、后台恢复为两段直线S→80cm→A→80cm→B，3×3自适应二值化，两个货物映射不变。

原位流：build/straight_demo_ax7035b.bit；原MCS：boot/straight_demo_spix1_16MiB.mcs。两者SHA保持已固化版本不变；Flash此前program/verify/JTAG重载通过。本次取消和恢复没有操作FPGA硬件。

未部署的同步控制、15×15与新诊断版本已完整另存到相邻目录mobile_straight_sync15_saved_20261104；不要自动部署。原实拍记录继续保留在runs/。

后台入口host/START_BACKEND.cmd，已恢复3×3模式，与板上原版本匹配。用户之前报告的偏转与COMM ERROR没有因本次恢复而被解决，整条路线仍未标记实车验收通过。
