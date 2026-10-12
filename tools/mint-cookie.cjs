#!/usr/bin/env node
// 为一个 DSH host authority 现签一个合法的浏览器会话 cookie。
//
// 原理（读自 @deepseek-ai/dsh-client-connection）：
//   name  = "dsh-auth-" + base64url(sha256(authority))
//   value = "v1." + base64url(JSON( payload )) + "." + base64url(hmac_sha256(secret, body))
//   payload = { version: 1, authority, issuedAt, expiresAt }
// 其中 secret 是 $DSH_HOME/.credentials.yaml 里 client-connection/browser-session 的 32 字节密钥。
//
// 用途：本机开发时让浏览器/脚本以合法身份访问 127.0.0.1:<port>（协议 spike、dev 代理）。
// 注意：这是**本机等价于用户本人**的凭据，不要外传、不要写进仓库。
'use strict'
const fs = require('fs')
const crypto = require('crypto')

const DEFAULT_HOME = process.env.DSH_HOME || `${process.env.HOME}/.dsh`

function readSecret(dshHome = DEFAULT_HOME) {
  const lines = fs.readFileSync(`${dshHome}/.credentials.yaml`, 'utf8').split('\n')
  const indentOf = (l) => l.length - l.trimStart().length
  const keyOf = (l) => { const m = l.trim().match(/^([^:]+):(.*)$/); return m ? [m[1], m[2].trim()] : null }

  const start = lines.findIndex((l) => { const k = keyOf(l); return k && k[0] === 'client-connection/browser-session' })
  if (start === -1) throw new Error('未找到 client-connection/browser-session 记录')
  const baseIndent = indentOf(lines[start])
  for (let i = start + 1; i < lines.length; i++) {
    if (!lines[i].trim()) continue
    if (indentOf(lines[i]) <= baseIndent) break
    const k = keyOf(lines[i])
    if (k && k[0] === 'secret') return k[1].replace(/^['"]|['"]$/g, '')
  }
  throw new Error('该记录里没有 secret')
}

const b64url = (buf) => Buffer.from(buf).toString('base64').replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '')
const decodeB64url = (v) => Buffer.from(v.replaceAll('-', '+').replaceAll('_', '/') + '='.repeat((4 - v.length % 4) % 4), 'base64')

/** 返回形如 `<cookieName>=<cookieValue>` 的 Cookie 头值。 */
function cookieFor(authority, { dshHome = DEFAULT_HOME } = {}) {
  const secret = decodeB64url(readSecret(dshHome))
  if (secret.byteLength !== 32) throw new Error(`secret 长度异常: ${secret.byteLength}`)
  const issuedAt = Date.now()
  const expiresAt = issuedAt + 30 * 24 * 60 * 60 * 1000
  const body = b64url(Buffer.from(JSON.stringify({ version: 1, authority, issuedAt, expiresAt }), 'utf8'))
  const sig = b64url(crypto.createHmac('sha256', secret).update(body).digest())
  const name = 'dsh-auth-' + b64url(crypto.createHash('sha256').update(authority).digest())
  return `${name}=v1.${body}.${sig}`
}

module.exports = { cookieFor, readSecret }

if (require.main === module) {
  const authority = process.argv[2] || '127.0.0.1:19387'
  process.stdout.write(cookieFor(authority))
}
