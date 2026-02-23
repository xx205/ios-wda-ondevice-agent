# 修复指导与验证方法（2026-02-23）

本文件用于记录本次 code review 提到的 **可复现问题**、**修复要点** 与 **验证步骤**，避免后续重复踩坑。

## 背景（Review 指出的问题）

### 1) Console 导出脱敏缺陷：`ondevice_agent_token` 可能泄露

- 位置：`apps/OnDeviceAgentConsole/OnDeviceAgentConsole/ContentView.swift`
- 症状：`redactSensitiveText()` 的正则在 Swift raw string 中写成了 `\\b...`，导致对 cookie 形态的
  `ondevice_agent_token=...` **匹配失败**，从而在导出（Raw JSONL / HTML）里可能出现明文 token。

### 2) 回归脚本依赖了错误的 WDA 源码来源

问题点：仓库的 Runner/WDA 改动以 `patches/webdriveragent_ondevice_agent_webui.patch` 为真源，
`wda_overlay/` 是由 patch 派生的可读镜像；而 `third_party/WebDriverAgent` 可能未初始化/未打补丁，
导致脚本要么失败、要么检查到“未打补丁”的代码，无法稳定发现回归。

- `scripts/test_plan_merge_regressions.py` 读取了 `third_party/.../UITestingUITests.m`
- `scripts/check_no_secrets_regressions.sh` 读取了 `third_party/.../UITestingUITests.m` / `third_party/.../FBRouteRequest.m`

## 修复要点（按最小改动）

### A. 修复脱敏正则并加单测

1. 将脱敏逻辑抽到可测试的工具函数（建议：`apps/OnDeviceAgentConsole/OnDeviceAgentConsole/Utilities/ConsoleRedaction.swift`）。
2. 修正 cookie token 的正则：在 raw string 中使用 `\b`（而不是 `\\b`），确保能匹配：
   - `ondevice_agent_token=...`
   - `Cookie: ondevice_agent_token=...; other=...`
3. 增加单测覆盖：输入包含 `ondevice_agent_token=secret`，输出应为 `ondevice_agent_token=<redacted>`。

### B. 修复回归脚本路径：检查 `wda_overlay/`（而非 `third_party/`）

1. `scripts/test_plan_merge_regressions.py`
   - 将 `WDA_FILE` 指向：`wda_overlay/WebDriverAgentRunner/UITestingUITests.m`
2. `scripts/check_no_secrets_regressions.sh`
   - 将 Runner 相关文件指向：
     - `wda_overlay/WebDriverAgentRunner/UITestingUITests.m`
     - `wda_overlay/WebDriverAgentLib/Routing/FBRouteRequest.m`

> 备注：是否需要额外扫描 patch 文件本身要谨慎（patch 里可能包含“被删除的危险代码”文本，
> 直接 grep patch 可能引入误报）。本次先以“实际可运行代码（overlay）”为准，并依赖
> `scripts/check_wda_patch_sync.sh` 保证 overlay 与 patch 一致。

## 验证步骤（按顺序执行）

### 1) 基础一致性（patch ↔ overlay）

```bash
bash scripts/check_wda_patch_sync.sh
```

### 2) 安全回归脚本

```bash
bash scripts/check_no_secrets_regressions.sh
```

### 3) Plan merge 回归脚本

```bash
python3 scripts/test_plan_merge_regressions.py
```

### 4) Console 单元测试（推荐）

根据本机 Xcode / iOS Simulator 情况选择可用 destination，例如：

```bash
xcodebuild test \
  -project apps/OnDeviceAgentConsole/OnDeviceAgentConsole.xcodeproj \
  -scheme OnDeviceAgentConsole \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -configuration Debug
```

## 验收标准（这次修复完成的定义）

- 导出（Raw JSONL / HTML）中不出现明文 `ondevice_agent_token=...`
- `scripts/test_plan_merge_regressions.py` 不依赖 `third_party/` 的初始化/补丁状态，稳定通过
- `scripts/check_no_secrets_regressions.sh` 不依赖 `third_party/` 的初始化/补丁状态，稳定通过
- `scripts/check_wda_patch_sync.sh` 仍通过

