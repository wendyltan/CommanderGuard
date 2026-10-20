# CommanderGuard 界面重排实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 执行用户已批准的界面审查方案，降低概览拥挤并改善排查顺序。

**Architecture:** 沿用单文件 AppKit 视图与现有状态来源；只调整展示、导航和布局。后台探测、恢复、认证、记录归属及持久化契约不变。

**Tech Stack:** Swift、AppKit、现有离线自检与原生预览。

**Spec:** 用户于本聊天批准的审查方案；持久约定见 PRODUCT.md、DESIGN.md。

## Task 1 — 界面及验证

- [x] 检查所有受影响的视图调用、页面索引和现有断言；先用新布局断言证实当前缺口。
- [x] 修改 CommanderGuard.swift：四页导航、概览结论优先、设置迁移、故障操作后置、表格与详情分区、清晰的连接恢复文案。
- [x] 保留控制回调与安全门槛；只更新受界面契约变化影响的断言。
- [x] 构建、完整自检；隔离身份执行浅深色两种尺寸的布局验证；实际截图作一次集中检查，必要时一次修正。

## Task 2 — 文档与交付

- [x] 同步 README.md 与 README.en.md 的四页结构和账户/探测入口，更新 TODO.md 验收状态。
- [x] 复核完整差异和安全逻辑不变；安装前记录偏好、Commander 进程及 Guard 正在进行的操作。
- [x] 安全安装新版 Guard，核对二进制、运行状态、偏好与 Commander 进程；只做本地 commit 与语义 tag。

## 执行记录

- 起点：feature/authorized-recovery-20261019，bef6302，工作树干净。
- 路由：HIGH → Luna high 负责界面实现；主代理负责文档、独立复核与验收。不调用外部判断服务来决定可由编译、自检和差异确认的事实。
- 范围决定：沿用当前干净的功能分支，不创建并行版本，不合并或推送。
- 当前状态：实现、离线验证、实际画面检查与安装核对完成，最终证据见 TODO.md；人工视觉验收待用户。
- 调查记录：首次分栏保留最小高度；实测发现主布局默认按 fitting 高度排列，改 fill 后又被未固定高度的筛选栏吸收剩余空间。设置主布局 fill、筛选栏 28 点后，列表高度与双区域断言通过；无后台行为变更。
