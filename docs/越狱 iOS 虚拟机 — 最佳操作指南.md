
## 越狱 iOS 虚拟机 — 最佳操作指南

### 0. 前提条件

**硬件/系统要求：**
- Apple Silicon Mac（macOS 14+ Sequoia）
- 足够磁盘空间（IPSW ~20GB + VM 磁盘 64GB）

**安全设置（重启到恢复模式）：**
```bash
# 长按电源键进入恢复模式，打开终端
csrutil disable
csrutil allow-research-guests enable
# 重启后
sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
# 再重启一次
```

**Homebrew 依赖：**
```bash
brew install gnu-tar openssl@3 ldid-procursus sshpass keystone autoconf automake pkg-config libtool git-lfs zstd
```

**Git LFS（必须在 clone 后执行）：**
```bash
git lfs install
git lfs pull
```

---

### 方式一：一键自动化（推荐）

```bash
make setup_machine JB=1
```

这条命令自动执行以下全部步骤，唯一需要手动的是**首次启动时在 VM 控制台输入初始化命令**（脚本会提示你）。

---

### 方式二：手动分步操作

适合需要调试或定制的场景。需要 **3 个终端窗口**。

#### 阶段 1 — 构建环境 & 准备固件

```bash
# 一次性工具安装
make setup_tools
source .venv/bin/activate

# 构建 vphone-cli
make build

# 创建 VM 目录（64GB 稀疏磁盘 + ROM + SEP）
make vm_new

# 下载 iPhone + cloudOS IPSW，合并生成混合固件
make fw_prepare

# 打 JB 补丁（先自动执行基础 41+ 处补丁，再叠加 JB 补丁）
make fw_patch_jb
```

> `fw_patch_jb` 补丁 3 个额外组件：iBSS（nonce 跳过）、TXM（5 个安全绕过）、KernelCache（24+ 个安全绕过）

#### 阶段 2 — DFU 刷写固件

```bash
# ═══ 终端 1（保持运行）═══
make boot_dfu
```

```bash
# ═══ 终端 2 ═══
make restore_get_shsh    # 获取 SHSH blob
make restore             # idevicerestore 刷写固件（耗时较长）
```

刷写完成后，在终端 1 按 `Ctrl+C` 停止 DFU。

#### 阶段 3 — Ramdisk + CFW 安装

```bash
# ═══ 终端 1（重新启动 DFU）═══
make boot_dfu
```

```bash
# ═══ 终端 2 ═══
make ramdisk_build       # 构建签名的 SSH ramdisk
make ramdisk_send        # 发送 ramdisk 到 VM
```

等待终端 1 输出 `Running server` 后：

```bash
# ═══ 终端 3（保持运行，iproxy 隧道）═══
iproxy 2222 22
```

```bash
# ═══ 终端 2 ═══
make cfw_install_jb      # 安装 CFW + JB 扩展（共 10 个阶段）
```

> `cfw_install_jb` = 基础 7 阶段 + JB 3 阶段：
> - **JB-1:** 补丁 launchd（注入 `launchdhook.dylib` + jetsam guard 绕过）
> - **JB-2:** 安装 procursus bootstrap（包管理系统）到 `/mnt5/<boot_hash>/jb-vphone/`
> - **JB-3:** 部署 BaseBin hooks（`systemhook.dylib`, `launchdhook.dylib`, `libellekit.dylib`）到 `/mnt1/cores/`

完成后 VM 会自动 halt。终端 1 按 `Ctrl+C`，终端 3 也可以关掉。

#### 阶段 4 — 首次启动（初始化 SSH 密钥）

```bash
make boot
```

看到 `bash-4.4#` 提示符后，在 VM 控制台输入：

```bash
export PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/bin/X11:/usr/games:/iosbinpack64/usr/local/sbin:/iosbinpack64/usr/local/bin:/iosbinpack64/usr/sbin:/iosbinpack64/usr/bin:/iosbinpack64/sbin:/iosbinpack64/bin'

mkdir -p /var/dropbear
cp /iosbinpack64/etc/profile /var/profile
cp /iosbinpack64/etc/motd /var/motd

# 生成 SSH 主机密钥（必须，否则 SSH 会立即断开）
dropbearkey -t rsa -f /var/dropbear/dropbear_rsa_host_key
dropbearkey -t ecdsa -f /var/dropbear/dropbear_ecdsa_host_key

shutdown -h now
```

#### 阶段 5 — 正式使用

```bash
# 启动 VM（GUI 窗口）
make boot
```

另开终端建立隧道：

```bash
iproxy 22222 22222   # SSH
iproxy 5901 5901     # VNC
```

连接方式：
- **SSH:** `ssh -p 22222 root@127.0.0.1`（密码 `alpine`）
- **VNC:** `vnc://127.0.0.1:5901`
- **安装 IPA:** `make boot BOOT_ARGS="--install-ipa /path/to/app.ipa"` 或菜单栏 Connect → Install IPA

---

### 完整流程时序图

```
                    终端 1              终端 2              终端 3
                    ──────              ──────              ──────
阶段 1              ┌─────────────────────────┐
(构建/准备)         │ make setup_tools        │
                    │ make build              │
                    │ make vm_new             │
                    │ make fw_prepare         │
                    │ make fw_patch_jb        │
                    └─────────────────────────┘

阶段 2              ┌──────────┐        ┌──────────────────┐
(DFU 刷写)          │boot_dfu  │───────▶│restore_get_shsh  │
                    │(保持运行) │        │restore           │
                    │ Ctrl+C   │◀───────│                  │
                    └──────────┘        └──────────────────┘

阶段 3              ┌──────────┐        ┌──────────────────┐  ┌──────────┐
(Ramdisk/CFW)       │boot_dfu  │───────▶│ramdisk_build     │  │          │
                    │(保持运行) │        │ramdisk_send      │  │iproxy    │
                    │          │        │  等 Running server│─▶│2222 22   │
                    │          │        │cfw_install_jb     │  │(保持运行) │
                    │ Ctrl+C   │◀───────│  (10 阶段完成)    │  │  关闭    │
                    └──────────┘        └──────────────────┘  └──────────┘

阶段 4              ┌──────────────────────────┐
(首次启动)          │ make boot                │
                    │ → 输入初始化命令          │
                    │ → shutdown -h now         │
                    └──────────────────────────┘

阶段 5              ┌──────────┐                              ┌──────────┐
(正式使用)          │make boot │                              │iproxy    │
                    │(GUI 窗口) │◀─── SSH/VNC ──────────────▶ │22222/5901│
                    └──────────┘                              └──────────┘
```

### JB vs 非 JB 关键差异

| 维度 | 非 JB | JB |
|---|---|---|
| 固件补丁命令 | `make fw_patch` | `make fw_patch_jb` |
| CFW 安装命令 | `make cfw_install` | `make cfw_install_jb` |
| 内核补丁数 | 25 | 25 + ~24 |
| TXM 补丁数 | 1 | 1 + 5 |
| CFW 安装阶段 | 7 | 7 + 3（JB-1/2/3）|
| launchd | 未修改 | dylib 注入 + jetsam 绕过 |
| 包管理器 | 无 | procursus（可选 Sileo）|
| 内核能力 | 基础虚拟化 | task_for_pid / RWX 内存 / 沙箱绕过 / AMFI 绕过 / 调试器附加 |

### 常见问题

1. **`zsh: killed ./vphone-cli`** → AMFI 未禁用，检查 `boot-args`
2. **SSH 连接后立即断开** → 首次启动时没生成 dropbear 密钥，回到阶段 4 操作
3. **卡在 "Press home to continue"** → VNC 连接后右键点击屏幕（模拟 Home 键）
4. **`cfw_jb_input` 找不到** → 确保执行过 `git lfs pull`，资源文件 `cfw_jb_input.tar.zst` 在 `scripts/resources/` 下
5. **想换 iOS 版本** → 设置 `IPHONE_SOURCE` 和 `CLOUDOS_SOURCE` 环境变量后重新 `make fw_prepare` + `make fw_patch_jb`