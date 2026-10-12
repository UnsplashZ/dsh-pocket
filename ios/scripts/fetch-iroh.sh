#!/usr/bin/env bash
# 把 IrohLib 的两个部件取到 ios/vendor/ 下（一次就好，之后离线可构建）：
#
#   1. Iroh.xcframework     —— iroh-ffi 的预编译静态库（含真机/模拟器/macOS 四个切片，
#                              模块名是 `Iroh`，来自 release 附件 IrohLib.xcframework.zip）
#   2. IrohLib.swift        —— 官方 Swift 绑定（UniFFI 生成，模块名 `IrohLib`，`import Iroh`）
#
# 为什么要有这一步：Xcode 工程把这两个部件做成**工程内**的 `IrohLib` target，
# 于是 `xcodebuild` 完全不依赖 SwiftPM 解析（不需要网络、不受 Xcode 的 SwiftPM 状态影响）。
# SwiftPM 侧的 `Package.swift`（swift test / M0b spike 用）仍然从官方仓库拉同一个版本 ——
# 两边的版本号由下面这两个常量钉在一起。
#
#   bash ios/scripts/fetch-iroh.sh [--force]
set -euo pipefail

VERSION="1.1.0"
TAG="v${VERSION}"
# 与 iroh-ffi v1.1.0 的 Package.swift 里 releaseChecksum 一致
XCFRAMEWORK_SHA256="ad46dadf09f9224157512992923562931ed60f252414230d50893a4d515c5776"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENDOR="${ROOT}/ios/vendor"
FORCE="${1:-}"

mkdir -p "${VENDOR}"

need_download() {
  [ "${FORCE}" = "--force" ] && return 0
  [ ! -d "${VENDOR}/Iroh.xcframework" ] || [ ! -f "${VENDOR}/IrohLib.swift" ]
}

if ! need_download; then
  echo "vendor/ 已就绪（要强制重取请加 --force）"
  echo "  ${VENDOR}/Iroh.xcframework"
  echo "  ${VENDOR}/IrohLib.swift"
  exit 0
fi

echo "==> 下载 IrohLib.xcframework.zip（iroh-ffi ${TAG}，约 42 MB）"
ZIP="$(mktemp -t iroh-xcframework).zip"
curl -fL --retry 3 --connect-timeout 20 \
  "https://github.com/n0-computer/iroh-ffi/releases/download/${TAG}/IrohLib.xcframework.zip" \
  -o "${ZIP}"

echo "==> 校验 sha256"
ACTUAL="$(shasum -a 256 "${ZIP}" | awk '{print $1}')"
if [ "${ACTUAL}" != "${XCFRAMEWORK_SHA256}" ]; then
  echo "校验失败：期望 ${XCFRAMEWORK_SHA256}，实际 ${ACTUAL}" >&2
  rm -f "${ZIP}"
  exit 1
fi
echo "    ok ${ACTUAL}"

echo "==> 解包到 vendor/"
rm -rf "${VENDOR}/Iroh.xcframework" "${VENDOR}/.unzip"
mkdir -p "${VENDOR}/.unzip"
unzip -q "${ZIP}" -d "${VENDOR}/.unzip"
rm -f "${ZIP}"

# 包里是 IrohLib.xcframework；工程里按 binaryTarget 的名字叫 Iroh.xcframework
SOURCE_XC="$(find "${VENDOR}/.unzip" -maxdepth 2 -name "*.xcframework" -type d | head -1)"
if [ -z "${SOURCE_XC}" ]; then
  echo "压缩包里没有 .xcframework" >&2
  exit 1
fi
mv "${SOURCE_XC}" "${VENDOR}/Iroh.xcframework"
rm -rf "${VENDOR}/.unzip"

echo "==> 下载 IrohLib.swift（${TAG} 的绑定源码）"
curl -fL --retry 3 --connect-timeout 20 \
  "https://raw.githubusercontent.com/n0-computer/iroh-ffi/${TAG}/IrohLib/Sources/IrohLib/IrohLib.swift" \
  -o "${VENDOR}/IrohLib.swift"

if ! grep -q "^import Iroh" "${VENDOR}/IrohLib.swift"; then
  echo "IrohLib.swift 不像预期的绑定源码（缺 import Iroh）" >&2
  exit 1
fi

cat > "${VENDOR}/VERSION" <<EOF
iroh-ffi ${TAG}
xcframework sha256 ${XCFRAMEWORK_SHA256}
fetched $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

echo "==> 完成"
echo "  ${VENDOR}/Iroh.xcframework"
echo "  ${VENDOR}/IrohLib.swift"
