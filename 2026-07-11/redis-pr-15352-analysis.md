# Redis PR #15352 详细分析文档

## 一、基本信息

| 项目 | 内容 |
|------|------|
| **PR 标题** | redis-cli: add configurable latency percentiles to --latency modes |
| **PR 链接** | https://github.com/redis/redis/pull/15352 |
| **作者** | fcostaoliveira (Filipe Oliveira) |
| **合并者** | sundb |
| **创建时间** | 2026-06-19 |
| **合并时间** | 2026-07-10 |
| **目标分支** | redis:unstable |
| **风险等级** | Low |
| **影响范围** | redis-cli 工具 |

---

## 二、功能概述

### 2.1 新增功能

为 `redis-cli` 的 `--latency` 和 `--latency-history` 模式添加了**可配置的延迟百分位数（latency percentiles）**支持。

### 2.2 背景

`redis-cli --latency` 是一个常用的诊断工具，用于测量客户端到服务器的网络/处理延迟。之前该工具只报告三个指标：
- **min** — 最小延迟
- **max** — 最大延迟  
- **avg** — 平均延迟

但平均延迟往往不能反映真实的服务质量。例如：P99（99% 的请求延迟低于此值）比平均值更能说明用户体验。

### 2.3 新功能详情

新增 `--latency-percentiles <p1,p2,...>` 选项，支持报告任意百分位数，如 `50,99,99.9,99.99`。

**支持所有四种输出格式**：
- 标准格式
- CSV 格式
- raw 格式
- JSON 格式

### 2.4 使用示例

```bash
# 标准格式
$ redis-cli --latency --latency-percentiles 50,99,99.9
min: 0.031, max: 0.336, avg: 0.103 (812 samples), p50: 0.089, p99: 0.315, p99.9: 0.336

# JSON 格式
$ redis-cli --json --latency --latency-percentiles 50,99,99.9
{"min": 0.031, "max": 0.336, "avg": 0.103, "count": 812, "percentiles": {"50": 0.089, "99": 0.315, "99.9": 0.336}}
```

---

## 三、技术实现

### 3.1 HDR Histogram

百分位数使用 **HDR histogram** 库计算：
- 已在 `redis-cli --vset-recall` 和 `redis-benchmark` 中使用
- 内存有界，记录操作 O(1)
- 初始化参数：`hdr_init(1us, 3s, 3 sig figs)`

### 3.2 微秒级精度

为了使百分位数有意义，延迟测量从**毫秒级**升级为**微秒级**：
- 使用 `ustime()` 测量每次 PING 往返
- 所有延迟数据以**毫秒 + 3 位小数**报告（如 `0.089` ms）

### 3.3 ⚠️ 行为变更

即使没有使用 `--latency-percentiles`，纯 `--latency`/`--latency-history` 的输出也有变化：

| 指标 | 之前 | 现在 |
|------|------|------|
| min/max/avg | 整数毫秒（`0`, `1`） | 小数毫秒（`0.030`, `1.233`） |

**影响**：如果外部工具按旧格式解析整数列，现在会收到小数，可能需要更新解析逻辑。

---

## 四、代码改动分析

### 4.1 修改文件

| 文件 | 变更类型 | 说明 |
|------|----------|------|
| `src/redis-cli.c` | 修改 | 核心实现：参数解析、HDR histogram 集成、输出格式化 |

### 4.2 关键改动

**新增配置字段**：
```c
static struct config {
    // ... 原有字段 ...
    double *latency_percentiles;      /* 百分位数值，如 50, 99, 99.9 */
    char **latency_percentiles_labels; /* 原始字符串，用于显示 */
    int latency_percentiles_count;     /* 百分位数个数 */
};
```

**参数解析**：
```c
} else if (!strcmp(argv[i],"--latency-percentiles") && !lastarg) {
    config.latency_mode = 1;
    int pcount;
    char *plist = argv[++i];
    sds *pvec = sdssplitlen(plist, strlen(plist), ",", 1, &pcount);
    // ... 解析每个百分位数值，验证范围 [0, 100] ...
}
```

**百分位数计算**：
```c
// 使用 HDR histogram 记录每个样本
hdr_record_value(histogram, latency_us);

// 计算指定百分位数
for (int i = 0; i < config.latency_percentiles_count; i++) {
    double p = config.latency_percentiles[i];
    hdr_value_at_percentile(histogram, p, &value);
    // 输出结果
}
```

**输出格式化（标准格式）**：
```
min: 0.031, max: 0.336, avg: 0.103 (812 samples), p50: 0.089, p99: 0.315, p99.9: 0.336
```

### 4.3 完整 Diff 摘要

```diff
diff --git a/src/redis-cli.c b/src/redis-cli.c
+    double *latency_percentiles;
+    char **latency_percentiles_labels;
+    int latency_percentiles_count;

+    } else if (!strcmp(argv[i],"--latency-percentiles") && !lastarg) {
+        config.latency_mode = 1;
+        // 解析逗号分隔的百分位数列表
+        // 验证每个值在 [0, 100] 范围内
+    }

+    // 在 latency 测量循环中记录到 HDR histogram
+    hdr_record_value(histogram, latency_us);
+
+    // 输出时计算并显示百分位数
+    for (int i = 0; i < config.latency_percentiles_count; i++) {
+        hdr_value_at_percentile(histogram, p, &value);
+        printf(" p%s: %.3f", label, value / 1000.0);
+    }
```

---

## 五、使用指南

### 5.1 基本用法

```bash
# 测量延迟并显示 P50, P99, P99.9
redis-cli --latency --latency-percentiles 50,99,99.9

# 历史模式（每窗口重置 histogram）
redis-cli --latency-history --latency-percentiles 50,99

# JSON 输出
redis-cli --json --latency --latency-percentiles 50,99,99.9,99.99
```

### 5.2 验证

```bash
# 确认帮助文档包含新选项
redis-cli --help | grep latency-percentiles

# 运行延迟测试
redis-cli --latency --latency-percentiles 50,99 --intrinsic-latency 5
```

---

## 六、影响评估

| 维度 | 评估 |
|------|------|
| **影响范围** | redis-cli 用户 |
| **向后兼容** | ⚠️ 部分不兼容（min/max/avg 输出格式变化） |
| **是否需要更新客户端** | 否（仅 CLI 工具） |
| **使用场景** | 延迟诊断、性能调优、SLA 监控 |

---

## 七、总结

PR #15352 为 `redis-cli --latency` 增加了高度可配置的延迟百分位数报告功能，使用 HDR histogram 实现高效计算。这是一个对运维和性能调优非常有用的增强，但需要注意**默认输出的 min/max/avg 已从整数变为小数**，可能影响到现有自动化工具的解析逻辑。

---

*文档生成时间：2026-07-11*
*基于 PR #15352 公开信息整理*
