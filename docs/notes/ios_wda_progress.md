# iOS/WDA 进展摘要（可公开复现，无个人信息）

## 背景问题

在部分设备/系统组合下，通过 `xcodebuild ... test`（Xcode UI Test）启动 WebDriverAgent（WDA）时，经常会触发 `WebDriverAgentRunner-Runner` 被重新安装/更新。副作用是 iPhone 上：

`Settings -> Apps -> WebDriverAgentRunner-Runner -> Wireless Data`

会被重置为 **Off**，导致：

- iPhone 上 `http://127.0.0.1:8100/status` 可访问；
- 但同一局域网其它设备（甚至 iPhone 自己）访问 `http://<iphone-ip>:8100/status` **timeout**；
- 同时更容易在设备日志里看到 `Exiting due to IDE disconnection.`（Wi‑Fi UI Test 场景）。

## 当前可行的解决方向

核心思路：**把“安装”和“启动”拆开**，尽量减少/避免 Runner 被反复重装，从而让你可以先手动把 Wireless Data 打开并长期保持。

### 1) P0：修复 LAN 访问超时（一次性操作）

如果你遇到 `127.0.0.1:8100` OK 但 `<iphone-ip>:8100` timeout，请先在 iPhone 上把：

`Settings -> Apps -> WebDriverAgentRunner-Runner -> Wireless Data`

从 **Off** 改成 **WLAN** 或 **WLAN & Cellular Data**。

### 2) 推荐：用 devicectl 启动“已安装的 WDA”（不再跑 xcodebuild test）

已验证在部分 iOS 17+ / 18 场景下，直接 `devicectl process launch` 需要加 `--no-activate` 才更稳定。

- 文档：`docs/recipes/run_wda_preinstalled_devicectl.md`
- 脚本：`scripts/run_wda_preinstalled_devicectl.sh`

你可以先把 Runner 安装一次、手动打开 Wireless Data，后续只用脚本 `start/stop` 启动/停止，不再触发频繁重装。

### 3) 仍想走 xcodebuild，但希望更快重启：build-for-testing + test-without-building

如果你接受 “WDA 仍由 UI Test 启动”，但不想每次都重新编译，可以：

- 文档：`docs/recipes/run_wda_xcodebuild.md`
- 脚本：`scripts/run_wda_xcodebuild.sh`

### 4) 可选：Appium 的 preinstalled WDA（减少环境坑位）

如果你更希望用成熟工具链来维护 XCTest 会话，可选 Appium XCUITest driver 的 `usePreinstalledWDA` 路径。

为了避免 Node/Appium 版本差异（例如某些环境会遇到 `uuid` 的 ESM/CJS 兼容错误），文档与脚本使用 `npx` 固定版本：

- 文档：`docs/recipes/run_wda_preinstalled_appium.md`
- 脚本：`scripts/run_wda_preinstalled_appium.sh`

### 5) USB 稳定兜底：iproxy 固定访问 127.0.0.1

如果你只需要稳定可用，不在乎 `<iphone-ip>:8100`，最稳的是用 `iproxy` 把设备侧 8100 转发到本机，然后始终访问 `http://127.0.0.1:8100`。

仓库提供“从源码编译安装 iproxy（不依赖 Homebrew）”的 recipe 与脚本：

- 文档：`docs/recipes/iproxy_from_source.md`
- 脚本：`scripts/install_iproxy_from_source.sh`

## 可公开复现的去隐私处理

上述脚本与文档均使用占位符（`<UDID>` / `<IPHONE_IP>` / `<WDA_DIR>` 等），不包含任何真实设备名称、UDID、内网 IP、用户名路径等个人信息。

