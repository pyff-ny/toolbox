# Decisions (ADR-lite)

> 目的：记录关键结构决策，避免未来因遗忘/误解而回滚系统边界。
#你后面每次“新增一个保护策略/隐藏一个入口/改变默认行为”，都加一条 ADR。
---

## ADR-0001: 三级菜单固定为 Cmd → Action → Confirm/Prompts
- Status: Accepted
- Context: 直接运行脚本容易误操作；功能扩展会导致目录/入口混乱。
- Decision: 强制三级分层；新增功能优先新增 Action，而不是新增目录结构。
- Consequences:
  - 扩展点清晰（Action）
  - 风险点可控（Confirm/Prompts）
  - 用户行为可被系统约束（减少误点）

---

## ADR-0002: “需要必填参数的脚本”隐藏通用 Run
- Status: Accepted
- Context: 人会习惯性点击 Run；对必填参数脚本会直接失败或产生错误行为。
- Decision: 对 needs_args 的脚本，隐藏 Run now / Run with --dry-run，只提供专用 Action。
- Consequences:
  - 消除“错误入口”
  - 参数输入统一走 TTY prompts
  - 增加少量维护成本（维护 needs_args 列表或规则）

---

## ADR-0003: Obsidian 导入路径必须可配置，并按 lang 分流
- Status: Accepted
- Context: 导入脚本写死路径导致不同语言笔记混在一起，且难迁移。
- Decision: 使用 VAULT_ROOT / LYRICS_NOTE_ROOT env；默认按 $lang/$artist/$title-artist 分层。
- Consequences:
  - 迁移成本低
  - 语言天然隔离
  - 需要保证 meta.txt 写入 lang

