# 5Mbps 中转带宽下的请求控制技术方案

状态:待评审 → 待实施(方案 1-3 在 agentd,方案 4 随下个 iOS build)
日期:2026-07-08
前置:`internal/httpapi/appserver_history_media.go` 的历史响应图片改写(imageGeneration.result + image data URL)与 thread/resume redact-only 管道已于 2026-07-07 部署。

## 1. 背景与约束

链路拓扑:

```
iPad (MimiRemote) ⇄ VPS 中转(5Mbps 出口,上下行共享)⇄ Mac agentd(:8787)⇄ 托管 codex app-server(ws://127.0.0.1:4222)
```

关键事实:VPS 计费带宽是**出口方向**。下行(Mac→iPad 的帧)和上行(iPad→Mac 的请求)分别经 VPS→iPad 和 VPS→Mac 两段出口,**合计共享 5Mbps ≈ 625KB/s**,可持续吞吐按 ~500KB/s 规划。

2026-07-07 晚实测基线(`/api/diagnostics/relay`):

| 流量源 | 实测 | 5Mbps 下的传输时间 |
|---|---|---|
| 实时通知(icon 生成类 turn) | 108MB/10min、38MB/4.5min、20.5MB/2min | 108MB 需 29 分钟 → 管道永久淤塞,连接以 i/o timeout / 1006 反复死亡 |
| 历史响应(redact 后) | ≤2MB/响应(cap) | 3.4s/个 |
| media 按需取图 | 1.2MB PNG → base64 JSON ~1.6MB | ~3s/张 |
| thread/list 轮询 | 2 通道 × ~26KB / 8s | ~0.7% 带宽,可忽略 |
| 用户上行截图 | ~300KB/张 | ~0.5s/张,合理 |

结论:问题不是"请求太多",是"**单帧太大 + 大帧无节制并发**"。

设计原则:

1. 任何单帧 ≤ 2MB(≈3.4s 管道占用,交互可感知但可接受);
2. 后台批量流量(历史/取图)在任意窗口内 ≤ 管道 40%,交互流量(delta、状态、审批)优先;
3. 图片一律"短 URL + 按需取",不随流推送;同一内容只传一次(去重);
4. 服务端兜底、客户端配合:旧 build 不升级也不能把链路打死。

## 2. 方案 1:通知帧图片改写 + media store 内容哈希去重(收益 ~95%)

### 现状

`observeUpstreamFrame`(appserver_gateway.go)只对「响应帧且命中 pendingHistory」执行 `redactInlineHistoryImagesInGatewayResponse`。通知帧(`frame.Method != "" && frame.ID == nil`,如 `item/started`/`item/completed`,params.item 内嵌完整 item)原样转发。imageGeneration 一张 1.4-1.9MB 的裸 base64 会随 generating→completed 状态推送 **2-4 遍**;用户 userMessage 图片也会在 turn 回显中重复出现。

### 改动点

**a) 通知帧接入 redaction**(appserver_gateway.go)

在 `observeUpstreamFrame` 的通知分支(现在直接透传的路径)加:

```go
// 通知帧(method 且无 id):item/started、item/completed 等会内嵌完整 item,
// 图片走与历史响应同一套改写;gate 用内容判定而非方法名,防上游方法名漂移。
if strings.TrimSpace(frame.Method) != "" && frame.ID == nil {
    if redacted, changed := p.router.redactInlineHistoryImagesInGatewayResponse(payload); changed {
        payload = redacted
    }
    return payload, true, nil
}
```

- gate 维持现有两个内容标记:`data:image/`、`"imageGeneration"`(bytes.Contains,GB/s 级扫描,对 `item/agentMessage/delta` 等小帧零成本);
- 命中才做完整 JSON decode(实测 2MB 帧 policy 耗时 ≤35ms,可接受);
- server→client 请求帧(method+id,如 `item/tool/requestUserInput`)不改写——审批/输入请求不带大图,且改写请求语义风险不值得;
- **仅 codex 通道**。claude_gateway.go 走 bridge stdout 独立拷贝循环,帧结构不同,且当前 Claude 通道无图片工具输出,列为后续观察项。

**b) media store 内容哈希去重**(appserver_history_media.go)

```go
type appServerHistoryMediaStore struct {
    mu         sync.Mutex
    entries    map[string]appServerHistoryMediaEntry
    idByHash   map[[32]byte]string   // 新增:SHA-256(data) → id
    totalBytes int64
}
```

- `put()` 先算 `sha256.Sum256(data)`,命中 `idByHash` 时刷新该 entry 的 `lastAccess` 并直接返回旧 id(重复推送零新增内存、且客户端 URL 稳定可缓存);
- 淘汰(TTL 过期 / 容量驱逐)时同步删除 `idByHash` 反向项;
- SHA-256 2MB ≈ 5ms,只在真的携带大图的帧上发生。

**c) 观测计数**(relay_monitor.go)

`recordForward` 已同时拿到 `payloadBytes` 与 `forwardedBytes`,补两个连接级字段并暴露到 diagnostics:

- `redacted_frames`:payloadBytes != forwardedBytes 的帧数;
- `redacted_bytes_saved`:Σ(payloadBytes − forwardedBytes)。

验收就看这两个数 + 通知期间连接不再 i/o timeout。

**d) 兜底开关**

env `AGENTD_MEDIA_REDACT_NOTIFICATIONS=off` 可整体关闭通知帧改写(默认 on),与 launchd plist 的现有 env 覆盖机制一致。出问题一条 `launchctl bootout/bootstrap` 即回退,无需换二进制。

### 兼容性

- iOS 现版本 `historyMessages` 对 imageGeneration item 是 `default: return nil` 直接丢弃 → 改写零影响;
- userMessage 图片回显:composer 发送时用本地 attachment 渲染,不依赖通知回显的 data URL → 影响可忽略;新 build 遇到 `agentd-history-media://` 会按需取图;
- 改写后的通知帧仍是合法 item 结构(只有 `result`/`url` 字段变短 + 元数据字段),不破坏任何解析。

### 测试

- 单测:含 imageGeneration 的通知帧被改写;同图两帧返回同一 media id;非图片 base64 / 小图 / delta 帧不动;
- 单测:store 驱逐后 hash 索引无悬挂(put→驱逐→再 put 同图 → 新 id);
- e2e(fake upstream):推 `item/completed` 大图通知 → 客户端收到 media URL 帧且尺寸 <50KB。

### 验收目标

icon 类 turn 通知量 108MB/10min → **<5MB/10min**(占带宽 ~1.5%)。

## 3. 方案 2:全局历史下行预算(防并发挤兑)

### 现状

预算按 `(threadID, method, itemsView)` 分桶,各桶独立(6 req/15s、64KB 请求字节、8MB 响应字节)。桶间无共享上限:full + summary + fullRead + 多线程并发时,理论放行量数倍于管道。cat_name 一条连接实测 11 个 >2MB 响应在 10 分钟内被 cap 逐个拦截,说明请求端确实会打出这种并发。

### 改动点

**Router 级(跨连接)共享预算**(appserver_gateway.go):

```go
appServerGatewayHistoryGlobalMaxResponseBytes = int64(3 << 20) // 3MB / 15s ≈ 1.6Mbps 均值
appServerGatewayHistoryGlobalWindow           = appServerGatewayHistoryBudgetWindow // 15s,复用
```

- 位置:挂在 `Router`(进程级),而非每连接的 policy 实例——codex/claude 两条 ws 连接共享同一物理管道,预算必须合计;
- `reserveHistoryRequest`:先查全局 `blockedUntil`,再查分桶(全局拒绝优先返回,错误 reason 同样用 `history_budget_limited` + `retryAfterMs`,iOS 现有 `historyPolicyFailure` 按 `history_` 前缀识别、自动退避,**零客户端改动**);
- `recordHistoryResponseBudget`:分桶与全局同时记账;全局超限则 `blockedUntil = now + window`;
- **redactOnly(thread/resume)豁免**:不记全局、不受全局阻断(它已被网关 `excludeTurns:true` 压到 ~1.3KB,且绝不能挡发消息);
- 被 cap 拦截的响应也计入全局(它已经消耗了 Mac↔VPS 段流量与上游算力,记账能压制重试风暴)。

### 已知取舍

- 单 iPad 部署下合理;若未来多设备共用一个 agentd,全局预算会互相挤兑——届时改成 per-client-IP 分桶,文档先行注明;
- 3MB/15s 意味着"summary(50KB)随便拉,full(≤2MB)15 秒窗口内约 1 个"——符合"缩略优先、完整按需"的产品语义。

### 测试

- 单测:两个不同 thread 的 full 响应合计 >3MB 后,第三个请求(任意桶)被拒且带 retryAfter;窗口滚动后放行;resume 不计入;cap 拦截的响应计入全局。

## 4. 方案 3:media 接口默认降采样(按需取图再省 6 倍)

### 现状

`/api/app-server/history-media/{id}` 返回 `fileReadResponse` JSON,`content_base64` 是原图。1.2MB PNG → 1.6MB 响应(base64 +33%)。iPad 展示宽度 ≤ ~1200pt,原图分辨率纯浪费。

### 改动点

**依赖**:新增 `golang.org/x/image`(draw 高质量缩放 + webp 解码)。stdlib 无插值缩放,x 系是官方扩展、无第三方传染,可接受。

**处理管线**(appserver_history_media.go):

1. 请求带 `?original=1` → 原样返回(现行为);
2. 否则解码(`image/png`、`image/jpeg`、`image/gif` 首帧、`x/image/webp`;解码失败 → 原样返回,不 500);
3. 长边 ≤1600px → 不缩放,仅在"JPEG 重编码可明显减重"时(原图为 PNG 且不透明)转 JPEG q80;
4. 长边 >1600px → `x/image/draw.CatmullRom` 缩放到 1600;
5. 透明判定:类型断言含 alpha 通道的解码结果,抽样(步长 16)扫描是否存在 α<255 像素;透明 → PNG 编码保 alpha,不透明 → JPEG q80;
6. 变体缓存:entry 增加 `derived map[string][]byte`(key = `"1600"`),首次计算后缓存,计入 `totalBytes` 与驱逐逻辑;同一张图最多缓存一个降采样变体。

**契约**:`fileReadResponse` 字段不变;`content_type` 反映实际输出格式(可能 PNG→JPEG);`size` 为输出字节数;新增可选字段 `original_byte_count`(向后兼容,老客户端忽略)。iOS WIP 的取图代码按 `content_type` 解码,无格式假设 → 兼容。

### 测试

- 单测:3000×2000 不透明 PNG → 1600 长边 JPEG,体积 < 原图 30%;带透明 icon PNG → 输出 PNG 且保留 alpha;800px 小图不缩放;`?original=1` 逐字节等于原图;二次请求命中 derived 缓存(无重复计算,可用计数断言);非法图片数据原样返回。

### 验收目标

典型截图/mockup 取图 1.6MB → **~300KB**(~0.5s/张)。

## 5. 方案 4:客户端配套(随下个 TestFlight build)

已在未提交工作区(发版即生效):

- economy=summary 请求链路(694a5a11 起)+ `agentd-history-media://` 按需取图(WIP);
- `summaryFailed` 失败态横幅 + 重试(2026-07-07);

新增小项:

1. **轮询降频**:`sessionListPollingDelayNanoseconds`(SessionStore.swift:886,现 8s)改为动态:选中项目存在 `isRunning` 会话时 8s,否则 20s。收益仅 ~0.4% 带宽,顺手做,优先级最低;
2. **取图走降采样**:media 取图默认不带 `?original=1`;若后续做"点开大图"交互再带;
3. **发送端压缩确认**:实测上行截图 ~300KB/张已合理,仅需确认 composer 对相册原图(可能 4-12MB HEIC)有长边 2048 压缩;没有则补;
4. 发布清单:bump build → TestFlight → 用 019f36d2(37MB rollout)与 cat_name(126MB rollout)两个线程验收:缩略秒开、图片点开可见、完整版按需可拉或明确失败态。

## 6. 部署顺序与回滚

1. 方案 1+2+3 一次实现(全在 agentd),`go test ./internal/httpapi/` 全绿;
2. `cp bin/agentd bin/agentd.bak.<date>` 留回滚二进制;
3. 构建新 bin/agentd,**等 cat_name 等运行中 turn 空闲**(`/api/diagnostics/relay` 无 active turn 流量 + rollout mtime 静止)再 `launchctl bootout/bootstrap`;
4. e2e 复测:019f36d2 full-20 / summary-50 尺寸、通知帧改写计数、全局预算拒绝路径、media 降采样体积;
5. 回滚路径:换回 bak 二进制重启;或仅关通知改写:plist 加 `AGENTD_MEDIA_REDACT_NOTIFICATIONS=off` 重载。

## 7. 参数汇总

| 参数 | 现值 | 方案值 | 依据 |
|---|---|---|---|
| 历史单响应 cap | 2MB | **不变** | 3.4s 管道占用,可接受上限 |
| 分桶响应预算 | 8MB/15s | **不变** | 由全局预算实际约束 |
| 全局响应预算 | 无 | **3MB/15s** | ≈1.6Mbps,留 ~60% 给交互流量 |
| media 改写阈值 | 16KB(裸 base64) | 不变 | 小图内联更省往返 |
| media store | 128 项/256MB/30min | 不变 + hash 去重 + derived 缓存计账 | 重复推送零成本 |
| 降采样 | 无 | 长边 1600px,JPEG q80(透明保 PNG),`?original=1` 取原图 | iPad 显示宽度上限 |
| 通知帧改写开关 | — | env 默认 on | 一键回退 |
| iOS 列表轮询 | 8s | 动态 8s/20s | 收益小,顺手 |

## 8. 风险清单

| 风险 | 影响 | 缓解 |
|---|---|---|
| 通知帧 full JSON decode CPU | 高频出图 turn 下每帧 ≤35ms | 内容 gate 前置;仅命中帧解码;实测确认 policy_ms |
| 改写破坏未知客户端对通知的假设 | 目前仅 iPad 一个消费方 | 结构保持合法 item;env 开关回退 |
| x/image 新依赖 | 供应链面扩大 | 官方扩展库;仅 media handler 使用 |
| 全局预算多设备挤兑 | 未来多客户端时互相限流 | 文档注明;届时 per-client 分桶 |
| PNG→JPEG 丢 alpha | icon 类图变黑底 | alpha 抽样检测,透明走 PNG |
| 旧 build 看不到改写后的图 | 图片位置空白(现状 imageGeneration 本就不显示) | 新 build 跟进;不阻塞 |

## 9. 明确不做的事

- 截断/压缩**文本**类工具输出(commandExecution output 等):改变 item 语义,影响 iOS 的 authoritative item 判定,收益不确定——先靠全局预算兜底;
- thread/list 响应 diff/增量:协议侵入大,实测占比 ~0.7% 不值得;
- claude 通道通知改写:当前无图片流量,观察后再说;
- WebSocket per-message compression(permessage-deflate):base64 压缩率有限(~25%),且改写方案已把大头消灭,复杂度不值。
