好，我继续把你要的 **统一一套 `_lib/ux.sh` 交互规范清单（read_tty / pick_dir / confirm / choose）** 写成“可落地的 v1.0 规范”，并把你当前踩过的坑（`set -u`、wrapper、GUI file picker、拖拽路径、冒号 `:hybrid`、`read_tty: command not found`）全部纳入规则里。

下面这份你可以直接存成：`toolbox/docs/UX_SPEC.md` 或贴进 `_lib/ux.sh` 顶部注释块。

---

# Toolbox UX 规范 v1.0（_lib/ux.sh）

## 0. 总原则（必须遵守）

1. **交互只从 `/dev/tty` 读写**

* 目的：fzf / 管道 / wrapper 场景稳定，不被 stdin 污染。
* 禁止：裸 `read`（除非明确 `</dev/tty`）

2. **CLI 参数优先，交互兜底**

* 顺序：`positional/flags` → `env default` → `interactive prompt` → `cancel`
* 目的：脚本可自动化 + 可交互，二者兼容。

3. **ux_* 不改变控制流**

* `ux_tip / ux_open_after`：只打印/执行辅助动作，不应该 `exit`，不改变返回码。
* 会改变控制流的只允许：`die` / 调用者显式判断返回值。

4. **取消是正常路径，不是错误**

* 用户取消：返回 `1` 或 `130`（如果是 Ctrl+C），并由上层打印 `[WARN][cancelled]` 即可。
* 不要把取消当作 `[ERROR]`。

5. **`set -u` 下任何变量读写都要安全**

* 所有函数入参用 `"${1-}"`
* 读取可选变量用 `"${VAR-}"` / `"${VAR:-default}"`
* 禁止直接 `$2` `$3`（你之前的 `std.sh line 9: $2 unbound` 就是这个）

---

## 1) `read_tty`：单行输入（核心原语）

### 规范签名

```bash
read_tty "<prompt>" [default]
```

### 行为

* 打印 prompt 到 `/dev/tty`
* 从 `/dev/tty` 读一行
* 返回读到的字符串（stdout）
* 用户 Ctrl+D / 空输入：返回空字符串（调用者决定是否用 default）
* 用户 Ctrl+C：由 trap 处理（建议外层统一 trap）

### 推荐实现（最小稳定版）

```bash
read_tty() {
  local prompt="${1-}"
  local out=""
  printf "%s" "$prompt" >/dev/tty
  IFS= read -r out </dev/tty || return 1
  printf "%s" "$out"
}
```

> 你报过 `read_tty: command not found`：根因是你脚本里调用了 `read_tty`，但你加载的是 `ux.sh` 里没有定义它，或 `read_tty` 定义在别的文件但未 source。
> **规范：read_tty 必须定义在 `ux.sh`（或 std.sh）且全局可用。**

---

## 2) `ux_get_default`：带默认值的输入（推荐）

### 规范签名

```bash
ux_get_default "<value_from_cli>" "<prompt>" "<default>"
```

### 行为

* 如果第一个参数非空：直接返回它（不问）
* 否则：提示用户输入；空则返回 default
* 取消：返回非 0（由调用者决定退出/回菜单）

### 推荐实现

```bash
ux_get_default() {
  local v="${1-}"
  local prompt="${2-}"
  local def="${3-}"

  if [[ -n "$v" ]]; then
    printf "%s" "$v"
    return 0
  fi

  local in
  in="$(read_tty "$prompt")" || return 1
  in="${in:-$def}"
  printf "%s" "$in"
}
```

---

## 3) `pick_dir` / `pick_file`：**不要用 GUI file picker**（你已经验证过坑）

### 结论（强制规范）

* **不做 GUI 弹窗选文件**（AppleScript / osascript / `choose file`）
  因为：回传路径会出现 quoting/encoding/TTY/stdin 混乱，wrapper 下更容易断。
* 采用：`open "$DIR"` + “拖拽路径到终端” 输入。

### `ux_pick_file_drag` 规范签名

```bash
ux_pick_file_drag "<dir_to_open>" "<prompt>"
```

### 行为

* `open` 打开目录帮助用户定位
* 从 tty 读取拖拽路径
* 归一化：去引号、去 file://、反斜杠空格转空格
* 校验存在性：由调用者做（因为有的要允许不存在）

### 推荐实现

```bash
ux_norm_path() {
  local p="${1-}"
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"
  p="${p%\"}"; p="${p#\"}"
  p="${p%\'}"; p="${p#\'}"
  p="${p#file://}"
  p="${p//\\ / }"
  printf "%s" "$p"
}

ux_pick_file_drag() {
  local dir="${1-}"
  local prompt="${2-:-"Audio file path (drag here): "}"

  [[ -d "$dir" ]] || return 1
  open "$dir" >/dev/null 2>&1 || true

  local raw
  raw="$(read_tty "$prompt")" || return 1
  raw="$(ux_norm_path "$raw")"
  [[ -n "$raw" ]] || return 1
  printf "%s" "$raw"
}
```

---

## 4) `confirm`：危险操作确认（统一 YES / NO 模式）

### 两种确认模式（只保留这两种）

#### A. 强确认（危险操作）

```bash
ux_confirm_yes "Type YES to confirm DELETE sync: "
```

* 必须输入 `YES` 才通过
* 其它都视为取消
* 返回 0/1

#### B. 普通确认

```bash
ux_confirm_yn "Proceed? (y/N): "   # default N
```

### 推荐实现

```bash
ux_confirm_yes() {
  local prompt="${1-}"
  local ans
  ans="$(read_tty "$prompt")" || return 1
  [[ "$ans" == "YES" ]]
}

ux_confirm_yn() {
  local prompt="${1-}"
  local ans
  ans="$(read_tty "$prompt")" || return 1
  case "${ans,,}" in
    y|yes) return 0 ;;
    *)     return 1 ;;
  esac
}
```

> 你提到“危险操作保留在带⚠️入口的 wrapper”——这条属于 **菜单/入口层策略**，但 confirm 仍要保留作为最后防线。

---

## 5) `choose`：编号选择器（不要让用户输入任意字符串）

### 规范签名

```bash
ux_choose "<prompt>" "<default_index>" "<option1>" "<option2>" ...
```

### 行为

* 显示 1..N
* 允许回车用默认值
* 返回选择的 option 文本（stdout） 或返回 index（看你喜欢，但必须统一）

### 推荐（返回 option 文本）

```bash
ux_choose() {
  local prompt="${1-}"
  local def="${2-1}"
  shift 2
  local opts=("$@")

  local i=1
  for o in "${opts[@]}"; do
    printf "%d) %s\n" "$i" "$o" >/dev/tty
    i=$((i+1))
  done

  local ans
  ans="$(read_tty "$prompt")" || return 1
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[0-9]+$ ]] || return 1
  (( ans>=1 && ans<=${#opts[@]} )) || return 1
  printf "%s" "${opts[ans-1]}"
}
```

---

## 6) `ux_tip`：完成态提示（不参与控制流）

### 规范签名

```bash
ux_tip "<title>" "<line1>" "<line2>" ...
```

### 行为

* 打印：

  * 💡 Title:
  * * line1
  * * line2
* 仅输出到 stdout/tty，不 return 特殊码（永远 0）

### 推荐实现

```bash
ux_tip() {
  local title="${1-}"
  shift || true
  echo "💡 ${title}:" >/dev/tty
  local line
  for line in "$@"; do
    [[ -n "${line-}" ]] || continue
    echo "  - ${line}" >/dev/tty
  done
}
```

---

## 7) `ux_open_after`：结束后打开输出（你现在需要的）

### 规范签名

```bash
ux_open_after "<path>" "<label>"
```

### 行为（macOS）

* 如果 path 是文件：打开其目录并选中该文件（Finder）
* 如果 path 是目录：直接打开目录
* 失败不算错误（return 0），避免影响脚本整体成功态

### 推荐实现

```bash
ux_open_after() {
  local p="${1-}"
  local label="${2-Output}"

  [[ -n "$p" ]] || return 0
  if [[ -d "$p" ]]; then
    open "$p" >/dev/null 2>&1 || true
    return 0
  fi
  if [[ -f "$p" ]]; then
    open -R "$p" >/dev/null 2>&1 || open "$(dirname "$p")" >/dev/null 2>&1 || true
    return 0
  fi
  return 0
}
```

> 你说“最好结束后打开 Lyrics 文件夹”：
> 你现在用 `ux_open_after "$OUT"` 会打开并选中输出文件，更好。
> 如果你想“固定打开目录”，就 `ux_open_after "$LYRICS_DIR"`。

---

## 8) 参数归一化规范（你已经踩过两个典型坑）

### 8.1 `MODE` 归一化（解决 `:hybrid`）

```bash
ux_norm_mode() {
  local m="${1-}"
  m="${m#"${m%%[![:space:]]*}"}"; m="${m%"${m##*[![:space:]]}"}"
  m="${m,,}"
  m="${m#:}"
  printf "%s" "$m"
}
```

### 8.2 `INTERVAL` 归一化（解决 `:12` 传给 python float 崩）

```bash
ux_norm_number() {
  local x="${1-}"
  x="${x#"${x%%[![:space:]]*}"}"; x="${x%"${x##*[![:space:]]}"}"
  x="${x#:}"
  [[ "$x" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
  printf "%s" "$x"
}
```

---

# 你要的“落地动作”（直接告诉你该怎么改）

1. 在 `_lib/ux.sh` 里补齐：`read_tty / ux_tip / ux_open_after / ux_pick_file_drag / ux_norm_mode / ux_norm_number`
2. 你的 lyrics 脚本末尾加一行（成功态）：

```bash
ux_open_after "$OUT" "Lyrics output"
```

或打开目录：

```bash
ux_open_after "$LYRICS_DIR" "Lyrics folder"
```

---

## English summary

I drafted a concrete **Toolbox UX Spec v1.0** for `_lib/ux.sh`, defining stable primitives (`read_tty`, drag-to-pick file, `confirm`, `choose`, `ux_tip`, `ux_open_after`) and hard rules (always read from `/dev/tty`, CLI-first then interactive, `ux_*` must not change control flow, safe under `set -u`). It also includes normalizers to fix your real-world bugs like `:hybrid` and `:12`.
