| 格式／OP位        | 指令                    | Opcode 十进制／十六进制 | DWORD | uop类别／功能  | 操作及主要效果                                |
| ----------------- | ----------------------- | ----------------------- | ----- | -------------- | --------------------------------------------- |
| SOP1 `[15:8]`     | `S_MOV_B32`             | 0／`0x00`               | L     | SALU／MOV      | 移动32-bit数据到标量目的                      |
| SOP1 `[15:8]`     | `S_MOV_B64`             | 1／`0x01`               | L     | SALU／MOV      | 移动64-bit数据到 SGPR pair                    |
| SOP2 `[29:23]`    | `S_ADD_CO_U32`          | 0／`0x00`               | L     | SALU／ADD      | 标量加法，更新目的和 SCC进位                  |
| SOP2 `[29:23]`    | `S_SUB_CO_U32`          | 1／`0x01`               | L     | SALU／SUB      | 标量减法，更新目的和 SCC借位                  |
| SOP2 `[29:23]`    | `S_LSHL_B32`            | 8／`0x08`               | L     | SALU／SHL      | `src0 << src1[4:0]`，更新 SCC                 |
| SOP2 `[29:23]`    | `S_LSHR_B32`            | 10／`0x0A`              | L     | SALU／SHR      | `src0 >> src1[4:0]`，更新 SCC                 |
| SOP2 `[29:23]`    | `S_AND_B32`             | 22／`0x16`              | L     | SALU／AND      | 位与，SCC表示结果是否非零                     |
| SOP2 `[29:23]`    | `S_OR_B32`              | 24／`0x18`              | L     | SALU／OR       | 位或，SCC表示结果是否非零                     |
| SOP2 `[29:23]`    | `S_XOR_B32`             | 26／`0x1A`              | L     | SALU／XOR      | 异或，SCC表示结果是否非零                     |
| SOP2 `[29:23]`    | `S_MUL_I32`             | 44／`0x2C`              | L     | SALU／MUL      | 乘积低32位写入目的，保持 SCC                  |
| SOPC `[22:16]`    | `S_CMP_EQ_U32`          | 6／`0x06`               | L     | SALU／CMP      | 无符号相等比较，结果写 SCC                    |
| SOPC `[22:16]`    | `S_CMP_LT_U32`          | 10／`0x0A`              | L     | SALU／CMP      | 无符号小于比较，结果写 SCC                    |
| SOPP `[22:16]`    | `S_NOP`                 | 0／`0x00`               | 1     | SYSTEM／NOP    | 当前只接受 `SIMM16=0`                         |
| SOPP `[22:16]`    | `S_BRANCH`              | 32／`0x20`              | 1     | BRANCH／BRANCH | 无条件相对跳转                                |
| SOPP `[22:16]`    | `S_CBRANCH_SCC0`        | 33／`0x21`              | 1     | BRANCH／BRANCH | SCC为0时跳转                                  |
| SOPP `[22:16]`    | `S_CBRANCH_SCC1`        | 34／`0x22`              | 1     | BRANCH／BRANCH | SCC为1时跳转                                  |
| SOPP `[22:16]`    | `S_CBRANCH_VCCZ`        | 35／`0x23`              | 1     | BRANCH／BRANCH | VCC为零时跳转                                 |
| SOPP `[22:16]`    | `S_CBRANCH_VCCNZ`       | 36／`0x24`              | 1     | BRANCH／BRANCH | VCC非零时跳转                                 |
| SOPP `[22:16]`    | `S_CBRANCH_EXECZ`       | 37／`0x25`              | 1     | BRANCH／BRANCH | EXEC为零时跳转                                |
| SOPP `[22:16]`    | `S_CBRANCH_EXECNZ`      | 38／`0x26`              | 1     | BRANCH／BRANCH | EXEC非零时跳转                                |
| SOPP `[22:16]`    | `S_ENDPGM`              | 48／`0x30`              | 1     | SYSTEM／END    | 提交结束指令，使 Wave进入 DONE                |
| SOPP `[22:16]`    | `S_WAIT_LOADCNT`        | 64／`0x40`              | 1     | WAIT／WAIT     | 等待 LOAD计数 ≤ `W0[5:0]`                     |
| SOPP `[22:16]`    | `S_WAIT_STORECNT`       | 65／`0x41`              | 1     | WAIT／WAIT     | 等待 STORE计数 ≤ `W0[5:0]`                    |
| SOPP `[22:16]`    | `S_WAIT_XCNT`           | 69／`0x45`              | 1     | WAIT／WAIT     | 等待 X计数 ≤ `W0[5:0]`                        |
| SOPP `[22:16]`    | `S_WAIT_DSCNT`          | 70／`0x46`              | 1     | WAIT／WAIT     | 等待 DS计数 ≤ `W0[5:0]`                       |
| SOPP `[22:16]`    | `S_WAIT_KMCNT`          | 71／`0x47`              | 1     | WAIT／WAIT     | 等待 KM计数 ≤ `W0[4:0]`                       |
| SOPP `[22:16]`    | `S_WAIT_LOADCNT_DSCNT`  | 72／`0x48`              | 1     | WAIT／WAIT     | LOAD ≤ `W0[13:8]`，且 DS ≤ `W0[5:0]`          |
| SOPP `[22:16]`    | `S_WAIT_STORECNT_DSCNT` | 73／`0x49`              | 1     | WAIT／WAIT     | STORE ≤ `W0[13:8]`，且 DS ≤ `W0[5:0]`         |
| SOPP `[22:16]`    | `S_WAIT_ASYNCCNT`       | 74／`0x4A`              | 1     | WAIT／WAIT     | 等待 ASYNC计数 ≤ `W0[5:0]`                    |
| SOPP `[22:16]`    | `S_WAIT_TENSORCNT`      | 75／`0x4B`              | 1     | WAIT／WAIT     | 等待 TENSOR计数 ≤ `W0[5:0]`                   |
| VOP1 `[15:9]`     | `V_MOV_B32`             | 1／`0x01`               | L     | VALU／MOV      | 按 EXEC移动数据到各 lane 的 VGPR              |
| VOP2 `[30:25]`    | `V_LSHLREV_B32`         | 24／`0x18`              | L     | VALU／SHL      | 各 lane 执行 `src1 << src0[4:0]`              |
| VOP2 `[30:25]`    | `V_LSHRREV_B32`         | 25／`0x19`              | L     | VALU／SHR      | 各 lane 执行 `src1 >> src0[4:0]`              |
| VOP2 `[30:25]`    | `V_AND_B32`             | 27／`0x1B`              | L     | VALU／AND      | 各 lane 位与，写 VGPR                         |
| VOP2 `[30:25]`    | `V_OR_B32`              | 28／`0x1C`              | L     | VALU／OR       | 各 lane 位或，写 VGPR                         |
| VOP2 `[30:25]`    | `V_XOR_B32`             | 29／`0x1D`              | L     | VALU／XOR      | 各 lane 异或，写 VGPR                         |
| VOP2 `[30:25]`    | `V_ADD_NC_U32`          | 37／`0x25`              | L     | VALU／ADD      | 各 lane 加法，写 VGPR，保持 VCC               |
| VOP2 `[30:25]`    | `V_SUB_NC_U32`          | 38／`0x26`              | L     | VALU／SUB      | 各 lane 减法，写 VGPR，保持 VCC               |
| VOPC `[24:17]`    | `V_CMP_LT_U32`          | 73／`0x49`              | L     | VALU／CMP      | 各 lane 无符号小于比较，生成 VCC mask         |
| VOPC `[24:17]`    | `V_CMP_EQ_U32`          | 74／`0x4A`              | L     | VALU／CMP      | 各 lane 无符号相等比较，生成 VCC mask         |
| SMEM `[18:13]`    | `S_LOAD_B32`            | 0／`0x00`               | 2     | SMEM／LOAD     | Scalar读取32-bit到 SGPR；使用 KM计数          |
| VGLOBAL `[20:13]` | `GLOBAL_LOAD_B32`       | 20／`0x14`              | 3     | VMEM／LOAD     | 按 EXEC从 Global读取到 VGPR；使用 LOAD计数    |
| VGLOBAL `[20:13]` | `GLOBAL_STORE_B32`      | 26／`0x1A`              | 3     | VMEM／STORE    | 按 EXEC将 VGPR数据写入 Global；使用 STORE计数 |
| VDS `[25:18]`     | `DS_STORE_B32`          | 13／`0x0D`              | 2     | LDS／STORE     | 按 EXEC将 VGPR数据写入 LDS；使用 DS计数       |
| VDS `[25:18]`     | `DS_LOAD_B32`           | 54／`0x36`              | 2     | LDS／LOAD      | 按 EXEC从 LDS读取到 VGPR；使用 DS计数         |





| `code`       | 含义                                     | 本版 M3 处理                                             |
| ------------ | ---------------------------------------- | -------------------------------------------------------- |
| **0～105**   | SGPR `s0～s105`                          | `OPERAND_SGPR`，`index = code`，检查实际寄存器范围       |
| **106**      | `VCC_LO`                                 | `OPERAND_VCC`                                            |
| 107          | `VCC_HI`                                 | 不支持                                                   |
| **108～123** | `TTMP0～TTMP15`                          | 只支持 **116、117**，对应 `TTMP8、TTMP9`                 |
| **124**      | NULL 源，读作零                          | `OPERAND_IMMEDIATE`，`value = 0`                         |
| **125**      | M0                                       | `OPERAND_M0`                                             |
| **126**      | `EXEC_LO`                                | `OPERAND_EXEC`                                           |
| 127          | `EXEC_HI`                                | 不支持                                                   |
| **128～192** | 内嵌整数 **0～64**                       | `OPERAND_IMMEDIATE`，`value = code - 128`                |
| **193～208** | 内嵌整数 **−1～−16**                     | `OPERAND_IMMEDIATE`，`value = -(code - 192)`             |
| 209～229     | 保留编码                                 | 不支持                                                   |
| 230～231     | `FLAT_SCRATCH_BASE_LO/HI`                | 不支持                                                   |
| 232～234     | 保留或 DPP 扩展标记，依格式而定          | 不支持                                                   |
| 235～236     | `SHARED_BASE`、`SHARED_LIMIT`            | 不支持                                                   |
| 237～239     | 保留编码                                 | 不支持                                                   |
| 240～248     | 内嵌浮点常量：±0.5、±1、±2、±4、`1/(2π)` | 不支持                                                   |
| 249～252     | 保留编码                                 | 不支持                                                   |
| **253**      | SCC                                      | `OPERAND_SCC`                                            |
| **254**      | 附加 **64-bit literal**                  | `OPERAND_IMMEDIATE`，`value = literal_value`             |
| **255**      | 附加 **32-bit literal**                  | `OPERAND_IMMEDIATE`，低 32 bit 零扩展                    |
| **256～511** | VGPR `v0～v255`                          | `OPERAND_VGPR`，`index = code - 256`，检查实际寄存器范围 |