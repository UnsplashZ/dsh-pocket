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
