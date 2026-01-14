# Xcode + Personal Team（免费）快速上手（用于安装/运行 WebDriverAgentRunner-Runner）

这份文档面向 **第一次用 Xcode** 的人：目标是让你用 **Personal Team（免费）** 把 `WebDriverAgentRunner-Runner`（WDA 的 `.xctrunner`）装进 iPhone 并跑起来，然后再接上本仓库的 on-device Agent。

> 提醒：跑 WDA 仍然需要 macOS + Xcode（至少一次）完成编译/签名/安装。后续你可以尽量减少依赖电脑，但“第一次装进去”基本绕不过 Xcode。

---

## 先把几个概念讲清楚

### Apple ID / Apple Developer Program / Personal Team

- **Apple ID**：你日常登录 iCloud / App Store 用的账号。
- **Apple Developer Program（付费）**：面向上架/分发等场景的开发者计划（你不一定需要）。
- **Personal Team（免费）**：你把 Apple ID 加进 Xcode 后，Xcode 会为你提供一个“个人团队”用于**本机开发/真机调试/测试签名**。
  - 在很多场景下，Personal Team 足够把 WDA 装进手机并运行。
  - 但它的签名/描述文件通常会有各种限制（例如有效期较短、能力受限等）。如果你发现“过几天又不能启动了”，通常就是要重新安装/重新签名。

### `<TEAMID>` 是什么

`<TEAMID>` 是你的 **Team ID**（通常是 10 位大写字母数字），Apple 用它来标识一个开发者团队。

你后面会在脚本里用到它，用于让 Xcode/签名系统知道“这次用哪个 Team 来签名”。

推荐获取方式（对新手更直观）：

1. 登录 `https://developer.apple.com/account`
2. 页面向下滚动到 “Membership details”（会员资格详细信息）
3. 找到 “Team ID” 字段（即 `<TEAMID>`）

### `<com.your.prefix>` 是什么

`<com.your.prefix>` 是你要使用的 **Bundle ID 前缀**（反向域名风格），例如：

- `com.example.wda`
- `com.yourname.wda`

为什么需要它：

- WebDriverAgent 默认使用 `com.facebook.*` 这类 bundle id；
- 为了让它在你的 Personal Team 下更稳定/更可控，我们会把 WDA 的 bundle id 统一改成你自己的前缀（例如 `com.yourname.wda.WebDriverAgentRunner` 等）。

**建议：选一个前缀后就一直用同一个**，这样 iOS 才不会把 Runner 当成“新 App”反复重置权限（例如 Wireless Data）。

---

## 一次性准备（首次使用）

### 0) 安装 Xcode（并完成首次启动）

1. 安装 Xcode（App Store 或 Apple Developer 下载都可以）。
2. 第一次打开 Xcode，按提示安装额外组件。
3. （可选但常见）在终端运行一次：

```bash
sudo xcodebuild -license accept
```

### 1) 在 Xcode 里登录 Apple ID（创建/启用 Personal Team）

1. 打开 Xcode
2. `Xcode -> Settings... -> Accounts`
3. 点 `+` 添加你的 Apple ID 登录
4. 登录成功后，你会在 Accounts 里看到类似 `Personal Team - <你的名字>` 的条目

> 这一步通常会要求你的 Apple ID 已经开启 2FA（双重认证）。

### 2) 打开 iPhone 的 Developer Mode（iOS 16+ 必需）

在 iPhone 上：

- `Settings -> Privacy & Security -> Developer Mode -> On`
- 按提示重启并确认开启

### 3) USB 连接并“信任此电脑”

1. 用 USB 线连接 iPhone 和 Mac
2. iPhone 解锁
3. 出现“信任此电脑”时点信任，并输入锁屏密码

### 4)（强烈建议）先跑通一次“普通 App 上机”，验证 Personal Team 签名链路没问题

这一步不是必须，但能显著减少你后面排查 WDA 的心智负担。

1. 在 Xcode 里新建一个 iOS App（随便一个空白工程即可）
2. 选中工程 Target：
   - 勾选 `Automatically manage signing`
   - `Team` 选择你的 `Personal Team`
   - `Bundle Identifier` 改成一个你自己的（例如 `com.your.prefix`）
3. 选择你的 iPhone 作为运行设备，点 `Run`

如果这一步能跑起来，说明：

- 设备注册/证书/描述文件基本 OK
- 后面 WDA 出问题更可能是 WDA 自身配置/权限，而不是“账号没配好”

---

## 对接到本仓库的流程（从 0 到装进手机）

### 0) 拉取子模块

在仓库根目录：

```bash
git submodule update --init --recursive
```

### 1) 获取你的 UDID / TEAMID

- **UDID**（设备标识符）：用于 `xcodebuild` / `devicectl` 选择你的 iPhone。
  - 形态通常类似 `XXXXXXXX-XXXXXXXXXXXXXXXX`（8 位 + `-` + 16 位，大写字母/数字），例如 `00000000-0000000000000000`
  - 获取方式：Xcode `Window -> Devices and Simulators` 里选中设备，复制 `Identifier`
- **TEAMID**（团队 ID）：用于签名（告诉 Xcode/证书体系“用哪个 Team”）。
  - 形态通常是 10 位大写字母/数字，例如 `A1B2C3D4E5`
  - 推荐获取方式：登录 `https://developer.apple.com/account` → “会员资格详细信息 (Membership details)” → “团队 ID (Team ID)”

### 2) 配置 WDA 的签名与 bundle id（脚本方式）

在仓库根目录执行：

```bash
bash scripts/configure_wda_signing.sh \
  --team-id <TEAMID> \
  --bundle-prefix <com.your.prefix>
```

这个脚本会做两件事（都只改你本地的 `third_party/WebDriverAgent` 工作区，不会把个人信息提交进 git）：

- 把 WDA 的 `PRODUCT_BUNDLE_IDENTIFIER` 从 `com.facebook.*` 改成 `<com.your.prefix>.*`
- 写入/覆盖一个本地签名配置，让 Xcode 知道用哪个 Team 来签名

### 3) 应用本仓库的 on-device Agent 补丁

```bash
bash scripts/apply_patch_to_wda.sh
```

### 4) 编译并安装 “prepared Runner”（推荐）

```bash
bash scripts/install_wda_prepared_runner.sh --device <UDID>
```

安装后，在 iPhone 上：

1. `Settings -> Apps -> WebDriverAgentRunner-Runner -> Wireless Data`：设为 `WLAN` 或 `WLAN & Cellular Data`
2. 点开 `WebDriverAgentRunner-Runner`（会启动 WDA，监听 8100）
3. Safari 打开 `http://127.0.0.1:8100/agent`

---

## 常见坑（快速定位）

- **找不到设备 / 安装失败**
  - iPhone 是否解锁、是否点了“信任此电脑”
  - iOS 16+ 是否开启 Developer Mode
- **签名/描述文件报错**
  - 确认 Xcode 已登录 Apple ID，并存在 `Personal Team`
  - 先按上面的“普通 App 上机”跑通一次
- **局域网访问 `<iphone-ip>:8100` 超时**
  - iPhone：`Settings -> Apps -> WebDriverAgentRunner-Runner -> Wireless Data` 不能是 Off
  - 也可以直接用 `127.0.0.1`（不依赖局域网）
