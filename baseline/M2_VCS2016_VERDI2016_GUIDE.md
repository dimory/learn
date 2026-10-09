# M2：VCS2016 + Verdi2016 验收步骤

## 1. 工程入口与环境

解压后进入 `learn-main/baseline`。顶层是 `tb_wave_control_subsystem`。
M2 只使用 `sim/filelist_m2_rtl.f` 和 `sim/filelist_m2_tb.f`。
不要把根目录的旧 RTL、M1 顶层或未完成的 M3 Decoder 一起编入这个验证顶层。

先加载你机器上已有的 VCS2016 / Verdi2016 环境设置，确保 `vcs` 和 `verdi` 在 PATH 中。
Verdi 安装根目录还应包含：

```text
share/PLI/VCS/LINUX64/novas.tab
share/PLI/VCS/LINUX64/pli.a
```

如果环境设置尚未定义根目录，使用你机器上的真实路径：

```bash
export VERDI_HOME=/actual/path/to/verdi2016
export NOVAS_HOME="$VERDI_HOME"
```

脚本优先使用 `NOVAS_HOME`，其次使用 `VERDI_HOME`。路径检查不会消耗仿真 license，
也不会自动验证所选版本或 license。实际编译和打开工具时再确认它们确实是 2016 版本。

## 2. 先跑默认四 Wave 配置

```bash
make m2_env
make preflight
make m2
make m2_verdi
```

`make preflight` 需要 Python 3；VCS / Verdi 启动脚本只依赖 Bash 和对应商业工具。
默认值为 `NUM_WAVE_CONTEXTS=4`、`THREADS_PER_WORKGROUP=64`、Wave32。

`make m2` 编译 package、五个 M2 子模块、wrapper、协议检查器和整个子系统 TB。
根据你的 VCS2016 环境反馈，编译参数已包含 `-lca`。矩阵调用同一个编译脚本，自动使用此参数。
它启用 FSDB，包括 `$fsdbDumpMDA()`，用于查看每 Wave 的 counter 和 Context 数组。

默认功能仿真通过时，日志中必须有：

```text
TinyGPU M2: ALL 9 SCENARIO GROUPS PASSED N=4 WG=64 cycles=... checks=...
```

输出文件：

| 内容 | 相对 `baseline` 的路径 |
| --- | --- |
| 编译日志 | `logs/m2_vcs_n4_wg64_compile.log` |
| 仿真日志 | `logs/m2_vcs_n4_wg64.log` |
| 仿真可执行文件 | `build/simv_m2_n4_wg64` |
| 默认配置的独立波形 | `waves/tinygpu_m2_n4_wg64.fsdb` |

功能日志必须通过，FSDB 必须非空，且 Verdi 应成功打开这个文件。
目前工程中附带的是本次补充仿真 VCD；你的 VCS 运行会生成上述 FSDB。

### 2.1 单独运行一个 Scenario

TB 现在支持 `+M2_SCENARIO=<1..9>`。`0` 表示原来的完整回归，默认 `make m2` 仍然跑全部 Scenario。
推荐通过 Makefile 使用：

```bash
make m2_scenario SCENARIO=3
make m2_scenario_verdi SCENARIO=3
```

也可以直接调用脚本：

```bash
./scripts/run_m2_vcs.sh 4 64 3
./scripts/open_m2_verdi.sh 4 64 3
```

单独运行 Scenario 3 时，文件名为：

```text
logs/m2_vcs_n4_wg64_s3.log
waves/tinygpu_m2_n4_wg64_s3.fsdb
```

Scenario 编号固定如下：

| ID | Scenario | 主要检查 |
| ---: | --- | --- |
| 1 | `zero_thread` | 零线程 launch、无分配、done 单周期 |
| 2 | `dispatch_edges_and_random_lifecycle` | Partial Wave、Context 满、RR、backpressure、随机生命周期 |
| 3 | `all_counter_bounds_wait_and_safe_retire` | 七类 counter 边界、Wait、DONE outstanding、安全退休 |
| 4 | `completion_and_wait_arm_same_edge` | completion 与 Wait arm 同沿时使用旧 counter 判断 |
| 5 | `multi_wave_wait_and_barrier_release` | 多 Wave Wait 唤醒、multi-hot Barrier release；要求 `N>1` |
| 6 | `invalid_events_ignored` | FREE/非法 ID/kind/zero amount 等非法事件保护 |
| 7 | `asynchronous_reset_discards_stalled_launch` | Scheduler stall/lock 状态下异步复位 |
| 8 | `asynchronous_reset_aborts_active_kernel` | 活跃 Kernel、outstanding、WAITCNT 状态下异步复位 |
| 9 | `workgroup_id_crosses_65535` | Workgroup ID 从 65535 跨到 65536 |

单跑模式不会执行“所有 Scenario 的联合 coverage 必须全部命中”的总检查；它只保留该 Scenario 本身的自检和协议检查。
TB 还导出了 `scenario_id`，在 Verdi 中把 `tb_wave_control_subsystem.scenario_id` 加入波形即可直接看到当前 Scenario 编号。

## 3. Verdi 中先加入这些信号

所有路径均位于 `tb_wave_control_subsystem`。把时钟、复位和事件放在最上方，
mask 用 binary，Wave ID 和 count 用 unsigned，PC / EXEC 用 hexadecimal。

| 分组 | 顶层 TB 信号 / DUT 内部对象 |
| --- | --- |
| Scenario / Kernel | `scenario_id`, `clk`, `rst_n`, `start`, `thread_count`, `busy`, `done` |
| 分配 | `alloc_fire`, `alloc_wave_id`, `free_mask`, `dut.alloc_valid`, `dut.alloc_ready` |
| 调度 | `selected_valid`, `selected_ready`, `selected_wave_id`, `schedule_fire`, `ready_mask`, `issued_mask` |
| RR 与背压 | `dut.u_scheduler.round_robin_pointer`, `dut.u_scheduler.locked`, `dut.u_scheduler.locked_wave_id` |
| Commit | `commit_valid`, `commit_wave_id`, `commit_next_state`, `commit_pc_write_enable`, `commit_pc` |
| Counter 事件 | `dependency_issue_valid`, `dependency_issue_wave_id`, `dependency_issue_kind`, `dependency_issue_amount`, 对应的 `dependency_complete_*` |
| Wait | `wait_arm_valid`, `wait_arm_wave_id`, `wait_arm_satisfied`, `waitcnt_mask`, `wait_satisfied_mask`, `wait_wakeup_mask` |
| Barrier / 退休 | `barrier_mask`, `barrier_release_mask`, `done_mask`, `all_counters_zero_mask`, `retire_fire`, `retire_wave_id` |
| 完成统计 | `dut.u_dispatcher.dispatch_finished`, `dut.u_dispatcher.waves_dispatched`, `dut.u_dispatcher.waves_completed` |

数组对象在各实例下展开查看：

- `dut.u_context_table.context_state`、`context_pc`、`context_exec` 等 Context 数组。
- `dut.u_dependency_tracker.load_count`、`store_count`、`ds_count`、`km_count`、`async_count`、`tensor_count`、`x_count`。
- `dut.u_dependency_tracker.wait_active`、`saved_wait_counter_mask` 和七个保存的阈值数组。

## 4. 按事件检查时序

事件以**上升沿前的值**决定是否被接受；非阻塞赋值在**这个上升沿之后**更新寄存器。
因此把光标放在边沿前后分别比较，不能只用沿后的 `fire` 值判断刚刚有没有发生传输。

| 上升沿前的条件 | 同一个沿之后应观察到的变化 |
| --- | --- |
| `alloc_fire=1`，目标原本 FREE | 该 Entry 变 READY；初始 Context 写入；`waves_dispatched+1` |
| `schedule_fire=1` | 该 Entry READY→ISSUED；RR pointer 更新到 accepted Wave 的下一个位置 |
| `selected_valid=1 && selected_ready=0` | `locked=1`；选中 ID 和 Context 在后续背压周期保持稳定 |
| 合法 `commit_valid=1` | 指定 Entry 从 ISSUED 变为 `commit_next_state`，写使能指定的架构字段更新 |
| 同 Wave、同 kind 的 issue 与 complete | Counter 按 old count + issue amount − complete amount 更新 |
| 未满足的 Wait arm 和 wait commit | `wait_active=1`，Context 变 WAITCNT；Scheduler 不再选择它 |
| completion 使 Wait 条件满足 | 沿后 counter 更新，组合 wake mask 可变为 1；下一上升沿才 WAITCNT→READY 并清 `wait_active` |
| DONE 且七个 counter 全为零 | `retire_fire=1`；退休沿后该 Entry FREE，`waves_completed+1` |
| 最后一个已分配 Wave 安全退休 | 退休沿后 `done=1`，下一沿后返回 IDLE，`done` 只持续一个 cycle |

还要检查：未完成 counter 非零时 DONE Entry 不会退休；表满时分配暂停；
满表释放 Entry 的那个沿不旁路分配，下一周期才能再用它；异步复位清空 Context、counter 和调度锁。
复位后的组合输出由已复位寄存器自然确定，RTL 不添加组合复位门控。

## 5. 再跑参数矩阵

默认配置完成波形检查后运行：

```bash
make m2_vcs_matrix
```

矩阵为 `(N, WG) = (1,64), (3,64), (4,64), (5,64), (8,64), (4,1), (4,33), (4,97)`。
最终 `logs/m2_vcs_matrix.log` 必须出现：

```text
M2 VCS matrix: 8/8 configurations passed
```

每个配置有独立 FSDB。查看非默认配置时，必须给仿真和 Verdi 相同参数：

```bash
make m2 M2_CONTEXTS=3 M2_WG_THREADS=64
make m2_verdi M2_CONTEXTS=3 M2_WG_THREADS=64
```

## 6. 运行失败时保留的证据

- 找不到 VCS / Verdi：加载本机的工具环境，然后重新运行 `make m2_env`。
- 找不到 PLI：检查实际 Verdi 根目录及上面的两个文件；`NOVAS_HOME` 不应指向旧安装。
- 编译错误：保留 `logs/m2_vcs_n4_wg64_compile.log` 中第一个错误及其上下文。
- license / 仿真 / assertion 错误：保留终端输出及 `logs/m2_vcs_n4_wg64.log`。
- 无 FSDB 或 Verdi 打不开：保留波形文件名、文件大小及工具输出。

仅做不生成波形的 VCS 仿真时，可显式运行 `make m2 M2_REQUIRE_FSDB=0`。
这个结果不包含 Verdi 波形验收。最终验收仍按默认 FSDB 流程运行。

本版已清除 M2 TB 中的全部 `$deposit` 和直接修改 DUT 寄存器的操作，
TB 对 DUT 内部状态只做读取和检查。RTL 保持 `always_ff`，不屏蔽多驱动诊断。
VCS2016 截图中的 `ICPD` 根因由此在验证端移除；实际编译仍以本机日志为准。

Workgroup ID 边界测试会从第 0 个 Workgroup 开始，通过正常的分配、调度、
DONE commit 和退休事件运行到 65536，并逐拍检查状态。它不再快进内部 cursor 或计数器，
所以仿真周期数会明显高于旧版。日志每经过 16384 个 Workgroup 输出一次 `[INFO]` 进度。

多个 Wave 的 Wait 使用单个 completion 端口逐拍完成，检查每个 Wave 的唤醒和确认；
多个 Wave 的同拍释放使用真正支持 multi-hot 的 `barrier_release_mask`。
补充 VCD 在长前缀期间暂停记录，跨越 65535 前恢复记录；FSDB 保留完整运行波形。
