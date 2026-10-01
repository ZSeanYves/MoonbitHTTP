# MoonbitHTTP 任务交接单（2026-09-22）

> 本文件是给下一轮 Codex 的本地交接资料，刻意不纳入本次 Git 提交和远端推送。源代码、测试和已有项目文档的变更仍按用户要求推送远端。

## 0. 一句话结论

本轮已经把 MoonbitHTTP 从“流式 HTTP/1、HTTP/2 服务基础完成”的状态继续推进到覆盖客户端策略、HTTP/3 字段边界、QUIC 状态隔离、URI authority、资源上限和 Native 策略注入的开发构建；最近一次全目标严格测试通过，但路线图中最关键的真实 TLS/QUIC/HTTP/3 互操作和生产发布门槛仍未完成，因此不能把当前包称为 production-ready。

当前 goal 已暂停，不要在没有新指令时把下面的未完成项默认为“已完成”。

## 1. 仓库与工作区信息

- 源码仓库：`/Users/winter/Documents/Moonbit/MoonbitHTTP`
- 项目历史工作目录：`/Users/winter/.codex/projects/MoonbitHTTP`（不要在这里修改源代码）
- 当前分支：`main`
- 远端：`origin = ssh://git@github.com/ZSeanYves/MoonbitHTTP`
- 本轮开始时的远端基线：`72293b9`（`fix(http2): bound stream receive windows to body queues`）
- 本轮已推送提交：`de84bb1aa49dfeb2f93f01971fb0f9a762336aa8`（`feat: harden production HTTP protocol stack`）
- 路线图：`docs/production-http-roadmap.zh-CN.md`
- 发布证据：`docs/release-evidence-2026-09-22.md`
- 本交接单：本地保留，不要 `git add`、不要提交、不要推送

工作区在本轮开始前已经包含大量未提交的路线图实现，不要用 `git reset --hard`、`git checkout --` 或其他破坏性命令清理它们。继续工作前先看：

```bash
cd /Users/winter/Documents/Moonbit/MoonbitHTTP
git status --short --branch
git diff --stat
git log --oneline --decorate -8
```

## 2. 已完成的主要实现

### 2.1 公共契约、Body 与生命周期

- `body/` 已改为有界的流式 Body/BodyStream 语义，覆盖生产者、消费者、关闭、取消、EOF、错误传播和唤醒。
- BodyStream 的 wake-up 事件使用单 token 有界队列，避免无界事件日志。
- `service/` 已有 HTTP/1、HTTP/2、h2c、自动选择和 scoped streaming service 生命周期。
- 服务端连接、请求体消费、关闭和 supervisor 路径已有回归测试。
- `types/` 增加限制、日期、URI、authority 和消息字段相关实现；公开接口通过 `moon info` 生成的 `.mbti` 进行审查。

### 2.2 HTTP/1.1

- `http1/connection.mbt` 完成更严格的请求/响应 framing、body 消费、连接复用和限制处理。
- 修正响应无体规则：`1xx`、`204` 和成功 `CONNECT` 不接受非法 `Content-Length`/`Transfer-Encoding` 组合。
- 保留合法的 `HEAD`/`304` 元数据行为，并补充负例和控制用例。
- `http1/conformance_test.mbt` 与 `http1/connection_test.mbt` 有 framing、解析、关闭、限制和分片回归。

### 2.3 HTTP/2 与 HPACK

- 帧编解码、HPACK Huffman/动态表、流生命周期、窗口和服务层已经扩展。
- 已增加 header block、CONTINUATION、流窗口、RST/GOAWAY、异常帧和资源限制覆盖。
- 关闭的 HTTP/2 stream 记录在固定 1,024 项 tombstone 历史后回收。
- header block 跨所有 CONTINUATION 帧受 `max_header_bytes` 限制。
- body 消费在记录回收后仍正确恢复 connection-level receive window。
- HPACK 安全回归位于 `http2/hpack_security_wbtest.mbt` 和 `http2/runtime_security_wbtest.mbt`。

### 2.4 HTTP 客户端、连接池与代理策略

- `client/` 已包含 round trip、HTTP/1 client、连接池、重试、重定向、Cookie、认证和 Native 适配器。
- 代理 forward 与 HTTPS `CONNECT` 在创建代理 socket 前：
  1. 解析 origin hostname；
  2. 对每个 numeric candidate 执行 `NetworkPolicy::Connect`；
  3. 再执行 `ProxyConnect`；
  4. 任一候选被拒绝时，不建立代理连接。
- 这样覆盖了代理模式下 loopback/private candidate 的 SSRF/policy bypass 边界。
- `client/http1_pooled_test.mbt` 有 forward proxy 和 CONNECT 的策略拒绝测试。

### 2.5 HTTP/3 与 URI authority

- `http3/runtime.mbt` 现在校验：
  - method token；
  - scheme（普通请求和 extended CONNECT 限制为 `http`/`https`）；
  - 必须存在并可解析的 `:authority`；
  - UTF-8；
  - 重复/畸形 `Host`；
  - `Host` 与 `:authority` 的 host/port/IP-literal 一致性；
  - request-target 必须是合法 OriginForm 或 AsteriskForm。
- `types/uri.mbt` 不再接受任意 bracket host，只接受严格的 IPv6 或 RFC 3986 IPvFuture。
- `[not-an-ip]`、`[gggg::1]` 等非法 authority 已有边界测试；IPv4-mapped IPv6 和合法 IPvFuture 有正例。
- HTTP/2 service 入口也会拒绝非法 bracketed authority，避免不同协议入口出现不一致。

### 2.6 QUIC 状态和端点策略

- `quic/driver.mbt` 支持端点授权回调，初始端点和 path migration candidate 都必须通过 `NetworkPolicy::QuicEndpoint`。
- 策略拒绝时 path 状态不改变。
- Application packet、双向 application stream 在 `Established` 前均被拒绝。
- `establish` 要求 application packet keys 已安装。
- packet type 1（0-RTT）默认拒绝，直到有明确 replay policy。
- 新增 path status、握手前应用数据和策略拒绝测试。
- 重要边界：当前仍是“手动安装 key 的 QUIC driver 能力”，不是已完成的 TLS 1.3 CRYPTO/traffic-secret 集成。

### 2.7 Native、TLS、Transport 与 Server

- `client/native/native.mbt` 保留兼容的 `new_http1_client`，并新增：

  ```moonbit
  new_http1_client_with_policy[P : @transport.NetworkPolicy](policy : P, options? : ClientOptions) -> ...
  ```

- Native `DenyAllPolicy` 黑盒测试确认请求在任何 socket 操作前返回 `ClientPolicy`。
- `transport/`、`tls/`、`server/` 已形成独立宿主能力接口和 Native 包边界。
- 当前 Native TLS 能力仍不足以满足生产路线图的全部要求，见第 6 节。

### 2.8 资源与安全边界

- HTTP/3 QPACK blocked frame 队列受 `max_buffer_bytes` 限制。
- 已完成的非关键单向 HTTP/3 stream 会从 driver registry 移除。
- QPACK encoder pending dynamic-section metadata 受 instruction buffer budget 限制，并在确认或取消时释放。
- 连接池 eviction notification 有界，资源拥有者必须 drain/close 后才归还容量。
- QUIC receive path 有 packet dedup 上限回归（包括 4,097 个 protected Initial packet）。
- transport endpoint 拒绝 embedded port 和畸形 bracketed host。

## 3. 最近一次验证结果

以下是 Native policy factory 加入后的最近一次全目标结果，不是本交接单写作时临时重跑的结果；文档变更本身不改变这些代码测试结果。

### 3.1 必过门槛

在模块根目录串行执行：

```bash
moon fmt --check
moon check --target all --deny-warn --warn-list +73
moon test --target all --no-parallelize --deny-warn --warn-list +73
moon build --target all --deny-warn --warn-list +73
moon info --target all
moon package --list
```

最近结果：

| 目标 | 结果 |
| --- | ---: |
| Wasm | 284/284 |
| Wasm-GC | 221/221 |
| JS | 284/284 |
| Native | 298/298 |

`moon build` 只有已有的空 external stub object 的 host `libtool` 提示，没有失败；`moon info` 显示 Native-only adapter 与 canonical Wasm interface 的差异，这是预期行为。

### 3.2 其他已通过验证

```bash
moon bench --build-only --target native --deny-warn --warn-list +73
bash scripts/interoperability.sh
moon coverage analyze -- -f cobertura -o coverage.xml
git diff --check
```

- Native HTTP/1、HTTP/2 benchmark build artifact 已生成。
- curl/Wget HTTP/1.1、nghttp2 prior-knowledge、h2c upgrade 互操作脚本已通过。
- 覆盖率 Cobertura 输出已生成。

### 3.3 当前开发包

```text
_build/publish/ZSeanYves-MoonbitHTTP-0.6.0.zip
SHA-256: a13fcf0a0a0412298cd6f46f47dcdd2909e75527b673f79c8af4a674a0c775ad
archive: 393,308 bytes
contents: 221 files
uncompressed: 1,469,103 bytes
```

这些数值已同步到 `docs/release-evidence-2026-09-22.md`。

## 4. 安全扫描现状

- 旧标准扫描 `bc7c3539-a1f8-40fd-b50c-7da74f86c6f1`：0 个已验证可报告 finding，但覆盖不完整，且早于当前 URI/QUIC/Native 最终改动。
- 后续标准扫描 `f45921e2-8954-44c3-8b4f-a44fd8349eb2`：在 URI/QUIC 加固之后、Native policy factory 之前启动；其固定快照已经过期，不能作为最终当前证据。
- 结论只能写成“在已审查且覆盖到的表面未发现已验证可报告漏洞，覆盖部分且仍需重扫”，不能写成“没有安全隐患”或“已生产批准”。
- 下一轮应在源码冻结后重新做一次当前工作树的标准安全扫描，并把 scan id、report 路径、coverage caveat 写入 release evidence。

## 5. 生产发布仍未完成的门槛

这些项目必须继续追踪，不能因为单元测试全绿而关闭：

### P0/P1 协议与 TLS

1. QUIC 与真实 TLS 1.3 CRYPTO 流程打通：TLS 产生/消费 CRYPTO，导出并更新 Initial/Handshake/Application traffic secrets，驱动 key transition。
2. QUIC key update：当前只解析 key phase，没有 TLS 1.3 traffic-secret update 流程。
3. Native TLS：自定义 trust anchor、客户端证书/私钥、服务端证书/私钥、真实证书链验证和错误分类。
4. Native TLS ALPN 当前只覆盖 `http/1.1`；HTTP/3 的 `h3` 不能据此宣称可用。
5. Native QUIC hostname endpoint 的 resolver 路径需要补齐；当前直接地址解析不等于完整 hostname 支持。
6. 真实 HTTP/3 client/server 独立互操作，不应只依赖 codec/runtime fixture。

### 负向、安全、资源与性能

7. 证书错误套件：wrong-host、expired、untrusted chain、invalid chain、revocation/hostname semantics（按项目范围明确）。
8. 长时间运行、连接池压力、body backpressure、HTTP/2/3 stream churn、QPACK/HPACK pressure。
9. 可重复的性能阈值和回归基线，而不是只确认 benchmark 能编译。
10. 独立协议/安全 review；当前 Codex Security 结果不能替代独立审查。

### 发布证据

11. 源码冻结后重新生成 package，核对包内文件、hash、接口和 docs。
12. 更新 `docs/release-evidence-2026-09-22.md`，移除过期 scan 作为“当前证据”的表述，但保留历史结果和覆盖限制。
13. 完成上述门槛后，才可以讨论版本发布；在此之前措辞应为“validated development build”。

## 6. 下一轮推荐顺序

1. 先读取本文件、`docs/production-http-roadmap.zh-CN.md`、`docs/release-evidence-2026-09-22.md` 和 Git 状态。
2. 确认远端已包含本轮提交，且本地交接单仍未被提交。
3. 重新跑 `moon fmt --check`、`moon check`、`moon test`、`moon build`、`moon info`，全程不要并行执行 Moon 命令，避免 `_build/.moon-lock` 干扰证据。
4. 先解决 QUIC/TLS 1.3 集成，再做 HTTP/3 真实互操作；不要把现有 QUIC fixture 当成 TLS 互操作证明。
5. 补 Native TLS 证书/ALPN/hostname/error semantics，再补证书负向套件。
6. 进行压力、长稳和性能阈值实验；把 preflight/诊断/报告时间排除在测量步骤之外。
7. 源码稳定后重新做标准安全扫描，并记录完整 scan context、coverage 和 report。
8. 最后重新生成包与 hash，更新发布证据，做独立 review。

## 7. Git 与提交边界

- 用户要求把实现推送远端，但本交接单只保存在本地。
- 提交时应把源代码、测试、`CHANGELOG.md`、路线图和 `docs/release-evidence-2026-09-22.md` 纳入提交。
- 不要提交本文件：

  ```bash
  git add -A -- ':!docs/task-handoff-2026-09-22.zh-CN.md'
  git status --short
  git commit -m "feat: harden production HTTP protocol stack"
  git push origin main
  ```

- 推送后验证：

  ```bash
  git status --short --branch
  git log --oneline --decorate -3
  git ls-remote --heads origin main
  ```

- 如果 `git status` 中出现本交接单的 `??`，这是预期的本地文件，不要为了清洁状态删除它；下一轮 Codex 应直接读取它。

## 8. 重要的判断边界

- “所有当前测试通过”不等于“HTTP/3/TLS/QUIC 已生产互操作”。
- “安全扫描 0 findings”在部分覆盖、快照过期或委托 worker 不可用时，不等于“无安全隐患”。
- “package 能生成”不等于“包可直接用于生产”。
- 未完成项必须在后续报告中继续列出，直到有可复现实验、独立证据和路线图对应的验收记录。
