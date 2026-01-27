## 记录边界：什么写进 changelog，什么写进 commit
你要的“记忆参考”其实就是把信息放到正确层级，避免散。
commit：记录“怎么改的”（细节、diff）
changelog：记录“对使用者有什么变化”（行为变化、功能新增/修复）
maintenance log（可选）：记录“为什么这么改”（故障现象、证据、命令）
一句话：
commit 是施工日志；changelog 是发布公告；maintenance log 是事故报告。

## 5) 给未来的你：一条“边界校验”口诀
每次你要加功能/改结构前，问自己三句：
这段逻辑属于 scripts 还是 bin？
这是源码还是产物？产物必须进 _out。
这次变化对使用者可见吗？可见就写 changelog。
如果三句都答得出来，你就不会走回“混乱态”。
----

# Maintenance Log 模板（事故报告：为什么这么改，证据是什么）
目标：把“当时的混乱、证据、判断链”保留住。以后再遇到类似问题，你一翻就能直接复用思路。
建议放哪里
reports/maintenance/ 或 changelog/maintenance/
命名：YYYY-MM-DD_<topic>.md
结构（你会很喜欢这个清晰度）

# 2026-01-26 | 

# 1. Embedded git repo warning + wrapper drift

## Symptom
- git warns: "adding embedded git repository: toolbox_changelog"
- behavior mismatch between bin wrapper and scripts version

## Impact
- Confusing entry point; changes appear not to take effect
- Maintenance requires editing in multiple places

## Root cause
- Nested git metadata / cached index state created embedded-repo semantics
- Two execution sources (bin vs scripts) caused drift

## Evidence
- `type -a toolbox_super_compatible` -> points to `~/toolbox/bin/...`
- `ls -l bin/...` timestamp differs from scripts
- git warning output (screenshot/log)

## Fix
- Remove embedded repo artifacts (`git rm --cached ...`, delete nested .git)
- Enforce single source of truth: bin launchers exec scripts
- Establish `_out/` boundary + .gitignore

## Prevention
- Never copy repos into repos; keep single toolbox repo
- Always verify entry point via `type -a <cmd>`
- Outputs must go to `_out/`
