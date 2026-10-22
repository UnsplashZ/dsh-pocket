import assert from 'node:assert/strict'
import { mkdtemp, readFile, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import { DeviceStore, MAX_SKEW_MS, TICKET_TTL_MS } from '../lib/auth.js'

async function makeStore({ now } = {}) {
  const dir = await mkdtemp(join(tmpdir(), 'uplink-auth-'))
  const clock = { t: 1_700_000_000_000 }
  const store = new DeviceStore(join(dir, 'state.json'), { now: now ?? (() => clock.t) })
  await store.load()
  return { store, clock, path: join(dir, 'state.json') }
}

/** 走一遍"配对 → 算应答 → 换票"的完整流程。 */
async function pairAndAuth(store, clock, name = '手机') {
  const device = await store.createDevice(name)
  const nonce = 'abcdef0123456789'
  const ts = clock.t
  const proof = DeviceStore.proofFor({ secret: device.secret, deviceId: device.deviceId, ts, nonce })
  const verified = await store.verifyProof({ deviceId: device.deviceId, ts, nonce, proof })
  assert.equal(verified.ok, true)
  return { device, nonce, ts, proof }
}

test('状态文件权限是 0600，且 hostId 持久化', async () => {
  const { store, path } = await makeStore()
  const hostId = await store.hostId()
  assert.match(hostId, /^[0-9a-f]{16}$/)
  const mode = (await stat(path)).mode & 0o777
  assert.equal(mode, 0o600)
  const reloaded = new DeviceStore(path)
  assert.equal(await reloaded.hostId(), hostId)
})

test('轮换密钥不改 hostId（手机按 hostId 缓存清单与 lastGood）', async () => {
  const { store } = await makeStore()
  const before = await store.hostId()
  await store.rotateKey()
  assert.equal(await store.hostId(), before)
})

test('正确的应答能换到票据，票据能验回设备', async () => {
  const { store, clock } = await makeStore()
  const { device } = await pairAndAuth(store, clock)
  const { ticket, ttl } = await store.issueTicket(device.deviceId)
  assert.equal(ttl, TICKET_TTL_MS)
  const verified = await store.verifyTicket(ticket)
  assert.equal(verified.ok, true)
  assert.equal(verified.deviceId, device.deviceId)
  assert.equal(verified.name, '手机')
})

test('应答错误 → bad-proof', async () => {
  const { store, clock } = await makeStore()
  const device = await store.createDevice('手机')
  const result = await store.verifyProof({
    deviceId: device.deviceId,
    ts: clock.t,
    nonce: 'abcdef0123456789',
    proof: 'deadbeef',
  })
  assert.equal(result.ok, false)
  assert.equal(result.reason, 'bad-proof')
})

test('时间戳偏差过大 → clock-skew（防重放）', async () => {
  const { store, clock } = await makeStore()
  const device = await store.createDevice('手机')
  const ts = clock.t - MAX_SKEW_MS - 1
  const nonce = 'abcdef0123456789'
  const proof = DeviceStore.proofFor({ secret: device.secret, deviceId: device.deviceId, ts, nonce })
  const result = await store.verifyProof({ deviceId: device.deviceId, ts, nonce, proof })
  assert.equal(result.ok, false)
  assert.equal(result.reason, 'clock-skew')
})

test('同一个 nonce 不能用第二次 → replayed', async () => {
  const { store, clock } = await makeStore()
  const { device, nonce, ts, proof } = await pairAndAuth(store, clock)
  const again = await store.verifyProof({ deviceId: device.deviceId, ts, nonce, proof })
  assert.equal(again.ok, false)
  assert.equal(again.reason, 'replayed')
})

test('撤销设备后：既不能认证，旧票据也立刻失效', async () => {
  const { store, clock } = await makeStore()
  const { device } = await pairAndAuth(store, clock)
  const { ticket } = await store.issueTicket(device.deviceId)
  assert.equal((await store.verifyTicket(ticket)).ok, true)

  assert.equal(await store.revoke(device.deviceId), true)
  assert.equal((await store.verifyTicket(ticket)).ok, false)

  const nonce = 'fedcba9876543210'
  const proof = DeviceStore.proofFor({ secret: device.secret, deviceId: device.deviceId, ts: clock.t, nonce })
  const result = await store.verifyProof({ deviceId: device.deviceId, ts: clock.t, nonce, proof })
  assert.equal(result.ok, false)
  assert.equal(result.reason, 'unknown-device')
})

test('票据过期 → expired', async () => {
  const { store, clock } = await makeStore()
  const { device } = await pairAndAuth(store, clock)
  const { ticket } = await store.issueTicket(device.deviceId)
  clock.t += TICKET_TTL_MS + 1
  const result = await store.verifyTicket(ticket)
  assert.equal(result.ok, false)
  assert.equal(result.reason, 'expired')
})

test('轮换密钥后所有在途票据失效（stale-key），设备无需重新配对', async () => {
  const { store, clock } = await makeStore()
  const { device } = await pairAndAuth(store, clock)
  const { ticket } = await store.issueTicket(device.deviceId)
  await store.rotateKey()
  assert.equal((await store.verifyTicket(ticket)).ok, false)

  // 密钥轮换后同一台设备仍能换到新票
  const nonce = '1122334455667788'
  const proof = DeviceStore.proofFor({ secret: device.secret, deviceId: device.deviceId, ts: clock.t, nonce })
  assert.equal((await store.verifyProof({ deviceId: device.deviceId, ts: clock.t, nonce, proof })).ok, true)
  const fresh = await store.issueTicket(device.deviceId)
  assert.equal((await store.verifyTicket(fresh.ticket)).ok, true)
})

test('篡改票据 → bad-signature', async () => {
  const { store, clock } = await makeStore()
  const { device } = await pairAndAuth(store, clock)
  const { ticket } = await store.issueTicket(device.deviceId)
  const [payload, signature] = ticket.split('.')
  const flipped = signature.startsWith('a') ? `b${signature.slice(1)}` : `a${signature.slice(1)}`
  const result = await store.verifyTicket(`${payload}.${flipped}`)
  assert.equal(result.ok, false)
  assert.equal(result.reason, 'bad-signature')
})

test('同 IP 连续失败 10 次后被封，且封禁有期限', async () => {
  const { store, clock } = await makeStore()
  const ip = '10.0.0.9'
  for (let index = 0; index < 9; index += 1) {
    store.noteFailure(ip)
    assert.equal(store.blockedFor(ip), 0, `第 ${index + 1} 次失败后还不该封`)
  }
  store.noteFailure(ip)
  const blocked = store.blockedFor(ip)
  assert.ok(blocked > 0, '第 10 次失败后应被封')
  clock.t += blocked + 1
  assert.equal(store.blockedFor(ip), 0, '封禁到期后自动放行')
})

test('状态文件损坏时重建，而不是让插件起不来', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'uplink-auth-'))
  const path = join(dir, 'state.json')
  const { writeFile } = await import('node:fs/promises')
  await writeFile(path, '{ not json', { mode: 0o600 })
  const store = new DeviceStore(path)
  const state = await store.load()
  assert.equal(typeof state.key, 'string')
  assert.match(await readFile(path, 'utf8'), /"key"/)
})
