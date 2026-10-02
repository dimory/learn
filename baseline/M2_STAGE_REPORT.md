# TinyGPU M2 阶段验证报告

日期：2026-10-03（北京时间）。输入工程：用户上传的 `baseline_1003.zip`。
最终验收平台：**VCS2016 + Verdi2016**。

## 阶段结论

M2 的五个功能模块已经完成并通过 `wave_control_subsystem.sv` 集成。
整体 M2 回归的 8 组参数配置全部通过；M1 的六个 Pattern 和 Legacy UOP
opcode 0–9/F 覆盖检查也全部通过。

这里实际使用 **Icarus Verilog 12.0** 运行 M2、**Verilator 5.020** 运行 M1。
本环境没有 VCS2016/Verdi2016，因此最终平台的编译、仿真和 FSDB 打开
尚未执行。这些结果可以作为 M2 功能完成的阶段证据；不能标记为已经通过
VCS2016 平台验收。工程已提供该平台的默认配置、参数矩阵和波形入口。

## 本次修改

| 文件 | 修改及原因 |
| --- | --- |
| `rtl/wave_sheduler.sv` → `rtl/wave_scheduler.sv` | 统一文件名；修正 `aalways_comb`；移除组合输出的 `rst_n` 判断，保留寄存器异步复位 |
| `rtl/wave_retire_controller.sv` | 上传版本仍为框架，补入最低 ID 优先的首项选择逻辑；退休条件为 DONE 且七类 counter 全部为零 |
| `rtl/gpu_pkg.sv` | `CDNA_WORKGROUP_ID_BITS` 从 16 扩为 32，避免 WG ID 超过 65535 后回绕，匹配默认 32 位线程数量接口 |
| `rtl/wave_control_subsystem.sv` | 新增纯连线 Top，连接五个 M2 模块，没有新增寄存器或状态机 |
| `tb/tb_wave_control_subsystem.sv` | 新增整体控制子系统 TB、整数参考模型、定向场景及固定种子随机事件 |
| `tb/m2_protocol_checker.sv` | 新增仿真协议检查，包括状态 mask 分区、握手对象、Wait/Commit 对齐、停顿稳定和安全退休 |
| `sim/filelist_m2_*.f`、`scripts/`、`Makefile` | 新增独立 M2 编译、回归、Verdi 入口及补充工具入口 |

上传的原始文件未在本地解压工作目录之外被改写。M1 执行 RTL保持原样；
`gpu_pkg.sv` 的上述 M2 公共宽度更新已随完整 M1 回归检查。
完整源代码变更见 `M2_CHANGES.patch`。

## 集成连线和外部协议

| 事件/数据 | 连接关系 |
| --- | --- |
| Allocation | Dispatcher 输出 Descriptor；Context Table 提供 FREE ID/ready；`alloc_fire` 同时初始化 Table 与 Tracker |
| Scheduling | Scheduler 输出 selected ID/valid；外部执行端提供 ready；`schedule_fire` 驱动 Table 的 READY → ISSUED |
| Context read | Scheduler 的 ID 直接连接 Table 读口，架构数据送出 Top |
| Wait wakeup | `waitcnt_mask & wait_satisfied_mask` 同时送 Table 与 Tracker；WAITCNT → READY，并清除 `wait_active` |
| Retirement | Retire Controller 输出 release ID/valid 给 Table 与 Tracker，completion 给 Dispatcher |

真实执行端和后端尚未接入。TB 为这些接口提供 synthetic events，验证 M2
对接收事件的反应，而不是执行真实 M3 指令。

Wait 指令在提交沿同时提供 `commit_valid`、`wait_arm_valid` 和相同 Wave ID。
执行端根据 `wait_arm_satisfied` 选择 `commit_next_state=READY/WAITCNT`；
Top 不生成 Commit 下一状态。`wait_arm_valid` 不得依赖该 satisfied 输出。
Wait query 使用当前寄存器 counter：同沿 completion/arm 后的 count 满足条件时，
先进入 WAITCNT，再由下一沿的 wakeup 恢复 READY。

保持已约定的简洁 RTL：组合逻辑不判断复位；Wait 存储只采用 reset > arm >
wakeup > hold，不增加 alloc/release 清除配置。失效配置不参与判断；下一次
arm 覆盖全部配置。FREE/DONE 不允许保留有效 Wait，由验证端检查系统协议。
Counter 继续采用 reset/release/alloc 初始化，并在净结果越界时保持原值。
正常流量必须符合容量协议，负向测试单独检查越界保护行为。

## 已执行的 M2 参数矩阵

所有配置使用完整的五模块 Top。单 Context 配置跳过多 Context 的 multi-hot
场景，运行 8 个场景组；其他配置各运行 9 个场景组。

| Context 数 | 每 Workgroup 线程数 | 场景组 | TB cycles | TB checks | 结果 |
| ---: | ---: | ---: | ---: | ---: | --- |
| 1 | 64 | 8 | 705 | 48,042 | PASS |
| 3 | 64 | 9 | 659 | 81,902 | PASS |
| 4 | 64 | 9 | 661 | 100,700 | PASS |
| 5 | 64 | 9 | 693 | 125,010 | PASS |
| 8 | 64 | 9 | 768 | 203,148 | PASS |
| 4 | 1 | 9 | 6,235 | 947,948 | PASS |
| 4 | 33 | 9 | 774 | 117,876 | PASS |
| 4 | 97 | 9 | 738 | 112,404 | PASS |

证据：`logs/m2_results.json` 和 `logs/m2_n<N>_wg<P>.log`。
默认配置的完成签名：

```text
TinyGPU M2: ALL 9 SCENARIO GROUPS PASSED N=4 WG=64 cycles=661 checks=100700
```

## M2 规格场景覆盖

| 规格编号 | 本阶段检查 |
| --- | --- |
| M2-01 | 零线程无分配，done 为单周期 |
| M2-02、03 | 1/31/32/33/64/70/129/257 threads 的 Descriptor、部分 Wave EXEC、WG 元数据 |
| M2-04 | 执行端停顿填满 Context；分配等待；释放后继续派发 |
| M2-05、06 | 每次 RR 选择与参考模型一致；背压期间 ID 和完整架构 payload 稳定 |
| M2-07 | Counter 非零时可回 READY，其他 Wave 和后端事件继续推进 |
| M2-08 | 空 mask、零及非零阈值、七类组合 Wait、输入变化后保存的配置仍生效 |
| M2-09 | 七类 counter 同周期增减净变化、边界值；KM 独立 5 位范围；负向越界保持 |
| M2-10 | Barrier 状态保持，显式 release mask 后恢复 READY |
| M2-11、12 | DONE 有 outstanding 时保持，清零后才能退休并统计完成 |
| M2-13 | ID 重用、架构初始化、counter 清零、无有效旧 Wait 继承 |
| M2-14 | 分配/完成统计，最后一次安全退休后 Kernel done，连续 Kernel |
| M2-15 | M1 六 Pattern 与 Legacy UOP coverage 全部 PASS |

额外检查：非 2 的幂 Context 数、非法 ID/kind、非 resident 事件、零 amount、
错误状态 Commit、停顿锁定时异步复位、运行中带 Wait/issued 状态的异步复位，
以及 Workgroup ID 从 65535 进入 65536。

两个边界场景采用 **仅在 TB 中的 backdoor deposit**：WG 边界场景跳过已经完成的
前缀，真实运行跨边界的尾段；multi-hot wakeup 场景构造多个已满足的 counter
快照，检查 wake mask 同时被两个模块消费。M2 的生产接口仍只有单 completion
event port，常规逐次 completion 通过正常接口测试。RTL 没有加入测试旁路。
VCS 编译使用 `$deposit`，避免 TB 成为 `always_ff` 寄存器的第二个过程驱动。
Icarus 的 `vpiMemoryWord` 不支持 deposit，只有其补充运行入口通过
`M2_IVERILOG` 宏启用 counter snapshot 的直接赋值替代；该分支不编入 VCS。

没有重新执行单模块测试。上传的 `tb_wave_dependency_tracker.sv` 保留，但不在
本次 M2 TB filelist 中。

## 静态检查和 M1 结果

Preflight、Shell/Python 语法和 Make 入口检查通过。Slang 12 全 RTL/TB
展开检查：M2 0 errors / 258 warnings，M1 0 errors / 24 warnings。
警告主要涉及整数参考模型、扫描索引和位宽间的符号/宽度转换；完整诊断
保存在 `logs/m2_slang_final.log` 与 `logs/m1_slang_final.log`。

M1 实际仿真结果：mat_add、partial_block、mat_mul、divergence、bank_conflict、
zero_thread 全部 PASS；Legacy UOP opcode 0–9/F coverage PASS。
证据：`logs/m1_regression.log`。Icarus 在旧 M1 的 unpacked port 处理处发生工具
内部异常，因此 M1 使用 Verilator 运行，未修改 Legacy RTL 绕过该异常。

## VCS2016 + Verdi2016 最终验收入口

使用原有工具环境，`vcs` 和 `verdi` 在 PATH 中；`NOVAS_HOME` 或 `VERDI_HOME`
指向 Verdi2016。脚本检测 `share/PLI/VCS/LINUX64/novas.tab` 与 `pli.a` 后启用 FSDB。

```bash
make preflight
make m2
make m2_verdi
make m2_vcs_matrix
make sim
make verdi
```

`make m2_vcs_matrix` 执行同一组 8 个配置；每次必须有完整 PASS 签名，失败立即
停止。日志存于 `logs/m2_vcs_n<N>_wg<P>*.log`，矩阵总结为
`logs/m2_vcs_matrix.log`。每组 FSDB 单独保存，默认配置由 `make m2_verdi` 打开。
其他配置例如：

```bash
./scripts/run_m2_vcs.sh 3 64
./scripts/open_m2_verdi.sh 3 64
```

当前附带的 VCD 是已通过的 **N=4、WG=97** 回归波形：
`waves/tinygpu_m2_n4_wg97.vcd`；它不代表已经生成 Verdi2016 FSDB。

下一阶段是 M3：真实 Wave-tagged Fetch/Decode/Execute、架构寄存器与 Scoreboard，
接入本 Top 的 launch/commit 接口。真实访存、完整 Barrier 和 Tensor 数据通路
仍按 M4/M5/M6 计划推进。
