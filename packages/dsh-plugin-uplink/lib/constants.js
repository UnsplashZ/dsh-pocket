/** 跨模块共享的常量。改这里之前先想清楚有没有别的地方依赖这个值。 */

/** cookie 的续期间隔。dsh 的 cookie 默认 30 天有效，12 小时续一次足够早。 */
export const DEFAULT_COOKIE_TTL_MS = 12 * 60 * 60 * 1000

/** 环境探测结果的缓存时长。探测要 fork 三四个进程，不能每次请求都跑。 */
export const DETECT_CACHE_MS = 30_000

/** 免票路由：只有这两条能在没有票据的情况下访问。 */
export const PUBLIC_PATHS = Object.freeze(['/uplink/hello', '/uplink/ping'])

/** 换票路由。 */
export const AUTH_PATH = '/uplink/auth'

/** 管理路由（挂在 dsh 自己的 webServer 上，仅回环可达）。 */
export const ADMIN_PATHS = Object.freeze({
  state: '/uplink/state',
  pair: '/uplink/pair',
  devices: '/uplink/devices',
  rotate: '/uplink/rotate',
  probe: '/uplink/probe',
  tiers: '/uplink/tiers',
})
