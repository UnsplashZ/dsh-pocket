#!/usr/bin/env node
// 抓一份真实的 session/follow 帧序列，落到 docs/artifacts/samples/（已 gitignore）。
// 用途：给 Swift 解码器当"活服务器事实"样本；DSH 升级后重跑一次做 diff。
//
//   node tools/capture-session.mjs list
//   node tools/capture-session.mjs follow <sessionId> [秒]
//   node tools/capture-session.mjs events [秒]
//
// 环境变量：DSH_AUTHORITY（默认 127.0.0.1:19387）、DSH_HOME
import { createRequire } from 'node:module'
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const require = createRequire(import.meta.url)
const here = dirname(fileURLToPath(import.meta.url))
const { cookieFor } = require('./mint-cookie.cjs')

const authority = process.env.DSH_AUTHORITY || '127.0.0.1:19387'
const outDir = resolve(here, '../docs/artifacts/samples')
const cookie = cookieFor(authority)
const rpcId = () => `cap-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`

async function unary(method, args = {}) {
  const res = await fetch(`http://${authority}/api/${method}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({ type: 'client-request', rpcId: rpcId(), method, payload: { args } }),
  })
  const text = await res.text()
  if (res.status !== 200) return { httpStatus: res.status, body: text.slice(0, 400) }
  try { return JSON.parse(text) } catch { return { unparsed: text.slice(0, 400) } }
}

function openStream(endpoint, args, { seconds = 10, onFrame } = {}) {
  return new Promise((done) => {
    const ws = new WebSocket(`ws://${authority}/api/remote.mux`, { headers: { cookie } })
    const frames = []
    ws.addEventListener('open', () => {
      ws.send(JSON.stringify({ type: 'open', streamId: 's1', endpoint, payload: { args } }))
    })
    ws.addEventListener('message', (ev) => {
      let frame
      try { frame = JSON.parse(ev.data) } catch { return }
      frames.push(frame)
      if (onFrame) onFrame(frame)
    })
    ws.addEventListener('error', (e) => console.error('WS 错误:', e.message || e.type))
    if (seconds > 0) {
      setTimeout(() => {
        try { ws.send(JSON.stringify({ type: 'cancel', streamId: 's1' })) } catch {}
        ws.close()
      }, seconds * 1000)
    }
    ws.addEventListener('close', () => done(frames))
  })
}

function save(name, payload) {
  mkdirSync(outDir, { recursive: true })
  const path = resolve(outDir, name)
  writeFileSync(path, payload)
  const bytes = Buffer.byteLength(payload)
  console.log(`已写入 ${path}（${(bytes / 1024).toFixed(1)} KB）`)
}

const [mode, ...rest] = process.argv.slice(2)

if (mode === 'list') {
  const out = await unary('session/list', { _request: {} })
  const items = out?.result?.value?.items ?? []
  for (const it of items) {
    const p = it.projections?.values ?? {}
    console.log(`${it.sessionId}\t${it.running ? 'RUNNING' : '       '}\tseq=${it.projections?.asOfSeq}\t${(p.title ?? '').slice(0, 40)}\t${it.cwd}`)
  }
} else if (mode === 'follow') {
  const sessionId = rest[0]
  if (!sessionId) { console.error('用法: follow <sessionId> [秒]'); process.exit(1) }
  const secs = Number(rest[1] || 8)
  const frames = await openStream('session/follow',
    { request: { address: { kind: 'session', sessionId }, assistantStream: true } },
    { seconds: secs, onFrame: (f) => console.log(`[${f.type}]`, JSON.stringify(f.value ?? f.error ?? '').slice(0, 160)) })
  save(`${sessionId}.follow.jsonl`, frames.map((f) => JSON.stringify(f)).join('\n'))
} else if (mode === 'events') {
  const secs = Number(rest[0] || 10)
  const frames = await openStream('$events', {}, {
    seconds: secs,
    onFrame: (f) => console.log(`[${f.type}]`, JSON.stringify(f.value ?? f.error ?? '').slice(0, 160)),
  })
  save('events.jsonl', frames.map((f) => JSON.stringify(f)).join('\n'))
} else {
  console.log(`用法:
  node tools/capture-session.mjs list
  node tools/capture-session.mjs follow <sessionId> [秒]
  node tools/capture-session.mjs events [秒]

当前目标: http://${authority}`)
}
