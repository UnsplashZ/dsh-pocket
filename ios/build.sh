#!/usr/bin/env bash
# 一条命令把 iOS 工程建起来。
#
#   bash ios/build.sh                       # 模拟器构建
#   bash ios/build.sh --device              # 真机构建（需要签名）
#   bash ios/build.sh --test                # 起模拟器并跑 App 层单测
#   bash ios/build.sh --run                 # 构建 + 装进已启动的模拟器 + 启动
#
# 这个脚本存在的理由：`xcodebuild` 有几个**必须随环境变化**的开关，
# 散在命令行里很容易漏（尤其是"没有沙箱的环境需要禁用宏插件沙箱"这一条）：
#
#   · `DSH_POCKET_SWIFT_FLAGS`：透传给 Swift 的额外参数。在受限沙箱里跑（本机 CI、
#     容器、agent 会话）需要设成 `-disable-sandbox` —— 否则 Swift 编译器的宏插件
#     宿主进程会因为 `sandbox-exec` 不能嵌套而报 "swift-plugin-server produced
#     malformed response"，表现为一排莫名其妙的 `cannot find '$xxx' in scope`。
#   · `CLANG_MODULE_CACHE_PATH`：默认落在 `/var/folders`，在受限环境里不可写，
#     于是连标准库都加载不了。这里统一指到工程目录下的 `.module-cache/`。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

SCHEME="DSHPocket"
PROJECT="DSHPocket.xcodeproj"
DERIVED="${ROOT}/.derived"
MODULE_CACHE="${ROOT}/.module-cache"
SIMULATOR="${DSH_POCKET_SIMULATOR:-iPhone 18 Pro}"
BUNDLE_ID="cc.zexa.dshpocket"

MODE="simulator"
for arg in "$@"; do
  case "${arg}" in
    --device) MODE="device" ;;
    --test) MODE="test" ;;
    --run) MODE="run" ;;
    --help|-h)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "未知参数：${arg}" >&2; exit 2 ;;
  esac
done

# 1) 依赖：IrohLib 的二进制部件（一次取好，之后离线可构建）
if [ ! -d "vendor/Iroh.xcframework" ] || [ ! -f "vendor/IrohLib.swift" ]; then
  echo "==> vendor/ 缺 Iroh 部件，先取一次"
  bash scripts/fetch-iroh.sh
fi

# 2) 工程：xcodegen 只在生成时 glob 源文件，新增文件后必须重跑
echo "==> 生成 Xcode 工程"
xcodegen generate --spec project.yml >/dev/null
if [ -f scripts/sync-xcodeproj-packages.mjs ]; then
  # 只有在用 SwiftPM 包引用时才需要；现在用工程内 target，脚本会自己判断并跳过
  node scripts/sync-xcodeproj-packages.mjs >/dev/null 2>&1 || true
fi

# 3) 环境开关
export CLANG_MODULE_CACHE_PATH="${MODULE_CACHE}"
export SWIFT_MODULECACHE_PATH="${MODULE_CACHE}"
mkdir -p "${MODULE_CACHE}"

# 受限沙箱里需要禁用宏插件沙箱（见文件头注释）。默认不开，显式设置才生效。
SWIFT_FLAGS="${DSH_POCKET_SWIFT_FLAGS:-}"

COMMON=(
  -project "${PROJECT}"
  -scheme "${SCHEME}"
  -derivedDataPath "${DERIVED}"
  "DSH_POCKET_SWIFT_FLAGS=${SWIFT_FLAGS}"
)

case "${MODE}" in
  simulator)
    echo "==> 构建（模拟器）"
    xcodebuild "${COMMON[@]}" -destination "platform=iOS Simulator,name=${SIMULATOR}" build
    ;;
  device)
    echo "==> 构建（真机，需要签名）"
    xcodebuild "${COMMON[@]}" -destination 'generic/platform=iOS' \
      -allowProvisioningUpdates build
    ;;
  test)
    echo "==> 单测（模拟器）"
    xcodebuild "${COMMON[@]}" -destination "platform=iOS Simulator,name=${SIMULATOR}" test
    ;;
  run)
    echo "==> 构建 + 启动（模拟器 ${SIMULATOR}）"
    xcodebuild "${COMMON[@]}" -destination "platform=iOS Simulator,name=${SIMULATOR}" build
    xcrun simctl boot "${SIMULATOR}" 2>/dev/null || true
    open -a Simulator 2>/dev/null || true
    sleep 4
    xcrun simctl install "${SIMULATOR}" "${DERIVED}/Build/Products/Debug-iphonesimulator/DSHPocket.app"
    xcrun simctl launch "${SIMULATOR}" "${BUNDLE_ID}"
    ;;
esac

echo "==> 完成（${MODE}）"
