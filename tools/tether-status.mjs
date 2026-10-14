#!/usr/bin/env node
// 在命令行查看 dsh-plugin-tether 的**配对码**与**连接状态** —— 一行都不改插件。
//
// 原理：插件自己往 DSH 的 web server 上注册了三个只服务本机的路由，
// 它界面上那个「连接手机」弹窗就是调这几个：
//
//   GET  /dsh-tether/pairing    开一个配对窗口 → {pairingString, expiresInSec}
//   GET  /dsh-tether/devices    已配对手机 + online 状态
//   POST /dsh-tether/devices    撤销一台手机（body {"id": "<64位十六进制>"}）
//
// 它的信任栅栏只挡浏览器（Host 必须是回环、拒 sec-fetch-site: cross-site、
// 带 Origin 时必须同源），**不挡本机进程**：本机请求的 Host 天然就是
// 127.0.0.1:<port>，直接通过，也不需要 DSH 的浏览器会话 cookie。
// 于是桌面端的弹窗出不来时，这里就是一条等价入口。
//
// 用法：
//   node tools/tether-status.mjs                  # 状态：端点 ID + 已配对手机 + 在线情况
//   node tools/tether-status.mjs --pair           # 另开一个配对窗口，打印完整配对串
//   node tools/tether-status.mjs --watch          # 持续轮询，只打印变化
//   node tools/tether-status.mjs --forget <id前缀># 撤销一台手机（前缀需唯一，需确认）
//   node tools/tether-status.mjs --json           # 机器可读
//   node tools/tether-status.mjs --port 19387     # 指定端口（默认 19387，失败时自动扫描本机监听端口）
//
// 注意：--pair **每次调用都会作废上一个码**并开新窗口（10 分钟有效，3 次尝试）。
// 「当前是 P2P 直连还是 relay 中转」只在插件日志里（stdio），本工具拿不到。
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import crypto from 'node:crypto'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { createInterface } from 'node:readline/promises'

const execFileAsync = promisify(execFile)

// ── 输出 ────────────────────────────────────────────────────────────────────
const useColor = Boolean(process.stdout.isTTY) && !process.env.NO_COLOR
const paint = (code) => (text) => (useColor ? `\u001b[${code}m${text}\u001b[0m` : String(text))
const dim = paint('2')
const bold = paint('1')
const red = paint('31')
const green = paint('32')
const cyan = paint('36')

// ── 参数 ────────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const options = { port: undefined, pair: false, watch: false, json: false, forget: undefined, yes: false, intervalMs: 2000, dataDir: undefined }
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i]
    if (token === '--port' || token === '-p') options.port = Number(argv[++i])
    else if (token === '--pair' || token === '--code') options.pair = true
    else if (token === '--watch' || token === '-w') options.watch = true
    else if (token === '--json') options.json = true
    else if (token === '--forget') options.forget = argv[++i]
    else if (token === '--yes' || token === '-y') options.yes = true
    else if (token === '--interval') options.intervalMs = Math.max(250, Number(argv[++i]) || 2000)
    else if (token === '--data-dir') options.dataDir = argv[++i]
    else if (token === '--help' || token === '-h') options.help = true
    else throw new Error(`未知参数：${token}`)
  }
  return options
}

let options
try {
  options = parseArgs(process.argv.slice(2))
} catch (error) {
  console.error(red(`[tether-status] ${error.message}`))
  process.exit(2)
}

if (options.help) {
  console.log(`用法: node tools/tether-status.mjs [--port <n>] [--pair] [--watch] [--forget <id前缀>] [--json]

  (无参数)      打印端点 ID 与已配对手机的在线状态
  --pair        另开一个配对窗口并打印完整配对串（作废上一个码）
  --watch       持续轮询，只在状态变化时打印
  --forget <id> 撤销一台手机（给唯一前缀即可；默认要确认，--yes 跳过）
  --json        机器可读输出
  --data-dir    指定 sidecar 的 data-dir（默认 macOS: ~/Library/Application Support/dsh-tether）`)
  process.exit(0)
}

// ── HTTP ────────────────────────────────────────────────────────────────────
/** 只打本机回环；不设 Origin/cookie，插件的栅栏照过。 */
async function api(port, routePath, { method = 'GET', body, timeoutMs = 8000 } = {}) {
  return fetch(`http://127.0.0.1:${port}${routePath}`, {
    method,
    headers: body === undefined ? undefined : { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
    cache: 'no-store',
    signal: AbortSignal.timeout(timeoutMs),
  })
}

/** 路由存在（200 正常 / 502、504 表示 sidecar 不在或没回话）都算「这台 DSH 装了插件」。 */
async function probePort(port, timeoutMs = 2500) {
  try {
    const res = await api(port, '/dsh-tether/devices', { timeoutMs })
    await res.arrayBuffer().catch(() => {})
    return [200, 502, 504].includes(res.status)
  } catch {
    return false
  }
}

async function listeningPorts() {
  try {
    const { stdout } = await execFileAsync('lsof', ['-nP', '-iTCP', '-sTCP:LISTEN', '-Fpn'], { timeout: 6000 })
    const ports = new Set()
    for (const line of stdout.split('\n')) {
      if (!line.startsWith('n')) continue
      const match = line.match(/:(\d+)\s*$/)
      if (!match) continue
      const port = Number(match[1])
      if (port > 1024 && port < 65536) ports.add(port)
    }
    return [...ports]
  } catch {
    return []
  }
}

async function resolvePort() {
  const explicit = Number.isFinite(options.port) ? options.port : undefined
  const candidates = []
  if (explicit !== undefined) candidates.push(explicit)
  else {
    const fromEnv = Number.parseInt(process.env.DSH_TETHER_PORT ?? '', 10)
    if (Number.isFinite(fromEnv)) candidates.push(fromEnv)
    candidates.push(19387)
  }
  for (const port of candidates) if (await probePort(port)) return port
  if (explicit !== undefined) return undefined
  for (const port of await listeningPorts()) {
    if (candidates.includes(port)) continue
    if (await probePort(port, 600)) return port
  }
  return undefined
}

// ── 本机身份 ────────────────────────────────────────────────────────────────
/** sidecar 不给插件传 --data-dir，用的是 dirs 的平台默认值。 */
function defaultDataDir() {
  if (process.platform === 'darwin') return path.join(os.homedir(), 'Library', 'Application Support', 'dsh-tether')
  if (process.platform === 'win32') return path.join(process.env.APPDATA ?? path.join(os.homedir(), 'AppData', 'Roaming'), 'dsh-tether')
  return path.join(process.env.XDG_DATA_HOME ?? path.join(os.homedir(), '.local', 'share'), 'dsh-tether')
}

/**
 * 端点 ID = identity.key（32 字节 ed25519 私钥）的公钥，**纯读**，不起进程、
 * 不开配对窗口、不碰文件权限。iroh 的 endpoint id 就是这把 ed25519 公钥。
 */
function endpointIdFromIdentity(dataDir) {
  try {
    const raw = fs.readFileSync(path.join(dataDir, 'identity.key'))
    if (raw.length !== 32) return undefined
    const pkcs8 = Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), raw])
    const key = crypto.createPrivateKey({ key: pkcs8, format: 'der', type: 'pkcs8' })
    return crypto.createPublicKey(key).export({ format: 'der', type: 'spki' }).subarray(-32).toString('hex')
  } catch {
    return undefined
  }
}

// ── 呈现 ────────────────────────────────────────────────────────────────────
const dot = (online) => (online ? green('●') : dim('○'))

function formatWhen(stamp) {
  const match = /^unix:(\d+)$/.exec(String(stamp ?? ''))
  if (!match) return ''
  return new Date(Number(match[1]) * 1000).toLocaleString('zh-CN', { hour12: false })
}

const hhmmss = () => new Date().toLocaleTimeString('zh-CN', { hour12: false })

/** 读一次状态；返回 {sidecar, devices, note} 或抛错。 */
async function readStatus(port) {
  const res = await api(port, '/dsh-tether/devices')
  const text = await res.text()
  if (res.status === 502) return { sidecar: text.trim() || 'sidecar 不在', devices: [] }
  if (res.status === 504) return { sidecar: 'sidecar 没在 5 秒内回话', devices: [] }
  if (res.status !== 200) throw new Error(`设备列表返回 HTTP ${res.status}: ${text.slice(0, 200)}`)
  return { sidecar: 'online', devices: JSON.parse(text).devices ?? [] }
}

function printStatus(port, status, { withHeader = true } = {}) {
  const alive = status.sidecar === 'online'
  if (withHeader) {
    console.log(`${bold('dsh-tether')} ${dim('·')} ${cyan(`http://127.0.0.1:${port}`)}`)
    console.log(`${dim('sidecar   ')} ${alive ? green('在线') : red(`不在：${status.sidecar}`)}`)
  }
  if (!alive) return
  const endpointId = endpointIdFromIdentity(options.dataDir ?? defaultDataDir())
  if (endpointId !== undefined) {
    console.log(`${dim('设备 ID   ')} ${endpointId}`)
    console.log(`${dim('          ')} ${dim('配对串 = 设备 ID + “#” + 6 位码（--pair 生成）')}`)
  } else {
    console.log(`${dim('设备 ID   ')} ${dim('读不到 identity.key（用 --data-dir 指定）')}`)
  }
  const devices = status.devices
  console.log(`${dim('已配对手机')} ${devices.length === 0 ? dim('（还没有）') : `(${devices.length})`}`)
  for (const device of devices) {
    const when = formatWhen(device.paired_at)
    console.log(`  ${dot(Boolean(device.online))} ${device.online ? '在线' : '离线'}  ${String(device.name ?? '?').padEnd(12)} ${dim(String(device.id).slice(0, 8))}${when ? dim(`  ${when} 配对`) : ''}`)
  }
  const online = devices.filter((d) => d.online).length
  console.log(dim(`  ── ${online} 台在线 / ${devices.length} 台已配对`))
}

async function withPort() {
  const port = await resolvePort()
  if (port === undefined) {
    console.error(red('[tether-status] 没找到装了 dsh-plugin-tether 的 DSH web server。'))
    console.error(dim('  确认 DSH 桌面端在跑；或显式指定端口：--port <n>'))
    process.exit(1)
  }
  return port
}

// ── 子命令 ──────────────────────────────────────────────────────────────────
async function doPair(port) {
  const res = await api(port, '/dsh-tether/pairing', { timeoutMs: 8000 })
  const text = await res.text()
  if (res.status !== 200) {
    if (res.status === 502 || res.status === 504) {
      console.error(red(`[tether-status] sidecar 不可用：${text.trim()}`))
      process.exit(1)
    }
    console.error(red(`[tether-status] 配对路由返回 HTTP ${res.status}: ${text.slice(0, 200)}`))
    process.exit(1)
  }
  const { pairingString, expiresInSec } = JSON.parse(text)
  const expiresAt = new Date(Date.now() + expiresInSec * 1000).toLocaleTimeString('zh-CN', { hour12: false })
  if (options.json) {
    console.log(JSON.stringify({ endpointId: pairingString.split('#')[0], pairingString, expiresInSec, expiresAt, baseUrl: `http://127.0.0.1:${port}` }, null, 2))
    return
  }
  const status = await readStatus(port).catch(() => undefined)
  if (status) {
    printStatus(port, status)
  } else {
    console.log(`${bold('dsh-tether')} ${dim('·')} ${cyan(`http://127.0.0.1:${port}`)}`)
  }
  console.log()
  console.log(`${bold('配对窗口已打开')} ${dim(`（${Math.round(expiresInSec / 60)} 分钟有效，到 ${expiresAt}；本次调用已作废上一个码）`)}`)
  console.log()
  console.log(`  ${bold(cyan(pairingString))}`)
  console.log()
  console.log(dim('  在手机 App「添加电脑」里整行粘贴即可。'))
}

async function doForget(port, rawPrefix) {
  const prefix = String(rawPrefix ?? '').trim().toLowerCase()
  if (!/^[0-9a-f]{6,64}$/.test(prefix)) {
    console.error(red('[tether-status] --forget 需要设备 id 的十六进制前缀（至少 6 位）'))
    process.exit(2)
  }
  const status = await readStatus(port)
  if (status.sidecar !== 'online') {
    console.error(red(`[tether-status] sidecar 不可用：${status.sidecar}`))
    process.exit(1)
  }
  const matches = status.devices.filter((d) => String(d.id).toLowerCase().startsWith(prefix))
  if (matches.length === 0) {
    console.error(red(`[tether-status] 没有 id 以 ${prefix} 开头的已配对手机。当前：`))
    for (const d of status.devices) console.error(`  ${d.name}  ${d.id}`)
    process.exit(1)
  }
  if (matches.length > 1) {
    console.error(red(`[tether-status] 前缀 ${prefix} 命中 ${matches.length} 台，请给更长的前缀：`))
    for (const d of matches) console.error(`  ${d.name}  ${d.id}`)
    process.exit(1)
  }
  const target = matches[0]
  if (!options.yes) {
    if (!process.stdin.isTTY) {
      console.error(red('[tether-status] 非交互环境请加 --yes 确认撤销。'))
      process.exit(2)
    }
    const ask = createInterface({ input: process.stdin, output: process.stdout })
    const answer = await ask.question(`撤销 ${target.name}（${target.id.slice(0, 8)}）？它需要重新配对 [y/N] `)
    ask.close()
    if (!/^y(es)?$/i.test(answer.trim())) {
      console.log(dim('已取消。'))
      return
    }
  }
  const res = await api(port, '/dsh-tether/devices', { method: 'POST', body: { id: target.id } })
  const text = await res.text()
  if (res.status !== 200) {
    console.error(red(`[tether-status] 撤销失败 HTTP ${res.status}: ${text.slice(0, 200)}`))
    process.exit(1)
  }
  console.log(`${green('已撤销')} ${target.name} ${dim(target.id.slice(0, 8))}`)
  const after = JSON.parse(text).devices ?? []
  console.log(dim(`  剩余 ${after.length} 台：${after.map((d) => d.name).join('、') || '无'}`))
}

async function doWatch(port) {
  console.log(`${bold('dsh-tether')} ${dim('·')} ${cyan(`http://127.0.0.1:${port}`)} ${dim(`每 ${options.intervalMs}ms 轮询，Ctrl-C 退出`)}`)
  const seen = new Map()
  let lastSidecar
  for (;;) {
    let status
    try {
      status = await readStatus(port)
    } catch (error) {
      console.log(`${dim(hhmmss())} ${red(`读取失败：${error.message}`)}`)
      await new Promise((r) => setTimeout(r, options.intervalMs))
      continue
    }
    if (status.sidecar !== lastSidecar) {
      console.log(`${dim(hhmmss())} sidecar ${status.sidecar === 'online' ? green('在线') : red(`不在：${status.sidecar}`)}`)
      lastSidecar = status.sidecar
    }
    if (status.sidecar === 'online') {
      for (const device of status.devices) {
        const key = device.id
        const was = seen.get(key)
        if (was === undefined) {
          console.log(`${dim(hhmmss())} ${dot(device.online)} ${device.name} ${dim('已配对')}${device.online ? ` ${green('在线')}` : ''}`)
        } else if (was !== Boolean(device.online)) {
          console.log(`${dim(hhmmss())} ${device.online ? green(`▲ ${device.name} 上线`) : dim(`▼ ${device.name} 离线`)}`)
        }
        seen.set(key, Boolean(device.online))
      }
      const ids = new Set(status.devices.map((d) => d.id))
      for (const [id, online] of [...seen]) {
        if (ids.has(id)) continue
        console.log(`${dim(hhmmss())} ${dim(`- 设备已被移除（${id.slice(0, 8)}${online ? '，当时在线' : ''}）`)}`)
        seen.delete(id)
      }
    }
    await new Promise((r) => setTimeout(r, options.intervalMs))
  }
}

// ── main ────────────────────────────────────────────────────────────────────
const port = await withPort()

if (options.watch) await doWatch(port)
else if (options.forget !== undefined) await doForget(port, options.forget)
else if (options.pair) await doPair(port)
else {
  const status = await readStatus(port)
  if (options.json) {
    console.log(JSON.stringify({
      baseUrl: `http://127.0.0.1:${port}`,
      sidecar: status.sidecar,
      endpointId: endpointIdFromIdentity(options.dataDir ?? defaultDataDir()),
      dataDir: options.dataDir ?? defaultDataDir(),
      devices: status.devices,
    }, null, 2))
  } else {
    printStatus(port, status)
  }
}
