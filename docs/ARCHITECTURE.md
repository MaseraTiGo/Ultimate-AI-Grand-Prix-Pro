# 系统分层与架构设计说明 (docs/ARCHITECTURE.md)

## 1. 整体架构全景 (Master-Slave / Thin-Client 解耦架构)

`Ultimate AI Grand Prix Pro` 采用彻底解耦的**主从式星型中继架构（Master-Slave / Thin-Client Hub-and-Spoke Architecture）**：
- **CSP Lua 瘦客户端（Dumb Actuator & Broadcaster）**：彻底剔除宏观策略计算、AI 性格配置与繁杂 ImGui 界面，仅承担 60Hz 物理看门狗、10Hz 微观车手反射、10Hz~20Hz 紧凑遥测/事件广播，以及硬件级 API 控制指令执行；
- **Python 独立策略中枢（`StrategyManager`）**：以双可执行程序体系（FIA Admin 与 Team Principal Pit Wall）统管真实规程解析、沙盒破坏者覆写、非线性轮胎/燃油数学模型、服务端“战争迷雾”脱敏广播与 ACL 权限拦截。

```text
┌────────────────────────────────────────────────────────────────────────────────────────┐
│               Ultimate AI Grand Prix Pro 统一主从架构 (CSP Lua + Python Suite)         │
│                                                                                        │
│  [A. 外部策略指挥中枢 (Python StrategyManager)] (PySide6 工业暗黑主题 #0F1115)          │
│     ├─ 1. admin_main.py (FIA Race Control / God Mode 主控台)                           │
│     │    ├─ 直连 Lua UDP:30888/30889 独占链路，控制广播开关与全场 AI 指令              │
│     │    ├─ 开放 TCP:30890 Hub 服务端，管理全场车手名册与 Parc Fermé 锁定状态机       │
│     │    ├─ 规则解析与 Copy-on-Write 沙盒破坏者预设引擎 (f1_2026, f1_2004, gt3)       │
│     │    └─ 服务端“战争迷雾 (Fog of War)”脱敏广播与指令 ACL 鉴权拦截器                 │
│     │                                                                                  │
│     └─ 2. user_main.py (Team Principal Pit Wall 车队墙客户端)                          │
│          ├─ 连入 Admin TCP:30890 (杜绝直连 Lua UDP 端口)，遵循网络星型拓扑            │
│          ├─ 赛前车手选秀大厅 (Driver Draft Lobby: LOBBY_OPEN 自由绑定 / 锁定禁改)      │
│          ├─ 公开 FIA 计时塔与动态 2D 赛道地图 (对手赛车深层数据自动掩码为 ---/---)    │
│          └─ 己方车队全量深度遥测、Stint 甘特图、Undercut 雷达与一键车队无线电指令      │
│                                                                                        │
│                    ▲ UDP : 30888 (Telemetry) / : 30889 (Commands)                     │
│                    ▼                                                                   │
│                                                                                        │
│  [B. Assetto Corsa CSP Lua 瘦客户端] (Ultimate-AI-Grand-Prix-Pro.lua)                  │
│     ├─ 1. 硬件级执行器与广播器 (dumb_actuator_broadcaster.lua)                         │
│     │    ├─ 非阻塞 UDP 套接字循环 (10Hz~20Hz 紧凑位掩码 JSON 遥测流)                  │
│     │    ├─ 边沿触发离散事件检测 (超车、进出站、碰撞摩擦、单圈结算)                   │
│     │    ├─ 硬件指令安全执行 (BOX, CANCEL_BOX, RADIO, PERSONA, BROADCAST_TOGGLE)       │
│     │    └─ 极简 ImGui 面板: 链路状态、广播主开关 (Broadcast Master Toggle)、日志开关 │
│     │                                                                                  │
│     ├─ 2. 微观车手决策与执行层 (AI Driver & Reflex Layer) ── 10Hz/60Hz                 │
│     │    ├─ persona_loader.lua: 7D 连续 DNA 基因图谱 (攻防/抗压/保胎/停站倾向)        │
│     │    ├─ TacticalTicker.lua: 生理延迟感知 (200ms)、心态心流 (Flow/Tilt)、肢体语言   │
│     │    ├─ X-Skill 拟人化技能体系: 交叉线下切、假动作佯攻、尾流破坏、内线晚刹        │
│     │    ├─ LODScheduler.lua: 三级空间调度 (聚焦 10Hz / 中距 3.33Hz / 远端 0Hz)      │
│     │    ├─ MistakeEngine.lua: 拟人化微失误谱系 (入弯迟疑/循迹推头/起步打滑/抱死)      │
│     │    ├─ BehaviorActuator.lua: 物理平滑限幅、一车宽防挤压走廊与大灯/鸣笛动态脉冲   │
│     │    └─ watchdog.lua @ 60Hz: 瞬态物理看门狗、J-Turn 掉头自救与零内存物理沙盒       │
│     │                                                                                  │
│     └─ 3. 核心状态基石 (RaceContext.lua / EventHub.lua / Config.lua / Logger.lua)      │
│          └─ CSP FFI 结构体安全防护、单次幂等初始化门闩与微扇区计时管理                 │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 关键数据流与事件流

1. **比赛时局动态采样**：每帧调用 `RaceContext.updateFromSim(sim)`，通过严格校验的 `safeGetCar` 与 `safeGetDriverName` 规避 CSP 越界崩溃；自动捕获全局赛局圈数（优先绑定 `sim.raceLaps`）、比赛阶段、全场黄旗与安全车。
2. **策略异步解算 (1Hz)**：`StrategyCoordinator.stepStrategy(dt)` 计算进站窗口与 Undercut 收益，若判定进站时机成熟或满足车队要求，将 `radioCommand` 标记为 `BOX_THIS_LAP`，并同步推送事件至 `EventHub`。
3. **车手战术响应与拟人化肢体语言 (10Hz)**：`TacticalTicker.stepCar(...)` 从 `RaceContext` 消费 `radioCommand`，更新生理感知环形缓冲区与压力/士气：
   - 收到 `PUSH`：caution 降低 60%，aggression 提升 25%，士气提升进入 Flow；
   - 收到 `SAVE`：触发 `isLiftAndCoast = true`，直道末端提前 50m 滑行断油；
   - 收到 `BOX_THIS_LAP`：贴向维修区外侧走线，准备安全进站；
   - **拟人化肢体语言调度（Body Language Orchestration）**：
     - 超车进攻 / 贴身逼抢（`HUNTING`）：车距 $< 18\text{m}$，触发 **6 次机枪式极速高频暴闪（0.07s 脉冲）**，极限施压前车后视镜；
     - 蓝旗提示让路（`BLUE_FLAG`）：车距 $7 \sim 35\text{m}$，触发 **2 次礼貌双闪（0.16s 从容节奏）**，坚定但礼貌示意借道；
     - 恶意阻挡抗议（`PROTEST`）：前车危险蛇形画龙阻挡时，触发 **5 次急促双闪 + 0.45s 鸣笛示警**；
     - 超越示威/致意（`TAUNT` / `THANKS`）：绝杀超越后触发 1 次尾随闪灯。
4. **X-Skill 战术技能仲裁**：`SkillArbitrator.stepCarSkill(...)` 驱动二阶段门控：
   - **Phase 1 (硬性物理前置过滤)**：以标量几何（车距、闭合速度、相对方位、直道/弯道曲率）为 O(1) 准入条件，未满足者直接 early-exit；
   - **Phase 2 (效用函数综合评分)**：结合车手性格画像（激进、防守、球商、耐心）、心流状态（Flow/Tilt）与轮胎抓地力计算 utility 分数，竞争选出最高效用技能；
   - **承诺锁（Commitment Hold）与安全中止**：触发后维持至少 0.6s 决策稳定期防抖；若出现严重碰撞风险或弯道曲率危险，即刻触发 `checkAbort` 安全降级。
5. **底层物理执行与动态脉冲执行 (60Hz)**：`BehaviorActuator.lua` 负责平滑速率自适应限幅、一车宽防挤压走廊与大灯/鸣笛动态物理脉冲发射；`watchdog.stepPhysics(dt)` 负责瞬态微操控的安全沙盒熔断与逆向 J-Turn 物理自救。
6. **双轨事件分发、控制遥测与 UI 回显**：`EventHub.lua` 维护两路独立有界环形缓冲池（Track 1 玩家与系统下发指令的回执与合流/批量结算状态确认；Track 2 全场 AI 拟人化决策、蓝旗让行、肢体语言闪灯/鸣笛、攻防博弈、进出站作业广播）。`ControlTelemetry.lua` 则提供 2-4Hz 动态抽样的底层原生动作语义化转译，确保策略执行与物理姿态具备毫秒级可观测性。

---

## 3. CSP 底层运行时安全机制

1. **零盲探越界隔离**：
   Assetto Corsa CSP 环境中，调用 `ac.getCar(idx)` 或 `ac.getDriverName(idx)` 时，若 `idx >= sim.carsCount`，CSP 将抛出硬性 Lua 错误中断当前执行栈。
   系统设计了严格的防护契约：
   - 所有 car / driver 查询统一通过 `safeGetCar(idx)` / `safeGetDriverName(idx)`（内部封装 `pcall`）；
   - 所有循环上限严格限定为 `math.min(simCars, MAX_CARS)`。
2. **单次幂等初始化看门狗**：
   UI 帧循环驱动的 `windowMain` 中采用 `_initAttempted` 保护，杜绝第一帧因异常导致逐帧重复触发 `script.init()`，确保 `EventHub` 与策略中枢不被循环清空。
3. **CSP C-Struct (LuaJIT FFI) 严格字段防护**：
   底层 `ac.getSim()` 返回 C 结构体 `struct state_sim`。在 LuaJIT FFI 下直接访问结构体未定义的字段（如不存在的 `sim.sessionTime`、`sim.raceLaps`、`sim.currentLap`、`sim.isYellowFlag` 等）会抛出不可恢复的运行时 Crash。系统在 `RaceContext.safeSimGet` 中采用保护性查询，并通过官方 `gameTime`、`currentSessionTime` 及 `ac.getSession(idx).laps` 映射标准赛时与赛程，彻底杜绝 FFI 字段缺失崩溃。

---

## 4. X-Skill 零修改插件化扩展机制

当需要新增全新战术技能时：
1. 在 `lib/skills/` 或任意相对路径创建符合契约的技能模块（实现 `id`, `name`, `category`, `checkPrerequisites`, `evaluateUtility`, `stepExecution`, `checkAbort`）。
2. 在 `config/skills_manifest.txt` 中追加该脚本相对路径，或直接调用 `SkillRegistry.registerSkill(def)`。
3. 系统在初始化时自动完成契约合法性校验并接入仲裁调度，**无需修改任何现有核心框架代码**。
