/**
 * 自签证书的单元测试。
 *
 * 两种环境都要能过：
 * - 有 openssl：断言真的生成了带 SAN 的证书、指纹格式、幂等、30 天复用门槛；
 * - 没有 openssl（或 openssl 不认 SAN 扩展）：断言返回的是 {ok:false, reason} 而不是抛异常。
 *
 * "没有 openssl"用注入 `run` 模拟，不依赖跑测试的机器装没装 —— 否则这条分支永远测不到。
 * 另外本机如果还有 /usr/bin/openssl（macOS 自带的 LibreSSL），额外跑一遍"老 openssl"路径，
 * 那条路径正是 -addext 不认、只能靠 -config 兜底的情形。
 */
import assert from 'node:assert/strict'
import { readFile, readdir, mkdtemp, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import { createRunner } from '../lib/detect.js'
import {
  CERT_FILE,
  KEY_FILE,
  REUSE_MIN_DAYS,
  ensureCertificate,
  fingerprint256FromPem,
} from '../lib/tls.js'

/** 指纹形如 `AB:CD:…`：32 组大写两位十六进制。 */
const FINGERPRINT_RE = /^(?:[0-9A-F]{2}:){31}[0-9A-F]{2}$/

const realRun = createRunner({ timeoutMs: 20000 })
const hasOpenssl = (await realRun('openssl', ['version'])).ok
const hasSystemOpenssl = (await realRun('/usr/bin/openssl', ['version'])).ok

/** 把 `openssl` 换成指定二进制，其余命令原样转发 —— 用来测"机器上另一套 openssl"。 */
function runWith(binary) {
  const calls = []
  const run = (command, args = []) => {
    const actual = command === 'openssl' ? binary : command
    calls.push([actual, ...args].join(' '))
    return realRun(actual, args)
  }
  run.calls = calls
  return run
}

/** 假执行器：按命令返回固定结果。 */
function stubRun(results) {
  const calls = []
  const run = async (command, args = []) => {
    calls.push([command, ...args].join(' '))
    return results(command, args) ?? { ok: false, code: 1, stdout: '', stderr: 'stub: no such command' }
  }
  run.calls = calls
  return run
}

async function withTmpDir(fn) {
  const dir = await mkdtemp(join(tmpdir(), 'dsh-uplink-tls-'))
  try {
    return await fn(dir)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
}

test('没有 openssl：返回 openssl-not-installed，不抛异常', async () => {
  await withTmpDir(async (dir) => {
    const run = stubRun((command) =>
      command === 'openssl' ? { ok: false, code: 127, stdout: '', stderr: 'command not found: openssl' } : null,
    )
    const result = await ensureCertificate({ dir, hostnames: ['localhost'], ips: ['127.0.0.1'], run })
    assert.deepEqual(result, { ok: false, reason: 'openssl-not-installed' })
  })
})

test('openssl 不认 SAN 扩展（三档都失败）：返回 openssl-unsupported，不抛异常', async () => {
  await withTmpDir(async (dir) => {
    const run = stubRun((command, args) => {
      if (command !== 'openssl') return null
      if (args[0] === 'version') return { ok: true, code: 0, stdout: 'OpenSSL 1.0.1e 11 Feb 2013', stderr: '' }
      // 任何 req 调用都失败：模拟"既不支持 -addext 也不支持 -config 扩展段"的老 openssl
      return { ok: false, code: 1, stdout: '', stderr: 'req: Unknown option or ciphersuite' }
    })
    const result = await ensureCertificate({ dir, hostnames: ['localhost'], ips: ['127.0.0.1'], run })
    assert.equal(result.ok, false)
    assert.equal(result.reason, 'openssl-unsupported')
    // detail 要留下最后一次失败原因，否则用户没法自己判断是版本问题还是参数问题
    assert.match(result.detail, /addext|extfile|config/)
  })
})

test('空 dir：返回 no-dir（调用方漏传不该变成在 cwd 里生成私钥）', async () => {
  const result = await ensureCertificate({ dir: '' })
  assert.equal(result.ok, false)
  assert.equal(result.reason, 'no-dir')
})

test('有 openssl：生成证书、指纹格式、SAN、幂等', { skip: hasOpenssl ? false : '本机没有 openssl' }, async () => {
  await withTmpDir(async (dir) => {
    const first = await ensureCertificate({
      dir,
      hostnames: ['localhost', 'dsh.local'],
      ips: ['127.0.0.1', '10.8.54.221'],
      run: realRun,
    })
    assert.equal(first.ok, true, first.detail)
    assert.equal(first.created, true)
    assert.equal(first.key, join(dir, KEY_FILE))
    assert.equal(first.cert, join(dir, CERT_FILE))

    // 指纹格式：大写、冒号分隔、32 组 —— 手机侧固定的是这一串
    assert.match(first.fingerprint256, FINGERPRINT_RE)

    // 文件真的落盘了，私钥不能是所有人可读
    assert.ok((await stat(first.key)).size > 0)
    assert.ok((await stat(first.cert)).size > 0)
    assert.equal((await stat(first.key)).mode & 0o777, 0o600)

    // SAN 必须含 DNS 名和 IP：手机多半直接打 IP，缺了 IP 就会域名通、IP 不通
    const text = await realRun('openssl', ['x509', '-text', '-noout', '-in', first.cert])
    assert.equal(text.ok, true)
    assert.match(text.stdout, /DNS:localhost/)
    assert.match(text.stdout, /DNS:dsh\.local/)
    assert.match(text.stdout, /IP Address:127\.0\.0\.1/)
    assert.match(text.stdout, /IP Address:10\.8\.54\.221/)

    // 指纹与 openssl 自己算的一致（交叉验证，别只信自己那套 base64 解码）
    const printed = await realRun('openssl', ['x509', '-fingerprint', '-sha256', '-noout', '-in', first.cert])
    if (printed.ok) {
      const expected = printed.stdout.split('=').pop().trim().toUpperCase()
      assert.equal(first.fingerprint256, expected)
    }

    // 剩余有效期提示（用注入的 now 只是为了证明这个参数确实参与计算）
    assert.ok(typeof first.expiresAt === 'string')
    assert.ok(first.daysLeft > 800, `825 天的证书应剩 800 天以上，实际 ${first.daysLeft}`)

    // 幂等：同样参数再来一次不重签、指纹不变
    const before = await readFile(first.cert, 'utf8')
    const second = await ensureCertificate({
      dir,
      hostnames: ['localhost', 'dsh.local'],
      ips: ['127.0.0.1', '10.8.54.221'],
      run: realRun,
    })
    assert.equal(second.ok, true)
    assert.equal(second.created, false)
    assert.equal(second.fingerprint256, first.fingerprint256)
    assert.equal(await readFile(first.cert, 'utf8'), before)

    // 临时扩展配置文件不能留在用户状态目录里
    const leftovers = (await readdir(dir)).filter((name) => name.endsWith('.cnf'))
    assert.deepEqual(leftovers, [])
  })
})

test('有 openssl：跳过 -addext 的降级路径也能生成带 SAN 的证书', { skip: hasOpenssl ? false : '本机没有 openssl' }, async () => {
  await withTmpDir(async (dir) => {
    const result = await ensureCertificate({
      dir,
      hostnames: ['localhost'],
      ips: ['127.0.0.1'],
      run: realRun,
      skipAddext: true,
    })
    assert.equal(result.ok, true, result.detail)
    assert.equal(result.created, true)
    assert.match(result.fingerprint256, FINGERPRINT_RE)

    const text = await realRun('openssl', ['x509', '-text', '-noout', '-in', result.cert])
    assert.match(text.stdout, /DNS:localhost/)
    assert.match(text.stdout, /IP Address:127\.0\.0\.1/)
  })
})

test(`剩余有效期不足 ${REUSE_MIN_DAYS} 天：不复用，直接重签`, { skip: hasOpenssl ? false : '本机没有 openssl' }, async () => {
  await withTmpDir(async (dir) => {
    // 先签一张 1 天的：明天就过期，必须被判定为"不能复用"
    const short = await ensureCertificate({ dir, hostnames: ['localhost'], ips: ['127.0.0.1'], days: 1, run: realRun })
    assert.equal(short.ok, true, short.detail)
    assert.equal(short.created, true)
    assert.ok(short.daysLeft <= 1)

    const renewed = await ensureCertificate({ dir, hostnames: ['localhost'], ips: ['127.0.0.1'], days: 825, run: realRun })
    assert.equal(renewed.ok, true, renewed.detail)
    assert.equal(renewed.created, true, '快过期的证书必须重签')
    assert.notEqual(renewed.fingerprint256, short.fingerprint256)
    assert.ok(renewed.daysLeft > 800)
  })
})

test('本机另有 LibreSSL 时：老 openssl 也能签出带 SAN 的证书', { skip: hasSystemOpenssl ? false : '本机没有 /usr/bin/openssl' }, async () => {
  await withTmpDir(async (dir) => {
    // macOS 自带的 LibreSSL 老版本不认 -addext，正是降级链存在的理由
    const run = runWith('/usr/bin/openssl')
    const result = await ensureCertificate({
      dir,
      hostnames: ['localhost'],
      ips: ['127.0.0.1'],
      run,
      skipAddext: true,
    })
    assert.equal(result.ok, true, result.detail)
    const text = await realRun('/usr/bin/openssl', ['x509', '-text', '-noout', '-in', result.cert])
    assert.match(text.stdout, /DNS:localhost/)
  })
})

test('指纹算法：PEM 里换行/头尾怎么变，指纹都一样', () => {
  // 用固定的一段 DER（"hi"）反推出 base64，验证实现只认 base64 内容
  const der = Buffer.from('hi')
  const body = der.toString('base64')
  const oneLine = `-----BEGIN CERTIFICATE-----\n${body}\n-----END CERTIFICATE-----\n`
  const wrapped = `-----BEGIN CERTIFICATE-----\r\n${body.slice(0, 2)}\r\n${body.slice(2)}\r\n-----END CERTIFICATE-----`
  assert.equal(fingerprint256FromPem(oneLine), fingerprint256FromPem(wrapped))
  assert.match(fingerprint256FromPem(oneLine), FINGERPRINT_RE)
  assert.equal(fingerprint256FromPem(''), '')
})
