# CSP Lua SDK — AI API 索引

> SDK 快照：`extension/internal/lua-sdk/ac_apps/lib.lua` (18,489 行，CSP 0.2.7~0.3.0 定义)
> 生成时间：2026-10-14
> 索引原则：精确定位优先，最小必要信息。

## 1. 快速路由

| 开发目标 | 首选 API / 搜索入口 | 深入位置 |
|---|---|---|
| 判断车辆是否由 AI 控制 | `car.isAIControlled` / `ac.onCarAIToggle` | §3 / §4 |
| 读取车辆与比赛状态 | `ac.getCar(idx)` / `ac.getSim()` | §3 |
| 修改 AI 控制或物理行为 | `physics.setAI*` / `physics.setCar*` | §2 |
| 实现超车、防守、避让 | `physics.setAISplineOffset` / `physics.setAICaution` | §2 |
| 实现进站与轮胎、燃油策略 | `physics.setAIPitStopRequest` / `physics.setAITyres` / `physics.setCarFuel` | §2 / §4 |
| 调查未发现直接支持的能力 | 原厂 INI 与 CSP 内部 hook | §5 |

## 2. AI 控制与行为接口

### 2.1 AI 战术与人格调节 (`physics.*`)
- `physics.setAIAggression(carIndex: int, aggression: num) → void` — 设置 AI 激进度 (0~1，100% 传 0.95)；`lib.lua:L15164`；需要物理权限。
- `physics.setAICaution(carIndex: int, caution: num) → void` — 调节跟车安全距离 (0~16，默认 1)；`lib.lua:L15189`；实验性。
- `physics.setAILevel(carIndex: int, level: num) → void` — 设置 AI 水平等级 (0~2)；`lib.lua:L15130`。
- `physics.setAIThrottleLimit(carIndex: int, limit: num) → void` — 限制油门开度 (0 锁油门，1 解除)；`lib.lua:L15218`。
- `physics.setAITopSpeed(carIndex: int, limit: num) → void` — 限制最高时速 (km/h，解禁用 1e9)；`lib.lua:L15223`。
- `physics.setAIStopCounter(carIndex: int, time: num) → void` — 强制刹车站立计时 (秒，传 0 立即起步)；`lib.lua:L15213`。
- `physics.setAISteerMultiplier(carIndex: int, mult: num) → void` — 调整转向倍率改善走线；`lib.lua:L15228`。
- `physics.preventAIFromRetiring(carIndex: int) → void` — 持续阻止静止 AI 自动退赛；`lib.lua:L15178`。
- `physics.setAIBrakeMistake(carIndex: int, time: num) → void` — 诱发刹车抱死失误；`lib.lua:L15274`。
- `physics.setAITractionMistake(carIndex: int, time: num, severity: num) → void` — 诱发循迹加速打滑失误；`lib.lua:L15280`。

### 2.2 轨迹走线与超车防守 (`physics.*` / `ac.*`)
- `physics.setAISplineOffset(carIndex: int, offset: num, overrideAwareness: bool?) → void` — 相对横向偏移 (-1 左 ~ +1 右)；`lib.lua:L15235`。
- `physics.setAISplineAbsoluteOffset(carIndex: int, offset: num, overrideAwareness: bool?) → void` — 绝对物理横向偏移 (米，负左正右)；`lib.lua:L15242`。
- `physics.setAISpline(carIndex: int, filename: str?, aiHintsFilename: str?) → bool` — 热切换 AI 寻路 spline；`lib.lua:L15249`；受 `sim.customAISplinesAllowed` 限制。
- `ac.worldCoordinateToTrackProgress(pos: vec3) → num` — 空间坐标投影为规范化赛道里程进度 (0~1)；`lib.lua:L3112`。
- `ac.getTrackAISplineSides(progress: num) → vec2` — 查询当前里程处左右赛道极限宽度 (X=左, Y=右)；`lib.lua:L3117`。
- `ac.getTrackUpcomingTurn(carIndex: int?) → vec2` — 预判下一弯道距离与弯角度数；`lib.lua:L3536`。

### 2.3 进站与动力执行 (`physics.*`)
- `physics.setAIPitStopRequest(carIndex: int, value: bool?) → void` — 触发/取消 AI 进站意图 (进入通道必须维持 true 直至出站重置)；`lib.lua:L15259`。
- `physics.setAILapsToComplete(carIndex: int, value: int) → void` — 设定 AI 剩余跑圈数 (归零后进站)；`lib.lua:L15264`。
- `physics.setAITyres(carIndex: int, index: int) → void` — 切换物理轮胎配方槽位并重置初始损伤；`lib.lua:L15269`。
- `physics.setAIRainTyres(carIndex: int, useRainTyres: bool) → void` — 提示/覆盖 AI 雨胎决策；`lib.lua:L15285`。
- `physics.setTyresCompound(carIndex: int, wheels: int?, compoundIndex: int?) → void` — 绕过 setup 强制各轮配方 (`ac.Wheel.All=60`)；`lib.lua:L14868`。
- `physics.setCarFuel(carIndex: int, fuelLiters: num) → void` — 直接注入燃油 (升)；`lib.lua:L14804`；会废除当前单圈成绩。
- `physics.setTyresVirtualKM(carIndex: int, wheels: int?, km: num?) → void` — 重置或指定轮胎磨损累计里程；`lib.lua:L14886`。

## 3. AI 车辆与比赛状态

### 3.1 车辆遥测状态 (`ac.getCar(idx)` → `ac.StateCar`)
| 字段 / 方法 | 类型及用途 | 源码位置 |
|---|---|---|
| `car.isAIControlled` | `bool`：是否处于 AI 或自动驾驶管辖 | `lib.lua:L5057` |
| `car.aiAggression` / `aiLevel` | `num`：当前激活的激进度与等级 | `lib.lua:L5043-L5044` |
| `car.isAIGoingToPits` / `isRequestingPitStop` | `bool`：AI 是否正规划/请求进站 | `lib.lua:L5047, L5064` |
| `car.isInPitlane` / `isInPit` | `bool`：是否在维修区限速通道 / 工位作业中 | `lib.lua:L5062-L5063` |
| `car.isRefueling` / `isChangingTyres` | `str`：正在加油 / 换胎作业 | `lib.lua:L4978-L4979` |
| `car.speedKmh` / `splinePosition` | `num`：时速 (km/h) 与赛道规范化进度 (0~1) | `lib.lua:L5014, L5034` |
| `car.fuel` / `maxFuel` | `num`：当前剩余油量与油箱容积上限 (升) | `lib.lua:L5010, L4939` |
| `car.compoundIndex` / `:tyresName()` | `int / str`：生效中的轮胎槽位与配方名称 | `lib.lua:L5148, L7734` |
| `car.collisionDepth` / `collidedWith` | `num / int`：碰撞深度 (米) 与碰撞对象车号 | `lib.lua:L5038, L5040` |
| `car.engineLifeLeft` / `waterTemperature` | `num`：引擎剩余寿命 (1000~0) 与水温 (°C) | `lib.lua:L5025, L5018` |
| `car:driverName()` / `driverNumber()` | `str / int`：车手姓名与车号 | `lib.lua:L7752, L7764` |

### 3.2 赛局与环境遥测 (`ac.getSim()` → `ac.StateSim`)
| 字段 | 类型及用途 | 源码位置 |
|---|---|---|
| `sim.carsCount` | `int`：当前赛局参赛车辆总数 (越界守护基准) | `lib.lua:L5342` |
| `sim.raceSessionType` | `ac.SessionType`：练习/排位/正赛阶段类型 | `lib.lua:L5391` |
| `sim.raceFlagType` / `raceFlagCause` | `ac.FlagType / int`：黄旗/蓝旗状态及引发车号 | `lib.lua:L5387-L5388` |
| `sim.rainIntensity` / `roadGrip` | `num`：实时降水强度与路面抓地力系数 (0~1) | `lib.lua:L5376, L5372` |
| `sim.speedLimitKmh` | `num`：维修区法定限速 | `lib.lua:L5398` |

## 4. 策略、事件与配置

### 4.1 事件监听回调 (`ac.on*`)
- `ac.onCarAIToggle(carIndex: int?, callback: fun(cIdx: int, active: bool)) → Disposable` — 监听 AI 控制权切换；`lib.lua:L4070`。
- `ac.onTyresSetChange(carIndex: int?, callback: fun(cIdx: int, setIdx: int, sName: str, lName: str)) → Disposable` — 监听换胎生效；`lib.lua:L4052`。
- `ac.onLapCompleted(carIndex: int?, callback: fun(cIdx: int, lapTime: int, valid: bool, cuts: int, lapsCount: int, ...)) → Disposable` — 监听完成单圈；`lib.lua:L4082`。
- `ac.onCarCollision(carIndex: int?, callback: fun(cIdx: int)) → Disposable` — 监听碰撞发生；`lib.lua:L4089`。

### 4.2 辅助查询与配置解析
- `ac.getTyresIndex(carIndex: int, shortName: str) → int` — 按配方短名解析物理槽位；`lib.lua:L3070`。
- `ac.getTyresName(carIndex: int, compIdx: int?) → str?` — 查询槽位短名称；`lib.lua:L3064`。
- `ac.getDriverName(carIndex: int) → str?` — 查询车手姓名；`lib.lua:L3541`。
- `ac.INIConfig.carData(carIndex: int, fileName: str) → INIConfig` — 访问 `ai.ini` / `tyres.ini` 原厂物理配置；`lib.lua:L7061`。
- `physics.setAssists(assists: table, targetCarIndex: int?) → int` — 单车独立驾驶辅助配置 (TC/ABS/DamageRate)；`lib.lua:L11305`。

## 5. 能力缺口与后续调查入口

1. **直接超车/防守决策指令 (Overtake Mode Trigger)**：
   - 状态：当前声明文件未发现直接的 `physics.setAIOvertake()` 原生接口。
   - 相关接口：`physics.setAISplineOffset` (横向卡位)、`physics.setAICaution` (贴身度)、`physics.setAIThrottleLimit`。
   - 调查方向：通过上层拟人化驱动层结合几何距离与直道时机自行编排偏移行程。
2. **AI 单车绝对油耗系数调节 (Per-Car Fuel Consumption Multiplier)**：
   - 状态：当前声明文件未发现单车燃油消耗速率系数 API（仅全局 `sim.fuelConsumptionRate`）。
   - 相关接口：`physics.setCarFuel(carIndex, fuel)`、`physics.setAIThrottleLimit(carIndex, limit)`。
   - 调查方向：在 10Hz/1Hz 策略步周期性调用 `setCarFuel` 实施差值补偿或通过微调油门上限控制耗油。
3. **AI 进站策略预设完全脱离原生系统 (Fully Custom Pitstop Blueprint Injector)**：
   - 状态：已确认原生 AC AI 在维修通道内拥有硬编码寻路独占权。
   - 相关接口：`physics.setAIPitStopRequest` + `physics.setAITyres` + `ac.setPitstopSpinnerValue`。
   - 调查方向：遵循独占交接规程，在进站前签发工单，工位停稳后单次幂等下发物理换装与补油。

## 6. 索引使用规则

- 索引仅用于快速定位，不替代原始 API 定义。
- 签名、重载或标量含义不明确时，直接跳转标注的 `lib.lua:L行号` 核验。
- 严禁盲目读取未确认存在的 C 结构体字段（如直接访问未声明字段），必须经由防御性访问接口调用。
- 不得仅凭索引推断 CSP 运行时行为，重要逻辑必须配套回归测试。
