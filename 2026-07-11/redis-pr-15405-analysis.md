# Redis PR #15405 详细分析文档

## 一、基本信息

| 项目 | 内容 |
|------|------|
| **PR 标题** | Add LMOVEM/BLMOVEM commands |
| **PR 链接** | https://github.com/redis/redis/pull/15405 |
| **作者** | minchopaskal |
| **合并者** | minchopaskal |
| **创建时间** | 2026-07-02 |
| **合并时间** | 2026-07-09 |
| **目标分支** | redis:unstable |
| **风险等级** | Medium |
| **影响范围** | List 命令、阻塞命令、模块接口 |

---

## 二、功能概述

### 2.1 新增命令

新增两个 List 命令：

| 命令 | 功能 | 阻塞 |
|------|------|------|
| `LMOVEM` | 批量移动列表元素 | 否 |
| `BLMOVEM` | 批量移动列表元素 | 是（阻塞版） |

### 2.2 与现有命令对比

| 命令 | 功能 | 单次移动元素数 |
|------|------|----------------|
| `LMOVE` | 从一个列表弹出并推入另一个列表 | 1 个 |
| `BLMOVE` | 阻塞版 LMOVE | 1 个 |
| `LMOVEM` | **批量**从一个列表弹出并推入另一个列表 | **N 个** |
| `BLMOVEM` | **阻塞版**批量移动 | **N 个** |

### 2.3 LMOVEM 语法

```
LMOVEM source destination <LEFT|RIGHT> <LEFT|RIGHT> [COUNT|EXACTLY count OBO|BULK]
```

**参数说明**：
- `source` / `destination`: 源列表和目标列表
- 第一个 `LEFT|RIGHT`: 从源列表的哪一端弹出
- 第二个 `LEFT|RIGHT`: 推入目标列表的哪一端
- `COUNT count`: 最多移动 `count` 个元素（同 `LPOP` 语义）
- `EXACTLY count`: 必须移动恰好 `count` 个元素，不足时返回 nil
- `OBO` (One By One): 逐个移动，保持原始顺序的逆序
- `BULK`: 批量移动，保持原始顺序

### 2.4 BLMOVEM 语法

```
BLMOVEM source destination <LEFT|RIGHT> <LEFT|RIGHT> timeout [COUNT|EXACTLY count OBO|BULK]
```

- `timeout`: 阻塞超时时间（秒）
- `COUNT`: 仅在源列表为空时阻塞
- `EXACTLY`: 在源列表为空或元素不足时阻塞，直到有足够元素或超时

### 2.5 使用示例

```bash
# 准备数据
> RPUSH l1 1 2 3 4
(integer) 4
> RPUSH l2 5 6 7
(integer) 3

# OBO 模式（逐个移动，结果逆序）
> LMOVEM l1 l2 LEFT LEFT COUNT 2 OBO
1) "2"
2) "1"
> LRANGE l2 0 -1
1) "2"
2) "1"
3) "5"
4) "6"
5) "7"

# BULK 模式（批量移动，保持顺序）
> RPUSH l1 1 2 3 4
> LMOVEM l1 l2 LEFT LEFT COUNT 2 BULK
1) "1"
2) "2"

# EXACTLY 模式（元素不足时返回 nil）
> RPUSH l1 1 2
> LMOVEM l1 l2 LEFT LEFT EXACTLY 3 BULK
(nil)

# 阻塞版
> BLMOVEM l1 l2 LEFT LEFT 0 COUNT 2 OBO
# 阻塞直到 l1 有元素
```

---

## 三、技术实现

### 3.1 核心改动

| 文件 | 说明 |
|------|------|
| `src/t_list.c` | LMOVEM/BLMOVEM 命令实现 |
| `src/blocked.c` | 阻塞逻辑：新增 `BLOCKED_LIST_NONEMPTY` 类型 |
| `src/server.h` | 新增命令定义和阻塞类型枚举 |
| `src/commands/*.json` | 命令参数定义 |
| `tests/unit/type/list.tcl` | 新命令单元测试 |

### 3.2 关键设计：BLOCKED_LIST_NONEMPTY

`BLMOVEM EXACTLY` 需要等待源列表**增长到足够长度**。这与现有阻塞命令（如 `BLPOP`）不同：

- `BLPOP` 阻塞直到列表**从无到有**
- `BLMOVEM EXACTLY` 阻塞直到列表**长度达到指定值**

为此引入了新的阻塞类型 `BLOCKED_LIST_NONEMPTY` 和信号机制 `signalKeyAsReadyNonEmptyList`：

```c
// 当列表 push 操作增加长度时，唤醒等待 nonempty 的客户端
if (listLength(subject) >= needed_count) {
    signalKeyAsReadyNonEmptyList(c->db, key);
}
```

### 3.3 复制重写

`BLMOVEM` 在主从复制时被重写为 `LMOVEM … EXACTLY N …`，避免从库也需要阻塞等待。

### 3.4 模块兼容性

新增 `readyList.wake_modules` 机制，确保模块客户端不会被普通写操作误唤醒，同时允许显式就绪信号和 key 创建信号。

---

## 四、代码改动分析

### 4.1 LMOVEM 命令实现

```c
void lmovemCommand(client *c) {
    // 1. 解析参数：source, dest, left/right, count/exactly, obo/bulk
    // 2. 检查源列表是否存在且长度足够
    // 3. 根据 OBO/BULK 模式逐个或批量移动
    // 4. 返回移动的元素数组
}
```

### 4.2 BLMOVEM 阻塞逻辑

```c
void blmovemCommand(client *c) {
    // 1. 尝试立即执行 LMOVEM
    // 2. 如果条件不满足（列表空或长度不足）
    // 3. 注册为 BLOCKED_LIST_NONEMPTY 阻塞客户端
    // 4. 等待信号或超时
}
```

### 4.3 信号唤醒

```c
void signalKeyAsReadyNonEmptyList(redisDb *db, robj *key) {
    // 只唤醒等待 nonempty list 的阻塞客户端
    // 不影响普通 BLPOP 等待者
}
```

---

## 五、风险与注意事项

| 维度 | 评估 |
|------|------|
| **影响范围** | 使用 List 结构 + 批量移动场景的用户 |
| **向后兼容** | 是（新增命令） |
| **客户端支持** | 需要客户端库更新以识别新命令 |
| **模块兼容性** | 需要验证模块阻塞逻辑不受影响 |
| **风险点** | 阻塞唤醒语义复杂，错误实现可能导致客户端卡住 |

### 5.1 为什么风险 Medium

- 改动核心阻塞和 key-ready 信号机制
- 影响所有 list blocker 和模块 key blocking
- 不正确的唤醒语义可能导致 stuck clients 或意外的 module unblock

---

## 六、验证

```bash
# 运行 list 相关测试
./runtest --single unit/type/list

# 手动测试
redis-cli RPUSH src a b c d
redis-cli RPUSH dst x y z
redis-cli LMOVEM src dst LEFT RIGHT COUNT 2 BULK
redis-cli LRANGE dst 0 -1
```

---

## 七、总结

PR #15405 新增了 `LMOVEM` 和 `BLMOVEM` 命令，提供 List 的批量移动能力。核心设计亮点：
- `COUNT`/`EXACTLY` 两种批量语义
- `OBO`/`BULK` 两种顺序模式
- 引入 `BLOCKED_LIST_NONEMPTY` 解决"等待列表增长到指定长度"的阻塞需求

这是一个实用的功能增强，减少了多次 `LMOVE` 的往返开销，但需要注意阻塞唤醒语义的正确性。

---

*文档生成时间：2026-07-11*
*基于 PR #15405 公开信息整理*
