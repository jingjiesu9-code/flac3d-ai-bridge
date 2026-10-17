# flac3d-ai-bridge

[![CI](https://github.com/jingjiesu9-code/flac3d-ai-bridge/actions/workflows/ci.yml/badge.svg)](https://github.com/jingjiesu9-code/flac3d-ai-bridge/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6.svg)](#兼容性)
[![FLAC3D](https://img.shields.io/badge/FLAC3D-7.x-orange.svg)](#兼容性)
[![MCP](https://img.shields.io/badge/MCP-stdio-6E56CF.svg)](https://modelcontextprotocol.io/)

**让 AI 助手（DeepSeek Harness / Codex / Claude Desktop / 任何 MCP 客户端）直接驱动你本机的 ITASCA FLAC3D**：
读模型、发命令、跑算例、盯进度。也可以完全不用 MCP，用附带的命令行工具 `flacctl.py` 脚本化控制。

> 中文 | [English](README.en.md)
>
> 适用 **ITASCA FLAC3D 7.x + Windows 10/11**（其他版本需自行验证）。本项目不绑定任何具体工程场景 —— 装好之后就是一个通用的 FLAC3D 控制通道。

---

## 目录

- [它解决什么问题](#它解决什么问题)
- [特性](#特性)
- [环境要求](#环境要求)
- [安装](#安装)
- [启动 bridge](#启动-bridge)
- [用法 A：在 AI 聊天里直接调用工具](#用法-a在-ai-聊天里直接调用工具)
- [用法 B：命令行直连（不需要 AI）](#用法-b命令行直连不需要-ai)
- [可选：给 DSH 加一个「FLAC3D 建模」模式](#可选给-dsh-加一个flac3d-建模模式)
- [工具清单](#工具清单)
- [目录结构](#目录结构)
- [版本配对与上游状态](#版本配对与上游状态)
- [排错](#排错)
- [三条硬性约束](#三条硬性约束)
- [安全说明](#安全说明)
- [兼容性](#兼容性)
- [卸载](#卸载)
- [贡献](#贡献)
- [许可证与第三方](#许可证与第三方)

---

## 它解决什么问题

FLAC3D 本身没有对外的控制接口。这个项目在 FLAC3D 进程内起一个本地 HTTP 服务
（`itasca-mcp-bridge`），再用一个 MCP 服务器（`flac-mcp`）把它翻译成 AI 能调用的工具。

```
   AI 客户端（DSH / Codex / Claude Desktop / ...）
        │  MCP (stdio)
        ▼
   flac-mcp                 ← 协议翻译，纯转发
        │  HTTP  127.0.0.1:9001
        ▼
   itasca-mcp-bridge        ← 跑在 FLAC3D 进程内部，用 itasca SDK 操作模型
        │
        ▼
   FLAC3D
```

**关键点：MCP 只是外壳。** bridge 是个普通 HTTP 服务，包里的 `flacctl.py`
（纯标准库）可以直接跟它对话 —— 不需要 MCP、不需要 AI、不需要任何第三方依赖。
所以你有两条独立通路，可以同时用。

## 特性

- **两条通路，一个内核**：MCP 工具负责聊天里用，`flacctl.py` 负责脚本/批处理；两者都打到同一个 bridge。
- **安装编排脚本**：`configure.ps1` 自动探测 FLAC3D / Python / DSH 并渲染所有含路径的文件，
  `setup.ps1` 一键装 bridge、建 venv、装 flac-mcp、自检，可反复运行。
- **排障工具**：`doctor.ps1` 9 项全链路体检，`verify_mcp.ps1` 只验 MCP 层（算例运行期间也安全）。
- **版本配对被锁死**：找得到最容易踩的坑（见[版本配对](#版本配对与上游状态)），不配对时直接指出原因。
- **零侵入**：不改 FLAC3D、不改 bridge/flac-mcp 源码，只做安装与配置编排；所有生成物都有模板可追溯。
- **可选 DSH 集成**：一行 patch 把工具挂进 DeepSeek Harness，还附带一个自带 FLAC3D 操作约定的 agent 模式。

## 环境要求

| 需要 | 说明 |
|---|---|
| Windows 10/11 | 编排脚本是 PowerShell；`flacctl.py` 本身跨平台 |
| FLAC3D 7.x | 已安装且能正常启动（脚本会自动找，也可手动指定） |
| Python 3.8–3.12 | 宿主机上的普通 Python，用来装 `flac-mcp`。**不是** FLAC3D 内嵌的那个 3.6 |
| PowerShell 5.1+ | Windows 自带即可 |
| Node.js（可选） | 只有 `verify_mcp.ps1` 的裸 JSON-RPC 探针需要 |
| 网络（仅首次） | 首次安装要从 PyPI 装两个包；之后完全离线可用 |
| DSH（可选） | 想在这个聊天里用 `mcp__flac3d__*` 工具才需要；其他 MCP 客户端不需要 |

## 安装

### 1. 获取代码

```powershell
git clone https://github.com/jingjiesu9-code/flac3d-ai-bridge.git
cd flac3d-ai-bridge
```

也可以直接在 [Releases](https://github.com/jingjiesu9-code/flac3d-ai-bridge/releases) 下载 zip 解压。

### 2. 探测环境

```powershell
.\configure.ps1                  # 探测本机 FLAC3D / Python / DSH，生成配置
```

探测不到时手动指定：

```powershell
.\configure.ps1 -Flac3dDir 'D:\Itasca\FLAC3D700' -Flac3dProject 'D:\my-model'
```

### 3. 安装

```powershell
.\setup.ps1                      # 装 bridge、建 venv、装 flac-mcp、自检
.\setup.ps1 -IndexUrl https://pypi.tuna.tsinghua.edu.cn/simple/   # 国内加速
```

`setup.ps1` 是幂等的，任何时候都可以重跑。装完后的目录里会多出三个生成物
（`preset.json`、`flac3d\run_bridge.dat`、`dsh\mcp-flac3d.patch.yml`），它们已加入 `.gitignore`，
不要提交。

## 启动 bridge

**每次 FLAC3D 启动后都要做一次**（bridge 不随 FLAC3D 自动启动）。

在 FLAC3D 的**命令控制台**（提示符 `flac3d>`）里执行 —— **不是** IPython 面板：

```
program call '<安装目录>\flac3d\run_bridge.dat'
```

> ⚠️ 这是 FLAC3D 命令语法，不是 Python。粘到 IPython 面板会得到
> `SyntaxError: invalid syntax`。如果界面上只看到 IPython，命令控制台一般在视图菜单里。
>
> 如果只想在 IPython 面板里操作，等价的 Python 是：
>
> ```python
> import itasca_mcp_bridge as b; b.start(host="127.0.0.1", port=9001, mode="console", auto_upgrade=False)
> ```

看到 `BRIDGE_READY: http://127.0.0.1:9001` 即成功。也可以让脚本代劳：

```powershell
.\start_bridge.ps1               # 拉起 FLAC3D 并等端口就绪
```

体检：

```powershell
.\doctor.ps1                     # 9 项全链路检查，异常直接指向原因
.\verify_mcp.ps1                 # 只验 MCP 层，算例运行期间也安全
```

## 用法 A：在 AI 聊天里直接调用工具

挂进 DSH（**可选**，其他 MCP 客户端按各自方式配置同一个 `flac-mcp` 命令即可）：

```powershell
.\apply_dsh_mcp.ps1              # 幂等，自动备份，-Remove 可撤销
```

然后**重启 DSH**。新会话里会出现 10 个 `mcp__flac3d__*` 工具（见[工具清单](#工具清单)）。

其他 MCP 客户端（Claude Desktop、Codex 等）用标准的 `mcpServers` 配置即可，命令是 venv 里的
`flac-mcp.exe`，参数与 `dsh\mcp-flac3d.patch.yml` 一致：

```json
{
  "mcpServers": {
    "flac3d": {
      "command": "C:\\path\\to\\flac3d-ai-bridge\\.venv-flac\\Scripts\\flac-mcp.exe",
      "args": ["--bridge-url", "http://127.0.0.1:9001", "--log-level", "warning"]
    }
  }
}
```

> 为什么需要 `apply_dsh_mcp.ps1`：DSH 自带 `@deepseek-ai/dsh-mcp-client`，
> 但**没有任何 bundle 挂载它** —— `dsh --dump-config` 里搜不到任何 `mcp` 字样，
> 容易误判成「DSH 不支持 MCP」。它支持，只是要在 profile 的用户补丁层插一行。
> 脚本做的就是这件事。

## 用法 B：命令行直连（不需要 AI）

```powershell
$py = (Get-Content .\preset.json -Raw | ConvertFrom-Json).hostPython

& $py flacctl.py ping                           # bridge 活着吗
& $py flacctl.py code "print(itasca.cycle())"   # 在 FLAC3D 里跑 Python
& $py flacctl.py code @myscript.py              # 跑本地脚本文件
& $py flacctl.py cmd "model new"
& $py flacctl.py cmd "zone create brick size 2 2 2"
& $py flacctl.py tasks --limit 5
& $py flacctl.py run long_job.py "描述"          # 提交异步任务
& $py flacctl.py check <task_id>
& $py flacctl.py interrupt <task_id>
```

全局参数放在子命令**前面**：`flacctl.py --timeout 20 tasks` ✅ ／ `flacctl.py tasks --timeout 20` ❌。

`flacctl.py` 只用标准库，成功返回 0、失败返回 1，方便串到批处理脚本里；加 `--raw` 打印原始 JSON。
bridge 地址可用 `--url` 或环境变量 `FLAC_MCP_BRIDGE_URL` 覆盖。

## 可选：给 DSH 加一个「FLAC3D 建模」模式

包里的 `dsh\agent_preset\` 是一个 agent preset：选中它之后，系统提示词自带 FLAC3D
操作约定，并附一份 `flac3d-simulation` 技能。

```powershell
.\dsh\install_agent_preset.ps1
```

装完后在新建会话的模式选择器里选「FLAC3D 建模」。**只有空会话能切换模式**，
所以要用它必须新建会话。

## 工具清单

挂进 MCP 客户端后，工具名统一带 `mcp__<serverName>__` 前缀（默认 `mcp__flac3d__`）：

| 工具 | 用途 |
|---|---|
| `flac_execute_code` | 同步执行 Python，适合读值、改变量、小操作 |
| `flac_execute_task` | 提交异步任务脚本，立即返回 `task_id`，适合 `model solve` 之类长任务 |
| `flac_check_task_status` | 查看任务状态，带实时控制台输出尾部 |
| `flac_list_tasks` | 列出已跟踪的任务 |
| `flac_interrupt_task` | 中断正在跑的任务 |
| `flac_query_command` | 查 FLAC 命令语法 |
| `flac_browse_commands` | 浏览命令参考 |
| `flac_query_python_api` | 查 Python SDK 接口 |
| `flac_browse_python_api` | 浏览 Python SDK |
| `flac_browse_reference` | 查 zone 本构模型 / 结构单元属性名等参考表 |

## 目录结构

| 文件 | 作用 |
|---|---|
| `preset.template.json` | 配置模板（含占位符）。**不要手改** |
| `preset.json` | `configure.ps1` 生成的实际配置，所有脚本的唯一事实源（已 gitignore） |
| `configure.ps1` | 探测本机环境并渲染所有含路径的文件 |
| `setup.ps1` | 一键安装（可反复运行） |
| `doctor.ps1` | 9 项全链路体检 |
| `verify_mcp.ps1` | 独立验证 MCP 层（不经过 AI 客户端） |
| `mcp_stdio_probe.js` | 上面用的裸 JSON-RPC 探针（无 SDK 依赖，需 node） |
| `install_bridge.ps1` | 只装 bridge 到 FLAC3D 内嵌 Python |
| `start_bridge.ps1` | 拉起 FLAC3D + bridge 并等端口就绪 |
| `flacctl.py` | 直连通路命令行工具，**纯标准库** |
| `apply_dsh_mcp.ps1` | 把 MCP 工具挂进 DSH（可选） |
| `flac3d\start_bridge.py` | bridge 实际启动代码 |
| `dsh\mcp-flac3d.patch.yml.template` | 写进 DSH profile 的那段 YAML 模板 |
| `dsh\agent_preset\` | 可选的「FLAC3D 建模」agent preset |
| `dsh\build_preset.py` | 从 DSH 自带 standard 模式生成 preset（构建期） |
| `dsh\validate_preset.py` | preset 结构校验（构建期/安装前） |
| `tests\check_repo.py` | 不依赖 FLAC3D 的仓库自检（CI 用） |

> `.ps1` 文件一律**只用 ASCII**。Windows PowerShell 5.1 在没有 BOM 时按 ANSI 读 `.ps1`，
> 中文注释会变乱码 —— 排障工具自己乱码比英文更难用。中文说明都放在文档里。
> CI 会强制检查这一点。

## 版本配对与上游状态

| 组件 | 本项目锁定 | 说明 |
|---|---|---|
| `itasca-mcp-bridge` | **0.5.5** | 必须 ≥ 0.5 |
| `flac-mcp` | **0.5.2** | 只支持 HTTP+SSE 的 bridge |

bridge 0.2.x 用的是 **WebSocket** 协议，配 flac-mcp 0.5.2 只会得到一句
`400 Bad Request for url '.../execute_code'` —— 完全看不出是版本问题。
`doctor.ps1` 的 pairing 那一行就是专门查这个的。

改版本：`configure.ps1 -BridgeVersion 0.5.5 -FlacMcpVersion 0.5.2`，然后重跑 `setup.ps1`。

> **上游状态（2026-10）**：`flac-mcp` 在 PyPI 上已标记为 deprecated，继任者是
> [itasca-mcp](https://github.com/yusong652/itasca-mcp)（版本 0.10.x，同样 MIT）。
> 本项目 v1.0 锁定的是**已经实测跑通的** bridge 0.5.5 + flac-mcp 0.5.2 组合，
> 没有迁移到 itasca-mcp —— 迁移后工具名/参数可能变化，需要重新验证。
> 如果你要迁移，欢迎提交 PR 并在 PR 里说明实测的 FLAC3D 版本。

## 排错

| 症状 | 原因 | 处理 |
|---|---|---|
| `400 Bad Request ... /execute_code` | bridge/flac-mcp 版本不配对 | 看 `doctor.ps1` 的 pairing 行 |
| 升级 bridge 后没变化 | 旧进程还在跑旧代码 | **重启 FLAC3D** —— 升级不会在运行中的进程里生效 |
| 一切调用返回 `timeout` / `stuck_in_c` | FLAC3D 解释器停在 `Fish>` 提示符 | 重启 FLAC3D。预防：FISH 写进 `.f3dat` 用 `program call` 跑，别拆成多条命令 |
| `program call` 报 `SyntaxError` | 粘到 IPython 面板了 | 要用 FLAC3D **命令控制台**（`flac3d>`） |
| 聊天里没有 `mcp__flac3d__*` | DSH 没重启，或补丁没生效 | `verify_mcp.ps1` → `doctor.ps1` → 重启 DSH |
| `model save` 写出了字面文件名 | save 名不能参数化 | 用字面命名，靠 tag 区分算例 |
| 数值微妙地不对但没有报错 | 给 FISH 三角函数喂了角度 | FISH 用**弧度**：`角度 * math.pi / 180.0` |
| `pip install` 卡住不动 | pip 的 cache/temp 不可写 | 本项目已把 `PIP_CACHE_DIR`/`TMP` 指到包内目录 |
| 端口在听但探测不到 | `Get-NetTCPConnection` 在某些环境不可靠 | 本项目一律用 `netstat -ano` |
| 中文输出 `UnicodeEncodeError` | 控制台是 GBK | `flacctl.py` 已设 `errors="replace"` |
| `doctor.ps1` 报 preset.json 不存在 | 还没跑过 `configure.ps1` | 先 `.\configure.ps1` |

## 三条硬性约束

写任何 FLAC3D 自动化之前必须知道：

1. **单进程单线程。** 两个算例不能并行；`model new` 会直接毁掉当前模型。
   批量跑必须串成一条链，不能并发提交。
2. **长任务走异步接口。** `flac_execute_code` 是同步的，会一直阻塞到超时；
   `model solve` 之类必须走 `flac_execute_task`。
3. **FISH 是 Python 3.6 且三角函数用弧度。** 没有 `math.deg2rad`；
   `math.sin(30.0)` 返回 `-0.988` 而不是 `0.5` —— **不报错，只是静默算错**。

## 安全说明

- bridge 只监听 `127.0.0.1`，**没有认证**。不要把它暴露到公网、不要把端口转发出去；
  同一台机器上的任何进程都能连上来。
- 通过 MCP 工具或 `flacctl.py` 执行的是 FLAC3D 进程内的**任意 Python**，
  等价于该进程的完整权限。只在你自己可信的机器/账号下使用。
- `configure.ps1`/`setup.ps1` 只写本项目目录和 FLAC3D 的 user-site Python 包，不改系统目录。
- 本项目不上传任何数据；除首次 `pip install` 外不需要外网。

## 兼容性

| 项 | 状态 |
|---|---|
| Windows 10 / 11 + PowerShell 5.1 | ✅ 主要目标平台，实测 |
| Windows 11 + PowerShell 7 | ⚠️ 未系统测试，脚本按 5.1 兼容写 |
| FLAC3D 7.0 / 7.1 | ✅ 目标版本；版本号从 exe 文件名推断 |
| FLAC3D 6.x / 9.x | ❌ 未验证，bridge 与命令语法可能不兼容 |
| macOS / Linux 跑编排脚本 | ❌ 不支持（PowerShell + Windows 路径 + netstat 语义） |
| macOS / Linux 跑 `flacctl.py` | ⚠️ 理论可行（纯标准库 HTTP），前提是能访问 bridge 端口 |

## 卸载

```powershell
# 1. 从 DSH profile 里移除托管块（自动备份）
.\apply_dsh_mcp.ps1 -Remove

# 2. 卸掉 FLAC3D 内嵌 Python 里的 bridge
$py = (Get-Content .\preset.json -Raw | ConvertFrom-Json).flac3d.pythonExe
& $py -m pip uninstall -y itasca-mcp-bridge

# 3. 删除「FLAC3D 建模」模式（如果装过）
Remove-Item -Recurse -Force "$HOME\.dsh\.agent-presets\flac3d"

# 4. 删掉整个目录即可
```

## 贡献

欢迎 issue 和 PR。提交前请跑一遍：

```powershell
python -m pip install pyyaml
python tests\check_repo.py
```

CI（GitHub Actions）会在 Ubuntu 和 Windows 上跑同一套检查，另外在 Windows 上用
PowerShell 解析器校验所有 `.ps1` 语法、强制 `.ps1` 保持 ASCII + 无 BOM。
改动涉及 FLAC3D 行为时，请在 PR 里注明实测的 FLAC3D 版本和 Windows 版本。

## 许可证与第三方

本项目自身代码以 [MIT License](LICENSE) 发布。第三方组件、商标与免责声明见 [NOTICE](NOTICE)：

- **FLAC3D 是 Itasca Consulting Group 的商业软件**，本项目不包含也不重新分发它，
  使用需要你自己的有效许可证；本项目与 Itasca 无隶属关系，也未获其背书。
- `itasca-mcp-bridge`、`flac-mcp`（以及继任者 `itasca-mcp`）是上游作者的 MIT 开源软件，
  本项目只做版本锁定与安装编排，不修改它们。
- `dsh/agent_preset/flac3d/agent.cordis.yml` 派生自 DeepSeek Harness 自带的 `standard`
  preset（见 `dsh/build_preset.py`），用于让 preset 可复现、可审查。

## 致谢

- [itasca-mcp](https://github.com/yusong652/itasca-mcp) / `flac-mcp` / `itasca-mcp-bridge`
  的作者 —— bridge 与 MCP 层是这个项目真正干活的部分。
- [DeepSeek Harness](https://deepseek.com) —— 提供 MCP 客户端与 agent preset 机制。
- 所有在 issue 里报告过坑的人。
