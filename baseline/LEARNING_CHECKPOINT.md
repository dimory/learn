# 学习断点：2026-10-07

当前先返回 M2，进行 VCS2016 + Verdi2016 阶段验收。M3 重写暂停在以下位置。

## M3 已讲解与已完成的重写

- F01 `cdna_instruction_info`：指令头分类、DWORD 长度、literal32/literal64 和头部 fault。
- F02 `wave_instruction_fetcher`：每 Wave 一个组装槽，DWORD 请求/响应、pending、assembled、两个 RR 仲裁器及背压锁定。
- F03 `cdna_decoder`：接口、声明、透明 valid/ready 连线，以及完整 `source()` 操作数解析函数。
- 最近讨论：TTMP 的作用，当前 M3 子集解析 `TTMP8` 和 `TTMP9`。

## 恢复 M3 时的下一步

连接 `cdna_instruction_info`，开始主 `always_comb` 的默认赋值，然后逐步编写 SOP1 译码。

对话已决定直接使用 Fetcher 包中保存的 `inst_dwords`；分类器的 `.inst_dwords()` 留空。
上传 ZIP 的学习稿还保留 `logic [2:0] length;`，恢复时删除这个未使用声明。
当前交付保持上传的全部 RTL 学习稿原样。

## 继续遵守的规则

- 最终验收工具为 VCS2016 + Verdi2016，波形使用 FSDB。
- 只进行 M2 整套子系统阶段验证，不运行单模块测试。
- RTL 使用 SystemVerilog；时序寄存器使用异步低有效复位。
- 组合逻辑不增加复位判断。
- 后续新增或改写的全部 RTL 注释用英文，聊天中的说明用中文。
- module 前包含功能、微架构、最终接口连接、时序和复位说明。
- 接口及 logic 声明使用单个空格，不使用 tab 或为对齐添加空格。
- 主体 RTL 由用户逐步重写；声明、重复部分、顶层连线和验证环境由助手提供。
- 每步保持适量代码，优先采用简洁写法。

M2 本次结果见 `M2_VERIFICATION_20261007.md`，最终平台操作见
`M2_VCS2016_VERDI2016_GUIDE.md`。
