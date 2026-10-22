/**
 * 配置的默认值与归一化。
 *
 * 一条原则：**配置只描述"允许哪些档位"，不描述"地址"**。地址永远由检测
 * （lib/detect.js）在运行时算出来 —— 换 Wi-Fi、Tailscale 重新分配地址、
 * 笔记本换个网段，配置文件都不该需要人改。
 */

/** 网关默认端口。固定值让 frp 的 remotePort 与手动填写可预测；被占用时自动顺延。 */
export const DEFAULT_PORT = 18788

export const DEFAULTS = Object.freeze({
  port: DEFAULT_PORT,
  bind: '0.0.0.0',
  name: '',
  tiers: {
    lan: { enabled: true, bonjour: true, tls: false },
    tailscale: { enabled: true },
    zerotier: { enabled: true },
    frp: {
      enabled: false,
      mode: 'managed',
      serverAddr: '',
      serverPort: 7000,
      remotePort: DEFAULT_PORT,
      token: '',
      tls: false,
      publicUrl: '',
      frpcPath: '',
    },
    iroh: {
      enabled: true,
      relay: 'n0',
      customRelay: '',
      binaryPath: '',
      dataDir: '',
    },
  },
})

const bool = (value, fallback) => (typeof value === 'boolean' ? value : fallback)
const str = (value, fallback) => (typeof value === 'string' ? value : fallback)
const int = (value, fallback, min, max) => {
  const number = typeof value === 'number' ? value : Number.parseInt(value, 10)
  if (!Number.isFinite(number) || number < min || number > max) return fallback
  return Math.trunc(number)
}

/** 端口 0 表示"随便给一个"，但绝不接受越界值 —— 静默回退比启动失败更难查。 */
const port = (value, fallback) => int(value, fallback, 0, 65535)

/**
 * 把用户配置与默认值合并，并把每个字段收敛到合法域。
 *
 * 不做"严格校验后抛错"：一个字段写错不应该让整个 dsh 起不来（插件在宿主进程里，
 * 抛错会拖垮宿主）。非法值回退默认，由 `warnings` 带出去给人看。
 *
 * @param {object} [input]
 * @returns {{config: object, warnings: string[]}}
 */
export function normalizeConfig(input = {}) {
  const warnings = []
  const raw = input && typeof input === 'object' ? input : {}
  const rawTiers = raw.tiers && typeof raw.tiers === 'object' ? raw.tiers : {}

  const tierOf = (key) => {
    const value = rawTiers[key]
    return value && typeof value === 'object' ? value : {}
  }

  const lan = tierOf('lan')
  const tailscale = tierOf('tailscale')
  const zerotier = tierOf('zerotier')
  const frp = tierOf('frp')
  const iroh = tierOf('iroh')

  if (raw.port !== undefined && port(raw.port, null) === null) {
    warnings.push(`port=${String(raw.port)} 不是合法端口，已回退 ${DEFAULT_PORT}`)
  }
  if (frp.mode !== undefined && frp.mode !== 'managed' && frp.mode !== 'byo') {
    warnings.push(`tiers.frp.mode=${String(frp.mode)} 只能是 managed / byo，已按 managed 处理`)
  }
  if (iroh.relay !== undefined && iroh.relay !== 'n0' && iroh.relay !== 'custom') {
    warnings.push(`tiers.iroh.relay=${String(iroh.relay)} 只能是 n0 / custom，已按 n0 处理`)
  }
  if (frp.enabled === true && str(frp.serverAddr, '').trim() === '' && str(frp.publicUrl, '').trim() === '') {
    warnings.push('tiers.frp 已启用但既没有 serverAddr 也没有 publicUrl，该档会被跳过')
  }

  const config = {
    port: port(raw.port, DEFAULT_PORT),
    bind: str(raw.bind, DEFAULTS.bind).trim() || DEFAULTS.bind,
    name: str(raw.name, '').trim(),
    tiers: {
      lan: {
        enabled: bool(lan.enabled, true),
        // Bonjour 广播让手机零配置发现；关掉之后只能靠配对串里的地址
        bonjour: bool(lan.bonjour, true),
        // 自签 TLS：局域网也能加密（手机侧用 Network 框架固定指纹，绕开 ATS）
        tls: bool(lan.tls, false),
      },
      tailscale: { enabled: bool(tailscale.enabled, true) },
      zerotier: { enabled: bool(zerotier.enabled, true) },
      frp: {
        enabled: bool(frp.enabled, false),
        mode: frp.mode === 'byo' ? 'byo' : 'managed',
        serverAddr: str(frp.serverAddr, '').trim(),
        serverPort: int(frp.serverPort, DEFAULTS.tiers.frp.serverPort, 1, 65535),
        remotePort: int(frp.remotePort, DEFAULTS.tiers.frp.remotePort, 1, 65535),
        token: str(frp.token, ''),
        tls: bool(frp.tls, false),
        publicUrl: str(frp.publicUrl, '').trim(),
        frpcPath: str(frp.frpcPath, '').trim(),
      },
      iroh: {
        enabled: bool(iroh.enabled, true),
        relay: iroh.relay === 'custom' ? 'custom' : 'n0',
        customRelay: str(iroh.customRelay, '').trim(),
        binaryPath: str(iroh.binaryPath, '').trim(),
        dataDir: str(iroh.dataDir, '').trim(),
      },
    },
  }

  if (config.tiers.iroh.relay === 'custom' && config.tiers.iroh.customRelay === '') {
    warnings.push('tiers.iroh.relay=custom 但没有填 customRelay，该档会退回 n0')
    config.tiers.iroh.relay = 'n0'
  }
  if (config.tiers.frp.enabled && config.tiers.frp.tls && !/^https:\/\//i.test(config.tiers.frp.publicUrl)) {
    // 只说"要 TLS"但没给 https 地址：仍然允许，公网 URL 由 serverAddr:remotePort 拼出，
    // 但那条是明文 —— 必须让用户知道，不能假装加密了。
    warnings.push('tiers.frp.tls=true 但 publicUrl 不是 https://，实际连接仍是明文')
  }
  if (config.tiers.lan.tls && config.tiers.lan.enabled) {
    // 自签证书靠 openssl 生成；没有就只能退回明文，别让用户以为开了加密
    warnings.push('tiers.lan.tls=true：需要本机有 openssl，生成失败时会自动退回明文并在日志里说明')
  }
  if (config.tiers.iroh.enabled && config.tiers.frp.enabled && config.tiers.frp.mode === 'managed') {
    warnings.push('iroh 与 frp 同时启用：两条外网通路会并行常驻，按需关掉一条可省资源')
  }

  return { config, warnings }
}

/**
 * 只保留启用且**当前可用**的档位，按优先级排序。
 *
 * 优先级是产品决策（局域网最快、虚拟组网次之、自建中转再次、iroh 兜底），
 * 用户可勾选启用哪些，但不改顺序 —— 让"自动"有一个可预测的答案。
 */
export const TIER_PRIORITY = Object.freeze({
  lan: 10,
  tailscale: 20,
  zerotier: 30,
  frp: 40,
  iroh: 50,
})

export function priorityOf(kind) {
  return TIER_PRIORITY[kind] ?? 99
}
