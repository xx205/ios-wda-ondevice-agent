# 后续修改计划（持续更新）

本文件用于记录 **ios-wda-ondevice-agent** 仓库在当前基线之后的后续修改计划与优先级，并在每次较大改动落地后追加一条“变更记录”，便于回溯与追踪。

> 约定：如果本计划与某个专项评审/讨论笔记冲突，以“代码行为 + 本计划的最新条目”为准，并在本文件中更新说明。

---

## 基线状态（截至 2026-02-22）

已完成（可认为是当前基线能力）：

- Patch ↔ Overlay 同步/校验脚本完善：以 `patches/webdriveragent_ondevice_agent_webui.patch` 为真源，脚本从 patch 解析出文件列表，避免漏检/漏更。
  - `scripts/update_wda_overlay_from_patch.sh`
  - `scripts/check_wda_patch_sync.sh`
- Chat Completions 模式做了 **有界历史**（滑动窗口），避免长任务上下文无限膨胀。
- Agent Token 泄露面收敛（LAN 401 + 仅首次 `?token=` 引导 + HttpOnly Strict cookie + URL 去 token + Rotate token + 全链路脱敏 + 回归脚本）。
  - `scripts/check_no_secrets_regressions.sh`
- Plan checklist 身份稳定化（normalize key + 稳定 id + sticky done + repair attempt 不回滚 plan）+ 回归用例。
  - `scripts/test_plan_merge_regressions.py`

本计划的初版来源于 2026-02-22 的并发审阅笔记，详见：

- `docs/notes/codebase_review_2026-02-22/summary.md`
- `docs/notes/codebase_review_2026-02-22/next_steps_plan.md`
- `docs/notes/codebase_review_2026-02-22/security_privacy.md`
- `docs/notes/codebase_review_2026-02-22/correctness_reliability.md`
- `docs/notes/codebase_review_2026-02-22/ux_product.md`
- `docs/notes/codebase_review_2026-02-22/build_devex.md`
- `docs/notes/codebase_review_2026-02-22/performance_cost.md`
- `docs/notes/codebase_review_2026-02-22/code_health.md`

同时本仓库还有一些专项讨论/规范文件，本计划也应纳入参考与落地追踪：

- `docs/notes/plan_responses_restart_by_plan.md`（Responses 按 Plan 分段重启）
- `docs/notes/plan_fix_plan_rollback_on_action_repair.md`（避免纠错轮导致 Plan 回滚）
- `docs/notes/spec_idempotent_bulk_write_and_checkpointing.md`（幂等批量写入与可验证 checkpoint）
- `docs/notes/ios_wda_progress.md`（WDA 部署/连接经验总结，面向可公开复现）

---

## 工作流约束（每次改动都遵循）

- **patch 为准**：对 Runner/WDA 的改动最终都要体现在 `patches/webdriveragent_ondevice_agent_webui.patch`。
- **overlay 派生**：`wda_overlay/` 只作为可读镜像（review/debug），由脚本从 patch 自动生成/更新。
- **每次改动后的最小校验**
  1. 生成/更新 patch（来自 `third_party/WebDriverAgent/` 的 diff）。
  2. `bash scripts/update_wda_overlay_from_patch.sh`
  3. `bash scripts/check_wda_patch_sync.sh`

---

## 后续修改优先级（建议顺序）

### P1-3：降低 Agent Token 泄露面

目标：在保证局域网保护强度的同时，减少 token 通过 URL / cookie / localStorage / 导出 / 日志等路径的意外泄露概率。

来源：`docs/notes/codebase_review_2026-02-22/security_privacy.md`、`docs/notes/codebase_review_2026-02-22/next_steps_plan.md`

建议实施清单（最小改动优先）：

- [x] 仅在首次配对/打开 `/agent` 时接受 `?token=`，随后用 history replace 移除 URL 中的 token。
- [x] 取消长期持久化 token（优先 sessionStorage 或内存）；若必须 cookie，则 `SameSite=Strict`，并避免长寿命。
- [x] 提供“旋转 token”能力（endpoint + UI），降低长期复用 token 的风险。
- [x] 统一脱敏：导出/日志/调试面板中出现的 token 一律 `<redacted>`。

验收点：

- [x] 没有 token 时 `/agent/*` 在 LAN 下稳定返回 401。
- [x] 复制 URL 不再包含 token。
- [x] 导出/日志不包含 token 明文。

补充（同属安全/隐私，建议与本项一起落地）：

- [x] `insecure_skip_tls_verify` 更显式的风险提示与更小作用域（仅影响“模型服务”请求）。
- [x] “raw 导出/日志不含秘密”回归检查（至少扫描 api key / bearer / agent token 的典型形态）。

---

### P1-4：稳定 plan 的“身份”（避免重述导致新条目）

问题：当前 plan 合并偏字符串匹配；模型轻微改写 `text` 可能被当作新项，导致 done_count 虚增，并在 Responses 模式下触发不必要的“按 plan 重启历史”。

来源：`docs/notes/codebase_review_2026-02-22/correctness_reliability.md`、`docs/notes/codebase_review_2026-02-22/next_steps_plan.md`

建议实施清单（由简到强）：

- [x] 文本归一化 key：trim / 合并空白 / lowercase / 去标点，用于去重。
- [x] 引入稳定 ID：允许 `plan[i].id`；缺失时首次生成并持久化，后续以 id 为准合并。
- [x] 加一组可复现用例：模型改写同一条 plan 文案不应产生重复项。

验收点：

- [x] “重述/改写”不会新增 plan 项。
- [x] `restart_responses_by_plan` 仅在真实新增完成项时触发。

补充（Plan 相关的另一个已知盲区）：

- [x] 避免“纠错重试（repair attempt）”导致 Plan 回滚（Plan 必须单调；repair 轮不应污染 plan）。

---

## P2（不阻塞，滚动改进）

### UX / 产品

来源：`docs/notes/codebase_review_2026-02-22/ux_product.md`

- [x] Web UI 校验与 Console 一致：缺少必填项时禁用 Start，并给出可执行提示。
- [x] Web UI 的对话/日志渲染改为按 step 分组（可折叠 raw JSON、可选截图），接近 Console 的可调试性。
- [x] 为“不可用/禁用按钮”提供就地原因说明（不要只靠 4xx/5xx）。
- [x] 在 Start/Stop 周围增加稳定的状态提示（Runner 可达 / 配置可用 / token 有效等），避免把“本机 Runner 不可用”误解为“远端服务器异常”。

### Build / 安装 / DevEx

来源：`docs/notes/codebase_review_2026-02-22/build_devex.md`

- [x] 安装脚本 fail-fast：如果 patch 未应用（或 overlay 不同步），明确报错并给出一键修复路径（或提示先应用 patch）。
- [x] `run_wda_preinstalled_devicectl.sh` 增加依赖检查（如 `python3`），并在 README/recipe 中写清楚。

### 性能 / 成本

来源：`docs/notes/codebase_review_2026-02-22/performance_cost.md`

- [x] 降低轮询与 payload：优先 delta / 降频 / 只在 running 时轮询。
- [x] 截图与导出边界：默认限制保留/导出截图数量；必要时提供 JPEG/quality 或裁剪策略。
- [x] 导出效率：避免 100-step 导出触发逐条截图的“海量请求”；可做批量或限制默认范围。
- [x] 缓存可观测：更清晰地展示缓存是否启用、是否命中（cached tokens > 0）。

### 代码健康 / 可维护性

来源：`docs/notes/codebase_review_2026-02-22/code_health.md`

- [x] 拆分 `ConsoleStore`：把 EventStream、Config 校验、AgentClient 网络层拆成更小的可测协作者。
- [x] 去重解析/校验 helper，避免 QR 校验 vs 导入逻辑漂移。
- [x] 校验/错误文案本地化收敛：集中管理字符串，保证中英文一致性。
- [x] 为关键逻辑补最小单测（QR 解析、SSE decode、请求/响应处理）。

---

## P3（规范/策略类：先写清楚，再选择落地等级）

来源：`docs/notes/spec_idempotent_bulk_write_and_checkpointing.md`

- [x] Level 1：仅通过 system prompt 规范 Ledger Notes + verify-before-done/Finish（最小侵入、最通用）。
- （可选，后续）Level 2：增加 Last step result 等“外显状态块” + 更稳的 restart-by-plan 触发策略（轻量代码改动）。
- （可选，后续）Level 3：系统维护更强的状态机/去重标识（最稳但侵入更高）。

---

## 变更记录（按时间倒序追加）

> 每次你认为“修改量足够大”或进入一个新阶段时，在这里追加一条记录：日期、核心改动点、影响面、回归点。

- 2026-02-22：建立基线（overlay 同步/校验补全；Chat Completions 有界历史）。
- 2026-02-22：完成 P1-3/P1-4（Agent Token 泄露面收敛 + Rotate token；Plan checklist 稳定 ID + sticky done + repair 不回滚；新增回归脚本）。
- 2026-02-23：完成 P2 性能/成本与代码健康项（SSE/按需轮询；批量获取 step screenshots；默认导出边界与 quality；缓存命中可观测；抽出 EventStream 服务与最小单测）。完成 P3 Level 1（system prompt：Ledger Notes + verify-before-done/Finish）。
