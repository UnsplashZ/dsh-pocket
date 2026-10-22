import assert from 'node:assert/strict'
import http from 'node:http'
import net from 'node:net'
import { mkdtemp } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import { DeviceStore } from '../lib/auth.js'
import { createGateway } from '../lib/gateway.js'

/**
 * 起一套"假 dsh + 真网关"。
 *
 * 上游记录它看到的每个请求，这样能断言"网关到底把什么交给了 dsh" ——
 * 特别是 cookie 注入与 Host 改写，那是整条链路能成立的前提。
 */
async function harness({ cookie = { cookie: 'session=abc123', authority: '127.0.0.1:1' } } = {}) {
  const seen = []
  // 升级过的连接不会被 closeAllConnections 覆盖（Node 的已知行为），得自己记账
  const upstreamSockets = new Set()
  const upstream = http.createServer((req, res) => {
    seen.push({ url: req.url, method: req.method, headers: req.headers })
    if (req.url === '/big') {
      res.writeHead(200, { 'content-type': 'text/plain' })
      res.end('x'.repeat(4096))
      return
    }
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ ok: true, path: req.url }))
  })
  // 假 WS：101 之后把收到的字节原样回显
  upstream.on('upgrade', (req, socket) => {
    seen.push({ url: req.url, method: 'UPGRADE', headers: req.headers })
    socket.write('HTTP/1.1 101 Switching Protocols\r\nupgrade: websocket\r\nconnection: Upgrade\r\n\r\n')
    socket.on('data', (chunk) => socket.write(chunk))
  })
  upstream.on('connection', (socket) => {
    upstreamSockets.add(socket)
    socket.on('close', () => upstreamSockets.delete(socket))
  })
  await new Promise((resolve) => upstream.listen(0, '127.0.0.1', resolve))
  const upstreamPort = upstream.address().port

  const dir = await mkdtemp(join(tmpdir(), 'uplink-gw-'))
  const store = new DeviceStore(join(dir, 'state.json'))
  await store.load()

  let cookieValue = cookie
  const gateway = createGateway({
    target: { host: '127.0.0.1', port: upstreamPort },
    store,
    cookie: { get: () => cookieValue, status: () => ({ ready: cookieValue !== null }) },
    identity: { hostId: 'testhost', name: 'Test Mac', version: '0.1.0' },
    logger: { info: () => {}, warn: () => {} },
    tierOfAddress: () => 'lan',
    openIrohPairing: async () => ({
      endpointId: 'a'.repeat(64),
      pairingString: `${'a'.repeat(64)}#123456`,
      expiresInSec: 600,
    }),
    descriptor: async () => ({
      v: 1,
      hostId: 'testhost',
      name: 'Test Mac',
      port: 18788,
      tiers: [{ kind: 'lan', url: 'http://10.0.0.9:18788', prio: 10 }],
      issuedAt: 1,
      ttl: 300000,
    }),
  })
  const bound = await gateway.listen({ port: 0, bind: '127.0.0.1' })
  const base = `http://127.0.0.1:${bound.port}`

  return {
    seen,
    store,
    gateway,
    base,
    port: bound.port,
    setCookie: (value) => { cookieValue = value },
    async close() {
      await gateway.close()
      for (const socket of upstreamSockets) {
        try {
          socket.destroy()
        } catch {
          // 已经断了
        }
      }
      upstreamSockets.clear()
      upstream.closeAllConnections?.()
      await new Promise((resolve) => {
        upstream.close(resolve)
        setTimeout(resolve, 2000)
      })
    },
  }
}

/** 配对一台设备并换到票。 */
async function pair(store, name = '手机') {
  const device = await store.createDevice(name)
  return device
}

async function authenticate(base, device) {
  const ts = Date.now()
  const nonce = `n-${Math.random().toString(16).slice(2)}`
  const proof = DeviceStore.proofFor({ secret: device.secret, deviceId: device.deviceId, ts, nonce })
  const response = await fetch(`${base}/uplink/auth`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ deviceId: device.deviceId, ts, nonce, proof }),
  })
  return { status: response.status, body: await response.json() }
}

test('ping 与 hello 免票，且 hello 不泄露档位与地址', async () => {
  const env = await harness()
  try {
    const ping = await fetch(`${env.base}/uplink/ping`)
    assert.equal(ping.status, 200)
    const pingBody = await ping.json()
    assert.equal(pingBody.ok, true)
    assert.equal(pingBody.hostId, 'testhost')

    const hello = await fetch(`${env.base}/uplink/hello`)
    const helloBody = await hello.json()
    assert.deepEqual(helloBody, { ok: true, v: 1, hostId: 'testhost', name: 'Test Mac', version: '0.1.0' })
  } finally {
    await env.close()
  }
})

test('没有票据访问真实路径 → 401', async () => {
  const env = await harness()
  try {
    const response = await fetch(`${env.base}/api/sessions`)
    assert.equal(response.status, 401)
    assert.equal((await response.json()).reason, 'no-ticket')
    // 关键：未认证请求不能到达 dsh
    assert.equal(env.seen.length, 0)
  } finally {
    await env.close()
  }
})

test('换票 → 带票访问 → dsh 收到注入的 cookie、改写后的 Host 与设备名', async () => {
  const env = await harness()
  try {
    const device = await pair(env.store, 'M的 iPhone')
    const auth = await authenticate(env.base, device)
    assert.equal(auth.status, 200)
    assert.ok(auth.body.ticket.includes('.'))
    assert.equal(auth.body.ttl, 900_000)

    const response = await fetch(`${env.base}/api/sessions?limit=5`, {
      headers: { authorization: `Bearer ${auth.body.ticket}` },
    })
    assert.equal(response.status, 200)
    assert.equal((await response.json()).path, '/api/sessions?limit=5')

    const request = env.seen.at(-1)
    assert.equal(request.headers.cookie, 'session=abc123')
    assert.equal(request.headers.host, '127.0.0.1:1')
    assert.equal(request.headers['x-dsh-device'], encodeURIComponent('M的 iPhone'))
    // 网关的票据绝不能透给 dsh：它只认自己的 cookie
    assert.equal(request.headers.authorization, undefined)
  } finally {
    await env.close()
  }
})

test('应答错误 → 401 bad-proof，且请求到不了 dsh', async () => {
  const env = await harness()
  try {
    const device = await pair(env.store)
    const response = await fetch(`${env.base}/uplink/auth`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ deviceId: device.deviceId, ts: Date.now(), nonce: 'n-aaaaaaaa', proof: 'ff' }),
    })
    assert.equal(response.status, 401)
    assert.equal((await response.json()).reason, 'bad-proof')
    assert.equal(env.seen.length, 0)
  } finally {
    await env.close()
  }
})

test('cookie 拿不到时返回 502 与一句人话，而不是让手机以为密钥错了', async () => {
  const env = await harness({ cookie: null })
  try {
    const device = await pair(env.store)
    const auth = await authenticate(env.base, device)
    const response = await fetch(`${env.base}/`, { headers: { authorization: `Bearer ${auth.body.ticket}` } })
    assert.equal(response.status, 502)
    const text = await response.text()
    assert.match(text, /电脑端认证失败/)
    assert.equal(env.seen.length, 0)
  } finally {
    await env.close()
  }
})

test('撤销设备后旧票据立刻失效', async () => {
  const env = await harness()
  try {
    const device = await pair(env.store)
    const auth = await authenticate(env.base, device)
    assert.equal((await fetch(`${env.base}/x`, { headers: { authorization: `Bearer ${auth.body.ticket}` } })).status, 200)
    await env.store.revoke(device.deviceId)
    const after = await fetch(`${env.base}/x`, { headers: { authorization: `Bearer ${auth.body.ticket}` } })
    assert.equal(after.status, 401)
  } finally {
    await env.close()
  }
})

test('大响应完整透传（不做缓冲截断）', async () => {
  const env = await harness()
  try {
    const device = await pair(env.store)
    const auth = await authenticate(env.base, device)
    const response = await fetch(`${env.base}/big`, { headers: { authorization: `Bearer ${auth.body.ticket}` } })
    const text = await response.text()
    assert.equal(text.length, 4096)
  } finally {
    await env.close()
  }
})

/** 裸 socket 发一次 WS 握手，返回 {statusLine, echoed}。 */
function upgradeRaw({ port, path, headers }) {
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, '127.0.0.1', () => {
      const lines = [
        `GET ${path} HTTP/1.1`,
        `Host: 127.0.0.1:${port}`,
        'Connection: Upgrade',
        'Upgrade: websocket',
        'Sec-WebSocket-Version: 13',
        'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==',
        ...Object.entries(headers).map(([key, value]) => `${key}: ${value}`),
        '',
        '',
      ]
      socket.write(lines.join('\r\n'))
    })
    let buffer = ''
    let statusLine = null
    let sentPing = false
    const timer = setTimeout(() => {
      socket.destroy()
      reject(new Error(`upgrade timeout; got: ${buffer.slice(0, 200)}`))
    }, 4000)
    socket.on('data', (chunk) => {
      buffer += chunk.toString('latin1')
      if (statusLine === null && buffer.includes('\r\n\r\n')) {
        statusLine = buffer.split('\r\n')[0]
        buffer = buffer.slice(buffer.indexOf('\r\n\r\n') + 4)
        if (!sentPing && statusLine.includes('101')) {
          sentPing = true
          socket.write('hello-through-gateway')
        }
      } else if (statusLine !== null && buffer.includes('hello-through-gateway')) {
        clearTimeout(timer)
        socket.destroy()
        resolve({ statusLine, echoed: 'hello-through-gateway' })
      }
    })
    socket.on('error', (error) => {
      clearTimeout(timer)
      reject(error)
    })
    // 被直接关掉（401 之后网关 destroy 连接）也要落地，否则测试会挂住
    socket.on('close', () => {
      clearTimeout(timer)
      reject(new Error(`socket closed; status: ${statusLine ?? '(none)'}`))
    })
  })
}

test('WebSocket 升级：带票放行并双向透传', async () => {
  const env = await harness()
  try {
    const device = await pair(env.store)
    const auth = await authenticate(env.base, device)
    const result = await upgradeRaw({
      port: env.port,
      path: '/api/stream',
      headers: { Authorization: `Bearer ${auth.body.ticket}` },
    })
    assert.match(result.statusLine, /101/)
    const upgrade = env.seen.at(-1)
    assert.equal(upgrade.method, 'UPGRADE')
    assert.equal(upgrade.headers.cookie, 'session=abc123')
    assert.equal(upgrade.headers.authorization, undefined)
  } finally {
    await env.close()
  }
})

test('WebSocket 升级：没票直接 401，不碰 dsh', async () => {
  const env = await harness()
  try {
    await assert.rejects(
      upgradeRaw({ port: env.port, path: '/api/stream', headers: {} }),
      (error) => {
        // 握手被拒：网关要么回一个 401 再断开，要么直接断开
        assert.match(String(error.message), /timeout|ECONNRESET|socket closed/)
        return true
      },
    )
    assert.equal(env.seen.length, 0)
  } finally {
    await env.close()
  }
})

test('端口被占用时自动顺延，而不是起不来', async () => {
  const blocker = http.createServer((req, res) => res.end('x'))
  await new Promise((resolve) => blocker.listen(0, '127.0.0.1', resolve))
  const taken = blocker.address().port
  const dir = await mkdtemp(join(tmpdir(), 'uplink-gw-'))
  const store = new DeviceStore(join(dir, 'state.json'))
  const gateway = createGateway({
    target: { host: '127.0.0.1', port: 1 },
    store,
    cookie: { get: () => null },
    identity: { hostId: 'h', name: 'n', version: '0' },
  })
  try {
    const bound = await gateway.listen({ port: taken, bind: '127.0.0.1' })
    assert.notEqual(bound.port, taken)
    assert.ok(bound.port > taken)
  } finally {
    await gateway.close()
    await new Promise((resolve) => blocker.close(resolve))
  }
})


test('清单路由：没票 401，有票拿到当前地址列表（配对串只是快照）', async () => {
  const env = await harness()
  try {
    const unauth = await fetch(`${env.base}/uplink/descriptor`)
    assert.equal(unauth.status, 401)

    const device = await pair(env.store)
    const auth = await authenticate(env.base, device)
    const response = await fetch(`${env.base}/uplink/descriptor`, {
      headers: { authorization: `Bearer ${auth.body.ticket}` },
    })
    assert.equal(response.status, 200)
    const body = await response.json()
    assert.equal(body.ok, true)
    assert.equal(body.hostId, 'testhost')
    assert.deepEqual(body.tiers, [{ kind: 'lan', url: 'http://10.0.0.9:18788', prio: 10 }])
    // 清单绝不能带密钥
    assert.equal(JSON.stringify(body).includes('secret'), false)
    // 它不该被当成普通请求转发给 dsh
    assert.equal(env.seen.length, 0)
  } finally {
    await env.close()
  }
})

test('清单算不出来时给 500，而不是把网关拖挂', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'uplink-gw-'))
  const store = new DeviceStore(join(dir, 'state.json'))
  await store.load()
  const gateway = createGateway({
    target: { host: '127.0.0.1', port: 1 },
    store,
    cookie: { get: () => ({ cookie: 'session=x', authority: '127.0.0.1:1' }) },
    identity: { hostId: 'h', name: 'n', version: '0' },
    logger: { info: () => {}, warn: () => {} },
    descriptor: async () => { throw new Error('环境探测炸了') },
  })
  const bound = await gateway.listen({ port: 0, bind: '127.0.0.1' })
  try {
    const device = await store.createDevice('手机')
    const ts = Date.now()
    const nonce = `n-${Math.random().toString(16).slice(2)}`
    const proof = DeviceStore.proofFor({ secret: device.secret, deviceId: device.deviceId, ts, nonce })
    const auth = await (await fetch(`http://127.0.0.1:${bound.port}/uplink/auth`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ deviceId: device.deviceId, ts, nonce, proof }),
    })).json()
    const response = await fetch(`http://127.0.0.1:${bound.port}/uplink/descriptor`, {
      headers: { authorization: `Bearer ${auth.ticket}` },
    })
    assert.equal(response.status, 500)
    assert.equal((await response.json()).reason, 'descriptor-failed')
    // 网关还活着
    assert.equal((await fetch(`http://127.0.0.1:${bound.port}/uplink/ping`)).status, 200)
  } finally {
    await gateway.close()
  }
})



test('iroh 配对码：没票 401、GET 405、有票拿到 endpointId#code', async () => {
  const env = await harness()
  try {
    assert.equal((await fetch(`${env.base}/uplink/iroh-pairing`, { method: 'POST' })).status, 401)

    const device = await pair(env.store)
    const auth = await authenticate(env.base, device)

    const wrongMethod = await fetch(`${env.base}/uplink/iroh-pairing`, {
      headers: { authorization: `Bearer ${auth.body.ticket}` },
    })
    assert.equal(wrongMethod.status, 405)

    const response = await fetch(`${env.base}/uplink/iroh-pairing`, {
      method: 'POST',
      headers: { authorization: `Bearer ${auth.body.ticket}` },
    })
    assert.equal(response.status, 200)
    const body = await response.json()
    assert.equal(body.ok, true)
    assert.equal(body.endpointId, 'a'.repeat(64))
    assert.equal(body.pairingString, `${'a'.repeat(64)}#123456`)
    assert.equal(body.expiresInSec, 600)
    // 这条不该被当成普通请求转给 dsh
    assert.equal(env.seen.length, 0)
  } finally {
    await env.close()
  }
})

test('iroh 不可用时给 503，而不是让手机拿着空配对码去试', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'uplink-gw-'))
  const store = new DeviceStore(join(dir, 'state.json'))
  await store.load()
  const gateway = createGateway({
    target: { host: '127.0.0.1', port: 1 },
    store,
    cookie: { get: () => ({ cookie: 'session=x', authority: '127.0.0.1:1' }) },
    identity: { hostId: 'h', name: 'n', version: '0' },
    logger: { info: () => {}, warn: () => {} },
    openIrohPairing: async () => null,
  })
  const bound = await gateway.listen({ port: 0, bind: '127.0.0.1' })
  try {
    const device = await store.createDevice('手机')
    const ts = Date.now()
    const nonce = `n-${Math.random().toString(16).slice(2)}`
    const proof = DeviceStore.proofFor({ secret: device.secret, deviceId: device.deviceId, ts, nonce })
    const auth = await (await fetch(`http://127.0.0.1:${bound.port}/uplink/auth`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ deviceId: device.deviceId, ts, nonce, proof }),
    })).json()
    const response = await fetch(`http://127.0.0.1:${bound.port}/uplink/iroh-pairing`, {
      method: 'POST',
      headers: { authorization: `Bearer ${auth.ticket}` },
    })
    assert.equal(response.status, 503)
    assert.equal((await response.json()).reason, 'iroh-unavailable')
  } finally {
    await gateway.close()
  }
})
