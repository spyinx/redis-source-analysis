# Redis PR #15446 详细分析文档

## 一、基本信息

| 项目 | 内容 |
|------|------|
| **PR 标题** | Skip unready fds in select event backend |
| **PR 链接** | https://github.com/redis/redis/pull/15446 |
| **作者** | vitahlin |
| **合并者** | sundb |
| **创建时间** | 2026-07-09 |
| **合并时间** | 2026-07-10 |
| **目标分支** | redis:unstable |
| **风险等级** | Low |
| **影响范围** | 仅 select 事件后端 |

---

## 二、问题描述

### 2.1 Bug 本质

Redis 的 **select 事件后端**（`src/ae_select.c`）在处理 `select()` 系统调用返回的结果时存在逻辑缺陷：

当 `select()` 返回后，代码会遍历所有**已注册**的文件描述符（fd），检查它们在 `readfds` 或 `writefds` 中是否被置位。对于**已注册但当前并未就绪**的 fd，代码会计算出一个 `mask = AE_NONE`，但仍然将其加入 `eventLoop->fired` 数组并递增 `numevents`。

这意味着：
- 这些 fd **不会触发任何读写回调**（因为 mask 是 AE_NONE）
- 但它们**被计为已处理的事件**，导致 `aeProcessEvents()` 可能提前结束事件循环
- 在极端情况下可能导致事件处理不及时

### 2.2 代码位置

```
src/ae_select.c:74-78  — aeApiPoll() 函数中 select() 结果处理逻辑
```

---

## 三、代码改动分析

### 3.1 修改文件

| 文件 | 变更类型 | 说明 |
|------|----------|------|
| `src/ae_select.c` | 修改 | 核心修复：跳过 mask 为 AE_NONE 的 fd |

### 3.2 详细改动

**修改前代码（存在 bug）**：
```c
static int aeApiPoll(aeEventLoop *eventLoop, struct timeval *tvp) {
    // ... select() 调用 ...
    
    for (j = 0; j <= eventLoop->maxfd; j++) {
        int mask = 0;
        aeFileEvent *fe = &eventLoop->events[j];
        
        if (fe->mask == AE_NONE) continue;  // 跳过未注册的 fd
        
        if (fe->mask & AE_READABLE && FD_ISSET(j, &state->_rfds))
            mask |= AE_READABLE;
        if (fe->mask & AE_WRITABLE && FD_ISSET(j, &state->_wfds))
            mask |= AE_WRITABLE;
        
        // ⚠️ Bug: mask 可能为 AE_NONE，但仍然加入 fired
        eventLoop->fired[numevents].fd = j;
        eventLoop->fired[numevents].mask = mask;
        numevents++;
    }
    return numevents;
}
```

**修改后代码（已修复）**：
```c
static int aeApiPoll(aeEventLoop *eventLoop, struct timeval *tvp) {
    // ... select() 调用 ...
    
    for (j = 0; j <= eventLoop->maxfd; j++) {
        int mask = 0;
        aeFileEvent *fe = &eventLoop->events[j];
        
        if (fe->mask == AE_NONE) continue;  // 跳过未注册的 fd
        
        if (fe->mask & AE_READABLE && FD_ISSET(j, &state->_rfds))
            mask |= AE_READABLE;
        if (fe->mask & AE_WRITABLE && FD_ISSET(j, &state->_wfds))
            mask |= AE_WRITABLE;
        
        // ✅ 修复：跳过未就绪的 fd
        if (mask == AE_NONE) continue;
        
        eventLoop->fired[numevents].fd = j;
        eventLoop->fired[numevents].mask = mask;
        numevents++;
    }
    return numevents;
}
```

### 3.3 修复逻辑

| 修复点 | 说明 |
|--------|------|
| **增加 AE_NONE 检查** | 在将 fd 加入 `fired` 数组前，检查 mask 是否为 `AE_NONE` |
| **跳过未就绪 fd** | 如果 fd 注册了但没有读/写事件就绪，直接 `continue` |
| **与 epoll 后端行为一致** | epoll 后端只会报告实际就绪的 fd，现在 select 后端也如此 |

### 3.4 完整 Diff

```diff
diff --git a/src/ae_select.c b/src/ae_select.c
index 208cc32ecb4..c73b875f4e3 100644
--- a/src/ae_select.c
+++ b/src/ae_select.c
@@ -74,6 +74,7 @@ static int aeApiPoll(aeEventLoop *eventLoop, struct timeval *tvp) {
                 mask |= AE_READABLE;
             if (fe->mask & AE_WRITABLE && FD_ISSET(j,&state->_wfds))
                 mask |= AE_WRITABLE;
+            if (mask == AE_NONE) continue;
             eventLoop->fired[numevents].fd = j;
             eventLoop->fired[numevents].mask = mask;
             numevents++;
```

---

## 四、影响评估

| 维度 | 评估 |
|------|------|
| **影响范围** | 仅使用 select 后端的平台（某些旧系统或不支持 epoll 的环境） |
| **严重程度** | 低 |
| **是否涉及数据安全** | 否 |
| **是否涉及性能** | 轻微（减少不必要的事件计数） |
| **向后兼容** | 是（行为更正确） |

### 4.1 为什么风险低

- 只影响 select 后端，现代 Linux 默认使用 epoll
- 这些 fd 不会触发回调，只是被错误计数
- 修复只是一行 `continue`

---

## 五、验证

### 5.1 代码审查

查看 `src/ae_select.c` 中 `aeApiPoll()` 函数，确认在 `mask |= AE_WRITABLE;` 之后有一行：

```c
if (mask == AE_NONE) continue;
```

### 5.2 运行测试

```bash
# 编译 Redis（确保 select 后端被使用）
make -C src redis-server

# 运行事件循环相关测试
./runtest --single unit/introspection

# 或者运行所有测试
./runtest
```

---

## 六、总结

PR #15446 修复了 select 事件后端的一个轻微 bug：已注册但未就绪的文件描述符被错误地计入已处理事件。修复方案是在将 fd 加入 `fired` 数组前增加 `mask == AE_NONE` 的检查，与 epoll 后端的行为保持一致。

这是一个低风险、一行代码的修复，只影响使用 select 后端的平台。

---

*文档生成时间：2026-07-11*
*基于 PR #15446 公开信息整理*
