# 安装未签名 IPA（自签指南）

> 英文版见 [README](../README.md#install-unsigned-ipa)。
> 本文只讲"怎么把这个包装到 iPhone 上"；项目本身的说明在 [README.zh-CN](../README.zh-CN.md)。

## 为什么发的是未签名的包

iOS 不允许安装没有签名的 App。签名需要把 **Apple 开发者证书**打进包里，而证书意味着两件事：

1. **它绑在某个账号上。** 我们发出去的包如果由我们签，就只有我们账号授权的设备能装 ——
   那等于没发布。所以正确的做法是：只发**未签名**的 App 本体，由安装的人用自己的 Apple ID 签一次。
2. **签名是可以被吊销的。** 把别人的证书塞进公开分发包，对方有权（也应当）吊销它，
   于是所有装了的人都一起失效。

所以本仓库的 Release 里只有一个 `DSHPocket-<版本>-unsigned.ipa`：**它不能被直接安装**，
它只是一份等待签名的 App。下面任选一种方式签。

| 方式 | 平台 | 需要 | 签名有效期 | 适合谁 |
|---|---|---|---|---|
| **Sideloadly** | macOS / Windows | 免费 Apple ID | 7 天 | **首选**，一条命令、界面直白 |
| **AltStore / SideStore** | macOS / Windows | 免费 Apple ID | 7 天（可自动续签） | 想省掉每周手动重签 |
| **Xcode 直接装** | 仅 macOS | 已装 Xcode + Apple ID | 7 天 | 本来就在用 Xcode 的人 |
| **TrollStore（巨魔）** | 设备侧 | 设备/iOS 版本支持 | 永久 | 系统版本合适的话最省事 |
| **付费开发者账号** | macOS / Windows | ￥688/年 | 1 年 | 不想每 7 天折腾一次 |

> 免费 Apple ID 的限制：签名 **7 天过期**，最多同时装 **3 个**自签 App。
> 过期后 App 打不开，重签一次即可（**数据不会丢**，见下文"重签要注意什么"）。

---

## 一、Sideloadly（推荐）

1. **先装电脑端**：确保 DSH 已安装，并且装了 `dsh-plugin-tether`
   （`dsh plugin install dsh-plugin-tether`，或见上游 [dsh-tether](https://github.com/zexadev/dsh-tether)）。
   本项目**不修改电脑端任何一行**，也不会替你装它。
2. 从 [sideloadly.io](https://sideloadly.io/) 下载对应平台的 Sideloadly。
3. 打开 Sideloadly，把 iPhone 用数据线连到电脑，信任这台电脑。
4. `IPA` 一栏选你从 Release 下载的 `DSHPocket-0.3.0-unsigned.ipa`。
5. `Apple account` 填你自己的 Apple ID。**这是本地签名用的**，凭据会直接发给 Apple，
   Sideloadly 不经手你的密码（但请自行确认你下载的 Sideloadly 来源可信）。
6. 点 `Start`，等它显示 `Done`。

**装完第一次打开会提示"未受信任的开发者"，这是正常的**，去手机设置里放行：

> 设置 → 通用 → VPN 与设备管理 → 描述文件 → 选择你的 Apple ID → 信任

然后打开 App，按引导配对（见 [README.zh-CN](../README.zh-CN.md#第一次使用)）。

## 二、AltStore / SideStore

适合不想每周手动重签的人：它在手机侧装一个"续签助手"，用同一台电脑（或另一台
常开的机器）自动续签。代价是首次配置比 Sideloadly 麻烦，且电脑上要跑一个
AltServer。步骤以上游文档为准：[altstore.io](https://altstore.io/)。

## 三、Xcode 直接装（仅 macOS）

如果你已经有 Xcode，可以不经 IPA、直接从源码装到自己的设备上 ——
这样还能顺手改 Bundle ID：

```bash
git clone https://github.com/UnsplashZ/dsh-pocket.git
cd dsh-pocket
bash ios/scripts/fetch-iroh.sh     # 一次：取 iroh 的预编译部件（约 42 MB，不入库）
```

然后在 `ios/project.yml` 里把 `bundleIdPrefix` 改成你自己的，并补上
`DEVELOPMENT_TEAM`，再：

```bash
bash ios/build.sh --device         # 真机构建（带签名）
bash scripts/install-device.sh     # 装进已连接的设备并启动
```

## 四、TrollStore

如果你的 iOS 版本在 TrollStore 支持范围内，可以直接把未签名的 IPA 交给它安装 ——
这是**唯一一种装上之后不会过期**的免费方式。支持范围随版本变化，
以 [TrollStore 的说明](https://github.com/opa334/TrollStore)为准。

---

## 校验下载的文件

Release 里每个 IPA 都带一个 `.sha256`。下载后核对：

```bash
shasum -a 256 -c DSHPocket-0.3.0-unsigned.ipa.sha256
# DSHPocket-0.3.0-unsigned.ipa: OK
```

## 重签要注意什么

- **App 数据不会丢。** 用同一个 Bundle ID 重签并覆盖安装，会话缓存、设置都还在。
- **但 iroh 身份可能变。** 免费账号每次重签时的 App ID 前缀不一定相同，而 iroh 的私钥存在
  Keychain 里，其访问组跟着签名走。如果换签名后 App 连不上电脑了，打开
  **设置 → 配对**重新配对一次即可（电脑上会多出一台设备，可以在
  设置 → 主机 里把旧的撤销）。
- **改了 Bundle ID 就等于换了一个 App。** 如果你在 Sideloadly 里自定义了 Bundle ID，
  旧 App 的数据不会跟过来，需要重新配对、重新填提供商密钥。

## 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| 安装时提示 "Unable to install …" / 设备不信任 | 先信任描述文件：设置 → 通用 → VPN 与设备管理 |
| 打开就闪退，或 7 天后突然打不开 | 免费签名过期了，重签一次 |
| 提示"无法验证 App 的完整性" | IPA 下载不完整，用 `.sha256` 核对后重下 |
| 连不上电脑，诊断页显示"连接超时" | 首次运行要允许**本地网络**权限；另外确认电脑端 `dsh-plugin-tether` 在跑 |
| 配对码输不进去 / 扫不出来 | 配对码 6 位、10 分钟有效、3 次尝试；过期就在电脑端重新生成 |
| 自签后 App 名下有多个图标 | 免费账号最多 3 个自签 App，先删掉不用的 |

安全边界（包括"不要把本 App 用在你同时跑不可信代码的电脑上"这条）见
[README.zh-CN §安全边界](../README.zh-CN.md#安全边界如实告知)。
