# Troubleshooting Index (read-only)

- Source: `docs/TROUBLESHOOTING.md`
- Generated: 2026-01-29 20:12

## System
- T1 | macOS 上 `rm -r/-rf` 删不掉目录（路径/权限都正确）
- T2 | macOS 的 `/bin/rm` 不支持 `--help`（“illegal option -- -”）
- T12 | macOS 手势/快捷键与 Windows/VM 映射混乱（“Command+R 变 Spotlight”）
- T19 | git push no work(untracked files)

## Tools
- T4 | fzf 场景里 `read -r` 读输入不稳定（或 Ctrl+C 行为怪）
- T5 | 扁平化菜单后，脚本路径/Wrapper 路径容易漂移（尤其目录结构变更）
- T7 | rsync dry-run 也会“读盘”吗？（SSD data_read 统计困惑）
- T8 | `eject /dev/diskX` 报错（用错命令/对象）
- T9 | “filtered files” 是什么意思（rsync 输出理解）
- T11 | wrapper 白名单/命名不一致导致“旧 wrapper 干扰”
- T13 | zsh 插件：补全/高亮/建议（“三个必要插件”）
- T16 | zsh出现suspended job数量提示
- T17 | toolbox:Ctrl+C后主程序被杀掉/不能“返回菜单”(set -e +130)
- T20 | bump_toolbox_versiochangelog.md文件写空
- T21 | Shell作业控制（zsh/bash）

## Interaction
- T3 | 终端里出现“引号/符号怪异”，脚本变量多了中文引号导致逻辑异常
- T6 | Ctrl+C 需求：只中断子脚本，不退出 toolbox 主程序
- T14 | 成过程
- T15 | test: how to use opesearch_troubleshootig.sh

## Structure
- T10 | 三级菜单→扁平化后，“边界”导致路径拼接错

## Misc
- T18 | 截图证据管理导致repo膨胀/手动成本高

