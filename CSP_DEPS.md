# csp-sdk 依赖管理与版本追踪 (CSP_DEPS.md)

> **本项目**：`Ultimate AI Grand Prix Pro`  
> **依赖清单配置文件**：[csp-deps.json](file:///C:/Users/EDZ/Desktop/update-ac/app/Ultimate%20AI%20Grand%20Prix%20Pro/csp-deps.json)  
> **上游 SDK 仓库**：[csp-sdk](file:///C:/Users/EDZ/Desktop/update-ac/app/csp-sdk)

---

## 1. 当前引入的 SDK 模块清单

| SDK 模块 | 本地安装版本 | SDK 最新版本 | 本地引入目录 | 状态 | 功能简述 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **CAS** | `v1.1.0` | `v1.1.0` | `lib/driver/cas/` | `UP_TO_DATE` | 360° 近距战术雷达与盲区监测 |
| **Pit Strategy** | `v1.0.0` | `v1.0.0` | `lib/strategy/pit_strategy/` | `UP_TO_DATE` | 限圈/限时正赛油耗推演与停站加注约束 |
| **Track Hotspots** | `v1.0.0` | `v1.0.0` | `lib/driver/track_hotspots/` | `UP_TO_DATE` | 空间网格事故热力学习与逆向减速区广播 |
| **Stewards** | `v1.0.0` | `v1.0.0` | `lib/driver/stewards/` | `UP_TO_DATE` | 弯道路权量化仲裁与攻防态势锁定 |
| **Utils** | `v1.0.0` | `v1.0.0` | `lib/core/utils/` | `UP_TO_DATE` | Win32 QPC 纳秒硬件时钟与安全探针 |

---

## 2. 依赖检查与升级工作流

### 2.1 检查 SDK 是否有新版本
可通过运行依赖比对脚本，自动扫描上游 `csp-sdk` 最新发布的版本及变更记录：
```powershell
python "C:\Users\EDZ\Desktop\update-ac\app\csp-sdk\utils\dep_tracker.py" --check-project "."
```

### 2.2 升级本地模块步骤
1. 从 `csp-sdk/<module>/` 同步最新源文件至本地对应目录。
2. 更新本工程的 [csp-deps.json](file:///C:/Users/EDZ/Desktop/update-ac/app/Ultimate%20AI%20Grand%20Prix%20Pro/csp-deps.json) 中的 `installedVersion`。
3. 执行项目的标准回归测试套件验证兼容性：
   ```powershell
   python -c "import lupa; from lupa import LuaRuntime; lua = LuaRuntime(unpack_returned_tuples=True); lua.execute(open('tests/test_grand_prix_pro.lua', 'r', encoding='utf-8').read())"
   ```
4. 测试通过后，执行同步脚本将最新状态登记回 `csp-sdk` 总表：
   ```powershell
   python "C:\Users\EDZ\Desktop\update-ac\app\csp-sdk\utils\dep_tracker.py" --sync-upstream
   ```

---

## 3. 本地定制与兼容性备忘录 (Local Customizations)
- **零 GC 与性能约束**：引入的模块必须严格遵守 `AGENTS.md` 规范（在 60Hz 物理循环中零表分配，热路径局部展开标量计算）。
- **FFI 防御**：任何涉及 CSP CData 的访问必须保持通过 `RaceContext.safeSimGet` 或 `utils.isCallable` 防护。
