/**
 * frp 档位：把本机网关端口映射到一台公网 frps 上。
 *
 * 两种模式，区别只在"谁负责拉进程"：
 * - `managed`：插件自己写 toml、自己 spawn `frpc -c <file>`；
 * - `byo`（bring your own）：用户自己跑隧道，插件只负责把公网 URL 发给手机。
 *
 * 三条踩过的坑写在最前面：
 *
 * 1. **toml 格式按 frp v0.52+ 写，别照抄老博客**。v0.52 起代理段是 `[[proxies]]`，
 *    字段名是 `localIP`（大写 IP）、`localPort`、`remotePort`；token 搬到了 `auth.token`，
 *    老版的顶层 `token = "..."` 已经废弃 —— 写错一个，frpc 只会吐一句
 *    "json: cannot unmarshal..." 或者干脆连不上，很难往"配置格式过时"上想。
 * 2. **frpc 没有可靠的就绪输出**。它启动后会一直安静地跑，连不上 frps 时也照样不退出
 *    （只是反复重试），所以"读一行日志说 ready"这条路走不通。这里的判据只能是
 *    "进程活过了 1.5 秒"，这**不等于**隧道通了 —— status() 里必须如实标注，见 NOTE_UP。
 * 3. **别用 existsSync 判断 frpc 装没装**。跟 lib/detect.js 里 Tailscale 的教训一样，
 *    存在但执行不了的 shim 会让人以为"装了却起不来"。所以复用 detectFrpc()，它会真执行一次。
 */
import { spawn } from 'node:child_process'
import { mkdir, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

import { createRunner, detectFrpc } from '../detect.js'

/**
 * 就绪判据的等待时长（毫秒）。
 *
 * 1500ms 是"足够长到能看见立刻崩溃、又短到不让人干等"的折中：frpc 在参数写错、端口被占、
 * 二进制损坏这几种情况下都是**立刻**退出，不会拖到一秒以后。反过来，1500ms 之后还活着
 * 只说明"没立刻退出"，不代表 frps 连上了、端口映射生效了。
 */
export const FRP_READY_MS = 1500

/** managed 模式写进 stateDir 的文件名。固定名字，重启后覆盖同一份。 */
export const FRPC_TOML_NAME = 'frpc.toml'

/** 进程活下来之后，status() 里那句"别当真"的说明。 */
const NOTE_UP =
  'state=up 只表示 frpc 进程启动后 1.5 秒内没有退出，没有验证过 frps 是否连上、端口映射是否生效'
const NOTE_BYO = 'byo 模式不管理进程；这个地址来自配置，插件没有验证过它可达'

/** 代理名多台机器共用一个 frps 时必须唯一，否则后连上的会把前一台顶掉。 */
export function proxyNameFor(hostId) {
  const id = typeof hostId === 'string' ? hostId.replace(/[^0-9a-zA-Z]/g, '') : ''
  // 一台机器都没给 hostId（测试或首次启动）时用固定后缀，至少保证格式合法。
  return `dsh-${id.slice(0, 8) || 'unknown0'}`
}

/** TOML 基本字符串转义。token 里出现引号/反斜杠是合法的，不能直接拼。 */
function tomlString(value) {
  return `"${String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`
}

function assertPort(value, name) {
  const number = typeof value === 'number' ? value : Number.parseInt(String(value), 10)
  if (!Number.isFinite(number) || !Number.isInteger(number) || number < 1 || number > 65535) {
    throw new TypeError(`${name} 必须是 1-65535 的整数，收到 ${String(value)}`)
  }
  return number
}

/**
 * 生成 frpc 的 toml 配置（frp v0.52+ 格式）。
 *
 * 纯函数：只拼字符串，不碰文件系统 —— 这样测试可以逐字段断言，而不用起进程。
 *
 * @param {object} options
 * @param {string} options.serverAddr frps 地址（必填）
 * @param {number} [options.serverPort=7000] frps 控制端口
 * @param {string} [options.token] 与 frps 约定的 token；为空则**不写** auth 段
 * @param {number} options.localPort 本机网关端口
 * @param {number} options.remotePort frps 上对外暴露的端口
 * @param {string} [options.proxyName] 代理名，默认 dsh-<hostId 前 8 位>
 * @returns {string}
 */
export function generateFrpcToml({
  serverAddr,
  serverPort = 7000,
  token = '',
  localPort,
  remotePort,
  proxyName,
} = {}) {
  const addr = typeof serverAddr === 'string' ? serverAddr.trim() : ''
  if (addr === '') throw new TypeError('serverAddr 不能为空：managed 模式必须知道 frps 在哪')
  const controlPort = assertPort(serverPort, 'serverPort')
  const local = assertPort(localPort, 'localPort')
  const remote = assertPort(remotePort, 'remotePort')
  const name = typeof proxyName === 'string' && proxyName.trim() !== '' ? proxyName.trim() : 'dsh-unknown0'

  const lines = [
    '# 由 dsh-plugin-uplink 自动生成。手改没用：下次 start() 会整份覆盖。',
    `serverAddr = ${tomlString(addr)}`,
    `serverPort = ${controlPort}`,
  ]

  // 空 token 就不写 auth 段：写 `auth.token = ""` 在 frps 配了 token 的情况下会以
  // "token in login doesn't match token from configuration" 失败，而"完全不发 token"
  // 至少能在 frps 没开鉴权时正常工作。宁可少写，不要写个空串装样子。
  const secret = typeof token === 'string' ? token : ''
  if (secret !== '') {
    lines.push('', 'auth.method = "token"', `auth.token = ${tomlString(secret)}`)
  }

  lines.push(
    '',
    '[[proxies]]',
    `name = ${tomlString(name)}`,
    'type = "tcp"',
    // localIP 而不是 localhost：frpc 有时会把 localhost 解析到 ::1，而网关只监听 127.0.0.1。
    'localIP = "127.0.0.1"',
    `localPort = ${local}`,
    `remotePort = ${remote}`,
    '',
  )
  return lines.join('\n')
}

/**
 * 造一个 frp 档位。
 *
 * 生命周期刻意做成"档位对象"而不是一次性函数：start() 可能被反复调用（换网、用户重试、
 * 手机重新配对），stop() 必须在任何状态下都能安全调 —— 幂等是这里唯一的硬要求。
 *
 * @param {object} options
 * @param {object} [options.config] 归一化后的整份配置，或直接是 `tiers.frp` 那一段
 * @param {number} options.gatewayPort 本机网关真实端口（被占用顺延后的那个）
 * @param {string} [options.hostId] 本机标识，用于生成不撞名的 proxyName
 * @param {string} options.stateDir 放 frpc.toml 的目录
 * @param {Function} [options.run] 命令执行器（默认 createRunner()，测试可注入）
 * @param {Function} [options.spawnImpl] 进程启动器（默认 child_process.spawn，测试可注入）
 * @param {{info?: Function, warn?: Function}} [options.logger]
 * @param {string} [options.frpcPath] 显式指定 frpc 路径，跳过探测
 */
export function createFrpTier({
  config,
  gatewayPort,
  hostId = '',
  stateDir,
  run = createRunner(),
  spawnImpl = spawn,
  logger,
  frpcPath = '',
} = {}) {
  // 调用方可能传整份配置（index.js 手上就是它），也可能只传 tiers.frp 那一段。
  // 两种都认，省得调用方为了这个参数再拆一次对象。
  const frp = config?.tiers?.frp ?? config ?? {}
  const mode = frp.mode === 'byo' ? 'byo' : 'managed'
  const localPort = gatewayPort

  let state = 'off'
  let url = ''
  let lastError = null
  let child = null
  let stopping = false
  let stderrTail = ''
  /** spawn 层错误（ENOENT/EACCES）：与"进程跑起来又退出"要分开报，见下面的 reason 分支。 */
  let spawnFailure = null

  /** 公网地址：优先用户填的 publicUrl（可能带路径、可能走反代），否则按 serverAddr:remotePort 拼。 */
  function publicUrlOf() {
    const explicit = typeof frp.publicUrl === 'string' ? frp.publicUrl.trim() : ''
    if (explicit !== '') return explicit
    const addr = typeof frp.serverAddr === 'string' ? frp.serverAddr.trim() : ''
    if (addr === '') return ''
    const scheme = frp.tls === true ? 'https' : 'http'
    return `${scheme}://${addr}:${frp.remotePort}`
  }

  function status() {
    return {
      state,
      // url 只在 start() 成功后才有值（stop() 会清空）：没在跑的时候给出一个地址，
      // 只会让 UI 显示一个点不开的链接。
      url,
      lastError,
      pid: typeof child?.pid === 'number' ? child.pid : null,
      mode,
      // 说明字段：让 UI 有东西可显示，而不是让用户把 state=up 理解成"确认通了"。
      note: state === 'up' ? (mode === 'byo' ? NOTE_BYO : NOTE_UP) : '',
    }
  }

  /** 找 frpc：显式路径优先，否则真执行一次 `frpc --version`（见 detect.js 的教训）。 */
  async function resolveFrpc() {
    if (typeof frpcPath === 'string' && frpcPath.trim() !== '') return frpcPath.trim()
    const detected = await detectFrpc({ run })
    return detected.available ? detected.command : null
  }

  /** 等"活过 ms 毫秒"或"提前退出"，两者谁先到算谁。 */
  function waitForSurvival(proc, ms) {
    return new Promise((resolve) => {
      let settled = false
      const finish = (result) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        resolve(result)
      }
      const timer = setTimeout(() => finish({ alive: true }), ms)
      // 用 once：start() 返回之后进程再退出，由下面那个常驻监听接管状态。
      proc.once?.('exit', (code, signal) => finish({ alive: false, code, signal }))
      proc.once?.('error', (error) => finish({ alive: false, error }))
    })
  }

  async function startManaged() {
    const addr = typeof frp.serverAddr === 'string' ? frp.serverAddr.trim() : ''
    if (addr === '') {
      state = 'down'
      lastError = 'managed 模式需要 tiers.frp.serverAddr（或者改用 byo 模式填 publicUrl）'
      return { ok: false, reason: 'no-server-addr' }
    }
    if (typeof stateDir !== 'string' || stateDir.trim() === '') {
      state = 'down'
      lastError = '缺少 stateDir，没地方放 frpc.toml'
      return { ok: false, reason: 'no-state-dir' }
    }

    const binary = await resolveFrpc()
    if (binary === null) {
      // 明确告诉调用方该换模式还是该装软件 —— 这是最常见的一种"配置看着对但起不来"。
      state = 'down'
      lastError = '没找到可执行的 frpc；装一个，或把 tiers.frp.mode 改成 byo 只填 publicUrl'
      return { ok: false, reason: 'frpc-not-installed' }
    }

    let toml
    try {
      toml = generateFrpcToml({
        serverAddr: addr,
        serverPort: frp.serverPort,
        token: frp.token,
        localPort,
        remotePort: frp.remotePort,
        proxyName: proxyNameFor(hostId),
      })
    } catch (error) {
      state = 'down'
      lastError = `frp 配置不合法：${error?.message ?? error}`
      return { ok: false, reason: 'bad-config' }
    }

    const tomlPath = join(stateDir, FRPC_TOML_NAME)
    try {
      await mkdir(stateDir, { recursive: true })
      // token 明文在里面，0600：同机其他用户不该读得到别人的中转凭据。
      await writeFile(tomlPath, toml, { mode: 0o600 })
    } catch (error) {
      state = 'down'
      lastError = `写 ${tomlPath} 失败：${error?.message ?? error}`
      return { ok: false, reason: 'write-failed' }
    }

    stopping = false
    stderrTail = ''
    spawnFailure = null
    let proc
    try {
      proc = spawnImpl(binary, ['-c', tomlPath], { stdio: ['ignore', 'pipe', 'pipe'] })
    } catch (error) {
      state = 'down'
      lastError = `启动 frpc 失败：${error?.message ?? error}`
      return { ok: false, reason: 'spawn-failed' }
    }

    child = proc
    // 留住 stderr 尾巴：frpc 的失败原因（token 不对、端口被占）只在这里。
    proc.stderr?.on?.('data', (chunk) => {
      stderrTail = (stderrTail + String(chunk)).slice(-2000)
    })
    // 常驻监听：进程在 start() 之后任何时刻退出，状态都得跟着变 —— 否则 UI 会一直显示 up。
    proc.on?.('exit', (code, signal) => {
      if (child === proc) child = null
      if (stopping) return
      state = 'down'
      const reason = signal ? `signal ${signal}` : `code ${code}`
      lastError = `frpc 已退出（${reason}）${stderrTail.trim() === '' ? '' : `：${stderrTail.trim()}`}`
      logger?.warn?.(`[uplink] ${lastError}`)
    })
    proc.on?.('error', (error) => {
      if (stopping) return
      state = 'down'
      // 记下来：spawn 层的错误（ENOENT/EACCES）和"进程跑起来又退出"是两回事，
      // 返回的 reason 要能区分，否则用户会去查 frps 配置而真正的问题是二进制没了。
      spawnFailure = error ?? null
      lastError = `frpc 启动出错：${error?.message ?? error}`
      logger?.warn?.(`[uplink] ${lastError}`)
    })

    const outcome = await waitForSurvival(proc, FRP_READY_MS)
    if (!outcome.alive) {
      // 立刻退出：参数错、端口占、token 不匹配都走这里，stderr 已经在上面记过了。
      state = 'down'
      if (spawnFailure !== null) {
        // ENOENT：探测时还在、spawn 时没了（升级/删除/路径失效）。这仍然是"没装"。
        const reason = spawnFailure?.code === 'ENOENT' ? 'frpc-not-installed' : 'spawn-failed'
        return { ok: false, reason, lastError }
      }
      if (lastError === null) {
        const detail = outcome.error ? String(outcome.error?.message ?? outcome.error) : stderrTail.trim()
        lastError = `frpc 启动后立刻退出${detail === '' ? '' : `：${detail}`}`
      }
      return { ok: false, reason: 'frpc-exited', lastError }
    }

    state = 'up'
    url = publicUrlOf()
    return { ok: true, url }
  }

  async function start() {
    if (mode === 'byo') {
      const target = publicUrlOf()
      if (target === '') {
        state = 'down'
        lastError = 'byo 模式需要 tiers.frp.publicUrl，或者至少填 serverAddr + remotePort'
        return { ok: false, reason: 'no-public-url' }
      }
      // 不拉进程、不探测：隧道是用户的，插件只负责把它写进清单。
      state = 'up'
      url = target
      return { ok: true, url }
    }

    // 已经起过就复用，不重复 spawn（否则每次 /uplink/probe 都会多一个 frpc）。
    if (state === 'up' && child !== null) return { ok: true, url }
    if (state === 'starting') return { ok: false, reason: 'starting' }

    state = 'starting'
    lastError = null
    try {
      return await startManaged()
    } catch (error) {
      // start() 是给路由调用的，绝不能把异常抛回宿主进程。
      state = 'down'
      lastError = `frp 档启动异常：${error?.message ?? error}`
      logger?.warn?.(`[uplink] ${lastError}`)
      return { ok: false, reason: 'start-failed', lastError }
    }
  }

  async function stop() {
    const proc = child
    child = null
    stopping = true
    state = 'off'
    url = ''
    if (proc === null) return // 幂等：没进程、或者已经停过，直接返回

    try {
      if (proc.exitCode === null && proc.killed !== true) proc.kill('SIGTERM')
    } catch {
      // 已经退了
    }
    // frpc 收到 SIGTERM 一般会自己退；万一卡住，两秒后补一刀。unref 让它不拖住事件循环。
    const timer = setTimeout(() => {
      try {
        if (proc.exitCode === null) proc.kill('SIGKILL')
      } catch {
        // 同上
      }
    }, 2000)
    timer.unref?.()
  }

  return { start, stop, status }
}
