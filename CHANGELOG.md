# 变更记录

## 1.0.0 - 2026-07-14

### 新增

- 增加可选的 `nq-webhook/1.0` 结构化事件和最终结果接口。
- 增加每 job 独立 Bearer Token 鉴权、事件 ID、单调 sequence、整体进度和稳定状态枚举。
- 增加非交互检测参数，NodeGet 等调用方不再需要通过 stdin 模拟交互。
- 增加 Hardware、IP、Network、Backroute 模块状态、结构化摘要和在线报告 URL 字段。
- 增加基于第三方函数调用边界的 Network、Backroute phase sidecar，并以最近 32 KiB 明确阶段文案作为有限回退；终态和结果不依赖该回退。
- 增加 Webhook 请求大小、字段长度、超时和有限重试约束。
- 增加自动化测试入口 `tests/run.sh`。

### 修复

- 修复清理函数固定返回退出码 1，导致成功检测被标记为失败的问题。
- 修复 `tee` 掩盖检测模块真实退出状态的问题。
- 拆分 INT、TERM、HUP 和 EXIT 处理，避免 trap 递归、重复清理和重复终态事件。
- 清理前检查工作目录内的挂载点，存在残留挂载时禁止递归删除。
- 官方报告上传失败时保留已经取得的模块结构化结果。

### 兼容性

- 未配置 Webhook 时继续保留原有交互、终端输出、模块检测和官方在线报告上传方式。
- Webhook 不替代 Hardware.Check.Place、IP.Check.Place、Net.Check.Place 或 NodeQuality 官方报告上传。
- 结构化集成接口不保存或返回与检测结果无关的营销输出。
