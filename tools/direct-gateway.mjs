#!/usr/bin/env node
// 直连网关：把进来的请求转发到本机 DSH，并逐请求注入一个现签的会话 cookie。
//
// 同一个工具服务三种场景，区别只在**绑到哪个地址**：
//
//   1. DEV-DIRECT（模拟器开发）
//        node tools/direct-gateway.mjs
//      绑 127.0.0.1:8788。客户端（模拟器里的 App）只管打这个地址，
//      与真机模式下打 TetherKit 派生的本地代理端口**完全同构**（ADR-0009）。
//
//   2. 同一局域网 / Tailscale 直连
//        node tools/direct-gateway.mjs --host 100.x.y.z --token <随机串>
//      绑到 tailnet 或局域网地址。这条路绕开 iroh 的打洞与中转，走的是
//      WireGuard / 局域网的稳定 TCP —— 在电脑上常驻 TUN 类代理
//      （sing-box、Clash 的 tun 模式）时，往往比 P2P 可靠得多。
//
//   3. 公网
//      把本网关放在 TLS 反向代理（Caddy / Cloudflare Tunnel）后面，
//      客户端填 https://your.host。**必须**同时设 --token。
//
// ⚠️ 安全边界（绑非回环地址时**必须**设 token）：
//   这个网关会代替你向 DSH 认证，也就是**任何能连上它的人都等于拿到了你的 DSH**。
//   回环之外一律要求 token；tailnet / 局域网本身有加密与设备认证，
//   但 token 是第二道门。不要把 --host 0.0.0.0 直接暴露到公网。
//
// 零依赖：Node 自带的 http / net / crypto 足够处理 HTTP 转发与 WebSocket 升级。
import { createRequire } from 'node:module'
import http from 'node:http'
import net from 'node:net'
import crypto from 'node:crypto'

const require = createRequire(import.meta.url)
const { cookieFor } = require('./mint-cookie.cjs')

function parseArgs(argv) {
  const options = { host: '127.0.0.1', port: 8788, target: '127.0.0.1:19387', token: '', quiet: false }
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index]
    if (token === '--host') options.host = argv[++index]
    else if (token === '--port') options.port = Number(argv[++index])
    else if (token === '--target') options.target = argv[++index]
    else if (token === '--token') options.token = argv[++index]
    else if (token === '--quiet') options.quiet = true
    else if (token === '--help' || token === '-h') options.help = true
  }
  return options
}

const LOOPBACK = new Set(['127.0.0.1', '::1', 'localhost'])

const options = parseArgs(process.argv.slice(2))

if (options.help) {
  console.log(`用法: node tools/direct-gateway.mjs [--host 127.0.0.1] [--port 8788]
                                    [--target 127.0.0.1:19387] [--token <串>] [--quiet]

  --host   绑到哪个地址。默认回环（DEV-DIRECT）。绑 tailnet / 局域网地址时
           必须同时给 --token。
  --token  共享令牌。客户端把它放在 Authorization: Bearer <token> 里。
  --target 本机 DSH 的 authority，默认 127.0.0.1:19387。

例子：
  node tools/direct-gateway.mjs                                   # 模拟器 DEV-DIRECT
  node tools/direct-gateway.mjs --host 100.64.0.1 --token s3cret  # Tailscale 直连
  node tools/direct-gateway.mjs --host 192.168.1.20 --token s3cret # 同一 Wi-Fi`)
  process.exit(0)
}

const isLoopback = LOOPBACK.has(options.host)
if (!isLoopback && !options.token) {
  console.error(`[direct-gateway] 绑非回环地址（${options.host}）必须设 --token。`)
  console.error('[direct-gateway] 这个网关会代替你向 DSH 认证 —— 谁能连上它，谁就等于拿到了你的 DSH。')
  console.error(`[direct-gateway] 生成一个：node -e "console.log(require('crypto').randomBytes(24).toString('base64url'))"`)
  process.exit(1)
}
if (isLoopback && options.token) {
  console.log('[direct-gateway] 回环地址上的 token 会被要求（客户端需要填同样的值）')
}

const [targetHost, targetPortText] = options.target.split(':')
const targetPort = Number(targetPortText)

/** cookie 与 authority 绑定，所以按目标 authority 现签；DSH 重启后 token 轮换，这里每次请求重签。 */
function cookieHeader() {
  try {
    return cookieFor(`${targetHost}:${targetPort}`)
  } catch (error) {
    console.error(`[direct-gateway] 无法签发 cookie：${error.message}`)
    console.error('[direct-gateway] 提示：确认 DSH 已启动过至少一次（~/.dsh/.credentials.yaml 存在）')
    return null
  }
}

function log(...args) {
  if (!options.quiet) console.log('[direct-gateway]', ...args)
}

/**
 * 令牌校验。回环且没设 token 时放行（本机开发）；否则一律要求
 * `Authorization: Bearer <token>`，比较用定长比较避免计时侧信道。
 */
function authorize(headers) {
  if (isLoopback && !options.token) return true
  const raw = headers.authorization
  const value = Array.isArray(raw) ? raw[0] : raw
  if (typeof value !== 'string') return false
  const prefix = 'Bearer '
  if (!value.startsWith(prefix)) return false
  const provided = Buffer.from(value.slice(prefix.length))
  const expected = Buffer.from(options.token)
  if (provided.length !== expected.length) return false
  return crypto.timingSafeEqual(provided, expected)
}

const server = http.createServer((request, response) => {
  if (!authorize(request.headers)) {
    response.writeHead(401, { 'content-type': 'text/plain; charset=utf-8' })
    response.end('direct-gateway: 缺少或错误的 Authorization: Bearer <token>')
    return
  }

  const cookie = cookieHeader()
  if (cookie === null) {
    response.writeHead(500, { 'content-type': 'text/plain; charset=utf-8' })
    response.end('direct-gateway: 无法签发会话 cookie，检查 ~/.dsh/.credentials.yaml')
    return
  }

  const headers = { ...request.headers }
  headers.cookie = cookie
  // Host 必须是回环 authority，且不能带 Origin（DSH 的 trust 栅栏要求同源）。
  delete headers.origin
  delete headers.referer
  headers.host = `${targetHost}:${targetPort}`

  const upstream = http.request(
    { host: targetHost, port: targetPort, method: request.method, path: request.url, headers },
    (upstreamResponse) => {
      response.writeHead(upstreamResponse.statusCode ?? 502, upstreamResponse.headers)
      upstreamResponse.pipe(response)
    }
  )

  upstream.on('error', (error) => {
    log(`${request.method} ${request.url} ✗ ${error.message}`)
    response.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' })
    response.end(`direct-gateway: 连不上 DSH（${targetHost}:${targetPort}）：${error.message}`)
  })

  request.pipe(upstream)
  log(`${request.method} ${request.url}`)
})

// WebSocket 升级：/api/remote.mux 全靠这条。升级后就是裸字节双向拷贝。
server.on('upgrade', (request, clientSocket, head) => {
  if (!authorize(request.headers)) {
    clientSocket.end('HTTP/1.1 401 Unauthorized\r\n\r\n')
    return
  }

  const cookie = cookieHeader()
  if (cookie === null) {
    clientSocket.destroy()
    return
  }

  const headers = { ...request.headers }
  headers.cookie = cookie
  delete headers.origin
  headers.host = `${targetHost}:${targetPort}`

  const upstream = net.connect(targetPort, targetHost, () => {
    const requestLine = `${request.method} ${request.url} HTTP/1.1\r\n`
    const headerLines = Object.entries(headers)
      .flatMap(([key, value]) => Array.isArray(value) ? value.map((item) => `${key}: ${item}`) : [`${key}: ${value}`])
      .join('\r\n')
    upstream.write(requestLine + headerLines + '\r\n\r\n')
    if (head?.length) upstream.write(head)
    upstream.pipe(clientSocket)
    clientSocket.pipe(upstream)
    log(`WS ↑ ${request.url}`)
  })

  const teardown = () => {
    upstream.destroy()
    clientSocket.destroy()
  }
  upstream.on('error', teardown)
  clientSocket.on('error', teardown)
  clientSocket.on('close', () => upstream.destroy())
  upstream.on('close', () => clientSocket.destroy())
})

server.listen(options.port, options.host, () => {
  const base = `http://${options.host}:${options.port}`
  console.log(`[direct-gateway] 就绪：${base} → ${options.target}（逐请求注入 cookie）`)
  if (isLoopback && !options.token) {
    console.log('[direct-gateway] 回环模式（DEV-DIRECT）：客户端 baseURL 填 ' + base)
  } else {
    console.log('[direct-gateway] 客户端填：')
    console.log(`[direct-gateway]   地址   ${base}`)
    console.log(`[direct-gateway]   令牌   ${options.token}`)
    console.log('[direct-gateway] 手机需要能路由到这个地址（同一 Wi-Fi 或同一个 tailnet）。')
  }
})

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    server.close(() => process.exit(0))
    setTimeout(() => process.exit(0), 500)
  })
}
