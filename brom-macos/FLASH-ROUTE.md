# 荣悦 E5 · macOS BROM 全链路刷机路线（实测可行）

> 2026-11-21 在一台 RongYue E5（Unisoc ums9158_1h10，TS305_V03_20260113_2322，
> Android 13）上全程跑通：**BROM 备份 → 官改 V4 → Magisk root → e5-sleep16 OpenWrt**。
> 本文档是可复现的步骤与踩坑记录；配套补丁和脚本在本目录。
> 本仓库是 [CharlesGool/e5-openwrt-flasher](https://github.com/CharlesGool/e5-openwrt-flasher)
> 的 fork，`brom-macos/` 为本 fork 新增内容。

## 为什么必须走 BROM

- 系统"OEM 解锁"开关被厂商 AIDL HAL + NV 锁焊死（点了自动弹回）；
- fastboot 在原厂 LK 下不可用；
- BROM（芯片里的掩膜 ROM 产线维修模式）是唯一不校验上层签名的入口——
  但它只运行**带工厂签名的 FDL**。

## 0. 材料（vendor/ 目录，不进 git）

```
vendor/
  e5-rom-share/            原厂 pac（2.9GB）+ 官改 V4 原始 7z
  official-mod-v4/         V4 解包（31 个镜像、Magisk apk、.bat 脚本）
  spd_dump-macos/          macOS 刷机工具（含本仓库补丁，见 brom-macos/*.patch）
  brom-work/backup/        本机 56 分区备份（prodnv 等独有数据，务必保管）
  brom-work/               follow 脚本、ops 序列、magisk_patched.img
  e5-sleep16/              OpenWrt 安装包
```

## 1. 进入 BROM

关机 → 取电池 10 秒装回 → **按住右侧横杠软键**插 USB → 进门后可松手
（FDL2 在 RAM 运行）。约 20 秒应答窗口。USB 必须直连（C to C 可以）。

## 2. 取出签名 FDL（CVE 路线在本机不可用的替代）

本机 BROM 对 CVE-2022-38694 的 blob 落地即僵死（活帧区间被砸坏），
官改包自带的未签名 fdl1-dl.bin 被 ACK 但静默不跑。**唯一可行入口**是原厂
pac 里的工厂签名件：

- pac 条目步长 `0xA14`；name@N、filename@N+0x200、size@N+0x600、
  data-offset@N+0x60c、load-addr@N+0x618
- 提取 `fdl1-sign.bin`(61576B) 与 `fdl2-sign.bin`(1110280B)，放
  `spd_dump-macos/` 下，用 `FDL1=fdl1-sign.bin FDL2=fdl2-sign.bin EXEC_ADDR=none
  ./scripts/runner.sh` 装载

## 3. 备份（不可跳过）

`follow-backup.sh`：生成并执行全分区读取计划。注意：
- `nr_fixnv1_a/b` 的**名字读取会挂死 FDL2**，跳过（读孪生 fixnv2）
- super 可不备（原厂 pac 里有同版本）

## 4. 刷官改 V4 —— 与签名 FDL2 的 AVB 保护搏斗

### 现象（很有迷惑性）

对 `init_boot_a / boot_a / vendor_boot_a / vbmeta_*` 写入时，**无论镜像多长，
总在"最后一块 4KB MIDST"被拒**（回 0xffffffff），随后 END_DATA 超时、会话死亡。
截短镜像无效——还是死在自己（变短后）的最后一块。其余分区（misc/dtb/
trustos/uboot/…哪怕恰好写满分区）全部正常。

### 根因

签名 FDL2 对 AVB 链分区做**完成时校验**：接收完最后一块才触发，拒绝即断连。
另外读回证实：即便写入"成功"，FDL2 也会**把 vbmeta 头 0x7B 的 flags 字节强制
清零**（大端 3 = 解除校验，是它重点照顾的对象）。

### 破解：SPD_WRITE_LIE（本路线核心增量）

`spd_dump.c` 的 `load_partition()` 打两个补丁（见 spd_dump-macos-changes.patch）：

1. `SPD_WRITE_LIE=1` 时 START_DATA **谎报 len+0x1000**——镜像里任何一块
   （包括最后一块）都不是"完成块"，保护永不触发，所有块 ACK 落盘；
2. END_DATA 对 0x84（长度不符）**容忍不退出**，批次继续下一个分区。

配套 `flash_ops_trunc.txt`：AVB 镜像截去尾部填充（boot 链镜像末尾只有零 +
AVBf footer；vbmeta 只写 struct 头部，`struct_end = 256+auth+aux`，头字段是
**大端**——打 flags 补丁必须写 BE，LE 写法等于没改）。super 尾块为全零，
截 4KB 安全。

执行（`follow-flash.sh`，自动喂确认）：

```sh
cd vendor/spd_dump-macos
EXEC_ADDR=none FDL1=fdl1-sign.bin FDL2=fdl2-sign.bin \
  FOLLOW=../brom-work/follow-flash.sh ./scripts/runner.sh
```

## 5. Magisk root

刷完 V4 重启即 orange（`ro.boot.verifiedbootstate=orange`，解锁 LK 自带
解 AVB，vbmeta flags=0 也不影响）：

1. `adb install` V4 包里的 Magisk_28103；把 V4 的 `init_boot_a.bin` 推到
   **`/sdcard/Download/`**（Magisk 选择器够不到 /data/local/tmp）
2. 设备上：Magisk → 安装 → **选择并修补一个文件** → Download/init_boot_a.img
3. `adb pull /sdcard/Download/magisk_patched-*.img`
4. `adb reboot bootloader && fastboot flash init_boot_a <patched>` ——解锁 LK
   的 fastboot 通畅，0.5 秒写完，**无需再进 BROM**
5. 首次 `adb shell su -c id` 弹授权框，点允许（建议勾记住）

## 6. OpenWrt（e5-sleep16）

```sh
cd vendor/e5-sleep16/Openwrt_E5_Flasher_sleep16
bash install-userdata.sh -y     # 后台/无 tty 必须带 -y，否则确认读 EOF 中止
```

流程：校验 → 从本机提取 Wi-Fi/蓝牙/音频固件（含本机蓝牙地址）→ 上传镜像
→ 写 /data/e5linux/openwrt.ext4 → boot_b 写入并校验 → 手动重启进 OpenWrt。
首次启动约 2 分钟；启动失败两次自动回 Android。

- LuCI：http://192.168.9.1（root/root，先改密码）
- 热点：E5-OpenWrt
- E5 的 Type-C 同时是 USB 网卡（NCM），Mac 直连即 192.168.9.2

## 7. 踩坑速查

| 症状 | 原因 / 处置 |
|---|---|
| 写 AVB 分区死在最后 4KB（0xffffffff） | 签名 FDL2 完成时校验，用 SPD_WRITE_LIE |
| END_DATA 回 0x84 | 长度谎报的预期回包，容忍即可 |
| 读 `nr_fixnv1_*` 挂死 | FDL2 不认这名字，跳过 |
| 官改 fdl1-dl.bin ACK 但不跑 | BROM 拒未签名，改用 pac 里的签名 FDL |
| vbmeta 解校验"没生效" | flags 是大端；且签名 FDL2 会清零它——靠解锁 LK，别指望 flags |
| spd_dump 参数文件重复传 `--wait` 前缀 | 会 "unknown command"，只传 $(cat ops) |

## 本目录文件

- `spd_dump-macos-changes.patch` —— 工具全部增量（exec2 调参、FDL 环境变量、
  checkbaud 超时、SPD_WRITE_LIE、flash_gen.py 修复）
- `follow-flash.sh` / `follow-backup.sh` —— BROM 探测成功后自动续跑的脚本
- `flash_ops_trunc.txt` —— 实测成功的刷写序列（15 写 + 3 擦 + reset）
- `backup_args.txt` —— 备份读取序列样例
