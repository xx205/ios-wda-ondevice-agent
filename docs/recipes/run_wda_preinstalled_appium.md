# 用 Appium “preinstalled WDA” 启动 WebDriverAgent（不再跑 xcodebuild test）

## 适用场景

你已经把 WebDriverAgent（WDA）装进 iPhone 了，但每次用 `xcodebuild ... test` 启动都会触发 Runner 安装/更新，从而把 iPhone 的

`Settings -> Apps -> WebDriverAgentRunner-Runner -> Wireless Data`

重置回 **Off**，导致 `http://<iphone-ip>:8100/status` 不可达（timeout）。

这个 recipe 的目标是：**WDA 只安装一次**，后续启动不再走 `xcodebuild test`，从而减少/避免该开关被反复重置。

---

## 关键解释：为什么直接 `devicectl process launch ...xctrunner` 容易失败？

WDA 的 WebServer 默认是由 UI Test 用例 `UITestingUITests/testRunner` 启动并常驻的（需要 XCTest 会话）。

所以仅仅执行：

```bash
xcrun devicectl device process launch --device <UDID> com.xxx.wda.xctrunner
```

在 iOS 17+ / 18 上常见会失败并退出，例如：

- `Failed to background test runner within 30.0s.`
- `Exiting due to IDE disconnection.`

实践上如果你想用 `devicectl` 直接启动已安装的 WDA，往往需要加 `--no-activate` 才稳定（见 `docs/recipes/run_wda_preinstalled_devicectl.md`）。

要“脱离 xcodebuild test”但仍然跑 UI Test，需要一个能在设备上启动 XCTest 会话的工具链。**Appium XCUITest driver 的 `usePreinstalledWDA`** 就是其中一个现成方案（iOS 17+ 通常会走 `devicectl`）。

如果你只是想“把 WDA 跑起来并保持可用”，更推荐直接使用 `devicectl --no-activate` 方案（`docs/recipes/run_wda_preinstalled_devicectl.md`），依赖更少、路径更短。

---

## 前置条件

1. macOS + Xcode（`xcrun` / `devicectl` 可用）。
2. iPhone 已配对、能被 Xcode 识别（USB 或 Wi‑Fi 均可）。
3. 你已经能在 Xcode 里至少跑通一次 WDA（确保签名/信任流程正确）。
4. Node.js + npm（用于安装 Appium）。

---

## 第 1 步：准备一个“可被 devicectl 启动”的 WDA Runner（iOS 17+ 必做）

> Appium 文档提示：iOS 17+ 下用 `devicectl` 启动 preinstalled WDA 时，Runner 包里不应包含 `Frameworks/XC*.framework`。  
> 直接 `rm -rf` 会破坏签名，所以必须 **删除 + 重新签名**。

### 1.1 找到 `WebDriverAgentRunner-Runner.app`

它通常在 Xcode DerivedData 里，例如：

```bash
ls ~/Library/Developer/Xcode/DerivedData/WebDriverAgent-*/Build/Products/Debug-iphoneos/WebDriverAgentRunner-Runner.app
```

如果你用的是自己的 DerivedData 路径，请按实际路径替换。

### 1.2 删除 `Frameworks/XC*.framework` 并重新签名（脚本自动做）

```bash
bash scripts/prepare_wda_runner_for_devicectl.sh \
  --app ~/Library/Developer/Xcode/DerivedData/WebDriverAgent-*/Build/Products/Debug-iphoneos/WebDriverAgentRunner-Runner.app \
  --out /tmp/WDA-Prepared
```

产物会在：

```bash
ls /tmp/WDA-Prepared/WebDriverAgentRunner-Runner.app
```

### 1.3 安装一次到设备

```bash
xcrun devicectl device install app --device <UDID> /tmp/WDA-Prepared/WebDriverAgentRunner-Runner.app
```

然后在 iPhone 上把 Wireless Data 打开一次（只要不被重装覆盖，通常能保持）：

- `Settings -> Apps -> WebDriverAgentRunner-Runner -> Wireless Data` → 选 **WLAN** 或 **WLAN & Cellular Data**

---

## 第 2 步：用 Appium 的 “preinstalled WDA” 启动（不跑 xcodebuild）

### 2.1 安装 Appium + XCUITest driver

> 注意：直接 `npm i -g appium` 可能会装到 Appium 3.x；同时 `appium driver install xcuitest` 默认安装最新 driver，可能与 server 版本不兼容。
> 为了减少环境差异，这里建议使用 `npx` 固定版本（你也可以自行替换成全局安装）。

```bash
npx -y appium@2.19.0 driver install xcuitest@7.6.0
```

### 2.2 启动并保持一个 Appium 会话（脚本自动做）

```bash
bash scripts/run_wda_preinstalled_appium.sh \
  --udid <UDID> \
  --wda-bundle-id <WDA_BASE_BUNDLE_ID>
```

说明：该脚本默认使用 `npx -y appium@2.19.0` 并确保安装 `xcuitest@7.6.0`，无需你额外全局安装 Appium。

这个脚本会：

1. 启动本机 Appium server；
2. 以 `usePreinstalledWDA=true` 创建一个会话（会触发启动 WDA）；
3. 保持进程不退出（`Ctrl-C` 才会清理并退出）。

> 注意：脚本运行期间不要同时用 Xcode 再跑 WDA（避免互相抢占）。

---

## 第 3 步：用本仓库的 /agent 页面跑任务

当 WDA 已启动后，你可以直接跑：

```bash
# 在 iPhone 上（推荐，不依赖局域网可达）
open "http://127.0.0.1:8100/agent"

# 或者（Wi‑Fi 可达时，局域网其它设备也能访问）
open "http://<iphone-ip>:8100/agent"
```

在页面里填写 Base URL / Model / API Key / Task，然后点击 Start。

如果你需要走 USB 稳定兜底（不依赖 Wi‑Fi LAN）：

1. 先用 `iproxy 8100 8100` 或 `iproxy -n 8100 8100` 把端口转发到本机；
2. 用 `http://127.0.0.1:8100/agent` 访问即可。
