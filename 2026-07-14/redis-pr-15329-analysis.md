# Redis PR #15329 详细分析文档

## 一、基本信息

| 项目 | 内容 |
|------|------|
| **PR 标题** | Fix IO thread busy looping for repl clients |
| **PR 链接** | https://github.com/redis/redis/pull/15329 |
| **作者** | minchopaskal |
| **合并者** | minchopaskal |
| **创建时间** | 2026-06-11 |
| **合并时间** | 2026-07-14 |
| **目标分支** | redis:unstable |
| **关联 Issue** | #15311 |
| **风险等级** | 🔴 High |

---

## 二、问题现象

启用 IO 线程（`io-threads > 1`）且有复制客户端（replica）连接时，**高流量结束后 IO 线程 CPU 可能持续 100%**，即使主节点完全空闲。

---

## 三、根因：一个微妙的时序窗口

### 3.1 触发路径

```
┌─────────────────────────────────────────────────────────────────┐
│  时序图：写 handler 是如何"滞留"的                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Main Thread                            IO Thread               │
│  ───────────                            ────────                │
│                                                                 │
│  writeToClient(c) ──► 未写完所有数据                              │
│       │                                                         │
│       ▼                                                         │
│  安装 write handler ──► connSetWriteHandler                     │
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

### 3.2 为什么偏偏是复制客户端？

> "replica clients always have big replies when traffic is high, whereas normal clients tend not to have sustained outgoing big traffic"

普通客户端的回复通常很小（OK、某个值），一次 `writeToClient` 就能写完，不会触发写 handler 的安装。而复制客户端需要持续发送 RDB / 增量数据，socket 缓冲区很容易被填满。

---

## 四、代码改动分析

### 4.1 修复前（iothread.c）

```c
void enqueuePendingClientsToMainThread(client *c, int unbind) {
    // ...
    /* Disable read and write to avoid race when main thread processes. */
    c->io_flags &= ~(CLIENT_IO_READ_ENABLED | CLIENT_IO_WRITE_ENABLED);
    /* ❌ 问题：只清除了标志，没有从 epoll 中注销 write handler */
    // ...
}
```

### 4.2 修复后

```c
void enqueuePendingClientsToMainThread(client *c, int unbind) {
    // ...
    /* Disable read and write to avoid race when main thread processes. */
    c->io_flags &= ~(CLIENT_IO_READ_ENABLED | CLIENT_IO_WRITE_ENABLED);
    connSetWriteHandler(c->conn, NULL);  // ✅ 关键修复
    // ...
}
```

### 4.3 为什么这行代码能解决问题？

| 阶段 | 修复前 | 修复后 |
|------|--------|--------|
| 客户端移交主线程 | 标志清除，handler 残留 | 标志清除 + handler 注销 |
| 客户端返回 IO 线程 | writeToClient(c,0) 发现标志=0，直接返回 | 无残留 handler，epoll 不会触发 |
| 流量停止后 | epoll 持续触发 EPOLLOUT → 忙循环 | IO 线程正常休眠 |

---

## 五、测试用例分析

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

---

## 六、影响评估

| 场景 | 影响 |
|------|------|
| 使用 `io-threads > 1` + 复制 | 🔴 **必须升级**，高流量后可能 CPU 100% |
| 使用 `io-threads > 1` 无复制 | 🟡 理论上也可能触发，但概率极低 |
| 不使用 IO 线程 | 🟢 不受影响 |

---

## 七、总结

仅修改 **1 行代码**，但修复了一个可能导致生产环境 CPU 100% 的并发时序 bug。问题的隐蔽性在于——它只在"高流量结束后的空闲期"才显现，常规的负载测试很难发现。

如果你用了 `io-threads > 1`，这个 PR 必须 cherry-pick。
