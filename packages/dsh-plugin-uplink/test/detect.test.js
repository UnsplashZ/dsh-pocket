import assert from 'node:assert/strict'
import test from 'node:test'

import {
  classifyInterface,
  collectCandidates,
  detectSingBox,
  detectTailscale,
  parseTailscalePeerList,
  resolveOwnTailnetAddresses,
  detectZeroTier,
  fingerprint,
  TAILSCALE_CANDIDATES,
} from '../lib/detect.js'

test('回环与链路本地一律丢弃', () => {
  assert.equal(classifyInterface('lo0', '127.0.0.1'), null)
  assert.equal(classifyInterface('en0', '169.254.10.20'), null)
  assert.equal(classifyInterface('en0', '0.0.0.0'), null)
  assert.equal(classifyInterface('en0', '::1'), null)
})

test('私有网段是局域网', () => {
  assert.equal(classifyInterface('en0', '192.168.1.5'), 'lan')
  assert.equal(classifyInterface('en0', '10.8.54.221'), 'lan')
  assert.equal(classifyInterface('en0', '172.16.0.9'), 'lan')
  assert.equal(classifyInterface('en0', '172.31.255.1'), 'lan')
  // 172.32 已经出了 172.16/12
  assert.equal(classifyInterface('en0', '172.32.0.1'), 'wan')
})

test('ZeroTier 按接口名识别，且优先于网段判断', () => {
  // ZeroTier 允许把网段改成 10/8：只看网段会误判成 lan，进而把
  // "只有装了 ZeroTier 的手机才可达"的地址当局域网地址广播出去
  assert.equal(classifyInterface('feth0', '10.147.20.5'), 'zerotier')
  assert.equal(classifyInterface('ztabc123', '192.168.196.3'), 'zerotier')
})

test('100.64/10 是 Tailscale（CGNAT 段）', () => {
  assert.equal(classifyInterface('utun4', '100.101.2.3'), 'tailscale')
  assert.equal(classifyInterface('tailscale0', '100.64.0.1'), 'tailscale')
  // 边界：100.63 与 100.128 都不在 100.64/10 里
  assert.equal(classifyInterface('utun4', '100.63.0.1'), 'tunnel')
  assert.equal(classifyInterface('utun4', '100.128.0.1'), 'tunnel')
})

test('认不出的隧道不默认广播（可能是 WireGuard / Docker / Private Relay）', () => {
  assert.equal(classifyInterface('utun9', '172.19.0.1'), 'tunnel')
  assert.equal(classifyInterface('utun2', '10.0.0.7'), 'tunnel')
})

test('collectCandidates 丢掉无关键并稳定排序', () => {
  const candidates = collectCandidates({
    lo0: [{ family: 'IPv4', address: '127.0.0.1' }],
    utun9: [{ family: 'IPv4', address: '172.19.0.1' }],
    en0: [{ family: 'IPv4', address: '10.8.54.221' }, { family: 'IPv6', address: 'fe80::1' }],
    feth0: [{ family: 'IPv4', address: '10.147.20.5' }],
    utun4: [{ family: 'IPv4', address: '100.101.2.3' }],
  })
  assert.deepEqual(
    candidates.map((item) => `${item.kind}@${item.iface}:${item.address}`),
    ['lan@en0:10.8.54.221', 'tailscale@utun4:100.101.2.3', 'zerotier@feth0:10.147.20.5', 'tunnel@utun9:172.19.0.1'],
  )
})

test('collectCandidates 兼容 Node 18 的 family: 4 数字形式', () => {
  const candidates = collectCandidates({ en0: [{ family: 4, address: '192.168.0.2' }] })
  assert.equal(candidates.length, 1)
  assert.equal(candidates[0].kind, 'lan')
})

/** 造一个假的 `run`：命令名 → 结果 */
function fakeRun(table) {
  const calls = []
  const run = async (command, args) => {
    calls.push([command, ...args].join(' '))
    const key = `${command} ${args.join(' ')}`.trim()
    const entry = table[key] ?? table[command]
    if (entry === undefined) return { ok: false, code: 127, stdout: '', stderr: 'not found' }
    return { ok: true, code: 0, stdout: entry, stderr: '' }
  }
  run.calls = calls
  return run
}

test('Tailscale：坏掉的 shim 会被逐个执行淘汰，最终选中能跑的那个', async () => {
  // 真实现场：/usr/local/bin/tailscale 存在但指向已删除的 App，执行报错
  const run = async (command, args) => {
    if (command === 'tailscale') return { ok: false, code: 127, stdout: '', stderr: 'not found' }
    if (command === '/Applications/Tailscale.app/Contents/MacOS/Tailscale') {
      return { ok: false, code: null, stdout: '', stderr: 'cannot execute: No such file or directory' }
    }
    if (command === '/usr/local/bin/tailscale') {
      return { ok: false, code: 127, stdout: '', stderr: 'No such file or directory' }
    }
    return {
      ok: true,
      code: 0,
      stdout: JSON.stringify({ BackendState: 'Running', Self: { TailscaleIPs: ['100.101.2.3', 'fd7a::1'], HostName: 'mac' } }),
      stderr: '',
    }
  }
  const result = await detectTailscale({ run })
  assert.equal(result.available, true)
  assert.deepEqual(result.addresses, ['100.101.2.3'])
  assert.equal(result.hostName, 'mac')
  assert.equal(result.command, '/opt/homebrew/bin/tailscale')
})

test('Tailscale：装了但没登录 → 不可用，并带上具体状态', async () => {
  const run = fakeRun({
    [TAILSCALE_CANDIDATES[0]]: JSON.stringify({ BackendState: 'NeedsLogin', Self: { TailscaleIPs: [] } }),
  })
  const result = await detectTailscale({ run, candidates: [TAILSCALE_CANDIDATES[0]] })
  assert.equal(result.available, false)
  assert.equal(result.backendState, 'NeedsLogin')
  assert.equal(result.reason, 'state:NeedsLogin')
})

test('Tailscale：完全没装 → not-installed', async () => {
  const result = await detectTailscale({ run: fakeRun({}), candidates: ['nope'] })
  assert.equal(result.available, false)
  assert.equal(result.reason, 'not-installed')
})

test('ZeroTier：只有 status=OK 的网络算可用', async () => {
  const run = fakeRun({
    'zerotier-cli -j listnetworks': JSON.stringify([
      { status: 'OK', assignedAddresses: ['10.147.20.5/24'] },
      { status: 'REQUESTING_CONFIGURATION', assignedAddresses: ['10.9.9.9/24'] },
    ]),
  })
  const result = await detectZeroTier({ run, candidates: ['zerotier-cli'] })
  assert.equal(result.available, true)
  assert.deepEqual(result.addresses, ['10.147.20.5'])
})

test('ZeroTier：全部没就绪 → 不可用并说明状态', async () => {
  const run = fakeRun({
    'zerotier-cli -j listnetworks': JSON.stringify([
      { status: 'ACCESS_DENIED', assignedAddresses: [] },
    ]),
  })
  const result = await detectZeroTier({ run, candidates: ['zerotier-cli'] })
  assert.equal(result.available, false)
  assert.equal(result.reason, 'no-network')
})

test('指纹：地址或 SSID 变了就变，顺序无关', () => {
  const a = [{ kind: 'lan', address: '10.8.54.221' }, { kind: 'tailscale', address: '100.101.2.3' }]
  const b = [{ kind: 'tailscale', address: '100.101.2.3' }, { kind: 'lan', address: '10.8.54.221' }]
  assert.equal(
    fingerprint({ candidates: a, ssid: 'home', defaultInterface: 'en0' }),
    fingerprint({ candidates: b, ssid: 'home', defaultInterface: 'en0' }),
  )
  assert.notEqual(
    fingerprint({ candidates: a, ssid: 'home', defaultInterface: 'en0' }),
    fingerprint({ candidates: a, ssid: 'office', defaultInterface: 'en0' }),
  )
  assert.notEqual(
    fingerprint({ candidates: a, ssid: 'home', defaultInterface: 'en0' }),
    fingerprint({ candidates: [{ kind: 'lan', address: '10.8.54.222' }], ssid: 'home', defaultInterface: 'en0' }),
  )
})

// ── sing-box 的 Tailscale endpoint ────────────────────────────────────────────

function fakeFetch(handler) {
  const calls = []
  const impl = async (url, init) => {
    calls.push({ url, init })
    return handler(url, init)
  }
  impl.calls = calls
  return impl
}

test('sing-box：Clash API 里 type=Tailscale 的 endpoint 能被认出来', async () => {
  const fetchImpl = fakeFetch(async () => ({
    ok: true,
    status: 200,
    json: async () => ({ proxies: { 手动选择: { type: 'Selector' }, 'ts-ep': { type: 'Tailscale' } } }),
  }))
  const result = await detectSingBox({
    run: fakeRun({ 'pgrep -f sing-box': '364\n' }),
    apiUrl: 'http://127.0.0.1:19090',
    apiSecret: 's3cret',
    fetchImpl,
  })
  assert.equal(result.running, true)
  assert.equal(result.via, 'api')
  assert.equal(result.tailscaleEndpoint, 'ts-ep')
  // 关键：**必须承认拿不到 IP**，而不是编一个
  assert.equal(result.reason, 'ip-not-exposed')
  assert.match(result.note, /tailnet IP 不出现在网卡上/)
  assert.equal(fetchImpl.calls.length, 1)
  assert.match(fetchImpl.calls[0].url, /\/proxies$/)
  assert.equal(fetchImpl.calls[0].init.headers.authorization, 'Bearer s3cret')
})

test('sing-box：在跑但没配 API → 明确说"看不到"', async () => {
  const result = await detectSingBox({ run: fakeRun({ 'pgrep -f sing-box': '364\n' }) })
  assert.equal(result.running, true)
  assert.equal(result.reason, 'no-api')
  assert.match(result.note, /Clash API/)
})

test('sing-box：没在跑也没配 API → not-running，且不去碰网络', async () => {
  const fetchImpl = fakeFetch(async () => { throw new Error('不该被调用') })
  const result = await detectSingBox({ run: fakeRun({}), fetchImpl })
  assert.equal(result.running, false)
  assert.equal(result.reason, 'not-running')
  assert.equal(fetchImpl.calls.length, 0)
})

test('sing-box：API 里没有 tailscale endpoint', async () => {
  const fetchImpl = fakeFetch(async () => ({
    ok: true, status: 200, json: async () => ({ proxies: { 直连: { type: 'Direct' } } }),
  }))
  const result = await detectSingBox({ run: fakeRun({}), apiUrl: 'http://127.0.0.1:19090', apiSecret: 'k', fetchImpl })
  assert.equal(result.running, false)
  assert.equal(result.reason, 'no-tailscale-endpoint')
})

test('sing-box：API 连不上 / 超时都要有可读原因，不能抛', async () => {
  const unreachable = await detectSingBox({
    run: fakeRun({}),
    apiUrl: 'http://127.0.0.1:1',
    apiSecret: 'k',
    fetchImpl: async () => { throw new Error('ECONNREFUSED') },
  })
  assert.equal(unreachable.reason, 'api-unreachable')

  const timeout = await detectSingBox({
    run: fakeRun({}),
    apiUrl: 'http://127.0.0.1:1',
    apiSecret: 'k',
    fetchImpl: async () => { const e = new Error('aborted'); e.name = 'AbortError'; throw e },
  })
  assert.equal(timeout.reason, 'api-timeout')
})

// ── sing-box 的 tailnet 地址（网卡上看不到，只能问 API） ──────────────────────

test('peer list 解析：只取 IPv4，FQDN 与在线状态都要留下', () => {
  const sample = [
    'sfm-mac.tail3d9dd2.ts.net\t100.64.16.30\tyes',
    'derper.tail3d9dd2.ts.net\t100.77.45.69\tyes',
    'steamdeck.tail3d9dd2.ts.net\t100.94.194.87\tno',
    'garbage line without ip',
    '',
  ].join('\n')
  assert.deepEqual(parseTailscalePeerList(sample), [
    { fqdn: 'sfm-mac.tail3d9dd2.ts.net', ip: '100.64.16.30', online: true },
    { fqdn: 'derper.tail3d9dd2.ts.net', ip: '100.77.45.69', online: true },
    { fqdn: 'steamdeck.tail3d9dd2.ts.net', ip: '100.94.194.87', online: false },
  ])
  assert.deepEqual(parseTailscalePeerList(''), [])
  assert.deepEqual(parseTailscalePeerList(undefined), [])
})

test('peer list 没有在线列时按在线处理（不同 sing-box 版本输出不一致）', () => {
  assert.deepEqual(parseTailscalePeerList('box.ts.net\t100.1.2.3'), [
    { fqdn: 'box.ts.net', ip: '100.1.2.3', online: true },
  ])
})

test('自证本机地址：谁的 hostId 对得上，谁才是"我"', async () => {
  const run = fakeRun({
    'sing-box api tailscale peer list --url http://api --secret s': [
      'self.ts.net\t100.64.16.30\tyes',
      'phone.ts.net\t100.86.75.36\tyes',
      'stale.ts.net\t100.94.194.87\tyes',
    ].join('\n'),
  })
  // 只有 100.64.16.30 回我们的 hostId；phone 回别人的；stale 超时
  const fetchImpl = async (url) => {
    if (url.includes('100.64.16.30')) return { ok: true, json: async () => ({ ok: true, hostId: 'me-1234' }) }
    if (url.includes('100.86.75.36')) return { ok: true, json: async () => ({ ok: true, hostId: 'someone-else' }) }
    throw new Error('timeout')
  }
  const result = await resolveOwnTailnetAddresses({
    run, cliPath: 'sing-box', apiUrl: 'http://api', apiSecret: 's',
    port: 18788, hostId: 'me-1234', fetchImpl,
  })
  assert.equal(result.available, true)
  assert.deepEqual(result.addresses, ['100.64.16.30'])
  assert.equal(result.peers.length, 3)
})

test('自证失败要给出可读原因，而不是编一个地址', async () => {
  const noConfig = await resolveOwnTailnetAddresses({ run: fakeRun({}), cliPath: '', apiUrl: '', apiSecret: '' })
  assert.equal(noConfig.reason, 'not-configured')

  const cliFail = await resolveOwnTailnetAddresses({
    run: fakeRun({}), cliPath: 'sing-box', apiUrl: 'http://api', apiSecret: 's',
    port: 1, hostId: 'h', fetchImpl: async () => { throw new Error('x') },
  })
  assert.equal(cliFail.reason.startsWith('cli-failed'), true)

  const nothing = await resolveOwnTailnetAddresses({
    run: fakeRun({ 'sing-box api tailscale peer list --url http://api --secret s': 'box.ts.net\t100.1.2.3\tyes' }),
    cliPath: 'sing-box', apiUrl: 'http://api', apiSecret: 's',
    port: 1, hostId: 'h', fetchImpl: async () => { throw new Error('timeout') },
  })
  assert.equal(nothing.available, false)
  assert.equal(nothing.reason, 'self-not-reachable')
})
