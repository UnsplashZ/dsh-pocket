#!/usr/bin/env bash
#
# 挑一台可用的 iPhone 模拟器并打印出来。
#
#   bash ios/scripts/pick-simulator.sh              # 打印 UDID（默认）
#   bash ios/scripts/pick-simulator.sh --name       # 打印机型名（`-destination …name=` / simctl 用）
#   bash ios/scripts/pick-simulator.sh --list       # 列出所有候选
#
# 为什么不能把机型名写死：模拟器机型跟着 Xcode 版本走（Xcode 27 有 "iPhone 18 Pro"，
# Xcode 16 只到 "iPhone 16"），写死会让构建脚本在别人的机器上和 CI 上直接失败 ——
# 而这类失败看上去像"工程坏了"，实际只是名字对不上。
set -euo pipefail

MODE="${1:-udid}"

command -v xcrun >/dev/null 2>&1 || { echo "找不到 xcrun（需要 macOS + Xcode）" >&2; exit 1; }
command -v node  >/dev/null 2>&1 || { echo "找不到 node（需要 Node ≥ 22，见 README 前置条件）" >&2; exit 1; }

JSON="$(xcrun simctl list devices available --json)"

# 排序规则：iOS runtime 从新到旧；同一 runtime 内优先名字里数字大的（更新的机型），
# 并跳过 Plus / SE / mini 这类不适合当默认测试机的型号。
UDID_LIST="$(PICK_MODE="${MODE}" node -e '
  const fs = require("fs");
  const data = JSON.parse(fs.readFileSync(0, "utf8"));
  const found = [];
  for (const [runtime, devices] of Object.entries(data.devices || {})) {
    if (!/iOS[- ]/.test(runtime)) continue;
    const rv = (runtime.match(/(\d+)-(\d+)/) || []).slice(1).map(Number);
    const rkey = (rv[0] || 0) * 1000 + (rv[1] || 0);
    for (const d of devices) {
      if (!d.isAvailable || !/^iPhone/.test(d.name)) continue;
      if (/Plus|SE|mini/.test(d.name)) continue;
      const n = (d.name.match(/(\d+)/) || [0, 0])[1];
      found.push({ runtime: rkey, model: Number(n), name: d.name, udid: d.udid });
    }
  }
  found.sort((a, b) => b.runtime - a.runtime || b.model - a.model || a.name.localeCompare(b.name));
  const mode = process.env.PICK_MODE || "udid";
  if (mode === "--list") for (const d of found) console.log(`${d.name}\t${d.udid}`);
  else if (found.length) console.log(mode === "--name" ? found[0].name : found[0].udid);
' <<< "${JSON}")"

if [ -z "${UDID_LIST}" ]; then
  echo "没有可用的 iPhone 模拟器。先装一个 iOS runtime：" >&2
  echo "  xcodebuild -downloadPlatform iOS" >&2
  exit 1
fi

printf '%s\n' "${UDID_LIST}"
