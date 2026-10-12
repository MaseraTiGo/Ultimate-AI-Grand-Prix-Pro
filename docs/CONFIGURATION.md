# 配置说明与参数约束 (CONFIGURATION.md)

## 1. 配置文件结构

- **`config/personas.json`**：预设人格模版（完整内置 2025/2026 现役 22 名 F1 车手）与车手姓名模糊映射表。
- **`config/skills_manifest.txt`**：X-Skill 外置扩展技能清单（支持动态发现，无需修改核心源码）。
- **`config/settings.json`**：全系统运行开关与物理超参数。

## 2. 车手基因连续谱系参数范围 (7D + X-Skill 特征)

每个车手（无论来自预设映射还是程序化 DNA）均拥有以下特征属性：

| 基因维度 | 键名 | 取值范围 | 物理与策略行为影响 |
| :--- | :--- | :--- | :--- |
| **战斗侵略性** | `base_aggression` | `0.40 ~ 0.98` | 攻防抽头意愿、晚刹车深度、破尾流画龙触发几率 |
| **入弯保守度** | `base_caution` | `0.20 ~ 2.50` | 默认跟车间距、重刹区留白冗余 |
| **心理抗压性** | `pressure_resist` | `0.30 ~ 0.95` | 压力衰减速率、生理感知延迟帧数（高抗压 1 帧，普通 2 帧） |
| **防守阻挡倾向** | `block_tendency` | `0.30 ~ 0.95` | 遭遇后车抽头时的变线占据幅度（最高 0.85 样条单位） |
| **保胎意识** | `tyre_preservation` | `0.35 ~ 0.95` | 胎耗临界值时主动触发 Lift and Coast 的积极程度 |
| **节油倾向** | `fuel_saving_factor` | `0.30 ~ 0.90` | 巡航巡航阶段平滑降耗能力（最多降低 6% 喷油） |
| **Undercut 偏好**| `undercut_preference` | `0.30 ~ 0.95` | 遇到前车阻挡时提前停站超车的倾向打分 |
| **赛道博弈球商** | `racecraft_iq` | `0.40 ~ 0.98` | X-Skill 假动作诱骗（FeintDummy）、交叉线反击（Switchback）成功判定权重 |
| **超车防守耐心** | `patience` | `0.30 ~ 0.95` | 避免无脑 Divebomb、等待最佳出弯开油抓地时机的忍耐系数 |

### 内置 22 名现役 F1 车手名录（11 支车队）
- **Red Bull Racing**: Max Verstappen, Liam Lawson
- **Ferrari**: Charles Leclerc, Lewis Hamilton
- **McLaren**: Lando Norris, Oscar Piastri
- **Mercedes**: George Russell, Kimi Antonelli
- **Aston Martin**: Fernando Alonso, Lance Stroll
- **Alpine**: Pierre Gasly, Jack Doohan
- **Williams**: Alexander Albon, Carlos Sainz
- **Racing Bulls**: Yuki Tsunoda, Isack Hadjar
- **Sauber / Audi**: Nico Hulkenberg, Gabriel Bortoleto
- **Haas**: Esteban Ocon, Oliver Bearman
- **Cadillac / 补充席位**: Valtteri Bottas, Sergio Perez

---

## 3. X-Skill 外置扩展清单 (`skills_manifest.txt`)

```text
# 每行一个技能实现脚本路径（支持绝对路径或相对项目根目录路径）
# 框架初始化时将自动 require 并执行 SkillRegistry.registerSkill 契约注册
lib/skills/SwitchbackSkill.lua
lib/skills/FeintDummySkill.lua
lib/skills/GentleSqueezeSkill.lua
lib/skills/TowWeaveSkill.lua
lib/skills/LateBrakeDiveSkill.lua
```

---

## 4. 全局策略超参数 (`settings.json`)

```json
{
  "general": {
    "enable_smart_driver": true,
    "enable_race_strategy": true,
    "enable_safety_watchdog": true,
    "enable_telemetry_bridge": true
  },
  "strategy": {
    "default_reserve_laps": 0.8,
    "sc_fuel_discount": 0.45,
    "traffic_density_penalty": 1.8,
    "pit_lane_loss_sec": 22.0
  },
  "driver": {
    "commitment_hold_sec": 0.7,
    "car_width_corridor_margin": 0.40,
    "breaking_tow_dist": 30.0,
    "lift_and_coast_wear_threshold": 0.65,
    "deep_sleep_enabled": true
  }
}
```
