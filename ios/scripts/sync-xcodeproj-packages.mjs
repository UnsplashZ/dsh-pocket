#!/usr/bin/env node
// xcodegen 对**本地** SwiftPM 包少写一行：`XCSwiftPackageProductDependency` 里没有
// `package = <XCLocalSwiftPackageReference id>;`。少了它，Xcode 加载不了包图，
// 构建时报 `Missing package product 'DSHKit'`，而 `swift build` 一切正常 —— 很容易被
// 误判成包本身的问题。
//
// 这个脚本在 xcodegen 之后跑，把那行补回去。幂等：已经有 `package =` 的块不动。
//
//   node ios/scripts/sync-xcodeproj-packages.mjs [--project ios/DSHPocket.xcodeproj]
import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'

function parseArgs(argv) {
  let project = null
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === '--project') project = argv[++index]
  }
  return { project }
}

const { project } = parseArgs(process.argv.slice(2))
const root = path.resolve(import.meta.dirname, '..', '..')
const pbxproj = path.resolve(root, project ?? 'ios/DSHPocket.xcodeproj/project.pbxproj')

if (!fs.existsSync(pbxproj)) {
  console.error(`[sync-packages] 找不到 ${pbxproj}；先跑 xcodegen generate`)
  process.exit(1)
}

const text = fs.readFileSync(pbxproj, 'utf8')

// 1) 收集本地包引用：名字 → 对象 id
const localRefs = new Map()
const refSection = text.match(/\/\* Begin XCLocalSwiftPackageReference section \*\/([\s\S]*?)\/\* End XCLocalSwiftPackageReference section \*\//)
if (refSection) {
  for (const match of refSection[1].matchAll(/([0-9A-F]{24}) \/\* XCLocalSwiftPackageReference "([^"]+)" \*\/ = \{/g)) {
    localRefs.set(match[2], match[1])
  }
}

if (localRefs.size === 0) {
  console.log('[sync-packages] 没有本地包引用，跳过')
  process.exit(0)
}

// 2) 给每个缺 `package =` 的 product dependency 补上
const productSection = text.match(/\/\* Begin XCSwiftPackageProductDependency section \*\/([\s\S]*?)\/\* End XCSwiftPackageProductDependency section \*\//)
if (!productSection) {
  console.error('[sync-packages] 找不到 XCSwiftPackageProductDependency 段')
  process.exit(1)
}

let patched = 0
const rewritten = productSection[1].replace(
  /(\t\t[0-9A-F]{24} \/\* ([^*]+) \*\/ = \{\n\t\t\tisa = XCSwiftPackageProductDependency;\n)((?:\t\t\t[^\n]*\n)*?)(\t\t\};)/g,
  (whole, head, productName, body, tail) => {
    if (body.includes('package =')) return whole
    const refId = localRefs.get(productName.trim())
    if (!refId) return whole
    patched += 1
    return `${head}${body}\t\t\tpackage = ${refId} /* XCLocalSwiftPackageReference "${productName.trim()}" */;\n${tail}`
  }
)

if (patched === 0) {
  console.log('[sync-packages] 本地包引用已完整，无需修改')
  process.exit(0)
}

fs.writeFileSync(pbxproj, text.replace(productSection[1], rewritten))
console.log(`[sync-packages] 已为 ${patched} 个 product dependency 补上 package 反引用`)
