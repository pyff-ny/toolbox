下面是一套**可落地、可扩展、在 `set -Eeuo pipefail` 下稳定**的 `_lib/ux.sh` 交互规范清单（含函数契约、返回码、输入输出、推荐用法）。目标：**所有脚本交互都“同一套感觉”**，同时避免你这次踩到的 `unbound variable / read_tty not found / GUI 选文件不回填路径` 这类坑。

---

## 0. 总体规范（必须统一）

### 0.1 I/O 约束

* **所有交互输入都从 `/dev/tty` 读**（避免 pipeline / 子进程吞 stdin）。
* **所有交互输出都写到 `/dev/tty`**（stdout 留给“可被管道消费”的结构化输出）。
* “业务输出”（比如生成的文件路径）走 stdout；“提示/日志/交互”走 tty。

### 0.2 返回码语义（统一）

* `0`：成功得到一个有效选择/输入
* `130`：用户取消（Esc / Ctrl+C / q / 空输入判定为取消时）
* `2`：参数/环境错误（缺目录、非法默认值）
* `1`：其他失败（执行失败/未知错误）

> 关键点：**取消不要用 0**。取消要让上层能分支处理。

### 0.3 `set -u` 安全：所有函数都用 `${var-}` 取参

* `local x="${1-}"` 而不是 `local x="$1"`

### 0.4 “交互函数”只做交互

* `ux.*` 不做业务动作（不做 rm/rsync/ffmpeg）。
* 只返回：字符串（stdout）+ 返回码（$?）。

---

## 1) `ux_read_tty`：基础读入（单行）

### 契约

* **用途**：打印 prompt，读取一行文本（可选默认值），支持取消语义
* **输入**：

  * `prompt`（必填）
  * `default`（可选）
  * `allow_empty`（可选：`0/1`，默认 0）
* **输出**：返回最终字符串到 stdout
* **返回码**：

  * `0` 成功
  * `130` 用户取消（Ctrl+C 或空输入且 allow_empty=0 且 default 也空）
  * `2` 参数错误

### 推荐行为

* Ctrl+C：直接返回 130（不打印 stack trace）
* 空输入：

  * 有 default → 返回 default
  * 没 default 且 allow_empty=1 → 返回空字符串
  * 否则 → 130

### 示例调用

```bash
name="$(ux_read_tty "Project name: " "" 0)" || exit $?
```

---

## 2) `ux_confirm`：确认（YES/NO）

### 契约

* **用途**：危险操作二次确认、不可逆操作 gate
* **输入**：

  * `prompt`（必填，例如 `"Type YES to confirm DELETE:"`）
  * `word`（可选，默认 `"YES"`）
* **输出**：无（不要 stdout）
* **返回码**：

  * `0` 确认通过
  * `130` 用户取消（Ctrl+C / 空输入）
  * `1` 明确拒绝（输入不是期望单词）

### 推荐行为

* 只接受完全匹配（区分大小写可配置，但默认严格）
* 在上层决定“拒绝是回菜单还是退出”

### 示例

```bash
if ! ux_confirm "Type YES to confirm DELETE sync: " "YES"; then
  rc=$?
  [[ $rc -eq 1 ]] && echo "[INFO] user refused" >/dev/tty
  exit $rc
fi
```

---

## 3) `ux_choose`：从列表选择（fzf 优先，fallback 数字菜单）

### 契约

* **用途**：选择 action / 模式 / 目标项
* **输入**：

  * `prompt`
  * `items...`（数组或 stdin 列表，两种形式二选一）
  * 可选：`--no-fzf`、`--header=...`、`--preview-cmd=...`
* **输出**：选中的 item（原样）到 stdout
* **返回码**：

  * `0` 成功选中
  * `130` 用户取消
  * `2` items 为空 / 参数错误

### 推荐行为

* 检测 `fzf`：有则用；无则用数字菜单
* 数字菜单：只接受 1..N；q 取消

### 示例

```bash
mode="$(ux_choose "Mode:" auto fixed hybrid)" || exit $?
```

---

## 4) `ux_pick_dir`：选择目录（Finder 打开 + 终端输入/拖拽）

> 你已经验证：macOS 原生 file dialog 的路径回填对 Terminal 场景不稳定；
> 所以规范里**不做 GUI 选择**，只做“打开目录 + 拖拽路径”。

### 契约

* **用途**：引导用户在 Finder 中定位，拖拽目录到终端输入框
* **输入**：

  * `start_dir`（必填：要打开的目录）
  * `prompt`（可选）
* **输出**：目录路径到 stdout（normalize 后）
* **返回码**：

  * `0` 成功且目录存在
  * `130` 取消
  * `2` start_dir 不存在

### 行为规范

* `open "$start_dir"`（失败不致命）
* 读取一行（/dev/tty），做 normalize（去引号、去 file://、反斜杠空格）
* 校验 `-d`

### 示例

```bash
pick="$(ux_pick_dir "$HOME/Music/Music" "Drag folder here: ")" || exit $?
```

---

## 5) `ux_pick_file_drag`：选择文件（打开目录 + 拖拽文件）

### 契约

* **用途**：最稳定的文件选择方式（与你的“lyrics”需求匹配）
* **输入**：

  * `start_dir`
  * `prompt`
  * `must_exist`（默认 1）
* **输出**：文件路径到 stdout（normalize 后）
* **返回码**：

  * `0` 成功（且文件存在 if must_exist=1）
  * `130` 取消
  * `2` 参数错误/目录不存在

### 关键点

* **不要**强制弹 macOS file picker
* **要**为拖拽 path 做 normalize（`\ `、引号、file://）

---

## 6) `ux_normalize_path`：路径清洗（公共）

### 契约

* **用途**：把 Finder/Terminal 拖拽来的 path 统一清洗
* **输入**：raw string
* **输出**：normalized path
* **返回码**：0（纯函数，不做 IO，不做校验）

### 规则

* trim 两端空白
* 去掉外层单/双引号
* `\ ` → ` `（只处理空格即可，别做过度 unescape）
* 去掉 `file://`

---

## 7) `ux_tip`：统一 Tips 输出（可选）

### 契约

* **用途**：脚本末尾统一提示样式（你问的 tip 函数）
* **输入**：

  * `title`（默认 `Tips`）
  * `lines...`
* **输出**：写到 `/dev/tty`
* **返回码**：0

### 规范

* Tips **不参与业务逻辑**，不影响 stdout（避免被管道误读）

---

## 8) 命名与风格约定

* `_lib/ux.sh` 对外统一导出这些名字（推荐）：

  * `ux_read_tty`
  * `ux_confirm`
  * `ux_choose`
  * `ux_pick_dir`
  * `ux_pick_file_drag`
  * `ux_normalize_path`
  * `ux_tip`
* 内部 helper 用 `_ux_*` 前缀，避免污染全局
* 函数里全部 `local var="${1-}"`，不要裸 `$1`

---

## 9) 典型用法模板（你要的 “lyrics：选音频 + 选语言”）

```bash
audio="$(ux_pick_file_drag "$HOME/Music/Music" "Audio file path (drag here): ")" || exit $?
lang="$(ux_read_tty "Lang (en|ja|zh) (default: en): " "en" 0)" || exit $?

# 可选项：不问，走默认或 CLI
mode="${3:-hybrid}"
interval="${4:-12}"
```

---

## 10) 最重要的工程纪律（避免再回到“费劲改”）

1. **交互入口只做一次**：IN/LANG/MODE/INTERVAL 只解析一次，后面只引用。
2. **取消语义统一 130**：上层看到 130 就“回菜单/退出但不报错栈”。
3. **绝不依赖 GUI picker 回填路径**：统一走 open + drag。
4. **ux 的输出只走 tty**：stdout 留给机器可读值（路径/选择结果）。

---

## English summary

This is a consistent `_lib/ux.sh` interaction contract: always read/write via `/dev/tty`, return `0` success, `130` user-cancel, `2` usage/env error; provide stable primitives `ux_read_tty`, `ux_confirm`, `ux_choose` (fzf + fallback), `ux_pick_dir`, `ux_pick_file_drag` (open folder + drag path), `ux_normalize_path`, and `ux_tip` (tty-only). This prevents `unbound variable`, missing `read_tty`, and unreliable GUI file-picker path issues.

如果你愿意，我下一步可以直接把这套规范**写成一个可用的 `_lib/ux.sh` 实现文件**（含注释、shellcheck 友好、返回码一致），你复制进去就能在 toolbox 全局复用。
