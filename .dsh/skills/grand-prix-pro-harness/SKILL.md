name: grand-prix-pro-harness 

description:  Mandatory engineering skill for Ultimate AI Grand Prix Pro. Use whenever working on this project's code, debugging, refactoring, architecture, configuration, tests, performance, integration, documentation, or releases. Enforces token-efficient code navigation, repository isolation, safe implementation, regression testing, and automatic synchronization of this skill with relevant project changes.

# Ultimate AI Grand Prix Pro — Engineering Workflow

## 1. Mandatory Rules

- Activate this skill before performing any work on Ultimate AI Grand Prix Pro.
- Identify the actual project root before executing commands.
- Keep all modifications inside the target project. `SmartAI` and `AI-PIT-PRO` in parent directories are read-only baselines.
- Never scan the entire repository by default. Navigate directly to relevant documentation, source files, dependencies, and tests.
- Make the smallest complete change that solves the task. Avoid unrelated refactoring and speculative abstractions.
- Verify changes with actual tests. Never invent test results or claim unverified success.
- Before finishing, review the diff and synchronize this skill and affected project documentation whenever the change invalidates existing instructions.

## 2. Token-Efficient Navigation

Use this workflow:

1. Read the applicable project instructions and the relevant section of documentation.
2. Inspect `git status --short` and relevant diffs before editing.
3. Locate implementation files using the routing table below.
4. Inspect only the required functions, their callers, dependencies, and relevant tests.
5. Expand the search only when evidence shows that the initial scope is insufficient.

Do not use `Get-ChildItem -Recurse`, `find .`, full-repository grep, or bulk source dumps for routine tasks. Never discard existing user changes.

### Task routing

| Task                                   | Documentation                 | Primary files                                                |
| -------------------------------------- | ----------------------------- | ------------------------------------------------------------ |
| Driver behavior, defense, mistakes     | `docs/MODULES.md`             | `lib/driver/TacticalTicker.lua`, `lib/driver/BehaviorActuator.lua`, `lib/driver/MistakeEngine.lua` |
| Race and pit strategy                  | `docs/ARCHITECTURE.md`        | `lib/strategy/StrategyCoordinator.lua`, `lib/strategy/pit_strategy.lua`, `lib/strategy/fuel_model.lua` |
| Driver persona                         | `docs/CONFIGURATION.md`       | `lib/driver/persona_loader.lua`, `config/personas.json`      |
| Watchdog and safety                    | `docs/INTEGRATION.md`         | `lib/driver/watchdog.lua`                                    |
| LOD and performance                    | `docs/PERFORMANCE.md`         | `lib/driver/LODScheduler.lua` and affected hot-loop modules  |
| UI and logging                         | `docs/MODULES.md`             | `lib/ui/DashboardUI.lua`, `lib/core/Logger.lua`              |
| Telemetry and CSP integration          | `docs/INTEGRATION.md`         | `lib/bridge/TelemetryBridge.lua`                             |
| Tests and regressions                  | Relevant module documentation | `tests/test_grand_prix_pro.lua`                              |
| Engineering rules or project structure | `AGENTS.md` and this skill    | Actual project instructions and affected files               |

Treat this table as a navigation hint, not unquestionable truth. Verify paths against the current project before editing. Update obsolete entries when the project structure changes.

## 3. Architecture and Interface Constraints

Preserve these design principles unless the task explicitly requires a justified architectural change:

- Watchdog: nominal 60 Hz.
- Tactical driver: nominal 10 Hz.
- Strategy evaluation: nominal 1 Hz.
- `RaceContext` owns shared race and vehicle state.
- Strategy communicates intent through validated commands rather than directly manipulating vehicle controls.
- Tactical control consumes strategy commands and translates them into driver behavior.
- Safety-critical control must not depend on blocking I/O, UI rendering, or unbounded background work.

Expected commands include `PUSH`, `SAVE`, `BOX_THIS_LAP`, and `DEFEND`. Verify the actual interface and command handling before relying on these names.

Do not change interfaces without checking their producers, consumers, initialization, error handling, and regression tests.

## 4. Hot-Loop Performance

Apply strict performance discipline to time-critical code, particularly:

- `lib/driver/TacticalTicker.lua`
- `lib/driver/watchdog.lua`
- `lib/driver/BehaviorActuator.lua`

Avoid unnecessary per-tick allocations, temporary tables, closures, string concatenation, vector objects, repeated configuration parsing, blocking operations, and excessive logging.

Prefer preallocated state, scalar calculations, cached references, bounded execution, and deterministic scheduling.

Example, only when the actual API exposes these coordinates:

```lua
local dx = car.posX - other.posX
local dz = car.posZ - other.posZ
local distSq = dx * dx + dz * dz
```

Do not impose hot-loop restrictions on unrelated initialization, UI, or cold-path code without evidence.

Performance targets to verify against the implementation:

- Watchdog: below `0.01 ms` per invocation.
- Tactical driver: below `0.04 ms` per invocation.
- LOD scheduling: nominal 10 Hz / 3.33 Hz / 0 Hz.
- Allocation regression: historical target of less than `1.0 KB` over 500 cycles.

These are targets, not proof of actual performance. Verify measurement methodology and runtime before making claims. Update thresholds when requirements or verified measurements change.

## 5. Implementation and Testing

For every code change:

1. Identify the expected behavior and smallest affected scope.
2. Inspect relevant code, callers, interfaces, and tests.
3. Implement the smallest coherent solution.
4. Add or update regression tests.
5. Run focused tests, followed by the full regression suite when feasible.
6. Inspect the final diff for unrelated changes and regressions.
7. Synchronize affected documentation and this skill.

Configured regression command:

```powershell
& "D:\Program Files (x86)\Lua\5.1\lua.exe" tests/test_grand_prix_pro.lua
```

Run from the verified project root. Confirm that the interpreter and test file exist before execution. If unavailable, use the project's verified test runner or report the limitation.

The historical expected output is:

```
ALL 15 INTEGRATION TESTS PASSED: Ultimate AI Grand Prix Pro!
```

Verify the current test count and output rather than assuming they remain unchanged. Never alter tests merely to hide a regression.

If verification fails, diagnose the affected scope first. If tests cannot run, report what remains unverified.

## 6. Automatic Skill Synchronization

Whenever a project task changes files, inspect the final diff and determine whether this skill has become inaccurate.

Update this skill in the same task if any change affects:

- File paths, directory structure, or task routing.
- Architecture, module responsibilities, interfaces, or command contracts.
- Performance constraints, scheduling, or allocation requirements.
- Test files, test counts, runtime paths, or verification commands.
- Repository boundaries or mandatory engineering workflows.

Also update the relevant technical documentation and project instructions when their content is affected.

Rules:

- Remove obsolete paths and requirements; do not accumulate contradictory instructions.
- Base updates on verified implementation and tests, not assumptions.
- Keep this skill concise. Store detailed implementation knowledge in the relevant project documentation instead of duplicating it here.
- Do not modify the skill for changes that have no meaningful effect on its rules.
- After updating, review the skill and documentation diffs for consistency.
- If synchronization cannot be completed, report it as unfinished.

## 7. Completion Criteria

Before finishing, verify:

- The correct project was modified.
- Read-only baseline repositories remain untouched.
- Changes are limited to the required scope.
- Relevant tests were actually executed, or limitations were reported.
- The final diff was reviewed.
- Affected documentation and this skill are synchronized.

Report changed files, actual test results, synchronization status, and remaining issues. Never claim completion of a check that was not performed.-- Correct scalar distance computation
local dx = car.posX - other.posX
local dz = car.posZ - other.posZ
local distSq = dx * dx + dz * dz
