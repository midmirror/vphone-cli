# vphone-cli 问题解决记录

## 问题 1：Python 版本不兼容

### 错误信息
```
ERROR: Could not find a version that satisfies the requirement capstone (from versions: none)
ERROR: No matching distribution found for capstone
```

### 原因
- 脚本使用系统默认的 Python 3.9.6
- Python 3.9 不兼容 `capstone`、`keystone-engine`、`pyimg4` 等包的最新版本

### 解决方案
修改 `scripts/setup_venv.sh`，将 Python 从 `python3` 改为 `python3.13`：

```diff
- # Use system Python3
- PYTHON="$(command -v python3)"
+ # Use Homebrew Python 3.13
+ PYTHON="$(command -v python3.13)"
```

同时修改验证部分：
```diff
- python3 -c "
+ python3.13 -c "
```

## 问题 2：pip 镜像源缺少包

### 错误信息
```
Looking in indexes: https://mirrors.tuna.tsinghua.edu.cn/pypi/simple
ERROR: Could not find a version that satisfies the requirement capstone
```

### 原因
- 系统配置了清华镜像源 `https://mirrors.tuna.tsinghua.edu.cn/pypi/simple`
- 该镜像源没有 `capstone`、`keystone-engine` 等包的 arm64 macOS 版本

### 解决方案
修改 `scripts/setup_venv.sh`，强制使用默认 PyPI：

```diff
- # Activate and install pip packages
- source "${VENV_DIR}/bin/activate"
- pip install --upgrade pip > /dev/null
- pip install -r "${REQUIREMENTS}"
+ # Activate and install pip packages (use default PyPI, not mirror)
+ source "${VENV_DIR}/bin/activate"
+ pip install --upgrade pip > /dev/null
+ pip install -i https://pypi.org/simple -r "${REQUIREMENTS}"
```

## 修改后的完整变更

### scripts/setup_venv.sh

1. 第 17-22 行：
```zsh
# Use Homebrew Python 3.13
PYTHON="$(command -v python3.13)"
if [[ -z "${PYTHON}" ]]; then
  echo "Error: python3.13 not found in PATH. Install with: brew install python@3.13"
  exit 1
fi
```

2. 第 33-36 行：
```zsh
# Activate and install pip packages (use default PyPI, not mirror)
source "${VENV_DIR}/bin/activate"
pip install --upgrade pip > /dev/null
pip install -i https://pypi.org/simple -r "${REQUIREMENTS}"
```

3. 第 72 行：
```zsh
python3.13 -c "
```

## 验证

修改完成后，运行以下命令验证：

```bash
rm -rf .venv
make setup_venv
```

成功输出：
```
=== Verifying imports ===
  capstone  OK
  keystone  OK
  pyimg4    OK

=== venv ready ===
```

## 依赖要求

- Homebrew 已安装 `python@3.13`
- Homebrew 已安装 `keystone`
- 系统 pip 配置了镜像源（可选，但需要绕过安装某些包）

---

## 问题 3：cfw_install 步骤 3/7 失败

### 错误信息
```
[3/7] Installing AppleParavirtGPUMetalIOGPUFamily...
/usr/bin/tar: Ignoring unknown extended header keyword `LIBARCHIVE.xattr.com.apple.lastuseddate#PS'
/usr/bin/tar: Ignoring unknown extended header keyword `SCHILY.xattr.com.apple.lastuseddate#PS'
make: *** [cfw_install] Error 255
```

### 原因
脚本使用 `sudo hdiutil attach` 挂载 DMG，但 make 环境下没有 TTY 来输入密码。

### 解决方案
配置 NOPASSWD sudo：

```bash
sudo visudo
# 添加:
your_username ALL=(ALL) NOPASSWD: /usr/bin/hdiutil
```

---

## 问题 4：vphoned 编译缺少符号链接

### 错误信息
```
Undefined symbols for architecture arm64:
  "_vp_devmode_arm", referenced from:
      _main in vphoned-dbb712.o
  "_vp_devmode_available", referenced from:
      ...
  "_vp_hid_key", referenced from:
      ...
  "_vp_location_available", referenced from:
      ...
  "_vp_make_response", referenced from:
      ...
  "_vp_read_fully", referenced from:
      ...
```

### 原因
编译命令只包含了 `vphoned.m`，缺少其他源文件：
- `vphoned_protocol.m`
- `vphoned_files.m`
- `vphoned_devmode.m`
- `vphoned_hid.m`
- `vphoned_location.m`

### 解决方案
修改 `scripts/cfw_install.sh` 第 390-392 行，添加所有源文件：

```diff
-    xcrun -sdk iphoneos clang -arch arm64 -Os -fobjc-arc \
-        -o "$VPHONED_BIN" "$VPHONED_SRC/vphoned.m" \
-        -framework Foundation
+    xcrun -sdk iphoneos clang -arch arm64 -Os -fobjc-arc \
+        -o "$VPHONED_BIN" \
+        "$VPHONED_SRC/vphoned.m" \
+        "$VPHONED_SRC/vphoned_protocol.m" \
+        "$VPHONED_SRC/vphoned_files.m" \
+        "$VPHONED_SRC/vphoned_devmode.m" \
+        "$VPHONED_SRC/vphoned_hid.m" \
+        "$VPHONED_SRC/vphoned_location.m" \
+        -framework Foundation
```

修改后的完整命令在 `scripts/cfw_install.sh:389-397`。
