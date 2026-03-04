## 深度可行性分析：扩展 vphoned 添加原生 IPA 安装命令

### 结论：**完全可行**，且是最合理的方式。

---

### 一、权限可行性 ✅

vphoned 的 `entitlements.plist` 已经拥有 IPA 安装所需的**全部关键权限**：

| 权限 | 用途 | 状态 |
|------|------|------|
| `com.apple.private.security.no-container` | 无沙盒限制，可访问任意路径 | ✅ 已有 |
| `com.apple.private.MobileContainerManager.allowed` | 创建/管理应用容器 (MCM) | ✅ 已有 |
| `com.apple.private.security.container-manager` | 安全容器管理 | ✅ 已有 |
| `com.apple.private.security.storage.AppBundles` | 读写应用包目录 | ✅ 已有 |
| `com.apple.private.security.storage.AppDataContainers` | 读写应用数据容器 | ✅ 已有 |
| `com.apple.private.security.storage.containers` | 容器存储访问 | ✅ 已有 |
| `com.apple.rootless.install` + `.heritable` | SIP 安装权限 | ✅ 已有 |
| `com.apple.frontboard.launchapplications` | 启动应用 | ✅ 已有 |
| `com.apple.springboard.launchapplications` | SpringBoard 启动 | ✅ 已有 |
| `platform-application` | 平台应用身份 | ✅ 已有 |
| `file-read-data` / `file-write-data` | 全局文件读写 | ✅ 已有 |
| `com.apple.security.exception.files.absolute-path.read-write: ["/"]` | 根目录完全读写 | ✅ 已有 |
| `uicache.app-data-container-required` | UICache 刷新 | ✅ 已有 |

**关键发现**：vphoned 拥有 `platform-application` 和 `com.apple.rootless.install` 权限，这意味着它以**系统级身份**运行，这比 TrollStore 的权限模型还要直接。

---

### 二、安装 API 选择

参考 TrollStore 的实现，有两种安装方式：

#### 方式 A：LSApplicationWorkspace（推荐优先尝试）

```objc
// 加载框架
dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_LAZY);
// 或 iOS 16+:
dlopen("/System/Library/PrivateFrameworks/CoreServices.framework/CoreServices", RTLD_LAZY);

Class LSApplicationWorkspace = NSClassFromString(@"LSApplicationWorkspace");
id workspace = [LSApplicationWorkspace performSelector:@selector(defaultWorkspace)];

NSURL *appURL = [NSURL fileURLWithPath:@"/tmp/extracted_app/Payload/SomeApp.app"];
NSDictionary *options = @{
    @"PackageType": @"Developer",  // 或 @"Placeholder"
};
NSError *error = nil;
BOOL success = [workspace installApplication:appURL withOptions:options error:&error];
```

TrollStore 在 `installd` 模式中就是用此 API，传入 `@{LSInstallTypeKey: @1, @"PackageType": @"Placeholder"}`。vphoned 拥有 `platform-application` 权限，应该能直接调用成功。

#### 方式 B：MCMAppContainer 手动安装（Custom 模式，兜底）

```objc
// 创建应用容器
Class MCMAppContainer = NSClassFromString(@"MCMAppContainer");
id container = [MCMAppContainer containerWithIdentifier:bundleId
                                      createIfNecessary:YES
                                               existed:nil
                                                 error:&error];
// 复制 .app 到容器路径
NSString *destPath = [[container url] path];
[[NSFileManager defaultManager] copyItemAtPath:appPath toPath:destPath error:&error];
```

这种方式直接操作文件系统和容器管理器，完全绕过 `installd`，是最暴力但最可靠的方式。

#### 方式 C：MobileInstallationInstall（传统 API）

```objc
void *lib = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_LAZY);
typedef int (*MobileInstallationInstall)(NSString *path, NSDictionary *options, void *callback, NSString *unused);
MobileInstallationInstall install = dlsym(lib, "MobileInstallationInstall");
int result = install(@"/tmp/app.ipa", @{@"AllowInstallLocalProvisioned": @YES}, NULL, NULL);
```

这是最传统的方式，同步推/iFunBox 使用的就是它。在越狱/系统级权限下可用。

**推荐策略**：优先尝试方式 A，失败则回退到方式 B。方式 C 作为备选。

---

### 三、完整实现方案

#### 3.1 数据流设计

```
宿主机 (macOS)                     Guest VM (iOS)
                                   
[选择 IPA 文件]                    
    │                              
    ▼                              
file_put → /tmp/install.ipa  ───→  [接收 IPA 文件到 /tmp/]
    │                              
    ▼                              
app_install {path}           ───→  [vphoned 处理]
                                     1. 解压 IPA (unzip → Payload/*.app)
                                     2. 对 .app 签名修正 (如需要)
                                     3. 调用 LSApplicationWorkspace 安装
                                     4. 调用 uicache 刷新图标
                                     5. 清理临时文件
                                     6. 返回结果 ←──────────────────
```

#### 3.2 Guest 端 (vphoned) 修改

**新增文件 `vphoned_app.h` / `vphoned_app.m`**：

```objc
// vphoned_app.h
#import <Foundation/Foundation.h>
NSDictionary *vp_handle_app_install(NSDictionary *msg, NSString *reqId);
```

```objc
// vphoned_app.m
#import "vphoned_app.h"
#import "vphoned_protocol.h"
#import <dlfcn.h>
#import <objc/runtime.h>

NSDictionary *vp_handle_app_install(NSDictionary *msg, NSString *reqId) {
    NSString *path = msg[@"path"];  // IPA 在 guest 中的路径 (如 /tmp/install.ipa)
    if (!path) return vp_make_error(@"missing path", reqId);
    
    // 1. 解压 IPA
    NSString *extractDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                            [[NSUUID UUID] UUIDString]];
    NSTask *unzip = ...;  // 或用 posix_spawn 调用 /usr/bin/unzip
    
    // 2. 找到 Payload/*.app
    NSString *appPath = /* 遍历 extractDir/Payload/ 找到 .app */;
    
    // 3. 调用 LSApplicationWorkspace 安装
    dlopen("/System/Library/PrivateFrameworks/CoreServices.framework/CoreServices", RTLD_LAZY);
    Class LSAppWorkspace = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = [LSAppWorkspace performSelector:@selector(defaultWorkspace)];
    
    NSURL *appURL = [NSURL fileURLWithPath:appPath];
    NSError *error = nil;
    BOOL success = /* installApplication:withOptions:error: */;
    
    // 4. 刷新 SpringBoard 缓存 (uicache)
    if (success) {
        // 方式一：调用 LSApplicationWorkspace 的 registerApplicationDictionary:
        // 方式二：执行 /usr/bin/uicache (如果已安装 iosbinpack)
    }
    
    // 5. 清理
    [[NSFileManager defaultManager] removeItemAtPath:extractDir error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];  // 删除上传的 IPA
    
    NSDictionary *resp = vp_make_response(success ? @"ok" : @"err", reqId);
    if (!success) resp = /* 添加 error 信息 */;
    return resp;
}
```

**在 `vphoned.m` 的 `handle_command()` 中添加路由**：

```objc
if ([type isEqualToString:@"app_install"]) {
    return vp_handle_app_install(msg, reqId);
}
```

**在 `caps` 数组中注册**：添加 `@"app_install"` 到握手消息的 capabilities 列表。

#### 3.3 宿主端 (Swift) 修改

**VPhoneControl.swift** — 添加 `installApp` 方法：

```swift
func installApp(localPath: String) async throws -> [String: Any] {
    // 1. 读取 IPA 文件
    let data = try Data(contentsOf: URL(fileURLWithPath: localPath))
    let remotePath = "/tmp/install_\(UUID().uuidString).ipa"
    
    // 2. 上传到 guest (复用现有 file_put)
    try await uploadFile(path: remotePath, data: data)
    
    // 3. 发送安装命令
    return try await sendRequest([
        "t": "app_install",
        "path": remotePath
    ])
}
```

**VPhoneMenuConnect.swift** — 添加菜单项（方式 2：GUI 安装）：

```swift
// 在 buildConnectMenu() 中添加
menu.addItem(makeItem("Install IPA...", action: #selector(installIPA)))

@objc func installIPA() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.init(filenameExtension: "ipa")!]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    
    guard panel.runModal() == .OK, let url = panel.url else { return }
    
    Task {
        do {
            let result = try await control.installApp(localPath: url.path)
            let status = result["t"] as? String == "ok" ? "安装成功" : "安装失败"
            showAlert(title: "IPA Install", message: status)
        } catch {
            showAlert(title: "IPA Install Error", message: error.localizedDescription)
        }
    }
}
```

**VPhoneCLI.swift** — 添加命令行选项（方式 1：命令安装）：

```swift
@Option(name: .long, help: "Install IPA file to the VM")
var installIPA: String?
```

然后在 AppDelegate 启动流程中，如果 `installIPA` 非 nil，等待 vsock 连接后调用 `control.installApp(localPath:)`。

---

### 四、需要注意的问题

#### 4.1 代码签名

PCC/研究 VM 环境下 TXM 的 trustcache 验证已被 patch 掉（`txm.py` 的 trustcache hash lookup bypass），且如果使用了 JB patch（`txm_jb.py` 的 CS validation bypass），代码签名检查也被旁路了。因此：

- **Base patch 模式**：IPA 中的二进制需要在 trustcache 中，或者需要 `ldid` 重签
- **JB patch 模式**：代码签名已被完全旁路，任何 IPA 都可以直接安装

建议在 `app_install` 命令中加入可选的重签步骤（如果 guest 中有 `ldid`）。

#### 4.2 IPA 大小限制

现有的 `file_put` 协议支持最大 4GB（uint32 size 字段），对大多数 IPA 足够。但上传大文件时应考虑进度回调——目前协议不支持进度通知，可以在宿主端根据 data.count 估算。

#### 4.3 unzip 工具

Guest VM 中需要有 `unzip` 命令。`cfw_install.sh` 安装的 `iosbinpack64` 中通常包含此工具。如果没有，可以用 `NSFileManager` + libarchive 或者 Foundation 的 `NSData` 手动解压 ZIP。

#### 4.4 uicache 刷新

uicache 的本质是调用 `LSApplicationWorkspace` 的注册方法。如果用 `installApplication:withOptions:error:` 安装成功，系统通常会自动刷新 SpringBoard，无需额外调用。但如果用 MCM 手动安装模式，则需要手动触发：

```objc
// 注册到 SpringBoard
[workspace registerApplicationDictionary:appInfoDict];
// 或 iOS 15+:
[workspace _LSPrivateRebuildApplicationDatabasesForSystemApps:NO internal:NO user:YES];
```

---

### 五、总结

| 维度 | 评估 |
|------|------|
| 权限可行性 | ✅ 全部满足，vphoned 拥有系统级权限 |
| API 可行性 | ✅ LSApplicationWorkspace + MCM 两条路可走 |
| 架构契合度 | ✅ 完美契合现有的命令分发 + file_put 上传模式 |
| 代码签名 | ⚠️ Base 模式需考虑 trustcache，JB 模式无忧 |
| 工程量 | 中等 — Guest 端新增 ~150 行 ObjC，宿主端 ~80 行 Swift |
| 命令行安装 | ✅ 可通过 CLI 选项 `--install-ipa` 实现 |
| GUI 菜单安装 | ✅ 在 Connect 菜单添加 "Install IPA..." 项，NSOpenPanel 选择文件 |

**方案完全可行，且是最自然的扩展方式**。核心工作量集中在 guest 端的 `vphoned_app.m`（~150 行），其余都是复用现有基础设施。