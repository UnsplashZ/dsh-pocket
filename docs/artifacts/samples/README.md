# samples

放**现场生成**的抓包样例（协议回归对照用）。内容可能含私人会话文本，因此 `*.json` / `*.txt` 已进 `.gitignore`，只有本说明文件入库。

生成方式：

```bash
node spikes/m0-probe.mjs unary session/list '{"_request":{}}' > docs/artifacts/samples/session-list.json
node spikes/m0-probe.mjs events 10 > docs/artifacts/samples/events.txt
node spikes/m0-probe.mjs follow <sessionId> 10 > docs/artifacts/samples/follow.txt
```
