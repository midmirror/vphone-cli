# PRD：vPhone GUI — iOS 虚拟机图形化管理工具

## 引言

在现有 `vphone-cli` 仓库内新建一个独立的 SwiftUI macOS 应用目标（`vphone-app`），将当前需要通过多个终端窗口、多条 `make` 命令手动执行的 iOS 虚拟机创建、固件准备、刷写、越狱、启动等流程，封装为直观的图形化操作界面。支持一键自动化和分阶段手动操作，支持越狱/非越狱两种模式，支持同时运行多个 VM 实例且互不冲突。

**核心问题：** 当前 CLI 工作流需要 3 个终端窗口配合、记忆大量命令和操作顺序，对用户门槛高、容易出错。GUI 应用将这些操作可视化，降低使用难度。

**技术路线：**
- 纯 SwiftUI（macOS 15+）
- 在 `vphone-cli` 仓库内作为新的 SPM target，复用现有 `VPhoneVirtualMachine`、`VPhoneControl`、`VPhoneWindowController` 等模块
- 固件准备/补丁等步骤通过后台调用 `make` 命令执行，GUI 解析输出显示进度 + 日志面板
- 假设 `make setup_tools` 已完成，一键自动化从 `build` 开始覆盖全流程

## 目标

- 提供 Docker Desktop 风格的 VM 管理界面（左侧列表 + 右侧详情/操作面板）
- 支持一键自动化创建并启动 VM（从 build → vm_new → fw_prepare → fw_patch → restore → ramdisk → cfw → 首次启动）
- 支持分阶段手动执行每个步骤，每个阶段可单独触发和重试
- 支持越狱（JB）和非越狱两种模式，在创建 VM 时选择
- 支持同时管理和运行多个 VM 实例，每个 VM 拥有独立目录和配置
- 实时显示命令执行日志和进度状态
- 复用现有 `vphone-cli` 的 VM 运行时能力（屏幕显示、触控、菜单、文件浏览等）

## 用户故事

### US-001: SPM 多目标项目结构搭建

**描述：** 作为开发人员，我需要在现有仓库中建立新的 `vphone-app` target，使 GUI 应用和 CLI 共享核心模块代码。

**验收标准：**
- [ ] `Package.swift` 新增 `vphone-app` 可执行目标，与 `vphone-cli` 并存
- [ ] 将可复用模块（`VPhoneVirtualMachine`、`VPhoneControl`、`VPhoneHardwareModel`、`VPhoneError`、`VPhoneWindowController`、`VPhoneVirtualMachineView`、`VPhoneKeyHelper`、`VPhoneLocationProvider`、`VPhoneScreenRecorder`、`VPhoneSigner`、`VPhoneIPAInstaller`、`VPhoneFileBrowserView`、`VPhoneFileBrowserModel`、`VPhoneRemoteFile`、`VPhoneFileWindowController`、`VPhoneMenuController` 及其子模块）提取到共享 library target（如 `VPhoneCore`）
- [ ] `vphone-cli` 和 `vphone-app` 均依赖 `VPhoneCore`
- [ ] `swift build` 可同时构建两个目标且无编译错误
- [ ] 类型检查通过

### US-002: VM 配置数据模型与持久化

**描述：** 作为用户，我希望创建的 VM 配置能持久化存储，重启应用后仍能看到之前创建的 VM 列表。

**验收标准：**
- [ ] 定义 `VMInstance` 数据模型，包含：唯一 ID、用户自定义名称、VM 目录路径、模式（JB/非 JB）、CPU 核心数、内存大小（MB）、磁盘大小（GB）、创建时间、当前阶段状态（未初始化/固件已准备/已刷写/已安装 CFW/可启动/运行中）
- [ ] 定义 `VMStore`（`@Observable`）管理 VM 列表的增删改查
- [ ] 使用 JSON 文件持久化到 `~/.vphone/vms.json`，应用启动时自动加载
- [ ] 每个 VM 的目录默认为 `~/.vphone/instances/<vm-id>/`
- [ ] 类型检查通过

### US-003: 应用主窗口 — 侧边栏 VM 列表

**描述：** 作为用户，我希望在应用左侧看到所有 VM 实例的列表，包含名称、模式标签和运行状态。

**验收标准：**
- [ ] 左侧 `NavigationSplitView` 侧边栏显示 VM 列表
- [ ] 每个 VM 行显示：名称、模式标签（JB 红色 / 非 JB 蓝色）、状态指示器（圆点：灰色=停止、绿色=运行中、黄色=操作中）
- [ ] 列表底部有「+」按钮用于创建新 VM
- [ ] 支持右键菜单：重命名、删除（需确认弹窗）
- [ ] 选中某个 VM 后右侧显示对应详情面板
- [ ] 无 VM 时右侧显示空状态引导（"点击 + 创建你的第一个虚拟 iPhone"）
- [ ] 类型检查通过

### US-004: 创建新 VM 向导

**描述：** 作为用户，我希望通过简单的向导创建新 VM，选择模式和配置参数。

**验收标准：**
- [ ] 点击「+」弹出 Sheet 向导，包含：VM 名称输入框、模式选择（越狱 / 非越狱 单选）、CPU 核心数（Stepper，默认 8）、内存大小（Picker：2048/4096/8192 MB，默认 4096）、磁盘大小（Picker：32/64/128 GB，默认 64）
- [ ] 可选：自定义 IPSW 源路径（iPhone IPSW + cloudOS IPSW，留空则使用默认）
- [ ] 点击「创建」后将 VM 配置写入 `VMStore`，状态设为「未初始化」
- [ ] VM 名称不能为空，不能与已有 VM 重名
- [ ] 类型检查通过

### US-005: Shell 命令执行引擎

**描述：** 作为开发人员，我需要一个后台命令执行器，能运行 `make` 命令并实时捕获 stdout/stderr 输出，供 GUI 显示。

**验收标准：**
- [ ] 实现 `ShellExecutor` 类，支持异步执行 shell 命令
- [ ] 使用 `Process` + `Pipe`，通过 `AsyncStream` 实时逐行输出日志
- [ ] 支持取消正在执行的命令（发送 SIGTERM）
- [ ] 正确设置工作目录（`cwd`）和环境变量（`PATH` 包含 `.tools/bin`、`.limd/bin`、`.venv/bin`）
- [ ] 命令完成后返回退出码，非零退出码标记为失败
- [ ] 支持串行执行命令队列（前一个成功后才执行下一个）
- [ ] 类型检查通过

### US-006: VM 详情面板 — 分阶段操作视图

**描述：** 作为用户，我希望在选中 VM 后看到清晰的操作阶段列表，每个阶段都能单独触发执行。

**验收标准：**
- [ ] 右侧详情面板顶部显示 VM 名称、模式标签、当前状态
- [ ] 中间区域按顺序展示 6 个操作阶段卡片（非 JB 模式）或 6 个操作阶段卡片（JB 模式，其中 fw_patch 和 cfw_install 替换为 JB 版本）：
  1. **构建** — `make build`（+ `make vphoned`）
  2. **创建 VM 目录** — `make vm_new VM_DIR=<vm_dir>`
  3. **准备固件** — `make fw_prepare`（+ 可选自定义 IPSW 路径）
  4. **补丁固件** — `make fw_patch` 或 `make fw_patch_jb`
  5. **刷写固件** — 包含 `boot_dfu`（后台）+ `restore_get_shsh` + `restore`
  6. **Ramdisk + CFW** — 包含 `boot_dfu` + `ramdisk_build` + `ramdisk_send` + `iproxy 2222 22` + `cfw_install` 或 `cfw_install_jb`
- [ ] 每个阶段卡片显示：阶段名称、简要说明、状态标签（待执行/执行中/已完成/失败）、执行按钮
- [ ] 已完成的阶段显示绿色勾号，失败的阶段显示红色叉号和「重试」按钮
- [ ] 未满足前置条件的阶段按钮置灰且显示提示（如"请先完成固件准备"）
- [ ] 类型检查通过

### US-007: 一键自动化执行

**描述：** 作为用户，我希望点击一个按钮就能从头到尾自动完成所有阶段，无需手动逐步操作。

**验收标准：**
- [ ] 详情面板顶部有「一键设置」按钮（仅在 VM 状态为「未初始化」或中间失败状态时可用）
- [ ] 点击后按顺序自动执行所有阶段（构建 → 创建 VM → 准备固件 → 补丁 → 刷写 → Ramdisk+CFW）
- [ ] 自动处理多终端协调逻辑（如 DFU 启动需保持运行、同时执行 restore；ramdisk 阶段需要 iproxy 隧道）
- [ ] 任一阶段失败时自动停止，标记失败阶段，用户可从失败处「继续」
- [ ] 自动化执行期间显示当前正在执行的阶段和总体进度（如 "3/6 准备固件..."）
- [ ] 类型检查通过

### US-008: 日志面板

**描述：** 作为用户，我希望看到命令执行的实时日志输出，方便排查问题。

**验收标准：**
- [ ] 详情面板底部有可展开/收起的日志区域
- [ ] 实时显示当前执行命令的 stdout + stderr 输出，自动滚动到底部
- [ ] 不同阶段的日志以分隔线或标题区分
- [ ] 支持复制日志文本
- [ ] 日志区域可手动向上滚动查看历史，滚动时暂停自动滚动
- [ ] 类型检查通过

### US-009: 启动 VM 与屏幕窗口

**描述：** 作为用户，完成所有设置阶段后，我希望点击「启动」按钮启动 VM 并看到 iOS 屏幕窗口。

**验收标准：**
- [ ] VM 完成所有设置阶段后（状态为「可启动」），详情面板顶部出现「启动」按钮
- [ ] 点击启动后，调用现有 `VPhoneVirtualMachine` + `VPhoneControl` 创建 VM 实例
- [ ] 复用现有 `VPhoneWindowController` 弹出 VM 屏幕窗口（含触控、菜单栏、Home 按钮工具栏）
- [ ] VM 运行期间侧边栏状态指示器变为绿色
- [ ] 支持「停止」按钮优雅关闭 VM
- [ ] VM 窗口关闭时自动清理资源，状态回到「可启动」
- [ ] 类型检查通过

### US-010: 多 VM 实例并行运行

**描述：** 作为用户，我希望同时启动多个 VM（越狱和非越狱混合），它们之间不冲突。

**验收标准：**
- [ ] 每个 VM 使用独立的目录（ROM/Disk/NVRAM/SEP 均在各自目录下），无文件共享冲突
- [ ] 每个 VM 的 vsock 控制通道独立（端口 1337 是 vsock 端口，虚拟化框架自动隔离，无需额外处理）
- [ ] 每个运行中的 VM 有独立的屏幕窗口，窗口标题包含 VM 名称
- [ ] iproxy 隧道为每个 VM 分配不同的本地端口（如 VM-1 用 22222/5901，VM-2 用 22223/5902），端口信息在详情面板中显示
- [ ] 侧边栏能同时显示多个 VM 为「运行中」状态
- [ ] 关闭一个 VM 不影响其他运行中的 VM
- [ ] 类型检查通过

### US-011: 首次启动初始化自动化

**描述：** 作为用户，我不想在首次启动时手动输入 SSH 密钥生成命令，希望 GUI 自动处理。

**验收标准：**
- [ ] 首次启动（CFW 安装完成后的第一次 boot）时，GUI 检测到 VM 处于「需要初始化」状态
- [ ] 通过 VM 控制台（串口/PL011）自动注入初始化命令（export PATH → mkdir → cp → dropbearkey → shutdown）
- [ ] 自动注入完成后等待 VM 关机，然后将状态更新为「可启动」
- [ ] 如果自动注入失败，回退为提示用户手动操作并提供命令文本的复制按钮
- [ ] 类型检查通过

### US-012: DFU 多终端协调逻辑

**描述：** 作为开发人员，我需要实现 DFU 启动+刷写/ramdisk 的多进程协调，因为 DFU 需要保持运行的同时在另一个进程执行操作。

**验收标准：**
- [ ] 实现 `DFUCoordinator` 类管理 DFU 相关的多进程编排
- [ ] 刷写阶段：先启动 `boot_dfu` 进程（保持运行），等 DFU 就绪后启动 `restore_get_shsh` → `restore`，restore 完成后终止 DFU 进程
- [ ] Ramdisk 阶段：启动 `boot_dfu`，等就绪后执行 `ramdisk_build` → `ramdisk_send`，检测到 `Running server` 输出后启动 `iproxy 2222 22`，然后执行 `cfw_install`/`cfw_install_jb`，完成后依次终止 iproxy 和 DFU 进程
- [ ] 所有子进程的 stdout/stderr 汇聚到日志面板
- [ ] 任一子进程异常退出时，自动终止其他关联进程并报告失败
- [ ] 类型检查通过

### US-013: 应用入口与窗口管理

**描述：** 作为用户，我希望应用启动后直接显示管理主窗口，在 Dock 中有图标，支持标准 macOS 窗口行为。

**验收标准：**
- [ ] 使用 SwiftUI `@main` `App` 协议作为入口
- [ ] `LSUIElement` 设为 `false`（在 Dock 显示图标）
- [ ] 主窗口为 `NavigationSplitView`，支持 macOS 标准窗口操作（缩放/最小化/全屏）
- [ ] 应用菜单栏包含标准菜单（vPhone/Edit/Window/Help）
- [ ] 类型检查通过

## 功能需求

- **FR-1：** 系统必须支持在同一仓库内作为独立 SPM target 构建，不破坏现有 `vphone-cli` 功能
- **FR-2：** 系统必须支持创建新 VM 实例，每个实例拥有独立目录、独立配置
- **FR-3：** 系统必须支持越狱和非越狱两种模式，在创建 VM 时选择，后续操作阶段自动使用对应的 make 目标（`fw_patch` vs `fw_patch_jb`、`cfw_install` vs `cfw_install_jb`）
- **FR-4：** 系统必须支持按顺序展示 6 个操作阶段，每个阶段可独立触发，已完成阶段可跳过
- **FR-5：** 系统必须支持一键自动化执行所有阶段，从构建到首次启动完全自动化
- **FR-6：** 系统必须通过 `Process` 后台调用 `make` 命令执行固件准备、补丁、刷写等操作，实时捕获输出
- **FR-7：** 系统必须正确处理 DFU 多进程协调（DFU 后台保持 + 前台操作 + iproxy 隧道）
- **FR-8：** 系统必须支持同时启动多个 VM 实例，每个 VM 使用独立文件目录和独立的 iproxy 端口映射
- **FR-9：** 系统必须复用现有 `VPhoneVirtualMachine`、`VPhoneControl`、`VPhoneWindowController` 等模块启动和显示 VM
- **FR-10：** 系统必须将 VM 列表和配置持久化到磁盘，应用重启后恢复
- **FR-11：** 系统必须在日志面板实时显示命令输出，支持查看历史日志
- **FR-12：** 系统必须在首次启动时自动通过串口注入 SSH 密钥初始化命令

## 非目标

- **不** 重写固件准备/补丁的 Shell/Python 脚本为 Swift 原生代码（通过后台调用 make 命令实现）
- **不** 实现 `make setup_tools` 的自动化（假设用户已完成基础工具安装）
- **不** 实现 SIP/AMFI 的自动禁用（需要用户手动在恢复模式下操作）
- **不** 支持 iOS 版本的在线搜索和下载（用户需提供 IPSW 路径或使用默认版本）
- **不** 实现 VM 快照/克隆功能
- **不** 实现远程 VM 管理（仅本地）
- **不** 替换或移除现有 `vphone-cli` 命令行功能

## 设计考量

### UI 布局参考

```
┌─────────────────────────────────────────────────────────┐
│  vPhone                                                  │
├──────────────┬──────────────────────────────────────────┤
│              │  iPhone-Dev (JB)                    [🟢]  │
│  📱 iPhone-1 │  ─────────────────────────────────────── │
│     🟢 运行中 │  [一键设置]  [启动]  [停止]              │
│              │                                          │
│  📱 iPhone-2 │  ┌─ 阶段 ─────────────────────────────┐ │
│     ⚫ 已停止 │  │ ✅ 1. 构建           [已完成]      │ │
│              │  │ ✅ 2. 创建 VM 目录    [已完成]      │ │
│  📱 Test-JB  │  │ ✅ 3. 准备固件        [已完成]      │ │
│     🟡 操作中 │  │ ✅ 4. 补丁固件 (JB)   [已完成]      │ │
│              │  │ ✅ 5. 刷写固件        [已完成]      │ │
│              │  │ ✅ 6. Ramdisk + CFW   [已完成]      │ │
│  ───────────│  └──────────────────────────────────────┘ │
│    [  +  ]   │                                          │
│              │  ┌─ 日志 ──────────────────────────────┐ │
│              │  │ > make build                         │ │
│              │  │ === Building vphone-cli (a1b2c3d) ===│ │
│              │  │ Build complete!                       │ │
│              │  │ === Signing with entitlements ===     │ │
│              │  │   signed OK                          │ │
│              │  └──────────────────────────────────────┘ │
└──────────────┴──────────────────────────────────────────┘
```

### 复用组件
- `VPhoneVirtualMachine` — VM 创建和启动
- `VPhoneControl` — vsock 通信协议
- `VPhoneWindowController` + `VPhoneVirtualMachineView` — VM 屏幕窗口
- `VPhoneMenuController` 及子模块 — VM 菜单栏
- `VPhoneKeyHelper` — 按键注入
- `VPhoneLocationProvider` — 位置转发
- `VPhoneScreenRecorder` — 屏幕录制
- `VPhoneSigner` + `VPhoneIPAInstaller` — IPA 安装
- `VPhoneFileBrowserView` + `VPhoneFileBrowserModel` — 文件浏览器

## 技术考量

- **SPM 结构变更：** 需将现有 26 个 Swift 文件拆分为共享库 `VPhoneCore`（VM 运行时相关）和 `vphone-cli`（CLI 入口 + 参数解析）两部分；新增 `vphone-app`（GUI 入口 + 管理界面）
- **进程管理：** DFU 刷写流程需要同时管理 2-3 个子进程（DFU 后台 + restore/ramdisk + iproxy），需要可靠的进程生命周期管理和异常处理
- **端口分配：** 多 VM 并行时，iproxy 的本地端口需要自动分配避免冲突。建议使用基础端口 + VM 索引偏移（如 SSH: 22222+N, VNC: 5901+N）
- **Makefile 适配：** 现有 Makefile 的 `VM_DIR` 变量需要传入各 VM 的独立目录路径，`make` 命令通过环境变量/参数指定
- **权限继承：** GUI 应用需要与 CLI 相同的 entitlements（`vphone.entitlements`）和签名处理
- **并发安全：** `build` 阶段产出是共享的（`.build/release/vphone-cli`），多个 VM 同时执行 build 可能冲突，需要加锁或确保 build 只执行一次

## 成功指标

- 用户从零开始创建并启动一个 VM，全程无需打开终端
- 一键自动化从创建到可启动的全流程耗时不超过手动 CLI 操作的 110%（即额外开销 < 10%）
- 同时运行 2 个 VM 实例无崩溃、无端口冲突、无文件冲突
- 每个操作阶段的失败能在 GUI 中清晰定位（阶段标记 + 日志输出）
- 已有 `vphone-cli` 用户无需任何操作即可继续使用 CLI 工作流

## 待澄清问题

1. **build 产物共享策略：** `make build` 的产物（`.build/release/vphone-cli` 和 `.build/vphone-cli.app`）是全局共享的。当多个 VM 同时处于设置阶段时，是否只需构建一次并共享？还是每个 VM 独立构建？
2. **vphoned 编译：** `make vphoned` 的输出路径依赖 `VM_DIR`（`$(VM_DIR)/.vphoned.signed`），多 VM 场景下每个 VM 目录需要独立的 vphoned 副本。是否可以先编译到临时位置再复制？
3. **首次启动自动注入的可靠性：** 通过串口自动输入命令的方式（PL011）是否足够可靠？是否有命令注入失败的风险？需要什么样的检测/重试机制？
4. **IPSW 缓存：** 固件下载文件（~20GB）是否应在多个 VM 间共享缓存，避免重复下载？
5. **应用图标和名称：** 应用的正式名称是 "vPhone" 还是其他？是否需要设计应用图标？
