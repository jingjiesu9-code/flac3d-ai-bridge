# 在 FLAC3D 进程内启动 itasca-mcp-bridge。
#
# 用法（二选一）：
#   FLAC3D 控制台里执行:  program call '本文件绝对路径'
#   或者直接用 flac3d/run_bridge.dat
#
# 注意：
#   * 必须在 FLAC3D 进程内运行（bridge 依赖 itasca SDK 访问模型）。
#   * 端口被占用说明 bridge 已在跑，重复 start() 会报错，属正常。
#   * 升级 bridge 后必须重启 FLAC3D，旧进程里仍是旧代码。
import itasca_mcp_bridge

print("BRIDGE_VERSION:", itasca_mcp_bridge.__version__)

itasca_mcp_bridge.start(
    host="127.0.0.1",
    port=9001,
    mode="console",
    auto_upgrade=False,   # 关掉自动升级：避免它私自换版本导致与 flac-mcp 失配
)

print("BRIDGE_READY: http://127.0.0.1:9001")
