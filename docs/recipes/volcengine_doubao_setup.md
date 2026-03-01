# 火山引擎（火山方舟 Ark）豆包模型接入指南（含 Responses 缓存）

本文面向使用本仓库的用户，说明如何在火山引擎（火山方舟 Ark）侧完成准备工作，并把豆包模型接入到本项目（Runner Web UI / Console App）。

目标：

- 能正常调用豆包模型（Responses 或 Chat Completions）。
- 可选：在 **Responses API** 下启用“上下文缓存”（命中缓存的输入可获得折扣），并在本项目里打开对应开关。

---

## 你需要准备什么

- 一个火山引擎账号（能登录控制台）。
- 已开通火山方舟服务，并在“开通管理”里开通目标模型。
- 一个可用的 **API Key**（用于接口鉴权）。
- （可选）如果要用 Responses 缓存：需要在**开通管理页**把“推理（缓存）定价”列对应的缓存服务也开通。

---

## Step 1：注册/登录火山引擎控制台

1. 注册火山引擎账号并完成必要的账号验证（以控制台提示为准）。
2. 登录火山引擎控制台，进入 **火山方舟（Ark）**。

对应链接（就近）：

- 控制台登录入口：[https://console.volcengine.com/](https://console.volcengine.com/)
- 快速入门（含“获取 API Key / 开通模型服务”总流程）：[https://www.volcengine.com/docs/82379/1399008?lang=zh](https://www.volcengine.com/docs/82379/1399008?lang=zh)

---

## Step 2：开通模型服务（拿到可用的 Model ID / Endpoint ID）

火山方舟的 OpenAI-compatible API 里，`model` 字段支持两类 ID：

- **Model ID**：模型本身的 ID（例如 `doubao-seed-1-8-251228`）。
- **Endpoint ID**：推理接入点 ID（一般形如 `ep-...`），用于多应用隔离/更细粒度权限管理（在官方文档里称为 Endpoint ID）。

建议优先使用：

- 直接填 **Model ID**（简单、可移植）。
- 需要隔离/多应用管理时再用 **Endpoint ID**。

在控制台里：

1. 打开火山方舟的 **开通管理** 页面。
2. 找到你要用的模型（例如 `doubao-seed-1-8-251228`）并开通推理服务。
3. （可选）如需 Endpoint：在“推理接入点（Endpoint）”里创建/启用一个接入点，并复制它的 Endpoint ID。

对应链接（就近）：

- 快速入门（Step 2 开通模型服务）：[https://www.volcengine.com/docs/82379/1399008?lang=zh](https://www.volcengine.com/docs/82379/1399008?lang=zh)
- Responses API 参数（`model` 支持 Model ID / Endpoint ID）：[https://www.volcengine.com/docs/82379/1569618?lang=zh](https://www.volcengine.com/docs/82379/1569618?lang=zh)

---

## Step 3：创建 API Key

你需要 API Key 作为鉴权凭证。建议按官方方式创建并妥善保管（避免泄露导致费用损失）。

在火山方舟文档中，API Key 的创建流程是：

- 打开并登录“API Key 管理”页面；
- 点击“创建 API Key”，并在 API Key 列表里查看/复制新建的 Key；
- （可选）可切换“项目空间”来限制 API Key 的作用范围。

对应链接（就近）：

- API Key 管理与使用说明：[https://www.volcengine.com/docs/82379/1541594?lang=zh](https://www.volcengine.com/docs/82379/1541594?lang=zh)

---

## Step 4（可选）：启用 Responses 的缓存能力（上下文缓存）

### 4.1 开通“模型缓存服务”（控制台开通）

如果你希望在 Responses API 使用缓存（上下文缓存/会话缓存/前缀缓存等能力），需要先在控制台开通该能力。

火山方舟文档对前提条件的描述是：

- **开通模型的缓存服务：在开通管理页，模型列表的「推理（缓存）定价」列开通。**

如果未开通缓存服务，即使请求里传了 `caching` 参数，也可能不生效或直接报错（以控制台与接口返回为准）。

对应链接（就近）：

- 上下文缓存（前提条件、用法与限制）：[https://www.volcengine.com/docs/82379/1602228?lang=zh](https://www.volcengine.com/docs/82379/1602228?lang=zh)

### 4.2 请求侧打开 caching（本项目会自动做）

在 Responses API 中，`caching` 用于开启缓存；多轮对话通过 `previous_response_id` 复用历史上下文（属于“Session 缓存”的用法）。

本仓库在以下条件满足时，会在 Responses 请求体里自动加上：

```json
{ "caching": { "type": "enabled" } }
```

触发条件（以代码实现为准）：

- API 模式选择 **Responses**；
- 模型名以 `doubao-seed` 开头；
- Console / Web UI 中开启了“启用会话缓存（豆包 Seed）”开关（默认开启）。

对应链接（就近）：

- Responses API 参数（`caching` / `previous_response_id` / `instructions` 限制）：[https://www.volcengine.com/docs/82379/1569618?lang=zh](https://www.volcengine.com/docs/82379/1569618?lang=zh)
- 上下文缓存（Session 缓存、前缀缓存、`expire_at`）：[https://www.volcengine.com/docs/82379/1602228?lang=zh](https://www.volcengine.com/docs/82379/1602228?lang=zh)

---

## Step 5：在本项目里填写推荐配置（Runner / Console）

在 iPhone 的 Runner Web UI（`/agent`）或 Console App 里，建议这样填：

- API 模式：优先选 **Responses**（豆包 Seed 更推荐；不支持再切 Chat Completions）
- Base URL（OpenAI 兼容）：
  - 推荐：`https://ark.cn-beijing.volces.com/api/v3`
  - 也可以直接填到具体 endpoint（例如 `.../api/v3/responses`），本项目会尽量兼容
- Model：
  - 推荐：`doubao-seed-1-8-251228`（Model ID）
  - 或使用你创建的 `ep-...`（Endpoint ID）
- API 密钥：填入你在火山方舟创建的 API Key
- 高级（可选）：
  - “启用会话缓存（豆包 Seed）”：若你已在控制台开通缓存服务，建议保持开启

对应链接（就近）：

- 调用地址与鉴权（Base URL / Authorization）：[https://www.volcengine.com/docs/82379/1298459](https://www.volcengine.com/docs/82379/1298459)
- Responses API 参数（含 `max_output_tokens`、`thinking/reasoning`、`caching`）：[https://www.volcengine.com/docs/82379/1569618?lang=zh](https://www.volcengine.com/docs/82379/1569618?lang=zh)

---

## 常见问题（排查清单）

### 1）401 / Unauthorized

- API Key 是否正确、是否有权限访问该模型/接入点（项目空间是否匹配）。
- Base URL 是否填错（例如多写/少写了路径）。
- 参考：[https://www.volcengine.com/docs/82379/1541594?lang=zh](https://www.volcengine.com/docs/82379/1541594?lang=zh)、[https://www.volcengine.com/docs/82379/1298459](https://www.volcengine.com/docs/82379/1298459)

### 2）404 / Not Found

- 如果 API 模式是 Responses：Base URL 是否已经包含 `/responses`（导致重复拼接路径）。
- 如果 API 模式是 Chat Completions：Base URL 是否包含 `/chat/completions`。
- 参考：[https://www.volcengine.com/docs/82379/1569618?lang=zh](https://www.volcengine.com/docs/82379/1569618?lang=zh)

### 3）缓存看起来没生效

- 控制台是否已在“开通管理页”开通该模型的缓存服务（推理（缓存）定价列）。
- 本项目是否处于 Responses 模式，并打开了“启用会话缓存（豆包 Seed）”开关。
- 看 Token 用量统计里 `cached`（或 `cached_tokens`）是否一直为 0（若一直为 0，通常意味着未命中缓存或未开启缓存）。
- 参考：[https://www.volcengine.com/docs/82379/1602228?lang=zh](https://www.volcengine.com/docs/82379/1602228?lang=zh)、[https://www.volcengine.com/docs/82379/1569618?lang=zh](https://www.volcengine.com/docs/82379/1569618?lang=zh)

---

## 参考（官方文档）

（以下为火山方舟官方文档页面，具体内容以官方更新为准）

- 调用地址与鉴权（Base URL / Authorization）：[https://www.volcengine.com/docs/82379/1298459](https://www.volcengine.com/docs/82379/1298459)
- 快速入门（首次调用）：[https://www.volcengine.com/docs/82379/1399008?lang=zh](https://www.volcengine.com/docs/82379/1399008?lang=zh)
- 获取并配置 API Key：[https://www.volcengine.com/docs/82379/1541594?lang=zh](https://www.volcengine.com/docs/82379/1541594?lang=zh)
- Responses API 参数参考（含 caching/previous_response_id/instructions 限制等）：[https://www.volcengine.com/docs/82379/1569618?lang=zh](https://www.volcengine.com/docs/82379/1569618?lang=zh)
- 上下文缓存（前提条件与使用方式）：[https://www.volcengine.com/docs/82379/1602228?lang=zh](https://www.volcengine.com/docs/82379/1602228?lang=zh)
