/**
 * 浏览器认证 cookie 的兑换与续期。
 *
 * 这是**唯一**与 dsh 内部耦合的地方，也是整条链路能成立的前提：
 *
 * dsh 的浏览器界面从 0.1.2-alpha 起要求认证 —— 进程启动 token 经 `GET /?token=`
 * 换成 HMAC 签名 cookie，`/api` 与首页没有 cookie 一律 401。而这个 cookie 是
 * `SameSite=Strict` 且**绑定 Host authority** 的，所以：
 *
 *   · 把 token 交给手机没用（手机不是浏览器，也没有那个 authority）；
 *   · 只能由电脑侧自己兑换，再在代理时**逐请求注入**。
 *
 * 兑换失败绝不能静默 —— 表现是手机白屏或满屏 401，而电脑端看起来一切正常。
 * 所以这里把失败原因留在 `status()` 里，由网关翻成一句人话回给手机。
 */
import { DEFAULT_COOKIE_TTL_MS } from './constants.js'

/**
 * @param {object} options
 * @param {() => string} options.authenticatedUrl 返回带 token 的 URL（dsh 的 connection 服务提供）
 * @param {string} options.authority dsh 的 host:port，cookie 绑在这个 authority 上
 * @param {Function} [options.fetchImpl]
 * @param {{warn: Function, info?: Function}} [options.logger]
 * @param {number} [options.refreshMs] 续期间隔
 */
export function createCookieSource({
  authenticatedUrl,
  authority,
  fetchImpl = globalThis.fetch,
  logger,
  refreshMs = DEFAULT_COOKIE_TTL_MS,
  /** 每次兑换成功后回调 —— 用来把新 cookie 同步给需要它的下游（例如 iroh sidecar）。 */
  onRefresh = null,
}) {
  let current = null
  let lastError = null
  let lastSuccessAt = 0
  let timer = null
  let stopped = false

  /** 一次兑换。成功才替换当前 cookie —— 失败时保留旧的那份，旧的可能还没过期。 */
  async function exchangeOnce() {
    const url = authenticatedUrl()
    const response = await fetchImpl(url, { redirect: 'manual' })
    const setCookie = typeof response.headers.getSetCookie === 'function'
      ? response.headers.getSetCookie()
      : []
    if (response.status !== 303 || setCookie.length !== 1) {
      throw new Error(`token 兑换应答异常：HTTP ${response.status}，set-cookie ×${setCookie.length}`)
    }
    // 只要 `name=value` 那段：属性（Path/HttpOnly/SameSite）在注入时没有意义，
    // 而且带着它们会让 dsh 认为收到了一个畸形 cookie。
    const cookie = setCookie[0].split(';', 1)[0]
    if (!cookie.includes('=')) throw new Error(`set-cookie 里没有 cookie 对：${setCookie[0].slice(0, 80)}`)
    current = { cookie, authority }
    lastError = null
    lastSuccessAt = Date.now()
    try {
      onRefresh?.(current)
    } catch (error) {
      // 下游同步失败不该影响兑换本身：cookie 已经拿到了，下一次续期会再试
      logger?.warn?.(`[uplink] cookie 同步给下游失败：${error?.message ?? error}`)
    }
    return current
  }

  /** 带重试的兑换：dsh 刚起来的那几秒 connection 服务可能还没就绪。 */
  async function exchangeWithRetry(attempts = 3) {
    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      try {
        return await exchangeOnce()
      } catch (error) {
        lastError = error?.message ?? String(error)
        if (attempt === attempts) {
          logger?.warn?.(`[uplink] 浏览器认证 cookie 获取失败，手机端会收到 502：${lastError}`)
          return null
        }
        await new Promise((resolve) => setTimeout(resolve, 1000 * attempt))
      }
    }
    return null
  }

  return {
    /** 立刻兑换一次并开始定期续期。 */
    async start() {
      stopped = false
      const result = await exchangeWithRetry()
      if (timer === null) {
        timer = setInterval(() => {
          if (stopped) return
          void exchangeWithRetry()
        }, refreshMs)
        // 别让一个续期定时器把进程钉住（dsh 退出时不该等它）
        timer.unref?.()
      }
      return result
    },
    stop() {
      stopped = true
      if (timer !== null) {
        clearInterval(timer)
        timer = null
      }
    },
    /** @returns {{cookie: string, authority: string} | null} */
    get() {
      return current
    },
    status() {
      return {
        ready: current !== null,
        authority,
        lastSuccessAt,
        lastError,
        cookieName: current === null ? null : current.cookie.split('=', 1)[0],
      }
    },
    /** 测试与"手动重试"按钮用 */
    refresh: () => exchangeWithRetry(),
  }
}
