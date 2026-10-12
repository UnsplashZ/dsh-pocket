#!/usr/bin/env node
// DEV-DIRECT：把 127.0.0.1:8788 上的请求转发到本机 DSH（默认 127.0.0.1:19387），
// 并逐请求注入一个现签的会话 cookie。
//
// 存在的理由（见 docs/DECISIONS.md ADR-0009）：正常链路需要真机 + 配对 + iroh 全通，
// 迭代成本高。有了它，95% 的界面与协议工作可以在模拟器里做完 —— 客户端只管打
// http://127.0.0.1:8788，与真机模式下打 TetherKit 派生的本地代理端口**完全同构**。
//
//   node tools/dev-proxy.mjs                 # 监听 8788，转发到 127.0.0.1:19387
//   node tools/dev-proxy.mjs --port 8788 --target 127.0.0.1:19387
//
// 零依赖：Node 自带的 http / net 足够处理 HTTP 转发与 WebSocket 升级。
import { createRequire } from 'node:module'
import http from 'node:http'
import net from 'node:net'

const require = createRequire(import.meta.url)
const { cookieFor } = require('./mint-cookie.cjs')

function parseArgs(argv) {
  const options = { port: 8788, target: '127.0.0.1:19387', quiet: false }
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index]
    if (token === '--port') options.port = Number(argv[++index])
    else if (token === '--target') options.target = argv[++index]
    else if (token === '--quiet') options.quiet = true
    else if (token === '--help' || token === '-h') options.help = true
  }
  return options
}

const options = parseArgs(process.argv.slice(2))

if (options.help) {
  console.log(`用法: node tools/dev-proxy.mjs [--port 8788] [--target 127.0.0.1:19387] [--quiet]

DEV-DIRECT：客户端直连本代理，代理注入 cookie 后转发到 DSH。`)
  process.exit(0)
}

const [targetHost, targetPortText] = options.target.split(':')
const targetPort = Number(targetPortText)

/** cookie 与 authority 绑定，所以按目标 authority 现签；DSH 重启后 token 轮换，这里每次请求重签。 */
function cookieHeader() {
  try {
    return cookieFor(`${targetHost}:${targetPort}`)
  } catch (error) {
    console.error(`[dev-proxy] 无法签发 cookie：${error.message}`)
    console.error('[dev-proxy] 提示：确认 DSH 已启动过至少一次（~/.dsh/.credentials.yaml 存在）')
    return null
  }
}

function log(...args) {
  if (!options.quiet) console.log('[dev-proxy]', ...args)
}

const server = http.createServer((request, response) => {
  const cookie = cookieHeader()
  if (cookie === null) {
    response.writeHead(500, { 'content-type': 'text/plain; charset=utf-8' })
    response.end('dev-proxy: 无法签发会话 cookie，检查 ~/.dsh/.credentials.yaml')
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
    response.end(`dev-proxy: 连不上 DSH（${targetHost}:${targetPort}）：${error.message}`)
  })

  request.pipe(upstream)
  log(`${request.method} ${request.url}`)
})

// WebSocket 升级：/api/remote.mux 全靠这条。升级后就是裸字节双向拷贝。
server.on('upgrade', (request, clientSocket, head) => {
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

server.listen(options.port, '127.0.0.1', () => {
  console.log(`[dev-proxy] 就绪：http://127.0.0.1:${options.port} → ${options.target}（逐请求注入 cookie）`)
  console.log(`[dev-proxy] 客户端把 baseURL 指到 http://127.0.0.1:${options.port} 即可（DEV-DIRECT）`)
})

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    server.close(() => process.exit(0))
    setTimeout(() => process.exit(0), 500)
  })
}
