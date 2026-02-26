# 下一阶段重构路线图（Runner/Console 可维护性）

本文档用于记录“下一阶段（非紧急）”的重构方向与可落地拆分方案，避免后续在压缩上下文时丢失关键共识。

目标不是立刻做功能扩展，而是**降低维护成本**、**减少回归半径**、**提升可测试性/可审阅性**，并为后续性能/可靠性优化打基础。

---

## 0. 当前状态（重构动机）

当前代码复杂度高度集中在两个“巨型文件”：

- Runner（WDA overlay）：`wda_overlay/WebDriverAgentRunner/UITestingUITests.m`（~7k 行）
  - 集中承载：路由（/agent/*）、HTML/JS Web UI、SSE events、配置存储、LLM 请求（Responses/Chat）、解析与纠错、动作执行、Notes/Plan、日志与导出、安全鉴权等。
- Console（SwiftUI）：`apps/OnDeviceAgentConsole/OnDeviceAgentConsole/ContentView.swift`（~3k 行）
  - 集中承载：UI 结构、导出/分享、对话呈现与 raw 视图、部分业务逻辑与状态拼装等。

这会导致：

- 修改任何一小块逻辑都容易触发“大范围改动”，review 和回归成本高。
- 真机问题定位需要在同一个文件里跨越多个领域跳转（网络/安全/UI/Agent runtime）。
- SwiftUI 超大 View 文件也会拖慢编译、降低可读性与组件复用能力。

---

## 1. 重构原则（避免“重构变重写”）

### 1.1 行为不变优先

- 先做“物理拆分 + 接口边界”，尽量不改业务行为。
- 只有在拆分过程中发现明显 bug 或安全缺陷时，才做**最小修复**并写明回归点。

### 1.2 不依赖 submodule 工作区状态

- 本仓库的“真实改动源”是 `patches/*.patch` 与 `wda_overlay/`。
- 任何重构都应保持 patch/overlay 同步：优先改 `patches/...patch`，再用脚本更新 overlay（或反向，但要保持一致）。
- 避免把“需要本机签名文件/TeamID”的改动留在 `third_party/WebDriverAgent` 的 tracked 视野里。

### 1.3 小步提交、可回滚

- 每一步重构尽量做到“可单独回归验证”，避免一次性把所有模块都拆完。
- 每步提交在说明里包含：拆分范围、符号迁移、回归清单（至少 3 条）。

---

## 2. Runner：拆分目标（把 `UITestingUITests.m` 拆成可读模块）

### 2.1 推荐的模块划分（最小可行）

> 下面是“先拆职责，再逐步稳定接口”的路径；初期可以先拆成多个 `.m` + 一个共享 `.h`（或直接在 `.m` 内部用 `@interface` 分类），不强求立刻做成 framework。

#### A) Prompt 模板与序列化（纯字符串/纯数据）

- 文件建议：
  - `wda_overlay/WebDriverAgentRunner/OnDeviceAgentPrompts.h`
  - `wda_overlay/WebDriverAgentRunner/OnDeviceAgentPrompts.m`
- 职责：
  - 默认 system prompt 模板（含日期占位符说明）
  - plan/notes 的模板片段
  - web UI 中提示文本的模板（若仍放在 Runner 内）
- 迁移目标（示例）：
  - `OnDeviceAgentDefaultSystemPromptTemplate()`
  - 与 prompt 拼装相关的 helper（格式化、占位符替换）

#### B) Agent Runtime（每步循环/状态机/截断策略）

- 文件建议：
  - `wda_overlay/WebDriverAgentRunner/OnDeviceAgentRuntime.h`
  - `wda_overlay/WebDriverAgentRunner/OnDeviceAgentRuntime.m`
- 职责：
  - step loop：截图→构造消息→发模型→解析 action→执行→记录结果
  - Responses/Chat 分流 + previous_response_id 管理
  - “重启历史/截断”策略与条件（例如 by plan）
  - Notes/Plan 的更新入口（但 merge 逻辑可以放到单独文件）
- 迁移目标：
  - `- (void)startAgentWithConfig...`
  - `- (void)runStep...`
  - 与“什么时候重启/什么时候 Finish”相关的判断

#### C) Plan/Notes 合并与工作记忆（纯数据处理）

- 文件建议：
  - `wda_overlay/WebDriverAgentRunner/OnDeviceAgentMemory.h`
  - `wda_overlay/WebDriverAgentRunner/OnDeviceAgentMemory.m`
- 职责：
  - plan 合并策略（当前存在 monotonic merge / id 规则等）
  - notes ledger / 校验逻辑（如果未来要做）
  - “将 plan 转成 checklist 文本”的呈现函数（供 prompt 拼装）
- 迁移目标：
  - `- mergePlanChecklist...`
  - `- planChecklistText`
  - `- doneCountForPlan:`

#### D) Model Client（HTTP 请求、脱敏、TLS 策略、token usage）

- 文件建议：
  - `wda_overlay/WebDriverAgentRunner/OnDeviceAgentModelClient.h`
  - `wda_overlay/WebDriverAgentRunner/OnDeviceAgentModelClient.m`
- 职责：
  - 组装请求体（Responses / Chat Completions）
  - URLSession + timeout + TLS 跳过（严格限定“只作用于模型服务请求”）
  - response 解析：reasoning/content/tooling fields 的抽取
  - token usage 累计与返回
  - raw request/response 的脱敏（或放到 Exports）

#### E) Actions（把 action.name/params 落到设备操作）

- 文件建议：
  - `wda_overlay/WebDriverAgentRunner/OnDeviceAgentActions.h`
  - `wda_overlay/WebDriverAgentRunner/OnDeviceAgentActions.m`
- 职责：
  - Tap/Swipe/Type/Launch 等动作执行
  - Swipe 具体实现策略（W3C actions / XCUITest fallback）
  - 参数校验（invalid_params）与 recoverable error 生成
  - “动作可视化标注”相关逻辑（如果属于执行层）

#### F) Web UI + Routes（/agent、/agent/status、/agent/events…）

- 文件建议：
  - `wda_overlay/WebDriverAgentRunner/OnDeviceAgentRoutes.h`
  - `wda_overlay/WebDriverAgentRunner/OnDeviceAgentRoutes.m`
  - `wda_overlay/WebDriverAgentRunner/OnDeviceAgentWebUI.m`（可选：把 HTML/JS 大字符串放这里）
- 职责：
  - 路由注册（GET/POST）
  - SSE events 输出
  - status/logs/chat/config 的序列化
  - reset / factory reset 行为
- 注意：
  - routes 里尽量只做“参数解析 + 调 runtime”，避免继续堆业务逻辑。

#### G) Security（LAN 鉴权、token 存储、peerIP 判定）

- 文件建议：
  - `wda_overlay/WebDriverAgentRunner/OnDeviceAgentSecurity.h`
  - `wda_overlay/WebDriverAgentRunner/OnDeviceAgentSecurity.m`
- 职责：
  - Agent Token 签发/轮换/校验（header/cookie/query）
  - 仅 loopback 免 token 的判断（基于 TCP peer IP，而不是 Host header）
  - Keychain 存储（token、可选 api_key 等）
  - 脱敏策略（可放到 Exports，但建议安全相关的常量集中）

#### H) Exports（HTML/JSONL、脱敏、长文本处理）

- 文件建议：
  - `wda_overlay/WebDriverAgentRunner/OnDeviceAgentExports.h`
  - `wda_overlay/WebDriverAgentRunner/OnDeviceAgentExports.m`
- 职责：
  - 导出结构化对话（图文/原始 JSON）
  - 长截图/图片缩放（如果属于导出）
  - 全链路脱敏（Bearer token、api_key、agent token、base64 image）

### 2.2 拆分的落地步骤（建议顺序）

1. **先拆纯函数**：Prompts / Memory（Plan/Notes）/ Redaction
   - 风险最低，回归最容易。
2. **再拆安全与存储**：Security（Keychain/token/peerIP）
   - 目标：把“鉴权门禁”从业务逻辑中剥离出来。
3. **再拆 Model Client**：Responses/Chat 构造与解析
   - 目标：让 Runtime 只关心“输入→输出”，不关心 HTTP 细节。
4. **最后拆 Routes 与 Web UI**：把 HTML/JS 与 route handlers 分离
   - 目标：减少 `UITestingUITests.m` 的“前端字符串噪音”。
5. **最后收口 Runtime**：把 step loop 稳定在一个文件里
   - Runtime 内只保留“状态机/调度”，其它功能都靠模块调用。

### 2.3 每一步的回归清单（Runner 通用）

每次拆分后至少跑：

- `GET /agent/status`：能返回（含 token gate 逻辑正确）
- `GET /agent`：页面能加载，能 Start/Stop
- 跑一个 5～10 步的真实任务：
  - 至少包含 `Tap` / `Type` / `Swipe` / `Note`
  - 导出 HTML 能打开，敏感信息被脱敏
- `bash scripts/check_wda_patch_sync.sh`：patch/overlay 同步（如果项目使用该脚本）

---

## 3. Console：拆分目标（降低 SwiftUI 巨型 View 成本）

### 3.1 结构拆分建议（最小可行）

把 `ContentView.swift` 拆成“按 Tab/页面”与“按组件”两层：

- 页面级（建议每个页面一个文件）：
  - `RunView.swift`
  - `LogsView.swift`
  - `ChatView.swift`
  - `NotesView.swift`
  - `Settings/ModelServiceView.swift`
  - `Settings/SystemPromptView.swift`
  - `Settings/LimitsView.swift`
  - `Settings/AdvancedView.swift`
  - `Settings/RunnerView.swift`
  - `Settings/ResetView.swift`
- 组件级（可复用）：
  - `CardSection.swift`（统一卡片样式/标题/说明）
  - `KeyValueRow.swift`（常见字段展示）
  - `ActionToggleRow.swift`
  - `TokenUsageCard.swift`
  - `ConversationMessageView.swift`（图文消息）
  - `RawJSONView.swift`（pretty JSON/折叠 details）

### 3.2 业务逻辑边界

- 网络与状态机尽量都落在 `ConsoleStore.swift` / `AgentClient.swift`。
- View 只负责渲染与输入绑定，避免“导出/脱敏/解析”散落在多个 View 内。

### 3.3 Console 回归清单

- Run 页：配置缺失时能给出可执行提示（如缺 api_key / runner 不可达）
- Chat 页：图文回放、raw 切换、导出（HTML/JSONL）正确脱敏
- 本地化：中英文切换时关键页面无硬编码英文残留

---

## 4. 其它建议（工程化但不紧急）

- 建立 `scripts/` 的“真机回归 checklist”脚本化入口（即便最终仍要人工点）
- 把“重要共识”写入 docs：
  - patch/overlay 的真源与同步规则
  - 安全模型：loopback 免 token、LAN 必须 token、不要暴露公网等

---

## 5. 不做/延后（明确非目标）

以下内容可以在完成上述拆分后再做：

- 引入更复杂的 UI tree / element selector 能力（属于范式升级）
- 大规模功能扩展（Apple Watch、更多设备）
- 彻底替换 Web UI（目前先以稳定/可维护为主）

