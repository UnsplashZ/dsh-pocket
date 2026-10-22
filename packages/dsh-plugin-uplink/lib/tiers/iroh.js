/**
 * iroh 档位：把已安装的 tether sidecar 当成"能穿 NAT 的反向代理"。
 *
 * 为什么单独一档：局域网 / Tailscale / ZeroTier 都需要两端在**同一个**可路由网络里，
 * 自建 frp 又需要一台公网服务器。iroh 是唯一"什么都不用准备"的兜底 —— 两端各自
 * 连上公共 relay 打洞，打不通就退回 relay 中转。
 *
 * 边界（很重要，别把这个文件写胖）：
 *   · 这里**不实现**配对协议本身。配对是手机侧的事，电脑侧只负责把
 *     `endpointId#code` 这种"一行可粘贴"的串交给调用方（二维码 / 手输都行）。
 *   · 这里也**不碰**网关（lib/gateway.js）。sidecar 自己把代理流打到
 *     `--proxy-target`，鉴权仍由网关的票据体系负责，两条路互不知情。
 *   · 只依赖 node 内置模块：本包零第三方依赖是硬约束。
 *
 * sidecar 的 stdout 是 JSON-lines 控制流，字段名是 Rust serde 的下划线风格
 * （`endpoint_id`、`expires_in_sec`）。读的时候不要"顺手"改成 camelCase —— 那是
 * 拿不到值的，而且不会报错，只会静默变成空串。
 */
import { spawn as nodeSpawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { createInterface } from 'node:readline'
import { fileURLToPath } from 'node:url'

/** 本文件在 lib/tiers/ 下，包根要往上退两级（cargo 产物与平台子包都按包根算）。 */
const PACKAGE_ROOT = dirname(dirname(dirname(fileURLToPath(import.meta.url))))

/**
 * 默认启动超时。
 *
 * 8 秒是给"第一次跑、要建 endpoint 并连 relay"留的余量；但它必须是**参数**而不是
 * 写死的常量 —— 测试里设 60ms，否则单测光等超时就要跑 8 秒。
 */
export const DEFAULT_READY_TIMEOUT_MS = 8_000
/** 要配对码的等待上限。sidecar 正常是毫秒级回，5 秒纯粹是防"卡死"。 */
export const DEFAULT_PAIRING_TIMEOUT_MS = 5_000
/** 等子进程退出的兜底。超过就 SIGKILL 并放弃等待，绝不把宿主挂在这里。 */
export const DEFAULT_STOP_TIMEOUT_MS = 2_000

const hostExecutableName = (platform) => (platform === 'win32' ? 'tether-host.exe' : 'tether-host')

/**
 * 找 sidecar 二进制。**只看本包自己**，不向任何外部包伸手。
 *
 * 这是刻意的：本插件是"完全独立构建"的 —— 不声明 peerDependencies、不解析别人的
 * node_modules、也不假设隔壁装了哪个插件。所以二进制只有两个来路：
 *
 *   1. 随本包发布的 `bin/<platform>-<arch>/tether-host`（自包含发布的落点）；
 *   2. 包内 `target/release|debug/tether-host` —— 本地 cargo build 的开发路径，
 *      release 优先（debug 版慢一个数量级，只适合调 sidecar 本身）。
 *
 * 都不在就返回 undefined：这一档不可用而已，**不要**抛 —— 兜底档位缺失是正常状态，
 * 其余档位照常工作。要临时指一个外部的 sidecar，用配置项 `tiers.iroh.binaryPath`，
 * 那是用户显式选择，不是插件的隐式依赖。
 *
 * @param {{packageRoot?: string, platform?: string, arch?: string}} [options]
 * @returns {string | undefined}
 */
export function resolveHostBinary({
  packageRoot = PACKAGE_ROOT,
  platform = process.platform,
  arch = process.arch,
} = {}) {
  const exe = hostExecutableName(platform)
  const candidates = [
    // 自包含发布的落点：一个包，一个二进制，没有任何外部包依赖
    join(packageRoot, 'bin', `${platform}-${arch}`, exe),
    join(packageRoot, 'bin', exe),
    join(packageRoot, 'target', 'release', exe),
    join(packageRoot, 'target', 'debug', exe),
  ]
  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate
  }
  return undefined
}

/**
 * 创建一个 iroh 档位句柄。构造阶段**不**碰文件系统、不 spawn —— 只有 start() 才动。
 *
 * @param {object} options
 * @param {string} [options.binaryPath] 显式指定 sidecar；省略则 start() 时调 resolveHostBinary()
 * @param {string} options.proxyTarget sidecar 要代理到的地址 `host:port`（IPv6 必须带方括号）
 * @param {string} [options.dataDir] sidecar 的数据目录（endpoint 身份、已配对设备）
 * @param {'zh'|'en'} [options.lang] sidecar 人读日志的语言，跟宿主终端保持一致
 * @param {{info?: Function, warn?: Function}} [options.logger]
 * @param {typeof nodeSpawn} [options.spawnImpl] 可注入，测试用假 child 代替真进程
 * @param {number} [options.readyTimeoutMs]
 * @param {number} [options.pairingTimeoutMs]
 * @param {number} [options.stopTimeoutMs]
 */
export function createIrohTier({
  binaryPath,
  proxyTarget,
  dataDir,
  lang = 'zh',
  logger,
  spawnImpl,
  readyTimeoutMs = DEFAULT_READY_TIMEOUT_MS,
  pairingTimeoutMs = DEFAULT_PAIRING_TIMEOUT_MS,
  stopTimeoutMs = DEFAULT_STOP_TIMEOUT_MS,
} = {}) {
  const warn = (message) => logger?.warn?.(`[uplink] ${message}`)
  const info = (message) => logger?.info?.(`[uplink] ${message}`)

  /** @type {import('node:child_process').ChildProcess | null} */
  let child = null
  /** @type {import('node:readline').Interface | null} */
  let stdoutReader = null
  let stderrReader = null
  let running = false
  /** 已就绪的 endpoint id；空串 = 还没 ready */
  let endpointId = ''
  /** relay 地址，可能没有（sidecar 版本差异），只用于诊断展示 */
  let relay = null
  /** 最近一次失败/退出的原因，status() 原样暴露给上层做诊断 */
  let lastError = null
  /** 并发 start() 共用同一次拉起，避免起两个 sidecar 抢同一个 data-dir */
  let starting = null
  /** 并发 stop() 共用同一次收尸 */
  let stopping = null
  /** 正在主动停止：exit 事件这时是"预期内"的，不该报成错误 */
  let stoppingNow = false
  /** @type {{resolve: Function, timer: NodeJS.Timeout} | null} */
  let readyWaiter = null
  /** @type {{resolve: Function, timer: NodeJS.Timeout} | null} */
  let pendingPairing = null

  function settleReady(result) {
    const waiter = readyWaiter
    readyWaiter = null
    if (!waiter) return
    clearTimeout(waiter.timer)
    waiter.resolve(result)
  }

  function settlePairing(result) {
    const waiter = pendingPairing
    pendingPairing = null
    if (!waiter) return false
    clearTimeout(waiter.timer)
    waiter.resolve(result)
    return true
  }

  function cleanupStreams() {
    try {
      stdoutReader?.close()
    } catch {
      // 流已经没了，无所谓
    }
    try {
      stderrReader?.close()
    } catch {
      // 同上
    }
    stdoutReader = null
    stderrReader = null
  }

  /** 往 sidecar 的 stdin 写一行 JSON。返回 false = 通道已不可用（不是异常）。 */
  function send(message) {
    const stdin = child?.stdin
    if (!stdin || stdin.destroyed === true || stdin.writable === false) return false
    try {
      stdin.write(`${JSON.stringify(message)}\n`)
      return true
    } catch (error) {
      lastError = `写入 sidecar 失败：${error?.message ?? error}`
      warn(lastError)
      return false
    }
  }

  /**
   * 单条 sidecar 消息的处理。
   *
   * 这里刻意**不**在认不出的消息上抛错：插件与 sidecar 是独立升级的，宿主更新
   * 之后多出来的消息只该是噪音。真崩了的话，一个纯展示类的消息就能让整条通路断开。
   */
  function handleMessage(message) {
    switch (message.type) {
      case 'ready': {
        // 下划线命名是 wire 格式；写成 endpointId 只会得到 undefined 且不报错
        endpointId = typeof message.endpoint_id === 'string' ? message.endpoint_id : ''
        relay = typeof message.relay === 'string' && message.relay !== ''
          ? message.relay
          : typeof message.relay_url === 'string' && message.relay_url !== ''
            ? message.relay_url
            : null
        if (endpointId === '') {
          lastError = 'sidecar 的 ready 消息里没有 endpoint_id'
          warn(lastError)
          settleReady({ ok: false, reason: 'bad-ready' })
          return
        }
        running = true
        info(`iroh 就绪，本机 endpoint ${endpointId}${relay === null ? '' : `（relay ${relay}）`}`)
        settleReady({ ok: true, endpointId, relay })
        return
      }
      case 'pairing': {
        const code = typeof message.code === 'string' ? message.code : ''
        const expiresInSec = Number(message['expires_in_sec'])
        if (code === '' || endpointId === '') {
          // 没 endpoint 就拼不出可粘贴的串；报错好过给调用方一个 "#1234"
          settlePairing({ ok: false, reason: code === '' ? 'bad-pairing' : 'not-ready' })
          return
        }
        const pairingString = `${endpointId}#${code}`
        if (settlePairing({
          pairingString,
          expiresInSec: Number.isFinite(expiresInSec) ? expiresInSec : 0,
        }) === false) {
          // 没人等（例如 sidecar 自己开了窗口）：记一行就够，别丢
          info(`配对串已就绪：${pairingString}`)
        }
        return
      }
      case 'pairing-closed':
        // 窗口关了（超时/取消）：等配对码的调用方不能一直挂到自己的超时
        info(`配对窗口已关闭${message.reason ? `：${message.reason}` : ''}`)
        settlePairing({ ok: false, reason: 'closed' })
        return
      case 'pairing-done':
        info(`配对成功：${message.name ?? ''}`)
        return
      case 'peer-connected':
        info(`手机已连接：${message.name ?? ''}`)
        return
      case 'peer-path':
        info(message.kind === 'direct'
          ? `连接路径：P2P 直连 ${message.remote ?? ''}`
          : `连接路径：relay 中转（打洞未成，可用但延迟略高）${message.remote ?? ''}`)
        return
      case 'peer-disconnected':
        info('手机已断开')
        return
      case 'proxy-opened':
        info('手机已开始加载界面')
        return
      case 'devices':
        // 设备清单目前不参与决策，只记数量，方便排查"为什么这台手机被拒"
        info(`sidecar 报告了 ${Array.isArray(message.devices) ? message.devices.length : 0} 台已配对设备`)
        return
      default:
        warn(`未知 sidecar 消息：${JSON.stringify(message)}`)
    }
  }

  async function doStart() {
    // 上一次 stop() 还没收完尸就重启，两个 sidecar 会抢同一个 data-dir
    // （endpoint 身份文件被两边同时打开），结果比等几十毫秒更糟
    if (stopping !== null) await stopping
    if (typeof proxyTarget !== 'string' || proxyTarget === '') {
      // 调用方 bug：没有目标就没法代理。返回 reason 而不是抛，调用方按降级处理
      return { ok: false, reason: 'bad-config' }
    }
    endpointId = ''
    relay = null
    lastError = null

    const binary = binaryPath ?? resolveHostBinary()
    if (typeof binary !== 'string' || binary === '' || !existsSync(binary)) {
      lastError = `找不到 sidecar 二进制（平台 ${process.platform}-${process.arch}）`
      warn(`${lastError}；iroh 档位不可用`)
      return { ok: false, reason: 'not-installed' }
    }

    const args = ['host', '--proxy-target', proxyTarget, '--lang', lang === 'en' ? 'en' : 'zh']
    if (typeof dataDir === 'string' && dataDir !== '') args.push('--data-dir', dataDir)
    // 不传 --pair：配对窗口由 openPairing() 按需开。兜底档位可能一直空闲，
    // 一启动就亮着配对窗口等于把入口敞着，没必要

    const spawnFn = spawnImpl ?? nodeSpawn
    let proc
    try {
      proc = spawnFn(binary, args, {
        // stdout 是 JSON-lines 控制流；stderr 是 sidecar 的人读日志，转进宿主日志
        stdio: ['pipe', 'pipe', 'pipe'],
        // 桌面端插件宿主是 ELECTRON_RUN_AS_NODE 跑的 Electron，GUI 子系统没有自己的
        // console，Windows 会给子进程新开一个黑窗口。该选项让 libuv 传 SW_HIDE
        windowsHide: true,
      })
    } catch (error) {
      // 有些注入实现（以及极端情况下 libuv 的同步失败）会直接抛，而不是走 error 事件
      lastError = `sidecar 启动失败：${error?.message ?? error}`
      warn(lastError)
      return { ok: false, reason: 'spawn-failed', detail: lastError }
    }
    child = proc

    const readyPromise = new Promise((resolve) => {
      readyWaiter = {
        resolve,
        timer: setTimeout(() => {
          readyWaiter = null
          lastError = `sidecar 在 ${readyTimeoutMs}ms 内没有报 ready`
          warn(lastError)
          resolve({ ok: false, reason: 'timeout' })
        }, readyTimeoutMs),
      }
    })

    // spawn 失败只走 error 不走 exit（EACCES / ENOENT 就是这样）。两个都必须接住：
    // 漏掉任何一个都是 uncaught，会直接拖垮宿主进程
    proc.on('error', (error) => {
      const hint = error?.code === 'EACCES'
        ? '；EACCES 通常是二进制丢了可执行位，chmod 0755 或升级插件'
        : error?.code === 'ENOENT' ? '；ENOENT 表示路径不存在' : ''
      lastError = `sidecar 启动失败：${error?.message ?? error}${hint}`
      warn(`${lastError}（${binary}）`)
      running = false
      child = null
      cleanupStreams()
      settleReady({ ok: false, reason: 'spawn-failed', detail: lastError })
      settlePairing({ ok: false, reason: 'not-running' })
    })

    proc.on('exit', (code, signal) => {
      running = false
      child = null
      cleanupStreams()
      if (stoppingNow === true) {
        // 主动停的，不算故障；保留之前的 lastError（例如启动超时的原因）
        info('iroh sidecar 已停止')
      } else {
        // sidecar 死了必须可见：手机端会静默失联，而电脑侧看起来一切照常
        lastError = signal
          ? `sidecar 被信号 ${signal} 终止`
          : `sidecar 已退出（code=${code}）`
        warn(`${lastError}；iroh 档位不可用，手机端已失联`)
      }
      settleReady({ ok: false, reason: 'exited', detail: lastError })
      settlePairing({ ok: false, reason: 'not-running' })
    })

    if (proc.stdout) {
      // createInterface 按行切分比手写 split('\n') 稳：跨 chunk 的半行、\r\n、末尾无换行都管
      stdoutReader = createInterface({ input: proc.stdout })
      stdoutReader.on('line', (line) => {
        if (line.trim() === '') return
        let message
        try {
          message = JSON.parse(line)
        } catch {
          // sidecar 偶尔会往 stdout 混进非 JSON（panic 摘要之类），丢一行比崩掉强
          warn(`无法解析 sidecar 消息：${line}`)
          return
        }
        if (message === null || typeof message !== 'object') {
          warn(`sidecar 消息不是对象：${line}`)
          return
        }
        handleMessage(message)
      })
    }

    if (proc.stderr) {
      // 原样转成 warn：这是宿主终端里唯一的现场证据（relay 连不上之类都在这里）
      stderrReader = createInterface({ input: proc.stderr })
      stderrReader.on('line', (line) => {
        if (line.trim() !== '') warn(`sidecar: ${line}`)
      })
    }

    const result = await readyPromise
    if (result.ok !== true) {
      // 起不来就立刻收尸：留一个半死的进程会占住 data-dir 和 UDP socket，
      // 下一次 start() 只会更莫名其妙地失败
      await stop()
    }
    return result
  }

  /**
   * 拉起 sidecar 并等到 ready。
   *
   * @returns {Promise<{ok: true, endpointId: string, relay: string|null}
   *   | {ok: false, reason: 'not-installed'|'timeout'|'spawn-failed'|'exited'|'bad-config'|'bad-ready', detail?: string}>}
   */
  function start() {
    if (running === true) return Promise.resolve({ ok: true, endpointId, relay })
    if (starting !== null) return starting
    starting = doStart().finally(() => {
      starting = null
    })
    return starting
  }

  async function doStop() {
    const proc = child
    running = false
    // 幂等：没有子进程就立刻返回，重复 stop() 不能挂住调用方
    if (!proc) {
      cleanupStreams()
      return
    }
    child = null
    stoppingNow = true
    settleReady({ ok: false, reason: 'stopped' })
    settlePairing({ ok: false, reason: 'not-running' })

    const exited = new Promise((resolve) => {
      let settled = false
      const finish = () => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        resolve()
      }
      // 兜底：SIGTERM 被忽略（sidecar 卡在阻塞 IO 上）时不能无限等，
      // 否则测试挂住、宿主退出也挂住，还留下僵尸进程
      const timer = setTimeout(() => {
        try {
          proc.kill('SIGKILL')
        } catch {
          // 已经死透了
        }
        finish()
      }, stopTimeoutMs)
      proc.once('exit', finish)
      proc.once('error', finish)
    })

    try {
      proc.kill('SIGTERM')
    } catch (error) {
      lastError = `结束 sidecar 失败：${error?.message ?? error}`
      warn(lastError)
    }
    try {
      await exited
    } finally {
      stoppingNow = false
      cleanupStreams()
    }
  }

  /** 停止并等它真的退出。幂等：并发/重复调用共用同一次收尸。 */
  function stop() {
    if (stopping !== null) return stopping
    stopping = doStop().finally(() => {
      stopping = null
    })
    return stopping
  }

  /**
   * 只读快照，给上层拼清单/诊断用。
   *
   * 停掉之后 endpointId 仍然保留（不清空）：它是这台机器的身份，日志和
   * "上次连的是哪个 endpoint" 都靠它，清掉只会让现场更难查。running 才是唯一判据。
   */
  function status() {
    return {
      running: running === true && child !== null,
      endpointId,
      relay,
      lastError,
    }
  }

  /**
   * 开一个配对窗口，拿"一行可粘贴"的配对串。
   *
   * 配对流程本身（手机侧生成密钥、握手、落白名单）不在这里 —— 这里只把
   * `endpointId#code` 交出去，二维码/手输由调用方决定怎么展示。
   *
   * @returns {Promise<{pairingString: string, expiresInSec: number} | {ok: false, reason: string}>}
   */
  function openPairing() {
    if (running !== true || child === null) return Promise.resolve({ ok: false, reason: 'not-running' })
    if (endpointId === '') return Promise.resolve({ ok: false, reason: 'not-ready' })
    // 同时只允许一个等待者：sidecar 的配对窗口是全局的，两个请求只会互相覆盖
    if (pendingPairing !== null) return Promise.resolve({ ok: false, reason: 'busy' })
    return new Promise((resolve) => {
      // 先挂 waiter 再发请求：假 child（或极快的 sidecar）可能在 write 里同步回包
      pendingPairing = {
        resolve,
        timer: setTimeout(() => {
          pendingPairing = null
          resolve({ ok: false, reason: 'timeout' })
        }, pairingTimeoutMs),
      }
      if (send({ type: 'pairing-begin' }) === false) {
        settlePairing({ ok: false, reason: 'not-running' })
      }
    })
  }

  /**
   * 把浏览器 cookie 交给 sidecar，让它在**每条代理流上逐请求注入**。
   *
   * 这一步漏掉的后果很隐蔽：iroh 能连上、控制流正常、本地代理也起得来，
   * 但手机拿到的每一个页面都是 **401** —— 因为 dsh 的浏览器认证只认 cookie，
   * 而 sidecar 自己拿不到它（它只负责转发字节，cookie 由插件经 stdin 递进来）。
   * 实测就是这么发现的：端到端跑通后 GET / 返回 401，68 字节。
   *
   * @param {{cookie: string, authority: string}} auth `cookie` 形如 `name=value`
   * @returns {boolean} 是否真的发出去了（没在跑就返回 false，不抛）
   */
  function setProxyAuth({ cookie, authority } = {}) {
    if (running !== true || typeof cookie !== 'string' || cookie === '') return false
    if (typeof authority !== 'string' || authority === '') return false
    send({ type: 'proxy-auth', cookie, authority })
    return true
  }

  return { start, stop, status, openPairing, setProxyAuth }
}
