# PRD：make install_ipa 命令

## 引言/概述

为 vphone-cli 添加 `make install_ipa IPA=<path>` 命令，允许在 VM **已经运行**的情况下，从终端向其安装 IPA 文件，无需操作 GUI 菜单。

核心挑战：`VPhoneControl.installIPA()` 只能在创建 VM 的进程内调用（vsock 设备绑定在 `vphone-cli` 进程中），外部进程无法直接访问。因此需要在 `vphone-cli` 内嵌入一个 **Unix domain socket 服务器**，作为进程间通信（IPC）桥梁。

---

## 目标

- 支持 `make install_ipa IPA=path/to/app.ipa`，向运行中的 VM 安装 IPA
- VM 启动后自动监听本地控制 socket（无需额外参数）
- 安装结果（成功/失败/错误信息）打印到终端
- 协议风格与项目现有模式一致（长度前缀 JSON over Unix socket）
- 不破坏任何现有功能（GUI、headless、DFU 模式）

---

## 用户故事

### US-001：在 vphone-cli 中嵌入本地控制 socket 服务器

**描述：** 作为开发者，我希望 vphone-cli 在正常启动（非 DFU）后自动监听一个 Unix domain socket，以便外部脚本可以向其发送控制命令。

**技术细节：**

- 新增 `VPhoneLocalControlServer.swift`
- socket 路径：`{vm_dir}/.vphone.sock`（`vm_dir` 通过 CLI 参数 `--vm-dir` 传入，见 US-002）
- 协议：每条消息 = `[uint32 大端 length][UTF-8 JSON]`，与 vsock 协议一致
- 每个客户端连接在独立的 Task 中处理
- 收到 `{"t": "ipa_install", "path": "/abs/path/to/app.ipa"}` 后，委托给 `VPhoneControl.installIPA()`
- 成功响应：`{"ok": true, "msg": "..."}`
- 失败响应：`{"ok": false, "error": "..."}`
- 进程退出时删除 socket 文件（`defer` + `applicationWillTerminate`）
- 若 `VPhoneControl` 未连接（guest 未就绪），返回 `{"ok": false, "error": "guest not connected"}`

**验收标准：**
- [ ] `VPhoneLocalControlServer` 在 VM 启动（非 DFU）后创建 socket 文件于 `{vm_dir}/.vphone.sock`
- [ ] 并发客户端连接互不干扰
- [ ] 进程退出后 socket 文件被清理
- [ ] `swift build` 无报错，类型检查通过

---

### US-002：为 vphone-cli 添加 `--vm-dir` CLI 参数

**描述：** 作为开发者，我希望 vphone-cli 知道自己的 VM 目录路径，以便将控制 socket 放在该目录下（与其他 VM 文件并列），方便外部脚本定位。

**技术细节：**

- 在 `VPhoneCLI.swift` 中新增 `@Option var vmDir: String = "."`
- `VPhoneAppDelegate` 将 `vmDir` 传给 `VPhoneLocalControlServer`
- `boot` / `boot_dfu` Makefile 目标新增 `--vm-dir $(VM_DIR)` 参数
- socket 路径 = `$(VM_DIR)/.vphone.sock`

**验收标准：**
- [ ] `--vm-dir` 参数缺省为 `.`（当前目录，兼容现有 `cd $(VM_DIR) && ...` 启动模式）
- [ ] socket 文件确实创建在指定目录下
- [ ] `swift build` 无报错，类型检查通过

---

### US-003：实现 Python 客户端脚本 scripts/install_ipa.py

**描述：** 作为终端用户，我希望有一个脚本可以连接到运行中的 vphone-cli socket，发送 IPA 安装命令，并打印安装结果后退出。

**技术细节：**

- 脚本路径：`scripts/install_ipa.py`
- 用法：`python3 scripts/install_ipa.py <socket_path> <ipa_path>`
- 使用标准库（`socket`, `struct`, `json`），无额外依赖
- 协议：发送 `[uint32 big-endian length][UTF-8 JSON]`，读取响应
- 超时：连接超时 5 秒，等待安装响应 180 秒（与 `transferRequestTimeout` 一致）
- 成功时输出：`[install] <msg>`，退出码 0
- 失败时输出：`[install] Error: <error>`，退出码 1
- socket 不存在或连接被拒绝时输出友好错误：`[install] VM not running or socket not found: <path>`

**验收标准：**
- [ ] `python3 scripts/install_ipa.py $(VM_DIR)/.vphone.sock app.ipa` 在 VM 运行时成功安装并打印结果
- [ ] VM 未运行时脚本以退出码 1 退出并打印友好错误
- [ ] 脚本无第三方依赖（仅标准库）
- [ ] 类型检查通过（无语法错误）

---

### US-004：添加 Makefile `install_ipa` 目标

**描述：** 作为开发者，我希望可以通过 `make install_ipa IPA=path/to/app.ipa` 一条命令完成安装，无需记忆脚本路径和 socket 位置。

**技术细节：**

- 新增 Makefile 目标 `install_ipa`
- 用法：`make install_ipa IPA=path/to/app.ipa`
- 若 `IPA` 未指定，打印用法提示并以非零退出码退出
- 实际调用：`$(PYTHON) $(SCRIPTS)/install_ipa.py $(VM_DIR)/.vphone.sock $(IPA)`
- 在 `make help` 输出中新增一行说明

**验收标准：**
- [ ] `make install_ipa IPA=app.ipa` 在 VM 运行时成功安装
- [ ] `make install_ipa`（无 IPA 参数）打印 `Usage: make install_ipa IPA=<path>` 并退出码非零
- [ ] `make help` 输出中包含 `install_ipa` 说明

---

## 功能需求

- FR-1：`vphone-cli` 启动（非 DFU 模式）后，在 `{vm_dir}/.vphone.sock` 创建并监听 Unix domain socket
- FR-2：socket 使用长度前缀 JSON 协议（uint32 大端 + UTF-8 JSON），与 vsock 协议风格一致
- FR-3：支持 `ipa_install` 命令类型，接收绝对路径，委托给 `VPhoneControl.installIPA()`
- FR-4：响应包含 `ok`（bool）和 `msg`/`error`（string）字段
- FR-5：进程退出时（正常终止 / SIGINT）清理 socket 文件
- FR-6：新增 `--vm-dir` CLI 参数（默认 `.`），用于定位 socket 路径
- FR-7：Python 脚本 `scripts/install_ipa.py` 作为外部客户端，仅使用标准库
- FR-8：`make install_ipa IPA=<path>` Makefile 目标封装完整调用链

---

## 非目标

- 不支持向 socket 发送除 `ipa_install` 以外的命令（本期不做通用控制协议扩展）
- 不支持同时安装多个 IPA（单连接、单命令）
- 不实现进度流式推送（等待安装完成后一次性返回结果）
- 不支持远程 socket（仅本机 Unix domain socket）
- 不支持安装到 DFU 模式下的 VM

---

## 技术考量

- **进程边界限制：** vsock 只能在创建 VM 的进程内访问，Unix domain socket 是最轻量的 IPC 方案，无需引入新依赖
- **并发安全：** `VPhoneLocalControlServer` 需在 `@MainActor` 上调用 `VPhoneControl` 方法；网络读取在后台 Task，完成后通过 `await MainActor.run {}` 跳回主 Actor
- **socket 冲突：** 启动前检查并删除残留 socket 文件（上次进程崩溃可能遗留）
- **vm_dir 默认值 `.`：** 现有 Makefile 用 `cd $(VM_DIR) && vphone-cli ...` 启动，默认 `.` 即 VM 目录，无需改动现有启动逻辑即可兼容
- **Python 客户端超时：** `ipa_install` 涉及文件上传 + 安装，响应超时应 ≥ 180 秒

---

## 成功指标

- `make install_ipa IPA=xxx.ipa` 从命令发出到终端打印安装结果，全程无需鼠标操作
- 安装流程不影响 VM 正常运行（GUI 依然可用）

---

## 待澄清问题

- 无（所有关键设计决策已在 PRD 中明确）
