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
  - UI 界面：整合为现代化 4-Tab ImGui 控制台（Live HUD / Pit Wall / Grid Setup / Logs），支持玩家一键向任意 AI 发送 PUSH、SAVE、BOX 等车队指令。
- **已废弃**：
  - 废除原工程中 Go 客户端（`vf1_strategist.exe`）及 Node.js WebSocket 服务端（`vf1_strategy_server.js`），彻底消除外部依赖和跨进程通信开销。
  - 废除 AppData 磁盘文件轮询协议（`ai_car_*_fuel.txt`）。

---

## 2. 验收状态与事实标记

- **已验证事实**：
  - 15 项核心集成测试 100% 通过（`tests/test_grand_prix_pro.lua`）。
  - 500 周期热循环 GC 分配为 0.000 KB。
  - 车队指令下达（PUSH / SAVE / BOX_THIS_LAP）能即时改变车手的目标 caution、aggression 及保胎滑行状态。
  - 原两个项目 `SmartAI` 和 `AI-PIT-PRO` 零文件被修改，原测试依然保持 100% 通过。
- **已知限制与待实机验证事项**：
  - 在完全真实的 Assetto Corsa 复杂联机房间下，由于不同 Dedicated Server 的物理干预权限开放程度各异，当服务器禁用 `physics.allowed` 时，应用将自动降级为“纯策略监控与车队建议 HUD”模式，无法直接注入变道与燃油。

---

## 3. 后续演进路线建议 (优先级排序)

1. **P1 - 真实语音副驾驶 TTS 接入**：基于已打通的 `TelemetryBridge.lua` 共享内存，直接与 Python/C++ 离线 TTS 引擎绑定，播放车队无线电提示音（如 “Box box box”, “Push now, we are undercutting”）。
2. **P2 - 多天气降水雨战策略联动**：接入 CSP 的雨天胎路抓地力接口，在降雨度突变时自动将轮胎策略切换为 INTERMEDIATE / WET。
3. **P3 - 历史赛季车手生涯积分系统**：将 `rivalry_memory.jsonl` 扩展为多周末锦标赛积分池，记录车手跨站士气起伏。
