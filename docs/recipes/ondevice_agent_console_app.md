# iOS 原生控制台 App（SwiftUI）使用说明

本仓库自带一个原生 iOS 控制台 App：`apps/OnDeviceAgentConsole`。

它的定位是：**替代 Safari 网页**，用原生 UI 调用 WDA Runner 暴露的 `/agent/*` 接口来完成配置、启动/停止、查看日志/对话/Notes。

> 重要：它 **不会** 取代 WebDriverAgentRunner-Runner（执行端仍在 Runner 里）。  
> 你仍然需要先把“prepared Runner”安装到 iPhone，并确保 WDA 在跑（8100 可达）。

---

## 前置条件

- macOS + Xcode
- 已完成 WDA Runner 安装（参考 `README.md`）
- iPhone 上能打开 WDA Runner，并且 `http://127.0.0.1:8100/status` 可访问

---

## 运行步骤

1) 打开 Xcode 工程：

- `apps/OnDeviceAgentConsole/OnDeviceAgentConsole.xcodeproj`

2) 选择 iPhone 真机作为运行目标。

3) 配置签名：

- `Signing & Capabilities` → 选择你的 Team（Personal Team 免费账号即可）
- 如有需要，改一个你自己的 `Bundle Identifier`

4) Run（安装并启动 App）。

5) 先在 iPhone 上启动 `WebDriverAgentRunner-Runner`（让 WDA 跑起来）。

6) 打开控制台 App：

- 默认连接 `http://127.0.0.1:8100`
- 填入 `Base URL / Model / API Key / Task` 等参数
- 点击 Start/Stop/Reset 即可

---

## 常见问题

### 1) App 提示连不上 /agent/status

- 确认 WDA Runner 已经在跑：`http://127.0.0.1:8100/status`
- 如果你换成了 `http://<iphone-ip>:8100`，可能需要：
  - iPhone 上 Runner 的 `Wireless Data` 不是 Off
  - iOS 的“本地网络权限”允许该 App 访问局域网

### 2) 为啥 App 不能直接跨 App 操作小红书/飞书？

普通 iOS App 没有跨 App UI 自动化能力；执行端必须由 WDA/XCTest 这类系统测试能力来完成。

---

## 开发调试补充（可选）

如果你在做研发排障，而不是日常使用，可以配合仓库根目录 `tools/` 下的脚本：

- `tools/wda_remote_tool.py`：直接调 `/agent/*` 接口并导出 chat/log/report
- `tools/wda_longshot.py`：抓取并拼接长截图（适合审查 Run 页完整 UI）
- `tools/macos_remote_tool.py`：在 macOS 本机做打开 app / 点击 / 滑动 / 截图

详细用法见 `tools/README.md`。
