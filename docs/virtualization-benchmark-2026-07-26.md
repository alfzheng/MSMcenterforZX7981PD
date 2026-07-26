# QEMU 硬件虚拟化性能 A/B 测试

日期：2026-07-26（Asia/Shanghai）

## 结论

在本机 ZX7981PD/OpenWrt SDK 实际负载上，WHPX 硬件加速相对原 TCG
软件模拟有数量级提升：

| 测试 | TCG | WHPX | 加速比 | 耗时减少 |
|---|---:|---:|---:|---:|
| LuCI `csstidy` 冷编译 | 231.23 秒 | 15.97 秒 | 14.48× | 93.1% |
| 512 MiB SHA-256 流水线 | 6.73 秒 | 0.78 秒 | 8.63× | 88.4% |

两轮 `csstidy` 构建返回码均为 0。

## 测试方法

- 主机：AMD Ryzen 5 7640HS，Windows 11 Pro 25H2。
- QEMU：同一个 Windows QEMU 安装。
- 虚拟机：同一份 `alpine-build.qcow2`。
- 资源：4 vCPU、4096 MiB RAM、Q35、相同用户网络。
- 启动：同一份 Alpine 3.23 ISO。
- 磁盘：两轮均使用 QEMU `-snapshot`；每轮从完全相同的基础磁盘开始，
  所有写入在关机时丢弃。
- TCG：`-accel tcg,thread=multi -cpu max`。
- WHPX：`-accel whpx`。
- SDK：
  `openwrt-sdk-25.12.5-mediatek-filogic_gcc-14.3.0_musl.Linux-x86_64`。
- 构建负载：

  ```sh
  make package/feeds/luci/csstidy/host/clean
  /usr/bin/time make -j1 package/feeds/luci/csstidy/host/compile V=s
  ```

- CPU 流水线：

  ```sh
  /usr/bin/time sh -c \
    'head -c 536870912 /dev/zero | sha256sum >/dev/null'
  ```

## 原始计时

```text
BENCH_CSSTIDY label=TCG  wall=231.23 user=189.36 sys=35.04
BENCH_BUILD_RC=0
BENCH_SHA512  label=TCG  wall=6.73 user=5.07 sys=7.55

BENCH_CSSTIDY label=WHPX wall=15.97 user=11.88 sys=4.02
BENCH_BUILD_RC=0
BENCH_SHA512  label=WHPX wall=0.78 user=0.49 sys=0.58
```

本地原始串口记录：

- `.build-temp/benchmark-tcg.log`
- `.build-temp/benchmark-whpx.log`

## 解释与边界

- 14.48× 是此前最慢的 LuCI C++ 主机工具冷编译，不代表每一次完整构建都固定
  加速 14.48×。
- 已缓存且只重新打包 ucode/JavaScript/翻译资源时，绝对节省时间会较小。
- 下载速度、Windows 文件访问、SDK 元数据扫描和串行脚本不会按相同比例加速。
- TCG `-cpu max` 与 WHPX 默认虚拟 CPU 并非逐指令完全相同；这是两种实际运行
  路径的正常差异。编译输入、SDK、磁盘快照、vCPU 数和内存保持一致。
- 两轮均出现相同的 SDK feed 缺失固件/Kconfig 警告；它们不是此次基准产生的
  错误，且目标构建均成功。

## 建议

后续默认使用：

```text
-accel whpx
```

如需在 WHPX 不可用时自动回退，可配置 QEMU 先尝试 WHPX、再回退 TCG。
发布构建仍保留完整日志、SDK SHA-256、feed commit 和 APK SHA-256；硬件加速
只改变执行速度，不放宽可复现性和目标机验收门禁。
