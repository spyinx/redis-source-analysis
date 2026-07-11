# Redis 源码每日提交分析

自动监控 Redis 官方仓库的每日提交，识别并深度分析重要的 bug 修复、安全漏洞修复和新功能更新。

## 目录结构

```
redis-source-analysis/
├── scripts/                    # 监控和分析脚本
│   ├── daily_monitor.sh        # 每日监控入口
│   ├── analyze_commit.py       # 提交分析引擎
│   └── reproduce_generator.py  # 复现脚本生成器
├── 2026-07-11/                 # 按日期组织的分析文档
│   └── commits.md              # 当天重要提交分析
└── README.md
```

## 提交分类

- 🔴 **Security** - 安全漏洞修复（必须分析）
- 🐛 **Bug Fix** - 重要 bug 修复（必须分析）
- ✨ **Feature** - 新功能（必须分析）
- 🧪 **Test** - 测试代码（可忽略）
- 📝 **Doc** - 文档更新（可忽略）
- 🔧 **Refactor** - 重构（视情况）

## 自动化

每日自动运行，通过 cron 定时触发监控脚本。
