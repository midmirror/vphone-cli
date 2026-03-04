# PRD：扩展 vphoned 添加原生 IPA 安装命令

## 引言

为 vphone-cli 添加原生 IPA 安装能力，允许用户将 iOS 应用（`.ipa` 文件）安装到虚拟 iPhone 中。该功能通过扩展 guest 端守护进程 `vphoned` 实现，利用 iOS 私有 API `LSApplicationWorkspace` 完成应用安装，支持两种使用方式：CLI 命令行安装和 GUI 菜单安装。

核心数据流：宿主机选择 IPA → 通过 vsock `file_put` 上传到 VM 的 `/tmp/` → 发送 `app_install` 命令 → vphoned 解压、可选重签、调用私有 API 安装 → 返回结果。

## 目标

- 支持通过 CLI 参数 `--install-ipa <path>` 在 VM 启动后自动安装 IPA
- 支持通过 GUI 菜单 "Install IPA..." 选择宿主机 Finder 中的 IPA 文件安装
- 安装过程提供阶段性进度回调（上传中、解压中、安装中、完成）
- 安装失败时返回详细错误信息（含 iOS 系统错误描述）
- 如果 guest 中存在 `ldid`，自动对 IPA 中的二进制进行重签；否则跳过
- 安装完成后自动刷新 SpringBoard 图标缓存

## 用户故事

### US-001: Guest 端 IPA 解压模块

**描述：** 作为 vphoned 开发者，我需要在 guest VM 中将上传的 `.ipa` 文件解压到临时目录，以便后续安装流程使用解压后的 `.app` 包。

**验收标准：**
- [ ] 新增 `vphoned_app.h` / `vphoned_app.m` 文件，遵循现有模块命名约定（`vp_handle_app_*`）
- [ ] 实现 IPA 解压函数，优先使用 `posix_spawn` 调用 `/usr/bin/unzip`，若 `unzip` 不可用则回退到 `NSData` + minizip/libarchive 解压
- [ ] 解压到 `/tmp/<UUID>/` 临时目录，成功后返回 `Payload/*.app` 的完整路径
- [ ] 解压失败时返回包含具体原因的错误字典（如 "unzip not found"、"invalid IPA format"、"Payload/*.app not found"）
- [ ] 编译通过（`vphoned.m` 中 `#import "vphoned_app.h"` 无错误）

### US-002: Guest 端可选 ldid 重签模块

**描述：** 作为安全研究员，我希望在 Base patch 模式下安装 IPA 时，vphoned 能自动检测 guest 中是否存在 `ldid` 并对 `.app` 包中的 Mach-O 二进制进行重签，确保应用能通过 trustcache 验证。

**验收标准：**
- [ ] 在 `vphoned_app.m` 中实现重签函数，使用 `posix_spawn` 调用 `ldid -S <binary_path>`
- [ ] 安装流程中，先通过 `access("/usr/bin/ldid", X_OK)` 检测 `ldid` 是否可用
- [ ] 如果 `ldid` 可用，对 `.app` 包内所有 Mach-O 二进制（主二进制 + Frameworks/*.framework/* ）执行重签
- [ ] 如果 `ldid` 不可用，跳过重签并在响应中附带 `"resigned": false` 字段
- [ ] 重签成功时响应附带 `"resigned": true`
- [ ] 编译通过

### US-003: Guest 端 LSApplicationWorkspace 安装调用

**描述：** 作为 vphoned 开发者，我需要通过 iOS 私有 API `LSApplicationWorkspace` 将解压后的 `.app` 包安装到系统中，完成应用注册和图标刷新。

**验收标准：**
- [ ] 使用 `dlopen` 加载 CoreServices 框架（先尝试 `/System/Library/PrivateFrameworks/CoreServices.framework/CoreServices`，回退到 `/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices`）
- [ ] 通过 `NSClassFromString(@"LSApplicationWorkspace")` 获取类，调用 `defaultWorkspace` 获取实例
- [ ] 使用 `installApplication:withOptions:error:` 方法安装 `.app`，options 传入 `@{@"PackageType": @"Developer"}`
- [ ] 安装成功后，调用 `_LSPrivateRebuildApplicationDatabasesForSystemApps:internal:user:` 刷新 SpringBoard 图标缓存
- [ ] 安装失败时返回 iOS 系统错误的 `localizedDescription`
- [ ] 安装完成后清理临时解压目录和上传的 IPA 文件
- [ ] 编译通过

### US-004: Guest 端 `app_install` 命令分发与协议集成

**描述：** 作为 vphoned 开发者，我需要将 IPA 安装功能注册为 `app_install` 命令，集成到现有的命令分发和能力协商机制中。

**验收标准：**
- [ ] 在 `vphoned.m` 的 `handle_command()` 中添加 `if ([type isEqualToString:@"app_install"])` 分支，调用 `vp_handle_app_install(msg, reqId)`
- [ ] `vp_handle_app_install` 接收 `msg[@"path"]`（IPA 在 guest 中的路径），串联解压 → 可选重签 → 安装三个阶段
- [ ] 在 `caps` 数组中添加 `@"app_install"` 字符串
- [ ] 成功响应格式：`{"t": "ok", "id": "<reqId>", "bundle_id": "<安装后的 bundleID>", "resigned": true/false}`
- [ ] 失败响应格式：`{"t": "err", "id": "<reqId>", "msg": "<详细错误描述>", "stage": "unzip|resign|install"}`，`stage` 字段标明失败阶段
- [ ] 编译通过

### US-005: 宿主端 `VPhoneControl.installApp` 方法

**描述：** 作为宿主端开发者，我需要在 `VPhoneControl.swift` 中添加高层安装方法，封装文件上传和安装命令的完整流程。

**验收标准：**
- [ ] 新增 `func installApp(localPath: String) async throws -> InstallResult` 方法
- [ ] `InstallResult` 结构体包含 `bundleId: String?`、`resigned: Bool`、`errorMessage: String?`、`failedStage: String?` 字段
- [ ] 方法内部流程：读取本地 IPA 文件 → 调用 `uploadFile(path:data:)` 上传到 `/tmp/install_<UUID>.ipa` → 调用 `sendRequest(["t": "app_install", "path": remotePath])` → 解析响应为 `InstallResult`
- [ ] 上传或安装失败时抛出包含详细信息的错误
- [ ] 类型检查通过（`swift build` 无类型错误）

### US-006: GUI 菜单 "Install IPA..." 入口

**描述：** 作为用户，我希望在 VM 窗口的 Connect 菜单中看到 "Install IPA..." 选项，点击后弹出 Finder 文件选择面板，选择 `.ipa` 文件后自动完成上传和安装。

**验收标准：**
- [ ] 在 `VPhoneMenuConnect.swift` 的 `buildConnectMenu()` 中，在 "File Browser" 之后添加 `NSMenuItem.separator()` 和 "Install IPA..." 菜单项
- [ ] 点击菜单项后弹出 `NSOpenPanel`，仅允许选择 `.ipa` 文件（`allowedContentTypes` 设为 UTType 对应 `.ipa` 扩展名）
- [ ] 选择文件后，异步调用 `control.installApp(localPath:)` 执行安装
- [ ] 安装成功时弹出 `NSAlert`（`.informational`），显示 "Installed successfully" 和 bundle ID
- [ ] 安装失败时弹出 `NSAlert`（`.warning`），显示失败阶段和错误详情
- [ ] 安装过程中菜单项变为禁用状态（防止重复触发），完成后恢复
- [ ] 类型检查通过（`make build` 无编译错误）

### US-007: CLI `--install-ipa` 参数支持

**描述：** 作为安全研究员，我希望通过命令行参数 `--install-ipa <path>` 在 VM 启动后自动安装指定的 IPA 文件，无需通过 GUI 操作。

**验收标准：**
- [ ] 在 `VPhoneCLI.swift` 中添加 `@Option(name: .long, help: "Install IPA file to the VM after boot") var installIpa: String?`
- [ ] 在 `VPhoneAppDelegate.swift` 的 `control.onConnect` 回调中，如果 `cli.installIpa` 非 nil 且 `caps` 包含 `"app_install"`，自动触发安装流程
- [ ] 安装结果通过 `print()` 输出到终端（成功："Installed <bundle_id> successfully"，失败："Install failed at <stage>: <error>"）
- [ ] 安装完成后 VM 继续正常运行（不退出）
- [ ] 如果指定的 IPA 文件不存在，启动时立即报错并退出
- [ ] 类型检查通过（`make build` 无编译错误）

## 功能需求

- FR-1：vphoned 新增 `app_install` 命令，接收 `path` 参数（guest 本地 IPA 路径），返回安装结果
- FR-2：`app_install` 命令串联三个阶段：解压 IPA → 可选 ldid 重签 → LSApplicationWorkspace 安装
- FR-3：IPA 解压优先使用 `posix_spawn("/usr/bin/unzip")`，不可用时回退到原生 ZIP 解压
- FR-4：如果 guest 中存在 `/usr/bin/ldid`，自动对 `.app` 包内所有 Mach-O 二进制执行 `ldid -S` 重签
- FR-5：使用 `LSApplicationWorkspace` 的 `installApplication:withOptions:error:` API 安装 `.app` 包
- FR-6：安装完成后调用 `_LSPrivateRebuildApplicationDatabasesForSystemApps:internal:user:` 刷新图标
- FR-7：安装完成后清理临时文件（解压目录 + 上传的 IPA）
- FR-8：失败响应必须包含 `stage` 字段（`unzip` / `resign` / `install`）和详细错误描述
- FR-9：成功响应必须包含 `bundle_id` 和 `resigned` 字段
- FR-10：在 `caps` 握手数组中注册 `app_install` 能力
- FR-11：宿主端 `VPhoneControl` 新增 `installApp(localPath:)` 方法，封装上传 + 安装的完整流程
- FR-12：Connect 菜单新增 "Install IPA..." 项，弹出 `NSOpenPanel` 选择 `.ipa` 文件
- FR-13：CLI 新增 `--install-ipa <path>` 选项，VM 启动并连接 vsock 后自动安装
- FR-14：安装过程中 GUI 菜单项禁用，防止重复触发

## 非目标

- 不实现 MCMAppContainer 手动安装模式或 MobileInstallationInstall API（仅使用 LSApplicationWorkspace）
- 不实现应用卸载功能
- 不实现已安装应用列表查询
- 不实现 IPA 内容预览或信息展示（如图标、版本号）
- 不实现批量安装多个 IPA
- 不实现安装过程的实时进度流推送（仅按阶段回调：上传中、解压中、安装中、完成）
- 不实现从 URL 下载 IPA 安装（仅支持本地文件）
- 不在文件浏览器中集成安装功能（仅 Connect 菜单和 CLI）

## 技术考量

### 依赖项

| 依赖 | 说明 | 是否必须 |
|------|------|---------|
| `LSApplicationWorkspace` | iOS 私有 API，通过 `dlopen` + `NSClassFromString` 动态加载 | 是 |
| `/usr/bin/unzip` | IPA 解压，由 `iosbinpack64` 提供 | 否（有回退） |
| `/usr/bin/ldid` | 二进制重签，由 `iosbinpack64` 提供 | 否（可选） |
| `vphoned entitlements` | 已拥有全部必要权限（`platform-application`、`no-container`、`rootless.install` 等） | 是（已满足） |

### 协议扩展

新增命令遵循现有 vphoned 协议（length-prefixed JSON over vsock port 1337）：

**请求：**
```json
{"v": 1, "t": "app_install", "id": "a1", "path": "/tmp/install_xxxx.ipa"}
```

**成功响应：**
```json
{"v": 1, "t": "ok", "id": "a1", "bundle_id": "com.example.app", "resigned": true}
```

**失败响应：**
```json
{"v": 1, "t": "err", "id": "a1", "msg": "LSApplicationWorkspace error: ...", "stage": "install"}
```

### 文件大小约束

现有 `file_put` 协议使用 `uint32` size 字段，支持最大 ~4GB 文件，覆盖绝大多数 IPA。

### 代码签名环境

- **JB patch 模式**：TXM CS 验证已旁路，任何 IPA 直接安装
- **Base patch 模式**：需要 ldid 重签或 trustcache 包含，可选重签机制自动适配

### 现有代码复用

| 现有设施 | 复用方式 |
|---------|---------|
| `VPhoneControl.uploadFile(path:data:)` | 直接调用上传 IPA 到 guest |
| `VPhoneControl.sendRequest(_:)` | 发送 `app_install` 命令 |
| `vp_make_response` / `vp_make_error` | 构造 guest 端响应 |
| `VPhoneMenuConnect.showAlert` | 显示安装结果弹窗 |
| `VPhoneMenuConnect.makeItem` | 构建菜单项 |
| `posix_spawn` 模式（`vphoned_devmode.m` 中已有） | 调用 `unzip` 和 `ldid` |

## 成功指标

- 用户从选择 IPA 到安装完成，操作步骤不超过 3 步（菜单点击 → 选择文件 → 自动完成）
- CLI 模式下一条命令完成安装（`--install-ipa /path/to/app.ipa`）
- 安装失败时能明确定位失败阶段（解压 / 重签 / 安装）和具体原因
- 不影响现有 vphoned 功能（`hid`、`devmode`、`file`、`location` 等命令无退化）

## 待澄清问题

- `LSApplicationWorkspace` 的 `installApplication:withOptions:error:` 在 PCC 研究 VM 的 iOS 26.1 上是否行为一致？需实际验证
- `_LSPrivateRebuildApplicationDatabasesForSystemApps:internal:user:` 在此 iOS 版本上的 selector 是否存在？可能需要回退到 `uicache` 命令
- 大文件（>500MB）IPA 上传是否会导致 vsock 超时？可能需要调整超时设置
- `ldid -S` 对 iOS 17+ 的 arm64e 二进制是否有效？可能需要 `ldid -S -M` 或其他参数
