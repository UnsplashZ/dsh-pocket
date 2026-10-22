/**
 * iroh 档位的单测。
 *
 * 全部用假 child（EventEmitter + PassThrough），**不启动真进程**：
 *   · 单测不该依赖 sidecar 二进制装没装、relay 通不通；
 *   · 真进程会连公网 relay，跑一次 CI 就多一份不确定性；
 *   · 超时路径要能 60ms 跑完，而不是真的等 8 秒。
 */
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { PassThrough } from 'node:stream'
import test from 'node:test'

import { createIrohTier, resolveHostBinary } from '../lib/tiers/iroh.js'

/** 一个存在的文件即可：spawnImpl 是假的，这个路径只用来过 existsSync 检查。 */
const EXISTING_BINARY = process.execPath
const PROXY_TARGET = '127.0.0.1:18788'

const tick = () => new Promise((resolve) => setImmediate(resolve))

/** 收集日志，顺便断言"未知消息只该 warn 不该崩"。 */
function fakeLogger() {
  const lines = { info: [], warn: [] }
  return {
    lines,
    logger: {
      info: (message) => lines.info.push(String(message)),
      warn: (message) => lines.warn.push(String(message)),
    },
  }
}

/**
 * 假 child：形状对齐 ChildProcess 里我们真正用到的部分。
 *
 * `kill()` 会异步补一个 exit 事件 —— 真进程被杀后也是走 exit，
 * 不补的话 stop() 只能靠 2 秒兜底，测试会白等。
 */
function fakeChild() {
  const child = new EventEmitter()
  child.stdout = new PassThrough()
  child.stderr = new PassThrough()
  child.stdin = {
    writes: [],
    destroyed: false,
    writable: true,
    write(chunk) {
      this.writes.push(String(chunk))
      return true
    },
  }
  child.kills = []
  child.kill = (signal) => {
    child.kills.push(signal ?? 'SIGTERM')
    queueMicrotask(() => child.emit('exit', null, signal ?? 'SIGTERM'))
    return true
  }
  return child
}

/** 建一个 tier 并把 spawnImpl 换成假 child；返回 {tier, child, spawned, logger}。 */
function harness(overrides = {}) {
  const child = fakeChild()
  const spawned = []
  const { logger, lines } = fakeLogger()
  const tier = createIrohTier({
    binaryPath: EXISTING_BINARY,
    proxyTarget: PROXY_TARGET,
    dataDir: '/tmp/iroh-test',
    logger,
    spawnImpl: (binary, args, options) => {
      spawned.push({ binary, args, options })
      return child
    },
    readyTimeoutMs: 200,
    pairingTimeoutMs: 200,
    stopTimeoutMs: 200,
    ...overrides,
  })
  return { tier, child, spawned, lines }
}

const readyLine = (extra = {}) => `${JSON.stringify({ type: 'ready', endpoint_id: 'ep-abc123', relay: 'https://relay.example', ...extra })}\n`
const line = (message) => `${JSON.stringify(message)}\n`

test('ready / pairing / devices：按 sidecar 的下划线字段解析，并拼出 endpointId#code', async () => {
  const { tier, child, spawned, lines } = harness()
  const starting = tier.start()

  // spawn 参数必须与 tether 的 apply() 一致，否则 sidecar 会直接拒绝启动
  assert.equal(spawned.length, 1)
  assert.deepEqual(spawned[0].args, [
    'host', '--proxy-target', PROXY_TARGET, '--lang', 'zh', '--data-dir', '/tmp/iroh-test',
  ])
  assert.equal(spawned[0].options.stdio[0], 'pipe')

  child.stdout.write(readyLine())
  const result = await starting

  // endpoint_id 是下划线字段：写成 endpointId 会静默拿到空串
  assert.deepEqual(result, { ok: true, endpointId: 'ep-abc123', relay: 'https://relay.example' })
  assert.deepEqual(tier.status(), {
    running: true,
    endpointId: 'ep-abc123',
    relay: 'https://relay.example',
    lastError: null,
  })

  const pairingPromise = tier.openPairing()
  assert.ok(
    child.stdin.writes.some((chunk) => chunk.includes('"pairing-begin"')),
    'openPairing 应该往 stdin 写一行 pairing-begin',
  )
  child.stdout.write(line({ type: 'pairing', code: '7788', expires_in_sec: 300 }))
  assert.deepEqual(await pairingPromise, { pairingString: 'ep-abc123#7788', expiresInSec: 300 })

  // devices 与未知消息都只该被记录：认不出的消息不能把宿主带崩
  child.stdout.write(line({ type: 'devices', devices: [{ id: 'd1', name: '手机' }] }))
  child.stdout.write(line({ type: 'some-future-message', whatever: true }))
  await tick()
  assert.equal(tier.status().running, true)
  assert.ok(lines.warn.some((text) => text.includes('未知 sidecar 消息')))
  assert.ok(lines.info.some((text) => text.includes('1 台已配对设备')))

  await tier.stop()
})

test('ready 里的 relay 字段缺失时容忍 relay_url，两者都没有就是 null', async () => {
  const first = harness()
  const startingFirst = first.tier.start()
  first.child.stdout.write(readyLine({ relay: undefined, relay_url: 'https://relay-via-url.example' }))
  assert.equal((await startingFirst).relay, 'https://relay-via-url.example')
  await first.tier.stop()

  const second = harness()
  const startingSecond = second.tier.start()
  second.child.stdout.write(line({ type: 'ready', endpoint_id: 'ep-plain' }))
  assert.deepEqual(await startingSecond, { ok: true, endpointId: 'ep-plain', relay: null })
  await second.tier.stop()
})

test('ready 超时返回 timeout，并且立刻收尸（不留孤儿进程）', async () => {
  const { tier, child, lines } = harness({ readyTimeoutMs: 60 })
  const began = Date.now()
  const result = await tier.start()
  const elapsed = Date.now() - began

  assert.deepEqual(result, { ok: false, reason: 'timeout' })
  // 关键：超时时长必须可注入，否则这里要真等 8 秒
  assert.ok(elapsed < 2_000, `超时应该按注入的 60ms 生效，实际 ${elapsed}ms`)
  assert.equal(tier.status().running, false)
  assert.ok(child.kills.length >= 1, '启动超时后必须 kill 掉 sidecar')
  assert.match(tier.status().lastError, /没有报 ready/)
  assert.ok(lines.warn.some((text) => text.includes('没有报 ready')))
})

test('spawn 失败只走 error 事件：返回 spawn-failed，不抛也不留 running', async () => {
  const { tier, child, lines } = harness({ readyTimeoutMs: 1_000 })
  const starting = tier.start()

  const error = Object.assign(new Error('spawn tether-host EACCES'), { code: 'EACCES' })
  child.emit('error', error)
  const result = await starting

  assert.equal(result.ok, false)
  assert.equal(result.reason, 'spawn-failed')
  assert.equal(tier.status().running, false)
  // EACCES 的提示要能指出"二进制缺可执行位"，否则现场只有一句 Permission denied
  assert.match(tier.status().lastError, /可执行位/)
  assert.ok(lines.warn.some((text) => text.includes('EACCES')))
})

test('stop() 幂等：kill 一次、running=false，重复调用立刻返回', async () => {
  const { tier, child } = harness()
  const starting = tier.start()
  child.stdout.write(readyLine())
  assert.equal((await starting).ok, true)

  await tier.stop()
  await tier.stop()
  await tier.stop()

  assert.equal(tier.status().running, false)
  assert.equal(child.kills.length, 1, '重复 stop 不该反复 kill')

  // 停掉之后再开配对窗口必须立刻被拒，而不是挂到超时
  assert.deepEqual(await tier.openPairing(), { ok: false, reason: 'not-running' })
})

test('sidecar 意外退出后 status() 如实反映，并记录退出原因', async () => {
  const { tier, child } = harness()
  const starting = tier.start()
  child.stdout.write(readyLine())
  await starting

  child.emit('exit', 3, null)
  await tick()

  assert.equal(tier.status().running, false)
  assert.match(tier.status().lastError, /code=3/)
  await tier.stop()
})

test('配对窗口被关闭时 openPairing 立刻返回 closed，而不是等到超时', async () => {
  const { tier, child } = harness({ pairingTimeoutMs: 5_000 })
  const starting = tier.start()
  child.stdout.write(readyLine())
  await starting

  const pending = tier.openPairing()
  child.stdout.write(line({ type: 'pairing-closed', reason: 'expired' }))
  assert.deepEqual(await pending, { ok: false, reason: 'closed' })

  await tier.stop()
})

test('没有二进制时 start() 返回 not-installed，不抛异常', async () => {
  const { logger } = fakeLogger()
  const tier = createIrohTier({
    binaryPath: '/nonexistent/dsh-tether-host/bin/tether-host',
    proxyTarget: PROXY_TARGET,
    logger,
    spawnImpl: () => {
      throw new Error('不应该走到 spawn')
    },
    readyTimeoutMs: 50,
  })

  const result = await tier.start()
  assert.deepEqual(result, { ok: false, reason: 'not-installed' })
  assert.equal(tier.status().running, false)
  assert.match(tier.status().lastError, /找不到 sidecar 二进制/)
})

test('resolveHostBinary：平台子包优先，缺包时只回落到包内 cargo 产物', () => {
  const exe = process.platform === 'win32' ? 'tether-host.exe' : 'tether-host'
  const moduleId = `dsh-tether-host-${process.platform}-${process.arch}/bin/${exe}`

  const fromPackage = resolveHostBinary({ requireResolve: (id) => `/fake/node_modules/${id}` })
  assert.equal(fromPackage, `/fake/node_modules/${moduleId}`)

  // 平台子包没装：这个包内也没有 target/ 产物，所以应该是 undefined
  const fallback = resolveHostBinary({
    requireResolve: () => {
      throw Object.assign(new Error(`Cannot find module '${moduleId}'`), { code: 'MODULE_NOT_FOUND' })
    },
  })
  assert.ok(fallback === undefined || fallback.includes('target'), '回落只允许指向包内 cargo 产物')
})
