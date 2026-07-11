# Redis PR #15433 详细分析文档

## 一、基本信息

| 项目 | 内容 |
|------|------|
| **PR 标题** | Fix signed overflow in BITFIELD #offset parsing |
| **PR 链接** | https://github.com/redis/redis/pull/15433 |
| **作者** | SacadM |
| **合并者** | sundb |
| **创建时间** | 2026-07-07 |
| **合并时间** | 2026-07-10 |
| **目标分支** | redis:unstable |
| **关联 Issue** | #15389 [BUG] Redis BITFIELD #offset Signed Overflow DoS |
| **风险等级** | Medium |
| **影响版本** | 需回退至 Redis 8.8 Backport |

---

## 二、BITFIELD 命令基础（新手友好）

在深入分析漏洞之前，先了解一下 `BITFIELD` 命令是什么、做什么用，以及为什么这个问题值得关注。

### 2.1 BITFIELD 是什么？

`BITFIELD` 是 Redis 中一个用于**按位操作字符串**的命令。它把 Redis 的字符串值当成一个**位域数组**（bit array）来对待，允许你：
- **读取**特定位置、特定宽度的整数值（GET）
- **修改**特定位置的整数值（SET）
- **原子性递增**特定位置的整数值（INCRBY）

它常用于：
- **紧凑存储多个小整数**（比如用 8 位存年龄、用 16 位存分数，塞到一个 key 里）
- **位图统计**（如用户签到、在线状态等）
- **低带宽计数器**（原子性加减，避免多个 key 的并发问题）

### 2.2 基本语法示例

```bash
# 格式：BITFIELD key [GET type offset] [SET type offset value] [INCRBY type offset increment]

# 示例 1：在偏移 0 的位置，读取一个 8 位有符号整数
redis-cli BITFIELD mykey GET i8 0
# 返回：42（假设 mykey 的二进制前 8 位是 00101010）

# 示例 2：在偏移 8 的位置，设置一个 16 位无符号整数为 1000
redis-cli BITFIELD mykey SET u16 8 1000
# 返回：[0]（表示旧值是 0）

# 示例 3：原子递增
redis-cli BITFIELD mykey INCRBY u8 0 1
# 返回：43（从 42 加 1）
```

**类型说明**：
- `i8` / `i16` / `i32` / `i64` — 有符号整数（8/16/32/64 位）
- `u8` / `u16` / `u32` / `u64` — 无符号整数（8/16/32/64 位）

### 2.3 两种偏移语法

BITFIELD 支持两种偏移写法：

| 语法 | 含义 | 示例 |
|------|------|------|
| **直接偏移** `offset` | 从第 offset 个**位**开始 | `GET i8 0` → 从第 0 位开始读 8 位 |
| **#索引偏移** `#offset` | 从第 offset 个**元素**开始，自动乘以类型宽度 | `GET i8 #3` → 从第 3×8=24 位开始读 8 位 |

**# 语法的便利之处**：
```bash
# 假设你存了 10 个 16 位整数，想读第 5 个
# 不用自己算 5×16=80，直接写 #5
redis-cli BITFIELD scores GET i16 #5
# 等价于：redis-cli BITFIELD scores GET i16 80
```

### 2.4 漏洞跟 # 语法的关系

问题就出在这个 `#` 语法的"自动乘以类型宽度"上。

```
# 正常情况：
GET i8 #3  →  offset = 3 × 8 = 24    ✓ 正常

# 恶意情况：
GET i64 #144115188075855872  →  offset = 144115188075855872 × 64
                               = 这个数超过了 long long 的最大值
                               → 有符号整数溢出 → 未定义行为
```

在普通编译的 Redis 中，溢出可能不会立刻崩溃，但结果是错的、不可预测的。在启用了 UBSAN（未定义行为检测）或加固编译的版本中，Redis 会直接异常终止——这就是 DoS 漏洞。

---

## 三、问题描述（Issue #15389）

### 2.1 漏洞本质

Redis 的 `BITFIELD` 和 `BITFIELD_RO` 命令支持 `#<offset>` 语法，其中 `#` 表示偏移量需要按位域宽度（bit width）进行缩放。具体逻辑是：

```
实际位偏移 = 解析的偏移量 × 位域宽度(bits)
```

问题出在 `src/bitops.c` 的 `getBitOffsetFromArgument()` 函数中——**乘法运算发生在边界检查之前**。当用户提供极大的 `#<offset>` 值时，`loffset * bits` 会在 `long long` 有符号整数上发生溢出，触发未定义行为（Undefined Behavior）。

在启用了 **UBSAN**（Undefined Behavior Sanitizer）或加固编译（hardened builds）的环境中，这种有符号溢出会导致 Redis 服务器进程直接异常终止，形成**远程可触发的拒绝服务（DoS）攻击**。

### 2.2 触发条件

- **命令**：`BITFIELD_RO` 或 `BITFIELD`
- **参数**：使用 `#<offset>` 形式，且偏移量满足 `offset > LLONG_MAX / bits`
- **示例 payload**：
  ```bash
  redis-cli BITFIELD_RO k GET i64 '#144115188075855872'
  redis-cli BITFIELD k GET i64 '#144115188075855872'
  ```

其中 `144115188075855872` = `floor(LLONG_MAX / 64) + 1`，乘以 64 位宽度后必然溢出 `long long`。

### 2.3 受影响代码位置

```
src/bitops.c:721  — 启用 #<offset> 语法乘法
src/bitops.c:730  — loffset *= bits（溢出点）
src/bitops.c:1931 — BITFIELD/BITFIELD_RO 调用入口
```

---

## 四、对话翻译与整理

### 4.1 PR 创建者 SacadM 的初始说明

> **原文**：
> BITFIELD and BITFIELD_RO support #<offset> syntax, where the parsed offset is multiplied by the bitfield width before use. For very large offsets, that multiplication could overflow long long before the existing range checks ran.
> 
> This PR fixes #15389 by rejecting #<offset> values that would overflow before applying the width multiplier, returning the existing ERR bit offset is not an integer or out of range error instead.
>
> Tests:
> ./runtest --single unit/bitfield
>
> Verified with a UBSAN build that both repro commands return an error and the server remains alive:
> BITFIELD_RO k GET i64 '#144115188075855872'
> BITFIELD k GET i64 '#144115188075855872'

> **翻译**：
> BITFIELD 和 BITFIELD_RO 支持 `#<offset>` 语法，其中解析出的偏移量在使用前会乘以位域宽度。对于非常大的偏移量，在现有范围检查执行之前，该乘法可能在 `long long` 上发生溢出。
>
> 本 PR 通过拒绝那些会在应用宽度乘数前溢出的 `#<offset>` 值来修复 #15389，返回已有的错误信息 `ERR bit offset is not an integer or out of range`。
>
> 测试：
> ./runtest --single unit/bitfield
>
> 已通过 UBSAN 构建验证，两个复现命令都返回错误且服务器保持存活：
> BITFIELD_RO k GET i64 '#144115188075855872'
> BITFIELD k GET i64 '#144115188075855872'

### 4.2 性能审查请求（fcostaoliveira）

> **原文**：
> This change touches performance-sensitive code paths. Adding the action:run-benchmark label will trigger the CE Performance suite so we can see the impact before merge.

> **翻译**：
> 此改动触及了性能敏感的代码路径。添加 `action:run-benchmark` 标签将触发 CE 性能测试套件，以便在合并前查看其影响。

### 4.3 审查反馈（sundb）

sundb 对代码进行了审查，提出了修改意见。随后 SacadM 提交了第二个 commit `09e0466` 来响应反馈（"Address BITFIELD offset review feedback"）。

最终 sundb 批准了修改，并添加了 `release-notes` 标签（表示需要在发布说明中提及），同时将此 PR 标记为需要回退至 `Redis 8.8 Backport`。

---

## 五、代码改动分析

### 5.1 修改文件概览

| 文件 | 变更类型 | 说明 |
|------|----------|------|
| `src/bitops.c` | 修改 | 核心修复：增加溢出和负数检查 |
| `tests/unit/bitfield.tcl` | 新增 | 单元测试：验证溢出偏移量被正确拒绝 |

### 5.2 `src/bitops.c` 详细改动

**修改前代码（存在漏洞）**：
```c
/* Handle #<offset> form. */
if (p[0] == '#' && hash && bits > 0) usehash = 1;

if (string2ll(p+usehash, plen-usehash, &loffset) == 0) {
    addReplyError(c, err);
    return C_ERR;
}

/* Adjust the offset by 'bits' for #<offset> form. */
if (usehash) loffset *= bits;  // ⚠️ 溢出点！乘法在检查之前

/* Limit offset to server.proto_max_bulk_len */
if (loffset < 0 || (!mustObeyClient(c) && (loffset >> 3) >= server.proto_max_bulk_len))
{
    addReplyError(c, err);
    return C_ERR;
}
```

**修改后代码（已修复）**：
```c
/* Handle #<offset> form. */
if (p[0] == '#' && hash && bits > 0) usehash = 1;

// ✅ 修复1：解析后立即检查负数
if (string2ll(p+usehash, plen-usehash, &loffset) == 0 || loffset < 0) {
    addReplyError(c, err);
    return C_ERR;
}

/* Adjust the offset by 'bits' for #<offset> form. */
if (usehash) {
    // ✅ 修复2：乘法前先检查溢出
    if (loffset > LLONG_MAX / bits) {
        addReplyError(c, err);
        return C_ERR;
    }
    loffset *= bits;
}

/* Limit offset to server.proto_max_bulk_len */
// ✅ 修复3：移除重复负数检查（前面已处理）
if (!mustObeyClient(c) && (loffset >> 3) >= server.proto_max_bulk_len)
{
    addReplyError(c, err);
    return C_ERR;
}
```

### 5.3 修复逻辑总结

| 修复点 | 说明 |
|--------|------|
| **提前拒绝负数** | `string2ll()` 解析后立刻检查 `loffset < 0`，避免后续负数通过溢出检查 |
| **乘法前溢出检查** | 对于 `#<offset>` 形式，在 `loffset *= bits` 之前检查 `loffset > LLONG_MAX / bits` |
| **移除冗余检查** | 后续条件中移除了 `loffset < 0`，因为负数已被提前处理 |
| **统一错误返回** | 所有违规情况均返回 `ERR bit offset is not an integer or out of range` |

### 5.4 `tests/unit/bitfield.tcl` 新增测试

```tcl
test {BITFIELD #<idx> form rejects offsets that overflow when scaled by type width} {
    assert_error {*ERR bit offset is not an integer or out of range*} {
        r bitfield_ro bits get i64 #144115188075855872
    }
    assert_error {*ERR bit offset is not an integer or out of range*} {
        r bitfield bits get i64 #144115188075855872
    }
}
```

---

## 六、问题复现步骤

### 6.1 环境准备

需要一个启用了 UBSAN 的 Redis 构建，这样才能观察到进程崩溃：

```bash
# 1. 克隆 Redis 源码（修复前版本）
git clone https://github.com/redis/redis.git
cd redis

# 2. 回退到修复前（可选，如需验证漏洞）
# git checkout <commit-before-fix>

# 3. 编译带 UBSAN 的 Redis
make -C src \
    SANITIZER=undefined \
    MALLOC=libc \
    OPTIMIZATION=-O0 \
    PROG_SUFFIX=-ubsan \
    redis-server-ubsan redis-cli-ubsan \
    -j$(nproc)
```

### 6.2 复现命令

**方式一：手动触发**

```bash
# 启动 UBSAN 服务器
./src/redis-server-ubsan --port 6379 --bind 127.0.0.1 \
    --save '' --appendonly no --daemonize yes

# 触发溢出（以下任一命令均可）
./src/redis-cli-ubsan BITFIELD_RO k GET i64 '#144115188075855872'
./src/redis-cli-ubsan BITFIELD k GET i64 '#144115188075855872'

# 观察服务器日志，应出现：
# bitops.c:730:26: runtime error: signed integer overflow: 64 * 144115188075855872 cannot be represented in type 'long long int'
```

**方式二：自动化 POC 脚本**

Issue 报告者提供了一个完整的 Bash 脚本，自动完成编译、启动、触发和验证：

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d /tmp/redis-bitfield-offset-overflow.XXXXXX)"
SRC="${TMP}/srcroot"

cleanup() {
    pkill -P "$$" 2>/dev/null || true
    rm -rf "${TMP}"
}
trap cleanup EXIT

echo "[1/4] Copying Redis workspace..."
mkdir -p "${SRC}"
cd "${ROOT}"
tar --exclude='.git' --exclude='src/*.o' -cf - . | tar -C "${SRC}" -xf -

echo "[2/4] Building UBSAN Redis..."
make -C "${SRC}/src" SANITIZER=undefined MALLOC=libc OPTIMIZATION=-O0 \
    PROG_SUFFIX=-ubsan redis-server-ubsan redis-cli-ubsan -j$(nproc) >/dev/null

SERVER="${SRC}/src/redis-server-ubsan"
CLI="${SRC}/src/redis-cli-ubsan"
OFFSET="#144115188075855872"

# 测试 BITFIELD_RO
"${SERVER}" --port 6415 --bind 127.0.0.1 --save '' --appendonly no &
SPID=$!
sleep 1
"${CLI}" -p 6415 BITFIELD_RO k GET i64 "${OFFSET}"
sleep 0.5
# 此时服务器应已崩溃
```

**预期现象（修复前）**：
- 服务器进程异常终止
- 日志中出现 `runtime error: signed integer overflow`
- 后续 `PING` 命令无响应

---

## 七、修复后验证步骤

### 7.1 验证修复是否生效

```bash
# 1. 确保使用的是包含 PR #15433 的代码
git log --oneline | head -5
# 应看到类似：c5ac971 Fix signed overflow in BITFIELD #offset parsing

# 2. 编译（同样可以用 UBSAN 构建验证安全性）
make -C src SANITIZER=undefined MALLOC=libc OPTIMIZATION=-O0 \
    PROG_SUFFIX=-ubsan redis-server-ubsan redis-cli-ubsan -j$(nproc)

# 3. 启动服务器
./src/redis-server-ubsan --port 6379 --bind 127.0.0.1 \
    --save '' --appendonly no --daemonize yes

# 4. 发送原本会导致溢出的命令
./src/redis-cli-ubsan BITFIELD_RO k GET i64 '#144115188075855872'
# 预期返回：(error) ERR bit offset is not an integer or out of range

./src/redis-cli-ubsan BITFIELD k GET i64 '#144115188075855872'
# 预期返回：(error) ERR bit offset is not an integer or out of range

# 5. 确认服务器仍然存活
./src/redis-cli-ubsan PING
# 预期返回：PONG

# 6. 查看 UBSAN 日志，确认无溢出报错
# 服务器应正常运行，无异常退出
```

### 7.2 运行新增单元测试

```bash
# 运行 bitfield 专项测试
./runtest --single unit/bitfield

# 预期结果：所有测试通过，包括新增的溢出测试用例
```

### 7.3 边界值测试

```bash
# 测试刚好不溢出的边界值
# LLONG_MAX / 64 = 144115188075855871（对于 i64 类型）
# 这个值应该正常工作（如果不超过 proto_max_bulk_len）

# 测试比边界大 1 的值（应被拒绝）
redis-cli BITFIELD k GET i64 '#144115188075855872'
# (error) ERR bit offset is not an integer or out of range

# 测试负数（应被拒绝）
redis-cli BITFIELD k GET i64 '#-1'
# (error) ERR bit offset is not an integer or out of range
```

---

## 八、安全影响评估

### 8.1 攻击面分析

| 维度 | 评估 |
|------|------|
| **远程可利用性** | ✅ 是，任何能连接 Redis 的客户端均可触发 |
| **权限要求** | 仅需能执行 `BITFIELD` 或 `BITFIELD_RO` 命令 |
| **影响范围** | 进程级 DoS，服务器崩溃 |
| **数据影响** | 可能导致未持久化的数据丢失（若未开启 AOF/RDB） |
| **利用难度** | 极低，单条命令即可触发 |

### 8.2 缓解措施（修复前）

在升级前，可通过以下方式降低风险：
1. **禁用 UBSAN**：生产环境通常不使用 UBSAN 构建，标准构建中溢出不会立即崩溃（但有未定义行为风险）
2. **ACL 限制**：通过 Redis ACL 限制不可信用户对 `BITFIELD`/`BITFIELD_RO` 的访问
3. **网络隔离**：将 Redis 部署在内网，避免直接暴露到公网

---

## 九、总结

PR #15433 修复了一个中等风险的整数溢出漏洞，该漏洞允许远程攻击者通过构造恶意的 `BITFIELD`/`BITFIELD_RO` `#<offset>` 参数触发有符号整数溢出，在 UBSAN/加固构建中导致进程崩溃（DoS）。

修复方案简洁有效：
- 在解析偏移量后立即拒绝负值
- 在 `#<offset>` 乘法前增加溢出检查 `loffset > LLONG_MAX / bits`
- 统一返回已有错误信息，无需新增错误码

此修复已合并至 `unstable` 分支，并计划回退至 `Redis 8.8`。

---

*文档生成时间：2026-07-11*
*基于 PR #15433 及 Issue #15389 的公开信息整理*
