/**
 * mDNS 广播的端到端测试。
 *
 * 这里**不复用** lib/publish.js 里的解析器：测试自带一个最小实现，否则"编码器写错了、
 * 解析器也跟着错"会互相掩盖。断言也只依赖 DNS 线上的字节，不看内部状态。
 *
 * 运行：node --test test/publish.test.js
 */
import assert from 'node:assert/strict'
import dgram from 'node:dgram'
import { after, before, test } from 'node:test'

import { createAdvertiser } from '../lib/publish.js'

const MDNS_ADDRESS = '224.0.0.251'
const MDNS_PORT = 5353
// 每次跑用**唯一的服务类型**。
//
// 5353 是共用总线：开发机上 dsh 真的在跑时，它自己的 uplink 也在广播 `_dsh._tcp`，
// 于是"第一个应答"很可能是别人的包（实例名、端口、TXT 全不一样），
// 断言就会莫名其妙地红 —— 而代码其实是对的。换个只有本次运行在用的类型，
// 干扰从根上消失，也不必靠"过滤别人的包"来凑。
const RUN_TAG = `${process.pid.toString(16)}${Math.random().toString(16).slice(2, 6)}`
const SERVICE_TYPE = `_dshtest${RUN_TAG}._tcp`
const SERVICE_DOMAIN = `${SERVICE_TYPE}.local`
const ENUM_DOMAIN = '_services._dns-sd._udp.local'

const HOST_ID = 'testhost0123456789abcdef'
const PORT = 18788
const VERSION = '9.9.9'

const TYPE_A = 1
const TYPE_PTR = 12
const TYPE_TXT = 16
const TYPE_SRV = 33
const TYPE_ANY = 255

let advertiser = null
let serviceName = null
/** 环境起不来时（start 失败 / 多播回环不通）把它写在这里，各测试据此 skip。 */
let skipReason = null
/** before 里先探一次，后续测试直接复用这一包，省几轮往返。 */
let firstReply = null

// ---------------------------------------------------------------------------
// 最小 DNS 报文构造
// ---------------------------------------------------------------------------

function encodeName(name) {
  const chunks = []
  for (const part of String(name).split('.').filter((item) => item.length > 0)) {
    const bytes = Buffer.from(part, 'utf8')
    chunks.push(Buffer.from([bytes.length]), bytes)
  }
  chunks.push(Buffer.from([0]))
  return Buffer.concat(chunks)
}

function buildQuery(name, type, id = 0x5150) {
  const header = Buffer.alloc(12)
  header.writeUInt16BE(id, 0)
  header.writeUInt16BE(0, 2) // 标准查询：QR=0
  header.writeUInt16BE(1, 4)
  const tail = Buffer.alloc(4)
  tail.writeUInt16BE(type, 0)
  tail.writeUInt16BE(1, 2) // class IN
  return Buffer.concat([header, encodeName(name), tail])
}

function u16(value) {
  const buffer = Buffer.alloc(2)
  buffer.writeUInt16BE(value, 0)
  return buffer
}

// ---------------------------------------------------------------------------
// 最小 DNS 报文解析（支持压缩指针，这样即使被测代码改成压缩也能验出来）
// ---------------------------------------------------------------------------

function decodeName(buffer, offset) {
  const labels = []
  let cursor = offset
  let next = -1
  let jumped = false
  let hops = 0
  while (cursor < buffer.length) {
    const length = buffer[cursor]
    if (length === 0) {
      if (!jumped) next = cursor + 1
      break
    }
    if ((length & 0xc0) === 0xc0) {
      if (cursor + 1 >= buffer.length) return null
      if (!jumped) next = cursor + 2
      jumped = true
      hops += 1
      if (hops > 8) return null
      cursor = ((length & 0x3f) << 8) | buffer[cursor + 1]
      continue
    }
    if (cursor + 1 + length > buffer.length) return null
    labels.push(buffer.toString('utf8', cursor + 1, cursor + 1 + length))
    cursor += 1 + length
    if (!jumped) next = cursor
  }
  return next < 0 ? null : { name: labels.join('.'), next }
}

function readRecords(buffer, offset, count) {
  const records = []
  let cursor = offset
  for (let index = 0; index < count; index += 1) {
    const decoded = decodeName(buffer, cursor)
    if (decoded === null) return null
    cursor = decoded.next
    if (cursor + 10 > buffer.length) return null
    const type = buffer.readUInt16BE(cursor)
    const klass = buffer.readUInt16BE(cursor + 2)
    const ttl = buffer.readUInt32BE(cursor + 4)
    const length = buffer.readUInt16BE(cursor + 8)
    const rdataOffset = cursor + 10
    if (rdataOffset + length > buffer.length) return null
    records.push({
      name: decoded.name,
      type,
      klass,
      ttl,
      rdata: buffer.subarray(rdataOffset, rdataOffset + length),
      rdataOffset,
    })
    cursor = rdataOffset + length
  }
  return { records, next: cursor }
}

function parseMessage(buffer) {
  if (buffer.length < 12) return null
  const flags = buffer.readUInt16BE(2)
  if ((flags & 0x8000) === 0) return null // 只要应答
  const counts = {
    questions: buffer.readUInt16BE(4),
    answers: buffer.readUInt16BE(6),
    authority: buffer.readUInt16BE(8),
    additional: buffer.readUInt16BE(10),
  }
  let offset = 12
  const questions = []
  for (let index = 0; index < counts.questions; index += 1) {
    const decoded = decodeName(buffer, offset)
    if (decoded === null) return null
    offset = decoded.next
    if (offset + 4 > buffer.length) return null
    questions.push({ name: decoded.name, type: buffer.readUInt16BE(offset) })
    offset += 4
  }
  const answers = readRecords(buffer, offset, counts.answers)
  if (answers === null) return null
  const authority = readRecords(buffer, answers.next, counts.authority)
  if (authority === null) return null
  const additional = readRecords(buffer, authority.next, counts.additional)
  if (additional === null) return null
  return {
    raw: buffer,
    id: buffer.readUInt16BE(0),
    flags,
    questions,
    answers: answers.records,
    additional: additional.records,
  }
}

function targetOf(message, record) {
  const decoded = decodeName(message.raw, record.rdataOffset)
  return decoded === null ? null : decoded.name
}

/** SRV 的 rdata 前 6 字节是 priority/weight/port，名字从第 7 个字节开始。 */
function srvTargetOf(message, record) {
  const decoded = decodeName(message.raw, record.rdataOffset + 6)
  return decoded === null ? null : decoded.name
}

function srvPort(record) {
  return record.rdata.readUInt16BE(4)
}

function txtStrings(record) {
  const out = []
  let cursor = 0
  while (cursor < record.rdata.length) {
    const length = record.rdata[cursor]
    cursor += 1
    if (cursor + length > record.rdata.length) return null
    out.push(record.rdata.toString('utf8', cursor, cursor + length))
    cursor += length
  }
  return out
}

function aAddress(record) {
  return [...record.rdata].join('.')
}

// ---------------------------------------------------------------------------
// 收发
// ---------------------------------------------------------------------------

/**
 * 发一条查询，收集 700ms 内收到的应答。
 *
 * 查询从临时端口发出（不是 5353），走的是 mDNS 的"老式单播查询"路径：广播器会把
 * 应答单播回这个临时端口 —— 正好避开"5353 被系统 mDNSResponder 占着、本机发的
 * 多播包可能收不到"这个坑。
 */
function sendRaw(packet, { timeoutMs = 700 } = {}) {
  return new Promise((resolve) => {
    const socket = dgram.createSocket({ type: 'udp4', reuseAddr: true })
    const replies = []
    let settled = false
    const finish = () => {
      if (settled) return
      settled = true
      clearTimeout(hard)
      try {
        socket.close()
      } catch {
        // 已经关了就算了
      }
      resolve(replies)
    }
    const hard = setTimeout(finish, timeoutMs)
    socket.on('error', finish)
    socket.on('message', (buffer) => {
      const parsed = parseMessage(buffer)
      if (parsed === null) return
      replies.push(parsed)
      // 收到第一包后再多等一会儿：应答理论上是一整包，但留点余量给重复包/分片。
      setTimeout(finish, 150)
    })
    socket.bind(0, () => {
      socket.send(packet, 0, packet.length, MDNS_PORT, MDNS_ADDRESS, (error) => {
        if (error) finish()
      })
    })
  })
}

function askOnce(name, type, options = {}) {
  return sendRaw(buildQuery(name, type), options)
}

/** 多播 UDP 可能丢包，正例最多试三次；反例只试一次（省时间，且"没应答"本身就是结论）。 */
async function ask(name, type, { attempts = 3 } = {}) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const replies = await askOnce(name, type)
    if (replies.length > 0) return replies
  }
  return []
}

function allRecords(replies) {
  const out = []
  for (const message of replies) out.push(...message.answers, ...message.additional)
  return out
}

function requireRunning(t) {
  if (skipReason !== null) {
    t.skip(skipReason)
    return false
  }
  return true
}

// ---------------------------------------------------------------------------
// 生命周期
// ---------------------------------------------------------------------------

before(async () => {
  advertiser = createAdvertiser({
    hostId: HOST_ID,
    name: 'MacBook Pro Test',
    port: PORT,
    version: VERSION,
    serviceType: SERVICE_TYPE,
  })
  const started = await advertiser.start()
  if (!started.ok) {
    skipReason = `mDNS 广播起不来（${started.reason}），跳过：多半是 5353 被独占或多播被禁`
    return
  }
  serviceName = started.serviceName
  const probe = await ask(SERVICE_DOMAIN, TYPE_PTR)
  if (probe.length === 0) {
    skipReason = '多播回环收不到应答（沙箱/防火墙可能拦了 224.0.0.251），跳过端到端断言'
    return
  }
  firstReply = probe[0]
})

after(async () => {
  if (advertiser !== null) await advertiser.stop()
})

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

test('start() 幂等，state() 如实反映运行状态', async (t) => {
  if (!requireRunning(t)) return
  const state = advertiser.state()
  assert.equal(state.running, true)
  assert.equal(state.serviceName, serviceName)
  assert.ok(serviceName.endsWith(SERVICE_DOMAIN), `服务名应落在 ${SERVICE_DOMAIN} 下：${serviceName}`)
  assert.equal(state.lastError, null)

  const again = await advertiser.start()
  assert.equal(again.ok, true)
  assert.equal(again.serviceName, serviceName)
  assert.equal(advertiser.state().running, true)
})

test('PTR 查询能拿到实例名，并附带 SRV / TXT / A', async (t) => {
  if (!requireRunning(t)) return
  const replies = firstReply === null ? await ask(SERVICE_DOMAIN, TYPE_PTR) : [firstReply]
  assert.ok(replies.length > 0, '应当收到应答')

  const message = replies[0]
  // 老式单播查询：回显 id，QR=1、AA=1，且不能带缓存刷新位（class 必须是 1）。
  assert.equal(message.id, 0x5150)
  assert.equal(message.flags & 0x8000, 0x8000)
  assert.equal(message.flags & 0x0400, 0x0400)

  const records = allRecords(replies)
  const ptr = records.find((record) => record.type === TYPE_PTR && record.name === SERVICE_DOMAIN)
  assert.ok(ptr, `应答里应有 ${SERVICE_DOMAIN} 的 PTR`)
  assert.equal(targetOf(message, ptr), serviceName)
  assert.equal(ptr.klass, 1)

  const srv = records.find((record) => record.type === TYPE_SRV)
  assert.ok(srv, '应答里应有 SRV')
  assert.equal(srv.name, serviceName)
  assert.equal(srvPort(srv), PORT)
  const srvTarget = srvTargetOf(message, srv)
  assert.ok(srvTarget.endsWith('.local'), `SRV target 应是 .local 主机名：${srvTarget}`)

  const txt = records.find((record) => record.type === TYPE_TXT)
  assert.ok(txt, '应答里应有 TXT')
  const strings = txtStrings(txt)
  assert.ok(strings.includes(`id=${HOST_ID}`), `TXT 应带 id=：${strings.join(',')}`)
  assert.ok(strings.includes(`port=${PORT}`), `TXT 应带 port=：${strings.join(',')}`)
  assert.ok(strings.includes(`v=${VERSION}`), `TXT 应带 v=：${strings.join(',')}`)

  const a = records.find((record) => record.type === TYPE_A)
  assert.ok(a, '应答里应有 A 记录，否则手机拿到 SRV 也连不上')
  assert.equal(a.name, srvTarget, 'A 记录的名字应与 SRV target 一致')
  assert.match(aAddress(a), /^\d{1,3}(\.\d{1,3}){3}$/)
})

test('_services._dns-sd._udp.local 返回服务类型（dns-sd -B 靠它枚举）', async (t) => {
  if (!requireRunning(t)) return
  const replies = await ask(ENUM_DOMAIN, TYPE_PTR)
  assert.ok(replies.length > 0, '枚举查询也应当被应答')
  const records = allRecords(replies)
  const ptr = records.find((record) => record.type === TYPE_PTR && record.name === ENUM_DOMAIN)
  assert.ok(ptr, '应有服务类型枚举的 PTR')
  assert.equal(targetOf(replies[0], ptr), SERVICE_DOMAIN)
})

test('直接按实例名查 SRV，也能拿到端口', async (t) => {
  if (!requireRunning(t)) return
  const replies = await ask(serviceName, TYPE_SRV)
  assert.ok(replies.length > 0, '按实例名查询应当被应答')
  const srv = allRecords(replies).find((record) => record.type === TYPE_SRV)
  assert.ok(srv, '应有 SRV')
  assert.equal(srvPort(srv), PORT)
})

test('ANY 查询一次给全（PTR + SRV + TXT + A）', async (t) => {
  if (!requireRunning(t)) return
  const replies = await ask(SERVICE_DOMAIN, TYPE_ANY)
  assert.ok(replies.length > 0, 'ANY 查询应当被应答')
  const types = new Set(allRecords(replies).map((record) => record.type))
  for (const type of [TYPE_PTR, TYPE_SRV, TYPE_TXT, TYPE_A]) {
    assert.ok(types.has(type), `ANY 应答里缺少类型 ${type}`)
  }
})

test('查询名里带压缩指针也能解析并应答', async (t) => {
  if (!requireRunning(t)) return
  // 两个问题，第二个名字用 0xC00C 指回第一个名字（偏移 12）—— 真实客户端常这么干。
  const header = Buffer.alloc(12)
  header.writeUInt16BE(0x5151, 0)
  header.writeUInt16BE(0, 2)
  header.writeUInt16BE(2, 4)
  const q1 = Buffer.concat([encodeName(SERVICE_DOMAIN), u16(TYPE_PTR), u16(1)])
  const q2 = Buffer.concat([Buffer.from([0xc0, 0x0c]), u16(TYPE_TXT), u16(1)])
  const replies = await sendRaw(Buffer.concat([header, q1, q2]))
  assert.ok(replies.length > 0, '带压缩指针的查询也应被正确解析')
  assert.equal(replies[0].id, 0x5151)
  const ptr = allRecords(replies).find((record) => record.type === TYPE_PTR && record.name === SERVICE_DOMAIN)
  assert.ok(ptr, 'PTR 应正常返回')
  assert.equal(targetOf(replies[0], ptr), serviceName)
})

test('serviceType 可覆盖，不同服务类型互不串台', async (t) => {
  if (!requireRunning(t)) return
  const altDomain = '_dsh-alt._tcp.local'
  const alt = createAdvertiser({
    hostId: 'alt-host',
    name: 'Alt Service',
    port: 19999,
    version: '0.0.1',
    serviceType: '_dsh-alt._tcp',
  })
  const started = await alt.start()
  if (!started.ok) {
    t.skip(`第二个广播器起不来（${started.reason}）`)
    return
  }
  try {
    assert.ok(started.serviceName.endsWith(altDomain), `实例名应落在 ${altDomain} 下：${started.serviceName}`)
    const replies = await ask(altDomain, TYPE_PTR)
    assert.ok(replies.length > 0, '自定义服务类型也应被应答')
    const ptr = allRecords(replies).find((record) => record.type === TYPE_PTR && record.name === altDomain)
    assert.ok(ptr, '应有自定义服务类型的 PTR')
    assert.equal(targetOf(replies[0], ptr), started.serviceName)

    // 默认服务类型不受影响：两个广播器可以共存。
    const mainReplies = await ask(SERVICE_DOMAIN, TYPE_PTR)
    const mainPtr = allRecords(mainReplies).find(
      (record) => record.type === TYPE_PTR && record.name === SERVICE_DOMAIN,
    )
    assert.ok(mainPtr, '默认服务类型应仍可被发现')
    assert.equal(targetOf(mainReplies[0], mainPtr), serviceName)
  } finally {
    await alt.stop()
  }
})

test('TXT 里只有公开字段，不含任何秘密', async (t) => {
  if (!requireRunning(t)) return
  const replies = firstReply === null ? await ask(SERVICE_DOMAIN, TYPE_PTR) : [firstReply]
  const txt = allRecords(replies).find((record) => record.type === TYPE_TXT)
  assert.ok(txt, '应有 TXT')
  const strings = txtStrings(txt)
  assert.deepEqual([...strings].sort(), [`id=${HOST_ID}`, `port=${PORT}`, `v=${VERSION}`].sort())
  for (const entry of strings) {
    assert.equal(/secret|token|passw|pair/i.test(entry), false, `TXT 里不该出现敏感字段：${entry}`)
  }
})

test('无关的查询一律不应答（不污染别人的 mDNS）', async (t) => {
  if (!requireRunning(t)) return
  const stranger = `_dsh-absent-${Math.random().toString(16).slice(2)}._tcp.local`
  const strangerReplies = await ask(stranger, TYPE_PTR, { attempts: 1 })
  assert.equal(strangerReplies.length, 0, `不该应答无关服务 ${stranger}`)

  // 名字对、类型不对（_dsh._tcp.local 的 A 记录）也不该应答。
  const wrongType = await ask(SERVICE_DOMAIN, TYPE_A, { attempts: 1 })
  assert.equal(wrongType.length, 0, '不该应答不存在的记录类型')
})

test('端口被独占时 start() 返回 ok:false，而不是抛异常', async () => {
  // 5353 上没法复现"独占"（系统 mDNSResponder 已经占着且带 reuseAddr），
  // 所以换一个临时端口：先不带 reuseAddr 绑住它，再让广播器去抢同一个端口。
  const blocker = dgram.createSocket({ type: 'udp4', reuseAddr: false })
  await new Promise((resolve) => blocker.bind(0, '0.0.0.0', resolve))
  const busyPort = blocker.address().port
  const victim = createAdvertiser({ hostId: 'busy', name: 'Busy', port: PORT, mdnsPort: busyPort })
  try {
    const result = await victim.start()
    assert.equal(result.ok, false)
    assert.equal(result.reason, 'bind:EADDRINUSE')
    assert.equal(victim.state().running, false)
    assert.equal(victim.state().serviceName, null)
    await victim.stop()
    assert.equal(victim.state().running, false)
  } finally {
    blocker.close()
  }
})

test('stop() 之后不再应答，且 stop 幂等', async (t) => {
  if (!requireRunning(t)) return
  await advertiser.stop()
  assert.equal(advertiser.state().running, false)
  assert.equal(advertiser.state().serviceName, null)

  const replies = await ask(SERVICE_DOMAIN, TYPE_PTR, { attempts: 1 })
  assert.equal(replies.length, 0, 'stop 之后不应再有任何应答')

  await advertiser.stop()
  assert.equal(advertiser.state().running, false)

  // 停掉之后重新 start 仍应工作（上层换网时就是这么用的）。
  const restarted = await advertiser.start()
  assert.equal(restarted.ok, true)
  assert.equal(advertiser.state().running, true)
})
