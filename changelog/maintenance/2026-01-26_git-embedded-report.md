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
- 重新生成wrapper，强制bin指向路径统一

## Prevention
- 放在脚本开头，需要时显示echo内容
TOOLBOX_VERSION="2026-01-26"
#echo "[INFO] toolbox version: $TOOLBOX_VERSION"

