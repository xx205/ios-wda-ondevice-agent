# 用 xcodebuild 更快启动 WebDriverAgent（build-for-testing + test-without-building）

## 背景

WDA 常见有两种启动方式：

- **启动已安装的 `*.xctrunner`**：用 `devicectl --no-activate`（见 `docs/recipes/run_wda_preinstalled_devicectl.md`）。
- **通过 Xcode UI Test 启动**：`xcodebuild ... test`（或在 Xcode 里 `Product > Test`）。

本文解决的是第二种：如果你仍然使用 `xcodebuild` 路径，但希望 **避免每次都重新编译**，更现实的做法是：**只 build 一次，然后反复 test-without-building**。

---

## 方案：build-for-testing 一次 + test-without-building 反复跑

> 说明：这仍然需要 macOS + Xcode；但可以把“编译”从每次启动里拆出去，让重启 WDA 更快、更稳定。

### 0) 准备

- 确保你已经能在 Xcode 里跑通一次 `Product > Test`（WDA 能输出 `ServerURLHere->http://...:8100<-ServerURLHere`）。
- 记下你的设备 UDID（Xcode 或 `xcrun devicectl list devices`）。

### 1) build-for-testing（只做一次）

```bash
UDID="<你的UDID>"
WDA_DIR="<WebDriverAgent 仓库路径>"
DD="$HOME/wda_derived"

xcodebuild -project "$WDA_DIR/WebDriverAgent.xcodeproj" \
  -scheme WebDriverAgentRunner \
  -destination "platform=iOS,id=$UDID" \
  -derivedDataPath "$DD" \
  build-for-testing
```

构建完成后，会生成一个 `*.xctestrun` 文件（路径通常类似）：

```bash
ls "$DD/Build/Products/"WebDriverAgentRunner_iphoneos*.xctestrun
```

### 2) test-without-building（后续每次重启都用这个）

```bash
UDID="<你的UDID>"
DD="$HOME/wda_derived"
XCTESTRUN="$(ls "$DD/Build/Products/"WebDriverAgentRunner_iphoneos*.xctestrun | head -n1)"

xcodebuild test-without-building \
  -xctestrun "$XCTESTRUN" \
  -destination "platform=iOS,id=$UDID" \
  -only-testing:WebDriverAgentRunner/UITestingUITests/testRunner
```

这个命令会“卡住不退出”是正常的：WDA 的 `testRunner` 是一个常驻循环，用来持续提供 WebServer。

### 3) 如何停止

在另一个 terminal 里结束对应的 `xcodebuild` 进程（或用脚本里的 trap 逻辑）：

```bash
pkill -TERM -f \"xcodebuild.*WebDriverAgentRunner\"
```

---

## 一键脚本（推荐）

仓库提供了一个小脚本把上面流程串起来：

```bash
bash scripts/run_wda_xcodebuild.sh --udid <UDID> --wda-dir <WDA_DIR>
```

默认会使用 `-derivedDataPath "$HOME/wda_derived"`，并在 `Ctrl-C` 时发送 `SIGTERM` 去结束 `xcodebuild`。

---

## 备注：关于 Wireless Data（Wi‑Fi 可达性）

如果你需要从局域网访问 `http://<iphone-ip>:8100/status`，请确保 iPhone 上：

`Settings -> Apps -> WebDriverAgentRunner-Runner -> Wireless Data` 不是 **Off**。

如果你不想被这个开关反复“重置”影响，最稳妥的绕开方式仍然是用 `iproxy` 固定访问 `http://127.0.0.1:8100`（USB 或 `iproxy -n`）。
