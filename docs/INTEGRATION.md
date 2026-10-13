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
- Assetto Corsa 官方会话结构中，总圈数由 `ac.getSession(sim.currentSessionIndex).laps` 提供。
- 系统采用多源自适应安全解析（通过 `RaceContext.updateFromSim`）：
  ```lua
  local laps = nil
  if ac and ac.getSession then
    local sessIdx = safeSimGet(sim, "currentSessionIndex") or 0
    local ok, sess = pcall(ac.getSession, sessIdx)
    if ok and sess then
      local sLaps = safeSimGet(sess, "laps")
      if sLaps and sLaps > 0 then laps = sLaps end
    end
  end
  if not laps or laps <= 0 then
    laps = safeSimGet(sim, "raceLaps")
      or safeSimGet(sim, "sessionLaps")
      or safeSimGet(sim, "totalLaps")
      or safeSimGet(sim, "laps")
  end
  ```
  有效圈数变更时即刻通知 `StrategyCoordinator.rebuildFieldStrategy(laps)` 重新解算进站窗口。

### 2.4 CSP C-Struct (LuaJIT FFI) 严格字段访问规范
- **C-Struct 运行时机理**：底层 `ac.getSim()` 返回 C 结构体 `struct state_sim`。在 LuaJIT FFI 机制下，如果代码尝试读取结构体未定义的字段（如 `sim.sessionTime`、`sim.raceLaps`、`sim.currentLap`、`sim.isYellowFlag` 等），会触发致命的 LuaJIT FFI Crash：`'struct state_sim' has no member named '...'`，且该错误会导致主更新帧循环立即崩断。
- **防护规范与最佳实践**：
  1. **防御性读取工具**：在 `lib/core/RaceContext.lua` 中封装 `safeSimGet(sim, field)`：
     ```lua
     local function safeSimGet(sim, field)
       if not sim or not field then return nil end
       local ok, val = pcall(function() return sim[field] end)
       if ok then return val end
       return nil
     end
     ```
  2. **官方时间字段映射**：
     - `sim.gameTime`：自 AC 启动以来的运行秒数（官方标准浮点数）。
     - `sim.currentSessionTime`：当前 Session 同步时间（毫秒），换算为秒：`currentSessionTime / 1000.0`。
     - `sim.time`：AC 启动以来的毫秒数。
     - 统一由 `RaceContext.getSimSessionTime(sim)` 进行优先级解析并存入 `RaceContext.getRaceState().sessionTime`。
  3. **官方旗语与事件映射**：
     - `sim.raceFlagType` 枚举：`None = 0`, `Caution = 2` (全场黄旗), `FasterCar = 12` (蓝旗), `Finished = 13` (方格旗)。
     - `sim.raceFlagCause`：触发旗语的 0 索引车号（-1 表示无）。

### 2.5 进站状态机闭环与双轨回执链路 (Pit Lifecycle Closed Loop & Event Echo)
- **触发与复位时机**：
  - **进站请求期**：玩家或策略下达 `BOX_THIS_LAP`，车辆置位 `pit_requested = true`，战术进入 `BOXING` 状态并注入物理诱导。
  - **维修区接管期**：当车辆跨入维修区通道（`isInPitlane == true` 或 `isInPit == true` 时）：
    - 立即清除 `pit_requested = false`、`pit_stop_planned = false`、`radioCommand = "NONE"`。
    - 战术状态锁定为 `PIT_BAY`（停站作业）。
    - 自动推进下一赛段规划圈数（`plan.targetLap = curLap + stintLaps[2]`），杜绝出站瞬间被旧计划再次触发重入。
    - 批量消费结算该车所有 Pending 指令并向 Track 1 发送回执：`[CMD SETTLED] [#%02d] Driver 进站作业已接管/批量完成`。
    - 向 Track 2 广播：`【进站作业】[#%02d] Driver 已平稳驶入维修区，车组人员开始换胎与补油！`。
  - **出站重返期**：当车辆出维修区（`wasInAnyPit and not isNowInPit` 时）：
    - 战术状态复位为 `CRUISE`，刷新冷胎升温初始状态。
    - 向 Track 2 广播：`【出站重返】[#%02d] Driver 进站作业完成，重返赛道全力推进！`。

### 2.6 蓝旗让行与战术事件广播链路 (Blue Flag & Broadcast Pipeline)
- **让行条件触发**：
  - CSP 底层旗语：`sim.raceFlagType == 12` 且 `sim.raceFlagCause == carIdx`。
  - 局部相对圈数拓扑：后车快车/头车套圈迫近时（`pLap > cLap and behindDist < 25.0`）。
- **动作执行与广播**：
  - `TacticalTicker` 将状态迁移至 `YIELD`，`activeSkill = "YIELD"`，偏航外线避让（`targetSplineOffset = 0.75`）。
  - `EventHub.emitTacticalStateChange` 捕获 `YIELD` 边沿，向 Track 2 实时推送：`【蓝旗避让】[#%02d] Driver 被出示蓝旗，主动让出内线避让快车！`。

---

## 3. 外部生态与 IPC 通信

项目废除了原 `AI-PIT-PRO` 中易引起文件争用或脚本锁死的高频磁盘 TXT/JSON 交换，全面升级为：
1. **进程内统一数据契约 (`lib/core/RaceContext.lua`)**：微观车手与宏观策略零时延、零序列化开销共享。
2. **外部应用桥接 (`lib/bridge/TelemetryBridge.lua`)**：通过 LuaJIT C 结构体内存映射输出实时遥测。外部副驾驶、比赛工程师或遥测看板可在单帧内零 GC 读取全场战术状态。
