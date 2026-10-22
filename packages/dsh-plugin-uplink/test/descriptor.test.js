import assert from 'node:assert/strict'
import test from 'node:test'

import {
  buildDescriptor,
  decodePairingPayload,
  DESCRIPTOR_TTL_MS,
  encodePairingPayload,
  PAIRING_SCHEME,
  publicIdentity,
} from '../lib/descriptor.js'

test('清单按优先级排序，并带上 ttl', () => {
  const descriptor = buildDescriptor({
    hostId: 'abcd1234',
    name: 'MacBook Pro',
    port: 18788,
    tiers: [
      { kind: 'frp', url: 'https://dsh.example.com' },
      { kind: 'lan', url: 'http://10.8.54.221:18788' },
      { kind: 'tailscale', url: 'http://100.101.2.3:18788' },
    ],
    now: 1_700_000_000_000,
  })
  assert.equal(descriptor.v, 1)
  assert.equal(descriptor.ttl, DESCRIPTOR_TTL_MS)
  assert.deepEqual(descriptor.tiers.map((tier) => tier.kind), ['lan', 'tailscale', 'frp'])
  assert.deepEqual(descriptor.tiers.map((tier) => tier.prio), [10, 20, 40])
})

test('清单里可以带 TLS 指纹，但不带任何密钥', () => {
  const descriptor = buildDescriptor({
    hostId: 'abcd1234',
    port: 18788,
    tiers: [{ kind: 'frp', url: 'https://dsh.example.com', tls: { sha256: 'AB:CD' } }],
  })
  assert.deepEqual(descriptor.tiers[0].tls, { sha256: 'AB:CD' })
  assert.equal(JSON.stringify(descriptor).includes('secret'), false)
})

test('公开身份只给 hostId / name / 版本，不泄露档位与地址', () => {
  const identity = publicIdentity({ hostId: 'abcd1234', name: 'Mac', version: '0.1.0' })
  assert.deepEqual(identity, { v: 1, hostId: 'abcd1234', name: 'Mac', version: '0.1.0' })
  assert.equal('tiers' in identity, false)
})

test('配对串可以往返', () => {
  const secret = 'a'.repeat(64)
  const text = encodePairingPayload({
    hostId: 'abcd1234',
    name: 'MacBook Pro',
    port: 18788,
    deviceId: '0123456789abcdef',
    secret,
    urls: ['http://10.8.54.221:18788'],
  })
  assert.ok(text.startsWith(PAIRING_SCHEME))
  const decoded = decodePairingPayload(text)
  assert.equal(decoded.ok, true)
  assert.equal(decoded.payload.hostId, 'abcd1234')
  assert.equal(decoded.payload.deviceId, '0123456789abcdef')
  assert.equal(decoded.payload.secret, secret)
  assert.deepEqual(decoded.payload.urls, ['http://10.8.54.221:18788'])
})

test('配对串允许前后有空白（从终端里复制粘贴）', () => {
  const text = encodePairingPayload({
    hostId: 'abcd1234', port: 1, deviceId: 'd', secret: 'b'.repeat(64),
  })
  assert.equal(decodePairingPayload(`  ${text}\n`).ok, true)
})

test('各种非法输入都返回 ok:false，不抛', () => {
  assert.equal(decodePairingPayload(undefined).ok, false)
  assert.equal(decodePairingPayload('hello').ok, false)
  assert.equal(decodePairingPayload(`${PAIRING_SCHEME}!!!`).ok, false)
  // 版本不对
  const wrongVersion = `${PAIRING_SCHEME}${Buffer.from(JSON.stringify({ v: 99 })).toString('base64url')}`
  assert.equal(decodePairingPayload(wrongVersion).reason, 'bad-version')
  // secret 长度不对
  const badSecret = `${PAIRING_SCHEME}${Buffer.from(JSON.stringify({
    v: 1, hostId: 'a', deviceId: 'b', secret: 'short',
  })).toString('base64url')}`
  assert.equal(decodePairingPayload(badSecret).reason, 'bad-secret')
})

test('配对串带档位名：urls 之外还有 tiers，手机才能逐档开关', () => {
  const text = encodePairingPayload({
    hostId: 'abcd1234',
    port: 18788,
    deviceId: 'd1',
    secret: 'c'.repeat(64),
    urls: ['http://10.8.54.221:18788', 'http://10.147.20.5:18788', 'https://dsh.example.com'],
    tiers: [
      { kind: 'lan', url: 'http://10.8.54.221:18788' },
      { kind: 'zerotier', url: 'http://10.147.20.5:18788' },
      { kind: 'frp', url: 'https://dsh.example.com' },
    ],
  })
  const decoded = decodePairingPayload(text)
  assert.equal(decoded.ok, true)
  assert.deepEqual(decoded.payload.tiers, [
    { kind: 'lan', url: 'http://10.8.54.221:18788' },
    { kind: 'zerotier', url: 'http://10.147.20.5:18788' },
    { kind: 'frp', url: 'https://dsh.example.com' },
  ])
  // urls 仍然在（兼容只认地址的旧客户端）
  assert.equal(decoded.payload.urls.length, 3)
})

test('配对串里的非法档位名会被丢掉，不会让整串解析失败', () => {
  const text = encodePairingPayload({
    hostId: 'abcd1234', port: 1, deviceId: 'd', secret: 'e'.repeat(64),
    urls: ['http://10.0.0.1:1'],
    tiers: [
      { kind: 'lan', url: 'http://10.0.0.1:1' },
      { kind: 'evil', url: 'http://10.0.0.2:1' },
      { kind: 'lan' },
    ],
  })
  const decoded = decodePairingPayload(text)
  assert.deepEqual(decoded.payload.tiers, [{ kind: 'lan', url: 'http://10.0.0.1:1' }])
})

test('没带 tiers 的老配对串仍能解析，tiers 退化成空数组', () => {
  const text = `${PAIRING_SCHEME}${Buffer.from(JSON.stringify({
    v: 1, hostId: 'h', deviceId: 'd', secret: 'f'.repeat(64), urls: ['http://10.0.0.1:1'],
  })).toString('base64url')}`
  const decoded = decodePairingPayload(text)
  assert.equal(decoded.ok, true)
  assert.deepEqual(decoded.payload.tiers, [])
  assert.deepEqual(decoded.payload.urls, ['http://10.0.0.1:1'])
})

test('配对串里带 iroh 的一次性配对码 —— 绕开"要票才能要码"的死锁', () => {
  const text = encodePairingPayload({
    hostId: 'abcd1234',
    port: 18788,
    deviceId: 'd1',
    secret: 'a'.repeat(64),
    urls: ['http://10.0.0.5:18788'],
    iroh: { endpointId: 'e'.repeat(64), relay: null, code: '123456', expiresAt: 1_700_000_600_000 },
  })
  const decoded = decodePairingPayload(text)
  assert.equal(decoded.ok, true)
  assert.equal(decoded.payload.iroh.endpointId, 'e'.repeat(64))
  assert.equal(decoded.payload.iroh.code, '123456')
  assert.equal(decoded.payload.iroh.expiresAt, 1_700_000_600_000)
})

test('没有 iroh 码时字段是 null，而不是缺失（手机侧好判断）', () => {
  const text = encodePairingPayload({
    hostId: 'abcd1234', port: 1, deviceId: 'd', secret: 'b'.repeat(64),
    iroh: { endpointId: 'f'.repeat(64), relay: 'https://relay.example' },
  })
  const decoded = decodePairingPayload(text)
  assert.equal(decoded.payload.iroh.code, null)
  assert.equal(decoded.payload.iroh.expiresAt, null)
  assert.equal(decoded.payload.iroh.relay, 'https://relay.example')
})
