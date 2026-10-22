/**
 * dsh-plugin-uplink · 多路接入
 *
 * 把「手机怎么连上电脑」从**一种协议**变成**一份可勾选的地址清单**：
 * 电脑侧起一个带鉴权的网关，把 dsh 同时暴露在局域网 / 虚拟组网 / 自建中转 / iroh 上；
 * 手机侧并行探一下，谁快用谁。
 *
 * 设计见仓库 `docs/UPLINK-PLUGIN.md`，决策见 `docs/DECISIONS.md` ADR-0029。
 *
 * 这个文件只做装配：读配置 → 起网关 → 起各档 → 算清单 → 挂管理路由。
 * 真正的逻辑都在 lib/ 下，每个模块单独可测。
 */
import { constants as fsConstants } from 'node:fs'
import { access, mkdir, readdir, readFile } from 'node:fs/promises'
import { homedir, hostname } from 'node:os'
import { dirname, join } from 'node:path'

import { normalizeConfig, priorityOf } from './lib/config.js'
import { DeviceStore } from './lib/auth.js'
import { createCookieSource } from './lib/cookie.js'
import { createGateway } from './lib/gateway.js'
import { ADMIN_PATHS, DETECT_CACHE_MS } from './lib/constants.js'
import { buildDescriptor, encodePairingPayload, publicIdentity } from './lib/descriptor.js'
import { createRunner, detectEnvironment, detectFrpc } from './lib/detect.js'
import { createAdvertiser } from './lib/publish.js'
import { ensureCertificate } from './lib/tls.js'
import { createFrpTier } from './lib/tiers/frp.js'
import { createIrohTier, resolveHostBinary } from './lib/tiers/iroh.js'

const name = 'dsh-plugin-uplink'
/** `connection` 动态 inject：老版本 dsh 没有这个服务，缺了也不该让插件起不来。 */
const inject = ['webServer']

const VERSION = '0.2.0'

/** 终端文案跟随系统语言；插件打在 dsh 的同一个终端上，不能一半中文一半英文。 */
const terminalZh = /^zh/i.test(
  process.env.LC_ALL || process.env.LANG || Intl.DateTimeFormat().resolvedOptions().locale || '',
)
const tt = (zh, en) => (terminalZh ? zh : en)

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

/**
 * 兜底找 tether sidecar。
 *
 * 为什么需要这一步：本插件是通过 `link:` 装进 profile 的，Node 解析裸模块名时用的是
 * **realpath**（仓库路径），所以 profile 自己的 `node_modules` 不在解析链上 ——
 * `resolveHostBinary()` 的 `createRequire().resolve()` 必然落空，而 sidecar 恰恰只装在
 * profile 里。这里直接去 profile 目录翻一遍，避免用户为了一个可选档位手工填路径。
 *
 * 找不到就返回 null，iroh 档位不可用而已，其余档位照常工作。
 */
async function findSidecarInProfiles() {
  const home = process.env.DSH_HOME && process.env.DSH_HOME !== '' ? process.env.DSH_HOME : join(homedir(), '.dsh')
  const profiles = join(home, 'profiles')
  const exe = process.platform === 'win32' ? 'tether-host.exe' : 'tether-host'
  let entries
  try {
    entries = await readdir(profiles, { withFileTypes: true })
  } catch {
    return null
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue
    const modules = join(profiles, entry.name, 'node_modules')
    let packages
    try {
      packages = await readdir(modules)
    } catch {
      continue
    }
    for (const pkg of packages) {
      if (!pkg.startsWith('dsh-tether-host-')) continue
      const candidate = join(modules, pkg, 'bin', exe)
      try {
        await access(candidate, fsConstants.X_OK)
        return candidate
      } catch {
        // 该平台的子包没装（npm 只装匹配当前平台的），继续翻下一个
      }
    }
  }
  return null
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

  // 网关只能转明文 HTTP 到上游：代理流要改写请求头，对着 HTTPS 监听器只会让手机白屏。
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

  const statePath = rawConfig.statePath ?? defaultStatePath()
  const stateDir = dirname(statePath)
  const store = new DeviceStore(statePath, { logger })
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

  // ── 各档的运行时状态 ───────────────────────────────────────────────────
  let cookie = null
  let gateway = null
  let advertiser = null
  let frpTier = null
  let irohTier = null
  let tlsInfo = null
  let actualPort = config.port
  let hostId = ''
  let started = false
  /** 运行时开关（设置页的勾选框用）；重启后回到配置文件的值 —— 配置文件才是唯一事实来源。 */
  const enabled = {
    lan: config.tiers.lan.enabled,
    tailscale: config.tiers.tailscale.enabled,
    zerotier: config.tiers.zerotier.enabled,
    frp: config.tiers.frp.enabled,
    iroh: config.tiers.iroh.enabled,
  }

  const scheme = () => (tlsInfo !== null ? 'https' : 'http')

  /** 本机所有可用于局域网档的地址（自签证书的 SAN 也要用）。 */
  function lanAddresses(env) {
    return (env.candidates ?? []).filter((item) => item.kind === 'lan').map((item) => item.address)
  }

  /**
   * 把配置 + 环境折成"这台电脑现在能从哪几个地址到达"。
   *
   * 顺序即优先级：局域网 → Tailscale → ZeroTier → 自建中转 → iroh。
   * 用户能勾选启用哪些档，但不改顺序 —— 让"自动"有一个可预测的答案。
   */
  async function buildTiers({ port, env }) {
    const tiers = []
    const push = (tier) => tiers.push({ ...tier, prio: priorityOf(tier.kind) })
    const withTls = () => (tlsInfo === null ? {} : { tls: { sha256: tlsInfo.fingerprint256 } })

    if (enabled.lan) {
      for (const candidate of env.candidates ?? []) {
        if (candidate.kind !== 'lan') continue
        push({ kind: 'lan', url: `${scheme()}://${candidate.address}:${port}`, address: candidate.address, iface: candidate.iface, ...withTls() })
      }
    }
    if (enabled.tailscale && env.tailscale?.available === true) {
      for (const address of env.tailscale.addresses) {
        push({ kind: 'tailscale', url: `${scheme()}://${address}:${port}`, address, ...withTls() })
      }
    }
    if (enabled.zerotier && env.zerotier?.available === true) {
      for (const address of env.zerotier.addresses) {
        push({ kind: 'zerotier', url: `${scheme()}://${address}:${port}`, address, ...withTls() })
      }
    }
    if (enabled.frp) {
      const status = frpTier?.status()
      if (status?.url) push({ kind: 'frp', url: status.url })
    }
    if (enabled.iroh && irohTier !== null) {
      const status = irohTier.status()
      if (status.running && status.endpointId) {
        push({ kind: 'iroh', endpointId: status.endpointId, relay: status.relay ?? undefined })
      }
    }
    return tiers
  }

  /** 从"手机连进来时命中的本地地址"反推它走的是哪一档，只用于日志与诊断。 */
  function tierOfAddress(address) {
    if (typeof address !== 'string' || address === '') return 'unknown'
    if (address === '::1' || address.startsWith('127.')) return 'loopback'
    const octets = address.split('.').map(Number)
    if (octets.length === 4 && octets.every((value) => Number.isFinite(value))) {
      if (octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127) return 'tailscale'
    }
    for (const candidate of envCache.value?.candidates ?? []) {
      if (candidate.address === address) return candidate.kind
    }
    return 'lan'
  }

  ctx.effect(() => () => {
    cookie?.stop()
    void advertiser?.stop()
    void frpTier?.stop()
    void irohTier?.stop()
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

  /** 起/停自建中转。返回给管理路由用的一句话结果。 */
  async function syncFrp() {
    if (!enabled.frp) {
      await frpTier?.stop()
      return { state: 'off' }
    }
    if (frpTier === null) {
      frpTier = createFrpTier({
        config,
        gatewayPort: actualPort,
        hostId,
        stateDir,
        run,
        logger,
        frpcPath: config.tiers.frp.frpcPath !== '' ? config.tiers.frp.frpcPath : undefined,
      })
    }
    const result = await frpTier.start()
    if (result.ok) logger.info(`[uplink] 自建中转已就绪：${result.url}`)
    else logger.warn(`[uplink] ${tt(`自建中转不可用（${result.reason}）`, `the self-hosted relay is unavailable (${result.reason})`)}`)
    return result
  }

  /** 起/停 iroh 兜底档。 */
  async function syncIroh() {
    if (!enabled.iroh) {
      await irohTier?.stop()
      return { ok: false, reason: 'disabled' }
    }
    if (irohTier === null) {
      const binaryPath = config.tiers.iroh.binaryPath !== ''
        ? config.tiers.iroh.binaryPath
        : (resolveHostBinary() ?? await findSidecarInProfiles())
      if (!binaryPath) {
        logger.warn(`[uplink] ${tt(
          '找不到 tether sidecar 二进制，iroh 档位不可用（其余档位照常工作）。装 dsh-plugin-tether 或配 tiers.iroh.binaryPath',
          'the tether sidecar binary was not found, so the iroh tier is unavailable (other tiers still work). Install dsh-plugin-tether or set tiers.iroh.binaryPath',
        )}`)
        return { ok: false, reason: 'not-installed' }
      }
      const dataDir = config.tiers.iroh.dataDir !== '' ? config.tiers.iroh.dataDir : join(stateDir, 'iroh')
      await mkdir(dataDir, { recursive: true })
      irohTier = createIrohTier({
        binaryPath,
        proxyTarget: authority,
        dataDir,
        lang: terminalZh ? 'zh' : 'en',
        logger,
      })
    }
    const result = await irohTier.start()
    if (result.ok) {
      logger.info(`[uplink] iroh 兜底档已就绪：${result.endpointId.slice(0, 16)}…`)
    } else {
      logger.warn(`[uplink] ${tt(`iroh 档位不可用（${result.reason}）`, `the iroh tier is unavailable (${result.reason})`)}`)
    }
    return result
  }

  /** Bonjour 广播：让手机零配置发现这台电脑。失败不影响任何数据通路。 */
  async function syncAdvertiser() {
    const want = enabled.lan && config.tiers.lan.bonjour && started
    if (!want) {
      await advertiser?.stop()
      return { ok: false, reason: 'disabled' }
    }
    if (advertiser === null) {
      advertiser = createAdvertiser({
        hostId,
        name: config.name !== '' ? config.name : hostname(),
        port: actualPort,
        version: VERSION,
        logger,
      })
    }
    const result = await advertiser.start()
    if (!result.ok) logger.warn(`[uplink] ${tt(`Bonjour 广播失败（${result.reason}），手机需手工填配对串`, `Bonjour advertising failed (${result.reason}); the phone must use a pasted pairing string`)}`)
    return result
  }

  // ── 主装配 ─────────────────────────────────────────────────────────────
  void (async () => {
    hostId = await store.hostId()
    const displayName = config.name !== '' ? config.name : hostname()

    // 自签 TLS（可选）：局域网也能加密。手机侧用 Network 框架固定指纹，绕开 ATS。
    if (config.tiers.lan.enabled && config.tiers.lan.tls) {
      const env = await environment({ force: true })
      const certificate = await ensureCertificate({
        dir: join(stateDir, 'tls'),
        hostnames: [`${hostId}.local`, hostname()],
        ips: lanAddresses(env),
        run,
      })
      if (certificate.ok) {
        try {
          const [key, cert] = await Promise.all([
            readFile(certificate.keyPath, 'utf8'),
            readFile(certificate.certPath, 'utf8'),
          ])
          tlsInfo = { key, cert, fingerprint256: certificate.fingerprint256 }
          logger.info(`[uplink] 自签 TLS 已启用，指纹 ${certificate.fingerprint256}`)
        } catch (error) {
          logger.warn(`[uplink] 自签证书读取失败，退回明文：${error?.message ?? error}`)
        }
      } else {
        logger.warn(`[uplink] ${tt(`自签证书不可用（${certificate.reason}），退回明文`, `self-signed TLS unavailable (${certificate.reason}); falling back to plain HTTP`)}`)
      }
    }

    gateway = createGateway({
      target,
      store,
      // cookie 可能晚一步就绪（connection 服务是异步注入的），所以用 getter 转发
      cookie: { get: () => cookie?.get() ?? null, status: () => cookie?.status() ?? { ready: false } },
      identity: { hostId, name: displayName, version: VERSION },
      logger,
      tierOfAddress,
      tls: tlsInfo,
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
    logger.info(`[uplink] ${tt('网关已监听', 'gateway listening on')} ${config.bind}:${actualPort}（${scheme()}）`)

    // 两档外网通路并行起，谁失败都不影响内网
    await Promise.all([syncFrp(), syncIroh()])
    await syncAdvertiser()

    const tiers = await buildTiers({ port: actualPort, env })
    if (tiers.length === 0) {
      logger.warn(`[uplink] ${tt(
        '当前没有任何可用档位（局域网地址、Tailscale/ZeroTier、自建中转、iroh 都没启用或探测不到），手机将无法连接',
        'no tier is available (no LAN address, no Tailscale/ZeroTier, no self-hosted relay, no iroh); the phone cannot connect',
      )}`)
    }
    for (const tier of tiers) {
      logger.info(`[uplink]   ${tier.kind.padEnd(9)} ${tier.url ?? `endpoint ${String(tier.endpointId).slice(0, 16)}…`}`)
    }
    if (env.tailscale && env.tailscale.available === false && env.tailscale.reason !== 'not-installed') {
      logger.info(`[uplink] ${tt(
        `Tailscale 不可用（${env.tailscale.reason}）：装了但没登录/没连上时这一档会被跳过`,
        `Tailscale unavailable (${env.tailscale.reason}); the tier is skipped while it is installed but not logged in or not connected`,
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
        scheme: scheme(),
        bind: config.bind,
        port: actualPort,
        configuredPort: config.port,
        tls: tlsInfo === null ? null : { fingerprint256: tlsInfo.fingerprint256 },
        cookie: cookie?.status() ?? { ready: false, reason: 'no-connection-service' },
        enabled,
        environment: {
          fingerprint: env.fingerprint,
          defaultInterface: env.defaultInterface ?? '',
          ssid: env.ssid ?? '',
          candidates: env.candidates ?? [],
          tailscale: env.tailscale ?? { available: false },
          zerotier: env.zerotier ?? { available: false },
        },
        tiers: tiers.map(({ kind, url, prio, endpointId }) => ({ kind, url, prio, endpointId })),
        bonjour: advertiser?.state() ?? { running: false, serviceName: null, lastError: null },
        frp: frpTier?.status() ?? null,
        iroh: irohTier?.status() ?? null,
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
      json(res, 200, { environment: env, frpc, tiers: started ? await buildTiers({ port: actualPort, env }) : [] })
    },
  }))

  /** 运行时勾选/取消档位。只影响本次进程 —— 配置文件才是唯一事实来源。 */
  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: ADMIN_PATHS.tiers,
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
      const body = await readJson(req)
      if (body === undefined || typeof body !== 'object') {
        json(res, 400, { ok: false, reason: 'bad-body' })
        return
      }
      const next = body.enabled && typeof body.enabled === 'object' ? body.enabled : body
      const changes = {}
      for (const key of Object.keys(enabled)) {
        if (typeof next[key] !== 'boolean') continue
        if (next[key] === enabled[key]) continue
        enabled[key] = next[key]
        changes[key] = next[key]
      }
      if (Object.keys(changes).length === 0) {
        json(res, 200, { ok: true, enabled, changes: {} })
        return
      }
      // 只重启受影响的组件：勾选局域网不该把 iroh 拉起来
      const applied = {}
      if ('frp' in changes) applied.frp = await syncFrp()
      if ('iroh' in changes) applied.iroh = await syncIroh()
      if ('lan' in changes) applied.bonjour = await syncAdvertiser()
      logger.info(`[uplink] 档位开关变更：${Object.entries(changes).map(([key, value]) => `${key}=${value ? 'on' : 'off'}`).join('、')}`)
      json(res, 200, { ok: true, enabled, changes, applied })
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
      const urls = tiers.filter((tier) => typeof tier.url === 'string').map((tier) => tier.url)
      const tierHints = tiers
        .filter((tier) => typeof tier.url === 'string')
        .map((tier) => ({ kind: tier.kind, url: tier.url }))
      const irohTierEntry = tiers.find((tier) => tier.kind === 'iroh') ?? null
      const iroh = irohTierEntry === null
        ? null
        : { endpointId: irohTierEntry.endpointId, relay: irohTierEntry.relay ?? null }
      const pairingString = encodePairingPayload({
        hostId,
        name: config.name !== '' ? config.name : hostname(),
        port: actualPort,
        deviceId: device.deviceId,
        secret: device.secret,
        urls,
        tiers: tierHints,
        iroh,
      })
      // iroh 的配对**码**只有几分钟有效期，不能塞进长期保存的配对串里，
      // 所以单独回一份，手机拿到就要立刻用掉。
      let irohPairing = null
      if (irohTier !== null && irohTier.status().running) {
        const opened = await irohTier.openPairing()
        if (opened.ok !== false) irohPairing = { pairingString: opened.pairingString, expiresInSec: opened.expiresInSec }
      }
      logger.info(`[uplink] ${tt('新设备已配对：', 'device paired: ')}${device.name}（${device.deviceId}）`)
      json(res, 200, {
        ok: true,
        deviceId: device.deviceId,
        name: device.name,
        pairingString,
        urls,
        tiers: tierHints,
        iroh,
        irohPairing,
      })
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
