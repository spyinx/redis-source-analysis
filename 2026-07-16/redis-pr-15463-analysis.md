# Redis PR #15463 简要分析

## 一、基本信息

| 项目 | 内容 |
|------|------|
| **PR 标题** | Update Redis modules(json & bloom) to version v8.9.90 |
| **PR 链接** | https://github.com/redis/redis/pull/15463 |
| **作者** | Aviv David (AvivDavid23) |
| **合并者** | AvivDavid23 |
| **合并时间** | 2026-07-16 |
| **风险等级** | 🟡 Low-Medium |

---

## 二、RedisJSON v8.9.90 更新

- **MOD-16300** `perf(json_path)`: materialize filter literals once per query
- **MOD-16608** Bump ijson（减少对象内存占用）
- **MOD-16274 / MOD-16275** 新增 `size` / `sizeof` / `empty` 操作符（作用于 object）
- **MOD-16685** 新增 RedisJSON API：从 `RedisModuleKey` 打开

---

## 三、RedisBloom v8.9.90 更新

- 仅版本 bump，无功能变更

---

## 四、影响

RedisJSON 新增了 `size` / `sizeof` / `empty` 操作符，可能改变现有查询语义（这些现在是保留关键字）。如果现有 JSONPath 查询中使用了这些名称作为键名，可能需要转义或修改。
