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
- **职责**：横向样条线平滑速率自适应控制、并排一车宽保护、大灯施压、微纠正抖舵拟真。

### `watchdog.lua`
- **职责**：60Hz 瞬态物理看门狗、物理 J-Turn 掉头脱困、自裁决防死车。

### `LODScheduler.lua`
- **职责**：三级空间调度与 0Hz 深度休眠。

---

## 4. X-Skill 拟人化决策与技能体系 (`lib/skills/`)

### `SkillRegistry.lua`
- **职责**：全场技能契约合法性校验、O(1) 快速检索与无修改自动发现。
- **公共接口**：
  - `M.init()`: 加载内置技能与 `config/skills_manifest.txt` 清单中的外置技能。
  - `M.registerSkill(skillDef)`: 动态接入新技能（校验 `id`, `name`, `category`, `checkPrerequisites`, `evaluateUtility`, `stepExecution`, `checkAbort`）。
  - `M.getSkillById(id)` / `M.getAllSkills()`: 零 GC 内存直接查询。

### `SkillArbitrator.lua`
- **职责**：二阶段门控仲裁调度器，管理 24 车技能上下文、承诺锁（0.6s）与冷却期。
- **公共接口**：
  - `M.init()` / `M.reset()`: 重置 24 车上下文状态。
  - `M.stepCarSkill(car, aheadCar, behindCar, persona, rivalryScore, raceCtx, sState, dt)`: 驱动技能前置过滤、效用评分与分阶段执行。
  - `M.getContext(carIndex)`: 获取该车当前激活技能名、阶段与指标。

### 内置战术技能库 (`lib/skills/*.lua`)
- **`SwitchbackSkill.lua` (ID: 1, Category: OFFENSE)**：晚 Apex 交叉线下切反击。
- **`FeintDummySkill.lua` (ID: 2, Category: OFFENSE)**：两段式声东击西假动作（外侧佯攻诱骗，瞬间内线切入）。
- **`GentleSqueezeSkill.lua` (ID: 3, Category: DEFENSE)**：渐进式侧向挤压（逼迫攻方至脏走线，保留一车宽走廊）。
- **`TowWeaveSkill.lua` (ID: 4, Category: DEFENSE)**：大直道尾流破坏摇摆防守（附加真实刹车/轮胎热负荷）。
- **`LateBrakeDiveSkill.lua` (ID: 5, Category: OFFENSE)**：内线晚刹深潜超车（极限挑战抓地力与减速边界）。

