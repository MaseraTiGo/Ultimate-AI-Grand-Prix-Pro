# CSP Lua SDK — AI API 审计与覆盖报告

> 审计基准：`extension/internal/lua-sdk/ac_apps/lib.lua` (18,489 行，CSP SDK)
> 交付对应索引：`csp-ai-api-index.md`

## 1. 扫描范围与策略

- **检查范围**：
  - 核心定义：`extension/internal/lua-sdk/ac_apps/lib.lua` (全量公共 API、结构体与回调)。
  - 辅助规范：`.agents/skills/csp-lua/SKILL.md` (项目内置约束与使用模式)。
- **核心关键词组**：
  - AI 与物理控制：`physics.setAI*`, `physics.setCar*`, `physics.override*`
  - 遥测状态与结构体：`ac.StateCar`, `ac.StateSim`, `isAIControlled`, `isAIGoingToPits`
  - 策略、进站与轮胎：`setAIPitStopRequest`, `setAITyres`, `setCarFuel`, `setTyresCompound`
  - 事件驱动：`ac.onCarAIToggle`, `ac.onTyresSetChange`, `ac.onLapCompleted`, `ac.onCarCollision`

## 2. 候选数量与收录统计

| 指标 | 统计值 | 说明 |
|---|---|---|
| 初筛匹配候选符号 | 114 个 | 涵盖所有包含 `AI`, `Pit`, `Tyre`, `Fuel`, `Control` 等字段 |
| 语义关联与去重后有效 API | 48 个 | 剔除通用绘图、音频、纯相机、重复重载与非 AI 强关联接口 |
| **最终主索引收录条目** | **38 个** | 控制接口 16 个、遥测字段 17 个、事件/配置 5 个 |
| 索引文件体积 | 117 行 / 6.4 KB | 严格达标（预算：$\le 200$ 行，$\le 12$ KB） |

## 3. 代表性条目复核结果

对以下 6 个不同类别的代表性 API 进行了源码逐行回跳复核：

1. `physics.setAIAggression` → `lib.lua:L15164` (签名、参数 0~1、0.95 倍率注释完全一致)。
2. `physics.setAISplineOffset` → `lib.lua:L15235` (签名、偏移范围 -1~1 完全一致)。
3. `physics.setAIPitStopRequest` → `lib.lua:L15259` (签名、布尔生命周期机制完全一致)。
4. `car.isAIControlled` → `lib.lua:L5057` (布尔状态字段，完全一致)。
5. `ac.onTyresSetChange` → `lib.lua:L4052` (回调入参、四元参数与返回值 Disposable 完全一致)。
6. `ac.getDriverName` → `lib.lua:L3541` (0-based carIndex、返回值 string? 完全一致)。

## 4. 已知覆盖盲区与环境限制

1. **New Mode 专属物理 API 差异**：部分辅助控制（如 `physics.setAllowedTyresOut`）可在普通脚本调用受限时在 New Mode 运行，但在纯 UI App 下需通过 `physics.allowed()` 校验。
2. **AC 原生 AI C++ 行为独占区**：维修区进站寻路与停车作业在 AC 引擎层面具备硬编码独占权，Lua API 只能通过 `setAIPitStopRequest` 诱导与 `setAITyres` 物理注入，无法修改原生进站停靠路径点。
