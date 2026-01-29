# 故障速查表（Toolbox / macOS / Shell）

## T1 | macOS 上 `rm -r/-rf` 删不掉目录（路径/权限都正确）


**现象**

* `pwd` 正确在 `~/toolbox`
* `ls -ld target` 显示你是 owner 且有写权限
* 但 `rm -r` / `rm -rf` 仍失败

**判定（优先怀疑）**：目录或内部文件带 **immutable flag（uchg/schg）**，权限再对也删不动

**定位**

```bash
ls -ldO scripts/media/Lyrics
# 看输出中是否出现 uchg / schg
```

**修复（唯一正确解）**

```bash
sudo chflags -R nouchg scripts/media/Lyrics
rm -rf scripts/media/Lyrics
```

**预防**

* 同步/备份/脚本可能会把 flag 带过来；遇到“rm 核按钮也无效”，直接跳到 `ls -ldO`

---

## T2 | macOS 的 `/bin/rm` 不支持 `--help`（“illegal option -- -”）
#macos #system


**现象**

```bash
rm --help | head
# rm: illegal option -- -
```

**判定**：你用的是 **BSD rm（macOS 自带 /bin/rm）**，不支持 GNU 风格长参数 `--help`

**正确做法**

```bash
man rm
rm -h   # 有些工具支持 -h；rm 通常用 man
```

**补充**

* 这也顺带证明：你看到的 `rm [-pv]` 不是系统 rm 的语法，而多半来自某个脚本/usage 文本

---

## T3 | 终端里出现“引号/符号怪异”，脚本变量多了中文引号导致逻辑异常
#input

**现象**

* 数值或字符串输出里出现 `“80”` 这种中文引号
* 同样脚本在另一台机器正常，这台不正常
* grep/比较/数值判断莫名失败

**判定**：输入法导致你写进去了 **中文全角引号**（`“ ”`）而不是 ASCII `"`

**定位（快速肉眼）**

* 看起来像引号，但宽一点、弯一点：基本就是全角

**修复**

* 把 `“ ”` 全部替换成 `"`（ASCII）
* 推荐用编辑器全局替换，或命令行（谨慎对路径）

```bash
# 示例：只给你思路，执行前先备份/确认文件
grep -n '“\|”' -R scripts
```

**预防**

* 写脚本时强制英文输入法
* 关键输出统一用 `printf '%q\n' "$var"` 做可见化（调试期）

---

## T4 | fzf 场景里 `read -r` 读输入不稳定（或 Ctrl+C 行为怪）
#fzf

**现象**

* 选择菜单后提示输入参数，`read -r` 偶尔读不到/卡住/被 fzf/管道影响
* Ctrl+C 影响主程序稳定性

**判定**：fzf/管道/子 shell 场景下 stdin 不可靠，需要从 **/dev/tty** 直接读

**正确模式（你现在用的就是对的）**

```bash
read_tty() {
  local prompt="$1"
  local out=""
  printf "%s" "$prompt" >/dev/tty
  IFS= read -r out </dev/tty || true
  printf "%s" "$out"
}
```

**预防**

* 任何“菜单 + 输入”组合，都优先 `read_tty`

---

## T5 | 扁平化菜单后，脚本路径/Wrapper 路径容易漂移（尤其目录结构变更）
#wrapper


**现象**

* 菜单能选到脚本，但执行时报“找不到文件”
* wrapper 指向旧目录，移动 scripts 目录结构后 wrapper 全失效

**判定**

* wrapper 写死了绝对路径，或相对路径计算不稳
* 扁平化扫描拿到的是 `REL`，但执行时拼路径有边界 bug

**稳健策略（你当前方案正确）**

* **执行**：统一 `REL + DIR + FILE`，并在 run_cmd 里打印 `[RUN] REL -> fullpath/file`
* **wrapper**：尽量写成相对 `$SCRIPTS_DIR` 的路径，而不是绝对路径

**可选增强（建议写进代码注释）**

* wrapper 内容固定：

```bash
SCRIPTS_DIR="${SCRIPTS_DIR:-$HOME/toolbox/scripts}"
exec "$SCRIPTS_DIR/<rel_dir>/<file>" "$@"
```

---

## T6 | Ctrl+C 需求：只中断子脚本，不退出 toolbox 主程序
#interact#ctrlc

**现象**

* Ctrl+C 想停止当前脚本，但不要把主菜单也杀掉

**判定**

* 需要把信号处理隔离在子 shell，主循环忽略 INT

**标准做法（你现在 run_cmd 结构是对的）**

* 主循环：

```bash
trap '' INT
```

* 运行子任务用子 shell，并在子 shell 内 trap INT：

```bash
(
  trap 'echo; echo "[INFO] Script interrupted. Returning to menu..."; exit 130' INT
  bash "$script" "$@"
)
```

* 返回后根据 exit code 打印结果（0/130/其他）

---

## T7 | rsync dry-run 也会“读盘”吗？（SSD data_read 统计困惑）
#rsync#dry-run#fzf

**现象**

* 你连续跑 rsync（包括 dry-run），发现 SSD `data_read` 仍增长
* dry-run 体积很小时可能看不出来变化

**判定（经验结论）**

* dry-run 不写入目标，但仍可能需要**枚举文件、读元数据**，某些情况下也会读更多（比如需要扫描大量目录/文件列表）
* 是否大量读盘，取决于：文件数、目录深度、是否需要比对属性、是否启用 checksum 等

**实用建议**

* 用“文件数量/路径变化”来判断 dry-run 的真实成本，不要只看本次拷贝字节
* 你已经确认“没有 checksum”，所以读盘成本通常主要来自目录遍历/元数据比对

---

## T8 | `eject /dev/diskX` 报错（用错命令/对象）
#tools
**现象**

* 你在 macOS 上执行类似：

  ```bash
  eject /dev/disk5
  ```

  报错或不生效

**判定**

* macOS 常用卸载/弹出命令是 `diskutil`（不是 Linux 的 eject 习惯）
* 需要区分：

  * **卸载 volume**（unmount）
  * **弹出磁盘**（eject）

**定位**

```bash
diskutil list
diskutil info /dev/disk5
```

**修复**

* 卸载该盘所有卷：

```bash
diskutil unmountDisk /dev/disk5
```

* 弹出（断开）该盘：

```bash
diskutil eject /dev/disk5
```

**预防**

* 记住：macOS 上“磁盘相关”优先 `diskutil`

---

## T9 | “filtered files” 是什么意思（rsync 输出理解）
#rsync
**现象**

* rsync 输出里出现 `filtered files`，你不确定含义

**判定**

* 被 rsync **排除/过滤** 的文件数量（通常来自 `--exclude`、`--filter`、`.rsync-filter` 或默认规则）
* 也可能是你脚本里设置了排除项（常见：`.DS_Store`、缓存、临时文件、node_modules 等）

**定位**

* 看你运行命令里是否有：

  * `--exclude=...`
  * `--filter=...`
  * `--exclude-from=...`
* 或检查目录里是否有 `.rsync-filter`

**修复**

* 想让它不被过滤：移除对应 exclude/filter 规则
* 想确认“到底过滤了哪些”：加上 itemize/verbose（根据你的脚本可选）

```bash
rsync -avn --itemize-changes ...
```

**预防**

* 备份脚本里明确把 exclude/filter 写到注释中，避免“黑箱过滤”

---

## T10 | 三级菜单→扁平化后，“边界”导致路径拼接错
#structure
**现象**

* 菜单能选中脚本，但执行报：

  * 找不到文件
  * 或执行到错误路径
* 你后来通过对比 debug 输出定位到了“边界问题”

**判定**

* 典型错误点：`DIR="."`、`dirname` / `basename` 在根目录时处理不一致
* 以及 `SCRIPTS_DIR` 与 `fullpath` 是否包含尾部 `/` 的细节

**定位（你现在已有）**

```bash
echo "[DBG] REL=$REL DIR=$DIR FILE=$FILE" >/dev/tty
```

**修复（稳健规则）**

* `REL` 永远是相对 `SCRIPTS_DIR` 的路径
* `DIR` 统一归一化：

  * `.` → `$SCRIPTS_DIR`
  * 其他 → `$SCRIPTS_DIR/$DIR`

**预防**

* 所有执行入口只接受：`REL + fullpath + filename + args`
* 禁止在多处重复拼路径（减少边界 bug）

---

## T11 | wrapper 白名单/命名不一致导致“旧 wrapper 干扰”
#wrapper
**现象**

* 你提到“白名单不一致/需要删旧 wrappers 吗？”
* 新结构上线后，旧 wrapper 仍在 PATH，行为不符合预期

**判定**

* wrapper 是**稳定入口**，但也会成为“陈旧指针”
* PATH 顺序导致你调用到旧 wrapper（尤其同名时）

**定位**

```bash
command -v <wrapper_name>
which -a <wrapper_name>
ls -l "$HOME/toolbox/bin/<wrapper_name>"
```

**修复**

* 批量找出 bin 目录里指向旧路径的 wrapper：

```bash
grep -R "toolbox/scripts" "$HOME/toolbox/bin"
```

* 删除或重建（你 toolbox 里已有 delete_wrapper/create_wrapper）

**预防**

* wrapper 内容尽量使用 `$SCRIPTS_DIR` 相对路径，而不是绝对路径
* wrapper 文件头部注释写清 target（你已做到）

---

## T12 | macOS 手势/快捷键与 Windows/VM 映射混乱（“Command+R 变 Spotlight”）
#system
**现象**

* 同一套键位在 iMac/VMware/Windows 里行为不同
* 你遇到：

  * `Command+R` 在某环境触发 Spotlight
  * 删除键不符合预期

**判定**

* 这是“宿主机 macOS + 虚拟机 Windows + 键盘映射层”的叠加结果
* VMware 可能把部分组合键拦截/映射为系统快捷键

**定位**

* VMware 设置里找：

  * Keyboard shortcuts / Key mapping
  * 是否启用 “Send shortcuts to virtual machine”

**修复（原则）**

* 在 VM 里用 Windows 语义的删除：`Del` / `Fn+Delete`（按你的键盘型号）
* 对关键组合键，优先设置 VMware：把快捷键“发送到虚拟机”

**预防**

* 形成两套 muscle memory：macOS / Windows（VM 内）
* 常用操作用 UI 路径兜底（文件菜单等），避免组合键陷阱

---

## T13 | zsh 插件：补全/高亮/建议（“三个必要插件”）
#zsh 
**现象**

* 你要“高亮、自动补全、历史建议”三件套

**判定**

* zsh 生态里最常见的稳定组合：

  * `zsh-autosuggestions`
  * `zsh-syntax-highlighting`
  * `fast-syntax-highlighting`（可替代上一条）
  * 再加一个补全增强：`zsh-completions`（可选）

**修复（最小可运行）**

* 如果你用 Homebrew：

  * 安装后在 `.zshrc` 按顺序加载（高亮通常要放后面）
* 你之前已经在推进这块，我建议你在速查表里只保留**“插件名 + 加载顺序”**，避免写太长

**预防**

* 插件加载顺序出错会导致“补全/高亮消失”，这是最常见问题



## T14 | 成过程
#interact#ctrlc

**Created**: 2026-01-28 02:37

**A. 触发（Friction）**
- 边界-摩擦-生成-新秩序

**B. 证据（Evidence）**
```bash
# paste commands + outputs
```

**C. 判定（Diagnosis）**
- 

**D. 修复（Fix）**
```bash
# paste fix commands
```

**E. 回归测试（Verify）**
```bash
# how to confirm it's resolved
```

**F. 预防（Prevention）**
- 

## T15 | test: how to use opesearch_troubleshootig.sh
#interact

**Created**: 2026-01-28 09:04

**A. 触发（Friction）**
- help_new_case first

**B. 证据（Evidence）**
```bash
# paste commands + outputs
```

**C. 判定（Diagnosis）**
- 

**D. 修复（Fix）**
```bash
# paste fix commands
```

**E. 回归测试（Verify）**
```bash
# how to confirm it's resolved
```

**F. 预防（Prevention）**
- 

## T16 | zsh出现suspended job数量提示
#zsh

**Created**: 2026-01-28 13:16

**A. 触发（Friction）**
- 提示符左侧出现数字，比如2
- ctrl z

**B. 证据（Evidence）**
```bash
# paste commands + outputs
```
![zsh suspended jobs](../changelog/_assets/2026-01-28_zsh_suspended_jobs.png)
**C. 判定（Diagnosis）**
- ctrl z触发

**D. 修复（Fix）**
```bash
# paste fix commands
```
- jobs / kill 
- exit
**E. 回归测试（Verify）**
```bash
# how to confirm it's resolved
```
- 提示符旁边的数字消失
**F. 预防（Prevention）**
- trap ''TSTP

## T17 | toolbox:Ctrl+C后主程序被杀掉/不能“返回菜单”(set -e +130)
#interact #ctrlc #bash #zsh #set_e #trap

**Created**: 2026-01-28 14:44

**A. 触发（Friction）**
- 在toolbox里运行子脚本按ctrl c
- 预期：只中断子脚本，回到菜单
- 实际：toolbox主程序也直接退出（回到shell）或流程断掉

**B. 证据（Evidence）**
```bash
# paste commands + outputs
```
![ctrlc toolbox shell](../changelog/_assets/2026-01-28_ctrlc_toolbox.png)

**C. 判定（Diagnosis）**
- 1. 看主脚本是否启用 errexit
`grep -n 'set -.*e' toolbox_supper_compatible.sh

**D. 修复（Fix）**
```bash
# paste fix commands
```

**E. 回归测试（Verify）**
```bash
# how to confirm it's resolved
```

**F. 预防（Prevention）**
- 

## T18 | 截图证据管理导致repo膨胀/手动成本高
#github#screenshot

**Created**: 2026-01-28 16:05

**A. 触发（Friction）**
- 截图落在Desktop，需要手动重命名/复制到assets；assets进git导致体积增长快

**B. 证据（Evidence）**
```bash
# paste commands + outputs
```

**C. 判定（Diagnosis）**
- 证据留存需求与代码仓库侧路未分层（raw与publish未分离）

**D. 修复（Fix）**
```bash
# paste fix commands
```
- 分层：assets/ （压缩/进git） + assets_raw/ （原图，不进git）
- 自动化：提供import_screenshot--一键完成“选择-重命名-压缩-落位”

**E. 回归测试（Verify）**
```bash
# how to confirm it's resolved
```

**F. 预防（Prevention）**
- assets设置体积红线（例如 单图 > 500KB必须压缩；raw永不进git）
- 

## T19 | git push no work(untracked files)
#git#macos#troubleshooting

**Created**: 2026-01-29 01:39

**A. 触发（Friction）**
- git push no work

**B. 证据（Evidence）**
```bash
# paste commands + outputs
```

**C. 判定（Diagnosis）**
- push 只推commit；untracked 没add/commit不会被push

**D. 修复（Fix）**
```bash
# paste fix commands
```
![git untracked no push](/changelog/_assets/20260129_014207_git-untracked-no-push.png)


**E. 回归测试（Verify）**
```bash
# how to confirm it's resolved
```

**F. 预防（Prevention）**
- 
