# Ultimate AI Grand Prix Pro - Agent 快速上手与总入口规范

> **项目定位**：Assetto Corsa (CSP Lua) 统一拟人化 AI 车手大脑与动态车队策略指挥平台（Unified Anthropomorphic Driver & Pit Wall Engine）。  
> **项目根目录**：`.`（当前仓库根目录）  
> **标准测试运行器**：
> - 方案 A（标准 Lua 5.1）：`& "D:\Program Files (x86)\Lua\5.1\lua.exe" tests/test_grand_prix_pro.lua`
> - 方案 B（Python Lupa 嵌入运行时，无需外部 Lua 环境）：`python -c "import lupa; from lupa import LuaRuntime; lua = LuaRuntime(unpack_returned_tuples=True); lua.execute(open('tests/test_grand_prix_pro.lua', 'r', encoding='utf-8').read())"`

---

## 1. 核心约束与工作准则

1. **零全盘扫描原则**：严禁无目的检索全量文件。进行任何任务前，请先查阅下方的【文档与模块索引导航】。
2. **相对路径原则**：所有文档索引、配置加载、脚本调用、测试执行一律采用相对路径（以仓库根目录为基准），严禁硬编码任何绝对物理路径。
3. **零运行时内存分配**：在 60Hz 物理看门狗与 10Hz 战术步中，严禁动态创建表、闭包或字符串拼接操作。所有局部几何计算全部展开为纯标量局部变量。
4. **CSP API 严格越界防护**：调用 `ac.getCar(idx)` 与 `ac.getDriverName(idx)` 必须先校验 `idx < sim.carsCount`，且必须通过 `safeGetCar` / `safeGetDriverName`（`pcall` 包装）进行访问，禁止对未参赛槽位进行盲探以防 C++ 级 `out of range` 抛错。
5. **初始化单次幂等保护**：`ensureInitialized()` 必须保证 `script.init()` 只触发一次，严禁在渲染帧循环中递归或逐帧重试初始化，防止重置 `EventHub` 与策略中枢。
6. **双脚本文件强同步**：根目录下的 `Ultimate AI Grand Prix Pro.lua` 与 `Ultimate-AI-Grand-Prix-Pro.lua` 必须保持 100% 字节一致。
7. **保护源工程**：严禁修改同级目录的 `SmartAI` 与 `AI-PIT-PRO`。新项目为 100% 独立闭环产品。
8. **单向依赖方向**：
   $$\text{Core (Context/Config/Logger/EventHub)} \longleftarrow \text{Driver / Strategy} \longleftarrow \text{Main App / UI}$$
   Driver（车手层）与 Strategy（策略层）之间通过 `RaceContext` 和 `StrategyCoordinator` 明确契约解耦交互，禁止私自跨层访问内部私有状态。
9. **CSP C-Struct (LuaJIT FFI) 严格字段防护**：底层 `ac.getSim()` 返回 C 结构体 `struct state_sim`。在 LuaJIT FFI 下直接访问结构体未定义的字段（如 `sim.sessionTime`、`sim.raceLaps`、`sim.currentLap` 等）会抛出不可恢复的运行时 Crash。必须统一使用 `RaceContext.safeSimGet(sim, field)` 进行防御性访问，或通过 `RaceContext.getRaceState()` 获取已规整好的数据。
10. **CSP 原生 AI 进站触发标准与独占权限规范（CSP AI Pit Control & Exclusive Handoff）**：
    - **合法触发 API**：进站控制必须且只能调用 CSP 官方接口 `physics.setAIPitStopRequest(carIndex, true)`，严禁使用虚假油量诱导（如 `setCarFuel(carIndex, 1.8)`），防止被油量保护看门狗覆盖或破坏赛车动力。在赛道上取消指令时显式调用 `setAIPitStopRequest(carIndex, false)`。
    - **进站请求生命周期守护（Prevent Drive-Through）**：`physics.setAIPitStopRequest(carIndex, true)` 在赛车驶入维修通道直至在工位停稳作业期间必须**持续保持为 true**，严禁在刚进入维修通道时过早置为 false（官方 SDK 明确规范：传入 false 会立即阻断并取消 AI 进站，导致赛车仅仅 Drive-Through 直通维修区而不进站停留）。只有在赛车完全完成作业驶离维修区重返赛道（`wasInAnyPit and not isNowInPit`）时，才调用 `setAIPitStopRequest(carIndex, false)` 进行闭环重置。
    - **维修区原生独占权**：当车辆进入维修区（`c.isInPitlane` 或 `c.isInPit`）时，原生 AC AI 拥有绝对寻路与停站作业权。`BehaviorActuator` 与 `TacticalTicker` 必须直接熔断退出，严禁施加横向偏移（`setAISplineOffset`）、调低油门上限或设置人为停止时间（`setAIStopCounter(i, 3)`）。
    - **出站三重释放保障**：赛车驶离维修区时，必须确保执行三重安全释放：`setAIPitStopRequest(i, false)`、`setAIStopCounter(i, 0)`、`setAIThrottleLimit(i, 1.0)`，彻底消除车辆在停站工位无限期发呆滞留（Stall in Pit Box）隐患。
11. **单车状态隔离与战术推荐解耦规范（Per-Car State Isolation & Command Idempotency）**：
    - **推荐与指令解耦**：策略计算层的战术建议（`plan.activeRecommendation`）仅作为参考数据，**严禁自动改写**车手无线电指令（`cState.radioCommand`）。`cState.radioCommand` 专供人类车队指令（Pit Wall）独占，未受人工干预的车辆其无线电状态必须保持 `"NONE"`。
    - **进站窗口梯次错峰**：全场赛车进站窗口必须调用 `StrategyCalc.getF1PitSpreadGroupOffset(i)` 进行梯次分组错峰（±1~2圈），严禁全车队在同一圈触发 `curLap >= plan.targetLap` 引发全场大范围同时进站雪崩。
    - **起步与首圈车群防护（Opening Lap Safety）**：在发车格与第 1 圈车群极度密集阶段（`lapCount == 0` 或 `speed < 75km/h`），横向偏移强制归零（`offset = 0.0`），Caution 警惕度维持 `>= 1.0`（严禁下调至 0.1 导致追尾），防止开局第一弯多车挤压追尾事故。

---

## 2. 模块与文档导航

| 任务类型 | 必须首选阅读的文档 | 核心关联源码 |
| :--- | :--- | :--- |
| **系统架构与数据流** | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | `Ultimate AI Grand Prix Pro.lua`, `lib/core/EventHub.lua` |
| **模块接口与职责** | [`docs/MODULES.md`](docs/MODULES.md) | `lib/core/RaceContext.lua`, `lib/strategy/StrategyCoordinator.lua`, `lib/ui/DashboardUI.lua` |
| **底层游戏与 CSP 交互**| [`docs/INTEGRATION.md`](docs/INTEGRATION.md) | `lib/driver/watchdog.lua`, `lib/bridge/TelemetryBridge.lua` |
| **配置项与合法范围** | [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md) | `config/personas.json`, `lib/core/Config.lua` |
| **测试与验证指南** | [`docs/TESTING.md`](docs/TESTING.md) | `tests/test_grand_prix_pro.lua` |
| **性能基线与预算** | [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) | `lib/driver/LODScheduler.lua` |
| **项目演进与已知限制**| [`docs/DEVELOPMENT_STATUS.md`](docs/DEVELOPMENT_STATUS.md) | `lib/skills/` |

---

## 3. 标准验证命令

在修改任何代码后，必须在终端执行并通过回归测试：
```powershell
# 推荐使用 Python Lupa 或指定环境下的 lua.exe
python -c "import lupa; from lupa import LuaRuntime; lua = LuaRuntime(unpack_returned_tuples=True); lua.execute(open('tests/test_grand_prix_pro.lua', 'r', encoding='utf-8').read())"
```
预期输出：`ALL 26 INTEGRATION TESTS PASSED: Ultimate AI Grand Prix Pro!`

---

## 4. 专属 Skills 工具链与 Token 极致效率控制规范（Skills Workflow & Token Optimization）

为了最大化 AI Agent 的工作效率并最小化上下文 Token 消耗，项目内置了 6 大专项目标 Skills（存放于 `.agents/skills/`），Agent 在不同工作阶段应严格按需调度对应工具：

| 阶段 / 意图 | 推荐专属 Skill | 核心执行脚本 / 工具 | 赋能与 Token 节约机制 |
| :--- | :--- | :--- | :--- |
| **架构与依赖感知** | `repo-map` | `python .agents/skills/repo-map/scripts/build_repo_map.py` | 提取模块符号、导出表与 `require` 依赖关系图。**节约 85%+ Context Token**，彻底消除无目的盲目开大文件。 |
| **影响面与调用链追踪**| `diff-aware-ripper` | `python .agents/skills/diff-aware-ripper/scripts/diff_ripper.py` | 针对当前 git diff 自动提取变动符号，扫描下游所有消费者调用点，秒级定位关联文件，防止遗漏改动点。 |
| **结构化 AST 语法萃取**| `tree-sitter-ast` | `python .agents/skills/tree-sitter-ast/scripts/ast_analyzer.py` | 免除阅读全文直接提取函数签名、作用域边界与 C-Struct 成员访问，精确圈定行号区间。 |
| **上下文多行锚点替换**| `search-replace-block`| `python .agents/skills/search-replace-block/scripts/search_replace.py` | 高保真块替换，确保上下文唯一性，杜绝整文件盲写带来的漂移与误伤。 |
| **手术式补丁与双脚本校验**| `patch-editor` | `python .agents/skills/patch-editor/scripts/patch_validator.py` | 自动验证双主入口脚本（`Ultimate AI Grand Prix Pro.lua` ↔ `Ultimate-AI-Grand-Prix-Pro.lua`）100% 字节一致性及语法无误。 |
| **质量门禁与全量回归**| `review-gate` | `python .agents/skills/review-gate/scripts/review_gate.py` | 统一执行全量 22 项回归测试与规则核验，一键阻断违规代码合并。 |

### Token 极致节省与高效工作纪律（Token Conservation Guardrails）
1. **按需切片读取（Slice-based Reading）**：严禁无行号限制直接加载 300+ 行的大型文件。必须先通过 `repo-map` 或 AST 分析器定位关键符号，仅使用 `StartLine` 与 `EndLine` 精确读取 30~80 行核心逻辑块。
2. **渐进式取证（Progressive Evidence Acquisition）**：单次任务严禁连续探测超过 3 个非直接关联文件。若需跨模块调用追踪，优先通过 `diff_ripper` 精准圈定 callers/callees，不逐个文件盲开。
3. **零重复读取（Zero Redundant Reads）**：严禁在未修改文件的情况下重复使用查看工具读取同一文件内容。充分复用 Context 历史。
4. **局部原子补丁（Minimal Atomic Edit）**：禁止为了修改几行代码而重写整个文件，必须使用 `replace_file_content` 进行最小范围局部替换。
5. **自动化门禁闭环（Automated Gate Loop）**：任务结束前，必须直接运行 `review_gate.py` 和 `patch_validator.py`，以极低命令开销完成全量规范与测试核验，无需将大量冗余验证文本写入上下文。

---

## 5. 行为约束与执行纪律（Operational Guardrails & Execution Discipline）

### 1. 文件访问与范围控制（File Scope & Read Efficiency）

- **最小必要原则：** 围绕当前任务，优先通过文件名、符号、调用关系、错误栈、配置项、Git diff 等低成本信息定位目标。禁止无目的遍历目录、全量加载代码库或读取无关文件。
- **渐进式读取：** 优先读取入口、核心实现及直接依赖，仅在现有证据不足时扩大范围。根据任务复杂度动态调整读取规模，不设置僵化的文件数量上限。
- **避免重复读取：** 默认复用已获取且仍然有效的内容。只有在文件已发生变化、需要核对精确内容、上下文缺失或验证确有必要时，才重新读取；禁止没有新增信息价值的重复操作。
- **按需深入：** 大型文件优先使用定向搜索、指定行读取或相关代码片段。禁止无目的读取大型日志、构建产物、依赖目录、虚拟环境及其他与任务无关的数据。
- **允许必要扩展：** 如果调用链、测试结果或错误信息表明问题涉及其他模块，可以自主扩展调查范围，不得因固定读取配额而牺牲诊断准确性。
- **上下文失效处理：** 当历史内容可能过期、不完整或与当前文件状态不一致时，以当前实际文件和工具输出为准，必要时重新获取证据。

### 2. 失败处理与重试控制（Failure Handling & Retry Control）

- **禁止无效重试：** 相同操作因相同原因失败后，最多进行一次有明确目的的重试。重试前必须检查错误原因、环境状态或输入条件是否发生变化。
- **先诊断，再重试：** 首次失败后优先提取完整错误信息，判断是参数、路径、依赖、权限、环境、代码逻辑还是工具能力问题。不得仅通过微调语法或反复更换命令形式进行盲目尝试。
- **允许改变方案：** 当获得新的诊断证据、排除原有假设或找到不同解决路径时，可以继续采取新的措施，不受原操作重试次数限制。
- **分级熔断：** 当同一根因持续无法排除、继续尝试没有明确成功路径、操作风险不可控或缺少必要授权时，暂停相关操作，并向用户简要说明已尝试的方案、失败原因、当前判断及需要的协助。
- **禁止过早放弃：** 不得仅因一次或两次失败就终止整个任务。若当前方案失败但存在合理、安全且成本可控的替代方案，应优先自主排查和解决。
- **避免重复破坏：** 不得在状态未知时重复执行可能造成数据丢失、重复写入、重复提交或其他不可逆副作用的操作。

### 3. 任务聚焦与自主执行（Goal Focus & Autonomous Execution）

- **目标锚定：** 严格围绕用户明确提出的目标、验收标准和授权范围开展工作。禁止顺手重构无关模块、修复无关警告或擅自增加需求。
- **允许必要的关联修改：** 如果目标无法在单个文件内正确实现，可以修改必要的调用方、配置、接口、测试和文档。以完整实现目标为准，而非机械限制修改文件数量。
- **先规划，后执行：** 在内部明确问题、关键证据、最小合理方案、潜在风险和验证方式，无须为常规、已授权的操作反复向用户请求批准。
- **自主完成闭环：** 对复杂任务按照“定位与分析 → 方案选择 → 实施修改 → 验证结果 → 必要修复”的流程执行。允许在获得新证据后调整方案，不得将该流程机械化为必须逐阶段等待用户确认的审批流程。
- **仅在必要时询问：** 只有当需求存在实质性歧义、关键决策无法合理推断、操作超出授权范围或风险需要用户承担时，才暂停并请求确认。能够安全推断的细节应自主处理。
- **持续检查方向：** 长任务、上下文压缩、连续失败或调查范围明显扩大时，重新核对核心目标与当前进展，及时终止偏离目标的工作。

### 4. 工具调用与执行效率（Tool Invocation & Efficiency）

- **调用必须有目的：** 每次调用工具前，在内部明确其预期产出，以及该产出如何帮助定位、修改或验证问题。没有明确价值的调用不应执行。
- **优先低成本证据：** 优先使用定向搜索、差异比较、指定范围读取、现有测试结果及已有日志片段。只有在这些信息不足时，才扩大读取或执行范围。
- **优先精准修改：** 优先采用局部补丁、精准替换或小范围重构。只有当局部修改无法保证正确性、一致性或可维护性时，才重写整个文件或模块。
- **避免无关副作用：** 执行批量修改、删除、覆盖、清理或系统级操作前，确认影响范围及必要的恢复手段；涉及重大或不可逆风险时，先取得必要授权。
- **合理合并操作：** 在不影响安全性、可诊断性和执行顺序的前提下，合并相关的只读搜索、状态检查与验证操作，减少重复工具调用和中间输出。
- **禁止虚假完成：** 不得将命令已执行、文件已写入或测试已启动等同于任务已成功。必须依据实际结果报告完成状态。

### 5. 修改验证与交付标准（Verification & Delivery）

- **验证与改动匹配：** 根据修改范围选择适当的测试、构建、静态检查、接口验证或运行验证，不执行与目标无关的昂贵检查。
- **检查实际差异：** 修改后检查关键差异，确认没有意外覆盖、无关变更、明显语法错误或遗漏必要的关联修改。
- **失败后的处理：** 验证失败时，先判断是否由本次修改引起，再依据证据修复；不得掩盖错误、伪造测试结果或为了通过检查而削弱原有功能。
- **明确验证边界：** 对无法执行的测试、缺失的依赖、受限的环境或未覆盖的场景，如实说明原因及其影响。
- **以目标完成为终点：** 在目标实现、必要验证完成且没有遗留的已知阻塞问题后结束任务。交付时简要列出关键修改、验证结果及仍存在的限制。