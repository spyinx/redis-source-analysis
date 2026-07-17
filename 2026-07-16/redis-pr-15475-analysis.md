# Redis PR #15475 简要分析

## 一、基本信息

| 项目 | 内容 |
|------|------|
| **PR 标题** | MOD-16885: Update RediSearch module to v8.9.90 |
| **PR 链接** | https://github.com/redis/redis/pull/15475 |
| **作者** | Omer Shadmi (oshadmi) |
| **合并者** | oshadmi |
| **合并时间** | 2026-07-16 |
| **风险等级** | 🟡 Low-Medium |

---

## 二、变更内容

- 更新 `modules/modules.yaml` 中 RediSearch 的版本 pin：v8.9.82 → v8.9.90
- 由于 `unstable` 分支已改用 `modules/modules.yaml` 作为单一数据源，不再修改 `modules/redisearch/Makefile`

验证命令：
```bash
scripts/lib/manifest.sh ref redisearch       # → v8.9.90
scripts/lib/manifest.sh ref-kind redisearch  # → tag
```

---

## 三、影响

Manifest-only 变更，无 Redis 核心代码改动。运行时风险取决于 RediSearch v8.9.90 本身的行为变化。建议关注 RediSearch 官方 release notes。
