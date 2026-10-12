#!/usr/bin/env node
// 在**不启动 DSH 桌面端**的情况下，把电脑侧的 tether sidecar 跑起来。
//
// 为什么需要它：sidecar 本身不认识 DSH 的 cookie。真实部署里是
// `dsh-plugin-tether` 兑换出 cookie 后通过 stdin 的 `{"type":"proxy-auth",…}` 交给它；
// 这里由本工具扮演那个角色 —— 于是可以在命令行上复现完整的电脑端，
// 用来跑 M0b spike 与传输层回归，不需要开着桌面 App、更不需要手机。
//
//   node tools/tether-host-dev.mjs                       # 用已安装的 sidecar 二进制
//   node tools/tether-host-dev.mjs --binary <path> --data-dir /tmp/tether --pair
//
// 输出：
//   {"type":"ready","endpoint_id":"…"}     ← 端点 ID（配对串前半段）
//   {"type":"pairing","code":"123456",…}   ← 配对码（开了 --pair）
// 之后 sidecar 的日志走 stderr，直接透传。
//
// ⚠️ **data-dir 就是这台电脑的身份**（`identity.key` 在里面）。清掉它 = 换一台
// 新电脑，所有已配对的手机都要重新配对，而且端点 ID 会变。所以：
//   · 不要 `rm -rf` 这个目录；
//   · 想再开一个配对窗口，**不要重启进程**，发个信号就行：
//         kill -USR1 <本进程 pid>
//     它会通过 stdin 给 sidecar 发 `{"type":"pairing-begin"}`，开一个新窗口。
import { createRequire } from 'node:module'
import { spawn } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'

const require = createRequire(import.meta.url)
const { cookieFor } = require('./mint-cookie.cjs')

const DEFAULT_BINARY = `${process.env.HOME}/.dsh/profiles/desktop/node_modules/dsh-tether-host-darwin-arm64/bin/tether-host`

function parseArgs(argv) {
  const options = {
    binary: process.env.TETHER_HOST_BIN || DEFAULT_BINARY,
    dataDir: '/tmp/dsh-pocket-tether-host',
    proxyTarget: '127.0.0.1:19387',
    pair: false,
    json: false,
  }
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index]
    if (token === '--binary') options.binary = argv[++index]
    else if (token === '--data-dir') options.dataDir = argv[++index]
    else if (token === '--proxy-target') options.proxyTarget = argv[++index]
    else if (token === '--pair') options.pair = true
    else if (token === '--json') options.json = true
    else if (token === '--help' || token === '-h') options.help = true
  }
  return options
}

const options = parseArgs(process.argv.slice(2))

if (options.help) {
  console.log(`用法: node tools/tether-host-dev.mjs [--binary <path>] [--data-dir <dir>]
                                   [--proxy-target 127.0.0.1:19387] [--pair] [--json]

--pair  启动即开配对窗口（默认只在白名单为空时自动开）
--json  第一行输出一个机器可读的 JSON 摘要（便于脚本消费）

再开一个配对窗口（不重启、不换身份）：
  kill -USR1 <本进程 pid>`)
  process.exit(0)
}

if (!fs.existsSync(options.binary)) {
  console.error(`[tether-dev] 找不到 sidecar 二进制：${options.binary}`)
  console.error('[tether-dev] 用 --binary 指定，或先安装 dsh-plugin-tether')
  process.exit(1)
}

fs.mkdirSync(options.dataDir, { recursive: true })

const identityPath = path.join(options.dataDir, 'identity.key')
const hadIdentity = fs.existsSync(identityPath)
if (!hadIdentity) {
  console.log(`[tether-dev] ${options.dataDir} 里没有 identity.key —— 会新建一把主机身份。`)
  console.log('[tether-dev] 之后请**保留这个目录**：它是这台电脑的身份，删掉等于换一台新电脑。')
}

const args = [
  'host',
  '--data-dir', options.dataDir,
  '--proxy-target', options.proxyTarget,
]
if (options.pair) args.push('--pair')

const child = spawn(options.binary, args, { stdio: ['pipe', 'pipe', 'inherit'] })

let cookiePushed = false
let readyEndpointId = null

function pushProxyAuth() {
  try {
    const cookie = cookieFor(options.proxyTarget)
    child.stdin.write(`${JSON.stringify({ type: 'proxy-auth', cookie, authority: options.proxyTarget })}\n`)
    cookiePushed = true
    console.log(`[tether-dev] 已把浏览器认证 cookie 交给 sidecar（authority=${options.proxyTarget}）`)
  } catch (error) {
    console.error(`[tether-dev] 无法签发 cookie：${error.message}`)
    console.error('[tether-dev] 代理流会返回 401。确认 DSH 至少启动过一次（~/.dsh/.credentials.yaml 存在）')
  }
}

// DSH 的浏览器 cookie 有绝对有效期（默认 30 天），但 DSH 进程重启会换密钥，
// 所以定期重签一次 —— 与真实插件的行为一致。
const cookieRefresh = setInterval(pushProxyAuth, 6 * 60 * 60 * 1000)

/// 按需开一个新的配对窗口。
///
/// 走的是插件真正用的那条路：往 sidecar 的 stdin 发 `pairing-begin`
/// （见 `host/src/main.rs` 的 `PluginIn::PairingBegin`）。
/// 这样就不需要为了重开窗口而重启进程 —— 重启会带着新的身份，把已配对的手机全废掉。
function openPairingWindow(reason) {
  if (!cookiePushed) {
    console.error('[tether-dev] sidecar 还没就绪，稍后再试')
    return
  }
  child.stdin.write(`${JSON.stringify({ type: 'pairing-begin' })}\n`)
  console.log(`[tether-dev] 已请求新的配对窗口（${reason}）`)
}

process.on('SIGUSR1', () => openPairingWindow('收到 SIGUSR1'))

let buffered = ''
child.stdout.on('data', (chunk) => {
  buffered += chunk.toString('utf8')
  let index
  while ((index = buffered.indexOf('\n')) !== -1) {
    const line = buffered.slice(0, index).trim()
    buffered = buffered.slice(index + 1)
    if (!line) continue
    let message = null
    try { message = JSON.parse(line) } catch { /* 非 JSON 行原样打印 */ }

    if (message?.type === 'ready') {
      readyEndpointId = message.endpoint_id
      console.log(line)
      console.log(`[tether-dev] 端点 ID：${message.endpoint_id}`)
      pushProxyAuth()
      console.log(`[tether-dev] 主机身份已就绪（稳定）：${message.endpoint_id}`)
      console.log(`[tether-dev] 想再开一个配对窗口：kill -USR1 ${process.pid}`)
      continue
    }
    if (message?.type === 'pairing') {
      console.log(line)
      console.log(`[tether-dev] 配对串（${Math.round(message.expires_in_sec / 60)} 分钟内有效）：${readyEndpointId}#${message.code}`)
      console.log(`[tether-dev] 重新开窗口不用重启：kill -USR1 ${process.pid}`)
      if (options.json) {
        console.log(JSON.stringify({ endpointId: readyEndpointId, code: message.code, dataDir: options.dataDir }))
      }
      console.log(`[tether-dev] 完整配对串：${readyEndpointId}#${message.code}`)
      continue
    }
    console.log(line)
  }
})

child.on('exit', (code, signal) => {
  clearInterval(cookieRefresh)
  console.error(`[tether-dev] sidecar 退出 code=${code} signal=${signal}`)
  process.exit(code ?? 0)
})

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    clearInterval(cookieRefresh)
    child.kill(signal)
  })
}

process.on('exit', () => {
  if (!cookiePushed) console.error('[tether-dev] 注意：cookie 从未成功推送，代理流会 401')
})
