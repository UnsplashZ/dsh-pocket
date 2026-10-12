#!/usr/bin/env node
// M0 协议 spike：直接对着一台 DSH host 说客户端协议，验证我们能拿到什么。
// 零依赖（Node ≥ 22 自带 fetch 与 WebSocket）。
//
//   node spikes/m0-probe.mjs unary session/list '{"_request":{}}'
//   node spikes/m0-probe.mjs events       # 打开 $events 流，打印前若干帧
//   node spikes/m0-probe.mjs follow <sessionId>
//
// 环境变量：DSH_AUTHORITY（默认 127.0.0.1:19387）、DSH_HOME
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const { cookieFor } = require('../tools/mint-cookie.cjs')

const authority = process.env.DSH_AUTHORITY || '127.0.0.1:19387'
const base = `http://${authority}`
const cookie = cookieFor(authority)

const rpcId = () => `m0-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`

/** unary：POST /api/<method>，注意业务错误也是 HTTP 200，必须看 result.ok */
async function unary(method, args = {}) {
  const res = await fetch(`${base}/api/${method}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({ type: 'client-request', rpcId: rpcId(), method, payload: { args } }),
  })
  const text = await res.text()
  if (res.status !== 200) return { httpStatus: res.status, body: text.slice(0, 400) }
  try { return JSON.parse(text) } catch { return { unparsed: text.slice(0, 400) } }
}

/** 打开一条流：所有流共用 /api/remote.mux 这一条 WebSocket */
function openStream(endpoint, args, { onFrame, seconds = 10 } = {}) {
  return new Promise((resolve) => {
    const ws = new WebSocket(`ws://${authority}/api/remote.mux`, { headers: { cookie } })
    const streamId = 's1'
    const frames = []
    ws.addEventListener('open', () => {
      ws.send(JSON.stringify({ type: 'open', streamId, endpoint, payload: { args } }))
    })
    ws.addEventListener('message', (ev) => {
      let frame
      try { frame = JSON.parse(ev.data) } catch { return }
      frames.push(frame)
      if (onFrame) onFrame(frame)
    })
    ws.addEventListener('error', (e) => {
      console.error('WS 错误:', e.message || e.type)
    })
    if (seconds > 0) {
      setTimeout(() => {
        try { ws.send(JSON.stringify({ type: 'cancel', streamId })) } catch {}
        ws.close()
      }, seconds * 1000)
      ws.addEventListener('close', () => resolve(frames))
    }
  })
}

const [mode, ...rest] = process.argv.slice(2)
const short = (o, n = 1200) => {
  const s = typeof o === 'string' ? o : JSON.stringify(o)
  return s.length > n ? `${s.slice(0, n)}…(共 ${s.length} 字符)` : s
}

if (mode === 'unary') {
  const method = rest[0] || 'session/list'
  const args = rest[1] ? JSON.parse(rest[1]) : {}
  const out = await unary(method, args)
  console.log(short(out, 4000))
} else if (mode === 'events') {
  const secs = Number(rest[0] || 10)
  console.log(`打开 $events，监听 ${secs}s …`)
  await openStream('$events', {}, {
    seconds: secs,
    onFrame: (f) => console.log(`[${f.type}]`, short(f.value ?? f.error ?? '', 600)),
  })
} else if (mode === 'follow') {
  const sessionId = rest[0]
  if (!sessionId) { console.error('用法: follow <sessionId>'); process.exit(1) }
  const secs = Number(rest[1] || 10)
  console.log(`打开 session/follow(${sessionId})，监听 ${secs}s …`)
  // address 是结构化地址：{kind:'session', sessionId} 或 {kind:'subagent', …}
  await openStream('session/follow', { request: { address: { kind: 'session', sessionId }, assistantStream: true } }, {
    seconds: secs,
    onFrame: (f) => console.log(`[${f.type}]`, short(f.value ?? f.error ?? '', 400)),
  })
} else {
  console.log(`用法:
  node spikes/m0-probe.mjs unary session/list '{"_request":{}}'
  node spikes/m0-probe.mjs events [秒]
  node spikes/m0-probe.mjs follow <sessionId> [秒]

当前目标: ${base}`)
}
