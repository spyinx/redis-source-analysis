# Redis 核心改动深入代码分析（2026.7.11 ~ 7.17）

> 分析时间：2026-07-17  
> 分析范围：PR #15329、#15462、#15437  
> 分析者：李有才

---

## 一、PR #15329 — IO 线程复制客户端忙循环修复

**风险等级：🔴 高（生产环境 CPU 飙高）**  
**合并时间：2026-07-14**  
**作者：minchopaskal**

### 1.1 问题现象

启用 IO 线程（`io-threads > 1`）且有复制客户端（replica）连接时，**高流量结束后 IO 线程 CPU 可能持续 100%**，即使主节点完全空闲。

### 1.2 根因：一个微妙的时序窗口

问题的触发路径如下（参考下图理解）：

```
┌─────────────────────────────────────────────────────────────────┐
│  时序图：写 handler 是如何" stranded "（滞留）的                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Main Thread                            IO Thread               │
│  ───────────                            ────────                │
│                                                                 │
│  writeToClient(c) ──► 未写完所有数据                              │
│       │                                                         │
│       ▼                                                         │
│  安装 write handler ──► connSetWriteHandler(c->conn,             │
│                         sendReplyToClient)                     │
│       │                                                         │
│       ▼                                                         │
│  processClientsFromMainThread                                   │
│       │                                                         │
│       ▼                                                         │
│  IOThreadClientsCron (每 100ms)                                 │
│       │                                                         │
│       ▼                                                         │
│  决定将客户端送回 IO 线程                                         │
│       │                                                         │
│       ├──► 清除 CLIENT_IO_WRITE_ENABLED 标志                     │
│       │    [但 write handler 仍注册在 IO 线程 epoll 中!]          │
│       │                                                         │
│       ▼                                                         │
│  客户端进入 IO 线程 pending 队列                                  │
│       │                                                         │
│       ▼                                                         │
│                         processClientsFromMainThread            │
│                              │                                  │
│                              ▼                                  │
│                         writeToClient(c, 0)  [尝试 drain]       │
│                              │                                  │
│                              ├──► CLIENT_IO_WRITE_ENABLED=0     │
│                              │    直接返回，**不卸载 handler**    │
│                              │                                  │
│                              ▼                                  │
│                         [流量停止]                               │
│                              │                                  │
│                              ├──► epoll_wait 返回 EPOLLOUT      │
│                              │    sendReplyToClient 被调用       │
│                              │    但 CLIENT_IO_WRITE_ENABLED=0  │
│                              │    再次直接返回...                │
│                              │                                  │
│                              ▼                                  │
│                         🔥 无限循环 🔥                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 1.3 关键代码分析

**原始代码（iothread.c）：**

```c
void enqueuePendingClientsToMainThread(client *c, int unbind) {
    // ...
    /* Disable read and write to avoid race when main thread processes. */
    c->io_flags &= ~(CLIENT_IO_READ_ENABLED | CLIENT_IO_WRITE_ENABLED);
    /* ❌ 问题：只清除了标志，没有从 epoll 中注销 write handler */
    // ...
}
```

**修复后：**

```c
void enqueuePendingClientsToMainThread(client *c, int unbind) {
    // ...
    /* Disable read and write to avoid race when main thread processes. */
    c->io_flags &= ~(CLIENT_IO_READ_ENABLED | CLIENT_IO_WRITE_ENABLED);
    connSetWriteHandler(c->conn, NULL);  // ✅ 关键修复
    // ...
}
```

**为什么这行代码能解决问题？**

| 阶段 | 修复前 | 修复后 |
|------|--------|--------|
| 客户端移交主线程 | 标志清除，handler 残留 | 标志清除 + handler 注销 |
| 客户端返回 IO 线程 | writeToClient(c,0) 发现标志=0，直接返回 | 无残留 handler，epoll 不会触发 |
| 流量停止后 | epoll 持续触发 EPOLLOUT → 忙循环 | IO 线程正常休眠 |

### 1.4 为什么偏偏是复制客户端？

> "replica clients always have big replies when traffic is high, whereas normal clients tend not to have sustained outgoing big traffic"

普通客户端的回复通常很小（OK、某个值），一次 `writeToClient` 就能写完，不会触发写 handler 的安装。而复制客户端需要持续发送 RDB / 增量数据，socket 缓冲区很容易被填满，从而进入"安装 handler → 未写完 → 移交"的代码路径。

### 1.5 测试用例分析

这是一个**确定性回归测试**，设计非常精巧：

```tcl
# 核心策略：SIGSTOP / SIGCONT 制造 socket 缓冲区填满

for {每轮 session} {
    # 1. 启动 12 个写负载（模拟 redis-benchmark -d 8）
    set loaders [start_write_load ...]
    
    # 2. 反复 STOP/CONT 复制进程
    while {6秒内} {
        exec kill -SIGSTOP $slave_pid   ;# 复制停止读取
        after 130                       ;# 超过 100ms 的 cron 周期
        exec kill -SIGCONT $slave_pid   ;# 恢复读取
        after 150
    }
    
    # 3. 停止所有负载，测量空闲期 CPU
    set frac [measure_proc_cpu_fraction $master_pid 1000]
    assert {$frac < 0.5}  ;# 健康服务器应接近空闲
}
```

**为什么用 SIGSTOP/SIGCONT？**
- STOP 让复制进程暂停读取 → master→replica socket 缓冲区填满
- 缓冲区满 → `writeToClient` 部分写入 → 安装 write handler
- 等待 130ms 超过 `IOThreadClientsCron` 的 100ms 周期 → cron 将客户端移回主线程
- CONT 恢复复制 → 客户端被送回 IO 线程 → `writeToClient(c,0)` drain 数据但不卸载 handler
- 如果没有修复，此时 handler 滞留，后续空闲期 CPU 100%

### 1.6 影响评估与建议

| 场景 | 影响 |
|------|------|
| 使用 `io-threads > 1` + 复制 | 🔴 必须升级，高流量后可能 CPU 100% |
| 使用 `io-threads > 1` 无复制 | 🟡 理论上也可能触发，但概率极低 |
| 不使用 IO 线程 | 🟢 不受影响 |

---

## 二、PR #15462 — dictMemUsage() 内存统计修复

**风险等级：🟡 中（监控数据失真）**  
**合并时间：2026-07-17**  
**作者：filipecosta90**

### 2.1 问题本质

Redis 内部使用两种字典 entry 结构：

```c
// 完整 entry（24 bytes on 64-bit）
typedef struct dictEntry {
    struct dictEntry *next;     // 8 bytes
    void *key;                   // 8 bytes
    union {
        void *val;
        uint64_t u64;
        double d;
    } v;                         // 8 bytes
} dictEntry;

// 无 value 优化 entry（16 bytes on 64-bit）
typedef struct dictEntryNoValue {
    struct dictEntry *next;     // 8 bytes
    void *key;                   // 8 bytes
    // 无 value 字段！
} dictEntryNoValue;
```

**`no_value=1` 的字典类型：**
- Set（集合，HT 编码）
- Sorted Set 的 element index（跳表编码时的元素索引）
- Hash（HT 编码）

这些结构不需要存储 value（Set 的 key 就是 value，Hash 的 value 单独存），所以用 `dictEntryNoValue` 节省 8 bytes/entry。

### 2.2 问题代码

```c
// 修复前
size_t dictMemUsage(const dict *d) {
    return dictSize(d) * sizeof(dictEntry) +      // ❌ 统一按 24B 算
           dictBuckets(d) * sizeof(dictEntry*);
}
```

对于 100 万个元素的 Set：
- 实际占用：`100万 * 16B + bucket开销`
- 统计报告：`100万 * 24B + bucket开销`
- **虚高：约 8MB**

### 2.3 修复代码

```c
// 修复后
size_t dictMemUsage(const dict *d) {
    return dictSize(d) * dictEntryMemUsage(d->type->no_value) +  // ✅ 按实际类型
           dictBuckets(d) * sizeof(dictEntry*);
}
```

其中 `dictEntryMemUsage(no_value)` 的实现：

```c
static inline size_t dictEntryMemUsage(int no_value) {
    return no_value ? sizeof(dictEntryNoValue) : sizeof(dictEntry);
}
```

### 2.4 实测数据

| 数据结构 | 修复前 (B/entry) | 修复后 (B/entry) | 偏差 |
|----------|-----------------|-----------------|------|
| Set (HT) | 12.26 | 4.25 | -8.01 |
| Zset index | 18.29 | 10.28 | -8.01 |
| Hash (HT) | 16.29 | 8.30 | -8.00 |

> 注：绝对值不等于 8B 是因为还有 bucket 指针数组的开销被平摊了，但偏差精确等于 8B。

### 2.5 测试验证

```c
TEST("dictMemUsage sizes no_value entries by dictEntryNoValue") {
    const size_t value_union_bytes = 8;
    assert(sizeof(dictEntry) - sizeof(dictEntryNoValue) == value_union_bytes);

    dict *dn = dictCreate(&BenchmarkDictType);          // no_value=0
    dict *dv = dictCreate(&BenchmarkDictTypeNoValue);   // no_value=1
    
    // 插入相同数量的 key
    for (long i = 0; i < n; i++) {
        dictAdd(dn, key, (void *)i);    // 需要 value
        dictAdd(dv, key, NULL);         // no_value 优化
    }

    // 验证：内存差恰好是 n * 8 bytes
    assert(dictMemUsage(dn) - dictMemUsage(dv) == n * value_union_bytes);
}
```

### 2.6 为什么故意保留一点误差？

注释说明：
> "inline-stored keys allocate 0 B but are still charged 16 B; crediting them 0 would require an O(buckets) walk that contradicts the command's O(1) design"

对于 `no_value=1` 的字典，如果 key 的哈希值不冲突，key 直接 inline 存储在 bucket 中（0 额外分配），但 `dictMemUsage()` 仍按 `dictEntryNoValue`（16B）计费。这是因为精确计算需要遍历所有 bucket 检查哪些 key 是 inline 的，会把 `MEMORY USAGE` 从 O(1) 变成 O(n)。

**修复后的 `dictMemUsage()` 是一个严格的上界（upper bound），但不是精确值。**

### 2.7 运维影响

如果你有以下监控告警，可能需要调整阈值：
- `MEMORY USAGE` 相对于 `used_memory` 的偏差告警
- 按 key 类型统计内存占用的报表
- 容量规划模型（基于 MEMORY USAGE 估算）

---

## 三、PR #15437 — 移除 dictForEach 宏

**风险等级：🟢 低（纯代码清理）**  
**合并时间：2026-07-15**  
**作者：moticless**

### 3.1 被移除的宏

```c
// dict.h 中被删除的宏
#define dictForEach(d, ty, m, ...) do { \
    dictIterator di; \
    dictEntry *de; \
    dictInitIterator(&di, d); \
    while ((de = dictNext(&di)) != NULL) { \
        ty *m = dictGetVal(de); \
        do { \
            __VA_ARGS__ \
        } while(0); \
    } \
    dictResetIterator(&di); \
} while(0);
```

### 3.2 这个宏的问题

| 问题 | 说明 |
|------|------|
| 使用范围极窄 | 全代码库仅 2 处使用（module.c 的 defrag 函数） |
| 与主流模式不一致 | 代码库中 ~286 处使用显式 `dictInitIterator/dictNext/dictResetIterator` |
| 调试困难 | 控制流藏在 `__VA_ARGS__` 宏体中，gdb 单步会乱跳 |
| 语法陷阱 | 宏体中如果有顶层逗号（如函数调用多参数），会打断宏展开 |
| 尾部多余分号 | 调用时写成 `dictForEach(...);` 会产生空语句警告 |

### 3.3 替换后的代码

**module.c 中的两处替换：**

```c
// moduleDefragStart —— 修复前
void moduleDefragStart(void) {
    dictForEach(modules, struct RedisModule, module, 
        if (module->defrag_start_cb) {
            RedisModuleDefragCtx defrag_ctx = INIT_MODULE_DEFRAG_CTX(...);
            module->defrag_start_cb(&defrag_ctx);
        }
    );
}

// moduleDefragStart —— 修复后
void moduleDefragStart(void) {
    dictIterator di;
    dictEntry *de;
    dictInitIterator(&di, modules);
    while ((de = dictNext(&di)) != NULL) {
        struct RedisModule *module = dictGetVal(de);
        if (module->defrag_start_cb) {
            RedisModuleDefragCtx defrag_ctx = INIT_MODULE_DEFRAG_CTX(...);
            module->defrag_start_cb(&defrag_ctx);
        }
    }
    dictResetIterator(&di);
}
```

### 3.4 为什么这个改动值得关注

虽然风险极低，但体现了 Redis 代码库的一个**工程原则**：

> "如果一个抽象（宏/函数）的使用次数极少，且增加了认知负担，不如内联展开。"

`dictForEach` 试图提供一种"更简洁"的迭代语法，但实际上：
- 省掉的代码行数有限（6 行 → 3 行有效代码）
- 引入的复杂度和陷阱超过了收益
- 与代码库中 286 处标准模式形成"两套写法"，增加维护成本

---

## 四、模块升级（#15475/#15463/#15476）简要说明

三个模块统一升级到 v8.9.90，主要变更：

| 模块 | 关键变更 |
|------|----------|
| **RediSearch** | 仅版本 pin 更新 |
| **RedisJSON** | json_path filter literals 单次物化（MOD-16300，性能优化）；新增 size/sizeof/empty 操作符（MOD-16274/16275） |
| **RedisBloom** | 仅版本 bump |
| **RedisTimeSeries** | 集群拓扑自动刷新（MOD-16382）；新增 TS.QUERYLABELS（MOD-16370）；TS.MRANGE 支持 EXCLUDEEMPTY（MOD-16172） |

**升级建议：**
- 如使用 RedisJSON，注意新增操作符可能改变现有查询语义（`size` / `sizeof` / `empty` 现在是保留关键字）
- 如使用 RedisTimeSeries 集群，拓扑刷新改为自动，不再需要手动 `TIMESERIES.REFRESHCLUSTER`

---

## 五、总结

| PR | 核心改动 | 风险 | 建议 |
|----|----------|------|------|
| #15329 | IO 线程 + 1 行代码 | 🔴 高 | **必须升级**（如用 io-threads） |
| #15462 | 内存统计公式修正 | 🟡 中 | 调整监控阈值 |
| #15437 | 移除宏，内联展开 | 🟢 低 | 无需关注 |
| 模块升级 | v8.9.90 | 🟡 中低 | 按需升级 |

最值得关注的是 **#15329**：一行 `connSetWriteHandler(c->conn, NULL)` 修复了一个可能导致生产环境 CPU 100% 的并发时序 bug。这个问题的隐蔽性在于——它只在"高流量结束后的空闲期"才显现，常规的负载测试很难发现。
