# Redis PR #15454 简要分析

## 一、基本信息

| 项目 | 内容 |
|------|------|
| **PR 标题** | Update build-from-source docs for 8.10+ and fix build.sh flag handling |
| **PR 链接** | https://github.com/redis/redis/pull/15454 |
| **作者** | TalBarYakar |
| **合并者** | YaacovHazan |
| **合并时间** | 2026-07-14 |
| **风险等级** | 🟢 Low |

---

## 二、主要变更

- 发布流程改用 `redis-full.tar.gz`
- 启动使用 `redis.conf`（模块配置已打包进 release tarball）
- 明确 Rust 1.94 + LLVM 21 / lld 依赖（RediSearch LTO 需要）
- Ubuntu 20.04 切换到 GCC 11（PPA）以支持 C++20
- Alma/Rocky 添加 lld/llvm、python3 替代方案
- 移除 Alma 10 上的 `make modules-update`
- `scripts/build.sh` 在 `INSTALL_RUST_TOOLCHAIN=yes` 时自动安装 Rust
- 移除 `modules/Makefile` 中过时的 `handle-werrors` target

---

## 三、影响

仅影响从源码构建 Redis 8.10+ 的用户，无运行时逻辑变更。
