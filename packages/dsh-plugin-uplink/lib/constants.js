/** 跨模块共享的常量。改这里之前先想清楚有没有别的地方依赖这个值。 */

/** cookie 的续期间隔。dsh 的 cookie 默认 30 天有效，12 小时续一次足够早。 */
export const DEFAULT_COOKIE_TTL_MS = 12 * 60 * 60 * 1000

/** 环境探测结果的缓存时长。探测要 fork 三四个进程，不能每次请求都跑。 */
export const DETECT_CACHE_MS = 30_000

/** 免票路由：只有这两条能在没有票据的情况下访问。 */
export const PUBLIC_PATHS = Object.freeze(['/uplink/hello', '/uplink/ping'])

/** 换票路由。 */
export const AUTH_PATH = '/uplink/auth'

/**
 * 清单路由（**要票**）：手机任何时候都能重新问一次"你现在有哪些地址"。
 *
 * 为什么必须有：配对串是**那一刻的快照**。电脑换网、DHCP 续租换了 IP、
 * 新接了一块网卡，快照就过期了 —— 而手机没有任何办法知道新地址，
 * 只能重新配对。有了这条，只要手机还能打到**任意一个**旧地址，就能自愈。
 */
export const DESCRIPTOR_PATH = '/uplink/descriptor'

/**
 * iroh 配对码路由（**要票**）：手机拿它自动完成 iroh 档位的配对。
 *
 * 为什么必须单独一条：配对**码**只有 600 秒有效期，不能塞进长期保存的配对串里
 * （那会变成一颗过期的雷）。而 iroh 的配对是 sidecar 维护的**独立白名单** ——
 * 和 uplink 的设备密钥是两套东西。所以手机在需要走 iroh 时，现场来要一次码：
 * 用 uplink 票据换 sidecar 的 `endpointId#code`，然后交给 TetherKit 完成配对。
 * 全程零手工。
 */
export const IROH_PAIRING_PATH = '/uplink/iroh-pairing'

/**
 * iroh 已配对设备清单（**要票**，走网关）。
 *
 * 手机拿它自检："我的 iroh 身份是不是已经在电脑端白名单里了？"
 * 是 → **永远不需要再要配对码**，那条"配对码已过期"的报错也就不会出现。
 * 手机自己的主机簿在 App 容器里，重装即失；这份在电脑端，才是权威。
 */
export const IROH_DEVICES_PATH = '/uplink/iroh-devices'

/** 管理路由（挂在 dsh 自己的 webServer 上，仅回环可达）。 */
export const ADMIN_PATHS = Object.freeze({
  state: '/uplink/state',
  pair: '/uplink/pair',
  devices: '/uplink/devices',
  rotate: '/uplink/rotate',
  probe: '/uplink/probe',
  tiers: '/uplink/tiers',
  irohDevices: '/uplink/iroh-devices',
})
