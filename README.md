# 基于 WebDriverAgent 的 iOS 端侧 Agent

这个仓库提供一个 **实验性** 方案：把 GUI Agent 的闭环（截图 → 调 LLM → 解析动作 → 执行）塞进 `WebDriverAgentRunner-Runner`（`.xctrunner`）的测试进程里运行。

你不需要在电脑上跑任何 Python 循环；配置（`base_url/model/api_key/task` 等）可以在 iPhone 或本地局域网机器上直接填写，然后让 Runner 在手机上自己跑。

> 仍然需要 macOS + Xcode（至少一次）把 Runner 编译/安装到 iPhone 上；WDA/XCTest 才有跨 App 自动化能力。

---

## 灵感来源

本项目受到以下产品/项目启发：

- 豆包手机（Doubao Phone）的手机端 Agent 交互形态
- Open-AutoGLM 开源项目

## 本仓库提供了什么

- 一个对 WebDriverAgent (WDA) 的补丁：
`patches/webdriveragent_ondevice_agent_webui.patch`
  - 增加一个手机端或局域网机器可访问的页面：`GET /agent`
  - 在该页面输入 `base_url/model/api_key/task`，点击 Start/Stop 即可
  - Agent 循环在 Runner 进程内执行：截图、调用 LLM、执行 tap/swipe/type 等

补丁会新增这些 endpoints（都挂在 WDA 的同一个 8100 端口上）：

- `GET /agent`：配置/启动页面（HTML）
- `GET /agent/status`：当前运行状态（JSON）
- `GET /agent/logs`：最近日志（JSON）
- `GET /agent/chat`：对话历史（JSON）
- `GET /agent/traces`：已记录的 canonical trace 列表（JSON）
- `GET /agent/trace/manifest`：指定 trace 的 manifest（JSON）
- `GET /agent/trace/turns`：指定 trace 的逐步 turn JSONL
- `GET /agent/trace/file`：指定 trace 内的截图等文件（base64 JSON）
- `POST /agent/config`：保存配置（JSON body）
- `POST /agent/start`：保存配置并启动（JSON body）
- `POST /agent/stop`：停止（无需 body）
- `POST /agent/reset`：重置运行态（不清空 base_url/model/task，不删除已记住的 API key）

---

## 操作流程

### 0) 拉取 WebDriverAgent 子模块

本仓库用 `git submodule` 固定引用了 WebDriverAgent（WDA）源码（位于 `third_party/WebDriverAgent`）。

首次 clone 后执行：

```bash
git submodule update --init --recursive
```

### 1)（首次使用）Xcode + Personal Team（免费）一次性准备

如果你是第一次用 Xcode / Personal Team（免费账号），建议先按这份文档把环境跑通（包含：登录 Apple ID、开启 Developer Mode、验证签名链路等）：

- `docs/recipes/xcode_personal_team_quickstart.md`

### 2) 配置 WDA 的签名与 bundle id（脚本方式）

你需要准备两个占位符：

- `<TEAMID>`：Xcode 里显示的 Team ID（通常 10 位大写字母数字）
- `<com.your.prefix>`：你自己的 bundle id 前缀（反向域名风格），建议选定后一直固定使用

在仓库根目录执行：

```bash
bash scripts/configure_wda_signing.sh --team-id <TEAMID> --bundle-prefix <com.your.prefix>
```

> 这个脚本只修改你本地的 `third_party/WebDriverAgent` 工作区，不会把个人信息写进本仓库的提交里（但请不要把 submodule 的改动提交出去）。

### 3) iPhone 权限：确保 WDA 的 8100 可达（Wi‑Fi 直连场景）

并确认 iPhone 上：

`Settings -> Apps -> WebDriverAgentRunner-Runner -> Wireless Data` 不是 Off（选 WLAN 或 WLAN & Cellular Data）

否则 `http://<iphone-ip>:8100/...` 可能不可达（`127.0.0.1` 往往仍可达）。

### 4) 在子模块 WDA 目录里应用补丁

在 `third_party/WebDriverAgent` 目录中执行：

```bash
cd third_party/WebDriverAgent
git apply ../../patches/webdriveragent_ondevice_agent_webui.patch
```

或者用脚本一键执行（等价于上面两行）：

```bash
bash scripts/apply_patch_to_wda.sh
```

### 5) 重新安装一次 Runner（让补丁生效）

因为你修改了 WDA 源码，需要重新编译/安装一次 `WebDriverAgentRunner-Runner` 到 iPhone。

之后你只要不再改 WDA 代码，就不需要每次都重新装。

推荐直接用本仓库脚本安装一个“prepared Runner”（更适合点开即用的 on-device 形态）：

```bash
bash scripts/install_wda_prepared_runner.sh --device <UDID>
```

你也可以用其它方式重新安装/启动（例如 Xcode `Product -> Test` / `xcodebuild ... test`）。

### 6) 在 iPhone 上直接配置并运行

在 iPhone 的 Safari 打开：

- `http://127.0.0.1:8100/agent`（推荐：不依赖 Wi‑Fi LAN 可达）

或（Wi‑Fi 可达时）：

- `http://<iphone-ip>:8100/agent`

在页面里填：
- `Base URL`（OpenAI-compatible，例如 `https://...` 或本地网关）
- `Model`
- `API Key`（如果你的服务需要）
- `Task`

然后点击 **Start**。

### 7)（可选）用原生 SwiftUI App 代替 Safari 网页

仓库内带一个原生 iOS 控制台 App：`apps/OnDeviceAgentConsole`。

它会调用 `http://127.0.0.1:8100/agent/*` 这套接口完成配置/启动/日志/对话等功能（执行端仍然是 WDA Runner）。

参考：`docs/recipes/ondevice_agent_console_app.md`

### 8) 导出训练轨迹、HTML viewer 和 review 视频

Runner 运行结束后，可以把 on-device agent 的 canonical trace 导出成训练数据目录：

```bash
python3 tools/wda_training_export.py \
  --base-url http://127.0.0.1:8100 \
  --out-dir training_dataset \
  --source auto \
  --include-parsed-json \
  --include-repair-samples
```

输出目录会包含：

- `trace.json`：canonical trace，保留 run manifest、system prompt、每一步状态、模型响应、解析结果、动作结果和截图引用
- `dataset.jsonl`：状态/截图/action 训练样本
- `messages.jsonl`：chat SFT 格式样本
- `repair_samples.jsonl`：可选的 action 修复样本
- `images/`：逐步截图
- `run_meta.json`：导出元数据和计数

如果通过局域网访问 iPhone，并且已配置 Agent Token：

```bash
export WDA_AGENT_TOKEN="<your-token>"
python3 tools/wda_training_export.py --base-url http://<iphone-ip>:8100 --out-dir training_dataset
```

如果你的终端设置了代理环境变量，导出到 `127.0.0.1` 或 iPhone 局域网 IP 时建议绕过代理：

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

只导出一个轻量 HTML 报告时，可以使用：

```bash
python3 tools/wda_rich_export.py --base-url http://127.0.0.1:8100 --html agent_report.html
```

### 9)（开发者可选）本地调试工具

仓库提供一组本地调试脚本（用于研发/回归，不是终端用户必需）：

- `tools/wda_remote_tool.py`：控制 `/agent/*`、导出 chat/log、生成 HTML 报告
- `tools/wda_rich_export.py`：导出带配置、日志、token usage 和动作标注的 HTML 报告
- `tools/wda_training_export.py`：导出 canonical trace、训练 JSONL 和截图
- `tools/wda_training_viewer.py`：为训练数据目录生成静态 HTML viewer
- `tools/wda_training_video.py`：把训练数据目录渲染成 review MP4
- `tools/wda_longshot.py`：通过 WDA 采集并拼接长截图
- `tools/macos_remote_tool.py`：在 macOS 本机做 app 打开/激活、点击/滑动、截图

说明见：`tools/README.md`

### 10) 豆包（火山方舟）接入与缓存说明

豆包模型（火山方舟 Ark）接入步骤、API Key 获取、Responses 缓存开通与配置已整理为独立文档：

- `docs/recipes/volcengine_doubao_setup.md`

---

## Disclaimer / 免责声明

### 中文

本项目提供基于 WebDriverAgent（WDA）的 iOS UI 自动化能力，仅用于学习、研究与开发测试。

使用前请注意：

- 授权与合规：仅在你拥有或已获明确授权的设备、账号与应用上使用。对第三方 App 的自动化操作可能违反其服务条款或当地法规，后果由你自行承担。
- 风险操作：自动化可能发生误触/误输入，导致数据修改、信息泄露、下单/支付等不可逆操作。涉及资金、隐私或重要账号（如银行/支付/企业管理后台）请谨慎使用，并优先启用人工确认/接管流程。
- 安全：不要将 WDA/Runner 的端口（默认 8100）暴露到公网。若启用了局域网访问，请启用并妥善保管 Agent Token。在不可信网络中不要开启“跳过 TLS 校验”，否则 API 密钥可能遭中间人攻击泄露。
- 隐私：运行过程中可能产生屏幕截图、日志与导出报告，其中可能包含敏感信息。分享或提交 issue 前请自行脱敏与清理。
- 无担保：本项目按“原样（AS IS）”提供，不对任何直接或间接损失负责。你使用本项目即表示理解并接受上述风险。

### English

This project provides iOS UI automation based on WebDriverAgent (WDA) for learning, research, and development/testing purposes only.

Please read before use:

- Authorization & compliance: Use only on devices, accounts, and apps you own or are explicitly authorized to access. Automating third‑party apps may violate their Terms of Service and/or local laws. You are solely responsible for any consequences.
- Risky actions: Automation can mis-click or mis-type, potentially causing irreversible actions such as data modification, information disclosure, ordering, or payments. Be extra cautious with financial/privacy‑sensitive apps (e.g., banking/payment/admin consoles) and prefer human confirmation/takeover.
- Security: Do not expose the WDA/Runner port (default 8100) to the public Internet. If LAN access is enabled, use and protect an Agent Token. Do not enable “skip TLS verification” on untrusted networks, or your API key may be exposed to MITM attacks.
- Privacy: Screenshots, logs, and exported reports may contain sensitive data. Redact and clean them before sharing or filing issues.
- No warranty: This project is provided “AS IS”, without warranties of any kind, and the authors are not liable for any damages. By using this project, you acknowledge and accept these risks.

---

## License

- This repository is primarily licensed under the Apache License 2.0 (see `LICENSE`).
- WebDriverAgent (submodule) is licensed under BSD 3‑Clause, and some files in this repo are derived from it (see `THIRD_PARTY_NOTICES.md`).
