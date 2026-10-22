/**
 * 网络环境探测。
 *
 * 目标：**用户不需要填任何 IP**。电脑最清楚自己有哪些地址，插件算好、随清单发给手机。
 *
 * 两条实测教训写在这里，改代码前先读：
 *
 * 1. **只 `existsSync` 会误判**。开发机上 `/usr/local/bin/tailscale` 存在，但它是个
 *    `exec /Applications/Tailscale.app/...` 的 shim，而那个 App 已经被删了 —— 直接执行报
 *    `cannot execute`。所以探测一律**执行命令并解析输出**，文件存在与否不作为判据。
 * 2. **接口名优先于网段**。ZeroTier 允许把网段改成 10/8，只看网段会把 ZT 误判成 LAN，
 *    进而把一个"只有装了 ZeroTier 的手机才可达"的地址当成局域网地址广播出去。
 */
import { createHash } from 'node:crypto'
import { networkInterfaces } from 'node:os'
import { spawn } from 'node:child_process'

/**
 * 各类虚拟网卡的命名。macOS 上 ZeroTier 是 `feth*`，Linux 是 `zt` + 一串随机字母
 * （例如 `ztks5wvlq`）—— 所以后缀要允许字母，不能只认数字。
 */
const ZEROTIER_IFACE = /^(zt|feth)[a-z0-9]*$/i
const TAILSCALE_IFACE = /^tailscale\d*$/i
const TUNNEL_IFACE = /^(utun|tun|tap|wg)\d*$/i

/** 100.64.0.0/10（CGNAT）—— Tailscale 的默认网段。 */
function inCgnat(octets) {
  return octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127
}

function inPrivate(octets) {
  if (octets[0] === 10) return true
  if (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) return true
  if (octets[0] === 192 && octets[1] === 168) return true
  return false
}

function parseIPv4(address) {
  if (typeof address !== 'string') return null
  const parts = address.split('.')
  if (parts.length !== 4) return null
  const octets = []
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) return null
    const value = Number(part)
    if (value > 255) return null
    octets.push(value)
  }
  return octets
}

/** Node 18 给 `family: 4`，20+ 给 `'IPv4'`；两种都得认。 */
function isIPv4(entry) {
  return entry.family === 'IPv4' || entry.family === 4
}

/**
 * 把一条网卡地址归类。
 *
 * @returns {'lan'|'tailscale'|'zerotier'|'tunnel'|'wan'|null} null 表示不该出现在清单里
 */
export function classifyInterface(iface, address) {
  const octets = parseIPv4(address)
  if (octets === null) return null
  // 回环、未配置、链路本地自分配：都不是"手机能打到的地址"
  if (octets[0] === 127 || (octets[0] === 0 && octets[1] === 0)) return null
  if (octets[0] === 169 && octets[1] === 254) return null

  if (ZEROTIER_IFACE.test(iface)) return 'zerotier'
  if (TAILSCALE_IFACE.test(iface)) return 'tailscale'
  // macOS 的 utun 可能是 Tailscale、WireGuard、iCloud Private Relay 或 Docker，
  // 无法只靠名字区分 —— 先按隧道处理（不默认广播），由命令探测再确认。
  if (inCgnat(octets) && TUNNEL_IFACE.test(iface)) return 'tailscale'
  if (TUNNEL_IFACE.test(iface)) return 'tunnel'
  if (inPrivate(octets)) return 'lan'
  return 'wan'
}

/**
 * 枚举本机所有可候选地址。
 *
 * @param {object} [interfaces] 便于测试注入（默认读 `os.networkInterfaces()`）
 */
export function collectCandidates(interfaces = networkInterfaces()) {
  const out = []
  for (const [iface, entries] of Object.entries(interfaces ?? {})) {
    for (const entry of entries ?? []) {
      if (!isIPv4(entry)) continue
      const kind = classifyInterface(iface, entry.address)
      if (kind === null) continue
      out.push({ kind, iface, address: entry.address })
    }
  }
  // 稳定顺序：先按类别优先级，再按接口名 —— 同一台机器每次算出来的清单必须一致，
  // 否则手机侧"上次成功的那档"会莫名其妙地漂移。
  const order = { lan: 0, tailscale: 1, zerotier: 2, tunnel: 3, wan: 4 }
  out.sort((a, b) => (order[a.kind] - order[b.kind]) || a.iface.localeCompare(b.iface))
  return out
}

/**
 * 跑一条命令并拿回 stdout；超时或非零退出都当作"失败"，不抛。
 *
 * 默认实现用 `spawn` 而不是 `exec`：这里不拼 shell 字符串，避免路径里的空格与注入。
 */
export function createRunner({ timeoutMs = 800, spawnImpl = spawn } = {}) {
  return function run(command, args = []) {
    return new Promise((resolve) => {
      let settled = false
      const done = (result) => {
        if (settled) return
        settled = true
        resolve(result)
      }
      let child
      try {
        child = spawnImpl(command, args, { stdio: ['ignore', 'pipe', 'pipe'] })
      } catch (error) {
        done({ ok: false, code: null, stdout: '', stderr: String(error?.message ?? error) })
        return
      }
      let stdout = ''
      let stderr = ''
      const timer = setTimeout(() => {
        try {
          child.kill('SIGKILL')
        } catch {
          // 已经退了就算了
        }
        done({ ok: false, code: null, stdout, stderr: `timeout after ${timeoutMs}ms` })
      }, timeoutMs)
      child.stdout?.on('data', (chunk) => { stdout += chunk })
      child.stderr?.on('data', (chunk) => { stderr += chunk })
      child.on('error', (error) => {
        clearTimeout(timer)
        done({ ok: false, code: null, stdout, stderr: String(error?.message ?? error) })
      })
      child.on('close', (code) => {
        clearTimeout(timer)
        done({ ok: code === 0, code, stdout, stderr })
      })
    })
  }
}

/** Tailscale CLI 的候选路径，按"最可能是真的"排序。 */
export const TAILSCALE_CANDIDATES = [
  'tailscale',
  '/Applications/Tailscale.app/Contents/MacOS/Tailscale',
  '/usr/local/bin/tailscale',
  '/opt/homebrew/bin/tailscale',
]

export const ZEROTIER_CANDIDATES = [
  'zerotier-cli',
  '/usr/local/bin/zerotier-cli',
  '/opt/homebrew/bin/zerotier-cli',
  '/Library/Application Support/ZeroTier/One/zerotier-cli',
]

export const FRPC_CANDIDATES = [
  'frpc',
  '/usr/local/bin/frpc',
  '/opt/homebrew/bin/frpc',
]

/**
 * 找一个能真正跑起来的 CLI。
 *
 * 注意：**逐个执行**，不是逐个 `existsSync`。坏掉的 shim 会在这里被自然淘汰。
 */
async function firstWorking(run, candidates, args) {
  const tried = []
  for (const command of candidates) {
    const result = await run(command, args)
    if (result.ok) return { command, result, tried }
    tried.push({ command, stderr: (result.stderr || '').trim().slice(0, 200) })
  }
  return { command: null, result: null, tried }
}

/**
 * 探测 Tailscale。
 *
 * `BackendState` 是判断"能不能用"的关键：装了但没登录（`NeedsLogin`）、
 * 或者客户端没起来（`Stopped`），地址可能还在，但流量根本走不通。
 */
export async function detectTailscale({ run, candidates = TAILSCALE_CANDIDATES } = {}) {
  const { command, result } = await firstWorking(run, candidates, ['status', '--json'])
  if (command === null) return { available: false, addresses: [], reason: 'not-installed' }
  let parsed
  try {
    parsed = JSON.parse(result.stdout)
  } catch {
    return { available: false, addresses: [], reason: 'bad-output' }
  }
  const backendState = typeof parsed?.BackendState === 'string' ? parsed.BackendState : 'unknown'
  const ips = Array.isArray(parsed?.Self?.TailscaleIPs) ? parsed.Self.TailscaleIPs : []
  const addresses = ips.filter((ip) => parseIPv4(ip) !== null)
  if (backendState !== 'Running') {
    return { available: false, addresses, backendState, reason: `state:${backendState}` }
  }
  if (addresses.length === 0) return { available: false, addresses, backendState, reason: 'no-address' }
  return {
    available: true,
    addresses,
    backendState,
    hostName: typeof parsed?.Self?.HostName === 'string' ? parsed.Self.HostName : '',
    command,
  }
}

/**
 * 探测 ZeroTier。
 *
 * `status: "OK"` 才是真正加入并拿到地址的网络；`REQUESTING_CONFIGURATION` 之类
 * 说明控制器还没下发地址，这时候广播出去只会让手机白等。
 */
export async function detectZeroTier({ run, candidates = ZEROTIER_CANDIDATES } = {}) {
  const { command, result } = await firstWorking(run, candidates, ['-j', 'listnetworks'])
  if (command === null) return { available: false, addresses: [], reason: 'not-installed' }
  let parsed
  try {
    parsed = JSON.parse(result.stdout)
  } catch {
    return { available: false, addresses: [], reason: 'bad-output' }
  }
  const networks = Array.isArray(parsed) ? parsed : []
  const addresses = []
  const pending = []
  for (const network of networks) {
    const list = Array.isArray(network?.assignedAddresses) ? network.assignedAddresses : []
    const ipv4 = list.map((item) => String(item).split('/')[0]).filter((ip) => parseIPv4(ip) !== null)
    if (network?.status === 'OK') addresses.push(...ipv4)
    else if (ipv4.length > 0) pending.push({ status: network?.status ?? 'unknown', addresses: ipv4 })
  }
  if (addresses.length === 0) {
    return {
      available: false,
      addresses: [],
      reason: pending.length > 0 ? `state:${pending[0].status}` : 'no-network',
      command,
    }
  }
  return { available: true, addresses, command }
}

/** 托管模式要用 frpc；没装就明确告诉用户"改成 byo 模式，或者装一下"。 */
export async function detectFrpc({ run, candidates = FRPC_CANDIDATES } = {}) {
  const { command } = await firstWorking(run, candidates, ['--version'])
  return command === null ? { available: false, reason: 'not-installed' } : { available: true, command }
}

/** 默认路由走哪张网卡 —— 用来判断"是不是换网了"。 */
export async function detectDefaultInterface({ run } = {}) {
  const result = await run('route', ['-n', 'get', 'default'])
  if (!result.ok) return ''
  const match = /interface:\s*(\S+)/.exec(result.stdout)
  return match === null ? '' : match[1]
}

/** macOS 当前 Wi-Fi 名（拿不到就空串，不报错）。 */
export async function detectSsid({ run, iface = 'en0' } = {}) {
  const result = await run('networksetup', ['-getairportnetwork', iface])
  if (!result.ok) return ''
  const match = /Current Wi-Fi Network:\s*(.+)$/m.exec(result.stdout)
  return match === null ? '' : match[1].trim()
}

/**
 * 网络指纹：换网了没有？
 *
 * 指纹变了意味着"上次成功的那档很可能已经不成立"——必须清空粘滞、立刻重新探测。
 * 只用地址与接口名，不用时间，保证同一网络下每次算出来一样。
 */
export function fingerprint({ candidates = [], ssid = '', defaultInterface = '' } = {}) {
  const addresses = candidates
    .map((item) => `${item.kind}:${item.address}`)
    .sort()
    .join(',')
  return createHash('sha256')
    .update(`${addresses}|${ssid}|${defaultInterface}`)
    .digest('hex')
    .slice(0, 16)
}

/**
 * 一次性把环境探清楚。结果缓存 30 秒（见 index.js）—— 探测要 fork 三四个进程，
 * 不能每次请求都跑。
 */
export async function detectEnvironment({ run, candidates, ssid = true } = {}) {
  const [tailscale, zerotier, defaultInterface] = await Promise.all([
    detectTailscale({ run }),
    detectZeroTier({ run }),
    detectDefaultInterface({ run }),
  ])
  const ssidValue = ssid ? await detectSsid({ run, iface: defaultInterface || 'en0' }) : ''
  const list = candidates ?? collectCandidates()
  return {
    candidates: list,
    tailscale,
    zerotier,
    defaultInterface,
    ssid: ssidValue,
    fingerprint: fingerprint({ candidates: list, ssid: ssidValue, defaultInterface }),
  }
}
