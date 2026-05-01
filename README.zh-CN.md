# 基于 WebDriverAgent 的 iOS 端侧 Agent

[English](README.md) | [简体中文](README.zh-CN.md)

这个仓库提供一个 **实验性** 方案：把 GUI Agent 的闭环放进 `WebDriverAgentRunner-Runner`（`.xctrunner`）测试进程里运行。

循环在 iPhone 端的 Runner 进程内执行：

```text
截图 -> 调 LLM -> 解析动作 -> 执行 tap/swipe/type
```

你不需要在 Mac 上常驻一个 Python 控制循环。Agent 可以直接在 iPhone Safari 或同一局域网内的机器上配置，配置项包括 `base_url`、`model`、`api_key`、`task` 等。

> 仍然需要 macOS + Xcode 至少一次，把 Runner 编译并安装到 iPhone 上。WDA/XCTest 才是 iOS 跨 App UI 自动化能力的来源。

## 最短路径

```bash
git submodule update --init --recursive
bash scripts/configure_wda_signing.sh --team-id <TEAMID> --bundle-prefix <com.your.prefix>
bash scripts/apply_patch_to_wda.sh
bash scripts/install_wda_prepared_runner.sh --device <UDID>
```

然后在 iPhone 上：

1. 打开 `WebDriverAgentRunner-Runner`。
2. 打开 Safari。
3. 访问 `http://127.0.0.1:8100/agent`。
4. 填入 `Base URL`、`Model`、`API Key`（如需要）和 `Task`。
5. 点击 **Start**。

## 本仓库提供了什么

本仓库提供一个 WebDriverAgent 补丁：

```text
patches/webdriveragent_ondevice_agent_webui.patch
```

补丁会增加：

- `GET /agent`：从 WDA 同一个端口（通常是 `8100`）提供 Web UI。
- 在 iPhone 或局域网机器上配置 Agent：`base_url`、`model`、`api_key`、`task` 等。
- 在 Runner 进程内执行 Agent 循环：截图、LLM 调用、动作解析、动作执行。
- 训练轨迹、HTML 报告、review 视频所需的导出接口。

## 前置条件

- macOS，并已安装 Xcode。
- 一台已开启 Developer Mode 的 iPhone。
- Apple Developer Team ID。Personal Team 足够本地测试。
- 唯一的 bundle identifier 前缀，例如 `com.yourname.wda`。
- 目标设备 UDID。可以在 Xcode 里查看，也可以运行：

```bash
xcrun devicectl list devices
```

安全注意事项：

- 不要把 WDA/Runner 端口（默认 `8100`）暴露到公网。
- 局域网访问 `/agent/*` 必须使用 Agent Token。分享访问链接前，请先配置并妥善保管 token。
- 不要在不可信网络里开启“跳过 TLS 校验”，否则 API Key 可能被中间人攻击泄露。

## 快速开始

### 1. 拉取 WebDriverAgent 子模块

本仓库用 git submodule 固定引用 WebDriverAgent，路径是 `third_party/WebDriverAgent`。

```bash
git submodule update --init --recursive
```

### 2. 准备 Xcode 签名

如果你是第一次使用 Xcode 或 Personal Team，先按这份文档跑通环境：

- `docs/recipes/xcode_personal_team_quickstart.md`

然后配置 WDA 签名和 bundle identifier：

```bash
bash scripts/configure_wda_signing.sh --team-id <TEAMID> --bundle-prefix <com.your.prefix>
```

这个脚本只修改你本地的 `third_party/WebDriverAgent` 工作区。Team ID 会写入子模块内的本地 xcconfig 文件。不要提交这些子模块改动。

### 3. 应用 on-device agent 补丁

```bash
bash scripts/apply_patch_to_wda.sh
```

执行后，`git status` 里看到 `m third_party/WebDriverAgent` 是预期现象。补丁需要应用到子模块工作区，Runner 才会暴露 `/agent/*`。

### 4. 安装 prepared Runner

因为补丁修改了 WDA 源码，需要重新编译并安装一次 `WebDriverAgentRunner-Runner`：

```bash
bash scripts/install_wda_prepared_runner.sh --device <UDID>
```

这个脚本会构建 WDA，把 Runner app 处理成更适合直接点开运行的形式，重新签名，并安装到设备上。

你也可以使用 Xcode `Product > Test`，或者按这份文档走 `xcodebuild` 流程：

- `docs/recipes/run_wda_xcodebuild.md`

### 5. 启动 WDA 并打开 Agent UI

在 iPhone 上：

1. 打开 `WebDriverAgentRunner-Runner`。
2. 打开 Safari。
3. 访问：

```text
http://127.0.0.1:8100/agent
```

这里的 `127.0.0.1` 指的是 iPhone 自己，因为 Safari 运行在 iPhone 上。如果你在 Mac 上通过 USB 访问 WDA，需要先用 `iproxy` 或其它端口转发方案，再在 Mac 上访问 `http://127.0.0.1:8100`。

如果通过局域网访问：

```text
http://<iphone-ip>:8100/agent
```

如果局域网访问不通，请检查 iPhone 上这个设置：

```text
Settings -> Apps -> WebDriverAgentRunner-Runner -> Wireless Data
```

应选择 `WLAN` 或 `WLAN & Cellular Data`，不能是 `Off`。

## 访问控制和 Agent Token

当前 Runner 代码对 loopback 和局域网请求采用不同的访问控制：

- iPhone 自己发起的 loopback 请求，例如在 iPhone Safari 打开 `http://127.0.0.1:8100/agent`，不需要 Agent Token。
- 非 loopback 请求，例如从同一 Wi-Fi 下另一台设备访问 `http://<iphone-ip>:8100/agent`，必须使用 Agent Token。
- 如果 Runner 里还没有保存 Agent Token，局域网请求会被拒绝，并返回 `LAN access denied. Set Agent Token in Console first.`
- 保存 token 后，局域网客户端还必须用下面任一方式带上 token。

创建或更新 token 的方式：

- 在 iPhone Safari 打开 Runner Web UI：`http://127.0.0.1:8100/agent`，点击 **Rotate token**。新 token 只显示一次，请妥善保存。
- 在原生控制台 App 中，使用 **Agent token (for LAN)** -> **Update token**。控制台 App 也可以复制访问链接。
- 程序化方式：从已经鉴权的客户端向 `/agent/config` 提交 `agent_token`。

客户端鉴权方式：

- 工具和原生客户端应发送 `X-OnDevice-Agent-Token: <token>` header。
- 仓库内 Python 工具支持 `--agent-token <token>` 或 `WDA_AGENT_TOKEN` 环境变量。
- 浏览器访问可以用 `http://<iphone-ip>:8100/agent?token=<token>` 作为 bootstrap 链接。token 有效时，Runner 会把它升级成名为 `ondevice_agent_token` 的 HttpOnly session cookie，并且 Web UI 会从地址栏移除 `?token=`。
- query token 只用于 Web 页面（`/agent` 和 `/agent/edit`）的初始访问。API 调用应使用 header 或 HttpOnly cookie。

示例：

```bash
export WDA_AGENT_TOKEN="<your-token>"
python3 tools/wda_remote_tool.py --base-url http://<iphone-ip>:8100 status
```

## 本地编译验证

如果只是想先确认当前项目能否编译，不想立刻处理真机和签名，可以使用下面这些命令。

编译原生 SwiftUI 控制台 App 到 iOS Simulator：

```bash
SIMULATOR_NAME="iPhone 17"

xcodebuild \
  -project apps/OnDeviceAgentConsole/OnDeviceAgentConsole.xcodeproj \
  -scheme OnDeviceAgentConsole \
  -destination "platform=iOS Simulator,name=$SIMULATOR_NAME" \
  -derivedDataPath /tmp/mobile_gui_build/OnDeviceAgentConsole \
  CODE_SIGNING_ALLOWED=NO \
  build
```

编译已打补丁的 WebDriverAgent Runner simulator `build-for-testing`：

```bash
xcodebuild \
  -project third_party/WebDriverAgent/WebDriverAgent.xcodeproj \
  -scheme WebDriverAgentRunner \
  -destination "platform=iOS Simulator,name=$SIMULATOR_NAME" \
  -derivedDataPath /tmp/mobile_gui_build/WebDriverAgent \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing
```

如果你的本机 simulator 名称不同，先列出可用设备：

```bash
xcrun simctl list devices available
```

## 原生控制台 App

仓库内带一个原生 SwiftUI 控制台 App：

```text
apps/OnDeviceAgentConsole
```

它调用 `http://127.0.0.1:8100/agent/*` 完成配置、启动、停止、重置、日志和对话查看。它不会取代 `WebDriverAgentRunner-Runner`，执行端仍然是 Runner。

控制台 App 也负责管理局域网访问：

- **Update token** 会生成新的 Agent Token 并同步到 Runner。
- **Copy access link** 会生成 `http://<iphone-ip>:8100/agent?token=<token>`，供同一局域网内的浏览器访问。

参考：

- `docs/recipes/ondevice_agent_console_app.md`

## 导出轨迹和报告

Runner 运行结束后，可以把 canonical trace 导出成训练数据目录：

```bash
python3 tools/wda_training_export.py \
  --base-url http://127.0.0.1:8100 \
  --out-dir training_dataset \
  --source auto \
  --include-parsed-json \
  --include-repair-samples
```

输出目录包含：

- `trace.json`：canonical trace，包含 manifest、prompt、状态、模型响应、解析动作、动作结果和截图引用。
- `dataset.jsonl`：状态/截图/action 样本。
- `messages.jsonl`：chat SFT 格式样本。
- `repair_samples.jsonl`：可选的 action 修复样本。
- `images/`：逐步截图。
- `run_meta.json`：导出元数据和计数。

如果通过局域网访问 iPhone，并且已配置 Agent Token：

```bash
export WDA_AGENT_TOKEN="<your-token>"
python3 tools/wda_training_export.py --base-url http://<iphone-ip>:8100 --out-dir training_dataset
```

如果你的终端设置了代理环境变量，访问本地或局域网 WDA 时建议绕过代理：

```bash
export NO_PROXY="127.0.0.1,localhost,<iphone-ip>"
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
```

PowerShell：

```powershell
$env:NO_PROXY = "127.0.0.1,localhost,<iphone-ip>"
Remove-Item Env:HTTP_PROXY,Env:HTTPS_PROXY,Env:ALL_PROXY,Env:http_proxy,Env:https_proxy,Env:all_proxy -ErrorAction SilentlyContinue
```

生成静态 HTML viewer：

```bash
python3 tools/wda_training_viewer.py --dataset-dir training_dataset
```

如果本机有 `ffmpeg`，可以生成 review 视频：

```bash
python3 tools/wda_training_video.py --dataset-dir training_dataset --out training_dataset/trace_review.mp4
```

导出轻量 HTML 报告：

```bash
python3 tools/wda_rich_export.py --base-url http://127.0.0.1:8100 --html agent_report.html
```

## 开发工具

仓库提供一组用于研发、回归和诊断的本地脚本：

- `tools/wda_remote_tool.py`：控制 `/agent/*`、导出 chat/log、生成 HTML 报告。
- `tools/wda_rich_export.py`：导出带配置、日志、token usage 和动作标注的 HTML 报告。
- `tools/wda_training_export.py`：导出 canonical trace、训练 JSONL 和截图。
- `tools/wda_training_viewer.py`：为训练数据目录生成静态 HTML viewer。
- `tools/wda_training_video.py`：把训练数据目录渲染成 review MP4。
- `tools/wda_longshot.py`：通过 WDA 采集并拼接长截图。
- `tools/macos_remote_tool.py`：在 macOS 本机做 app 打开/激活、点击/滑动、截图。

说明见：

- `tools/README.md`

## API 参考

补丁会在 WDA 同一个端口（通常是 `8100`）下新增这些接口：

- `GET /agent`：配置/启动页面。
- `GET /agent/edit`：用于编辑长 task 或 prompt 的全屏文本编辑页。
- `GET /agent/status`：当前运行状态。
- `GET /agent/logs`：最近日志。
- `GET /agent/chat`：对话历史。
- `GET /agent/traces`：已记录的 canonical trace 列表。
- `GET /agent/trace/manifest`：指定 trace 的 manifest。
- `GET /agent/trace/turns`：指定 trace 的逐步 JSONL。
- `GET /agent/trace/file`：指定 trace 内截图等文件的 base64 JSON。
- `GET /agent/events`：用于实时状态更新的 server-sent events stream。
- `GET /agent/step_screenshot`：单步截图的 base64 PNG。
- `GET /agent/step_screenshots`：批量导出多步截图。
- `POST /agent/config`：保存配置。
- `POST /agent/rotate_token`：生成并保存新的 Agent Token。
- `POST /agent/start`：保存配置并启动。
- `POST /agent/stop`：停止 Agent。
- `POST /agent/reset`：重置运行态，不清空 `base_url`、`model`、`task` 或已记住的 API key。
- `POST /agent/factory_reset`：停止 Agent 并清空已保存配置，包括 Agent Token 和已记住的 API key。

## 模型服务说明

豆包 / 火山方舟 Ark 接入、API Key 获取、Responses 缓存开通与配置见：

- `docs/recipes/volcengine_doubao_setup.md`

## 灵感来源

本项目受到以下产品/项目启发：

- 豆包手机（Doubao Phone）的手机端 Agent 交互形态。
- Open-AutoGLM 开源项目。

## 免责声明

本项目提供基于 WebDriverAgent（WDA）的 iOS UI 自动化能力，仅用于学习、研究与开发测试。

使用前请注意：

- 授权与合规：仅在你拥有或已获明确授权的设备、账号与应用上使用。对第三方 App 的自动化操作可能违反其服务条款或当地法规，后果由你自行承担。
- 风险操作：自动化可能发生误触/误输入，导致数据修改、信息泄露、下单/支付等不可逆操作。涉及资金、隐私或重要账号（如银行、支付、企业管理后台）请谨慎使用，并优先启用人工确认/接管流程。
- 安全：不要将 WDA/Runner 的端口（默认 `8100`）暴露到公网。若启用了局域网访问，请启用并妥善保管 Agent Token。在不可信网络中不要开启“跳过 TLS 校验”，否则 API Key 可能遭中间人攻击泄露。
- 隐私：运行过程中可能产生屏幕截图、日志与导出报告，其中可能包含敏感信息。分享或提交 issue 前请自行脱敏与清理。
- 无担保：本项目按“原样（AS IS）”提供，不对任何直接或间接损失负责。你使用本项目即表示理解并接受上述风险。

## License

- 本仓库主体使用 Apache License 2.0。见 `LICENSE`。
- WebDriverAgent 子模块使用 BSD 3-Clause license。本仓库部分文件派生自 WebDriverAgent。见 `THIRD_PARTY_NOTICES.md`。
