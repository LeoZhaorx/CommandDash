# Security Policy

## Supported version

当前仅维护 `main` 分支上的最新版本。

## Report a vulnerability

请通过 GitHub Security Advisory 私下报告安全问题，不要先创建公开 Issue。报告中请包含复现步骤、影响范围和建议修复方式。

## Execution model

CommandDash 会以当前 macOS 用户权限运行用户主动添加的 `.command`、`.sh` 文件和 `.app`。它不是沙箱，也不会审查脚本内容。只添加你理解并信任的文件，并在停止进程前确认运行项归属。
