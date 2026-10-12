# Ultimate AI Grand Prix Pro - Agent 快速上手与总入口规范

> **项目定位**：Assetto Corsa (CSP Lua) 统一拟人化 AI 车手大脑与动态车队策略指挥平台（Unified Anthropomorphic Driver & Pit Wall Engine）。  
> **项目根目录**：`C:\Users\EDZ\Desktop\update-ac\app\Ultimate AI Grand Prix Pro\`  
> **测试运行器**：`& "D:\Program Files (x86)\Lua\5.1\lua.exe" tests/test_grand_prix_pro.lua`

---

## 1. 核心约束与工作准则

1. **零全盘扫描原则**：严禁无目的检索全量文件。进行任何任务前，请先查阅下方的【文档与模块索引导航】。
2. **零运行时内存分配**：在 60Hz 物理看门狗与 10Hz 战术步中，严禁动态创建表、闭包或字符串拼接操作。所有局部几何计算全部展开为纯标量局部变量。
3. **保护源工程**：严禁修改同级目录的 `SmartAI` 与 `AI-PIT-PRO`。新项目为 100% 独立闭环产品。
4. **单向依赖方向**：
   $$\text{Core (Context/Config/Logger)} \longleftarrow \text{Driver / Strategy} \longleftarrow \text{Main App / UI}$$
   Driver（车手层）与 Strategy（策略层）之间通过 `RaceContext` 和 `StrategyCoordinator` 明确契约解耦交互，禁止私自跨层访问内部私有状态。

---

## 2. 模块与文档导航

| 任务类型 | 必须首选阅读的文档 | 核心关联源码 |
| :--- | :--- | :--- |
| **系统架构与数据流** | [`docs/ARCHITECTURE.md`](file:///C:/Users/EDZ/Desktop/update-ac/app/Ultimate%20AI%20Grand%20Prix%20Pro/docs/ARCHITECTURE.md) | `Ultimate AI Grand Prix Pro.lua` |
| **模块接口与职责** | [`docs/MODULES.md`](file:///C:/Users/EDZ/Desktop/update-ac/app/Ultimate%20AI%20Grand%20Prix%20Pro/docs/MODULES.md) | `lib/core/RaceContext.lua`, `lib/strategy/StrategyCoordinator.lua` |
| **底层游戏与 CSP 交互**| [`docs/INTEGRATION.md`](file:///C:/Users/EDZ/Desktop/update-ac/app/Ultimate%20AI%20Grand%20Prix%20Pro/docs/INTEGRATION.md) | `lib/driver/watchdog.lua`, `lib/bridge/TelemetryBridge.lua` |
| **配置项与合法范围** | [`docs/CONFIGURATION.md`](file:///C:/Users/EDZ/Desktop/update-ac/app/Ultimate%20AI%20Grand%20Prix%20Pro/docs/CONFIGURATION.md) | `config/personas.json`, `lib/core/Config.lua` |
| **测试与验证指南** | [`docs/TESTING.md`](file:///C:/Users/EDZ/Desktop/update-ac/app/Ultimate%20AI%20Grand%20Prix%20Pro/docs/TESTING.md) | `tests/test_grand_prix_pro.lua` |
| **性能基线与预算** | [`docs/PERFORMANCE.md`](file:///C:/Users/EDZ/Desktop/update-ac/app/Ultimate%20AI%20Grand%20Prix%20Pro/docs/PERFORMANCE.md) | `lib/driver/LODScheduler.lua` |
| **项目演进与已知限制**| [`docs/DEVELOPMENT_STATUS.md`](file:///C:/Users/EDZ/Desktop/update-ac/app/Ultimate%20AI%20Grand%20Prix%20Pro/docs/DEVELOPMENT_STATUS.md) | - |

---

## 3. 标准验证命令

在修改任何代码后，必须在终端执行并通过回归测试：
```powershell
cd "C:\Users\EDZ\Desktop\update-ac\app\Ultimate AI Grand Prix Pro"
& "D:\Program Files (x86)\Lua\5.1\lua.exe" tests/test_grand_prix_pro.lua
```
预期输出：`ALL 15 INTEGRATION TESTS PASSED: Ultimate AI Grand Prix Pro!`
