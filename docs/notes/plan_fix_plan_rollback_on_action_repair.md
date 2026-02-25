# 修复方案：避免“纠错重试”导致 Plan 回滚与重复执行

本文档用于记录一次真实运行中暴露的盲区与对应修复方案。后续对 `OnDeviceAgent`（Runner 内 agent loop）相关的代码修改，应以本方案为参考基线，避免重复踩坑。

> 状态：核心防护已落地（Plan 单调合并 + repair attempt 不回写 Plan + 重启触发基于合并后 Plan）。本文档作为设计/回归说明继续保留。

---

## 1. 问题现象（用户可见）

在执行长任务时：

1. 模型已经把某个 Plan Checklist 项标记为 `done=true`（例如“将收集到的封面文字填入表格”）。
2. 某一步模型输出的 action JSON 出现格式错误，触发 Runner 的 **LLM 二次询问纠错**（action repair）。
3. 纠错后的模型输出虽然能解析并继续执行，但 **Plan 被回写为更旧的版本**（把刚刚完成的条目标回 `done=false`）。
4. 之后模型看到 Plan 里该项未完成，于是再次按 Notes 逐条重做，从而出现“已经填过又再填一遍”的重复执行。

该现象在开启 **Responses 模式** + **按 Plan 完成项重启历史**（`restart_responses_by_plan`）时更容易出现，因为“阶段完成→重启链”的边界点恰好更容易触发一次纠错/重生成。

---

## 2. 复盘与根因（机制层面）

以一次真实 run 为例（step 序号仅用于解释）：

- Step 43：模型把 plan 第 6 项写为 `done=true`，Runner 也记录 `old_done=5 new_done=6` 并 schedule 下一步重启 responses 链。
- Step 44：由于模型输出不是合法 JSON（常见为“Extra data”/多段 JSON 拼在一起），触发 `parse_action_failed`，Runner 发起 action repair。
- Step 44（repair response）：模型为了满足 repair prompt，又输出了一个新的 plan，但其中第 6 项变回 `done=false`（或 plan 长度/内容发生漂移）。

**当前 Runner 的实现问题在于：**

1) **Plan 是可倒退的（non-monotonic）**  
只要 action JSON 里带了 `plan`，Runner 就会用它覆盖 `self.planChecklist`；因此 `done=true -> false` 会真实发生。

2) **纠错重试的语义被误用**  
action repair 的目标应该是“把输出修成可解析 JSON”，而不是“允许模型重写系统状态（plan）”。但当前 repair prompt 强制模型输出完整 `think/plan/action`，且 Runner 也会采信其中的 plan，导致“纠错轮修改 plan”成为可能。

3) **Responses 分段重启放大了该问题**  
当 `previous_response_id` 被清空后，模型对上下文的掌握会更不稳定；repair 轮更容易生成“缺项/回滚”的 plan。

> 结论：这不是 OCR/执行失败问题，而是 **纠错轮 + plan 覆盖策略** 导致的状态回滚。

---

## 3. 修复目标（不改范式、最小侵入）

### 目标 A：Plan 状态永远不倒退

- 一旦某条 plan item 被标记 `done=true`，后续任何模型输出都不应把它改回 `false`。
- 模型如果认为“需要重试/复核”，应当 **追加** 新条目，而不是回滚旧条目的 done。

### 目标 B：纠错重试只修 JSON，不允许重写 plan

- 纠错轮（attempt>0）输出的 plan 要么被忽略，要么只能以“单调合并”的方式更新，绝不允许回滚。

### 目标 C：兼容当前可观测与 restart-by-plan 行为

- `restart_responses_by_plan` 的触发应基于“合并后的 plan”，避免被回滚污染。
- 继续保留现有日志信号：`responses_chain_restart_scheduled` / `responses_chain_restarted`。

---

## 4. 方案设计（推荐）

本方案由两条“硬约束”组成：**单调合并（sticky done）** + **修复轮忽略 plan**。

### 4.1 单调合并（sticky done / append-friendly）

在 Runner 内部，把新 plan 合并进旧 plan，而不是直接覆盖：

- 对于 `text` 相同（或可归一化后相同）的条目：
  - `done = old.done || new.done`
- 对于新 plan 中不存在的旧条目：
  - 保留旧条目（避免模型“丢项/重排”造成状态丢失）
- 对于新出现的条目：
  - 允许追加（append），并进行必要的 sanitize（截断长度/数量上限等）

可选护栏（更小改动，但更弱）：
- 若检测到 `new_done_count < old_done_count`，直接拒绝更新 plan（保留旧 plan）。

推荐优先用“合并”，再加 done_count 护栏作为兜底。

### 4.2 纠错轮（attempt>0）忽略 plan

当解析失败触发 repair 后：

- repair response 如果能解析出合法 action：
  - **执行 action**
  - **不使用其中的 plan 覆盖/更新 `self.planChecklist`**（或仅做 4.1 的 merge，但禁止回滚）

这样即使 repair response 里 plan 回滚，也不会污染系统状态。

### 4.3 修复 prompt（降低模型犯错概率）

虽然 4.2 已经能从代码层彻底阻断回滚，但 prompt 仍建议改为“语法修复”：

- repair prompt 改成：只返回 1 个合法 JSON 对象，重点保证 `action` 可解析。
- 明确要求：**不要修改 plan；最好不要输出 plan**。如果必须输出 plan，请原样复制上一条的 plan。

说明：`parseActionFromModelText` 当前只要求 `action.name` 存在，因此 repair 轮无需强制携带 plan 字段。

---

## 5. 实施要点（函数级落点）

建议在 `WebDriverAgentRunner/UITestingUITests.m` 的主循环中落地以下结构：

1) 在解析 action 后，先拿到：
   - `oldPlan = self.planChecklist`
   - `newPlanRaw = action["plan"]`（可能为空）
2) 若 `attempt == 0`（正常轮）：
   - `newPlan = sanitize(newPlanRaw)`
   - `mergedPlan = mergeMonotonic(oldPlan, newPlan)`
   - `planDoneIncreased = doneCount(mergedPlan) > doneCount(oldPlan)`
   - `self.planChecklist = mergedPlan`
3) 若 `attempt > 0`（纠错轮）：
   - **不更新 plan**（保持 `self.planChecklist` 不变）
   - `planDoneIncreased = NO`（避免纠错轮触发重启）
4) 仅在 **动作执行成功后** 才允许：
   - 根据 `planDoneIncreased` schedule `restart_responses_chain_next_step`

推荐新增两条轻量日志（便于未来 debug）：
- `plan_update_ignored_repair_attempt`（attempt>0 且输出带 plan）
- `plan_merge_regression_detected`（若检测到 newPlan 有回滚企图）

---

## 6. 回归验证清单（真机）

### Case 1：不启用 restart-by-plan（基线）
- `restart_responses_by_plan=false` 跑任务，行为与当前一致，不应引入回归。

### Case 2：启用 restart-by-plan（目标场景）
- `restart_responses_by_plan=true` 跑任务。
- 人为/自然触发一次 action JSON 格式错误（进入 repair）。
- 预期：
  - repair 后 `self.planChecklist` 不回滚；
  - 之前已 done 的条目仍保持 done；
  - 模型不会再次“从 Notes 重填整套内容”。

### Case 3：高频 done 变化（抖动）
- 模型频繁修改 plan 时：
  - done 仍应保持单调；
  - 新条目可追加，但不应导致旧条目消失或 done 下降。

---

## 7. 取舍与不做事项

- 本方案不引入“摘要/记忆压缩”，避免新的幻觉来源与额外复杂度。
- 本方案不要求模型严格遵循某种 plan 结构，只约束系统内部的状态机单调性。
- 后续如需更强健的稳定性，可再加：
  - 两次重启最小间隔步数（debounce）
  - 同一条目连续两步保持 done 才视为完成（stability check）
