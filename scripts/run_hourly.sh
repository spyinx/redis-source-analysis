#!/usr/bin/env bash
# 每小时监控入口 - 确保环境正确
set -euo pipefail

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
export HOME="/root"

cd /root/.openclaw/workspace/redis-source-analysis
bash scripts/hourly_monitor.sh >> /tmp/redis-monitor.log 2>&1
