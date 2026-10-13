# 游戏与 CSP 接口集成说明 (docs/INTEGRATION.md)

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

---

## 2. CSP 关键运行时越界异常与生命周期规范

### 2.1 API 严格越界防护（Zero Out-of-Bounds Probing）
- **CSP 异常机制**：
  在 CSP Lua 运行时中，调用 `ac.getCar(idx)` 或 `ac.getDriverName(idx)` 时，若 `idx >= sim.carsCount`，底层 C++ 将直接触发硬性 Lua 异常：`out of range: idx`，导致当前脚本调用栈崩断。
- **强制工程设计规范**：
  1. 严禁无上限或盲目探测（如 `for i = 0, 23 do ac.getCar(i)`）。
  2. 探测上限必须严格锚定于 `local carsCount = (sim and sim.carsCount) or (ac.getSim and ac.getSim().carsCount) or 0`。
  3. 全量调用必须封装为安全保护函数：
     ```lua
     local function safeGetCar(idx)
       if not ac or not ac.getCar or not idx or idx < 0 then return nil end
       local ok, res = pcall(ac.getCar, idx)
       return (ok and res) or nil
     end
     ```
  4. 遍历时若遇到第一个 `nil`，应当机立断中断探测，避免对空白槽位盲探。

### 2.2 初始化单次幂等性保障（Idempotent Lifecycle）
- **现象反思**：若第一帧因任何底层未知异常崩断，UI 渲染函数 `windowMain` 会在每一帧被 CSP 调用时重复尝试初始化，引发每秒 120 次的重置循环与日志雪崩。
- **看门狗防御契约**：
  在入口 `ensureInitialized()` 中引入 `_initAttempted` 门闩：
  ```lua
  local _initialized = false
  local _initAttempted = false

  local function ensureInitialized()
    if _initialized then return true end
    if _initAttempted then return false end
    _initAttempted = true

    if script.init then
      local ok, err = pcall(script.init)
      if not ok then
        _initialized = true -- 阻止逐帧死循环重试
        Logger.error("LIFECYCLE", "Initialization error: " .. tostring(err))
        return false
      end
    end
    return _initialized
  end
  ```

### 2.3 动态赛局总圈数解析
- Assetto Corsa 会话参数中，总圈数由 `sim.raceLaps`（正赛设定圈数）提供。在计时排位或自由练习中，该值为 0 或 nil。
- 系统采用多源自适应解析：
  ```lua
  local laps = (sim.raceLaps and sim.raceLaps > 0 and sim.raceLaps)
    or (sim.sessionLaps and sim.sessionLaps > 0 and sim.sessionLaps)
    or (sim.totalLaps and sim.totalLaps > 0 and sim.totalLaps)
    or (sim.laps and sim.laps > 0 and sim.laps)
    or 13
  ```
  有效圈数变更时即刻通知 `StrategyCoordinator.rebuildFieldStrategy(laps)` 重新解算进站窗口。

---

## 3. 外部生态与 IPC 通信

项目废除了原 `AI-PIT-PRO` 中易引起文件争用或脚本锁死的高频磁盘 TXT/JSON 交换，全面升级为：
1. **进程内统一数据契约 (`lib/core/RaceContext.lua`)**：微观车手与宏观策略零时延、零序列化开销共享。
2. **外部应用桥接 (`lib/bridge/TelemetryBridge.lua`)**：通过 LuaJIT C 结构体内存映射输出实时遥测。外部副驾驶、比赛工程师或遥测看板可在单帧内零 GC 读取全场战术状态。
