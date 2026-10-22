/**
 * 自签 TLS 证书。
 *
 * **为什么必须 fork openssl**：`node:crypto` 只能生成密钥对和签名，**没有任何生成 X.509
 * 证书的 API**（没有证书编码、没有 TBSCertificate 构造），而 iOS/Android 的 TLS 栈都要求
 * 服务端给出证书。用 npm 上的 `selfsigned` 之类当然更省事，但本包零第三方依赖是硬约束，
 * 所以只能借系统 openssl 子进程。
 *
 * **为什么指纹要自己算**：自签证书没有 CA 信任链，手机侧唯一的判据是"证书指纹等于配对时
 * 记下的那串"。所以指纹必须是证书 DER 的确定性函数（sha256），而不是 openssl 打印的
 * 某种可能带算法前缀的文本 —— 那种输出 OpenSSL 3 与 LibreSSL 的大小写、前缀都不一样。
 *
 * **为什么只在剩 30 天以上才复用**：证书悄悄过期是最难排查的一类"手机连不上"（浏览器只会
 * 说一句 ERR_CERT_DATE_INVALID）。宁可提前重签 —— 重签只换指纹，手机侧本来就要重新信任一次。
 *
 * **实测教训（写在这里，改之前先看）**：`-addext` 不是到处都有。macOS 自带的 LibreSSL
 * 老版本不认 `-addext`；而本机实测 **OpenSSL 3.x 和 LibreSSL 3.3.6 的 `openssl req`
 * 都不认 `-extfile`**（那是 `openssl x509` 的选项，req 只认 `-config` + `-extensions`）。
 * 所以降级链是三档：`-addext` → `-extfile`（老 LibreSSL）→ `-config` 临时配置文件（真正兜底）。
 * 三档都失败才返回 openssl-unsupported。
 */
import { createHash } from 'node:crypto'
import { chmod, mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

import { createRunner } from './detect.js'

/** 复用门槛：剩余有效期不足 30 天就重签。 */
export const REUSE_MIN_DAYS = 30
/** `openssl x509 -checkend` 要的是秒。 */
const REUSE_MIN_SECONDS = REUSE_MIN_DAYS * 24 * 60 * 60

export const DEFAULT_DAYS = 825
export const KEY_FILE = 'key.pem'
export const CERT_FILE = 'cert.pem'
/** 证书 CN 固定：主机名/地址都在 SAN 里，CN 只是给"人看证书"时有个名字。 */
const SUBJECT_CN = 'dsh-uplink'

const DAY_MS = 24 * 60 * 60 * 1000

/**
 * 证书 PEM → DER 的 sha256 指纹，形如 `AB:CD:EF:…`（大写、冒号分隔）。
 *
 * 直接自己 base64 解码，不调 `openssl x509 -fingerprint`：那个输出在 OpenSSL 3 是
 * `sha256 Fingerprint=...`、在 LibreSSL 是 `SHA256 Fingerprint=...`，还得再解析一遍文本，
 * 不如按 PEM 规则自己算 —— 结果对同一张证书永远一致，手机侧才好固定。
 */
export function fingerprint256FromPem(pem) {
  const body = String(pem ?? '')
    .replace(/-----(BEGIN|END) CERTIFICATE-----/g, '')
    .replace(/[^A-Za-z0-9+/=]/g, '')
  if (body === '') return ''
  const der = Buffer.from(body, 'base64')
  const hex = createHash('sha256').update(der).digest('hex').toUpperCase()
  return hex.match(/.{2}/g).join(':')
}

function sanValueOf(hostnames, ips) {
  const entries = []
  const seen = new Set()
  const push = (entry) => {
    if (entry === '' || seen.has(entry)) return
    seen.add(entry)
    entries.push(entry)
  }
  for (const host of hostnames) {
    const value = String(host ?? '').trim()
    if (value !== '') push(`DNS:${value}`)
  }
  for (const ip of ips) {
    const value = String(ip ?? '').trim()
    if (value !== '') push(`IP:${value}`)
  }
  // 一个都没给时退回 localhost：空 SAN 会让 openssl 直接报错，而"本机回环"是唯一
  // 一个永远成立的地址，至少能让人在电脑上先验证证书本身没问题。
  if (entries.length === 0) {
    entries.push('DNS:localhost', 'IP:127.0.0.1')
  }
  return entries.join(',')
}

async function exists(path) {
  try {
    await stat(path)
    return true
  } catch {
    return false
  }
}

/**
 * 已有证书还能不能用？
 *
 * 判据只有一条：`openssl x509 -checkend 2592000` 退出码 0（还剩超过 30 天）。
 * 用 openssl 而不是自己解析 notAfter：解析 ASN.1 时间格式（UTCTime vs GeneralizedTime）
 * 的坑不值得自己踩。
 */
async function canReuse(run, certPath, keyPath) {
  if (!(await exists(certPath)) || !(await exists(keyPath))) return false
  const check = await run('openssl', ['x509', '-checkend', String(REUSE_MIN_SECONDS), '-noout', '-in', certPath])
  return check.ok === true
}

/** 读证书的 notAfter，用来给调用方一个"还有多少天"的可读提示（失败就返回 null，不影响主流程）。 */
async function readExpiry(run, certPath, now) {
  const result = await run('openssl', ['x509', '-enddate', '-noout', '-in', certPath])
  if (!result.ok) return null
  const match = /notAfter=(.+)$/m.exec(result.stdout)
  if (match === null) return null
  const end = new Date(match[1].trim())
  if (Number.isNaN(end.getTime())) return null
  return {
    expiresAt: end.toISOString(),
    daysLeft: Math.floor((end.getTime() - now().getTime()) / DAY_MS),
  }
}

/**
 * 确保 `dir` 下有一张可用的自签证书（key.pem + cert.pem）。
 *
 * 幂等：参数不变时第二次调用 created=false，指纹与第一次完全一致。
 *
 * @param {object} options
 * @param {string} options.dir 存放 key.pem / cert.pem 的目录（不存在会自动建）
 * @param {string[]} [options.hostnames] SAN 里的 DNS 名（如 dsh.local、localhost）
 * @param {string[]} [options.ips] SAN 里的 IP（手机可能直接打 IP，所以必须进 SAN）
 * @param {number} [options.days=825] 有效期天数
 * @param {Function} [options.run] 命令执行器（默认 createRunner，测试可注入）
 * @param {Function} [options.now] 取当前时间（测试可注入；只用于算剩余天数提示）
 * @param {boolean} [options.skipAddext] 跳过 `-addext` 直接走降级链（仅供测试覆盖老 openssl 路径）
 * @returns {Promise<{ok:true, key:string, cert:string, keyPath:string, certPath:string,
 *   fingerprint256:string, created:boolean, expiresAt?:string, daysLeft?:number}
 *   | {ok:false, reason:string, detail?:string}>}
 */
export async function ensureCertificate({
  dir,
  hostnames = [],
  ips = [],
  days = DEFAULT_DAYS,
  // 默认超时给足：rsa:2048 生成在慢机器/老 CPU 上可能超过一秒，而 createRunner 默认只有 800ms。
  run = createRunner({ timeoutMs: 20000 }),
  now = () => new Date(),
  skipAddext = false,
} = {}) {
  if (typeof dir !== 'string' || dir.trim() === '') return { ok: false, reason: 'no-dir' }

  const keyPath = join(dir, KEY_FILE)
  const certPath = join(dir, CERT_FILE)
  const lifeDays = Number.isFinite(days) && days > 0 ? Math.trunc(days) : DEFAULT_DAYS

  // 先确认 openssl 真的能跑：后面每一步都依赖它，早失败能给出更准的原因。
  const probe = await run('openssl', ['version'])
  if (!probe.ok) return { ok: false, reason: 'openssl-not-installed' }

  await mkdir(dir, { recursive: true })

  if (await canReuse(run, certPath, keyPath)) {
    const pem = await readFile(certPath, 'utf8')
    const fingerprint256 = fingerprint256FromPem(pem)
    if (fingerprint256 !== '') {
      // 顺手收紧权限：复用路径也不能让私钥停在 0644（用户可能从别处拷过来）。
      await chmod(keyPath, 0o600).catch(() => {})
      const expiry = await readExpiry(run, certPath, now)
      return {
        ok: true,
        key: keyPath,
        cert: certPath,
        keyPath,
        certPath,
        fingerprint256,
        created: false,
        ...(expiry ?? {}),
      }
    }
    // 证书文件读得出但解不出 DER（被截断/被换成别的东西）：当它不存在，重签。
  }

  const san = sanValueOf(hostnames, ips)
  const extFile = join(dir, 'san.ext.cnf')
  const reqConfigFile = join(dir, 'san.req.cnf')

  /** 每一档的 argv 与需要的临时文件；按"从新到旧"排序。 */
  const attempts = []

  if (!skipAddext) {
    // 第一档：OpenSSL 1.1.1+ / LibreSSL 3.x 都认。最干净，不留临时文件。
    attempts.push({
      name: 'addext',
      args: [
        'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
        '-keyout', keyPath, '-out', certPath,
        '-days', String(lifeDays),
        '-subj', `/CN=${SUBJECT_CN}`,
        '-addext', `subjectAltName=${san}`,
        // 明确标成叶子证书：自签也应该是 CA:FALSE，否则 iOS 会把它当 CA 对待。
        '-addext', 'basicConstraints=critical,CA:FALSE',
      ],
    })
  }

  // 第二档：老 LibreSSL（req 支持 -extfile 的那批）。
  attempts.push({
    name: 'extfile',
    prepare: async () => {
      await writeFile(extFile, `[v3_req]\nsubjectAltName = ${san}\nbasicConstraints = critical,CA:FALSE\n`, { mode: 0o600 })
      return ['-extfile', extFile, '-extensions', 'v3_req']
    },
  })

  // 第三档：真正兜底。req 的 -extensions 从 -config 指定的配置文件里找段，
  // 这条路 OpenSSL 1.0.2 到 3.x、LibreSSL 2.x 到 3.x 全都能走。
  attempts.push({
    name: 'config',
    prepare: async () => {
      const body = [
        '[req]',
        'distinguished_name = dn',
        'prompt = no',
        '[dn]',
        `CN = ${SUBJECT_CN}`,
        '[v3_req]',
        `subjectAltName = ${san}`,
        'basicConstraints = critical,CA:FALSE',
        '',
      ].join('\n')
      await writeFile(reqConfigFile, body, { mode: 0o600 })
      return ['-config', reqConfigFile, '-extensions', 'v3_req']
    },
  })

  let detail = ''
  try {
    for (const attempt of attempts) {
      // 每次重来前清掉半成品：openssl 常常先写出 key 再失败，留着会让"复用"误判。
      await rm(keyPath, { force: true })
      await rm(certPath, { force: true })

      const extra = typeof attempt.prepare === 'function' ? await attempt.prepare() : []
      const result = await run('openssl', [
        'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
        '-keyout', keyPath, '-out', certPath,
        '-days', String(lifeDays),
        '-subj', `/CN=${SUBJECT_CN}`,
        ...(attempt.args ?? []),
        ...extra,
      ])

      const produced = result.ok && (await exists(keyPath)) && (await exists(certPath))
      if (!produced) {
        detail = `${attempt.name}: ${(result.stderr || result.stdout || '').trim().slice(0, 300)}`
        continue
      }

      const pem = await readFile(certPath, 'utf8')
      const fingerprint256 = fingerprint256FromPem(pem)
      if (fingerprint256 === '') {
        detail = `${attempt.name}: 生成的证书不是合法 PEM`
        continue
      }

      // 私钥只给自己读：里面没有口令，落到 0644 等于同机任何用户都能冒充这台机器。
      await chmod(keyPath, 0o600).catch(() => {})
      const expiry = await readExpiry(run, certPath, now)
      return {
        ok: true,
        key: keyPath,
        cert: certPath,
        keyPath,
        certPath,
        fingerprint256,
        created: true,
        ...(expiry ?? {}),
      }
    }
  } finally {
    // 临时配置里只有 SAN，但没必要长期留在用户状态目录里。
    await rm(extFile, { force: true }).catch(() => {})
    await rm(reqConfigFile, { force: true }).catch(() => {})
  }

  return { ok: false, reason: 'openssl-unsupported', detail }
}
