# 自动化测试与验证规范 (docs/TESTING.md)

## 1. 测试运行方式

项目包含全量独立的系统集成测试套件，在离线 Standalone Lua 5.1 环境或 Python Lupa 嵌入运行时下均可一键执行：

```powershell
# 方案 A（标准 Lua 5.1）
& "D:\Program Files (x86)\Lua\5.1\lua.exe" tests/test_grand_prix_pro.lua

# 方案 B（Python Lupa 嵌入运行时，推荐，无需依赖外部 Lua 安装）
python -c "import lupa; from lupa import LuaRuntime; lua = LuaRuntime(unpack_returned_tuples=True); lua.execute(open('tests/test_grand_prix_pro.lua', 'r', encoding='utf-8').read())"
```

预期标准输出：
```text
==================================================================
  ALL 18 INTEGRATION TESTS PASSED: Ultimate AI Grand Prix Pro!    
==================================================================
```

---

## 2. 覆盖的 18 项集成验证用例全览

1. **Test 1：Core Config & Logger** - 参数加载、默认值回退、有界循环日志（Ring Buffer）防溢出。
2. **Test 2：RaceContext** - 比赛圈数、旗语、安全车状态单一真相源及 24 车标量数据同步。
3. **Test 3：PersonaLoader 7D DNA** - 预设配置解析、姓名模糊匹配及未收录车手 7D 程序化连续基因展开。
4. **Test 4：Driver Psychology & Momentum** - 压力累积、顺畅追击士气上升进入 Flow（心流）状态。
5. **Test 5：Breaking the Tow** - 长直道高速咬尾（< 30m）时激进车手主动画龙防吸尾流。
6. **Test 6：Radio Command Adherence** - 车队无线电指令（PUSH / SAVE / BOX_THIS_LAP / NONE）的即时下达与车手行为即时响应。
7. **Test 7：Stint Planning** - 确定性多组别正赛分段拆解与进站窗口计算。
8. **Test 8：Dynamic Fuel Model** - 质量效应、推圈模式、脏空气跟车及安全车低速降耗解算。
9. **Test 9：Pit Timing Evaluation** - 重度胎耗与前车压制下的 Undercut 提前停站评分裁决。
10. **Test 10：Emergency Fuel Guard & Pit Refill** - 极限断油安全注入与维修区出站精准加油接管。
11. **Test 11：Safety Watchdog 60Hz Takeover** - 单帧微操自动释放熔断与反向 J-Turn 物理自救。
12. **Test 12：Spatial LOD & Deep Sleep** - 远端 0Hz 绝对静默休眠与碰撞/黄旗中断唤醒。
13. **Test 13：TelemetryBridge Shared Memory** - C 结构体定长共享内存导出与外部查询一致性。
14. **Test 14：Hot Loop Zero Allocation** - 500 周期战术循环执行，GC 内存增量实测 < 1.0 KB。
15. **Test 15：Full System Integration** - 主脚本生命周期（`init`, `simUpdate`, `update`, `windowMain`）端到端集成步进。
16. **Test 16：24-Car AI Topology & Racecraft** - 24 车局部缠斗网格拓扑、两段式虚晃假动作、轮胎热衰竭与出站冷胎升温爬坡。
17. **Test 17：X-Skill Architecture** - 技能契约合法性校验、无修改 manifest 自动注册、二阶段门控仲裁、0.6s 承诺锁防抖与安全熔断。
18. **Test 18：CSP Strict Bounds Safety & Dynamic Laps** - 真实 CSP 环境越界抛错沙盒模拟、动态赛程圈数解析与无报错动态 AI 车手发现。
