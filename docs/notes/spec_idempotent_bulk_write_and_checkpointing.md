# 规范：幂等批量写入（Idempotent Bulk Write）与可验证检查点（Verifiable Checkpoints）

本文档用于规范 On‑Device Agent 在“批量写入/多条提交/不可逆操作”类任务中的行为，目标是：

- **避免重复写入**（模型不确定时倾向重做的问题）
- **在 Responses 历史截断/新链后仍保持一致性**
- **不依赖特定 App**（通用方案，不做飞书/小红书特判）

> 背景：在 Responses + `restart_responses_by_plan` 场景下，模型在新链第一步往往只能看到“当前编辑中的一条记录”，即使 Plan 已勾选 done，仍可能因“可验证性不足”而自我推翻并重复写入。仅靠 Plan checklist 不能从机制上杜绝重复副作用。

---

## 1. 核心概念

### 1.1 幂等（Idempotency）
同一个“逻辑写入”即使重复执行，也不会产生重复副作用，或能被检测并安全跳过。

在 UI 自动化中，幂等通常需要：
- **写前查重**（是否已经写过）
- **写入标识**（让查重可靠）
- **明确的提交状态**（写入成功是否已提交/保存）

### 1.2 可验证检查点（Verifiable checkpoint）
“我完成了”必须基于屏幕可验证证据，而不是模型自信。

对批量写入场景，一个可靠 checkpoint 往往不是“当前编辑页”，而是：
- 回到列表/总览页看到 **N 条**
- 或能搜索到 **特定标题/标识**
- 或能看到“已保存/已提交”的 UI 提示

### 1.3 账本式工作记忆（Ledger Notes）
把 Working Notes 从“待写列表”升级为“提交账本”，用于跨链/跨上下文保持一致。

---

## 2. 推荐的系统行为规范（通用）

### 2.1 Notes 必须使用“账本结构”表达
对任何批量写入任务，模型应在 Notes 中维护以下字段（自由文本即可，但建议固定格式）：

- `target_count`: 目标条目数量（如 5/10）
- `items`: 全量候选项（可选）
- `pending`: 正在写/尚未提交的条目（0 或 1 条为宜）
- `written`: 已确认写入并提交成功的条目列表
- `last_checkpoint`: 最近一次可验证检查点的简述（例如“回到列表看到 written 的前 4 项已出现”）

建议模板：

```text
LEDGER
- target_count: 5
- written (3/5):
  1) ...
  2) ...
  3) ...
- pending:
  - ...
- next:
  - ...
- last_checkpoint: ...
```

**规范要求**：
- `written` 只包含“已经提交/保存成功”的条目。
- 任何时候发现 UI 证据不足，应先进入 verify，而不是直接把条目加入 `written`。

### 2.2 Plan 的 done 只能由 checkpoint 解锁
对于 Plan Checklist：

- 允许有一个“大项”代表“批量写入完成”（例如“将收集到的文字填入表格”）。
- **只有当 `written_count == target_count` 且已做一次可验证 checkpoint** 时，该大项才允许 `done=true`。

理由：在新链/长任务下，Plan 是一种“声明”，而 checkpoint 是“证据”。

### 2.3 进入写入阶段前先把目标集合固定
批量写入常见失败模式是“写着写着集合变了/忘了写过哪些”。

规范要求：
- 在开始批量写入前，模型应先在 Notes 里写下 `items` 或至少写下 `written=[]` 的目标集合（可简化）。
- 写入过程中，不得把 `items` 当成“已写”，必须显式更新 `written`。

### 2.4 写入必须“写前查重”
当模型准备写入第 k 条时：

- 如果该条目已在 `written` 列表中：必须跳过写入，转向下一条。
- 如果不确定是否已写入：优先 verify（回到列表/搜索），不要直接再写。

> 这是避免重复副作用的核心。

### 2.5 Finish 之前必须 verify
完成任务时：

- 必须先回到能验证的 UI（列表/总览/搜索结果）并确认 `written` 的条目存在。
- 然后再 `Finish`。

---

## 3. 与 Responses 历史截断（restart-by-plan）的配合规范

### 3.1 重启链的“安全边界”
当启用 `restart_responses_by_plan` 时，建议把“重启链”绑定到 **已验证 checkpoint 之后**。

换句话说：
- `done_count` 增加只是候选信号。
- **只有在 Notes 里写入 `last_checkpoint`（或等价证据）后** 才允许触发会话重启。

### 3.2 新链第一步必须补齐上下文
当重启链发生（`previous_response_id` 置空）时：

- 必须补一次 System Prompt（已有实现）
- 必须补一次 Task（已有实现）
- **建议补一次 Ledger 摘要**（例如：`written_count / target_count + 下一步要做什么`），但这可以通过 Notes 自动达成。

---

## 4. 最建议的实现程度（分级建议）

下面按“改动成本/收益”给出建议的落地等级。

### Level 1（最推荐的 MVP，优先实现）
**仅修改 system prompt 规范**（不新增 action，不新增复杂状态机）：

- 强制 Notes 使用 Ledger 结构（written/pending/target_count/last_checkpoint）。
- 强制 Plan done 只能在 verify 后设置。
- 强制 Finish 前 verify。

优点：
- 改动最小、最通用。
- 立即降低“新链后重复写入”。

缺点：
- 仍依赖模型自律；极端情况下仍会犯错。

### Level 2（增强稳定性，建议尽快做）
**轻量代码改动**（不引入 OCR/UI tree）：

- 在每步 user message 中增加一个短的 `Last step result` 区块（成功/失败/动作名/关键信息）。
- 调整 restart-by-plan 触发：done 增加后先走 1 步 verify（或 done 稳定两步）再重启。

优点：
- 明显提升跨链一致性。
- 减少模型“我不确定”的概率。

缺点：
- 需要改 Runner 逻辑与 prompt 描述。

### Level 3（最稳但成本更高，后续可选）
**系统维护的状态机 + 去重标识**：

- Runner 维护 `phase / target_count / written_count` 等显式 STATE（不依赖模型输出）。
- 写入内容加可搜索的 run-id/序号标识，用于强查重。

优点：
- 幂等性最强，重复副作用几乎可消除。

缺点：
- 需要引入更强的工程约束（对写入内容格式有侵入）。

---

## 5. 验收标准（回归点）

### 5.1 重启链后不应重复写入
在出现 `responses_chain_restarted` 后：
- 模型应优先 verify（回列表/搜索），而不是立即重新写入。

### 5.2 Notes 账本单调前进
- `written_count` 不应减少。
- `written` 不应把已提交条目移回 pending。

### 5.3 完成必须可解释
- Finish message 能引用 ledger（例如“已写入 written 5/5，且在列表页可见”）。

---

## 6. 参考：常见失败模式与对策（通用）

- **只看到编辑页的一条记录**：必须回列表 verify。
- **模型说“我填完了”但 UI 没证据**：禁止把 plan done，先 verify。
- **重启链后忘记已写**：依赖 ledger written + checkpoint。

