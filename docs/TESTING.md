# 测试说明

## 本地测试

需要 Bash 4 或更高版本：

```bash
bash tests/run.sh
```

当前测试覆盖：

- Bash 语法；
- 版本和 Webhook 协议版本；
- 明文命令行 Token 拒绝；
- 未启用 Webhook 的兼容路径；
- Webhook 配置校验；
- 非交互环境的 `TERM` 默认值和第三方模块有限执行超时；
- sequence 递增；
- 旧进度不使任务倒退；
- TCP 延迟等细分阶段优先读取结构化 phase sidecar，并覆盖受限终端阶段文案回退；
- 普通事件请求体上限；
- 报告 URL 域名白名单；
- 剩余挂载点阻止递归删除。

## Linux 集成测试

Windows 本地测试不能真实覆盖 mount、chroot、signal 和 BenchOS。发布前必须在隔离 Linux 测试机验证：

1. 四个模块分别执行和四项联检；
2. Hardware、IP、Network 和 Backroute JSON；
3. 三种 `report.check.place` SVG URL；
4. 回程报告 URL 存在和不存在两种上游行为；
5. NodeQuality 完整在线报告 URL；
6. INT、TERM、HUP；
7. 检测中取消；
8. 清理重复调用；
9. `/dev`、`/proc`、`/sys` 残留挂载；
10. Webhook 超时、429、5xx、401 和最终重试；
11. 官方上传失败时仍返回模块结果；
12. Webhook 失败不影响官方上传；
13. Token 不进入进程输出、报告归档和工作目录；
14. 第三方广告资源被隔离后，模块 JSON、SVG 和完整报告仍能生成。

真实服务器测试、部署、Tag 和 Release 需要单独授权，不属于本地测试命令。
