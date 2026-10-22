# 内置二进制的来源与许可

`bin/<platform>-<arch>/tether-host` 是本插件内置的 iroh sidecar 二进制。
**它不来自任何 npm 依赖** —— 插件本身零依赖，这个文件随包发布，所以装好即可用。

## 当前内置的那一个

| 项 | 值 |
|---|---|
| 上游项目 | [dsh-tether](https://github.com/zexadev/dsh-tether)（`dsh-tether-host-darwin-arm64` 0.1.22） |
| 许可 | MIT |
| 版权 | Copyright (c) 2026 zexadev |
| 用途 | 实现 DLP v1 线协议（ALPN `dsh-tether/0`）：控制流 JSON-lines + 代理流，逐请求注入浏览器 cookie |

MIT 允许再分发，条件是保留版权与许可声明 —— 本文件就是那个声明。
完整许可全文见同目录 `LICENSE.tether-host`。

## 为什么先内置上游二进制

「完全独立构建」的第一层要求是**不依赖外部包**（能装上、能卸载、版本不打架），
这一层已经做到：内置二进制 + 包内解析路径，`package.json` 里没有任何依赖声明。

第二层是**自己实现 sidecar**（Rust，iroh + DLP + HTTP 头注入），那是更大的工程，
正在单独推进。做完之后本目录会被我们自己的构建产物替换，
`host-rs/` 里的源码就是它的来源 —— 届时这份 NOTICE 会改成我们自己的许可。

## 替换成自己的二进制

把任何实现 DLP v1 的可执行文件放到 `bin/<platform>-<arch>/tether-host`
（`resolveHostBinary()` 认这个路径），或用配置项 `tiers.iroh.binaryPath` 显式指定。
