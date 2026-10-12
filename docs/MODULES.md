# 模块职责与接口说明 (MODULES.md)

## 1. 核心基础设施层 (`lib/core/`)

### `RaceContext.lua`
- **职责**：全场比赛与 64 辆车单一真相数据仓库。
- **公共接口**：
  - `M.getRaceState()`: 获取全局旗语、总圈数、当前圈、安全车状态。
  - `M.getCarState(carIndex)`: 获取指定赛车的全部动力学、轮胎、燃油与无线电指令。
  - `M.updateFromSim(sim)`: 增量更新。
  - `M.updateCarFromAc(carIndex, acCar)`: 从 CSP 车辆对象更新标量属性。

### `Config.lua`
- **职责**：配置加载与回退保护。
- **公共接口**：
  - `M.init(path)`: 解析配置文件。
  - `M.get(section, key, defaultVal)`: 安全查询配置。
  - `M.set(section, key, val)`: 动态修改配置。

### `Logger.lua`
- **职责**：有界循环日志（Ring Buffer，上限 100 条）与高频节流输出。
- **公共接口**：
  - `M.info(tag, msg, throttleSec)` / `M.warn(...)` / `M.error(...)`
  - `M.getRecentLogs()`: 供 UI 实时展示。

---

## 2. 宏观车队策略层 (`lib/strategy/`)

### `StrategyCoordinator.lua`
- **职责**：统筹燃油模型、进站决策、换胎时机、车队无线电指令及物理注入。
- **公共接口**：
  - `M.init()`: 初始化 64 辆车的 Stint 容器。
  - `M.rebuildFieldStrategy(totalLaps, defaultStops, baseFpl)`: 重构全场发车策略。
  - `M.issueRadioOrder(carIndex, command)`: 下达车队指令（"PUSH" / "SAVE" / "BOX_THIS_LAP" / "DEFEND" / "NONE"）。
  - `M.stepStrategy(dt)`: 1Hz 动态研判与加油接管。

### `pit_strategy.lua`
- **职责**：实时评分 `PIT_NOW` (Undercut) vs `PIT_PLUS_1` vs `PIT_PLUS_2` (Overcut)。

### `fuel_model.lua`
- **职责**：基于赛车质量、跟车气流、比赛节奏与黄旗状态实时解算 `estimatedFuelPerLap`。

---

## 3. 微观车手决策与执行层 (`lib/driver/`)

### `TacticalTicker.lua`
- **职责**：10Hz 战术调度、生理感知延迟环、攻防博弈与无线电指令消费。
- **输入**：`car, aheadCar, behindCar, persona, rivalryGrievance, raceCtx, dt`。
- **输出**：`aiState`（包含 `targetSplineOffset, targetCaution, targetAggression, isLiftAndCoast, isBreakingTow`）。

### `BehaviorActuator.lua`
- **职责**：横向样条线平滑速率自适应控制、并排一车宽保护、大灯施压。

### `watchdog.lua`
- **职责**：60Hz 瞬态物理看门狗、物理 J-Turn 掉头脱困、自裁决防死车。

### `LODScheduler.lua`
- **职责**：三级空间调度与 0Hz 深度休眠。
