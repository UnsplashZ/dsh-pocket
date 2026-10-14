#!/usr/bin/env bash
#
# 打一个**未签名**的 .ipa —— 本仓库对外分发的唯一形态。
#
#   bash ios/scripts/make-ipa.sh                          # 版本号取 ios/VERSION
#   bash ios/scripts/make-ipa.sh --version 0.3.1 --build 42
#   bash ios/scripts/make-ipa.sh --out /tmp/dist
#
# 产出（默认写到仓库根的 dist/）：
#   DSHPocket-<version>-unsigned.ipa
#   DSHPocket-<version>-unsigned.ipa.sha256
#   DSHPocket-<version>-build.log          构建全量日志（失败时也会留档）
#
# 为什么需要这个脚本，而不是在 CI 里现写一遍命令：
#   · 「关签名」在 xcodebuild 里是**四个**开关一起才成立的，漏一个就会去要开发者证书
#     （CI 上必然失败，本地则悄悄用你的证书签出一个不该外发的包）；
#   · 产物必须被**断言**过才能进 Release：版本号对不对、是否真的没签名、
#     Payload/ 结构对不对 —— 这三条都在这里做成硬失败，而不是靠人工看一眼；
#   · 同一套逻辑要被本地、CI、以及第三方复现，只能有一份实现。
set -euo pipefail

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "${IOS_DIR}/.." && pwd)"

SCHEME="DSHPocket"
PROJECT="DSHPocket.xcodeproj"
PRODUCT_NAME="DSHPocket"
CONFIGURATION="Release"
VERSION=""
BUILD=""
OUT_DIR="${ROOT}/dist"
DERIVED="${IOS_DIR}/.derived"

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?--version 需要值}"; shift 2 ;;
    --build)   BUILD="${2:?--build 需要值}"; shift 2 ;;
    --out)     OUT_DIR="${2:?--out 需要值}"; shift 2 ;;
    --config)  CONFIGURATION="${2:?--config 需要值}"; shift 2 ;;
    --help|-h) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1（--help 看用法）" >&2; exit 2 ;;
  esac
done

if [ -z "${VERSION}" ]; then
  VERSION="$(bash "${IOS_DIR}/scripts/version.sh" get)"
fi
if [ -z "${BUILD}" ]; then
  BUILD="$(bash "${IOS_DIR}/scripts/version.sh" build)"
  [ -n "${BUILD}" ] || BUILD="1"
fi

# 版本号同时进文件名与 Info.plist，先卡住格式：带空格的产物名会让所有下游脚本难写
printf '%s' "${VERSION}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || { echo "版本号必须形如 X.Y.Z，收到：${VERSION}" >&2; exit 1; }
printf '%s' "${BUILD}" | grep -Eq '^[0-9]+$' \
  || { echo "构建号必须是数字，收到：${BUILD}" >&2; exit 1; }

ARTIFACT="${PRODUCT_NAME}-${VERSION}-unsigned.ipa"
mkdir -p "${OUT_DIR}"
LOG="${OUT_DIR}/${PRODUCT_NAME}-${VERSION}-build.log"

echo "==> 版本 ${VERSION}（构建号 ${BUILD}）→ ${OUT_DIR}/${ARTIFACT}"

# ── 1. iroh 预编译部件（约 42 MB，不入库；CI 上由 actions/cache 兜住）──────────
if [ ! -d "${IOS_DIR}/vendor/Iroh.xcframework" ] || [ ! -f "${IOS_DIR}/vendor/IrohLib.swift" ]; then
  echo "==> vendor/ 缺 Iroh 部件，先取一次"
  bash "${IOS_DIR}/scripts/fetch-iroh.sh"
fi

# ── 2. 生成 Xcode 工程（xcodegen 只在生成时 glob 源文件）─────────────────────
echo "==> 生成 Xcode 工程"
command -v xcodegen >/dev/null 2>&1 || {
  echo "缺 xcodegen。macOS 上：brew install xcodegen" >&2; exit 1; }
( cd "${IOS_DIR}" && xcodegen generate --spec project.yml >/dev/null )

# ── 3. 环境开关（受限沙箱里必须禁用宏插件沙箱，见 ios/build.sh 的说明）───────
export CLANG_MODULE_CACHE_PATH="${IOS_DIR}/.module-cache"
export SWIFT_MODULECACHE_PATH="${IOS_DIR}/.module-cache"
mkdir -p "${CLANG_MODULE_CACHE_PATH}"
mkdir -p "${DERIVED}"

# ── 4. 构建：关掉签名，只出 arm64 真机切片 ──────────────────────────────────
# CODE_SIGNING_ALLOWED=NO 是主开关；另外三个是它不出意外时的补刀 ——
# 有些 target（工程内静态框架）会各自带着自己的签名设置进来。
echo "==> xcodebuild（Release / generic iOS device / 未签名）"
set +e
xcodebuild \
  -project "${IOS_DIR}/${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "${DERIVED}" \
  -sdk iphoneos \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  EXPANDED_CODE_SIGN_IDENTITY="" \
  MARKETING_VERSION="${VERSION}" \
  CURRENT_PROJECT_VERSION="${BUILD}" \
  "DSH_POCKET_SWIFT_FLAGS=${DSH_POCKET_SWIFT_FLAGS:-}" \
  build > "${LOG}" 2>&1
STATUS=$?
set -e
if [ ${STATUS} -ne 0 ]; then
  echo "构建失败（完整日志：${LOG}）。最后 40 行：" >&2
  tail -40 "${LOG}" >&2
  exit ${STATUS}
fi

APP="${DERIVED}/Build/Products/${CONFIGURATION}-iphoneos/${PRODUCT_NAME}.app"
[ -d "${APP}" ] || { echo "构建成功但找不到 ${APP}" >&2; exit 1; }

# ── 5. 断言：版本号真的进了包 ──────────────────────────────────────────────
echo "==> 校验 Info.plist"
PLIST="${APP}/Info.plist"
[ -f "${PLIST}" ] || { echo "包里没有 Info.plist" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "${PLIST}" 2>/dev/null || true; }

GOT_VERSION="$(plist CFBundleShortVersionString)"
GOT_BUILD="$(plist CFBundleVersion)"
[ "${GOT_VERSION}" = "${VERSION}" ] \
  || { echo "版本号不符：期望 ${VERSION}，包内 ${GOT_VERSION}" >&2; exit 1; }
[ "${GOT_BUILD}" = "${BUILD}" ] \
  || { echo "构建号不符：期望 ${BUILD}，包内 ${GOT_BUILD}" >&2; exit 1; }
echo "    CFBundleShortVersionString=${GOT_VERSION}  CFBundleVersion=${GOT_BUILD}"

EXECUTABLE="$(plist CFBundleExecutable)"
[ -f "${APP}/${EXECUTABLE}" ] || { echo "包里没有可执行文件 ${EXECUTABLE}" >&2; exit 1; }

# ── 6. 断言：这个包必须是**没签名**的 ──────────────────────────────────────
# 签过的包带着某个人的证书与描述文件，既装不到别人机器上，也不该出现在 Release 里。
if codesign -dv "${APP}" >/dev/null 2>&1; then
  IDENTITY="$(codesign -dv "${APP}" 2>&1 | perl -ne 'print "$1\n" and exit if /^Authority=(.*)$/')"
  if [ -n "${IDENTITY}" ] && [ "${IDENTITY}" != "-" ]; then
    echo "产物被真实证书签过了（Authority=${IDENTITY}）—— 拒绝外发。" >&2
    echo "请确认 CODE_SIGNING_ALLOWED=NO 真的生效（常见原因：工程里写死了 CODE_SIGN_IDENTITY）。" >&2
    exit 1
  fi
  echo "    ad-hoc 签名（无证书身份，符合预期）"
else
  echo "    未签名（符合预期）"
fi

# ── 7. 打包成 ipa ─────────────────────────────────────────────────────────
echo "==> 打包 Payload/"
WORK="$(mktemp -d -t dshpocket-ipa)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/Payload"
cp -R "${APP}" "${WORK}/Payload/"

rm -f "${OUT_DIR}/${ARTIFACT}"
( cd "${WORK}" && zip -qry "${OUT_DIR}/${ARTIFACT}" Payload )

# ── 8. 断言：ipa 结构与内容自洽 ────────────────────────────────────────────
LISTING="$(unzip -l "${OUT_DIR}/${ARTIFACT}")"
for needle in "Payload/${PRODUCT_NAME}.app/Info.plist" "Payload/${PRODUCT_NAME}.app/${EXECUTABLE}"; do
  printf '%s' "${LISTING}" | grep -q "${needle}" \
    || { echo "ipa 里缺少 ${needle}" >&2; exit 1; }
done
if printf '%s\n' "${LISTING}" | grep -q "Payload/${PRODUCT_NAME}.app/_CodeSignature"; then
  echo "ipa 里带着 _CodeSignature/ —— 这不是未签名包" >&2
  exit 1
fi
echo "    Payload/ 结构正确、无 _CodeSignature/"

# ── 9. 校验和 ─────────────────────────────────────────────────────────────
( cd "${OUT_DIR}" && shasum -a 256 "${ARTIFACT}" > "${ARTIFACT}.sha256" )

SIZE="$(du -h "${OUT_DIR}/${ARTIFACT}" | awk '{print $1}')"
echo "==> 完成：${OUT_DIR}/${ARTIFACT}（${SIZE}）"
cat "${OUT_DIR}/${ARTIFACT}.sha256"
echo
echo "这个包**没有签名**，装不进任何设备，需要安装者用自己的 Apple ID 重签："
echo "  见 docs/INSTALL-UNSIGNED-IPA.md"
