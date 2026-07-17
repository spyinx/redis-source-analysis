# Redis PR #15462 详细分析文档

## 一、基本信息

| 项目 | 内容 |
|------|------|
| **PR 标题** | Fix dictMemUsage() over-counting no_value entries |
| **PR 链接** | https://github.com/redis/redis/pull/15462 |
| **作者** | Filipe Oliveira (fcostaoliveira) |
| **合并者** | filipecosta90 |
| **合并时间** | 2026-07-17 |
| **关联 Issue** | #15461 |
| **风险等级** | 🟡 Medium |

---

## 二、问题本质

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

---

## 三、问题代码

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

---

## 四、修复代码

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

---

## 五、实测数据

| 数据结构 | 修复前 (B/entry) | 修复后 (B/entry) | 偏差 |
|----------|-----------------|-----------------|------|
| Set (HT) | 12.26 | 4.25 | -8.01 |
| Zset index | 18.29 | 10.28 | -8.01 |
| Hash (HT) | 16.29 | 8.30 | -8.00 |

> 注：绝对值不等于 8B 是因为还有 bucket 指针数组的开销被平摊了，但偏差精确等于 8B。

---

## 六、为什么故意保留一点误差？

注释说明：
> "inline-stored keys allocate 0 B but are still charged 16 B; crediting them 0 would require an O(buckets) walk that contradicts the command's O(1) design"

对于 `no_value=1` 的字典，如果 key 的哈希值不冲突，key 直接 inline 存储在 bucket 中（0 额外分配），但 `dictMemUsage()` 仍按 `dictEntryNoValue`（16B）计费。这是因为精确计算需要遍历所有 bucket 检查哪些 key 是 inline 的，会把 `MEMORY USAGE` 从 O(1) 变成 O(n)。

**修复后的 `dictMemUsage()` 是一个严格的上界（upper bound），但不是精确值。**

---

## 七、运维影响

如果你有以下监控告警，可能需要调整阈值：
- `MEMORY USAGE` 相对于 `used_memory` 的偏差告警
- 按 key 类型统计内存占用的报表
- 容量规划模型（基于 MEMORY USAGE 估算）
