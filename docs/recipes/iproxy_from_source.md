# 从源码编译安装 iproxy（macOS）

`iproxy` 是一个 **usbmux 端口转发**工具：把 Mac 本地端口转发到 iPhone 设备上的端口（例如 WebDriverAgent 的 `8100`），从而用 `http://127.0.0.1:8100` 访问设备侧服务。

本文提供两种方式：

- **一键脚本**：直接运行仓库里的 `scripts/install_iproxy_from_source.sh`。
- **手动步骤**：脚本实际执行的命令与关键点，便于你按需裁剪。

## 前置条件（不用 Homebrew 也可以，但你仍需要这些工具）

你至少需要：

- Xcode Command Line Tools（含 `clang` / `make`）：`xcode-select --install`
- `curl`、`tar`
- `pkg-config`

说明：本文使用的是 *release* 源码包（自带 `configure` 等生成文件），通常不需要额外安装 `autoconf/automake/libtool`。如果你改成从 Git 仓库拉源码自己跑 `./autogen.sh`，那才需要它们。

你可以先用下面命令检查：

```bash
for c in clang make curl tar pkg-config libtool glibtool; do
  echo "== $c =="; command -v "$c" || true
done
```

## 方式 A：运行一键脚本

在仓库根目录执行：

```bash
bash scripts/install_iproxy_from_source.sh
```

常用参数（环境变量）：

- `PREFIX`：安装前缀（默认 `~/.local`）
- `KEEP_BUILD_DIR=1`：保留临时编译目录（默认会清理）
- `LIBPLIST_VERSION` / `GLUE_VERSION` / `LIBUSBMUXD_VERSION`：指定版本

示例：

```bash
PREFIX="$HOME/.local" KEEP_BUILD_DIR=1 bash scripts/install_iproxy_from_source.sh
```

## 方式 B：手动步骤（脚本做了什么）

以下示例统一安装到 `~/.local`：

```bash
export PREFIX="$HOME/.local"
mkdir -p "$PREFIX"
export PATH="$PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CPPFLAGS="-I$PREFIX/include ${CPPFLAGS:-}"
export LDFLAGS="-L$PREFIX/lib ${LDFLAGS:-}"
```

### 1) 安装 libplist（关闭 Python bindings，避免 `python` 依赖）

libplist 默认会尝试构建 Python bindings，如果系统找不到 `python` 可能直接失败。这里通过 `--without-cython` 关闭。

```bash
curl -fsSLo libplist.tar.bz2 \
  https://github.com/libimobiledevice/libplist/releases/download/2.7.0/libplist-2.7.0.tar.bz2
tar -xjf libplist.tar.bz2
cd libplist-2.7.0
./configure --prefix="$PREFIX" --without-cython
make -j"$(sysctl -n hw.ncpu)"
make install
```

### 2) 安装 libimobiledevice-glue

`libusbmuxd`（包含 `iproxy`）依赖 `libimobiledevice-glue`。

```bash
cd ..
curl -fsSLo glue.tar.bz2 \
  https://github.com/libimobiledevice/libimobiledevice-glue/releases/download/1.3.2/libimobiledevice-glue-1.3.2.tar.bz2
tar -xjf glue.tar.bz2
cd libimobiledevice-glue-1.3.2
./configure --prefix="$PREFIX"
make -j"$(sysctl -n hw.ncpu)"
make install
```

### 3) 安装 libusbmuxd（得到 iproxy）

```bash
cd ..
curl -fsSLo libusbmuxd.tar.bz2 \
  https://github.com/libimobiledevice/libusbmuxd/releases/download/2.1.1/libusbmuxd-2.1.1.tar.bz2
tar -xjf libusbmuxd.tar.bz2
cd libusbmuxd-2.1.1
./configure --prefix="$PREFIX"
make -j"$(sysctl -n hw.ncpu)"
make install
```

### 4) 验证

```bash
"$PREFIX/bin/iproxy" --version
otool -L "$PREFIX/bin/iproxy"
```

## 使用示例：转发 WDA 的 8100 端口

前提：你的 iPhone 上 WebDriverAgent 已经启动，并在设备侧监听 `8100`。

```bash
~/.local/bin/iproxy -u <UDID> 8100:8100
```

另开一个终端验证：

```bash
curl http://127.0.0.1:8100/status
python3 ios.py --wda-url http://127.0.0.1:8100 --wda-status
```

## 常见问题

### `configure: error: Giving up, python development not available`

通常是 libplist 在构建 Python bindings，但系统找不到 `python`。解决：给 libplist 的 `./configure` 加上 `--without-cython`。

### `curl http://127.0.0.1:8100/status` 连接被重置（connection reset）

这通常意味着 **WDA 没有在设备侧正常监听 8100**，或 WDA 进程已退出。请先确认 `xcodebuild ... test` 正在运行（或你用 Xcode 触发的 UI Test 仍存活）。

### iPhone 上 `127.0.0.1:8100` 可用，但 `http://<iphone-ip>:8100/status` 超时

请检查 iPhone **设置 -> App（或 应用）-> WebDriverAgentRunner-Runner -> 无线数据（Wireless Data）**，确保不是 **Off**，而是 **WLAN** 或 **WLAN & Cellular Data**。

如果你发现该开关经常在重新运行 Xcode UI Test 后被重置，建议直接使用 `iproxy` 转发并固定访问 `http://127.0.0.1:8100`（USB 或 `iproxy -n` 走 Wi‑Fi 配对通道），可以完全绕开这个问题。
