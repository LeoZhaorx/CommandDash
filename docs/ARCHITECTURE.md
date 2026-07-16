# CommandDash Architecture

CommandDash 是一个不依赖第三方运行库的原生 macOS SwiftUI 应用。源码直接由 `swiftc` 编译并组装为 `.app`。

## Modules

| 文件 | 职责 |
| --- | --- |
| `CommandDashApp.swift` | SwiftUI 场景、菜单栏入口、固定尺寸无边框窗口与窗口位置恢复。 |
| `ContentView.swift` | 启动卡片、Tab、拖放、运行状态列表、日志面板和编辑弹窗。 |
| `AppState.swift` | 用户数据持久化、任务启动、日志状态、运行扫描调度和停止流程。 |
| `CommandRunner.swift` | 通过 `Process` 启动 shell、脚本或系统 `open`，并汇集 stdout/stderr。 |
| `RunningCommandMonitor.swift` | 读取 `ps` 与 `lsof`，结合路径、端口、进程组和启动会话推断任务归属。 |
| `Models.swift` | 启动项、运行记录、停止策略和运行指纹的数据模型。 |
| `Theme.swift`, `GlassUI.swift`, `CommandIconStyle.swift` | 视觉变量、玻璃面板和卡片图标样式。 |

## Data flow

1. 用户把 `.command`、`.sh` 或 `.app` 拖入指定 Tab。
2. `AppState` 把启动项写入用户的 Application Support 目录。
3. 点击卡片后，脚本通过 `/bin/zsh <path>` 启动，App 通过 `/usr/bin/open <path>` 启动。
4. `CommandRunner` 合并 stdout/stderr 并回传到界面日志。
5. `RunningCommandMonitor` 周期性读取系统进程与监听端口，生成运行记录。
6. 停止操作优先针对安全的进程组；存在归属冲突时退化为排除共享 PID 后的 PID 列表。

## Persistence

默认数据目录：

```text
~/Library/Application Support/CommandDash/
```

- `commands.json`：启动项及其 Tab、Emoji、背景信息。
- `tabs.json`：Tab 顺序。
- `runtime_fingerprints.json`：从运行进程学习到的路径和端口提示。

窗口位置与最近 Tab 使用 `UserDefaults` 保存。

## Trust boundary

CommandDash 是用户主动选择的本地任务启动器，不是安全沙箱。脚本拥有当前用户可用的权限，运行监控需要读取进程命令行和监听端口。任何修改停止算法的贡献都应优先避免把同一个 PID 归属给多个启动项。
