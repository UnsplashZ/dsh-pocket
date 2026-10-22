/**
 * 设备身份、挑战-应答、短期票据。
 *
 * 设计要点：**长期密钥不上明文网络**。
 *
 * 局域网是明文的（同一 Wi-Fi 下任何设备都能嗅探）。如果手机每次带一个长期 Bearer，
 * 嗅到一次就是永久授权。所以：
 *
 *   1. 配对时生成一把 per-device 的 32 字节 `secret`，只存在两端（电脑 0600 文件 / 手机 Keychain）；
 *   2. 每次连接用 `secret` 对 (deviceId, ts, nonce) 做 HMAC 应答，换一张 **900 秒**的票据；
 *   3. 之后所有请求带票据。票据泄露只有 15 分钟窗口，且绑 deviceId 可单独撤销。
 *
 * 票据是**无状态**的：`HMAC(serverKey, payload)`，服务端只验签不查表。
 * 撤销/轮换靠 `keyVersion` —— 提升版本号，所有在途票据立刻失效。
 */
import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto'
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'

/** 票据有效期。短到"泄露了也就 15 分钟"，长到不必每个请求都换。 */
export const TICKET_TTL_MS = 900_000
/** 客户端时钟允许的偏差。超过就拒，防重放。 */
export const MAX_SKEW_MS = 120_000
/** nonce 去重窗口，比 skew 稍长。 */
const NONCE_TTL_MS = 180_000
/** 认证失败限流：同 IP 10 次/分钟 → 封 5 分钟。 */
const FAIL_LIMIT = 10
const FAIL_WINDOW_MS = 60_000
const FAIL_BLOCK_MS = 300_000

const b64url = (buffer) => Buffer.from(buffer).toString('base64url')
const hmac = (key, data) => createHmac('sha256', key).update(data).digest()

/** 定长比较，避免按字节提前返回泄漏前缀。 */
function safeEqual(a, b) {
  const left = Buffer.from(a)
  const right = Buffer.from(b)
  if (left.length !== right.length) return false
  return timingSafeEqual(left, right)
}

/** 配对串里给人看的设备 id：短、无歧义、够唯一。 */
function newDeviceId() {
  return randomBytes(8).toString('hex')
}

export class DeviceStore {
  /**
   * @param {string} path 状态文件路径（不存在会创建；权限 0600）
   * @param {{now?: () => number, logger?: {warn: Function}}} [options]
   */
  constructor(path, { now = () => Date.now(), logger } = {}) {
    this.path = path
    this.now = now
    this.logger = logger
    this.state = null
    this.nonces = new Map()
    this.failures = new Map()
    this.loaded = false
  }

  /** 惰性加载：第一次用到才读盘，避免插件 apply 阶段就有 IO 失败风险。 */
  async load() {
    if (this.loaded) return this.state
    this.loaded = true
    try {
      const raw = await readFile(this.path, 'utf8')
      const parsed = JSON.parse(raw)
      if (parsed && typeof parsed === 'object' && typeof parsed.key === 'string') {
        this.state = {
          v: 1,
          key: parsed.key,
          keyVersion: Number.isInteger(parsed.keyVersion) ? parsed.keyVersion : 1,
          hostId: typeof parsed.hostId === 'string' && parsed.hostId !== '' ? parsed.hostId : newDeviceId(),
          devices: parsed.devices && typeof parsed.devices === 'object' ? parsed.devices : {},
        }
        return this.state
      }
      this.logger?.warn?.(`[uplink] 设备文件格式不认识，已重建：${this.path}`)
    } catch (error) {
      if (error?.code !== 'ENOENT') {
        this.logger?.warn?.(`[uplink] 读取设备文件失败，已重建：${error?.message ?? error}`)
      }
    }
    this.state = {
      v: 1,
      key: randomBytes(32).toString('hex'),
      keyVersion: 1,
      hostId: newDeviceId(),
      devices: {},
    }
    await this.save()
    return this.state
  }

  /**
   * 本机稳定 id。
   *
   * **不能**从签名密钥派生：轮换密钥是为了"把所有票据踢下线"，不该顺带改掉主机身份
   * （手机按 hostId 缓存清单与 lastGood）。所以它是独立持久化的一列。
   */
  async hostId() {
    const state = await this.load()
    return state.hostId
  }

  async save() {
    const dir = dirname(this.path)
    await mkdir(dir, { recursive: true })
    // 先写临时文件再 rename：中途崩溃不会留下半个 JSON 把所有人锁在门外。
    const temp = `${this.path}.${process.pid}.tmp`
    await writeFile(temp, `${JSON.stringify(this.state, null, 2)}\n`, { mode: 0o600 })
    await rename(temp, this.path)
  }

  async list() {
    const state = await this.load()
    return Object.entries(state.devices).map(([deviceId, device]) => ({
      deviceId,
      name: device.name,
      createdAt: device.createdAt,
      lastSeen: device.lastSeen ?? null,
      revoked: device.revoked === true,
    }))
  }

  /**
   * 登记一台新设备，返回**只能显示一次**的配对信息。
   *
   * `secret` 是明文返回给调用方（要打进配对串 / 二维码），但落盘时也存明文 ——
   * 因为验证 HMAC 需要原值。文件是 0600，与 tether 的 paired.json 同一信任级别。
   */
  async createDevice(name) {
    const state = await this.load()
    const deviceId = newDeviceId()
    const secret = randomBytes(32).toString('hex')
    state.devices[deviceId] = {
      name: String(name ?? '').trim() || '未命名设备',
      secret,
      createdAt: this.now(),
      lastSeen: null,
      revoked: false,
    }
    await this.save()
    return { deviceId, secret, name: state.devices[deviceId].name }
  }

  async revoke(deviceId) {
    const state = await this.load()
    if (!state.devices[deviceId]) return false
    state.devices[deviceId].revoked = true
    await this.save()
    return true
  }

  /**
   * 轮换服务端签名密钥：所有在途票据立刻失效，设备不必重新配对。
   * 用于"怀疑票据泄露"或"全部踢下线"。
   */
  async rotateKey() {
    const state = await this.load()
    state.key = randomBytes(32).toString('hex')
    state.keyVersion += 1
    await this.save()
    return state.keyVersion
  }

  // ── 限流 ──────────────────────────────────────────────────────────────

  /** @returns {number} 还要封多少毫秒；0 表示放行 */
  blockedFor(ip) {
    const entry = this.failures.get(ip)
    if (!entry) return 0
    const now = this.now()
    if (entry.blockedUntil && entry.blockedUntil > now) return entry.blockedUntil - now
    if (entry.blockedUntil && entry.blockedUntil <= now) {
      this.failures.delete(ip)
      return 0
    }
    if (now - entry.windowStart > FAIL_WINDOW_MS) {
      this.failures.delete(ip)
      return 0
    }
    return 0
  }

  noteFailure(ip) {
    const now = this.now()
    const entry = this.failures.get(ip)
    if (!entry || now - entry.windowStart > FAIL_WINDOW_MS) {
      this.failures.set(ip, { count: 1, windowStart: now, blockedUntil: 0 })
      return
    }
    entry.count += 1
    if (entry.count >= FAIL_LIMIT) entry.blockedUntil = now + FAIL_BLOCK_MS
  }

  // ── 挑战-应答 ─────────────────────────────────────────────────────────

  /** 客户端要算的应答。电脑端也用它做自检/单测。 */
  static proofFor({ secret, deviceId, ts, nonce }) {
    return hmac(Buffer.from(secret, 'hex'), `auth|${deviceId}|${ts}|${nonce}`).toString('hex')
  }

  /**
   * 验证一次认证请求。
   *
   * 顺序很重要：先看限流与时间戳（便宜且能挡掉大量垃圾），再算 HMAC（贵）。
   *
   * @returns {{ok: true, deviceId: string} | {ok: false, reason: string}}
   */
  async verifyProof({ deviceId, ts, nonce, proof }) {
    const state = await this.load()
    if (typeof deviceId !== 'string' || typeof nonce !== 'string' || typeof proof !== 'string') {
      return { ok: false, reason: 'bad-request' }
    }
    if (nonce.length < 8 || nonce.length > 128) return { ok: false, reason: 'bad-nonce' }
    const device = state.devices[deviceId]
    if (!device || device.revoked === true) return { ok: false, reason: 'unknown-device' }

    const now = this.now()
    const stamp = Number(ts)
    if (!Number.isFinite(stamp) || Math.abs(now - stamp) > MAX_SKEW_MS) {
      return { ok: false, reason: 'clock-skew' }
    }
    this.pruneNonces(now)
    if (this.nonces.has(nonce)) return { ok: false, reason: 'replayed' }

    const expected = DeviceStore.proofFor({ secret: device.secret, deviceId, ts: stamp, nonce })
    if (!safeEqual(expected, proof)) return { ok: false, reason: 'bad-proof' }

    this.nonces.set(nonce, now + NONCE_TTL_MS)
    device.lastSeen = now
    await this.save()
    return { ok: true, deviceId }
  }

  pruneNonces(now) {
    for (const [nonce, expiry] of this.nonces) {
      if (expiry <= now) this.nonces.delete(nonce)
    }
  }

  // ── 票据 ──────────────────────────────────────────────────────────────

  /** 签一张票据。返回的 `ttl` 是毫秒。 */
  async issueTicket(deviceId) {
    const state = await this.load()
    const payload = b64url(JSON.stringify({
      d: deviceId,
      e: this.now() + TICKET_TTL_MS,
      v: state.keyVersion,
    }))
    const signature = hmac(Buffer.from(state.key, 'hex'), payload).toString('hex')
    return { ticket: `${payload}.${signature}`, ttl: TICKET_TTL_MS }
  }

  /**
   * 验票。**不查设备表**（除了撤销检查）—— 这样每个请求的开销只是一次 HMAC。
   *
   * @returns {{ok: true, deviceId: string, name: string} | {ok: false, reason: string}}
   */
  async verifyTicket(ticket) {
    if (typeof ticket !== 'string' || ticket.length === 0 || ticket.length > 512) {
      return { ok: false, reason: 'bad-ticket' }
    }
    const dot = ticket.lastIndexOf('.')
    if (dot <= 0) return { ok: false, reason: 'bad-ticket' }
    const payload = ticket.slice(0, dot)
    const signature = ticket.slice(dot + 1)
    const state = await this.load()
    const expected = hmac(Buffer.from(state.key, 'hex'), payload).toString('hex')
    if (!safeEqual(expected, signature)) return { ok: false, reason: 'bad-signature' }

    let claims
    try {
      claims = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'))
    } catch {
      return { ok: false, reason: 'bad-payload' }
    }
    if (claims?.v !== state.keyVersion) return { ok: false, reason: 'stale-key' }
    if (typeof claims.e !== 'number' || claims.e <= this.now()) return { ok: false, reason: 'expired' }
    const device = state.devices[claims.d]
    if (!device || device.revoked === true) return { ok: false, reason: 'unknown-device' }
    return { ok: true, deviceId: claims.d, name: device.name }
  }
}
