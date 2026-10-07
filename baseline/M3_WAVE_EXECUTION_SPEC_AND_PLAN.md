# TinyGPU M3：真实 CDNA5 Wave 执行规格与实施计划

版本：1.0；日期：2026-10-02。工程依据：已完成 M2 阶段回归的 `baseline_1003.zip`。

本文件是 M3 的实现与验收计划，尚未表示这些模块已经生成或通过验证。最终验收工具固定为 **VCS2016 + Verdi2016**。

## 1. 阶段目标与规格依据

M3 完成一条可执行真实 CDNA5 指令子集的多 Wave 通路：机器码取指、译码、寄存器读取、执行、写回、架构提交及访存依赖通知。M2 的事件驱动接口由这条真实 RTL 通路接管。

指令规范以 AMD《CDNA5 Instruction Set Architecture: Reference Guide》，2026-07-27 版为准。Kernel 参数的 User SGPR 布置参考 LLVM AMDGPU ABI 文档；发生代际差异时，以 CDNA5 本代的启动状态和编码规定为准。禁止默认把 CDNA5 当作某个旧 GCN/RDNA 编译目标。

规格分两层：

- **架构行为**：已支持指令的编码、运算、地址、标志位、EXEC、Wait 和启动状态遵守真实 ISA。
- **本项目实现参数**：物理 SIMD4、4 个常驻 Context、队列深度、RF 端口和发射带宽是本项目的选择。它们影响吞吐与容量，不代表 AMD 芯片内部结构或周期行为。

阶段结束应能运行真实机器码的整数向量加法、条件分支循环、标量参数加载、Global/LDS 数据读写，以及带未完成请求的 End-program。存储模型只提供指令字和内存响应，不生成 uop、commit 或 dependency 事件。

## 2. M3 与后续阶段的边界

| 阶段 | 本阶段负责的内容 |
| --- | --- |
| M3 | Wave-tagged Fetch/Decode、SGPR/VGPR、初始化、Scoreboard、操作数收集、SALU/VALU/Control、访存指令与标签管理、Writeback/Commit |
| M4 | 将 M3 的 Wave 访存命令接到真实 Coalescer、Transaction Queue、Load Return Router、LDS Bank、Scalar Memory 与 Cache 接口 |
| M5 | Workgroup 资源和真实 Barrier 协议、Named/Cluster Barrier 的支持范围、EXEC 路径管理和 Divergence/Reconvergence |
| M6 | 按本代编码实现 Matrix/WMMA/Tensor/TDM，并补齐所需数值运算、格式转换及 LDS 双缓冲 |

M3 不把完整 Cache、虚拟地址翻译、XNACK replay、Trap handler、AQL/ELF 加载器、浮点/SFU 或 Matrix 放入退出条件。程序限制在明确支持的子集内；遇到未支持指令或配置，报告具体故障。不能作为 NOP 静默执行。

M4 替换外部内存模型时，应保留 M3 的寄存器和提交协议；M5/M6 增加相应生产者。M3 不为将来的内部结构预设未经核实的 AMD 实现细节。

## 3. 默认硬件配置

| 项目 | M3 默认值与约束 |
| --- | --- |
| 数据元素 | 32 bit；64 bit 数据通过两个元素组织 |
| 地址接口 | 64 bit 字节地址；本阶段外部模型使用已映射地址 |
| PC 存储容器 | 沿用 64 bit；有效 PC 为 [56:0]，高 [63:57] 为 0、低 [1:0] 为 0；入口检查在 launch 接口集中完成 |
| Wave | Wave32；32 个逻辑 lane |
| EXEC/VCC 容器 | 沿用 64 bit；本阶段 Wave32 的运算与归约使用低 32 bit |
| 物理向量通路 | SIMD4；完整 Wave 分 8 个 beat 处理 |
| 常驻 Context | 默认 4；回归包含 1、3、4、8 |
| 初始寄存器容量 | 每个常驻 Wave 32 个 SGPR、64 个 VGPR；这是支持的分配容量，不是 ISA 寄存器编号上限 |
| RF 读写 | 同步读，1 cycle 读延迟；SGPR 2R1W；VGPR 四个 lane bank，每 bank 2R1W |
| 同一 Wave 前端 | 最多一条尚未架构提交的指令；保持 M2 的 ISSUED 约束 |
| 不同 Wave | 可以同时有取指、等待操作数、执行和长延迟访存工作 |
| 架构 commit | 每个上升沿最多 1 个 |
| 访存请求 | 每个上升沿最多接受 1 条完整指令命令；不按 lane 增加依赖计数 |
| 访存标签 | 默认 16 个活动槽；沿用 8 bit transaction ID，默认槽号占低 4 bit |
| 返回缓冲 | 默认 4 项，满时通过 ready 反压 |
| 依赖通知 | 每个上升沿最多 1 个 issue 事件和 1 个 complete 事件，可同沿发生 |
| Workgroup | 默认 64 threads；支持现有 M2 的 1D 派发和尾部 Wave；合法大小上限 1024 |
| LDS 分配 | 模型容量参数默认每 Workgroup 4096 bytes，launch 分配量不得超过配置容量；M3 按 Workgroup 隔离，M4 再实现物理分配 |

RF 写口由统一 Writeback 仲裁，初始化、普通运算及 Load 返回共享。基础版不加读后写旁路：相关指令可以多等一个 cycle，结果必须正确。

同一条向量指令的收集、执行、写回各自需要多个 beat，不能把“单发射口”解释为“每 cycle 完成一条 Wave 指令”。

## 4. 真实启动状态与寄存器初始化

### 4.1 支持的 launch 配置

M3 接收驱动已经解析的启动信息，保留 M2 的 `start/start_pc/thread_count`，增加：

| 新输入 | 位宽 | 含义 |
| --- | --- | --- |
| `launch_user_sgpr_count` | 6 | 要初始化的连续 User SGPR 数量，支持 0..32 |
| `launch_user_sgpr_data` | 32 × 32 packed bits | 由驱动按 Kernel 描述信息准备的 User SGPR 值；第 i 个元素写入 si |
| `launch_dispatch_index` | 25 | 本次 dispatch 的启动字段，用于构造 TTMP8 |
| `launch_group_segment_bytes` | 32 | 每 Workgroup 的 LDS 分配字节数 |

`launch_accept = start && !busy && !done`，与当前 Dispatcher 的 IDLE/RUN/DONE 定义对应。所有 launch 数据在该事件捕获，在本次 Kernel 内保持。暂不支持 cluster、scratch 或 `tg_size_en` 附加 SGPR。

常用 Kernel 参数配置只开启 kernarg 指针：s0/s1 保存 kernarg 地址低/高 DWORD。其他 User SGPR 可以由驱动按真实描述信息启用；不擅自插入全局线程号或 Workgroup ID。

### 4.2 本代必须使用的初始化值

CDNA5 初始状态规定：v0 为 packed 的 Workgroup 内 X/Y/Z 坐标；1D 配置下可写为 `{22'b0, local_x[9:0]}`。Grid X 来自 TTMP9，TTMP8 包含 Wave-in-group 和 dispatch index。普通 shader 可以读取 TTMP，写入权限属于 privileged mode。[S1：3.4.10、3.5]

因此采用：

- `local_x = workgroup_wave_index * 32 + lane_id`，初始化 v0。
- `TTMP9 = workgroup_id`，在 1D、无 cluster 模式下从已有 Context 元数据提供。
- `TTMP8 = {1'b0, 1'b0, workgroup_wave_index[4:0], saved_dispatch_index[24:0]}`。
- TTMP8/9 在用户模式只读，值可由快照构造，无需增加通用 TTMP RF。其他 TTMP/privileged 功能不进入本阶段子集。
- 程序自行计算 `global_x = workgroup_id * workgroup_size + local_x`；默认 WG64 可以用移位，非 2 的幂大小可用标量乘法。

未指定初始化的 SGPR/VGPR/LDS 不保证为零。不对 RF 数据数组做复位或 alloc 全量清零。M2 已经选择的其他控制寄存器初值不作为 Kernel ABI 的软件保证；验证器跟踪“已定义”状态，程序必须先写再读未定义值。

`wave_register_init` 为每个已 alloc Wave 保存初始化进度，逐一写入启用的 User SGPR 和 v0。最后一次 RF 写完成后置 `rf_initialized_mask[wave_id]`。READY Context 只有初始化完成才进入 Scheduler 候选集合。

## 5. 指令支持清单

以下列出的 **45 条指令** 为 M3 必须实现的子集。opcode 和 field 位号按 [S1] 冻结成 manifest，不在计划中复写整套 ISA 表。

| 类别 | 必须支持的真实指令 |
| --- | --- |
| Scalar move | `S_MOV_B32`、`S_MOV_B64` |
| Scalar integer | `S_ADD_CO_U32`、`S_SUB_CO_U32`、`S_MUL_I32` |
| Scalar bit/shift | `S_AND_B32`、`S_OR_B32`、`S_XOR_B32`、`S_LSHL_B32`、`S_LSHR_B32` |
| Scalar compare | `S_CMP_EQ_U32`、`S_CMP_LT_U32` |
| Vector move/integer | `V_MOV_B32`、`V_ADD_NC_U32`、`V_SUB_NC_U32` |
| Vector bit/shift | `V_AND_B32`、`V_OR_B32`、`V_XOR_B32`、`V_LSHLREV_B32`、`V_LSHRREV_B32` |
| Vector compare | `V_CMP_EQ_U32`、`V_CMP_LT_U32`，先实现 VOPC 编码 |
| Control | `S_NOP`（SIMM16=0）、`S_ENDPGM`、`S_BRANCH` |
| Conditional branch | `S_CBRANCH_SCC0/1`、`S_CBRANCH_VCCZ/NZ`、`S_CBRANCH_EXECZ/NZ` |
| Single counter Wait | `S_WAIT_LOADCNT`、`S_WAIT_STORECNT`、`S_WAIT_DSCNT`、`S_WAIT_KMCNT`、`S_WAIT_ASYNCCNT`、`S_WAIT_TENSORCNT`、`S_WAIT_XCNT` |
| Combined Wait | `S_WAIT_LOADCNT_DSCNT`、`S_WAIT_STORECNT_DSCNT` |
| Scalar memory | `S_LOAD_B32` |
| Global memory | `GLOBAL_LOAD_B32`、`GLOBAL_STORE_B32` |
| LDS | `DS_LOAD_B32`、`DS_STORE_B32` |

支持 SOP1/SOP2/SOPC/SOPP、VOP1/VOP2/VOPC、SMEM、VGLOBAL、VDS 对应形式。VOP3 别名、DPP、VOPD、间接寄存器、额外高 VGPR 编号模式和未列出的运算后移。

操作数支持容量内 SGPR/VGPR、已实现的特殊寄存器、NULL、整数 inline constant、32/64 bit literal。64 bit literal 在支持的短 ALU 格式中使指令占 3 DWORD；32 bit 运算取相应低位。S_MOV_B64 基础范围为普通 SGPR pair 与立即数；特殊寄存器的 B64 变体暂不纳入子集。

标量 B32 路径包括 EXEC_LO、VCC_LO、M0 的适用读写，SCC 源，以及 TTMP8/9 读取。NULL 目的操作不写 GPR，仍保留该 opcode 的其他效果。高半 mask 操作及 TTMP 写入不在本阶段配置内，须按“子集未支持”报告，不能误称其为整个 ISA 的非法编码。

程序使用 Wait 遵守真实依赖规则。Scoreboard 是本项目的数据通路互锁实现，采用保守 RAW/WAW 阻塞；不宣称这就是 AMD 的内部 Scoreboard 结构。

## 6. 必须冻结的执行语义

### 6.1 取指与 PC

Fetch 保存 wave_id、原 PC、EXEC/VCC/SCC/M0 和 Workgroup 元数据快照。每个 Wave 一个组装槽；同一个 Wave 同时只保留一个未完成 DWORD 请求，不同 Wave 的响应可乱序。

先读 DWORD0，`cdna_instruction_info` 判定格式、所需后续字和 literal，再发后续请求。基础组装宽度 96 bit，支持 1/2/3 DWORD；VGLOBAL 需要 3 DWORD，SMEM/VDS 需要 2 DWORD。[S1：4.1、14]

顺序地址 `pc_sequential = pc + 4 * inst_dwords`；SOPP taken 地址 `pc_taken = pc + 4 + sign_extend(SIMM16) * 4`。写回 PC 截取有效位并保持 DWORD 对齐；本阶段不处理超出已映射程序范围的跳转恢复。没有本 Wave 的下一条 speculative fetch，所以分支提交前不产生需要冲刷的同 Wave 后继指令。

### 6.2 标量、向量与相关性

- Scalar 指令在 EXEC=0 时仍执行。向量运算只修改发射时 EXEC 选中的 lane。
- Scalar add 设置 carry；unsigned subtract 的 SCC 按 ISA 的 borrow 定义处理；逻辑运算、比较及 move 的 SCC 效果逐 opcode 实现。
- V_CMP 汇总 active lane 比较结果，并按 ISA 生成 VCC_LO。VCCZ/EXECZ 的 Wave32 归约只使用低 32 bit。
- Scoreboard 的 SGPR busy 位按 DWORD，VGPR busy 位按整条逻辑 VGPR。检查 RAW 与 WAW，64 bit 源/目的检查整个寄存器 pair。
- 目的 busy 仅在 `execute_issue_fire` 分配；最后一次实际 RF 写完成后清除。普通 ALU 指令必须完成所需 RF 写，才允许架构提交释放 Wave。
- 每 Wave 的 decoded slot 保持 ISSUED；一个等 Load 的 Wave 不能占据全局 FIFO 头，阻止其他 Wave 进入就绪执行单元。
- 同 Wave 的上下文写入由 ISSUED 和 commit 串行化，基础版不重复添加 SCC/EXEC/VCC/M0 的 busy 状态。

### 6.3 访存寻址范围

| 路径 | M3 支持的地址形式 |
| --- | --- |
| Global GV | SADDR=NULL；VGPR pair 64 bit 地址 + signed IOFFSET24 |
| Global GVS | SGPR pair base + signed VGPR32 offset + signed IOFFSET24；SCALE_OFFSET=0 |
| SMEM | SGPR pair base + signed IOFFSET24；SOFFSET=NULL，SCALE_OFFSET=0 |
| LDS | VGPR32 byte offset + unsigned IOFFSET16；Workgroup ID 指定共享空间 |

B32 访存的阶段测试使用自然对齐地址。请求保存地址、写数据、active mask、Workgroup ID、目的寄存器和原指令 PC；不依赖以后变化的寄存器值。

Cache scope/hint 等字段的基础接受配置在编码 manifest 中逐格式列明。暂不接受需要额外机制的 modifier；不能把这些位全部忽略后宣称执行完整指令。

### 6.4 counter、返回与排序

M3 有四类真实生产者：Global Load→LOAD，Global Store→STORE，DS Load/Store→DS，S_LOAD_B32→KM。本阶段每条有效命令的 amount=1。

Tag 在访存单元接受已收集的指令时预留；外部 `mem_req_valid && mem_req_ready` 才产生 dependency issue 和正常 memory-instruction 的提交资格。反压期间请求及 Tag 保持。reserved、sent、response-received、RF-written、counter-notified 是独立阶段。

Load 返回可按 transaction ID 乱序接收和写 RF；counter complete 不能直接等同于 response 到达。LOAD/STORE/DS 用每 Wave、每 kind 的顺序号保证通知顺序；KM 的本阶段标量读允许乱序通知。数据写入完成后，该 Tag 才满足 complete 条件。[S1：5.7]

示例：Wave0 先发 Load A→v10，再发 Load B→v11，LOAD=2。B 先回来可以写 v11，但此时不能把 LOAD 减到 1；`S_WAIT_LOADCNT 1` 必须仍阻塞。A 的 RF 写完成后先通知 A，再通知已经完成的 B。

默认 Tag 16 项、amount=1，使每 Wave 未通知的真实依赖数量始终不超过 16，低于包括 KM 在内的计数范围。Tag 满时停止接受新访存，不能先溢出再依赖 counter 的保护逻辑补救。扩大标签容量或增加大尺寸 SMEM 时必须重新设计加权 credit。

Tag 在 complete 通知发出的上升沿释放。每个后端请求只能产生一次响应、一次 complete；Store complete 必须建立在写操作已经完成的 ack 上。同 Wave、同地址的 Store/Load 顺序由后端模型及后续 M4 保证。

Load 使用 **请求时保存的 EXEC** 写回。即使 Wave 后续改变 EXEC，返回也不能改用当前 mask。向量 EXEC=0 时不发实际命令、不分配 Tag、不增加 counter，但仍完成该指令的 PC 提交；SMEM 不受该跳过规则影响。

### 6.5 Wait、End-program 与故障

Wait 解码生成七类选择 mask 和对应阈值：单类取 SIMM16 的实际 6 bit，KM 取 5 bit；组合 Wait 取 LOAD/STORE 的 [13:8] 和 DS 的 [5:0]。未实现的 ASYNC/TENSOR 生产者不制造事件；XNACK 关闭配置按真实 Wait-X 行为处理。

`wait_arm_valid = commit_fire && is_wait`，同沿提供相同 wave_id。根据 tracker 的 `wait_arm_satisfied`，Commit 产生 READY 或 WAITCNT；PC 只前进一次。已满足也发 arm，使现有 tracker 行为保持一致。

commit 的仲裁和 fire 不等待 `wait_arm_satisfied`，该信号只选择 next-state，防止组合环。同沿 complete 若使条件成立而查询仍看到旧 count，允许先进入 WAITCNT、随后由 wakeup 恢复；不能提前漏等。

`S_ENDPGM` 提交 DONE，Retire 继续由 M2 的 DONE && all_counters_zero 决定。不要求软件在 End 前人为清空所有请求；真实请求必须排空后才回收 Context/RF。验证器同时检查该 Wave 没有残留 Tag、busy 或前端所有权。

故障输出含 sticky `fault_valid`、wave_id、原 PC、opcode/first DWORD 和原因码。区分未支持子集、非法编码、RF 容量越界、launch 配置及外部存储错误。故障后停发新前端工作，已有合法访存返回继续排空；Kernel 不产生成功 done，复位清除故障。完整 Trap/恢复协议后续增加。

## 7. 模块划分

共 **14 个功能模块 + 2 个结构 Top**。已有 `rtl/wave_lsu.sv` 属于旧通路，新访存模块采用 `wave_memory_unit.sv`，避免同名覆盖。

| 编号 | 新模块 | 主要输入 → 输出与职责 |
| --- | --- | --- |
| F01 | `cdna_instruction_info.sv` | 首字/已取 literal 信息 → 格式、字数、下一 DWORD 请求；与 Decoder 共用编码常量 |
| F02 | `wave_instruction_fetcher.sv` | M2 selected Context、imem response → 完整指令包；保存 wave_id、原 PC 和上下文快照 |
| F03 | `cdna_decoder.sv` | 真实指令字 → `decoded_uop_t`、合法性及未支持原因 |
| F04 | `wave_instruction_buffer.sv` | decoded packet → 每 Wave 一个待执行槽；阻塞槽不拦住其他 Wave |
| F05 | `wave_sgpr_file.sv` | 统一读请求/写请求 → 该 Wave SGPR 数据；支持 pair 分解 |
| F06 | `wave_vgpr_file.sv` | Wave/寄存器/beat 读写 → 4 lane 数据；按 lane mask 保留 inactive 数据 |
| F07 | `wave_register_init.sv` | alloc 元数据、保存的 launch 数据 → RF 初始化写包、`rf_initialized_mask` |
| F08 | `wave_scoreboard.sv` | decoded 源/目的、issue、最终 writeback → 源 ready、目的可用、busy 生命周期 |
| F09 | `wave_operand_collector.sv` | 每 Wave 槽、Scoreboard、RF response、单元容量 → 完整操作数包、`execute_issue_fire` |
| F10 | `wave_salu.sv` | Scalar 操作数及 uop → SGPR/特殊状态结果与 SCC；整数和位运算 |
| F11 | `wave_valu.sv` | Wave32 操作数和保存的 EXEC → 8 beat SIMD4 结果或 VCC mask |
| F12 | `wave_control_unit.sv` | Branch/NOP/Wait/End uop 与快照 → next-PC、Wait 配置或 End 提交描述 |
| F13 | `wave_memory_unit.sv` | 访存 uop/已收集数据、mem response → mem request、返回写包、dependency issue/complete、访存提交描述 |
| F14 | `wave_writeback_commit.sv` | SALU/VALU/Load/Init 结果及 Control/Memory 提交描述 → RF 写、Scoreboard clear、M2 commit/Wait arm |
| T01 | `wave_execution_subsystem.sv` | F01..F14 纯结构连线，连接 M2 执行接口和外部 imem/memory |
| T02 | `wave_compute_top.sv` | M2 Control + T01 + launch/fault/存储接口，成为 M3 阶段回归顶层 |

F13 内部分四步编写：命令保存与 Tag 预留、请求发送、返回匹配和 RF 写包、按顺序发 complete。基础版先集中在一个模块，M4 再沿明确接口抽取后端结构。

F14 的 RF 仲裁以完整结果包为单位轮转并锁定，避免一个 Wave 的 8 beat 被另一个 packet 替换。Init/Load 最后一拍只完成 RF 与 busy 生命周期；普通运算最后一拍还要获得 commit 资格。Control/访存接受的提交描述也参与 commit 仲裁，必须保持到实际消费。

普通结果的最后 RF 写与架构 commit 采用同沿完成规则；若 commit 未获仲裁，则暂停最后一拍，不能重复写或提前把 Wave 变为 READY。异步 Load 返回不更新 PC。

## 8. 关键接口和事件所有权

`*_valid/*_ready` 都是电平；每个上升沿 `valid && ready` 成立就是一次传输，连续多个 cycle 成立代表连续传输。事件端口没有 ready 时，生产者只对每个被接受操作发一个 cycle 的事件；相邻 cycle 可以分别代表不同操作。

| 接口/事件 | 最终来源 | 目的模块 | 内容或生效条件 |
| --- | --- | --- | --- |
| `selected_valid/context` | M2 Scheduler + Context Table | Fetcher | 选中 Wave 的完整快照 |
| `selected_ready` | Fetcher | M2 Scheduler | 该 Wave 组装槽有空间且能捕获本次工作 |
| `schedule_enable_mask` | Register Init 与全局 halt 控制 | M2 Top → Scheduler | READY 且已初始化的 Wave 才可选 |
| `schedule_fire` | M2 Top 的 selected 握手 | Context Table + Fetcher | READY→ISSUED，并建立前端所有权 |
| `imem_req_valid/ready` | Fetcher / 指令存储接口 | 指令存储 / Fetcher | wave_id、word_index、word byte address |
| `imem_rsp_valid/ready` | 指令存储 / Fetcher | Fetcher / 指令存储 | wave_id、word_index、DWORD、error |
| `decoded_valid/ready` | Decoder / per-Wave Buffer | Buffer / Decoder | wave_id + uop + 原始上下文快照 |
| `execute_issue_fire` | Operand Collector 与目标单元握手 | 单元 + Scoreboard | 真正消耗操作数并预留目的 busy |
| `mem_req_valid/ready` | Memory Unit / M4 或 M3 内存模型 | 存储后端 / Memory Unit | Wave 命令、Tag、kind、地址、数据和 mask |
| `mem_rsp_valid/ready` | 存储后端 / Memory Unit | Memory Unit / 后端 | Tag、返回数据或 Store ack、error |
| `dependency_issue_*` | Memory Unit 的 request fire | M2 Dependency Tracker | 请求实际接受，amount=1 |
| `dependency_complete_*` | Memory Unit 的完成通知仲裁 | M2 Dependency Tracker | 已满足 RF/Store ack 和排序要求，amount=1 |
| `rf_write_*` | Writeback/Commit | SGPR/VGPR File | 受仲裁的实际数据写入 |
| `scoreboard_clear_*` | Writeback/Commit 的最后 RF 写 | Scoreboard | 对应目的寄存器完成 |
| `commit_*` | Writeback/Commit | M2 Context Table | PC/EXEC/VCC/SCC/M0 和 `commit_next_state` |
| `wait_arm_*` | Writeback/Commit 的 Wait commit | M2 Dependency Tracker | 同 commit edge 和相同 wave_id |
| `wait_arm_satisfied` | M2 Dependency Tracker | Writeback/Commit | 为本次 Wait 选择 READY/WAITCNT |
| `wait_wakeup_mask` | M2 Top 根据 Tracker 与 Context 状态形成 | Context Table | 后续条件满足，WAITCNT→READY |
| `retire_fire/wave_id` | M2 Retire Controller | Dispatcher、Context、RF/Scoreboard 生命周期 | 依赖已排空后回收 |

所有 M3 队列都将 wave_id 与 payload 一起存储、一起握手。RF/LSU/Writeback 不得使用“当前 Scheduler 选中的 Wave”代替请求所属 Wave。

外部基础命令接口采用固定 packed 总线：transaction ID 8 bit、kind 3 bit、active mask 32 bit、32 lane × 64 bit 地址、32 lane × 32 bit Store/Load 数据，以及 Workgroup ID 和 error/status。SMEM 只使用 lane0 的地址/数据槽且不受 EXEC 限制；Global/DS 使用保存的 active mask。Tag 表保存目的寄存器信息，后端不推断 live RF。该接口是供 M4 处理的 Wave 指令命令，不等同于物理 AXI 或已合并内存事务。

指令和数据模型的响应延迟至少为 request fire 后 1 cycle。请求与返回各自独立握手；完整命令的所有 lane 处理完后，后端返回一次带 Tag 的数据或 ack。M4 若内部拆分成多个事务，需在返回这一级接口前汇总。

`WAVE_ID_BITS = (NUM_WAVE_CONTEXTS > 1) ? $clog2(NUM_WAVE_CONTEXTS) : 1` 在参数化模块中统一推导。当前 package 的 `cdna_wave_id_t` 固定在默认 4 Context 的 2 bit；M3 通用 packed payload 不直接内嵌此类型，而使用同宽参数化 wave_id sideband，并确保两者同步保存。

## 9. 已有工程的修改范围

| 文件/模块 | 计划修改 |
| --- | --- |
| `gpu_pkg.sv` | 补 instruction/operand/result/memory payload、Wait 配置、compare 条件、逐源 64 bit immediate；operand kind 扩为 4 bit 并追加 TTMP，保留原编码；追加 bit/shift function，保留 M1 已用的值 |
| `decoded_uop_t` | 保留原 immediate 字段供 legacy/branch 使用；追加逐源 immediate、Wait mask/threshold、必要存储字段及 fault reason，不把不同立即数挤进同一字段 |
| `wave_control_subsystem.sv` | 对外输出 alloc 的 Workgroup ID 和 Wave-in-group；增加 `schedule_enable_mask` 并在 Scheduler 输入处与 ready mask 相与 |
| M2 功能模块 | 保持 Dispatcher/Context/Tracker/Retire 的生命周期算法；不增加 REGISTER_WAIT 状态 |
| M2 TB/checker | 补齐新 Top 端口；独立 M2 验证把 `schedule_enable_mask` 接全 1，保证原测试意义不变 |
| 旧 `gpu_top/core/decode/wave_lsu` | 保留为 M1 回归通路；M3 新 Top 使用真实指令通路 |
| Makefile/filelist/scripts | 增加 M3 的 VCS2016 编译、矩阵回归、FSDB 和 Verdi2016 脚本 |

不通过结构 Top 重复实现已有 Context/Wait/计数器逻辑。旧 package 编码兼容性由 M1 回归确认；packed 类型位宽变化涉及的声明和 checker 由助手一起补齐。

## 10. 编写顺序与阶段产物

| 步骤 | 实施内容 | 本步完成标准 |
| --- | --- | --- |
| P01 | 冻结真实子集、启动 profile、opcode manifest；生成 package 增量与最小 M2 接口补充 | 字段含义/位宽/事件唯一来源明确，遗留编码不重排 |
| P02 | F01 Instruction Info + F02 Fetcher | 1/2/3 DWORD、literal、Wave 标签及反压保存完整；指令模型接口明确 |
| P03 | F03 Decoder | 45 条真实指令及支持字段生成正确 uop；未支持路径有明确原因 |
| P04 | F05/F06 RF + F07 Init | 同步读协议、bank/beat 映射、User SGPR 与 v0 初始化完成，候选 gating 接口确定 |
| P05 | F04 Buffer + F08 Scoreboard + F09 Collector | 每 Wave 槽隔离、RAW/WAW、2 读口下地址 pair/store data 的多次读取与公平选择 |
| P06 | F10 SALU | 整数、乘法、逻辑、比较、特殊状态与 SCC 各效果完成 |
| P07 | F11 VALU | 32 lane 的 8 beat 运算、inactive 保留、VCC 汇总及结果反压完成 |
| P08 | F12 Control + F14 Writeback/Commit | Branch/NOP/Wait/End、完整结果包仲裁、PC/flags 更新和 `commit_next_state` 完成 |
| P09 | F13 Memory Unit + 外部数据模型 | 真实请求、16 Tag、多返回、RF 回写、四类计数和顺序通知完成 |
| P10 | 助手完成两个 Top、filelist、TB、ISS、checker、VCS/Verdi 脚本 | M3 全功能工程可编译、可执行、可复现 |
| P11 | 整体 M3 验证 + M2/M1 回归 + 用户平台验收 | 下方验收矩阵通过并生成报告；保留 FSDB 与失败诊断 |

保持此前约定：每个模块开始时，助手提供参数、所有声明、接口前的完整注释与微架构说明，并在聊天中解释注释。用户编写主要 RTL；重复 bank/计数/端口逻辑由助手补齐；两个 Top 的纯连线、package 文件、验证材料由助手生成。

不增加逐模块仿真任务。编写期间做必要语法、字段一致性和接口检查；所有功能模块完成后再进行完整 M3 集成验证。P08 是此前尚未实现的 `commit_next_state` 真实生产逻辑落地的位置。

第一个实际编码任务是 P01/P02：先补公共类型和 Fetch 接口，再分步实现 Instruction Info 与 Fetcher。

## 11. 整体阶段验收矩阵

| 编号 | 测试 | 必须观察的结果 |
| --- | --- | --- |
| V01 | 真实 HEX 与独立解码参考 | opcode/format/register/literal/length 一致，内部 uop 编码不能替代机器码 |
| V02 | 1/2/3 DWORD 顺序混排 | PC 正确，VGLOBAL 和 literal64 不丢第三字 |
| V03 | 多 Wave 取指乱序返回 | word 与原 Wave/PC 对应，无串包 |
| V04 | Fetch/Decode/执行/存储/Writeback 随机反压 | valid 持续时 payload 稳定；每 fire 只消耗一次 |
| V05 | User SGPR、TTMP8/9、v0 启动 | 初始化前不选 Wave；global ID 由程序正确计算 |
| V06 | 未定义寄存器、RF 隔离与重新 alloc | defined 状态按新 Wave 重建，不依赖数据数组清零 |
| V07 | Scalar carry/borrow/逻辑/比较/move | 结果及 SCC 效果逐条比对，move 不误写 SCC |
| V08 | VGPR 四 bank/8 beat | lane0..31 无重复、无遗漏；非 active lane 保留数据 |
| V09 | V_CMP + VCC/EXEC 条件分支 | mask 与归约正确，EXEC=0 仍能执行 Scalar/Control |
| V10 | 正/负 branch offset 与循环 | taken/not-taken PC，退出次数，原指令 PC 正确 |
| V11 | SGPR/VGPR RAW 与 WAW | pending Load 目的阻塞相关指令，pair 任一 busy 都不能绕过 |
| V12 | 一个 Wave 等待操作数，其他 Wave 就绪 | 其他 Wave 能继续，没有全局 FIFO 头阻塞 |
| V13 | Global GV/GVS、SMEM、DS 地址 | signed offset、高 32 bit 地址、Workgroup LDS key 正确 |
| V14 | 请求长时间反压，期间其他 Tag 释放 | request Tag/地址/数据/mask 不改变，无额外 counter++ |
| V15 | Tag 全满与返回 FIFO 全满 | 正确反压，counter 不溢出，返回不丢失 |
| V16 | Load B 比 Load A 先写回，Wait threshold=1 | LOAD 仍为 2，A 完成前不错误唤醒；之后按序通知 |
| V17 | 四类真实依赖事件并发 | issue/complete amount 正确，同沿更新不丢事件 |
| V18 | SMEM 乱序及 `S_WAIT_KMCNT 0` | 所有所需 Scalar 返回写完后才继续 |
| V19 | 七类单 Wait 与两个组合 Wait | 按真实 threshold 位解码；未产生的类别保持无未完成工作 |
| V20 | Wait arm 与 complete 同沿/已满足 arm | next-state 正确，PC/arm 各一次，无多余 re-execute |
| V21 | Load 发出后改变 EXEC；Store 发出后改源寄存器 | 返回/Store 使用保存的 mask 与数据 |
| V22 | 同 Wave 同地址 Store→Load | 后端顺序正确，不能读到违反规定的旧值 |
| V23 | 多结果源同时争 RF 和 commit | 完整结果包不串 beat，仲裁有进展，最终写与普通 commit 同沿 |
| V24 | 无显式末尾 Wait 的 End-program | DONE 等依赖排空，最后 Tag 释放前不 retire |
| V25 | 真实 `LOAD → WAIT → ADD → STORE` Kernel | 完整整数向量加法逐元素等于独立参考，输出地址正确 |
| V26 | LDS 单 Wave Store/Wait/Load 及 Workgroup 隔离 | DS 数据正确；不同 WG 不互相污染，不宣称已验证跨 Wave Barrier |
| V27 | 线程数量 1/31/32/33/70/129/257 | 尾部 EXEC、跨 WG、Context 循环利用和结果数量正确 |
| V28 | Context 数量 1/3/4/8；WG 大小 33/64/97 | wave_id 位宽、非 2 的幂仲裁和地址计算正确 |
| V29 | 连续 Kernel 启动 | launch 参数重新捕获，之前的 busy/Tag/故障状态不误归属 |
| V30 | 取指、RF beat、请求待接受、Wait 时复位 | 控制状态清空；存储接口同步丢弃旧请求/响应，无旧事务写回新 Wave |
| V31 | 未支持 opcode/modifier/寄存器容量及存储错误 | 故障码/原 PC/Wave 可定位，没有假 done 或静默 NOP |
| V32 | M2 与 M1 全回归 | 现有 M2 矩阵与 M1 六个 pattern/opcode 覆盖继续通过 |

存储模型至少支持可配置 latency、跨 Tag 乱序返回、反压、Store 完成 ack 和错误注入；它必须保持所承诺的同地址顺序。Reset 是整个计算与存储接口共同 flush 的协议，基础版不增加 epoch；checker 对该系统约束直接断言。

参考模型独立执行真实指令字并比对提交、有效 GPR 结果及内存效果。ISA encoding fixture 与 RTL 不共用解码实现，避免两者同时写错仍通过。可用官方对应 assembler 时做二次交叉检查；未确认 CDNA5 target 时不拿其他架构的 `llvm-mc -mcpu` 替代。

## 12. VCS2016/Verdi2016 与 RTL 风格

保留 `logic`、`always_ff`、`always_comb`、普通参数、packed struct 和固定界数组。Wave ID 作为参数宽度 sideband；大结果数据采用固定 packed bundle，避免参数化 package、接口 class、UVM 或新版专有语法依赖。

控制状态使用 `posedge clk or negedge rst_n` 异步低有效复位。**组合逻辑不判断 rst_n。** 请求/valid 所有权、队列和 busy 状态通过时序复位清除；RF 数据不复位。

保持简洁实现，把重复的“系统已经保证”检查放进 checker/assertion。明确的接口合法性、资源容量和未支持配置集中处理；现有 counter 越界保护保留。Wait 保存逻辑继续按 reset > arm > wakeup > hold，不加入 alloc/release 清配置。

P10 计划增加 `filelist_m3_rtl.f`、`filelist_m3_tb.f`、M3 VCS 矩阵脚本、Verdi 启动脚本与 Makefile 目标 `m3/m3_matrix/m3_verdi`。这些名称目前是计划项，并非现有可运行命令。

FSDB 至少包含：Wave state/masks、alloc/schedule/execute_issue/commit、PC/原指令字、RF 地址与 beat、busy 位、Tag 生命周期、counter、Wait arm/wakeup、外部请求/返回。

当前环境尚无 VCS2016/Verdi2016 的实际执行证据。其他编译器/仿真器可以辅助开发，但退出报告必须分别记录辅助结果和用户平台的最终结果，不能互相替代。

## 13. M3 完成条件

1. 45 条声明支持的指令、启动 profile、RF、Scoreboard、执行单元、访存标签及 Writeback/Commit 均有完整实现。
2. `wave_compute_top` 能从真实机器码生成所有正常 commit、Wait arm 及四类真实 dependency 事件。
3. V01..V32 阶段验证通过；报告记录工具版本、配置、种子与每项结果。
4. M1/M2 回归继续通过；package 编码与参数化 wave_id 无兼容性回退。
5. 用户的 VCS2016 编译/仿真和 Verdi2016 FSDB 查看完成验收。
6. 未支持 ISA 范围、后端接口契约和下一阶段接口在 README/报告中明确。

全部达到后进入 M4。不能以“只有加法跑通”或“TB 能手动制造 commit”判定 M3 已完成。

## 14. 参考来源

- [S1] AMD，*CDNA5 Instruction Set Architecture: Reference Guide*，2026-07-27。查阅：3.4/3.5（Wave 状态与初始化）、4.1（literal/operand）、5.7（Wait/完成顺序）、10.2（寻址）、14/15（编码与指令语义）。<https://www.amd.com/content/dam/amd/en/documents/instinct-tech-docs/instruction-set-architectures/amd-instinct-cdna5-instruction-set-architecture.pdf>
- [S2] LLVM，*User Guide for AMDGPU Backend*，Kernel Descriptor / Initial Kernel Execution State / Kernel Functions。用于 User SGPR 参数布置参考；不把文档未列出的 CDNA5 编译目标或旧代 System SGPR 规则当作本项目事实。<https://llvm.org/docs/AMDGPUUsage.html>
- [E1] 本工程 `rtl/gpu_pkg.sv`、`rtl/wave_control_subsystem.sv`、`M2_MULTI_WAVE_CONTROL_SPEC.md`、`M2_STAGE_REPORT.md`：已有类型、接口、阶段划分和 M2 验证状态。
