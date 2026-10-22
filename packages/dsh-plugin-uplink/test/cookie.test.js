import assert from 'node:assert/strict'
import test from 'node:test'

import { createCookieSource } from '../lib/cookie.js'

/** 造一个假的 token 兑换应答（303 + 一条 set-cookie）。 */
function fakeFetch({ status = 303, cookies = ['dsh-auth-abc=v1.xyz; Path=/; HttpOnly; SameSite=Strict'] } = {}) {
  const calls = []
  const impl = async (url, init) => {
    calls.push({ url, init })
    return {
      status,
      headers: { getSetCookie: () => cookies },
    }
  }
  impl.calls = calls
  return impl
}

test('兑换成功：拿到 name=value（丢掉 Path/HttpOnly 这些属性）', async () => {
  const fetchImpl = fakeFetch()
  const source = createCookieSource({
    authenticatedUrl: () => 'http://127.0.0.1:1/?token=t',
    authority: '127.0.0.1:1',
    fetchImpl,
  })
  const result = await source.start()
  assert.equal(result.cookie, 'dsh-auth-abc=v1.xyz')
  assert.equal(result.authority, '127.0.0.1:1')
  assert.equal(source.status().ready, true)
  assert.equal(source.status().cookieName, 'dsh-auth-abc')
  source.stop()
})

test('每次兑换成功都回调 onRefresh —— iroh sidecar 靠它拿到新 cookie', async () => {
  const seen = []
  const source = createCookieSource({
    authenticatedUrl: () => 'http://127.0.0.1:1/?token=t',
    authority: '127.0.0.1:1',
    fetchImpl: fakeFetch(),
    onRefresh: (auth) => seen.push(auth.cookie),
  })
  await source.start()
  await source.refresh()
  assert.deepEqual(seen, ['dsh-auth-abc=v1.xyz', 'dsh-auth-abc=v1.xyz'])
  source.stop()
})

test('onRefresh 抛错不影响兑换本身（cookie 已经拿到了）', async () => {
  const source = createCookieSource({
    authenticatedUrl: () => 'http://127.0.0.1:1/?token=t',
    authority: '127.0.0.1:1',
    fetchImpl: fakeFetch(),
    onRefresh: () => { throw new Error('下游炸了') },
  })
  const result = await source.start()
  assert.equal(result.cookie, 'dsh-auth-abc=v1.xyz')
  assert.equal(source.status().ready, true)
  source.stop()
})

test('兑换失败保留旧 cookie，并记下原因（不静默）', async () => {
  let fail = false
  const fetchImpl = async () => {
    if (fail) return { status: 401, headers: { getSetCookie: () => [] } }
    return { status: 303, headers: { getSetCookie: () => ['dsh-auth-abc=v1; Path=/'] } }
  }
  const source = createCookieSource({
    authenticatedUrl: () => 'http://127.0.0.1:1/?token=t',
    authority: '127.0.0.1:1',
    fetchImpl,
  })
  await source.start()
  fail = true
  const second = await source.refresh()
  assert.equal(second, null)
  assert.equal(source.status().ready, true, '旧 cookie 还留着')
  assert.match(source.status().lastError, /401/)
  source.stop()
})
