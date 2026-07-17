# Redis PR #15437 详细分析文档

## 一、基本信息

| 项目 | 内容 |
|------|------|
| **PR 标题** | Remove single-use dictForEach macro |
| **PR 链接** | https://github.com/redis/redis/pull/15437 |
| **作者** | moticless |
| **合并者** | moticless |
| **合并时间** | 2026-07-15 |
| **风险等级** | 🟢 Low |

---

## 二、被移除的宏

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

---

## 三、这个宏的问题

| 问题 | 说明 |
|------|------|
| 使用范围极窄 | 全代码库仅 2 处使用（module.c 的 defrag 函数） |
| 与主流模式不一致 | 代码库中 ~286 处使用显式 `dictInitIterator/dictNext/dictResetIterator` |
| 调试困难 | 控制流藏在 `__VA_ARGS__` 宏体中，gdb 单步会乱跳 |
| 语法陷阱 | 宏体中如果有顶层逗号（如函数调用多参数），会打断宏展开 |
| 尾部多余分号 | 调用时写成 `dictForEach(...);` 会产生空语句警告 |

---

## 四、替换后的代码

### moduleDefragStart

```c
// 修复前
dictForEach(modules, struct RedisModule, module, 
    if (module->defrag_start_cb) {
        RedisModuleDefragCtx defrag_ctx = INIT_MODULE_DEFRAG_CTX(...);
        module->defrag_start_cb(&defrag_ctx);
    }
);

// 修复后
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
```

---

## 五、为什么这个改动值得关注

虽然风险极低，但体现了 Redis 代码库的一个**工程原则**：

> "如果一个抽象（宏/函数）的使用次数极少，且增加了认知负担，不如内联展开。"

`dictForEach` 试图提供一种"更简洁"的迭代语法，但实际上：
- 省掉的代码行数有限（6 行 → 3 行有效代码）
- 引入的复杂度和陷阱超过了收益
- 与代码库中 286 处标准模式形成"两套写法"，增加维护成本
