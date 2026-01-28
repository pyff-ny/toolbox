# Toolbox Architecture & Rules (ARCHITECTURE)

> 目标：把“可控性”写进系统。  
> 原则：不依赖操作者记忆；所有高风险点必须由系统强制减速。

---

## 0. 核心定义

**Toolbox** = 一个命令/脚本编排器（orchestrator），负责：
- 扫描并展示可运行对象（Cmd）
- 提供对该对象的操作集合（Action）
- 在关键节点做强制边界与确认（Prompts/Confirm）
- 统一运行体验（Ctrl+C 返回、退出码提示、可追溯输出）

**脚本（子程序）**负责：
- 业务逻辑（transcribe / import / backup / disk health 等）
- 自己的日志/输出策略（Toolbox 不做业务日志）
- 对输入参数做校验（失败要明确返回退出码）

---

## 1. 三级菜单模型（不可破坏）

### Level 1: Cmd（选择“对象”）
- 对象是：一个可执行脚本（.sh/.py/可执行文件）
- 只负责定位对象，不做任何运行决策

### Level 2: Action（选择“对对象做什么”）
- Action 是可扩展点：新增功能应该优先新增 Action，而不是新增目录层级
- Action 必须体现“边界”：哪些能做、哪些不能做

### Level 3: Confirm/Prompts（强制减速点）
- 任何可能造成不可逆影响的动作必须有 Confirm Gate
- 任何需要参数才能运行的动作必须走 Prompts Gate（从 Action 进入）

---

## 2. 不依赖记忆的“边界规则”

### 2.1 入口安全：禁止暴露“会出错的入口”
**规则：凡是需要必填参数的脚本，不允许出现通用 Run。**
- 例：lyrics_auto_no_vad.sh 需要 audio path
- 处理：隐藏 `Run now / Run with --dry-run`
- 替代：提供专用 Action（如 `Lyrics:Transcribe`），由 Toolbox 采集参数后调用

> 目的：不让“看到 Run 就想点”的人性触发错误入口。

### 2.2 风险分级（建议统一）
- **Safe**：只读/查询类（可默认 Run）
- **Caution**：可能写文件但可回滚/可重复（可 Run + 轻确认）
- **Danger**：删除/覆盖/同步/推送等不可逆（必须二次确认：输入 YES）

---

## 3. Action 设计规范

### 3.1 Action 必须自描述
Action 名称必须体现语义，而非技术实现：
- ✅ `Lyrics:Transcribe(whisper-cpp)`
- ✅ `Backup:Dry run`
- ❌ `Run script`

### 3.2 Action 类型
- **Generic Actions（通用）**
  - Run now（仅对 Safe/Caution 且无需参数脚本开放）
  - Run with --dry-run（仅当脚本支持该参数）
  - Create/Preview/Delete wrapper
  - Open in editor
- **Special Actions（专用）**
  - 需要 prompts、需要上下文、或需要多步编排的功能必须用专用 action

### 3.3 Prompts 输入规范（TTY）
- 所有交互输入必须从 `/dev/tty` 读，避免管道/重定向污染
- 默认值必须明确展示，例如：
  - `Lang (default: en): `
  - `Mode (auto|fixed|hybrid) (default: hybrid): `

---

## 4. 运行与退出码规范（run_cmd contract）

### 4.1 Ctrl+C 行为（强约束）
- Ctrl+C 只中断子程序并返回菜单，不允许退出整个 toolbox
- 子程序退出码 130 视为用户中断（Info 级别）

### 4.2 退出码（建议）
- `0`：成功
- `1`：可恢复失败 / 未找到结果 / 未检测到 silence 等
- `2`：缺少依赖 / 参数错误 / 环境不满足
- `130`：用户中断（Ctrl+C）

Toolbox 必须把退出码显式打印出来，并保持一致风格：
- `[OK]` / `[WARN]` / `[INFO]`

---

## 5. 路径与配置规则（禁止硬编码）

### 5.1 统一路径变量（全局约定）
- `TOOLBOX_DIR` default `$HOME/toolbox`
- `SCRIPTS_DIR` default `$TOOLBOX_DIR/scripts`
- `WRAPPER_DIR` default `$HOME/toolbox/bin`

脚本内部只能使用这些变量或基于它们派生：
- 禁止写死 `/Users/<name>/...`

### 5.2 业务脚本配置优先级
建议采用以下优先级（从高到低）：
1) CLI 参数  
2) 环境变量（env）  
3) conf 文件（如果存在）  
4) 默认值

---

## 6. Wrapper 规则（可迁移性）

### 6.1 Wrapper 只做一件事：稳定入口
Wrapper 的职责：
- 把“调用路径”固定到 `$SCRIPTS_DIR/<rel_path>/script`
- 允许 scripts 目录结构调整时，入口不崩

### 6.2 Wrapper 命名
建议使用：`<category>_<scriptbase>`
- 避免重名
- 便于搜索与补全

---

## 7. Lyrics Pipeline 的规范化（示例）

### 7.1 Transcribe（专用 action）
输入：
- audio path（必填）
- lang / mode / interval（有默认值）

输出：
- work_dir：`$LYRICS_DIR/work_lyrics_<name>/`
- meta.txt：写入 title/artist/lang/source/mode/interval/model/generated_at
- raw segments / srt / cleaned txt（按阶段分文件）

### 7.2 Cleanup（歌词笔记态）
目标：生成“无时间轴的歌词文本”用于 Obsidian
- 默认输出 plain text（段落分隔）
- dropped 审计文件保留，用于调规则

### 7.3 Import（路径必须可配置）
- Vault root 使用 env：`VAULT_ROOT`
- notes root 使用 env：`LYRICS_NOTE_ROOT`
- 按语言分流：`$LYRICS_NOTE_ROOT/<lang>/<artist>/<title-artist>/`

---

## 8. 新功能接入 Checklist（8 行规格模板）

新增功能时必须写清：

1) Feature 名：  
2) 入口位置：全局 action / 针对某 cmd 的专用 action  
3) 默认行为：  
4) 危险边界：是否需要 YES 确认？是否默认 dry-run？  
5) 参数来源：CLI/env/conf/prompts（默认值）  
6) 输出：生成哪些文件/目录？放哪？  
7) 失败策略：退出码、提示、可恢复性  
8) 验收项（3–6 条）：可复现、可回滚、无硬编码路径、Ctrl+C 行为正确

---

## 9. 设计底线（不可退化）

- 不用“提醒用户小心”替代系统边界
- 不用“记住不要点 Run”替代隐藏错误入口
- 不把业务日志塞回 Toolbox 主程序
- 不为省事硬编码用户路径
