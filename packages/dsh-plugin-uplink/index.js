/**
 * dsh-plugin-uplink · 多路接入
 *
 * 把「手机怎么连上电脑」从**一种协议**变成**一份可勾选的地址清单**：
 * 电脑侧起一个带鉴权的网关，把 dsh 同时暴露在局域网 / 虚拟组网 / 自建中转上；
 * 手机侧并行探一下，谁快用谁。
 *
 * 设计见仓库 `docs/UPLINK-PLUGIN.md`，决策见 `docs/DECISIONS.md` ADR-0029。
 *
 * 这个文件只做装配：读配置 → 起网关 → 算清单 → 挂管理路由。
 * 真正的逻辑都在 lib/ 下，每个模块单独可测。
 */
import { homedir } from 'node:os'
import { hostname } from 'node:os'
import { join } from 'node:path'

import { normalizeConfig, priorityOf } from './lib/config.js'
import { DeviceStore } from './lib/auth.js'
import { createCookieSource } from './lib/cookie.js'
import { createGateway } from './lib/gateway.js'
import { ADMIN_PATHS, DETECT_CACHE_MS } from './lib/constants.js'
import { buildDescriptor, encodePairingPayload, publicIdentity } from './lib/descriptor.js'
import { createRunner, detectEnvironment, detectFrpc } from './lib/detect.js'

const name = 'dsh-plugin-uplink'
/** `connection` 动态 inject：老版本 dsh 没有这个服务，缺了也不该让插件起不来。 */
const inject = ['webServer']

const VERSION = '0.1.0'

/** 终端文案跟随系统语言；插件打在 dsh 的同一个终端上，不能一半中文一半英文。 */
const terminalZh = /^zh/i.test(
  process.env.LC_ALL || process.env.LANG || Intl.DateTimeFormat().resolvedOptions().locale || '',
)
const tt = (zh, en) => (terminalZh ? zh : en)

/** 请求方声明的语言（手机侧会带 Accept-Language），决定路由报错用哪种语言。 */
const tr = (req, zh, en) => {
  const declared = req.headers['accept-language'] || ''
  return /(^|[\s,])zh/i.test(declared) ? zh : en
}

/** dsh 的回环判定（localhost / ::1 / 整个 127/8）。 */
function isLoopbackHostname(value) {
  if (value === 'localhost' || value === '[::1]' || value === '::1') return true
  const parts = String(value).split('.')
  return parts.length === 4 && parts[0] === '127'
    && parts.every((part) => /^\d{1,3}$/.test(part) && Number(part) <= 255)
}

/**
 * 浏览器信任栅栏 —— 判据与 dsh 自己的 `/api` 一致。
 *
 * 挡的是两条"受骗代理"路径：DNS 重绑定（Host 写攻击者域名而套接字落到本机）、
 * 以及恶意页面发出的跨站请求。**挡不住本机进程**（本机 curl 的 Host 就是回环），
 * 这是这套栅栏的设计边界，不是疏漏。
 */
function isTrustedRequest(req) {
  const host = req.headers.host
  if (typeof host !== 'string') return false
  let hostUrl
  try {
    hostUrl = new URL(`http://${host}`)
  } catch {
    return false
  }
  if (!isLoopbackHostname(hostUrl.hostname)) return false
  if (req.headers['sec-fetch-site'] === 'cross-site') return false
  const origin = req.headers.origin
  if (typeof origin !== 'string') return true
  try {
    return new URL(origin).host === hostUrl.host
  } catch {
    return false
  }
}

function json(res, status, body) {
  const payload = Buffer.from(JSON.stringify(body), 'utf8')
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': payload.length,
    'cache-control': 'no-store',
  })
  res.end(payload)
}

async function readJson(req, limit = 8192) {
  return new Promise((resolve) => {
    let size = 0
    const chunks = []
    req.on('data', (chunk) => {
      size += chunk.length
      if (size > limit) {
        resolve(undefined)
        req.destroy()
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')))
      } catch {
        resolve(undefined)
      }
    })
    req.on('error', () => resolve(undefined))
  })
}

/** 状态文件默认落在 dsh 的 home 下，跟其它插件的数据放一起。 */
function defaultStatePath() {
  const home = process.env.DSH_HOME && process.env.DSH_HOME !== '' ? process.env.DSH_HOME : join(homedir(), '.dsh')
  return join(home, 'uplink', 'state.json')
}

/**
 * @param {import('@deepseek-ai/cordis').Context} ctx
 * @param {object} [rawConfig]
 */
function apply(ctx, rawConfig = {}) {
  const { config, warnings } = normalizeConfig(rawConfig)
  for (const warning of warnings) console.warn(`[uplink] ${warning}`)

  // 网关只能转明文 HTTP：代理流要改写请求头，对着 HTTPS 监听器只会让手机白屏。
  if ((ctx.webServer.protocol ?? 'http:') !== 'http:') {
    throw new Error(
      `[uplink] ${tt(
        'dsh web 开了 TLS（https），而网关只能转明文 HTTP，手机连上只会白屏。去掉 webServer 的 tls 配置再用。',
        'dsh web is serving HTTPS, but the uplink gateway can only carry plain HTTP — the phone would get a blank page. Remove the tls config from webServer.',
      )}`,
    )
  }

  const targetHost = String(ctx.webServer.host).replace(/^\[|\]$/g, '')
  const target = { host: targetHost, port: ctx.webServer.port }
  const authority = new URL(`http://${targetHost.includes(':') ? `[${targetHost}]` : targetHost}:${target.port}`).host

  const logger = {
    info: (message) => console.log(message),
    warn: (message) => console.warn(message),
  }

  const store = new DeviceStore(rawConfig.statePath ?? defaultStatePath(), { logger })
  const run = createRunner()

  /** 环境探测结果缓存：探测要 fork 三四个进程，不能每个请求都跑。 */
  let envCache = { at: 0, value: null }
  let envInFlight = null
  async function environment({ force = false } = {}) {
    const now = Date.now()
    if (!force && envCache.value !== null && now - envCache.at < DETECT_CACHE_MS) return envCache.value
    if (envInFlight !== null) return envInFlight
    envInFlight = detectEnvironment({ run })
      .then((value) => {
        envCache = { at: Date.now(), value }
        return value
      })
      .catch((error) => {
        logger.warn(`[uplink] 环境探测失败：${error?.message ?? error}`)
        const fallback = { candidates: [], tailscale: { available: false }, zerotier: { available: false }, fingerprint: 'unknown' }
        envCache = { at: Date.now(), value: fallback }
        return fallback
      })
      .finally(() => { envInFlight = null })
    return envInFlight
  }

  let cookie = null
  let gateway = null
  let actualPort = config.port
  let hostId = ''
  let started = false

  /**
   * 把配置 + 环境折成"这台电脑现在能从哪几个地址到达"。
   *
   * 顺序即优先级：局域网 → Tailscale → ZeroTier → 自建中转 → iroh。
   * 用户能勾选启用哪些档，但不改顺序 —— 让"自动"有一个可预测的答案。
   */
  async function buildTiers({ port, env }) {
    const tiers = []
    const push = (kind, url, extra = {}) => {
      tiers.push({ kind, url, prio: priorityOf(kind), ...extra })
    }

    if (config.tiers.lan.enabled) {
      for (const candidate of env.candidates ?? []) {
        if (candidate.kind !== 'lan') continue
        push('lan', `http://${candidate.address}:${port}`, { address: candidate.address, iface: candidate.iface })
      }
    }
    if (config.tiers.tailscale.enabled && env.tailscale?.available === true) {
      for (const address of env.tailscale.addresses) {
        push('tailscale', `http://${address}:${port}`, { address })
      }
    }
    if (config.tiers.zerotier.enabled && env.zerotier?.available === true) {
      for (const address of env.zerotier.addresses) {
        push('zerotier', `http://${address}:${port}`, { address })
      }
    }
    if (config.tiers.frp.enabled) {
      if (config.tiers.frp.publicUrl !== '') {
        push('frp', config.tiers.frp.publicUrl)
      } else if (config.tiers.frp.serverAddr !== '') {
        const scheme = config.tiers.frp.tls ? 'https' : 'http'
        push('frp', `${scheme}://${config.tiers.frp.serverAddr}:${config.tiers.frp.remotePort}`)
      }
    }
    // iroh 档位由 sidecar 提供，M0 还没接入 —— 显式说出来，别让人以为它生效了。
    return tiers
  }

  /** 从"手机连进来时命中的本地地址"反推它走的是哪一档，只用于日志与诊断。 */
  function tierOfAddress(address) {
    if (typeof address !== 'string' || address === '') return 'unknown'
    if (address === '::1' || address === '127.0.0.1' || address.startsWith('127.')) return 'loopback'
    const octets = address.split('.').map(Number)
    if (octets.length === 4 && octets.every((value) => Number.isFinite(value))) {
      if (octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127) return 'tailscale'
    }
    const env = envCache.value
    for (const candidate of env?.candidates ?? []) {
      if (candidate.address === address) return candidate.kind
    }
    return 'lan'
  }

  ctx.effect(() => () => {
    cookie?.stop()
    void gateway?.close()
  })

  // cookie 兑换：依赖 dsh 的 connection 服务（老版本没有就跳过，网关会明确报 502）
  ctx.inject(['connection'], (connCtx) => {
    if (typeof connCtx.connection?.authenticatedUrl !== 'function') {
      logger.warn(`[uplink] ${tt(
        '这个 dsh 版本没有浏览器认证，uplink 不需要 cookie（网关将直接转发）',
        'this dsh version has no browser auth; uplink does not need a cookie (the gateway proxies directly)',
      )}`)
      return
    }
    cookie = createCookieSource({
      authenticatedUrl: () => connCtx.connection.authenticatedUrl(`http://${authority}/`),
      authority,
      logger,
    })
    void cookie.start().then((result) => {
      if (result === null) return
      logger.info(`[uplink] ${tt('浏览器 cookie 已就绪', 'browser cookie ready')}（${result.cookie.split('=', 1)[0]}）`)
    })
    connCtx.effect(() => () => cookie?.stop())
  })

  // 主装配：探测环境 → 起网关 → 算清单
  void (async () => {
    hostId = await store.hostId()
    const displayName = config.name !== '' ? config.name : hostname()

    gateway = createGateway({
      target,
      store,
      // cookie 可能晚一步就绪（connection 服务是异步注入的），所以用 getter 转发
      cookie: { get: () => cookie?.get() ?? null, status: () => cookie?.status() ?? { ready: false } },
      identity: { hostId, name: displayName, version: VERSION },
      logger,
      tierOfAddress,
    })

    try {
      const bound = await gateway.listen({ port: config.port, bind: config.bind })
      actualPort = bound.port
      // port=0 是"交给系统分配"，不是被占用 —— 别报假警
      if (config.port !== 0 && actualPort !== config.port) {
        logger.warn(`[uplink] ${tt(`端口 ${config.port} 被占用，网关改用 ${actualPort}`, `port ${config.port} is taken; the gateway uses ${actualPort}`)}`)
      }
      started = true
    } catch (error) {
      logger.warn(`[uplink] ${tt(`网关启动失败：${error?.message ?? error}`, `the gateway failed to start: ${error?.message ?? error}`)}`)
      return
    }

    const env = await environment({ force: true })
    const tiers = await buildTiers({ port: actualPort, env })
    logger.info(`[uplink] ${tt('网关已监听', 'gateway listening on')} ${config.bind}:${actualPort}`)
    if (tiers.length === 0) {
      logger.warn(`[uplink] ${tt(
        '当前没有任何可用档位（局域网地址、Tailscale/ZeroTier、自建中转都没启用或探测不到），手机将无法连接',
        'no tier is available (no LAN address, no Tailscale/ZeroTier, no self-hosted relay); the phone cannot connect',
      )}`)
    }
    for (const tier of tiers) {
      logger.info(`[uplink]   ${tier.kind.padEnd(9)} ${tier.url}`)
    }
    if (env.tailscale && env.tailscale.available === false && env.tailscale.reason !== 'not-installed') {
      logger.info(`[uplink] ${tt(
        `Tailscale 不可用（${env.tailscale.reason}）：装了但没登录/没连上时这一档会被跳过`,
        `Tailscale unavailable (${env.tailscale.reason}); the tier is skipped while it is installed but not logged in or not connected`,
      )}`)
    }
    if (config.tiers.iroh.enabled) {
      logger.info(`[uplink] ${tt(
        'iroh 档位尚未接入（M0 只做局域网），清单里不会有它',
        'the iroh tier is not wired up yet (M0 is LAN only), so it is absent from the descriptor',
      )}`)
    }
  })()

  // ── 管理路由：挂在 dsh 自己的 webServer 上，只有本机可达 ──────────────────

  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: ADMIN_PATHS.state,
    handler: async (req, res) => {
      if (!isTrustedRequest(req)) {
        res.writeHead(403, { 'content-type': 'text/plain; charset=utf-8' })
        res.end('forbidden')
        return
      }
      const env = await environment()
      const tiers = started ? await buildTiers({ port: actualPort, env }) : []
      const devices = await store.list()
      json(res, 200, {
        version: VERSION,
        hostId,
        name: config.name !== '' ? config.name : hostname(),
        started,
        bind: config.bind,
        port: actualPort,
        configuredPort: config.port,
        cookie: cookie?.status() ?? { ready: false, reason: 'no-connection-service' },
        environment: {
          fingerprint: env.fingerprint,
          defaultInterface: env.defaultInterface ?? '',
          ssid: env.ssid ?? '',
          candidates: env.candidates ?? [],
          tailscale: env.tailscale ?? { available: false },
          zerotier: env.zerotier ?? { available: false },
        },
        tiers: tiers.map(({ kind, url, prio }) => ({ kind, url, prio })),
        devices: devices.map(({ deviceId, name, createdAt, lastSeen, revoked }) => ({
          deviceId, name, createdAt, lastSeen, revoked,
        })),
        stats: gateway?.stats() ?? null,
        warnings,
      })
    },
  }))

  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: ADMIN_PATHS.probe,
    handler: async (req, res) => {
      if (!isTrustedRequest(req)) {
        res.writeHead(403, { 'content-type': 'text/plain; charset=utf-8' })
        res.end('forbidden')
        return
      }
      const env = await environment({ force: true })
      const frpc = config.tiers.frp.enabled && config.tiers.frp.mode === 'managed'
        ? await detectFrpc({ run })
        : null
      json(res, 200, { environment: env, frpc })
    },
  }))

  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: ADMIN_PATHS.pair,
    handler: async (req, res) => {
      if (!isTrustedRequest(req)) {
        res.writeHead(403, { 'content-type': 'text/plain; charset=utf-8' })
        res.end('forbidden')
        return
      }
      if (req.method !== 'POST') {
        json(res, 405, { ok: false, reason: 'method' })
        return
      }
      if (!started) {
        json(res, 503, { ok: false, reason: 'gateway-not-running' })
        return
      }
      const body = (await readJson(req)) ?? {}
      const env = await environment({ force: true })
      const tiers = await buildTiers({ port: actualPort, env })
      const device = await store.createDevice(body.name)
      const urls = tiers.map((tier) => tier.url)
      const pairingString = encodePairingPayload({
        hostId,
        name: config.name !== '' ? config.name : hostname(),
        port: actualPort,
        deviceId: device.deviceId,
        secret: device.secret,
        urls,
      })
      logger.info(`[uplink] ${tt('新设备已配对：', 'device paired: ')}${device.name}（${device.deviceId}）`)
      json(res, 200, { ok: true, deviceId: device.deviceId, name: device.name, pairingString, urls })
    },
  }))

  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: ADMIN_PATHS.devices,
    handler: async (req, res) => {
      if (!isTrustedRequest(req)) {
        res.writeHead(403, { 'content-type': 'text/plain; charset=utf-8' })
        res.end('forbidden')
        return
      }
      if (req.method === 'GET') {
        json(res, 200, { ok: true, devices: await store.list() })
        return
      }
      if (req.method === 'POST') {
        const body = await readJson(req)
        const deviceId = typeof body?.id === 'string' ? body.id : ''
        if (deviceId === '') {
          json(res, 400, { ok: false, reason: 'missing-id' })
          return
        }
        const revoked = await store.revoke(deviceId)
        logger.info(`[uplink] ${tt('撤销设备：', 'device revoked: ')}${deviceId}`)
        json(res, revoked ? 200 : 404, { ok: revoked })
        return
      }
      json(res, 405, { ok: false, reason: 'method' })
    },
  }))

  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: ADMIN_PATHS.rotate,
    handler: async (req, res) => {
      if (!isTrustedRequest(req)) {
        res.writeHead(403, { 'content-type': 'text/plain; charset=utf-8' })
        res.end('forbidden')
        return
      }
      if (req.method !== 'POST') {
        json(res, 405, { ok: false, reason: 'method' })
        return
      }
      const keyVersion = await store.rotateKey()
      logger.info(`[uplink] ${tt(`签名密钥已轮换到 v${keyVersion}，所有在途票据失效`, `signing key rotated to v${keyVersion}; all outstanding tickets are void`)}`)
      json(res, 200, { ok: true, keyVersion })
    },
  }))
}

export { name, inject, apply }

// 便于单测与其它模块复用
export { buildDescriptor, publicIdentity }
