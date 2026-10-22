import assert from 'node:assert/strict'
import test from 'node:test'

import { DEFAULT_PORT, normalizeConfig, priorityOf } from '../lib/config.js'

test('空配置给出可用的默认值', () => {
  const { config, warnings } = normalizeConfig()
  assert.deepEqual(warnings, [])
  assert.equal(config.port, DEFAULT_PORT)
  assert.equal(config.bind, '0.0.0.0')
  // 内网三档默认开，自建中转默认关（需要用户填地址才谈得上"可用"）
  assert.equal(config.tiers.lan.enabled, true)
  assert.equal(config.tiers.tailscale.enabled, true)
  assert.equal(config.tiers.zerotier.enabled, true)
  assert.equal(config.tiers.frp.enabled, false)
  assert.equal(config.tiers.iroh.enabled, true)
})

test('非法端口回退默认值并给出警告，而不是抛错', () => {
  const { config, warnings } = normalizeConfig({ port: 70000 })
  assert.equal(config.port, DEFAULT_PORT)
  assert.equal(warnings.length, 1)
  assert.match(warnings[0], /70000/)
})

test('端口 0 是合法的（交给系统分配）', () => {
  const { config, warnings } = normalizeConfig({ port: 0 })
  assert.equal(config.port, 0)
  assert.deepEqual(warnings, [])
})

test('frp 的 mode 只认 managed / byo，其它值回退 managed', () => {
  const { config, warnings } = normalizeConfig({ tiers: { frp: { mode: 'weird' } } })
  assert.equal(config.tiers.frp.mode, 'managed')
  assert.equal(warnings.length, 1)
})

test('frp 启用但既没 serverAddr 也没 publicUrl → 警告（该档会被跳过）', () => {
  const { warnings } = normalizeConfig({ tiers: { frp: { enabled: true } } })
  assert.ok(warnings.some((item) => item.includes('serverAddr')))
})

test('iroh relay=custom 但没填 customRelay → 回退 n0 并警告', () => {
  const { config, warnings } = normalizeConfig({ tiers: { iroh: { relay: 'custom' } } })
  assert.equal(config.tiers.iroh.relay, 'n0')
  assert.ok(warnings.some((item) => item.includes('customRelay')))
})

test('iroh relay=custom 且填了地址 → 保留', () => {
  const { config, warnings } = normalizeConfig({
    tiers: { iroh: { relay: 'custom', customRelay: 'https://relay.example.com' } },
  })
  assert.equal(config.tiers.iroh.relay, 'custom')
  assert.equal(config.tiers.iroh.customRelay, 'https://relay.example.com')
  assert.deepEqual(warnings, [])
})

test('frp 声称要 TLS 但 publicUrl 不是 https → 明确警告"实际仍是明文"', () => {
  const { warnings } = normalizeConfig({
    tiers: { frp: { enabled: true, tls: true, publicUrl: 'http://dsh.example.com' } },
  })
  assert.ok(warnings.some((item) => item.includes('明文')))
})

test('优先级顺序固定：lan < tailscale < zerotier < frp < iroh', () => {
  const order = ['lan', 'tailscale', 'zerotier', 'frp', 'iroh'].map(priorityOf)
  for (let index = 1; index < order.length; index += 1) {
    assert.ok(order[index - 1] < order[index], `第 ${index} 档优先级必须更大`)
  }
  assert.equal(priorityOf('nope'), 99)
})

test('Bonjour 默认开、自签 TLS 默认关（加密是可选，不是默认拦路）', () => {
  const { config } = normalizeConfig()
  assert.equal(config.tiers.lan.bonjour, true)
  assert.equal(config.tiers.lan.tls, false)
})

test('新档位字段能透传：iroh 的 binaryPath/dataDir、frp 的 frpcPath', () => {
  const { config, warnings } = normalizeConfig({
    tiers: {
      iroh: { binaryPath: '/opt/bin/tether-host', dataDir: '/tmp/uplink-iroh' },
      frp: { frpcPath: '/opt/bin/frpc' },
    },
  })
  assert.equal(config.tiers.iroh.binaryPath, '/opt/bin/tether-host')
  assert.equal(config.tiers.iroh.dataDir, '/tmp/uplink-iroh')
  assert.equal(config.tiers.frp.frpcPath, '/opt/bin/frpc')
  assert.deepEqual(warnings, [])
})

test('lan.tls 打开时给出"依赖 openssl、失败会退回明文"的警告', () => {
  const { warnings } = normalizeConfig({ tiers: { lan: { tls: true } } })
  assert.ok(warnings.some((item) => item.includes('openssl')))
})

test('iroh 与 frp 托管同时开会提示"两条外网通路并行常驻"', () => {
  const { warnings } = normalizeConfig({
    tiers: { frp: { enabled: true, mode: 'managed', serverAddr: '1.2.3.4' } },
  })
  assert.ok(warnings.some((item) => item.includes('并行常驻')))
})
