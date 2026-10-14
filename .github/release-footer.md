## 安装（未签名 IPA，需要自签）

挂在这个 Release 上的 `.ipa` **没有签名**，直接装是装不上的 —— 它只包含 App 本体。
用你自己的 Apple ID 重签一次即可，不需要开发者账号（免费 Apple ID 可用，签名 7 天有效；
付费账号 1 年）。完整步骤见
[docs/INSTALL-UNSIGNED-IPA.md](https://github.com/UnsplashZ/dsh-pocket/blob/main/docs/INSTALL-UNSIGNED-IPA.md)。

**装之前请确认**：你的电脑上已经装了 DSH，并且装了 `dsh-plugin-tether`
（这一端本项目一行都不改）。iOS 17.5 或更新。

---

## Install (unsigned IPA — you re-sign it)

The `.ipa` attached here is **not signed** and cannot be installed as-is.
Re-sign it with your own Apple ID — no developer account required (a free Apple ID
works; its signature expires after 7 days, a paid account gives you a year). See
[docs/INSTALL-UNSIGNED-IPA.md](https://github.com/UnsplashZ/dsh-pocket/blob/main/docs/INSTALL-UNSIGNED-IPA.md).

**Before installing**: DSH must already be installed on your computer together with
`dsh-plugin-tether` (this project changes nothing on the host side). Requires iOS 17.5+.

文件 / Files:

| 文件 | 说明 |
|---|---|
| `DSHPocket-<版本>-unsigned.ipa` | 未签名安装包 |
| `…ipa.sha256` | 校验和（`shasum -a 256 -c <文件>`） |
