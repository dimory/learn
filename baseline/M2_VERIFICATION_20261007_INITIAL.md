# M2 阶段复验：2026-10-07

> 历史初版：保留修复 `ICPD` 前的验证结果。本文件的快照操作和诊断豁免说明
> 不适用于当前工程；更新结果见 `M2_VERIFICATION_20261007.md`。

输入工程为本次上传的 `learn-main.zip`，有效工程入口是 `learn-main/baseline`。
本次重新编译和仿真这份源码，验证对象为 `wave_control_subsystem` 及其五个子模块。
没有运行单模块测试，也没有把尚在重写的 M3 Decoder 加入 M2 文件列表。

## 当前结论

| 检查 | 本次状态 |
| --- | --- |
| 工程文件列表、模块唯一性、package 顺序等 preflight | PASS |
| Icarus Verilog 12.0 的 M2 整体集成回归 | 8/8 配置 PASS |
| 场景组累计 / 模拟周期累计 / 参考模型检查累计 | 71 / 11,233 / 1,737,030 |
| Slang 12.0 的 M2 RTL 编译、展开及分析 | 0 errors；无额外诊断豁免 |
| Slang 12.0 的 M2 RTL + TB 检查 | PASS；测试快照操作的限定说明见下文 |
| Bash 语法及 Makefile 参数传递 | PASS |
| 启动诊断负向检查 | 5 项 PASS；没有脚本执行权限错误 |
| VCS2016 编译及仿真 | 未执行：当前环境未安装 |
| Verdi2016 打开 FSDB 和波形验收 | 未执行：当前环境未安装 |

补充工具的通过结果证明本次源码的 M2 功能回归通过。最终平台验收仍需要实际运行
VCS2016 和 Verdi2016；当前没有新生成的 FSDB。提供的本次波形为 Icarus VCD。

## 八个配置的本次结果

| Resident contexts | Threads / workgroup | 场景组 | 周期 | 检查次数 |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 64 | 8 | 705 | 48,042 |
| 3 | 64 | 9 | 659 | 81,902 |
| 4 | 64 | 9 | 661 | 100,700 |
| 5 | 64 | 9 | 693 | 125,010 |
| 8 | 64 | 9 | 768 | 203,148 |
| 4 | 1 | 9 | 6,235 | 947,948 |
| 4 | 33 | 9 | 774 | 117,876 |
| 4 | 97 | 9 | 738 | 112,404 |

单 Context 不运行多 Wave 同时唤醒场景，所以是 8 个场景组；其余配置是 9 个。
所有配置使用完整顶层、同一参考模型和协议检查器。

## 验证覆盖

- 零线程，以及 1、31、32、33、64、70、129、257 线程的分组、尾 Wave EXEC 和分配描述符。
- 表满时停止分配、执行端背压、RR 选择锁定与稳定的选中 Context。
- allocation、issue、commit、wait/barrier wakeup、DONE、retire 和 Wave ID 重用。
- PC、EXEC、VCC、SCC、M0 的独立 commit 写使能及不变的 dispatch 元数据。
- 七类 counter 的范围、同拍加减净值、上溢和下溢负向事件。
- 空 Wait、非零阈值、多类 Wait、completion 与 arm 同拍时使用沿前注册值。
- 多 Wave 唤醒 mask、不同 Entry 的并发事件、非阻塞依赖及未完成请求阻止退休。
- 非法 Wave ID / counter kind / 零 amount 的忽略行为。
- 背压和活动 Kernel 中异步复位，以及 Workgroup ID 跨越 65535。

真实 M3 执行端、M4 存储后端和 M5 Barrier Controller 由 TB 的带 Wave ID 事件代替。
这些接口事件是 M2 的阶段验证边界；本次没有执行真实指令程序。

## 本次修改

本次没有修改任何 RTL 或 TB 的功能代码。修改内容为：

1. Makefile 和 matrix 脚本通过 `bash` 调用 shell 文件，避免 ZIP 解压丢失执行权限后无法运行；同时恢复 shell 文件的可执行权限。
2. 添加 `make m2_env`，检查 VCS、Verdi 可执行文件和 Verdi VCS PLI 文件。
3. `make m2` 默认要求可用 FSDB PLI，避免功能仿真通过却没有可供 Verdi 检查的波形。
4. 添加 `M2_CONTEXTS` / `M2_WG_THREADS`，让仿真与 Verdi 使用相同参数。
5. 每个配置保留独立 VCS 可执行文件，新的运行清除该配置的过期日志和 FSDB。
6. 补充仿真脚本检查完整且匹配参数的 PASS 标识，并保存每个配置独立的 VCD。
7. 添加最终平台运行说明和 M3 学习断点文件。
8. 根据 14:14 的本机环境反馈，在 M2 VCS 编译参数中加入 `-lca`；已检查 Bash 语法，真实 VCS 结果仍待本机运行。

输入 ZIP 的原有 M2 日志保存在 `logs/archive_input_zip/`。本次仿真日志是
`logs/m2_n<N>_wg<P>.log`，本次机器可读结果是 `logs/m2_verification_1007.json`。
输入已有的 `M2_STAGE_REPORT.md` 是 10 月 3 日的历史报告，本报告对应 10 月 7 日复验。

## 测试快照与静态诊断说明

TB 用 `$deposit` 快进已完成的 65535 个 Workgroup，以及一次清零多个 Wave 的 LOAD counter
来验证 multi-hot wakeup 连线。后者是测试快照，不代表 M2 有多个真实 completion 输入端口。
Icarus 分支因数组 `$deposit` 限制使用验证端的直接赋值；最终 VCS 分支使用 `$deposit`。

Slang 的完整 TB 分析将这些快照操作识别为写入 `always_ff` 变量，产生 6 条多写诊断。
未豁免的输出保存在 `logs/m2_slang_tb_strict_1007.log`；完整 TB 的补充静态检查使用
`-Wno-multiple-always-assigns`，见 `logs/m2_slang_tb_1007.log`。
M2 RTL 单独分析没有使用这个选项，见 `logs/m2_slang_rtl_1007.log`。
VCS 脚本没有加入诊断屏蔽参数；是否存在其工具特定的编译问题，需要以真实 VCS2016 日志确认。

## 本次补充仿真的复现

安装 Icarus 12.0 后，在 `baseline` 目录运行：

```bash
python3 scripts/run_m2_iverilog.py --matrix --vcd
```

本次使用相同命令和文件列表，只通过 `--iverilog`、`--vvp`、`--ivl-dir` 指定了本地解包的工具路径。
这些工具和生成的可执行文件没有打入交付工程，VCS 会在你的机器重新编译。

最终平台的验收命令、信号分组和判读方法见 `M2_VCS2016_VERDI2016_GUIDE.md`。
