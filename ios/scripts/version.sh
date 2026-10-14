#!/usr/bin/env bash
#
# 版本号的唯一真源是 `ios/VERSION`。本脚本是它唯一的读写入口，
# 也是 CI 与本地唯一的版本号出口 —— 想改版本号就改这里，别手改 project.yml。
#
#   bash ios/scripts/version.sh get                    # 打印版本号（0.3.0）
#   bash ios/scripts/version.sh tag                    # 打印 tag 名（v0.3.0）
#   bash ios/scripts/version.sh build                  # 打印 project.yml 里的构建号
#   bash ios/scripts/version.sh sync [<build>]         # 把 ios/VERSION 写进 project.yml
#   bash ios/scripts/version.sh set <X.Y.Z> [<build>]  # 改版本号并同步
#   bash ios/scripts/version.sh bump <major|minor|patch>
#   bash ios/scripts/version.sh check <X.Y.Z|vX.Y.Z>   # 断言一致，不一致退出 1（CI 用）
#
# 设计取舍：
#   · 构建号（CURRENT_PROJECT_VERSION）**不是**版本内容的一部分，所以不写进 ios/VERSION：
#     同一个版本号被反复构建是常态，构建号应当由构建方决定。本地默认沿用 project.yml
#     里的值，CI 用 `github.run_number` 覆盖（xcodebuild 命令行覆盖优先于 project.yml）。
#   · 只依赖 perl，不依赖 GNU/BSD 各自的 sed -i 方言，macOS 与 ubuntu runner 行为一致。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION_FILE="${ROOT}/ios/VERSION"
PROJECT_YML="${ROOT}/ios/project.yml"

die() { echo "version.sh: $*" >&2; exit 1; }

[ -f "${VERSION_FILE}" ] || die "找不到 ${VERSION_FILE}"

read_version() {
  # 取第一个非空、非注释行，去掉首尾空白
  perl -ne 'next if /^\s*(#|$)/; s/^\s+|\s+$//g; print "$_\n"; exit' "${VERSION_FILE}"
}

write_version() {
  printf '%s\n' "$1" > "${VERSION_FILE}"
}

read_build() {
  [ -f "${PROJECT_YML}" ] || die "找不到 ${PROJECT_YML}"
  perl -ne 'print "$1\n" and exit if /^\s*CURRENT_PROJECT_VERSION:\s*"?([0-9]+)"?\s*$/' "${PROJECT_YML}"
}

# 把 MARKETING_VERSION / CURRENT_PROJECT_VERSION 写进 project.yml。
# 写成单点替换而不是整段重排，是为了让 diff 只有一行，评审时一眼能看出改动。
sync_project_yml() {
  local version="$1" build="${2:-}"
  [ -f "${PROJECT_YML}" ] || die "找不到 ${PROJECT_YML}"

  perl -i -pe "s/^(\s*MARKETING_VERSION:\s*).*\$/\${1}\"${version}\"/" "${PROJECT_YML}"
  if [ -n "${build}" ]; then
    perl -i -pe "s/^(\s*CURRENT_PROJECT_VERSION:\s*).*\$/\${1}${build}/" "${PROJECT_YML}"
  fi

  # 写完立刻回读断言：静默失配比报错危险得多（构建出来的包会带着旧版本号）
  local got_ver got_build
  got_ver="$(perl -ne 'print "$1\n" and exit if /^\s*MARKETING_VERSION:\s*"?([^"\s]+)"?\s*$/' "${PROJECT_YML}")"
  [ "${got_ver}" = "${version}" ] || die "写 project.yml 失败：期望 ${version}，实际 ${got_ver}"
  if [ -n "${build}" ]; then
    got_build="$(read_build)"
    [ "${got_build}" = "${build}" ] || die "写构建号失败：期望 ${build}，实际 ${got_build}"
  fi
}

valid_semver() {
  printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

cmd="${1:-get}"
shift || true

case "${cmd}" in
  get)
    read_version
    ;;

  tag)
    echo "v$(read_version)"
    ;;

  build)
    read_build
    ;;

  sync)
    sync_project_yml "$(read_version)" "${1:-}"
    echo "project.yml ← MARKETING_VERSION=$(read_version)${1:+ CURRENT_PROJECT_VERSION=$1}"
    ;;

  set)
    [ $# -ge 1 ] || die "用法：version.sh set <X.Y.Z> [<build>]"
    valid_semver "$1" || die "版本号必须形如 X.Y.Z，收到：$1"
    write_version "$1"
    sync_project_yml "$1" "${2:-}"
    echo "$1"
    ;;

  bump)
    [ $# -ge 1 ] || die "用法：version.sh bump <major|minor|patch>"
    cur="$(read_version)"
    valid_semver "${cur}" || die "ios/VERSION 里的版本号不合法：${cur}"
    IFS=. read -r major minor patch <<< "${cur}"
    case "$1" in
      major) major=$((major + 1)); minor=0; patch=0 ;;
      minor) minor=$((minor + 1)); patch=0 ;;
      patch) patch=$((patch + 1)) ;;
      *) die "未知的递增类型：$1（可选 major / minor / patch）" ;;
    esac
    next="${major}.${minor}.${patch}"
    write_version "${next}"
    sync_project_yml "${next}"
    echo "${next}"
    ;;

  # CI 在打 tag 时用这个把「tag 名」与「仓库里的版本号」对齐，
  # 避免出现 tag 是 v0.4.0、包里却印着 0.3.0 的发布事故。
  check)
    [ $# -ge 1 ] || die "用法：version.sh check <X.Y.Z|vX.Y.Z>"
    want="${1#v}"
    have="$(read_version)"
    if [ "${want}" != "${have}" ]; then
      echo "版本号不一致：tag/期望 = ${want}，ios/VERSION = ${have}" >&2
      echo "先把 ios/VERSION 改成 ${want}（bash ios/scripts/version.sh set ${want}）再打 tag。" >&2
      exit 1
    fi
    echo "版本号一致：${have}"
    ;;

  *)
    die "未知子命令：${cmd}（见脚本头部注释）"
    ;;
esac
