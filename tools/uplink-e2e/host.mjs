// 起一个**独立的** iroh sidecar（不依赖正在运行的 dsh 插件），供 uplink-e2e 客户端验证。
//
// 为什么要独立起：跑着的 dsh 里那版插件还没接 cookie 注入，用它验证不了这条修复。
// 这里直接把 cookie 递给 sidecar，然后打印配对串 —— 客户端连上来应当看到 dsh 页面 200。
import { createRequire } from 'node:module'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createIrohTier, resolveHostBinary } from '../../packages/dsh-plugin-uplink/lib/tiers/iroh.js'

const require = createRequire(import.meta.url)
const { cookieFor } = require('../mint-cookie.cjs')

const DSH_PORT = Number(process.env.DSH_PORT ?? 52652)
const authority = `127.0.0.1:${DSH_PORT}`
const dataDir = mkdtempSync(join(tmpdir(), 'uplink-e2e-iroh-'))

const tier = createIrohTier({
  binaryPath: resolveHostBinary(),
  proxyTarget: authority,
  dataDir,
  lang: 'zh',
  logger: { info: (m) => console.error('  ' + m), warn: (m) => console.error('  ! ' + m) },
})

const started = await tier.start()
if (started.ok !== true) {
  console.error('sidecar 起不来:', started.reason)
  process.exit(1)
}
console.error('endpoint:', started.endpointId)

const cookie = cookieFor(authority)
const sent = tier.setProxyAuth({ cookie, authority })
console.error('proxy-auth 已发送:', sent, '| cookie:', cookie.split('=', 1)[0])

const opened = await tier.openPairing()
if (opened.ok === false) {
  console.error('配对窗口打不开:', opened.reason)
  process.exit(1)
}
writeFileSync('/tmp/uplink-e2e-pairing.txt', opened.pairingString)
console.error('配对串已写入 /tmp/uplink-e2e-pairing.txt（有效期', opened.expiresInSec, '秒）')
console.error('等待客户端连接…')

const shutdown = async () => {
  await tier.stop()
  process.exit(0)
}
process.on('SIGTERM', shutdown)
process.on('SIGINT', shutdown)
setTimeout(shutdown, 180_000)
