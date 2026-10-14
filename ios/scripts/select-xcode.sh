#!/usr/bin/env bash
#
# 挑一个足够新的 Xcode，打印它的版本（两行，和 `xcodebuild -version` 一样）。
#
#   bash ios/scripts/select-xcode.sh          # 至少 Xcode 16
#   bash ios/scripts/select-xcode.sh 26       # 至少 Xcode 26
#
# 为什么要有这个脚本，而不是在 CI 里写三行：
#
# 1. runner 上预装了好几个 Xcode，**默认选中的那个不一定够新**。
# 2. 千万不能写 `xcodebuild -version | head -1` —— head 读一行就退出并关掉管道，
#    xcodebuild 继续往这个已经没人读的管道写，就吃到 SIGPIPE；在 macOS 上它表现为
#    `NSFileHandleOperationException … Broken pipe` 未捕获异常，直接崩掉（CI 上实测过：
#    整个 job 在选 Xcode 这一步就死了）。所以这里先把输出整段收进变量再解析。
# 3. `sort -V` 是 GNU 的选项，macOS 自带的 BSD sort 不认 —— 写成 `sort -V` 在本地永远
#    走不到（因为不报错就沉默地没换 Xcode），查起来极费劲。这里用普通的 sort。
set -euo pipefail

MIN_MAJOR="${1:-${DSH_MIN_XCODE_MAJOR:-16}}"

command -v xcodebuild >/dev/null 2>&1 || {
  echo "找不到 xcodebuild（需要 macOS + Xcode）" >&2
  exit 1
}

# 整段收下来再解析：不要在上游挂任何会提前退出的消费者。
version_output="$(xcodebuild -version)"
current="$(printf '%s\n' "${version_output}" | awk 'NR==1{print $2}')"
major="${current%%.*}"

if [ -z "${major}" ] || ! [ "${major}" -ge 0 ] 2>/dev/null || [ "${major}" -lt "${MIN_MAJOR}" ]; then
  newest="$(ls -d /Applications/Xcode_*.app 2>/dev/null | sort | tail -1 || true)"
  if [ -n "${newest}" ]; then
    echo "默认 Xcode ${current:-未知} 老于 ${MIN_MAJOR}，改用 ${newest}" >&2
    sudo xcode-select -s "${newest}"
    version_output="$(xcodebuild -version)"
  else
    echo "默认 Xcode ${current:-未知} 老于 ${MIN_MAJOR}，但 /Applications 下没有别的 Xcode" >&2
  fi
fi

printf '%s\n' "${version_output}"
