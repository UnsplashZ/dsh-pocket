/**
 * Bonjour / mDNS 广播。
 *
 * 目的：手机上**不填 IP、不扫码**，打开 App 就能在"附近的电脑"里看到这台机器。
 * 引导阶段只需要公开信息（哪台电脑、端口多少、版本多少），密钥仍然只在配对串里。
 *
 * 三条实测教训，改代码前先读：
 *
 * 1. **应答必须能被 iOS 的 NWBrowser 解析**。它比桌面上的 `dns-sd` 挑剔得多：报文里
 *    任何一处名字写错、压缩指针指偏，整包会被静默丢弃，表现是"电脑明明在广播，手机
 *    却什么都看不到"。所以这里**一律写完整名字，不做压缩** —— 报文多几十字节，换来的是
 *    不会算错 offset。
 * 2. **别乱回答**。mDNS 是共享的多播域，回错一个 `_http._tcp.local` 就是在污染邻居的
 *    服务列表。这里只认四个名字（见 `recordsFor`），其余查询直接丢。
 * 3. **多播不一定可靠**。某些系统/防火墙会吃掉本机发出的多播包，所以应答除了发回
 *    224.0.0.251:5353，还会**单播回查询方的地址** —— 这是让"第一次发现"成功率最高的
 *    做法，代价只是偶尔多一个重复包（mDNS 客户端按名字+类型去重，无害）。
 */
import dgram from 'node:dgram'
import { hostname as osHostname, networkInterfaces } from 'node:os'

const MDNS_ADDRESS = '224.0.0.251'
const MDNS_PORT = 5353
/** 服务类型枚举用的固定名字，`dns-sd -B` 就是查它。 */
const ENUM_DOMAIN = '_services._dns-sd._udp.local'

const TYPE_A = 1
const TYPE_PTR = 12
const TYPE_TXT = 16
const TYPE_SRV = 33
const TYPE_ANY = 255

const CLASS_IN = 1
/** 缓存刷新位：表示"这条记录是我独占的，收到别的同值记录请覆盖掉"。 */
const CACHE_FLUSH = 0x8000

/**
 * 服务记录的存活时间（秒）。75 分钟是 DNS-SD 的惯例：够长，不至于频繁重播；
 * 够短，广播进程被杀掉后邻居的列表里不会长期挂着一个僵尸条目。
 */
const TTL_SERVICE = 4500
/** 地址记录短得多：换网/换 IP 之后，手机必须尽快拿到新地址。 */
const TTL_ADDRESS = 120

/** mDNS 的报文 TTL 必须是 255（RFC 6762 §11），有些实现会拿它做防跨网段校验。 */
const MULTICAST_TTL = 255

// ---------------------------------------------------------------------------
// DNS 报文编码
// ---------------------------------------------------------------------------

/** 名字 = 若干"长度字节 + 内容"的标签，最后以 0 收尾。 */
function encodeName(name) {
  const parts = String(name).split('.').filter((part) => part.length > 0)
  const chunks = []
  for (const part of parts) {
    const bytes = Buffer.from(part, 'utf8')
    // 单个标签超过 63 字节就是非法报文，宁可在这里炸掉，也不要发出一个手机解析不了的包。
    if (bytes.length === 0 || bytes.length > 63) {
      throw new Error(`DNS 标签长度非法（${bytes.length} 字节）：${part}`)
    }
    chunks.push(Buffer.from([bytes.length]), bytes)
  }
  chunks.push(Buffer.from([0]))
  return Buffer.concat(chunks)
}

function u16(value) {
  const buffer = Buffer.alloc(2)
  buffer.writeUInt16BE(value & 0xffff, 0)
  return buffer
}

function u32(value) {
  const buffer = Buffer.alloc(4)
  buffer.writeUInt32BE(value >>> 0, 0)
  return buffer
}

function ptrData(target) {
  return encodeName(target)
}

function srvData({ port, target, priority = 0, weight = 0 }) {
  return Buffer.concat([u16(priority), u16(weight), u16(port), encodeName(target)])
}

/** TXT 是一串"长度字节 + 内容"；一个 key=value 占一段。 */
function txtData(entries) {
  const chunks = []
  for (const entry of entries) {
    const bytes = Buffer.from(String(entry), 'utf8')
    const slice = bytes.length > 255 ? bytes.subarray(0, 255) : bytes
    chunks.push(Buffer.from([slice.length]), slice)
  }
  return Buffer.concat(chunks)
}

function aData(address) {
  return Buffer.from(address.split('.').map((octet) => Number(octet) & 0xff))
}

/**
 * 序列化一条资源记录。
 *
 * `unique` 为真时带上缓存刷新位；`legacyUnicast` 为真时**不能**带 —— 老式单播查询方
 * 按普通 DNS 处理应答，看到 0x8001 这个 class 会当成未知类型丢掉（RFC 6762 §6.7）。
 */
function encodeRecord(record, { legacyUnicast }) {
  const flags = CLASS_IN | (record.unique && !legacyUnicast ? CACHE_FLUSH : 0)
  const head = Buffer.concat([
    u16(record.type),
    u16(flags),
    u32(record.ttl),
    u16(record.data.length),
  ])
  return Buffer.concat([encodeName(record.name), head, record.data])
}

/**
 * 组一个应答包。
 *
 * id 只有老式单播查询才回显；多播应答按 RFC 6762 §6 固定为 0（有些客户端会拿非零 id
 * 判定"这不是 mDNS 包"）。TC 恒为 0：我们的应答最多几百字节，永远不需要截断。
 */
function buildPacket({ id = 0, answers = [], additionals = [], legacyUnicast = false }) {
  const header = Buffer.alloc(12)
  header.writeUInt16BE(id, 0)
  header.writeUInt16BE(0x8400, 2) // QR=1（应答）、AA=1（权威）
  // DNS 头部的四个计数字段顺序固定：QDCOUNT / ANCOUNT / NSCOUNT / ARCOUNT。
  // 顺序写错（比如把 ANCOUNT 写到 QDCOUNT 的位置）不会报错，只会让对端把资源记录
  // 当成问题段去解析 —— 表现就是"包收到了，但一个服务都看不到"。
  header.writeUInt16BE(0, 4) // QDCOUNT：应答里不回显问题
  header.writeUInt16BE(answers.length, 6) // ANCOUNT
  header.writeUInt16BE(0, 8) // NSCOUNT：mDNS 不用权威段
  header.writeUInt16BE(additionals.length, 10) // ARCOUNT
  const body = [
    ...answers.map((record) => encodeRecord(record, { legacyUnicast })),
    ...additionals.map((record) => encodeRecord(record, { legacyUnicast })),
  ]
  return Buffer.concat([header, ...body])
}

// ---------------------------------------------------------------------------
// DNS 报文解析（只解析查询需要的那部分）
// ---------------------------------------------------------------------------

/**
 * 解一个名字，返回 `{name, next}`。
 *
 * 查询里的名字同样可能带压缩指针（同一个问题里问多个类型时很常见），所以必须支持。
 * 指针只允许向后跳、且跳数有上限 —— 否则一个恶意报文就能让解析器死循环。
 */
function decodeName(buffer, offset) {
  const labels = []
  let cursor = offset
  let next = -1
  let jumped = false
  let hops = 0
  while (cursor < buffer.length) {
    const length = buffer[cursor]
    if (length === 0) {
      cursor += 1
      if (!jumped) next = cursor
      break
    }
    if ((length & 0xc0) === 0xc0) {
      if (cursor + 1 >= buffer.length) return null
      const pointer = ((length & 0x3f) << 8) | buffer[cursor + 1]
      if (!jumped) next = cursor + 2
      jumped = true
      hops += 1
      if (hops > 8 || pointer >= buffer.length) return null
      cursor = pointer
      continue
    }
    cursor += 1
    if (cursor + length > buffer.length) return null
    labels.push(buffer.toString('utf8', cursor, cursor + length))
    cursor += length
    if (!jumped) next = cursor
  }
  if (next < 0) return null
  return { name: labels.join('.'), next }
}

/**
 * 解查询包。解析失败或不是查询（QR=1 是别人的应答）时返回 null。
 *
 * 注意 `qdcount` 可能很大：限制到 16 条，避免被一个畸形包拖着做无用功。
 */
function parseQuery(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length < 12) return null
  const id = buffer.readUInt16BE(0)
  const flags = buffer.readUInt16BE(2)
  if ((flags & 0x8000) !== 0) return null // 是应答，不是查询
  // opcode 必须是 0（标准查询）。别的 opcode 是别的协议在用这个端口，别插嘴。
  if ((flags & 0x7800) !== 0) return null
  const qdcount = Math.min(buffer.readUInt16BE(4), 16)
  const questions = []
  let offset = 12
  for (let index = 0; index < qdcount; index += 1) {
    const decoded = decodeName(buffer, offset)
    if (decoded === null) return null
    offset = decoded.next
    if (offset + 4 > buffer.length) return null
    const type = buffer.readUInt16BE(offset)
    const qclass = buffer.readUInt16BE(offset + 2)
    offset += 4
    // 只认 class IN；其余（CH/HS…）不是 DNS-SD 的查询。最高位是 QU（希望单播回复），
    // 掩掉即可 —— 我们本来就会单播回一份，不用单独处理。
    if ((qclass & 0x7fff) !== CLASS_IN) continue
    questions.push({ name: decoded.name, type })
  }
  return { id, questions }
}

// ---------------------------------------------------------------------------
// 本机信息
// ---------------------------------------------------------------------------

function parseIPv4(address) {
  if (typeof address !== 'string') return null
  const parts = address.split('.')
  if (parts.length !== 4) return null
  const octets = parts.map((part) => (/^\d{1,3}$/.test(part) ? Number(part) : Number.NaN))
  return octets.every((octet) => Number.isInteger(octet) && octet >= 0 && octet <= 255) ? octets : null
}

/** 私有网段 + CGNAT（Tailscale 的默认网段）。 */
function isPrivateIPv4(octets) {
  if (octets[0] === 10) return true
  if (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) return true
  if (octets[0] === 192 && octets[1] === 168) return true
  if (octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127) return true
  return false
}

/**
 * 本机可以作为 A 记录广播的 IPv4。
 *
 * 只收私有地址：mDNS 只在链路本地有意义，把一个公网地址写进 `.local` 既没用又多泄露
 * 一点信息。但如果这台机器一个私有地址都没有（罕见），退一步把所有非回环地址给出去 ——
 * 没有 A 记录，手机拿到 SRV 也连不上，等于白广播。
 */
function collectAddresses() {
  const all = []
  for (const entries of Object.values(networkInterfaces())) {
    for (const entry of entries ?? []) {
      // Node 18 给 `family: 4`，20+ 给 `'IPv4'`。
      if (entry.family !== 'IPv4' && entry.family !== 4) continue
      if (entry.internal) continue
      const octets = parseIPv4(entry.address)
      if (octets === null) continue
      if (octets[0] === 127 || octets[0] === 0) continue
      if (octets[0] === 169 && octets[1] === 254) continue // 链路本地自分配，不可达
      all.push(entry.address)
    }
  }
  const unique = [...new Set(all)]
  const privateOnes = unique.filter((address) => isPrivateIPv4(parseIPv4(address)))
  return privateOnes.length > 0 ? privateOnes : unique
}

/**
 * 把用户可见的名字收拾成一个合法的 DNS 标签。
 *
 * 点号必须换掉：我们的编码器按点分标签，名字里带点会被拆成两级，实例名就对不上了。
 * 单标签上限 63 字节，按 UTF-8 逐字符截断，不能把多字节字符切一半。
 */
function sanitizeLabel(value, fallback, { allowSpaces = true } = {}) {
  const raw = String(value ?? '').trim()
  let cleaned = raw.replace(/[.\u0000-\u001f\u007f]/g, '-')
  if (!allowSpaces) cleaned = cleaned.replace(/\s+/g, '-')
  let out = ''
  for (const char of cleaned) {
    if (Buffer.byteLength(out + char, 'utf8') > 63) break
    out += char
  }
  return out.length > 0 ? out : fallback
}

function normalizeServiceType(serviceType) {
  const raw = String(serviceType ?? '').trim().replace(/\.$/, '')
  const withoutLocal = raw.toLowerCase().endsWith('.local') ? raw.slice(0, -'.local'.length) : raw
  return withoutLocal.length > 0 ? withoutLocal : '_dsh._tcp'
}

function errorCode(error) {
  return String(error?.code ?? error?.message ?? error ?? 'unknown')
}

function isUsablePort(value) {
  return Number.isInteger(value) && value > 0 && value <= 65535
}

// ---------------------------------------------------------------------------
// 对外接口
// ---------------------------------------------------------------------------

/**
 * 创建广播器。
 *
 * @param {object} input
 * @param {string} input.hostId 本机稳定 id（首次运行生成）。会作为 TXT 的 `id=` 广播出去，
 *   手机靠它把"Bonjour 发现的服务"和"已配对的那台电脑"对上号。
 * @param {string} [input.name] 电脑名，手机侧列表里显示的就是它
 * @param {number} input.port 网关实际监听端口（TXT 与 SRV 都用它）
 * @param {string} [input.version] 插件版本，TXT 的 `v=`
 * @param {{info?: Function, warn?: Function}} [input.logger]
 * @param {string} [input.serviceType] 默认 `_dsh._tcp`，测试或多实例时才能改
 * @param {number} [input.mdnsPort] 监听/发送用的端口，默认 5353。只有测试会改它：
 *   线上改了这个值，系统的 mDNSResponder 就听不到了，广播等于白做
 */
export function createAdvertiser({
  hostId = '',
  name = '',
  port = 0,
  version = '',
  logger = null,
  serviceType = '_dsh._tcp',
  mdnsPort = MDNS_PORT,
} = {}) {
  const normalizedHostId = String(hostId ?? '').trim()
  const normalizedPort = Number(port)
  const normalizedMdnsPort = Number(mdnsPort)
  const service = normalizeServiceType(serviceType)
  const serviceDomain = `${service}.local`
  // 名字为空（或只有空白）时退回主机名：Bonjour 列表里总得有个能认出来的东西。
  const preferredName = String(name ?? '').trim() || osHostname()
  const instanceLabel = sanitizeLabel(preferredName, normalizedHostId || 'dsh')
  const instanceName = `${instanceLabel}.${serviceDomain}`
  const hostLabel = sanitizeLabel(osHostname(), 'dsh-host', { allowSpaces: false })
  const hostName = `${hostLabel}.local`

  const state = { running: false, serviceName: null, lastError: null }

  let socket = null
  let starting = null
  let announceTimer = null
  /** 记录集在 start 时按当时的网卡地址生成；换网后需要 stop/start 重新生成。 */
  let records = null

  function buildRecords() {
    const addresses = collectAddresses()
    return {
      ptr: {
        name: serviceDomain,
        type: TYPE_PTR,
        data: ptrData(instanceName),
        ttl: TTL_SERVICE,
        unique: false,
      },
      enumPtr: {
        name: ENUM_DOMAIN,
        type: TYPE_PTR,
        data: ptrData(serviceDomain),
        ttl: TTL_SERVICE,
        unique: false,
      },
      srv: {
        name: instanceName,
        type: TYPE_SRV,
        data: srvData({ port: normalizedPort, target: hostName }),
        ttl: TTL_SERVICE,
        unique: true,
      },
      txt: {
        name: instanceName,
        type: TYPE_TXT,
        // 只放公开信息。这里**永远不要**加 token / secret / 配对码：mDNS 是明文的，
        // 同网段任何人（包括咖啡厅里的陌生人）都能收到。
        data: txtData([
          `id=${normalizedHostId}`,
          `port=${normalizedPort}`,
          `v=${String(version ?? '')}`,
        ]),
        ttl: TTL_SERVICE,
        unique: true,
      },
      a: addresses.map((address) => ({
        name: hostName,
        type: TYPE_A,
        data: aData(address),
        ttl: TTL_ADDRESS,
        unique: true,
      })),
    }
  }

  /** 一条查询该回哪些记录。只认这四个名字，别的一律空数组（不回 = 不污染别人）。 */
  function recordsFor(question, current) {
    const name = question.name.toLowerCase().replace(/\.$/, '')
    const any = question.type === TYPE_ANY
    if (name === serviceDomain) {
      return any || question.type === TYPE_PTR ? [current.ptr] : []
    }
    if (name === ENUM_DOMAIN) {
      return any || question.type === TYPE_PTR ? [current.enumPtr] : []
    }
    if (name === instanceName.toLowerCase()) {
      const out = []
      if (any || question.type === TYPE_SRV) out.push(current.srv)
      if (any || question.type === TYPE_TXT) out.push(current.txt)
      return out
    }
    if (name === hostName.toLowerCase()) {
      return any || question.type === TYPE_A ? [...current.a] : []
    }
    return []
  }

  /**
   * 补充记录：问到 PTR 时把 SRV/TXT/A 一起塞进 additional，手机就不用再多问一轮。
   * 这是 DNS-SD 的标准做法，也是"点开 App 立刻能用"的关键。
   */
  function extrasFor(answers, current) {
    const extras = []
    const add = (record) => {
      if (!answers.includes(record) && !extras.includes(record)) extras.push(record)
    }
    if (answers.includes(current.ptr)) {
      add(current.srv)
      add(current.txt)
      for (const record of current.a) add(record)
    }
    if (answers.includes(current.srv)) {
      for (const record of current.a) add(record)
    }
    return extras
  }

  function sendTo(packet, address, targetPort) {
    if (socket === null) return
    try {
      socket.send(packet, 0, packet.length, targetPort, address, (error) => {
        if (!error) return
        state.lastError = errorCode(error)
        logger?.warn?.(`[uplink] mDNS 发送失败（${address}:${targetPort}）：${state.lastError}`)
      })
    } catch (error) {
      state.lastError = errorCode(error)
      logger?.warn?.(`[uplink] mDNS 发送失败：${state.lastError}`)
    }
  }

  function onMessage(buffer, rinfo) {
    if (!state.running || records === null) return
    const query = parseQuery(buffer)
    if (query === null || query.questions.length === 0) return

    const answers = []
    for (const question of query.questions) {
      for (const record of recordsFor(question, records)) {
        if (!answers.includes(record)) answers.push(record)
      }
    }
    // 一个都不匹配：装作没听见。乱回应答会让别人的服务列表变脏。
    if (answers.length === 0) return

    // 源端口不是 5353 的是"老式单播查询"（比如测试脚本、一些老客户端）：
    // 回显它的 id、不带缓存刷新位，并且只单播回去。
    const legacyUnicast = rinfo.port !== normalizedMdnsPort
    const packet = buildPacket({
      id: legacyUnicast ? query.id : 0,
      answers,
      additionals: extrasFor(answers, records),
      legacyUnicast,
    })
    if (!legacyUnicast) sendTo(packet, MDNS_ADDRESS, normalizedMdnsPort)
    sendTo(packet, rinfo.address, rinfo.port)
  }

  function announce() {
    if (!state.running || records === null) return
    const packet = buildPacket({
      answers: [records.ptr, records.enumPtr, ...records.a],
      additionals: [records.srv, records.txt],
    })
    sendTo(packet, MDNS_ADDRESS, normalizedMdnsPort)
  }

  function scheduleAnnounce() {
    // 广播一次可能撞上 Wi-Fi 省电/丢包，RFC 6762 §8.3 建议至少发两次。
    announce()
    announceTimer = setTimeout(() => {
      announceTimer = null
      announce()
    }, 1000)
    announceTimer.unref?.()
  }

  function bindSocket(target) {
    return new Promise((resolve) => {
      const onError = (error) => {
        target.removeListener('listening', onListening)
        resolve({ ok: false, error })
      }
      const onListening = () => {
        target.removeListener('error', onError)
        resolve({ ok: true })
      }
      target.once('error', onError)
      target.once('listening', onListening)
      // exclusive:false + reuseAddr：5353 上通常已经坐着系统 mDNSResponder（或别的
      // 客户端），独占绑定必然 EADDRINUSE。共享绑定才能既收到多播、又不打扰它们。
      target.bind({ port: normalizedMdnsPort, address: '0.0.0.0', exclusive: false })
    })
  }

  function closeSocket(target) {
    return new Promise((resolve) => {
      try {
        target.close(resolve)
      } catch {
        resolve()
      }
    })
  }

  async function start() {
    if (state.running) return { ok: true, serviceName: instanceName }
    if (starting !== null) return starting
    if (
      normalizedHostId === '' ||
      !isUsablePort(normalizedPort) ||
      !isUsablePort(normalizedMdnsPort)
    ) {
      return { ok: false, reason: 'bad-config' }
    }

    starting = (async () => {
      let target = null
      try {
        records = buildRecords()
        target = dgram.createSocket({ type: 'udp4', reuseAddr: true })
        target.on('message', (buffer, rinfo) => onMessage(buffer, rinfo))
        // 绑定完成后的异步错误（网卡被拔、权限变化）不该让整个插件崩掉：
        // 记下来，广播退化成"部分可用"，上层可以从 state() 里看到。
        target.on('error', (error) => {
          state.lastError = errorCode(error)
          logger?.warn?.(`[uplink] mDNS socket 错误：${state.lastError}`)
        })

        const bound = await bindSocket(target)
        if (!bound.ok) {
          await closeSocket(target)
          return { ok: false, reason: `bind:${errorCode(bound.error)}` }
        }

        try {
          target.addMembership(MDNS_ADDRESS)
          target.setMulticastTTL(MULTICAST_TTL)
          target.setMulticastLoopback(true)
        } catch (error) {
          // 没有多播权限（容器、受限网络）就没法被 Bonjour 发现，如实报告，别假装成功。
          await closeSocket(target)
          return { ok: false, reason: `multicast:${errorCode(error)}` }
        }

        socket = target
        state.running = true
        state.serviceName = instanceName
        state.lastError = null
        logger?.info?.(`[uplink] Bonjour 广播已启动：${instanceName} → ${hostName}:${normalizedPort}`)
        scheduleAnnounce()
        return { ok: true, serviceName: instanceName }
      } catch (error) {
        if (target !== null) await closeSocket(target)
        socket = null
        state.running = false
        state.lastError = errorCode(error)
        return { ok: false, reason: state.lastError }
      }
    })()

    try {
      return await starting
    } finally {
      starting = null
    }
  }

  async function stop() {
    // 正在 start 的过程中被叫停：等它落定再关，否则会漏一个已绑定的 socket。
    if (starting !== null) await starting
    if (!state.running) return
    state.running = false
    if (announceTimer !== null) {
      clearTimeout(announceTimer)
      announceTimer = null
    }
    const target = socket
    socket = null
    if (target === null) {
      state.serviceName = null
      return
    }
    // 告别包：TTL=0 让邻居立刻把条目摘掉，而不是等 75 分钟自然过期。
    if (records !== null) {
      const expire = (record) => ({ ...record, ttl: 0 })
      const goodbye = buildPacket({
        answers: [expire(records.ptr), expire(records.enumPtr), ...records.a.map(expire)],
        additionals: [expire(records.srv), expire(records.txt)],
      })
      await new Promise((resolve) => {
        const timer = setTimeout(resolve, 50)
        timer.unref?.()
        try {
          target.send(goodbye, 0, goodbye.length, normalizedMdnsPort, MDNS_ADDRESS, () => {
            clearTimeout(timer)
            resolve()
          })
        } catch {
          clearTimeout(timer)
          resolve()
        }
      })
    }
    await closeSocket(target)
    records = null
    state.serviceName = null
    logger?.info?.('[uplink] Bonjour 广播已停止')
  }

  return {
    start,
    stop,
    state() {
      return { running: state.running, serviceName: state.serviceName, lastError: state.lastError }
    },
  }
}
