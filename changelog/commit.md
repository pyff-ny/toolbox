## Commit 模板（施工日志：怎么改的）
目标：让你 3 个月后看 git log 还能复现当时的施工思路。
格式建议
type(scope): summary
body 只写“做了什么改动、改在哪里、关键实现点”
例子（贴合你今天）

chore(toolbox): enforce scripts as source of truth and clean execution path

- Make bin launchers exec scripts directly (no duplicated logic)
- Add _out as runtime output boundary and update .gitignore
- Adjust action menu visibility rules for prompt-based commands
- Improve run_cmd signal handling (Ctrl+C -> exit 130)
