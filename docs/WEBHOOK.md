# NodeQuality Webhook 协议

## 版本

- NodeQuality：`1.0.0`
- 协议名称：`nq-webhook`
- 协议版本：`1.0`

协议主版本变化表示存在不向后兼容的字段或语义调整。同一主版本内只新增可选字段或错误码。

## 启用方式

Webhook 是可选能力。以下参数必须同时有效：

```bash
export NQ_WEBHOOK_TOKEN='当前 job 的一次性 Token'

bash NodeQuality.sh \
  --webhook-url 'https://example.com/event' \
  --webhook-job-id 'job-123' \
  --webhook-version '1.0' \
  --non-interactive \
  --hardware deep \
  --ip run \
  --network low \
  --route run
```

Token 也可以使用 `--webhook-token-env <环境变量名>` 或 `--webhook-token-fd <文件描述符>` 传入。脚本明确拒绝 `--webhook-token <明文>`，避免 Token 出现在进程参数和任务记录中。

## 鉴权

```http
Authorization: Bearer <job-token>
Content-Type: application/json
X-NodeQuality-Protocol: 1.0
```

Token 必须由调用方为当前 job 随机生成，只允许提交当前 job 的事件，终态或 TTL 到期后失效。NodeQuality 不生成、保存或硬编码 NodeGet Token、Telegram Bot Token或其他管理凭据。

## 模块枚举

```text
core
environment
hardware
ip_quality
network_quality
backroute
report_upload
cleanup
```

## 事件枚举

```text
job.started
job.progress
module.started
module.completed
module.partial
module.failed
module.skipped
cleanup.started
cleanup.completed
cleanup.partial
cleanup.failed
job.completed
job.failed
job.cancelled
job.terminated
```

## 状态枚举

Job：

```text
starting
preparing
running
uploading
cleaning
succeeded
partial
failed
cancelled
terminated
```

模块：

```text
pending
running
succeeded
partial
failed
skipped
cancelled
```

清理：

```text
not_started
running
succeeded
partial
failed
```

## 普通事件示例

```json
{
  "protocol": "nq-webhook",
  "protocol_version": "1.0",
  "schema": "event",
  "nodequality_version": "1.0.0",
  "job_id": "job-123",
  "event_id": "019b1d8a-75aa-7a2c-8bcc-cc09f441db38",
  "sequence": 7,
  "event_type": "module.started",
  "job_status": "running",
  "module": "network_quality",
  "module_status": "running",
  "progress": { "current": 55, "total": 100, "unit": "percent" },
  "phase": {
    "code": "network_quality.running",
    "status": "running",
    "message": "正在检测网络质量、TCP 延迟与吞吐"
  },
  "timestamp": "2026-07-13T10:30:45Z",
  "error": null
}
```

`phase.code` 是业务判断字段，`phase.message` 仅用于展示。模块内部没有可靠结构化进度来源时，阶段保持在 `<module>.running`，不得通过猜测终端动画得出当前项目。

Net.Check.Place 当前没有独立的结构化进度接口。NodeQuality 通过受限的 Bash 函数边界适配器，将上游实际执行的 `get_tcp`、`get_delay`、`get_route`、`speedtest_test`、`iperf_test` 和 `get_route_mode` 调用写入只包含稳定 phase code 的 sidecar，再发送：

```text
network_quality.bgp
network_quality.tcp_settings
network_quality.tcp_latency.domestic
network_quality.route_summary
network_quality.speed.domestic
network_quality.tcp_latency.international
backroute.trace
```

该适配器优先记录白名单中的函数调用边界。为提高第三方脚本版本变化时的阶段准确性，如果函数钩子没有产生对应 phase，NodeQuality 可以从模块最近 32 KiB 的受限输出窗口识别明确的中英文阶段文案作为回退。回退不会上传或保存完整终端输出，也不会把 ANSI、动画或广告内容写入事件。

细分 phase 只用于 Telegram 等接收端显示“正在检测国内三网 TCP 延迟”等当前进度。模块成功、失败、取消、最终结果和报告 URL 仍只依据退出码、结构化 JSON、官方上传响应和清理事实，不依赖阶段文案。

## 幂等和乱序

- sequence 从 1 开始，在同一 job 内单调递增。
- 同一个逻辑事件重试时复用 event ID 和 sequence。
- 接收端应使用 `(job_id, event_id)` 去重。
- sequence 小于已接收值的旧事件不得覆盖当前状态和进度。
- sequence 相同但 event ID 不同视为协议冲突。
- 终态事件接受后，普通阶段事件不得改变终态。
- 时间戳不用于事件排序，避免目标服务器时间漂移影响状态。

## 大小限制

| 项目 | 上限 |
|---|---:|
| 普通事件请求体 | 8 KiB |
| 最终结果请求体 | 64 KiB |
| job ID | 128 字符 |
| Token | 256 字符 |
| Webhook URL | 2048 字符 |
| context JSON | 4 KiB |
| 单个错误摘要 | 512 字节 |
| 单模块结构化摘要 | 12 KiB |

请求体不包含完整 stdout、stderr、终端动画或原始 BenchOS 输出。

## 超时和重试

普通事件：

- 连接超时 2 秒；
- 单次总超时 5 秒；
- 最多 2 次；
- 延迟 0、1 秒。

最终事件：

- 连接超时 3 秒；
- 单次总超时 10 秒；
- 最多 4 次；
- 延迟 0、1、3、7 秒。

网络错误、超时、408、425、429、500、502、503、504 可以重试。确定性 4xx 不重试。Webhook 失败不阻止模块检测和官方报告上传。

## 报告 URL

- 模块报告只接受 HTTPS `report.check.place` URL。
- 完整报告只接受 `https://nodequality.com/r/<id>`。
- 模块 URL 由受控上传响应 sidecar 取得。
- NodeQuality 完整 URL 只在官方上传函数的有限响应内严格解析。
- 不扫描完整终端输出提取 URL。

## 退出码

| 代码 | 含义 |
|---:|---|
| 0 | 检测和清理成功 |
| 2 | 部分成功 |
| 3 | 检测整体失败 |
| 4 | 用户取消 |
| 5 | 系统终止 |
| 6 | 检测成功，但最终 Webhook 未送达 |
| 64 | 参数或协议配置错误 |
| 70 | 内部异常 |

退出码 6 不改变最终结果中的真实检测状态。
