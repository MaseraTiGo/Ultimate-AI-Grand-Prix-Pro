# 系统分层与架构设计说明 (ARCHITECTURE.md)

## 1. 整体架构全景

`Ultimate AI Grand Prix Pro` 采用四层解耦的高性能异步驱动架构，彻底融合了微观车手神经反射与宏观车队策略决策：

```text
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                     Ultimate AI Grand Prix Pro 统一产品架构 (24 车高拟真)              │
│                                                                                        │
│  [1. 交互与指挥层 (UI & Head-Up Display)] (lib/ui/DashboardUI.lua)                     │
│     ├─ Tab 1 [LIVE HUD]: 全场 24 车微观状态矩阵 (压力、士气 Flow/Tilt、战术动作)        │
│     ├─ Tab 2 [PIT WALL]: 车队策略看板 (Stint 窗口、预估续航圈数、主动车队指令无线电)     │
│     ├─ Tab 3 [GRID SETUP]: 连续基因图谱/预设人格手动覆写面板                           │
│     └─ Tab 4 [LOGS]: 有界循环日志诊断流 (Bounded Ring Buffer)                          │
│                                                                                        │
│  [2. 核心状态与数据契约层 (Core & State Contract)]                                     │
│     ├─ RaceContext.lua: 全局唯一样条圈数、旗语、安全车与预分配 24 车全局拓扑网络        │
│     ├─ Config.lua: 统一参数配置、范围校验与默认值回退保护                             │
│     └─ Logger.lua: 结构化分级日志、高频节流保护与有界内存池                            │
│                                                                                        │
│  [3. 宏观车队策略层 (AI Race Strategy Layer)] ── 1.0Hz 异步周期调度                    │
│     ├─ StrategyCoordinator.lua: Stint 规划、进站窗口管理、3.0s换胎停顿与出站冷胎注入   │
│     ├─ strategy_calculator.lua: 确定性多组别停站拆解与错峰计算                         │
│     ├─ pit_strategy.lua: 实时 Undercut / Overcut 动态净收益评分                        │
│     ├─ fuel_model.lua: 动态燃油消耗模型 (质量效应、推圈模式、脏空气跟车、安全车降耗)   │
│     ├─ tyre_model.lua: 轮胎磨损非线性悬崖曲线与冷胎出站升温窗口解算                    │
│     ├─ traffic_model.lua: 出站虚拟落点投影与交通密度惩罚                               │
│     └─ safety_car.lua: 全场黄旗/安全车异常减速智能识别                                 │
│                                                                                        │
│  [4. 微观车手决策与执行层 (AI Driver & Reflex Layer)] ── 10Hz/60Hz 空间调度            │
│     ├─ persona_loader.lua: 7D 连续 DNA 基因图谱 (攻防/抗压/保胎/停站/球商/耐心倾向)    │
│     ├─ TacticalTicker.lua: 全局感官缓冲 (200ms延迟)、心态流动 (Flow/Tilt) 状态机       │
│     ├─ X-Skill 拟人化技能体系 (lib/skills/):                                            │
│     │   ├─ SkillRegistry.lua: 契约校验、快速检索与零修改 manifest 自动注册机制         │
│     │   ├─ SkillArbitrator.lua: 二阶段门控 (硬性前置 O(1) 过滤 -> 效用函数评分)        │
│     │   │                       防抖锁定 (0.6s) 与技能冷却，全预分配 24 车上下文       │
│     │   ├─ SwitchbackSkill.lua: 晚 Apex 交叉线下切反击 (三阶段状态机)                  │
│     │   ├─ FeintDummySkill.lua: 假动作声东击西诱骗 (外侧佯攻 -> 内线下切)              │
│     │   ├─ GentleSqueezeSkill.lua: 渐进式侧向挤压 (迫使对手进入脏线，保留一车宽)       │
│     │   ├─ TowWeaveSkill.lua: 尾流破坏防守摇摆 (阻断后车吸尾流，附加轮胎热量累积)      │
│     │   └─ LateBrakeDiveSkill.lua: 内线晚刹俯冲超车 (轮胎抓地力边界极限攻防)           │
│     ├─ LODScheduler.lua: 三级空间调度 (聚焦 10Hz / 中距 3.33Hz / 远端 0Hz 深度休眠)    │
│     ├─ MistakeEngine.lua: 拟人化微失误谱系 (入弯迟疑/循迹推头/起步打滑/抱死)           │
│     ├─ BehaviorActuator.lua: 物理反打与油门切断、一车宽并排走廊、大灯施压、冷热胎抓地   │
│     └─ watchdog.lua @ 60Hz: 瞬态物理看门狗、J-Turn 掉头自救与零内存物理沙盒            │
│                                                                                        │
│  [5. 外部生态开放层 (Zero-Overhead Bridge)] (lib/bridge/TelemetryBridge.lua)          │
│     └─ LuaJIT FFI 共享内存块，无 GC 损耗直接反哺外部 AI 领航员与策略分析器              │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 关键数据流与事件流

1. **比赛时局采样**：每帧调用 `RaceContext.updateFromSim(sim)`，捕获全局圈数、比赛阶段、全场黄旗与安全车。
2. **策略异步解算 (1Hz)**：`StrategyCoordinator.stepStrategy(dt)` 计算进站窗口与 Undercut 收益，若判定进站时机成熟或满足车队要求，将 `radioCommand` 标记为 `BOX_THIS_LAP`。
3. **车手战术响应 (10Hz)**：`TacticalTicker.stepCar(...)` 从 `RaceContext` 消费 `radioCommand`，更新生理感知环形缓冲区与压力/士气：
   - 收到 `PUSH`：caution 降低 60%，aggression 提升 25%，士气提升进入 Flow；
   - 收到 `SAVE`：触发 `isLiftAndCoast = true`，直道末端提前 50m 滑行断油；
   - 收到 `BOX_THIS_LAP`：贴向维修区外侧走线，准备安全进站。
4. **X-Skill 战术技能仲裁**：`SkillArbitrator.stepCarSkill(...)` 驱动二阶段门控：
   - **Phase 1 (硬性物理前置过滤)**：以标量几何（车距、闭合速度、相对方位、直道/弯道曲率）为 O(1) 准入条件，未满足者直接 early-exit；
   - **Phase 2 (效用函数综合评分)**：结合车手性格画像（激进、防守、球商、耐心）、心流状态（Flow/Tilt）与轮胎抓地力计算 utility 分数，竞争选出最高效用技能；
   - **承诺锁（Commitment Hold）与安全中止**：触发后维持至少 0.6s 决策稳定期防抖；若出现严重碰撞风险或弯道曲率危险，即刻触发 `checkAbort` 安全降级。
5. **底层物理执行 (60Hz)**：`watchdog.stepPhysics(dt)` 负责瞬态微操控的安全沙盒熔断与逆向 J-Turn 物理自救。

---

## 3. X-Skill 零修改插件化扩展机制

当需要新增全新战术技能时：
1. 在任意路径创建符合契约的技能模块（提供 `id`, `name`, `category`, `checkPrerequisites`, `evaluateUtility`, `stepExecution`, `checkAbort`）。
2. 在 `config/skills_manifest.txt` 中追加该文件路径，或者直接调用 `SkillRegistry.registerSkill(def)`。
3. 系统在初始化时自动完成契约合法性校验并接入仲裁调度，**无需修改任何现有核心框架代码**。
