# M2 阶段复验：2026-10-07，VCS2016 TB 多驱动修复版

工程入口为 `learn-main/baseline`，来源是本次上传的 `learn-main.zip`。
本版处理 VCS2016 截图中的 `Error-[ICPD] Illegal combination of drivers`。
验证对象是完整 `wave_control_subsystem`、五个子模块和协议检查器；没有运行单模块测试。

## 修改与原因

1. 删除 M2 TB 中全部 `$deposit`、直接写 DUT 数组的 Icarus 分支，以及内部 dispatcher 计数器的快进操作。这些写入与 RTL 的 `always_ff` 构成了多个过程驱动，是截图中 `ICPD` 的根因。
2. Workgroup 边界用正常端口执行完整 Kernel：从 Workgroup 0 开始分配、调度、提交 DONE 和退休，真实跨越 65535→65536。长前缀的 DONE commit 不写 PC/EXEC 等字段，但每一拍仍经过完整参考模型和协议检查器。
3. 多 Wave Wait 测试逐拍使用单 completion 端口，核对每个 Wave 的唤醒及 `wait_active` 清除。同拍多 Wave 释放通过 `barrier_release_mask` 验证，不再通过强改 counter 构造 Wait 快照。
4. 保留 VCS 编译参数 `-lca`；不添加多驱动诊断屏蔽选项，不修改 RTL 的 `always_ff`。
5. 补充仿真脚本移除 `M2_IVERILOG` 宏，使用同一份 TB；单配置运行超时默认为 300 秒，可用 `--timeout` 调整。
6. 更新运行说明、验证报告和历史结果标记；保留此前的脚本权限、FSDB PLI、参数传递及 PASS 检查修复。

`baseline/rtl` 下 24 个 SystemVerilog 文件均与上传 ZIP 逐字节一致，包含 M2 RTL、package 及当前 M3 学习稿。
TB 仅通过 DUT 正常输入发送事件，对 DUT 内部对象只读取和检查。

## 当前结果

| 检查 | 状态 |
| --- | --- |
| M2 RTL + TB 的 Slang 12.0 严格编译、展开及分析 | 0 errors，0 warnings；无诊断豁免 |
| Icarus Verilog 12.0 的完整 M2 回归 | 8/8 配置 PASS |
| 累计场景组 / 模拟周期 / 参考模型检查 | 71 / 1,562,028 / 206,875,570 |
| 文件列表、模块唯一性、package 顺序等 preflight | PASS |
| M2 Bash 脚本语法、`-lca` 和无内部写入检查 | PASS |
| VCS2016 编译及仿真 | 未执行：当前环境未安装 |
| Verdi2016 FSDB 验收 | 未执行：当前环境未安装 |

源代码中的多驱动根因已移除，补充工具验证通过。实际 VCS2016 编译和 Verdi2016 波形验收由本机运行确认。
当前附带默认四 Context 配置的新 VCD，没有新生成的 FSDB。

## 八个配置

| Resident contexts | Threads / workgroup | 场景组 | 周期 | 检查次数 |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 64 | 8 | 524,948 | 35,696,566 |
| 3 | 64 | 9 | 175,395 | 21,749,166 |
| 4 | 64 | 9 | 131,706 | 20,019,540 |
| 5 | 64 | 9 | 131,741 | 23,713,650 |
| 8 | 64 | 9 | 131,816 | 34,799,820 |
| 4 | 1 | 9 | 71,755 | 10,906,988 |
| 4 | 33 | 9 | 131,821 | 20,037,020 |
| 4 | 97 | 9 | 262,846 | 39,952,820 |

单 Context 不运行多 Wave Wait/Barrier 场景，因此为 8 组；其余为 9 组。
所有配置均执行正常接口驱动的完整 Workgroup 边界，运行周期明显高于旧版快照测试。

## 覆盖与边界

- 零线程；1、31、32、33、64、70、129、257 线程的分组、尾 Wave EXEC 和分配描述符。
- 表满停止分配、背压期间 RR 锁定及稳定 Context、Wave ID 重用和不同 Entry 的并发事件。
- allocation、issue、commit、Wait/Barrier 唤醒、DONE、retire 和 Kernel 完成统计。
- PC、EXEC、VCC、SCC、M0 的独立 commit 写使能及固定 dispatch 元数据。
- 七类 counter 的范围、同拍加减净值，以及上溢/下溢非法事件的忽略行为。
- 空 Wait、非零阈值、多类 Wait；completion 与 arm 同拍时使用沿前注册值。
- 多 Wave 的逐拍 Wait 唤醒、真实 multi-hot Barrier release、非阻塞依赖及未完成请求阻止退休。
- 非法 Wave ID、counter kind、零 amount，及背压/活动 Kernel 中的异步复位。
- 从 Workgroup 0 到 65536 的分配、退休、描述符和总数检查，未跳过前缀。

真实 M3 执行端、M4 存储后端和 M5 Barrier Controller 由 TB 带 Wave ID 的接口事件代替；
本次属于 M2 阶段验证，没有执行真实指令程序。当前单 completion 输入不作为多完成端口使用。

## 日志与波形

- 本版回归：`logs/m2_n<N>_wg<P>.log`、`logs/m2_results.json`、`logs/m2_verification_1007.json`。
- 严格静态结果：`logs/m2_slang_tb_strict_fixed_1007.log`，未使用 `-Wno-multiple-always-assigns`。
- 默认新波形：`waves/tinygpu_m2_n4_wg64.vcd`。长前缀期间暂停 VCD，在 Workgroup 65535 前恢复；VCS FSDB 流程记录完整运行。
- 原输入日志：`logs/archive_input_zip/`；修复前结果：`logs/archive_before_icpd_fix/`、`waves/archive_before_icpd_fix/`。
- `M2_STAGE_REPORT.md` 和 `M2_VERIFICATION_20261007_INITIAL.md` 仅为历史记录。

## 本机最终平台运行

加载已有 VCS2016 + Verdi2016 环境后，在 `baseline` 目录执行：

```bash
make m2_env
make preflight
make m2
make m2_verdi
make m2_vcs_matrix
```

`make m2` 和矩阵使用同一脚本，均包含 `-lca`；默认要求 FSDB PLI。
边界测试每经过 16384 个 Workgroup 输出一次 `[INFO]` 进度。
完整平台说明见 `M2_VCS2016_VERDI2016_GUIDE.md`。

补充回归复现：

```bash
python3 scripts/run_m2_iverilog.py --matrix
python3 scripts/run_m2_iverilog.py --contexts 4 --wg 64 --vcd
```

本次仅用 `--iverilog`、`--vvp`、`--ivl-dir` 指定本地 Icarus 12.0 路径。
工具安装和生成的 simulator executable 不包含在 ZIP 中。
