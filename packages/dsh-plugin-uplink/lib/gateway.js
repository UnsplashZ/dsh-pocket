/**
 * 网关：把 dsh 暴露成一个"带鉴权的 HTTP/WS 反向代理"。
 *
 * 全部四类通路最终都落到这个 server 上 —— 这是整个插件最省事的地方：
 *   · 局域网 / Tailscale / ZeroTier 是**同一个监听**的不同地址（绑 0.0.0.0 就都有了）；
 *   · frp 只是把这个端口从公网映射进来；
 *   · iroh 走的是另一条完全不同的路（sidecar 的代理流），与这里无关。
 *
 * 所以"新增一档"不需要改这个文件，只需要多一个地址。
 *
 * 安全边界（三条硬线，改代码时不要破）：
 *   1. 只转发到**回环上的 dsh**，不做通用正向代理 —— 不能变成跳板；
 *   2. 除 `/uplink/hello` 与 `/uplink/ping` 外，一律要票据；
 *   3. 认证失败按 IP 限流（见 lib/auth.js），防止拿网关当 HMAC 预言机。
 */
import http from 'node:http'
import https from 'node:https'
import { AUTH_PATH, DESCRIPTOR_PATH, PUBLIC_PATHS } from './constants.js'
import { publicIdentity } from './descriptor.js'

/** hop-by-hop 头不能透传（RFC 7230 §6.1），否则连接语义会错乱。 */
const HOP_BY_HOP = new Set([
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
])

function stripHopByHop(headers) {
  const out = {}
  for (const [key, value] of Object.entries(headers)) {
    if (!HOP_BY_HOP.has(key.toLowerCase())) out[key] = value
  }
  return out
}

function json(res, status, body, extraHeaders = {}) {
  const payload = Buffer.from(JSON.stringify(body), 'utf8')
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': payload.length,
    'cache-control': 'no-store',
    ...extraHeaders,
  })
  res.end(payload)
}

function text(res, status, body) {
  const payload = Buffer.from(String(body), 'utf8')
  res.writeHead(status, {
    'content-type': 'text/plain; charset=utf-8',
    'content-length': payload.length,
    'cache-control': 'no-store',
  })
  res.end(payload)
}

/** 客户端 IP：优先 `x-forwarded-for`（frp 之后），否则用 socket 地址。 */
function clientIp(req) {
  const forwarded = req.headers['x-forwarded-for']
  if (typeof forwarded === 'string' && forwarded.length > 0) {
    return forwarded.split(',')[0].trim()
  }
  return req.socket.remoteAddress ?? 'unknown'
}

function bearer(req) {
  const header = req.headers.authorization
  if (typeof header !== 'string') return null
  const match = /^Bearer\s+(.+)$/i.exec(header.trim())
  return match === null ? null : match[1].trim()
}

/** 读一个小 JSON body（认证请求只有几百字节）。 */
function readJsonBody(req, limit = 4096) {
  return new Promise((resolve) => {
    let size = 0
    const chunks = []
    req.on('data', (chunk) => {
      size += chunk.length
      if (size > limit) {
        resolve({ ok: false, reason: 'too-large' })
        req.destroy()
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => {
      try {
        resolve({ ok: true, value: JSON.parse(Buffer.concat(chunks).toString('utf8')) })
      } catch {
        resolve({ ok: false, reason: 'bad-json' })
      }
    })
    req.on('error', () => resolve({ ok: false, reason: 'aborted' }))
  })
}

/**
 * @param {object} options
 * @param {{host: string, port: number}} options.target dsh 自己的监听地址（永远是回环）
 * @param {import('./auth.js').DeviceStore} options.store
 * @param {{get: () => ({cookie: string, authority: string}|null), status: Function}} options.cookie
 * @param {object} options.identity `{hostId, name, version}`
 * @param {{info: Function, warn: Function}} [options.logger]
 * @param {(address: string) => string} [options.tierOfAddress] 从本地监听地址反推档位（日志用）
 */
export function createGateway({
  target,
  store,
  cookie,
  identity,
  logger,
  tierOfAddress = () => 'unknown',
  /** 现算清单（`() => descriptor`）。要票：地址清单本身也是信息，不该给未配对的人看。 */
  descriptor = null,
  /**
   * 可选的自签 TLS。传 `{key, cert}`（PEM 内容，不是路径）就起 https，
   * 否则起明文 http —— 局域网默认明文是刻意的：ATS 不挡 IP 字面量，
   * 加 TLS 要手机侧固定指纹，属于"可选加固"而不是默认拦路。
   */
  tls = null,
}) {
  const server = tls ? https.createServer({ key: tls.key, cert: tls.cert }) : http.createServer()
  /**
   * 升级过的 socket 必须自己记账。
   *
   * 实测：Node 的 http server 在 `upgrade` 之后**不再跟踪**那条连接，
   * 于是 `closeAllConnections()` 碰不到它、`close()` 的回调永远不触发 ——
   * 插件卸载时会把整个 dsh 卡在退出路上。所以这里自己存一份。
   */
  const upgradedSockets = new Set()
  const stats = {
    startedAt: Date.now(),
    requests: 0,
    upgraded: 0,
    unauthorized: 0,
    bytesUp: 0,
    bytesDown: 0,
    lastTier: 'unknown',
    lastError: null,
  }

  /**
   * 把一条请求转给 dsh。
   *
   * 逐请求注入 cookie —— 这是整个方案能成立的核心，也是不能换成"给手机一个 token"的原因。
   */
  function proxyRequest(req, res, { deviceName }) {
    const auth = cookie.get()
    if (auth === null) {
      // 电脑侧自己没拿到 cookie：明确告诉手机是"电脑端认证失败"，
      // 而不是让它看到一个 401 去怀疑自己的密钥。
      stats.lastError = 'cookie-unavailable'
      text(res, 502, '电脑端认证失败：uplink 拿不到 dsh 的浏览器 cookie，请重启 dsh 后重试。')
      return
    }
    const headers = stripHopByHop(req.headers)
    delete headers.authorization // 网关的票据不给 dsh 看，它只认自己的 cookie
    headers.host = auth.authority
    headers.cookie = auth.cookie
    headers['x-forwarded-for'] = clientIp(req)
    headers['x-dsh-device'] = encodeURIComponent(deviceName ?? '')

    const upstream = http.request(
      { host: target.host, port: target.port, method: req.method, path: req.url, headers },
      (upstreamRes) => {
        const responseHeaders = stripHopByHop(upstreamRes.headers)
        res.writeHead(upstreamRes.statusCode ?? 502, responseHeaders)
        upstreamRes.on('data', (chunk) => { stats.bytesDown += chunk.length })
        upstreamRes.pipe(res)
        upstreamRes.on('error', (error) => {
          stats.lastError = `upstream-res: ${error?.message ?? error}`
          res.destroy()
        })
      },
    )

    upstream.on('error', (error) => {
      stats.lastError = `upstream: ${error?.message ?? error}`
      logger?.warn?.(`[uplink] 转发失败（${req.method} ${req.url}）：${error?.message ?? error}`)
      if (!res.headersSent) text(res, 502, '电脑端转发失败：dsh 可能已经退出。')
      else res.destroy()
    })

    req.on('data', (chunk) => { stats.bytesUp += chunk.length })
    req.pipe(upstream)
    // 手机提前断开时把上游也断掉，否则 dsh 那边会挂着一个没人读的请求
    req.on('aborted', () => upstream.destroy())
  }

  /** 认证：验票 → 放行；否则 401。 */
  async function authorize(req) {
    const ticket = bearer(req)
    if (ticket === null) return { ok: false, reason: 'no-ticket' }
    const result = await store.verifyTicket(ticket)
    return result
  }

  server.on('request', (req, res) => {
    void (async () => {
      const path = (req.url ?? '/').split('?')[0]
      const ip = clientIp(req)
      stats.requests += 1
      stats.lastTier = tierOfAddress(req.socket.localAddress ?? '')

      // ── 免票路由 ────────────────────────────────────────────────────
      if (path === PUBLIC_PATHS[0]) {
        // 用 publicIdentity 而不是直接摊开 identity：**公开什么由一处决定**，
        // 免得以后有人往 identity 里加个字段就顺带泄露了。
        json(res, 200, { ok: true, ...publicIdentity(identity) })
        return
      }
      if (path === PUBLIC_PATHS[1]) {
        json(res, 200, { ok: true, hostId: identity.hostId, v: identity.version })
        return
      }

      // ── 换票 ────────────────────────────────────────────────────────
      if (path === AUTH_PATH) {
        if (req.method !== 'POST') {
          json(res, 405, { ok: false, reason: 'method' })
          return
        }
        const blocked = store.blockedFor(ip)
        if (blocked > 0) {
          json(res, 429, { ok: false, reason: 'rate-limited', retryAfterMs: blocked })
          return
        }
        const body = await readJsonBody(req)
        if (!body.ok) {
          store.noteFailure(ip)
          json(res, 400, { ok: false, reason: body.reason })
          return
        }
        const verified = await store.verifyProof(body.value ?? {})
        if (!verified.ok) {
          store.noteFailure(ip)
          stats.unauthorized += 1
          logger?.warn?.(`[uplink] 认证失败（${ip}）：${verified.reason}`)
          json(res, 401, { ok: false, reason: verified.reason })
          return
        }
        const { ticket, ttl } = await store.issueTicket(verified.deviceId)
        logger?.info?.(`[uplink] 设备换票：${verified.deviceId}（${ip}）`)
        json(res, 200, { ok: true, ticket, ttl })
        return
      }

      // ── 其余一律要票 ────────────────────────────────────────────────
      const authorized = await authorize(req)
      if (!authorized.ok) {
        stats.unauthorized += 1
        json(res, 401, { ok: false, reason: authorized.reason })
        return
      }

      // 清单：手机拿它刷新"这台电脑现在有哪些地址"（配对串只是快照）
      if (path === DESCRIPTOR_PATH && descriptor !== null) {
        try {
          json(res, 200, { ok: true, ...(await descriptor()) })
        } catch (error) {
          stats.lastError = `descriptor: ${error?.message ?? error}`
          json(res, 500, { ok: false, reason: 'descriptor-failed' })
        }
        return
      }

      proxyRequest(req, res, { deviceName: authorized.name })
    })().catch((error) => {
      stats.lastError = `handler: ${error?.message ?? error}`
      logger?.warn?.(`[uplink] 请求处理异常：${error?.message ?? error}`)
      if (!res.headersSent) text(res, 500, 'internal error')
      else res.destroy()
    })
  })

  /**
   * WebSocket 升级。
   *
   * 这里不能走 `http.request` 的普通响应路径 —— 升级是"客户端拿到 101 之后，
   * 底层 socket 直接被接管"。所以：先验票，再向 dsh 发起一个带 Upgrade 的请求，
   * 拿到它那边的 101 之后把两条 socket 对接起来。
   */
  server.on('upgrade', (req, socket, head) => {
    void (async () => {
      const ip = clientIp(req)
      const authorized = await authorize(req)
      if (!authorized.ok) {
        stats.unauthorized += 1
        // 升级失败只能用裸 socket 回一个 HTTP 响应
        socket.write('HTTP/1.1 401 Unauthorized\r\nconnection: close\r\ncontent-length: 0\r\n\r\n')
        socket.destroy()
        return
      }
      const auth = cookie.get()
      if (auth === null) {
        socket.write('HTTP/1.1 502 Bad Gateway\r\nconnection: close\r\ncontent-length: 0\r\n\r\n')
        socket.destroy()
        return
      }
      const headers = { ...req.headers }
      delete headers.authorization
      headers.host = auth.authority
      headers.cookie = auth.cookie
      headers['x-forwarded-for'] = ip
      headers['x-dsh-device'] = encodeURIComponent(authorized.name ?? '')
      headers.connection = 'Upgrade'
      headers.upgrade = req.headers.upgrade ?? 'websocket'

      const upstream = http.request({
        host: target.host,
        port: target.port,
        method: req.method,
        path: req.url,
        headers,
      })

      upstream.on('upgrade', (upstreamRes, upstreamSocket, upstreamHead) => {
        stats.upgraded += 1
        stats.lastTier = tierOfAddress(socket.localAddress ?? '')
        // 记账：close() 要靠这份清单才能把这些连接断掉（见文件头 upgradedSockets）
        upgradedSockets.add(socket)
        socket.on('close', () => upgradedSockets.delete(socket))
        const lines = [`HTTP/1.1 ${upstreamRes.statusCode ?? 101} ${upstreamRes.statusMessage ?? 'Switching Protocols'}`]
        for (const [key, value] of Object.entries(upstreamRes.headers)) {
          for (const item of Array.isArray(value) ? value : [value]) {
            if (item !== undefined) lines.push(`${key}: ${item}`)
          }
        }
        socket.write(`${lines.join('\r\n')}\r\n\r\n`)
        if (upstreamHead?.length > 0) socket.write(upstreamHead)
        if (head?.length > 0) upstreamSocket.write(head)

        upstreamSocket.on('data', (chunk) => { stats.bytesDown += chunk.length })
        socket.on('data', (chunk) => { stats.bytesUp += chunk.length })

        // 两侧都要能互相拖死：一边关另一边也关，别留半开连接
        upstreamSocket.pipe(socket)
        socket.pipe(upstreamSocket)
        const close = () => {
          socket.destroy()
          upstreamSocket.destroy()
        }
        upstreamSocket.on('error', close)
        socket.on('error', close)
        upstreamSocket.on('close', () => socket.destroy())
        socket.on('close', () => upstreamSocket.destroy())
      })

      upstream.on('response', (upstreamRes) => {
        // dsh 拒绝了升级（例如 401/404）：原样转回去，别让手机干等
        const lines = [`HTTP/1.1 ${upstreamRes.statusCode} ${upstreamRes.statusMessage}`]
        for (const [key, value] of Object.entries(upstreamRes.headers)) {
          for (const item of Array.isArray(value) ? value : [value]) {
            if (item !== undefined) lines.push(`${key}: ${item}`)
          }
        }
        socket.write(`${lines.join('\r\n')}\r\n\r\n`)
        upstreamRes.pipe(socket)
      })

      upstream.on('error', (error) => {
        stats.lastError = `upgrade: ${error?.message ?? error}`
        socket.destroy()
      })
      socket.on('error', () => upstream.destroy())
      upstream.end()
    })().catch((error) => {
      stats.lastError = `upgrade-handler: ${error?.message ?? error}`
      logger?.warn?.(`[uplink] 升级处理异常：${error?.message ?? error}`)
      socket.destroy()
    })
  })

  /**
   * 监听。端口被占用就顺延（最多 20 次）。
   *
   * 为什么不直接报错：网关端口是"给手机用的入口"，不是协议约定值。真实端口会随
   * 清单与 Bonjour 一起下发，所以顺延对手机完全透明 —— 而报错会让整个插件不可用。
   */
  function listen({ port, bind, attempts = 20 }) {
    return new Promise((resolve, reject) => {
      let attempt = 0
      const tryPort = (candidate) => {
        const onError = (error) => {
          server.removeListener('listening', onListening)
          if (error?.code === 'EADDRINUSE' && attempt < attempts) {
            attempt += 1
            tryPort(candidate + 1)
            return
          }
          reject(error)
        }
        const onListening = () => {
          server.removeListener('error', onError)
          resolve({ port: server.address().port, bind })
        }
        server.once('error', onError)
        server.once('listening', onListening)
        server.listen(candidate, bind)
      }
      tryPort(port)
    })
  }

  function close() {
    return new Promise((resolve) => {
      // 升级过的连接不在 server 的跟踪里，得先自己清掉，否则 close() 永不回调
      for (const socket of upgradedSockets) {
        try {
          socket.destroy()
        } catch {
          // 已经断了
        }
      }
      upgradedSockets.clear()
      server.close(() => resolve())
      server.closeAllConnections?.()
      // 兜底：插件卸载绝不能把宿主卡在退出路上。2 秒还没关干净就直接返回。
      const fallback = setTimeout(() => resolve(), 2000)
      fallback.unref?.()
    })
  }

  return {
    server,
    listen,
    close,
    stats: () => ({ ...stats, uptimeMs: Date.now() - stats.startedAt }),
  }
}
