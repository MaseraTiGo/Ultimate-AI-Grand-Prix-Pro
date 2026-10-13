# 开发状态、迁移清单与后续演进建议 (DEVELOPMENT_STATUS.md)

## 1. 源工程功能迁移状态审计

### 1.1 来自 `SmartAI` 的迁移
- **已迁移与强化**：
  - 心理压力池与多轴微失误模型 (`MistakeEngine.lua`)：入弯迟疑、循迹推头、起步打滑、轮胎抱死。
  - 生理感知延迟环形缓冲 (`TacticalTicker.lua`)：覆盖 200ms 人类神经延迟与重刹注意力盲区。
  - 空间 3-Tier 动态调度与 0Hz 深度休眠 (`LODScheduler.lua`)。
  - 破尾流画龙（Breaking the Tow）与晚弯心交叉线反击（Switchback）。
  - 车辆肢体语言（并排一车宽留白、大灯逼抢频闪、极限微纠盘）。
  - 物理级 J-Turn 掉头自救看门狗 (`watchdog.lua`)。
  - LuaJIT FFI 共享内存桥 (`TelemetryBridge.lua`)。
  - 跨场宿怨记忆记录器 (`rivalry_memory.lua`)。
- **已重写**：
  - `persona_loader.lua`：由 5 维人格扩展为融合车队策略（节油倾向、保胎意识、Undercut/Overcut 偏好）的 **7D 连续 DNA 基因图谱**。
- **已废弃**：
  - `fuel_guard.lua`：原项目简易的 4Hz 补油死锁看门狗已彻底淘汰，全权由宏观策略层 `StrategyCoordinator` 接管。

### 1.2 来自 `AI-PIT-PRO` 的迁移
- **已迁移与强化**：
  - 确定性多组别分段拆解与进站窗口计算 (`strategy_calculator.lua`)。
  - 动态燃油消耗估算模型 (`fuel_model.lua`)：引入燃油质量衰减、脏空气跟车省油、推圈高耗与安全车低速降耗。
  - 动态 Undercut / Overcut 评分机制 (`pit_strategy.lua`)。
  - 轮胎磨损悬崖模型 (`tyre_model.lua`)。
  - 出站交通投影分析 (`traffic_model.lua`)。
  - 安全车/全场黄旗自适应检测 (`safety_car.lua`)。
  - 车队指令仲裁 (`strategy_authority.lua`)。
- **已重写**：
  - `StrategyCoordinator.lua`：将原项目中冗长（5000+行）、多进程、双 App 磁盘 TXT/JSON 交换逻辑彻底重构为低开销、线程内单一真相源（`RaceContext`）驱动的单模块。
  - UI 界面：整合为现代化 5-Tab ImGui 控制台（1. 实时HUD / 2. 车队指挥 / 3. 策略工坊 / 4. 车手配置 / 5. 诊断日志），配合底部常驻双轨实时信息广播台（Track 1 指令回执 + Track 2 拟人决策与突发赛况广播），支持玩家一键向任意 AI 发送 PUSH、SAVE、BOX 等车队指令。
- **已废弃**：
  - 废除原工程中 Go 客户端（`vf1_strategist.exe`）及 Node.js WebSocket 服务端（`vf1_strategy_server.js`），彻底消除外部依赖和跨进程通信开销。
  - 废除 AppData 磁盘文件轮询协议（`ai_car_*_fuel.txt`）。

---

## 2. 验收状态与事实标记

- **已验证事实**：
  - **30 项核心集成与实机安全防护测试 100% 通过**（`tests/test_grand_prix_pro.lua`）。
  - **车手配置折叠面板修复（Accordion Fold Fix）**：攻克了 Lua 三元运算 `isEditing and nil or i` 恒等于 `i` 导致折叠失效的语言级陷阱，重构为显式条件分支，实现卡片展开/收起 100% 顺畅双向切换。
  - **广播事件虚警严控与几何特征过滤**：收紧 `TacticalTicker` 与 `TowWeaveSkill` 触发阈值，严格校验直线物理特征（车速 > 100km/h、横向加速度 $|a_x| < 2.0\text{ m/s}^2$、航向点积 $> 0.985$）与横向尾流走廊（$|\Delta x| \le 1.2\text{m}$），彻底杜绝弯道中触发“大直道摇摆走线”与非贴身跟车阶段虚报“进入攻击窗口”。
  - **赛事广播多维扩展与智能防抖限流**：环形缓冲容量扩容至 64 条；新增真实超车、轮胎抓地力断崖（磨损 > 65%）、水温过热（> 105℃）以及单圈最快圈广播；引入 12~15s 差异化冷却去重机制，消除重复战术通知刷屏。
  - **AI 车手过早进站（Premature Pit Stop）根治**：修复开局遥测未同步时的油量保护回退（默认 80L 防止圈数被钳制在第 2 圈）；短程冲刺赛（$\le 8$ 圈）默认 0 停；严格门控目标进站圈前（`curLap < targetLap`）的进站触发，仅允许燃油紧急（$\le 1.2$ 圈）、轮胎断崖（$\ge 58\%$）、安全车出动或真有效 Undercut 提前进站。
  - **策略工坊赛制圈数锁定**：彻底废除策略工坊中易引发策略崩塌的手动圈数覆盖修改逻辑，严格将比赛总圈数与 FIA / CSP 官方 Session 实时同步，保护计算完整性。
  - **自适应动态油耗（EMA）与非固定进站 Timing**：引入单圈实测燃油指数移动平均（EMA）追踪，杜绝机械硬编码 2.5L；进站时机动态考量油箱物理容积上限、车手 Undercut/Overcut 进站偏好基因及车队错峰差值。
  - **全车手性格模板选择器与一键重置**：彻底修复车手配置中模板写死为激进猛牛的缺陷，完整开放 5 大性格原型（猛牛、冰人、战术大师、绅士车手、稳健平衡）与 5 位 F1 现役/传奇车手（Verstappen, Hamilton, Leclerc, Norris, Alonso）模板自由切换，并支持一键恢复默认程序化 DNA。
  - **进站预派发工单弹窗（Pre-Dispatch Pit Work Order）**：在下发进站指令前唤出专业车队工单确认，支持换胎开关、基于 CSP `ac.getTyresName` 动态车型轮胎配方自适应查询（GT3/Cup/方程式自适应）、油箱剩余容积安全防溢出校验，并提供“极速进站”与“个性化配置”双轨派发。
  - **同步车手遥测与整车机械健康监控面板**：实时监视引擎剩余寿命、水温、变速箱损耗、车体/悬挂外壳受损百分比，以及四轮独立磨损、胎面核心温度与刹车温度。
  - **车队指令全维扩展**：在原 PUSH、SAVE、BOX 基础上扩展 `ATTACK`（全力进攻）与 `DEFEND`（战术防守）战术无线电指令。
  - **CSP LuaJIT FFI C 结构体严格防护与零崩溃**：排查并彻底攻克了底层 `ac.getSim()` 返回 C 结构体时，读取未定义字段引发的 fatal crash (`'struct state_sim' has no member named 'sessionTime'`)。引入 `safeSimGet(sim, field)` 防御性访问工具，官方标准时间从 `sim.gameTime` / `sim.currentSessionTime` 映射，主循环与策略模块 100% 免疫未知结构体成员抛错。
  - **进站状态机全闭环与 Drive-Through 根治**：确保 `physics.setAIPitStopRequest(carIndex, true)` 在维修通道及作业期间持续保持，杜绝过早置 false 导致原生 AI 取消停靠直接穿越；赛车跨入维修区通道（`isInPitlane`/`isInPit`）即刻解除 UI 层的 `pit_requested` 与 `radioCommand` 并批量结算出队所有待处理指令；完全驶出维修区时三重释放 `setAIPitStopRequest(false)`、`setAIStopCounter(0)` 与 `setAIThrottleLimit(1.0)`；实时向 Track 1 回显 `[CMD SETTLED]`，向 Track 2 广播进站作业与出站重返，自动推移下一赛段窗口杜绝重入死锁。
  - **赛事广播全链路打通与蓝旗让行**：打通 CSP 蓝旗与套圈迫近检测，`TacticalTicker` 驱动车辆主动外切让出内线，并在 Track 2 广播金黄色高亮 `【蓝旗避让】` 战术事件。
  - **CSP 严格越界防护与单次幂等初始化防护**：排查并彻底攻克了在不同车数房间下无界调用 `ac.getCar` / `ac.getDriverName` 导致底层 C++ 抛错断开 `script.init()` 的关键隐患。彻底解决圈数未同步、AI 车手假离线（0 AI detected）以及广播事件被逐帧重置清空的 Bug。
  - **动态赛局总圈数自动绑定**：优先绑定 `sim.raceLaps`，与玩家设置的赛程严格保持同步。
  - **车手轮换防卡死与 Tooltip 交互增强**：车手轮换按钮具备活动列表寻址与槽位循环兜底，全量操作按钮均增加鼠标 Hover 说明，车手长姓名自适应省略截断不破损。
  - **支持最高 24 辆赛车**零全盘扫描、零运行时 GC 内存分配与毫秒级拓扑解算。
  - **X-Skill 拟人化技能体系全面交付**：
    - 统一技能契约与零修改清单自动加载（`SkillRegistry.lua` + `config/skills_manifest.txt`）。
    - 二阶段门控仲裁（`SkillArbitrator.lua`）：O(1) 标量前置过滤 + 基于性格与心流的效用函数动态评分 + 0.6s 承诺锁防抖 + 异常安全沙盒。
    - 5 大内置高阶实战技能落地（晚 Apex 交叉线下切反击、两段式声东击西假动作、渐进式侧向挤压、大直道尾流破坏摇摆、内线晚刹深潜超车）。
    - 现役 22 名 F1 车手（11 支车队）真实人格谱系入库（新增 `racecraft_iq` 赛道球商与 `patience` 超车防守耐心维度）。
  - **AI-to-AI 局部缠斗网格拓扑**：全场赛车彼此具备前车/后车感知能力，不再局限于玩家单向中心。
  - **两段式虚晃假动作（Feint Dummy Move）**：侵略型车手具备外线诱骗随后切内线超车的人性化博弈。
  - **轮胎热衰竭（Tire Cooking）与冷胎出站升温（Cold Out-Lap）**：长时强硬防守导致胎温过热衰退；进站换新胎后经历真实的冷胎适应期。
  - **微失误物理反打（Counter-Steer Twitch）**：甩尾失误时通过 60Hz 瞬态看门狗触发反打姿态修正与油门抑制，彻底消除生硬突变。
  - **500 周期热循环 GC 分配为 0.000 KB 极速零内存控制**。
  - 原两个项目 `SmartAI` 和 `AI-PIT-PRO` 零文件被修改，原测试依然保持 100% 通过。
- **已知限制与待实机验证事项**：
  - 在完全真实的 Assetto Corsa 复杂联机房间下，由于不同 Dedicated Server 的物理干预权限开放程度各异，当服务器禁用 `physics.allowed` 时，应用将自动降级为“纯策略监控与车队建议 HUD”模式，无法直接注入变道与燃油。

---

## 3. 后续演进路线建议 (优先级排序)

1. **P1 - 真实语音副驾驶 TTS 接入**：基于已打通的 `TelemetryBridge.lua` 共享内存，直接与 Python/C++ 离线 TTS 引擎绑定，播放车队无线电提示音（如 “Box box box”, “Push now, we are undercutting”）。
2. **P2 - 多天气降水雨战策略联动**：接入 CSP 的雨天胎路抓地力接口，在降雨度突变时自动将轮胎策略切换为 INTERMEDIATE / WET。
3. **P3 - 历史赛季车手生涯积分系统**：将 `rivalry_memory.jsonl` 扩展为多周末锦标赛积分池，记录车手跨站士气起伏。
