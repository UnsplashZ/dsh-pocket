/**
 * 清单（descriptor）与配对串。
 *
 * 清单是**手机侧唯一的输入**：它说"这台电脑能从哪几个地址到达"。手机不猜地址、
 * 不扫网段、不问用户 —— 拿到清单就并行探一下，谁先通就用谁。
 *
 * 清单里**不含任何密钥**，可以走明文（Bonjour 引导、二维码）。密钥只在配对串里，
 * 而配对串是一次性的、只在电脑屏幕上出现。
 */
import { priorityOf } from './config.js'

export const DESCRIPTOR_VERSION = 1
export const PAIRING_SCHEME = 'dshuplink://'
/** 清单的软有效期。过期后手机仍可用旧清单（离线优先），但会标注"可能已过期"。 */
export const DESCRIPTOR_TTL_MS = 300_000

/**
 * 构造清单。
 *
 * @param {object} input
 * @param {string} input.hostId 本机稳定 id（首次运行生成，存在状态文件里）
 * @param {string} [input.name] 电脑名，手机侧显示用
 * @param {number} input.port 网关实际监听端口
 * @param {Array<{kind: string, url: string, tls?: object}>} input.tiers
 * @param {number} [input.now]
 */
export function buildDescriptor({ hostId, name = '', port, tiers = [], now = Date.now() }) {
  const sorted = [...tiers]
    .map((tier) => ({
      kind: tier.kind,
      // iroh 档位没有 url（它是 QUIC + endpointId），所以 url 是可选的 ——
      // 但 lan/tailscale/zerotier/frp 必须有，缺了就是配置错误，宁可少一档也别发个点不开的地址
      ...(tier.url ? { url: tier.url } : {}),
      prio: tier.prio ?? priorityOf(tier.kind),
      ...(tier.tls ? { tls: tier.tls } : {}),
      ...(tier.endpointId ? { endpointId: tier.endpointId } : {}),
      ...(tier.relay ? { relay: tier.relay } : {}),
    }))
    .filter((tier) => tier.kind === 'iroh' || typeof tier.url === 'string')
    .sort((a, b) => a.prio - b.prio)
  return {
    v: DESCRIPTOR_VERSION,
    hostId,
    name,
    port,
    tiers: sorted,
    issuedAt: now,
    ttl: DESCRIPTOR_TTL_MS,
  }
}

/**
 * 只保留"可以给未认证请求看"的字段。
 *
 * `/uplink/hello` 用它：让手机确认"这个地址上是哪台电脑"，但**不泄露**有哪些档位、
 * 更不泄露地址 —— 否则局域网里任何人扫一遍就知道你的 Tailscale 地址与 frp 域名。
 */
export function publicIdentity({ hostId, name = '', version = '' }) {
  return { v: DESCRIPTOR_VERSION, hostId, name, version }
}

/**
 * 配对串。整段可复制/可打成二维码，手机扫一次就完成引导。
 *
 * 内容 = 设备身份（一次性）+ 此刻算出来的地址清单。手机存下 secret，之后所有档位
 * 都用它换票；地址过期了也不影响（换网后重新拉清单即可）。
 */
export function encodePairingPayload({
  hostId,
  name = '',
  port,
  deviceId,
  secret,
  urls = [],
  iroh = null,
  now = Date.now(),
}) {
  const payload = {
    v: DESCRIPTOR_VERSION,
    hostId,
    name,
    port,
    deviceId,
    secret,
    urls,
    // iroh 兜底档的寻址信息：endpointId + relay。配对**码**不放在这里 ——
    // 它只有几分钟有效期，塞进长期保存的配对串里只会变成一个过期的坑。
    ...(iroh ? { iroh } : {}),
    issuedAt: now,
  }
  return `${PAIRING_SCHEME}${Buffer.from(JSON.stringify(payload), 'utf8').toString('base64url')}`
}

/**
 * 解析配对串。任何不合规都返回 `{ok:false}`，不抛 —— 用户粘贴错东西是常态。
 */
export function decodePairingPayload(text) {
  if (typeof text !== 'string') return { ok: false, reason: 'not-a-string' }
  const trimmed = text.trim()
  if (!trimmed.toLowerCase().startsWith(PAIRING_SCHEME)) return { ok: false, reason: 'bad-scheme' }
  let parsed
  try {
    parsed = JSON.parse(Buffer.from(trimmed.slice(PAIRING_SCHEME.length), 'base64url').toString('utf8'))
  } catch {
    return { ok: false, reason: 'bad-payload' }
  }
  if (parsed?.v !== DESCRIPTOR_VERSION) return { ok: false, reason: 'bad-version' }
  if (typeof parsed.hostId !== 'string' || parsed.hostId === '') return { ok: false, reason: 'bad-host' }
  if (typeof parsed.deviceId !== 'string' || parsed.deviceId === '') return { ok: false, reason: 'bad-device' }
  if (typeof parsed.secret !== 'string' || !/^[0-9a-f]{64}$/i.test(parsed.secret)) {
    return { ok: false, reason: 'bad-secret' }
  }
  const urls = Array.isArray(parsed.urls) ? parsed.urls.filter((url) => typeof url === 'string') : []
  const iroh = parsed.iroh && typeof parsed.iroh === 'object' && typeof parsed.iroh.endpointId === 'string'
    ? {
      endpointId: parsed.iroh.endpointId,
      relay: typeof parsed.iroh.relay === 'string' ? parsed.iroh.relay : null,
    }
    : null
  return {
    ok: true,
    payload: {
      hostId: parsed.hostId,
      name: typeof parsed.name === 'string' ? parsed.name : '',
      port: Number.isInteger(parsed.port) ? parsed.port : 0,
      deviceId: parsed.deviceId,
      secret: parsed.secret,
      urls,
      iroh,
      issuedAt: Number.isInteger(parsed.issuedAt) ? parsed.issuedAt : 0,
    },
  }
}
