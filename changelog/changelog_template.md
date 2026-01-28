# Changelog
## Changelog 模板（发布公告：对使用者有什么变化）
目标：用户（也包括未来的你当用户）看完就知道“我现在能干什么、有什么不同”。
结构固定
Added / Changed / Fixed / Removed / Breaking
例子

## [Unreleased]
### Added
- 
### Changed
- 
### Fixed
- 
### Removed
- 
### Breaking
- 
## [2026-01-26]
### Changed
- `toolbox_super_compatible` is now the primary entry point 我确定了toolbox_super_compatible是目前唯一入口
- Output artifacts are stored under `_out/` (ignored by git) 统一了脚本产出地址到 _out/，便于.gitignore维护
- Action menu hides "Run with prompts" for unsupported commands 对于使用不到 "Run with prompts"的子程序，使prompts不可见，避免误操作

### Fixed
- Ctrl+C handling now cleanly returns to menu (exit 130) 改进了 ctrl c 命令，停止目前子程序后可以正常返回到主菜单
