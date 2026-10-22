import assert from 'node:assert/strict'
import { mkdtemp } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import { apply } from '../index.js'
import { decodePairingPayload } from '../lib/descriptor.js'

/**
 * 一个够用的假 cordis ctx：只实现 apply 真正用到的那几样。
 *
 * `effect(fn)` 在 cordis 里是"立刻执行 fn，把返回的函数当清理器"，
 * 这里照做，测试结束时统一调用，才能验证插件能被干净卸载。
 */
function fakeCtx({ host = '127.0.0.1', port }) {
  const routes = new Map()
  const disposers = []
  const ctx = {
    webServer: {
      host,
      port,
      protocol: 'http:',
      register(spec) {
        routes.set(spec.path, spec.handler)
        return () => routes.delete(spec.path)
      },
    },
    effect(fn) {
      const dispose = fn()
      if (typeof dispose === 'function') disposers.push(dispose)
      return () => {}
    },
    // 这个测试里不给 connection 服务：网关的 cookie 会是 null，
    // 正好验证"没有 connection 时插件照样能起来"
    inject() {},
  }
  return { ctx, routes, disposeAll: () => { for (const dispose of disposers) dispose() } }
}

/** 直接调用管理路由的 handler，拿回 {status, body}。 */
function call(handler, { method = 'GET', path = '/', body, headers = {} } = {}) {
  return new Promise((resolve) => {
    const chunks = []
    let status = 0
    const responseHeaders = {}
    const res = {
      writeHead(code, value) {
        status = code
        Object.assign(responseHeaders, value ?? {})
        return res
      },
      end(chunk) {
        if (chunk !== undefined) chunks.push(Buffer.from(chunk))
        const text = Buffer.concat(chunks).toString('utf8')
        let json
        try {
          json = JSON.parse(text)
        } catch {
          json = undefined
        }
        resolve({ status, headers: responseHeaders, text, json })
      },
      destroy() {
        resolve({ status, headers: responseHeaders, text: '', json: undefined })
      },
    }
    const request = {
      method,
      url: path,
      headers: { host: '127.0.0.1:63978', ...headers },
      on(event, listener) {
        if (event === 'data' && body !== undefined) listener(Buffer.from(JSON.stringify(body)))
        if (event === 'end') listener()
        return request
      },
      destroy() {},
    }
    handler(request, res)
  })
}

/** 等插件把网关真正拉起来（apply 里的装配是异步的）。 */
async function waitForGateway(routes, timeoutMs = 8000) {
  const started = Date.now()
  while (Date.now() - started < timeoutMs) {
    const state = await call(routes.get('/uplink/state'))
    if (state.json?.started === true) return state.json
    await new Promise((resolve) => setTimeout(resolve, 50))
  }
  throw new Error('网关没在超时内起来')
}

async function boot(options = {}) {
  const dir = await mkdtemp(join(tmpdir(), 'uplink-plugin-'))
  const { ctx, routes, disposeAll } = fakeCtx({ port: options.dshPort ?? 1 })
  apply(ctx, {
    port: 0,
    bind: '127.0.0.1',
    statePath: join(dir, 'state.json'),
    tiers: {
      lan: { enabled: true },
      tailscale: { enabled: false },
      zerotier: { enabled: false },
      frp: { enabled: false },
      iroh: { enabled: false },
      ...(options.tiers ?? {}),
    },
    ...(options.extraAddresses ? { extraAddresses: options.extraAddresses } : {}),
  })
  const state = await waitForGateway(routes)
  return { routes, state, disposeAll, dir }
}

test('插件能装配起来，网关拿到真实端口并算出局域网档位', async () => {
  const env = await boot()
  try {
    assert.equal(env.state.started, true)
    assert.ok(env.state.port > 0, '端口应该是系统分配的真实值')
    assert.equal(env.state.configuredPort, 0)
    assert.match(env.state.hostId, /^[0-9a-f]{16}$/)
    // 关掉了 tailscale/zerotier/frp/iroh，清单里只该有局域网
    for (const tier of env.state.tiers) assert.equal(tier.kind, 'lan')
    // 本机至少有一张私有网卡（10/8、172.16/12 或 192.168/16）
    assert.ok(env.state.tiers.length >= 1, '局域网档不该为空')
    for (const tier of env.state.tiers) assert.match(tier.url, /^http:\/\/\d+\.\d+\.\d+\.\d+:\d+$/)
  } finally {
    env.disposeAll()
  }
})

test('免票路由真的能被手机打到（网关独立监听）', async () => {
  const env = await boot()
  try {
    const response = await fetch(`http://127.0.0.1:${env.state.port}/uplink/ping`)
    assert.equal(response.status, 200)
    const body = await response.json()
    assert.equal(body.ok, true)
    assert.equal(body.hostId, env.state.hostId)

    const unauth = await fetch(`http://127.0.0.1:${env.state.port}/`)
    assert.equal(unauth.status, 401)
  } finally {
    env.disposeAll()
  }
})

test('配对：返回可解析的配对串，里面带着手机要用的地址', async () => {
  const env = await boot()
  try {
    const paired = await call(env.routes.get('/uplink/pair'), { method: 'POST', body: { name: 'M的 iPhone' } })
    assert.equal(paired.status, 200)
    assert.equal(paired.json.ok, true)
    assert.equal(paired.json.name, 'M的 iPhone')

    const decoded = decodePairingPayload(paired.json.pairingString)
    assert.equal(decoded.ok, true)
    assert.equal(decoded.payload.hostId, env.state.hostId)
    assert.equal(decoded.payload.port, env.state.port)
    assert.deepEqual(decoded.payload.urls, paired.json.urls)
    assert.deepEqual(paired.json.urls, env.state.tiers.map((tier) => tier.url))
    // 配对串里必须有 secret，但设备列表里不能有
    assert.match(decoded.payload.secret, /^[0-9a-f]{64}$/)
  } finally {
    env.disposeAll()
  }
})

test('设备列表、撤销、轮换密钥都通', async () => {
  const env = await boot()
  try {
    const paired = await call(env.routes.get('/uplink/pair'), { method: 'POST', body: { name: '手机' } })
    const deviceId = paired.json.deviceId

    const list = await call(env.routes.get('/uplink/devices'))
    assert.equal(list.json.devices.length, 1)
    assert.equal(list.json.devices[0].deviceId, deviceId)
    assert.equal(list.json.devices[0].revoked, false)
    // 列表里绝不能出现 secret
    assert.equal(JSON.stringify(list.json).includes('secret'), false)

    const revoked = await call(env.routes.get('/uplink/devices'), { method: 'POST', body: { id: deviceId } })
    assert.equal(revoked.status, 200)
    const after = await call(env.routes.get('/uplink/devices'))
    assert.equal(after.json.devices[0].revoked, true)

    const rotated = await call(env.routes.get('/uplink/rotate'), { method: 'POST' })
    assert.equal(rotated.json.keyVersion, 2)
  } finally {
    env.disposeAll()
  }
})

test('管理路由拒绝非回环 Host（DNS 重绑定 / 跨站请求）', async () => {
  const env = await boot()
  try {
    const evil = await call(env.routes.get('/uplink/state'), { headers: { host: 'evil.example.com' } })
    assert.equal(evil.status, 403)
    const crossSite = await call(env.routes.get('/uplink/pair'), {
      method: 'POST',
      headers: { 'sec-fetch-site': 'cross-site' },
      body: {},
    })
    assert.equal(crossSite.status, 403)
    const badOrigin = await call(env.routes.get('/uplink/state'), {
      headers: { origin: 'http://evil.example.com' },
    })
    assert.equal(badOrigin.status, 403)
  } finally {
    env.disposeAll()
  }
})

test('卸载插件会把网关关掉（不留监听端口）', async () => {
  const env = await boot()
  const port = env.state.port
  env.disposeAll()
  // 关掉之后同一个端口应该没人监听
  await assert.rejects(
    fetch(`http://127.0.0.1:${port}/uplink/ping`, { signal: AbortSignal.timeout(2000) }),
    (error) => {
      assert.ok(/ECONNREFUSED|fetch failed|aborted|timeout/i.test(String(error?.message ?? error)))
      return true
    },
  )
})

test('state 里能看出每一档的真实状态（而不是只回配置）', async () => {
  const env = await boot()
  try {
    assert.equal(env.state.scheme, 'http')
    assert.equal(env.state.tls, null)
    assert.deepEqual(env.state.enabled, {
      lan: true, tailscale: false, zerotier: false, frp: false, iroh: false,
    })
    // Bonjour 广播的状态要能单独看见：它失败不该让整档不可用
    assert.equal(typeof env.state.bonjour.running, 'boolean')
    // frp / iroh 没启用时是 null，不是 {}，前端好判断
    assert.equal(env.state.frp, null)
    assert.equal(env.state.iroh, null)
    assert.ok(Array.isArray(env.state.warnings))
  } finally {
    env.disposeAll()
  }
})

test('运行时勾选/取消档位：只动受影响的组件，并如实回报', async () => {
  const env = await boot()
  try {
    // 关掉局域网：Bonjour 广播要跟着停
    const off = await call(env.routes.get('/uplink/tiers'), { method: 'POST', body: { enabled: { lan: false } } })
    assert.equal(off.status, 200)
    assert.deepEqual(off.json.changes, { lan: false })
    assert.equal(off.json.enabled.lan, false)
    const after = await call(env.routes.get('/uplink/state'))
    assert.equal(after.json.enabled.lan, false)
    assert.equal(after.json.bonjour.running, false)
    // 关掉之后清单里不该再有局域网档
    assert.equal(after.json.tiers.some((tier) => tier.kind === 'lan'), false)

    // 再打开
    const on = await call(env.routes.get('/uplink/tiers'), { method: 'POST', body: { lan: true } })
    assert.deepEqual(on.json.changes, { lan: true })
    const back = await call(env.routes.get('/uplink/state'))
    assert.ok(back.json.tiers.some((tier) => tier.kind === 'lan'))
  } finally {
    env.disposeAll()
  }
})

test('档位开关：没有变化时不重启任何组件，非 POST 直接 405', async () => {
  const env = await boot()
  try {
    const noop = await call(env.routes.get('/uplink/tiers'), { method: 'POST', body: { enabled: { lan: true } } })
    assert.equal(noop.status, 200)
    assert.deepEqual(noop.json.changes, {})
    assert.deepEqual(noop.json.applied, undefined)

    const wrongMethod = await call(env.routes.get('/uplink/tiers'), { method: 'GET' })
    assert.equal(wrongMethod.status, 405)
  } finally {
    env.disposeAll()
  }
})

test('配对响应里带档位名，手机不用靠地址段猜', async () => {
  const env = await boot()
  try {
    const paired = await call(env.routes.get('/uplink/pair'), { method: 'POST', body: { name: '手机' } })
    assert.ok(Array.isArray(paired.json.tiers))
    assert.ok(paired.json.tiers.length >= 1)
    for (const tier of paired.json.tiers) {
      assert.ok(['lan', 'tailscale', 'zerotier', 'frp'].includes(tier.kind))
      assert.match(tier.url, /^https?:\/\//)
    }
    // tiers 与 urls 必须一一对应（同一个地址不能一边有一边没有）
    assert.deepEqual(paired.json.tiers.map((tier) => tier.url), paired.json.urls)
    // 配对串里也要带上
    const decoded = decodePairingPayload(paired.json.pairingString)
    assert.deepEqual(decoded.payload.tiers, paired.json.tiers)
  } finally {
    env.disposeAll()
  }
})

test('手填 tailnet 地址会进清单，并标出来源是 manual', async () => {
  // 这是 sing-box 那种情况的解：tailnet IP 不出现在网卡上，自动探测原理上看不到
  const env = await boot({
    tiers: { tailscale: { enabled: true, addresses: ['100.101.2.3'] } },
  })
  try {
    const tier = env.state.tiers.find((item) => item.kind === 'tailscale')
    assert.ok(tier, '手填的 tailscale 地址必须出现在清单里')
    assert.match(tier.url, /^http:\/\/100\.101\.2\.3:\d+$/)
    assert.equal(tier.source, 'manual')
    assert.equal(tier.address, '100.101.2.3')
    // 局域网档仍然在，且来源标成 interface
    const lan = env.state.tiers.find((item) => item.kind === 'lan')
    assert.equal(lan.source, 'interface')
  } finally {
    env.disposeAll()
  }
})

test('extraAddresses 支持完整 URL，档位按地址段猜', async () => {
  const env = await boot({
    extraAddresses: ['https://dsh.example.com', '100.88.1.2', 'http://192.168.1.9:18788'],
  })
  try {
    const frp = env.state.tiers.find((item) => item.url === 'https://dsh.example.com')
    assert.ok(frp, '完整 URL 要原样保留')
    assert.equal(frp.kind, 'frp')
    assert.equal(frp.source, 'manual')

    const ts = env.state.tiers.find((item) => item.url.startsWith('http://100.88.1.2:'))
    assert.equal(ts.kind, 'tailscale', '100.64/10 猜成 tailscale')

    const lan = env.state.tiers.find((item) => item.url === 'http://192.168.1.9:18788')
    assert.equal(lan.kind, 'lan')
  } finally {
    env.disposeAll()
  }
})

test('手填地址的非法项被静默丢弃，不会让插件起不来', async () => {
  const env = await boot({
    tiers: { tailscale: { enabled: true, addresses: ['不是IP', '100.1.2.3', '999.1.2.3'] } },
    extraAddresses: ['', '   ', '::not-a-url::'],
  })
  try {
    const tailscale = env.state.tiers.filter((item) => item.kind === 'tailscale')
    assert.equal(tailscale.length, 1, '只有合法的那一条能进来')
    assert.equal(tailscale[0].address, '100.1.2.3')
  } finally {
    env.disposeAll()
  }
})
