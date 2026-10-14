# 模块职责与接口说明 (docs/MODULES.md)

## 1. 核心基础设施层 (`lib/core/`)

### `RaceContext.lua`
- **职责**：全场比赛与最高 24 辆车单一真相数据仓库。维护圈数、旗语、安全车状态、微观车辆状态及全局拓扑关系。
- **安全契约**：内置 `safeSimGet`、`getSimSessionTime`、`safeGetCar` 与 `safeGetDriverName` 包装，对 CSP FFI C 结构体及底层 API 实施严格的成员安全防护与越界防穿透；赛局总圈数自动绑定底层 `sim.raceLaps` 或 `ac.getSession().laps`。
- **公共接口**：
  - `M.safeSimGet(sim, field)`: LuaJIT FFI C 结构体安全访问器（`pcall` 容错包装），避免 `'struct state_sim' has no member` 崩溃。
  - `M.getSimSessionTime(sim)`: 官方标准会话秒数解析（优先级：`gameTime` -> `currentSessionTime / 1000` -> `time / 1000` -> `os.clock`）。
  - `M.getRaceState()`: 获取全局旗语、总圈数、当前圈、安全车状态。
  - `M.setTotalLaps(laps)`: 动态覆写总圈数并联动策略工坊。
  - `M.getCarState(carIndex)`: 获取指定赛车的动力学、轮胎、燃油与无线电指令快照。
  - `M.getAllCarStates()`: 获取全场赛车状态平坦数组。
  - `M.updateFromSim(sim)`: 增量更新时局与赛车连接状态（纯标量，零分配）。
  - `M.updateCarFromAc(carIndex, acCar)`: 从 CSP 车辆对象更新动力学状态与真实车手名称，并处理进出站状态机闭环。
  - `M.updateTopology(carCount, acGetCar)`: 计算全场 AI-to-AI / AI-to-Player 24 车拓扑邻居环。
  - `M.getNeighbors(carIndex)`: O(1) 获取当前车辆最近前车、后车索引与米制间距。

### `EventHub.lua`
- **职责**：双轨实时事件与指令回显总线。
  - **Track 1**：用户/系统下发指令的回执与状态确认（PENDING / SUCCESS / MERGED / SETTLED / FAILED）。
  - **Track 2**：AI 车手拟人化动作、攻防技能、微失误、蓝旗避让、爆胎/过热、进站作业以及全场旗语/赛程世界事件。
- **公共接口**：
  - `M.init()`: 重置事件池并添加系统就绪信标。
  - `M.isCarPitPending(carIdx)`: 检查车辆是否有未完成的挂起进站指令。
  - `M.registerPitCommand(carIdx)`: 登记该车的一条进站指令。
  - `M.settleCarPitCommands(carIdx, dLabel)`: 批量结算该车所有待处理进站指令并向 Track 1 推送确认回执。
  - `M.pushCommandEvent(tag, msg, status, sessionSec)`: 记录并回显操作指令。
  - `M.pushAiEvent(carIdx, tag, msg, category, sessionSec)`: 广播 AI 拟人化决策与突发赛况。
  - `M.emitTacticalStateChange(carIdx, dName, state, prevState, skill, time)`: 快捷广播战术姿态变更（含蓝旗 `YIELD`、进站 `BOXING` 等）。
  - `M.emitMistake(carIdx, dName, mistakeType, time)`: 快捷广播微失误事件。
  - `M.formatDriverLabel(carIdx, name)`: 统一格式化车手标识（`[#02] 车手名`）。
  - `M.getRecentCommands(limit)`: 提取最近指令回执列表。
  - `M.getRecentAiEvents(limit)`: 提取最近赛事广播列表。
  - `M.clearAll()`: 清空当前事件流。

### `Config.lua`
- **职责**：配置加载、范围校验与默认值回退保护。
- **公共接口**：
  - `M.init(path)`: 解析配置文件（默认 `config/settings.json`）。
  - `M.get(section, key, defaultVal)`: 安全查询配置项。
  - `M.set(section, key, val)`: 动态修改配置项。

### `Logger.lua`
- **职责**：有界循环日志（Ring Buffer，上限 100 条）与高频自适应节流输出。
- **公共接口**：
  - `M.info(tag, msg, throttleSec)` / `M.warn(...)` / `M.error(...)`
  - `M.getRecentLogs()`: 供 UI 日志面板展示。

---

## 2. 宏观车队策略层 (`lib/strategy/`)

### `StrategyCoordinator.lua`
- **职责**：统筹燃油模型、进站决策、换胎时机、车队无线电指令及物理注入。
- **公共接口**：
  - `M.init()`: 初始化全场车辆的 Stint 容器与策略权威状态机。
  - `M.rebuildFieldStrategy(totalLaps, defaultStops, baseFpl)`: 重构全场发车策略与进站窗口。
  - `M.issueRadioOrder(carIndex, command)`: 下达车队指令（"PUSH" / "SAVE" / "BOX_THIS_LAP" / "NONE"），带幂等与合流保护。
  - `M.stepStrategy(dt)`: 1Hz 动态研判、进站状态清算与燃油安全注入。
  - `M.getCarPlan(carIndex)`: 获取该车的当前进站窗口规划与建议。

### `pit_strategy.lua`
- **职责**：实时评分 `PIT_NOW` (Undercut) vs `PIT_PLUS_1` vs `PIT_PLUS_2` (Overcut)。

### `fuel_model.lua`
- **职责**：基于赛车质量、跟车气流、比赛节奏与黄旗状态实时解算 `estimatedFuelPerLap`。

### `tyre_model.lua`
- **职责**：非线性轮胎磨损曲线、冷胎出站升温窗口（~20s 抓地力爬坡）与过热衰竭解算。

### `traffic_model.lua`
- **职责**：出站虚拟落点投影、交通密度惩罚与进站时间窗口修正。

### `safety_car.lua`
- **职责**：全场黄旗/安全车异常减速智能识别。

---

## 3. 微观车手决策与执行层 (`lib/driver/`)

### `persona_loader.lua`
- **职责**：现役 22 位 F1 车手预设人格库（`config/personas.json`）、10 款内置核心模版后备库（`_defaultPresets`）与 7D 连续 DNA 基因图谱展开。
- **公共接口**：
  - `M.init(path)`: 支持多路径自适应解析车手数据库（支持短路径、`apps/lua/...` 及 CSP 根目录探测）。
  - `M.getPersonaForCar(carIndex, driverName)`: 匹配或程序化生成 7D 基因（带内置模版保底，绝不返空）。
  - `M.setManualOverride(carIndex, personaKey)`: 无条件持久化手动覆写指定车手驾驶风格。
  - `M.getManualOverride(carIndex)`: 获取指定车手当前手动覆写的模版 Key。
  - `M.getActivePersonaKey(carIndex, driverName)`: 查询车手当前生效的性格 Key（供 UI 选项精准高亮与状态同步）。
  - `M.getAllPersonas()`: 获取当前全量可用的人格字典。

### `TacticalTicker.lua`
- **职责**：10Hz 战术调度、生理感知延迟环（200ms）、攻防博弈与无线电指令消费。
- **输入**：`car, aheadCar, behindCar, persona, rivalryGrievance, raceCtx, dt`。
- **输出**：`aiState`（包含 `targetSplineOffset, targetCaution, targetAggression, isLiftAndCoast, isBreakingTow, stress, momentum`）。

### `BehaviorActuator.lua`
- **职责**：横向样条线平滑速率自适应控制、并排一车宽保护、大灯施压、微纠正抖舵拟真与冷胎抓地力调整。

### `watchdog.lua`
- **职责**：60Hz 瞬态物理看门狗、物理 J-Turn 掉头脱困、冷胎起步防打滑油门渐进爬坡、内置 `safeGetCar` 严格越界保护。

### `LODScheduler.lua`
- **职责**：三级空间动态调度（聚焦 T1: 10Hz / 中距 T2: 3.33Hz / 远端 T3: 0Hz 深度休眠）。

### `MistakeEngine.lua`
- **职责**：拟人化微失误谱系（入弯迟疑、循迹推头、起步打滑、轮胎抱死、胎温过热挣扎）。

---

## 4. X-Skill 拟人化技能体系 (`lib/skills/`)

### `SkillRegistry.lua`
- **职责**：全场技能契约合法性校验、O(1) 快速检索与外置 manifest 自动注册。
- **公共接口**：
  - `M.init()`: 加载内置技能与 `config/skills_manifest.txt` 清单中的扩展技能。
  - `M.registerSkill(skillDef)`: 动态接入新技能（校验 `id`, `name`, `category`, `checkPrerequisites`, `evaluateUtility`, `stepExecution`, `checkAbort`）。
  - `M.getSkillById(id)` / `M.getAllSkills()`: 零分配查询技能。

### `SkillArbitrator.lua`
- **职责**：二阶段门控仲裁调度器，管理 24 车技能上下文、承诺锁（0.6s）与冷却期。
- **公共接口**：
  - `M.init()` / `M.reset()`: 重置 24 车上下文状态。
  - `M.stepCarSkill(...)`: 驱动技能前置过滤、效用评分与分阶段执行。
  - `M.getContext(carIndex)`: 获取该车当前激活技能名、阶段与指标。

### 内置战术技能库 (`lib/skills/*.lua`)
- **`SwitchbackSkill.lua` (ID: 1, Category: OFFENSE)**：晚 Apex 交叉线下切反击。
- **`FeintDummySkill.lua` (ID: 2, Category: OFFENSE)**：两段式声东击西假动作（外侧佯攻诱骗，瞬间内线切入）。
- **`GentleSqueezeSkill.lua` (ID: 3, Category: DEFENSE)**：渐进式侧向挤压（逼迫攻方至脏走线，保留一车宽走廊）。
- **`TowWeaveSkill.lua` (ID: 4, Category: DEFENSE)**：大直道尾流破坏摇摆防守（附加真实刹车/轮胎热负荷）。
- **`LateBrakeDiveSkill.lua` (ID: 5, Category: OFFENSE)**：内线晚刹深潜超车（极限挑战抓地力与减速边界）。

---

## 5. 用户交互与面板层 (`lib/ui/`)

### `DashboardUI.lua`
- **职责**：ImGui 统一控制面板渲染，包含 5 大功能标签页以及底部常驻双轨实时信息广播台。
- **特性**：
  - 动态 AI 探测（带安全探测上限与越界兜底，杜绝 `no ai cars detected` 假离线）。
  - 车手姓名自适应截断（`getDriverNameDisplay`），支持 Tooltip 全称悬浮预览，避免长名字排版错位。
  - 车手轮换按钮（`< 上一车手` / `下一车手 >`）具备活动 AI 列表寻址与离线槽位回退，绝不卡死。
  - 按钮操作与状态同步附带鼠标 Hover 说明。
- **公共接口**：
  - `M.renderMain(perfMs, activeAiCount)`: 主控制台窗口入口。
  - `M.renderSetup()`: 策略工坊窗口入口（圈数加减、停站轮次预设）。
  - `M.renderGridSetupTab()`: 车手性格与基因图谱管理入口。
