# 游戏与 CSP 接口集成说明 (INTEGRATION.md)

## 1. 真实接口核实与权限清单

所有底层物理与控制接口均经过 Assetto Corsa CSP 实机兼容性核实：

| 接口符号 | 所属引擎 | 调用频率 | 安全约束与降级设计 |
| :--- | :--- | :--- | :--- |
| `physics.allowed()` | CSP Lua | 初始化阶段单次 | 检验是否具备物理干预权限。若返回 false，降级为纯数据监控 HUD |
| `physics.setAISplineOffset` | CSP Physics | 10Hz 平滑更新 | 必须经过 `BehaviorActuator` 的速度动态斜率限幅，严禁单帧瞬变打满 |
| `physics.setAICaution` | CSP Physics | 10Hz (Slew-Limiting) | 二阶平滑限幅（1.5 units/s），防止急踩刹车幽灵追尾 |
| `physics.setAIAggression` | CSP Physics | 10Hz (Slew-Limiting) | 二阶平滑限幅 |
| `physics.setExtraAIGrip` | CSP Physics | 10Hz | 用于脏空气下压力衰减与循迹推头微失误补偿 |
| `physics.setAIThrottleLimit` | CSP Physics | 10Hz | Lift and Coast 滑行断油（0.0）与发车失误延迟启动 |
| `physics.setCarFuel` | CSP Physics | 事件驱动 (发车/进站) | 策略注入燃油，替代已淘汰的简易燃油看门狗 |
| `ac.overrideCarControls` | CSP Apps | 60Hz 微操接管 | 看门狗单帧自动释放保护，硬上限 0.5s，用于执行物理 J-Turn 倒挡脱困 |
| `ffi.cdef` / `ffi.new` | LuaJIT | 初始化单次 | 连续二进制共享内存块，环境无 FFI 时自动回退至平坦表 |

## 2. 外部生态与 IPC 通信

项目废除了原 `AI-PIT-PRO` 中易引起文件争用或脚本锁死的高频磁盘 TXT/JSON 交换，全面升级为：
1. **进程内统一数据契约 (`RaceContext.lua`)**：微观车手与宏观策略零时延、零序列化开销共享。
2. **外部应用桥接 (`TelemetryBridge.lua`)**：通过 LuaJIT C 结构体内存映射输出实时遥测。外部副驾驶、比赛工程师或遥测看板可在单帧内零 GC 读取全场战术状态。
