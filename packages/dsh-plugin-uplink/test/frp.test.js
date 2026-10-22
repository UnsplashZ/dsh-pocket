/**
 * frp 档位的单元测试。
 *
 * 本机没有装 frpc（也不该为了跑测试去装），所以 managed 模式的"真跑起来"路径
 * 一律靠注入 `spawnImpl` + 注入 `run` 覆盖：
 * - `run` 假装 `frpc --version` 成功/失败，控制"装没装"；
 * - `spawnImpl` 返回一个假 child，控制"活过 1.5 秒"还是"立刻退出"。
 * 唯一真实的等待是 1.5 秒就绪窗口本身 —— 那是被测行为，不能 mock 掉。
 */
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import {
  FRP_READY_MS,
  createFrpTier,
  generateFrpcToml,
  proxyNameFor,
} from '../lib/tiers/frp.js'

const HOST_ID = '1a2b3c4d5e6f7788'

/**
 * 造一个"命令执行器"：按命令名给出结果，没列的走 fallback。
 *
 * 注意 detectFrpc 会**逐个**执行候选路径（`frpc`、`/usr/local/bin/frpc`、
 * `/opt/homebrew/bin/frpc`），所以"没装 frpc"必须让所有候选都失败 —— 只把 `frpc`
 * 设成失败是不够的。
 */
function fakeRun(table = {}, fallback = { ok: true, code: 0, stdout: 'frpc version 0.52.0', stderr: '' }) {
  const calls = []
  const run = async (command, args = []) => {
    calls.push([command, ...args].join(' '))
    const entry = table[command] ?? fallback
    return typeof entry === 'function' ? entry(command, args) : entry
  }
  run.calls = calls
  return run
}

/** 假 child：不会自己退出（代表"活过了就绪窗口"）。 */
function aliveChild(pid = 4242) {
  const child = new EventEmitter()
  child.pid = pid
  child.killed = false
  child.exitCode = null
  child.signals = []
  child.stdout = new EventEmitter()
  child.stderr = new EventEmitter()
  child.kill = (signal = 'SIGTERM') => {
    child.signals.push(signal)
    child.killed = true
    return true
  }
  return child
}

/** 假 child：spawn 之后很快自己退出（代表"参数错/端口占/token 不对"）。 */
function exitingChild({ pid = 4243, code = 1, signal = null, stderr = '' } = {}) {
  const child = aliveChild(pid)
  setImmediate(() => {
    if (stderr !== '') child.stderr.emit('data', stderr)
    child.exitCode = code
    child.emit('exit', code, signal)
  })
  return child
}

async function withStateDir(fn) {
  const dir = await mkdtemp(join(tmpdir(), 'dsh-uplink-frp-'))
  try {
    return await fn(dir)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
}

const FRP_CONFIG = Object.freeze({
  mode: 'managed',
  serverAddr: 'frp.example.com',
  serverPort: 7000,
  remotePort: 19000,
  token: 's3cret-token',
  tls: false,
  publicUrl: '',
})

test('generateFrpcToml 生成 frp v0.52+ 的 toml（[[proxies]] / localIP / auth.token）', () => {
  const toml = generateFrpcToml({
    serverAddr: 'frp.example.com',
    serverPort: 7000,
    token: 's3cret-token',
    localPort: 18788,
    remotePort: 19000,
    proxyName: 'dsh-1a2b3c4d',
  })

  assert.match(toml, /^serverAddr = "frp\.example\.com"$/m)
  assert.match(toml, /^serverPort = 7000$/m)
  // v0.52 起 token 在 auth.token；旧版顶层 token 必须不出现，两者混写会让人查半天
  assert.match(toml, /^auth\.token = "s3cret-token"$/m)
  assert.doesNotMatch(toml, /^token = /m)
  assert.match(toml, /^\[\[proxies\]\]$/m)
  assert.match(toml, /^name = "dsh-1a2b3c4d"$/m)
  assert.match(toml, /^type = "tcp"$/m)
  // 字段名是大写 IP：写成 localIp 会被 frpc 静默忽略，然后连到错误地址
  assert.match(toml, /^localIP = "127\.0\.0\.1"$/m)
  assert.doesNotMatch(toml, /localIp/)
  assert.match(toml, /^localPort = 18788$/m)
  assert.match(toml, /^remotePort = 19000$/m)
})

test('token 为空时不写 auth 段（写空串会让配了 token 的 frps 直接拒绝）', () => {
  const toml = generateFrpcToml({
    serverAddr: 'frp.example.com',
    token: '',
    localPort: 18788,
    remotePort: 19000,
    proxyName: 'dsh-x',
  })
  assert.doesNotMatch(toml, /auth\./)
  assert.doesNotMatch(toml, /token/)
  assert.match(toml, /^remotePort = 19000$/m)
})

test('generateFrpcToml 拒绝非法端口与空地址（宁可报错也不生成一份坏配置）', () => {
  assert.throws(() => generateFrpcToml({ serverAddr: '', localPort: 1, remotePort: 2 }), /serverAddr/)
  assert.throws(() => generateFrpcToml({ serverAddr: 'a', localPort: 0, remotePort: 2 }), /localPort/)
  assert.throws(() => generateFrpcToml({ serverAddr: 'a', localPort: 1, remotePort: 70000 }), /remotePort/)
})

test('proxyName 默认取 hostId 前 8 位，多台机器不会撞名', () => {
  assert.equal(proxyNameFor(HOST_ID), 'dsh-1a2b3c4d')
  assert.equal(proxyNameFor(''), 'dsh-unknown0')
  // 带连字符的 hostId 也不能让 frp 的代理名出现怪字符
  assert.equal(proxyNameFor('ab-cd-ef-12-34'), 'dsh-abcdef12')
})

test('byo 模式：不拉进程，url 用配置里的 publicUrl', async () => {
  const run = fakeRun()
  let spawned = false
  const tier = createFrpTier({
    config: { ...FRP_CONFIG, mode: 'byo', publicUrl: 'https://dsh.example.com' },
    gatewayPort: 18788,
    hostId: HOST_ID,
    stateDir: '/tmp/never-used',
    run,
    spawnImpl: () => {
      spawned = true
      return aliveChild()
    },
  })

  const result = await tier.start()
  assert.deepEqual(result, { ok: true, url: 'https://dsh.example.com' })
  assert.equal(spawned, false)
  // byo 连探测都不该做：不跑 frpc --version
  assert.deepEqual(run.calls, [])

  const status = tier.status()
  assert.equal(status.state, 'up')
  assert.equal(status.url, 'https://dsh.example.com')
  assert.equal(status.pid, null)
  // state=up 不能假装验证过连通性
  assert.match(status.note, /没有验证/)
  await tier.stop()
  assert.equal(tier.status().state, 'off')
})

test('byo 模式没有 publicUrl 时用 serverAddr:remotePort 拼（tls 决定 scheme）', async () => {
  const plain = createFrpTier({
    config: { ...FRP_CONFIG, mode: 'byo', tls: false },
    gatewayPort: 18788,
    run: fakeRun(),
    spawnImpl: () => aliveChild(),
  })
  assert.equal((await plain.start()).url, 'http://frp.example.com:19000')

  const secure = createFrpTier({
    config: { ...FRP_CONFIG, mode: 'byo', tls: true },
    gatewayPort: 18788,
    run: fakeRun(),
    spawnImpl: () => aliveChild(),
  })
  assert.equal((await secure.start()).url, 'https://frp.example.com:19000')
})

test('byo 模式既没 publicUrl 也没 serverAddr：返回 no-public-url 而不是一个空地址', async () => {
  const tier = createFrpTier({
    config: { ...FRP_CONFIG, mode: 'byo', serverAddr: '', publicUrl: '' },
    gatewayPort: 18788,
    run: fakeRun(),
    spawnImpl: () => aliveChild(),
  })
  const result = await tier.start()
  assert.equal(result.ok, false)
  assert.equal(result.reason, 'no-public-url')
  assert.equal(tier.status().state, 'down')
})

test('managed 模式：写 frpc.toml、spawn `-c <file>`、活过 1.5 秒算 up、stop 幂等', async () => {
  await withStateDir(async (stateDir) => {
    const child = aliveChild(999)
    const spawnCalls = []
    const tier = createFrpTier({
      config: FRP_CONFIG,
      gatewayPort: 18788,
      hostId: HOST_ID,
      stateDir,
      run: fakeRun(),
      spawnImpl: (command, args, options) => {
        spawnCalls.push({ command, args, options })
        return child
      },
    })

    const started = Date.now()
    const result = await tier.start()
    const elapsed = Date.now() - started

    assert.equal(result.ok, true)
    assert.equal(result.url, 'http://frp.example.com:19000')
    // 就绪判据是"活过 1.5 秒"，所以至少要等这么久
    assert.ok(elapsed >= FRP_READY_MS - 50, `start() 应该等满就绪窗口，实际 ${elapsed}ms`)

    assert.equal(spawnCalls.length, 1)
    assert.equal(spawnCalls[0].command, 'frpc')
    assert.equal(spawnCalls[0].args[0], '-c')
    const tomlPath = spawnCalls[0].args[1]
    assert.equal(tomlPath, join(stateDir, 'frpc.toml'))

    const toml = await readFile(tomlPath, 'utf8')
    assert.match(toml, /^remotePort = 19000$/m)
    assert.match(toml, /^localPort = 18788$/m)
    assert.match(toml, /^auth\.token = "s3cret-token"$/m)
    assert.match(toml, /^name = "dsh-1a2b3c4d"$/m)
    // 里面是明文 token，权限必须是 0600
    assert.equal((await stat(tomlPath)).mode & 0o777, 0o600)

    const status = tier.status()
    assert.equal(status.state, 'up')
    assert.equal(status.pid, 999)
    // 关键诚实性：up 只代表"没立刻退出"
    assert.match(status.note, /没有验证/)
    assert.equal(status.lastError, null)

    await tier.stop()
    await tier.stop() // 幂等：第二次不该再 kill，也不该抛
    assert.deepEqual(child.signals, ['SIGTERM'])
    assert.equal(tier.status().state, 'off')
    assert.equal(tier.status().pid, null)
  })
})

test('managed 模式：frpc 立刻退出时 start 失败、status 记 lastError', async () => {
  await withStateDir(async (stateDir) => {
    const tier = createFrpTier({
      config: FRP_CONFIG,
      gatewayPort: 18788,
      hostId: HOST_ID,
      stateDir,
      run: fakeRun(),
      spawnImpl: () => exitingChild({ code: 1, stderr: 'login to server failed: token mismatch' }),
    })

    const result = await tier.start()
    assert.equal(result.ok, false)
    assert.equal(result.reason, 'frpc-exited')

    const status = tier.status()
    assert.equal(status.state, 'down')
    // 失败原因必须留下来给人看，否则用户只能看到"没连上"
    assert.match(status.lastError, /frpc 已退出/)
    assert.match(status.lastError, /token mismatch/)
  })
})

test('managed 模式：进程在 up 之后退出，状态要跟着翻成 down（不能一直显示 up）', async () => {
  await withStateDir(async (stateDir) => {
    const child = aliveChild(777)
    const tier = createFrpTier({
      config: FRP_CONFIG,
      gatewayPort: 18788,
      hostId: HOST_ID,
      stateDir,
      run: fakeRun(),
      spawnImpl: () => child,
    })
    assert.equal((await tier.start()).ok, true)
    assert.equal(tier.status().state, 'up')

    child.exitCode = 0
    child.emit('exit', 0, null)
    const status = tier.status()
    assert.equal(status.state, 'down')
    assert.match(status.lastError, /已退出/)
  })
})

test('没有 frpc 二进制时 start 返回 frpc-not-installed，且不去 spawn', async () => {
  await withStateDir(async (stateDir) => {
    let spawned = false
    const tier = createFrpTier({
      config: FRP_CONFIG,
      gatewayPort: 18788,
      hostId: HOST_ID,
      stateDir,
      // detectFrpc 会逐个执行候选路径；全部失败即"没装"
      run: fakeRun({}, { ok: false, code: 127, stdout: '', stderr: 'command not found' }),
      spawnImpl: () => {
        spawned = true
        return aliveChild()
      },
    })

    const result = await tier.start()
    assert.deepEqual(result, { ok: false, reason: 'frpc-not-installed' })
    assert.equal(spawned, false)
    assert.equal(tier.status().state, 'down')
    assert.match(tier.status().lastError, /frpc/)
  })
})

test('managed 模式缺 serverAddr：返回 no-server-addr，不写文件也不 spawn', async () => {
  await withStateDir(async (stateDir) => {
    let spawned = false
    const tier = createFrpTier({
      config: { ...FRP_CONFIG, serverAddr: '' },
      gatewayPort: 18788,
      hostId: HOST_ID,
      stateDir,
      run: fakeRun(),
      spawnImpl: () => {
        spawned = true
        return aliveChild()
      },
    })
    const result = await tier.start()
    assert.equal(result.ok, false)
    assert.equal(result.reason, 'no-server-addr')
    assert.equal(spawned, false)
  })
})

test('config 传整份配置或只传 tiers.frp 都能用（调用方不必再拆一次）', async () => {
  const whole = createFrpTier({
    config: { port: 18788, tiers: { frp: { ...FRP_CONFIG, mode: 'byo', publicUrl: 'https://a.example' } } },
    gatewayPort: 18788,
    run: fakeRun(),
  })
  assert.equal((await whole.start()).url, 'https://a.example')

  const partial = createFrpTier({
    config: { ...FRP_CONFIG, mode: 'byo', publicUrl: 'https://b.example' },
    gatewayPort: 18788,
    run: fakeRun(),
  })
  assert.equal((await partial.start()).url, 'https://b.example')
})

test('managed 模式：探测到 frpc 但 spawn 时报 ENOENT，仍按 frpc-not-installed 报（二进制在探测后被删了）', async () => {
  await withStateDir(async (stateDir) => {
    const tier = createFrpTier({
      config: FRP_CONFIG,
      gatewayPort: 18788,
      hostId: HOST_ID,
      stateDir,
      run: fakeRun(),
      spawnImpl: () => {
        const child = aliveChild(555)
        setImmediate(() => {
          const error = new Error('spawn frpc ENOENT')
          error.code = 'ENOENT'
          child.emit('error', error)
        })
        return child
      },
    })

    const result = await tier.start()
    assert.equal(result.ok, false)
    // 报 spawn-failed 会让人去查 frps 配置；真实原因是二进制没了
    assert.equal(result.reason, 'frpc-not-installed')
    assert.match(tier.status().lastError, /ENOENT/)
  })
})

test('stop 在从未 start 过时也是安全的', async () => {
  const tier = createFrpTier({
    config: FRP_CONFIG,
    gatewayPort: 18788,
    stateDir: '/tmp/never-used',
    run: fakeRun(),
    spawnImpl: () => aliveChild(),
  })
  await tier.stop()
  await tier.stop()
  assert.equal(tier.status().state, 'off')
  // 没在跑就不该给地址：否则 UI 会显示一个点不开的链接
  assert.equal(tier.status().url, '')
  assert.equal(tier.status().pid, null)
})
