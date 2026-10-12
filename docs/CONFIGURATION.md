# 配置说明与参数约束 (CONFIGURATION.md)

## 1. 配置文件结构

- **`config/personas.json`**：预设人格模版与车手姓名模糊映射表。
- **`config/settings.json`**：全系统运行开关与物理超参数。

## 2. 7D 车手基因连续谱系参数范围

每个车手（无论来自预设映射还是程序化 DNA）均拥有以下 7 维属性：

| 基因维度 | 键名 | 取值范围 | 物理与策略行为影响 |
| :--- | :--- | :--- | :--- |
| **战斗侵略性** | `base_aggression` | `0.40 ~ 0.98` | 攻防抽头意愿、晚刹车深度、破尾流画龙触发几率 |
| **入弯保守度** | `base_caution` | `0.20 ~ 2.50` | 默认跟车间距、重刹区留白冗余 |
| **心理抗压性** | `pressure_resist` | `0.30 ~ 0.95` | 压力衰减速率、生理感知延迟帧数（高抗压 1 帧，普通 2 帧） |
| **防守阻挡倾向** | `block_tendency` | `0.30 ~ 0.95` | 遭遇后车抽头时的变线占据幅度（最高 0.85 样条单位） |
| **保胎意识** | `tyre_preservation` | `0.35 ~ 0.95` | 胎耗临界值时主动触发 Lift and Coast 的积极程度 |
| **节油倾向** | `fuel_saving_factor` | `0.30 ~ 0.90` | 巡航巡航阶段平滑降耗能力（最多降低 6% 喷油） |
| **Undercut 偏好**| `undercut_preference` | `0.30 ~ 0.95` | 遇到前车阻挡时提前停站超车的倾向打分 |

---

## 3. 全局策略超参数 (`settings.json`)

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
