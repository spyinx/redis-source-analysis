# Redis PR #15476 简要分析

## 一、基本信息

| 项目 | 内容 |
|------|------|
| **PR 标题** | Update RedisTimeSeries module to v8.9.90 |
| **PR 链接** | https://github.com/redis/redis/pull/15476 |
| **作者** | Tom Gabsow (gabsow) |
| **合并者** | gabsow |
| **合并时间** | 2026-07-16 |
| **风险等级** | 🟡 Low-Medium |

---

## 二、变更内容

更新 `modules/modules.yaml` 中 RedisTimeSeries 版本 pin：v8.9.82 → v8.9.90

---

## 三、RedisTimeSeries v8.9.90 新特性

| MOD | 描述 |
|-----|------|
| **MOD-16382** | 集群拓扑变更自动刷新（替代手动 `TIMESERIES.REFRESHCLUSTER`） |
| **MOD-16370** | 新增 `TS.QUERYLABELS` 命令：返回符合过滤条件的标签列表 |
| **MOD-16172** | `TS.MRANGE` / `TS.MREVRANGE` 支持 `EXCLUDEEMPTY` |
| **MOD-16873** | `TS.INCRBY` 复制时，若给定时间戳低于主节点时间戳，则复制主节点时间戳 |

---

## 四、影响

- 使用 RedisTimeSeries 集群的用户不再需要手动调用 `TIMESERIES.REFRESHCLUSTER`
- `TS.QUERYLABELS` 是全新命令，不影响现有逻辑
- `EXCLUDEEMPTY` 是新选项，默认行为不变
