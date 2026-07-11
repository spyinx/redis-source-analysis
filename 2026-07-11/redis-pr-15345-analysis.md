# Redis PR #15345 详细分析文档

## 一、基本信息

| 项目 | 内容 |
|------|------|
| **PR 标题** | Optimize wide HSET/HMSET on a fresh hash with a single batched listpack append |
| **PR 链接** | https://github.com/redis/redis/pull/15345 |
| **作者** | fcostaoliveira (Filipe Oliveira) |
| **合并者** | sundb |
| **创建时间** | 2026-06-16 |
| **合并时间** | 2026-07-09 |
| **目标分支** | redis:unstable |
| **风险等级** | Low |
| **影响范围** | HSET/HMSET 命令性能（listpack 编码的全新 hash） |

---

## 二、问题描述

### 2.1 性能瓶颈

使用 `HSET`/`HMSET` 向一个**全新创建**的、采用 **listpack 编码**的 Hash 中批量写入多个字段时，存在严重的性能问题：

**时间复杂度：O(n²)**

原因：
- `hsetCommand` 对每个字段调用一次 `hashTypeSet`
- 每次 `hashTypeSet` 调用都需要执行一次完整的 `lpFind` 遍历 listpack
- listpack 随着字段不断追加而增长
- 对于 N 个字段，总比较次数约为 `n²/2`

```
第 1 个字段: lpFind 遍历 0 个已有字段
第 2 个字段: lpFind 遍历 1 个已有字段
第 3 个字段: lpFind 遍历 2 个已有字段
...
第 N 个字段: lpFind 遍历 N-1 个已有字段
总比较次数 ≈ N(N-1)/2 = O(n²)
```

### 2.2 影响场景

- 初始化包含大量字段的 Hash（如配置文件存储、元数据缓存）
- 批量导入数据时使用 `HMSET`
- 字段数越多，性能恶化越严重

---

## 三、优化方案

### 3.1 核心思想

对于**空 listpack hash + ≥5 个字段**的场景，使用**单次 `lpBatchAppend`** 批量写入，将时间复杂度从 O(n²) 降到 **O(n)**。

### 3.2 实现机制

**`hashTypeBuildFreshListpack()` 函数**：

```
1. 检查条件：
   - Hash 编码为 OBJ_ENCODING_LISTPACK
   - Hash 当前为空
   - 字段数 ≥ 5
   - 无字段 TTL
   
2. 单次遍历参数：
   - 使用临时 dict 映射 field → slot index
   - 首次出现的 field → 分配新 slot
   - 重复 field → 复用 slot（last-wins 语义）
   
3. 构建 (field, value) 数组：
   - ≤128 个字段：数组分配在栈上
   - >128 个字段：数组分配在堆上
   
4. 单次 lpBatchAppend 写入
   - 无 per-field lpFind
   - 无 per-field realloc
   - 结果与逐字段路径字节级一致
```

### 3.3 范围限制（有意收窄）

| 场景 | 处理方式 |
|------|----------|
| 空 listpack hash + ≥5 字段 + 无 TTL | ✅ 使用 fast path |
| 空 listpack hash + <5 字段 | ❌ 逐字段路径（dict 开销不划算） |
| 非空 hash（追加/更新） | ❌ 逐字段路径（保持行为一致） |
| 含字段 TTL（LISTPACK_EX 编码） | ❌ 逐字段路径 |
| hashtable 编码 | ❌ 逐字段路径（已由 hashTypeTryConversion 处理） |

### 3.4 字节一致性保证

- 结果与逐字段构建**字节级一致**
- `HGETALL` 返回的字段顺序（插入顺序）不变
- CI 测试直接断言：`HGETALL` 顺序 + `DEBUG DIGEST-VALUE` 在 fast path 和逐字段路径之间相等

---

## 四、代码改动分析

### 4.1 修改文件

| 文件 | 变更类型 | 说明 |
|------|----------|------|
| `src/t_hash.c` | 修改 | 核心实现：hashTypeBuildFreshListpack() |
| `src/server.h` | 修改 | 函数声明 |
| `tests/unit/type/hash.tcl` | 新增 | 字节一致性测试 |

### 4.2 关键代码

```c
/* 在 hsetCommand 中 */
if (hashTypeLength(o) == 0 && 
    c->argc >= 5*2+2 &&  /* ≥5 个字段 */
    o->encoding == OBJ_ENCODING_LISTPACK) {
    
    // 尝试 fast path
    if (hashTypeBuildFreshListpack(c, o) == C_OK) {
        // 成功，跳过逐字段循环
        goto done;
    }
    // 失败回退到逐字段路径
}

/* hashTypeBuildFreshListpack 实现 */
int hashTypeBuildFreshListpack(client *c, robj *o) {
    dict *dup = dictCreate(&sdsReplyDictType);
    // ... 构建 field→slot 映射 ...
    // ... 处理重复 field（last-wins）... 
    // ... 单次 lpBatchAppend ...
    // ... 释放临时 dict ...
}
```

---

## 五、性能提升

### 5.1 基准测试结果

**测试场景**：每个 key 一次 `HSET`，51 个字段，listpack 编码

| 平台 | 优化前 (unstable) | 优化后 (this PR) | 提升 |
|------|-------------------|------------------|------|
| Intel Sapphire Rapids (x86) | 68.0K ops/s | 138.7K ops/s | **+104%** |
| AMD Zen 5 (x86) | 89.9K ops/s | 170.1K ops/s | **+89%** |
| Graviton4 (ARM) | 60.0K ops/s | 108.5K ops/s | **+81%** |

### 5.2 读操作无影响

同一数据集的只读 `HGETALL` 测试持平，确认优化不影响读取性能。

---

## 六、验证

### 6.1 功能验证

```bash
# 运行 hash 相关测试
./runtest --single unit/type/hash

# 手动测试
redis-cli HMSET myhash field1 value1 field2 value2 field3 value3 field4 value4 field5 value5
redis-cli HGETALL myhash
```

### 6.2 性能验证

```bash
# 使用 redis-benchmark 测试宽 HSET
redis-benchmark -n 100000 -c 50 HMSET myhash \
    f1 v1 f2 v2 f3 v3 f4 v4 f5 v5 f6 v6 f7 v7 f8 v8 f9 v9 f10 v10
```

---

## 七、影响评估

| 维度 | 评估 |
|------|------|
| **影响范围** | 大量使用 HSET/HMSET 批量初始化 hash 的用户 |
| **向后兼容** | 是（纯内部优化，行为不变） |
| **是否需要客户端更新** | 否 |
| **性能收益** | 宽字段（≥5）批量写入提升 80%~100% |
| **风险点** | 极低（有字节一致性测试保证） |

---

## 八、总结

PR #15345 针对 "全新 listpack hash + 多字段 HSET/HMSET" 场景引入了一个高效的 fast path，通过单次 `lpBatchAppend` 将时间复杂度从 O(n²) 降到 O(n)，在多平台上实现了 **80%~104%** 的性能提升。

优化的关键在于：
1. **精准的范围限制**：只对满足条件的空 hash 生效，避免影响其他场景
2. **临时 dedup dict**：处理重复 field 的 last-wins 语义
3. **字节一致性保证**：CI 测试确保 fast path 和逐字段路径结果完全一致

这是一个高质量的内部优化，对用户完全透明。

---

*文档生成时间：2026-07-11*
*基于 PR #15345 公开信息整理*
