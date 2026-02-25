# Responses 历史“按 Plan 分段重启”方案（实现计划）

目的：在 **Responses API（stateful, previous_response_id）** 模式下，以 **Plan Checklist** 的“完成项”为边界做“会话分段”，从而在不引入复杂总结/压缩逻辑的前提下，主动截断历史，降低长任务的跑偏与上下文膨胀风险。

> 状态：已实现（Runner 配置字段 `restart_responses_by_plan`）。本文档作为设计/行为约定继续保留，后续改动应与代码实现保持一致。

本方案强调 **最小改动**：
- 仅在“需要截断”的那一轮 **不传 previous_response_id**（或置空），等价于“开新会话链”。
- 其它流程保持不变（仍按当前方式附带 plan/notes/screen info + 截图）。
- 为了稳定性：**每次开新链的第一轮额外带一次 System Prompt + Task**（都只带一次）。

---

## 1. 前置条件（当前实现假设）

每一步发给模型的 user message 都会携带：
- `Plan Checklist`（如果存在）
- `Working Notes`（如果存在）
- `Screen Info`（current_app / bundle_id）
- 本步截图

并且模型输出的 action JSON 中包含可选字段：
- `plan`: checklist 数组（元素包含 `text` + `done`）
- `action`: 结构化动作对象

Runner 会在本地维护 `self.planChecklist`（经 sanitize 后）。

---

## 2. 何时触发“重启链”（核心策略）

### 2.1 基本规则

当且仅当检测到 **Plan Checklist 完成度提升** 时触发一次“重启链”：
- `done_count(new_plan) > done_count(old_plan)`

其中 `done_count(plan) = Σ item.done == true`（忽略无效 item）。

### 2.2 触发后“何时重启”

采用 **下一步重启**（而不是立刻在当前步重发）：
- 在 step N 解析到 plan 完成度提升后，设置标记：`restart_responses_chain_next_step = true`
- step N 正常执行当前模型给出的动作并继续
- step N+1 构造 Responses 请求时：
  - 不传 `previous_response_id`
  - 在输入中附带一次 **System Prompt + Task**（只这一轮）
  - 然后继续常规流程

理由：
- 避免“同一截图/同一 state”重复请求一遍模型（浪费与不稳定）。
- 对外行为更可预测：每个 step 仍然是一次“截图→请求→动作”闭环。

---

## 3. 重启链时带哪些信息（最小加固）

当 `restart_responses_chain_next_step == true` 时，构造 step N+1 的 user 文本：
- 在现有 `textContent` 前面加一段短前缀（建议固定格式，便于模型理解）：
  - `Task: <task 原文>`
  - （可选）`Checkpoint: Plan item completed`（一句即可）

其余内容不变：
- 仍然附带 `Plan Checklist` + `Working Notes` + `Screen Info`
- 仍然附带截图

说明：
- 不做额外“总结/压缩”，避免引入新的幻觉来源。
- Task 只在“新链第一轮”补一次，后续继续按当前逻辑（不重复贴 task）。
- System Prompt 在 Responses 新链第一轮需要随请求带上（建议作为 `developer` 消息；后续不重复）。

---

## 4. 抖动/误标 done 的防护（可选，默认先不做）

实际模型可能“过早把某项 done 打勾”，导致重启过于频繁。可以逐步加以下护栏（按成本从低到高）：

1) **最小间隔步数**
   - 例如：两次重启之间至少间隔 `min_restart_gap_steps = 3~5` 步

2) **只在计划稳定时触发**
   - 例如：同一条目在连续两步中都保持 `done=true` 才认为“完成度提升”

3) **限制可重启次数**
   - 例如：最多重启 `max_restarts_per_run = 5`，避免极端情况下 thrash

同时建议调整 System Prompt 中与 plan 相关的表述，避免与“done 触发重启”产生冲突：
- 只有在**确实完成且可验证**（屏幕/Notes/明确结果）时才将条目标记为 `done=true`。
- 不要为了“看起来进度更快”提前勾选 done；因为勾选 done 可能触发一次会话重启。
- 尽量只追加新条目（不要随意删除/重排）；避免频繁重排/来回勾选导致 done_count 抖动；建议保持精简（<=50 项，更多细节写入 Notes）。

---

## 5. 可观测性与回归点

### 5.1 运行日志/对话中应出现的信号
- 当完成度提升时：
  - `Plan updated`（已有）
  - 新增一条轻量日志：`responses_chain_restart_scheduled`（step=N）
- 当实际重启发生时：
  - 新增一条轻量日志：`responses_chain_restarted`（step=N+1）
  - 并且该 step 的 raw request 中应看到 `previous_response_id` 被省略/为空

### 5.2 行为回归
- 任务可继续执行，不因重启导致“忘记要做什么”
- 模型在新链第一步能重新拿到 Task 目标（无需依赖旧历史）
- token 使用量随时间增长更平滑（尤其是 input side）

---

## 6. 实施顺序（建议）

1) 实现基础规则（2.1 + 2.2 + 3）
2) 做一次真机验证（长任务 40+ 步），观察是否“重启过频”
3) 如有必要再加 4.1 的“最小间隔步数”
