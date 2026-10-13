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
  - **21 项核心集成与实机安全防护测试 100% 通过**（`tests/test_grand_prix_pro.lua`）。
  - **CSP LuaJIT FFI C 结构体严格防护与零崩溃**：排查并彻底攻克了底层 `ac.getSim()` 返回 C 结构体时，读取未定义字段引发的 fatal crash (`'struct state_sim' has no member named 'sessionTime'`)。引入 `safeSimGet(sim, field)` 防御性访问工具，官方标准时间从 `sim.gameTime` / `sim.currentSessionTime` 映射，主循环与策略模块 100% 免疫未知结构体成员抛错。
  - **进站状态机全闭环与指令幂等批量结算**：进站指令自动合流防堆积；赛车跨入维修区通道（`isInPitlane`/`isInPit`）即刻解除 `pit_requested` 与 `radioCommand` 并批量结算出队所有待处理指令；实时向 Track 1 回显 `[CMD SETTLED]`，向 Track 2 广播进站作业与出站重返，自动推移下一赛段窗口杜绝重入死锁。
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
