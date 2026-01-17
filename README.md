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

---

## 安全提醒（务必读）

- WDA 本身就是“远程控制手机”的能力：如果你的 `8100` 端口对局域网开放，任何能访问到的人都能操作你的手机。
- `/agent` 页面里会需要输入 `API key`。请不要把包含 key 的截图/日志直接贴公开论坛；必要时务必打码。

---

## License

- This repository is primarily licensed under the Apache License 2.0 (see `LICENSE`).
- WebDriverAgent (submodule) is licensed under BSD 3‑Clause, and some files in this repo are derived from it (see `THIRD_PARTY_NOTICES.md`).
