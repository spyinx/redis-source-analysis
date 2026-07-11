#!/usr/bin/env python3
"""
reproduce_generator.py - 复现脚本生成器
根据提交内容自动生成一键复现脚本。
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime
from urllib.request import Request, urlopen

# ============ 配置 ============
GH_TOKEN_PATH = os.path.expanduser("~/.config/gh/config.yml")

def get_token():
    try:
        with open(GH_TOKEN_PATH) as f:
            for line in f:
                if "oauth_token:" in line:
                    return line.split("oauth_token:")[1].strip()
    except Exception:
        pass
    return None

TOKEN = get_token()

def github_api(url):
    req = Request(url)
    req.add_header("Accept", "application/vnd.github.v3+json")
    if TOKEN:
        req.add_header("Authorization", f"token {TOKEN}")
    try:
        with urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except Exception as e:
        print(f"API Error: {e}", file=sys.stderr)
        return None


def fetch_commit(repo, sha):
    return github_api(f"https://api.github.com/repos/{repo}/commits/{sha}")


def detect_vulnerability_type(message, files, patches):
    """根据提交内容检测漏洞/bug 类型"""
    msg_lower = message.lower()
    combined = msg_lower + " ".join(patches).lower()
    
    vuln_types = []
    
    # 整数溢出
    if any(k in combined for k in ["overflow", "underflow", "signed", "unsigned", "llong", "long long"]):
        vuln_types.append("INTEGER_OVERFLOW")
    
    # 缓冲区溢出
    if any(k in combined for k in ["buffer", "memcpy", "memmove", "strcpy", "strncpy", "sprintf", "snprintf", "overflow"]):
        if "integer" not in combined:
            vuln_types.append("BUFFER_OVERFLOW")
    
    # 命令解析问题
    if any(k in combined for k in ["parse", "command", "protocol", "argument", "input", "validation"]):
        vuln_types.append("COMMAND_PARSING")
    
    # 内存泄漏
    if any(k in combined for k in ["leak", "free", "malloc", "calloc", "realloc", "sdsfree", "zfree"]):
        vuln_types.append("MEMORY_LEAK")
    
    # 竞争条件
    if any(k in combined for k in ["race", "deadlock", "lock", "mutex", "atomic", "concurrent", "thread"]):
        vuln_types.append("RACE_CONDITION")
    
    # 空指针/野指针
    if any(k in combined for k in ["null", "dangling", "use-after-free", "uaf"]):
        vuln_types.append("NULL_POINTER")
    
    # DoS / 拒绝服务
    if any(k in combined for k in ["dos", "denial", "crash", "segfault", "oom", "infinite", "loop", "hang"]):
        vuln_types.append("DOS")
    
    # 默认类型
    if not vuln_types:
        vuln_types.append("GENERAL")
    
    return vuln_types


def extract_key_values(patches):
    """从 diff 中提取关键数值（用于构造 PoC）"""
    values = {
        "offsets": [],
        "sizes": [],
        "commands": [],
        "numbers": [],
    }
    
    for patch in patches:
        # 提取偏移量
        offset_matches = re.findall(r'#?(\d{10,})', patch)
        values["offsets"].extend(offset_matches)
        
        # 提取尺寸/长度
        size_matches = re.findall(r'(\d+)(?:\s*\*\s*\d+)?', patch)
        values["sizes"].extend(size_matches)
        
        # 提取 Redis 命令
        cmd_matches = re.findall(r'(?:BITFIELD|GET|SET|INCRBY|HSET|HGET|LPUSH|RPUSH|SADD|ZADD|CONFIG|DEBUG|CLIENT|MODULE)(?:_\w+)?', patch, re.IGNORECASE)
        values["commands"].extend(cmd_matches)
        
        # 提取大数字
        big_nums = re.findall(r'\b(\d{8,})\b', patch)
        values["numbers"].extend(big_nums)
    
    return values


def generate_integer_overflow_script(sha, repo, message, values, patches):
    """生成整数溢出复现脚本"""
    
    # 尝试从提交消息或补丁中提取关键数值
    offset = None
    for o in values.get("offsets", []):
        if len(o) >= 10:
            offset = o
            break
    
    # 尝试提取命令和类型
    command = "BITFIELD"
    field_type = "i64"
    
    if "BITFIELD_RO" in message.upper():
        command = "BITFIELD_RO"
    elif "bitfield_ro" in message.lower():
        command = "BITFIELD_RO"
    
    type_match = re.search(r'(i|u)(\d+)', message)
    if type_match:
        field_type = f"{type_match.group(1)}{type_match.group(2)}"
    else:
        # 从补丁中找
        for p in patches:
            tm = re.search(r'(i|u)(\d+)', p)
            if tm:
                field_type = f"{tm.group(1)}{tm.group(2)}"
                break
    
    # 构造偏移值
    if not offset:
        # 默认使用一个会溢出的值
        offset = "144115188075855872"  # LLONG_MAX / 64 + 1
    
    poc_commands = f"""
# 触发有符号整数溢出
{command} test_key GET {field_type} '#{offset}'
"""
    
    return f"""#!/usr/bin/env bash
# 复现脚本: 整数溢出漏洞
# 来源: {repo}@{sha}
# 生成时间: {datetime.now().isoformat()}
# 漏洞类型: 有符号整数溢出

set -euo pipefail

RED="\\033[0;31m"
GREEN="\\033[0;32m"
YELLOW="\\033[1;33m"
NC="\\033[0m"

echo -e "${{YELLOW}}=== Redis 整数溢出漏洞复现 ===${{NC}}"
echo "来源提交: {sha}"
echo "描述: {message.split(chr(10))[0]}"
echo ""

# 检查 redis-cli
if ! command -v redis-cli &> /dev/null; then
    echo -e "${{RED}}错误: redis-cli 未找到${{NC}}"
    echo "请确保 Redis 已安装并在 PATH 中"
    exit 1
fi

# 检查 Redis 服务器连接
echo -e "${{YELLOW}}[1/3] 检查 Redis 服务器...${{NC}}"
if ! redis-cli PING &> /dev/null; then
    echo -e "${{RED}}错误: 无法连接到 Redis 服务器${{NC}}"
    echo "请确保 Redis 服务器正在运行: redis-server --port 6379"
    exit 1
fi
echo -e "${{GREEN}}✓ Redis 服务器可用${{NC}}"

# 执行 PoC 命令
echo ""
echo -e "${{YELLOW}}[2/3] 执行溢出触发命令...${{NC}}"
echo "命令: {command} test_key GET {field_type} '#{offset}'"
echo ""

echo "--- 修复前预期行为 ---"
echo "如果使用 UBSAN 构建的 Redis，此命令会导致服务器进程异常终止"
echo "日志应显示: runtime error: signed integer overflow"
echo ""

echo "--- 修复后预期行为 ---"
echo "此命令应返回错误: ERR bit offset is not an integer or out of range"
echo "服务器应继续正常运行"
echo ""

echo "--- 执行中 ---"
redis-cli << 'REDIS_EOF'
{poc_commands.strip()}
REDIS_EOF

RC=$?

# 验证服务器是否存活
echo ""
echo -e "${{YELLOW}}[3/3] 验证服务器状态...${{NC}}"
if redis-cli PING &> /dev/null; then
    echo -e "${{GREEN}}✓ 服务器仍然存活 (PING 成功)${{NC}}"
    echo -e "${{GREEN}}✓ 漏洞已修复或未能复现${{NC}}"
else
    echo -e "${{RED}}✗ 服务器无响应 (可能已崩溃)${{NC}}"
    echo -e "${{RED}}✗ 漏洞复现成功!${{NC}}"
fi

echo ""
echo -e "${{YELLOW}}=== 复现完成 ===${{NC}}"
echo "退出码: $RC"

# 清理
redis-cli DEL test_key &> /dev/null || true
"""


def generate_buffer_overflow_script(sha, repo, message, values, patches):
    """生成缓冲区溢出复现脚本"""
    return f"""#!/usr/bin/env bash
# 复现脚本: 缓冲区溢出/内存安全问题
# 来源: {repo}@{sha}
# 生成时间: {datetime.now().isoformat()}

set -euo pipefail

echo "=== 缓冲区溢出漏洞复现 ==="
echo "来源提交: {sha}"
echo "描述: {message.split(chr(10))[0]}"
echo ""

echo "[INFO] 此漏洞可能涉及内存安全问题"
echo "[INFO] 建议使用 Valgrind 或 AddressSanitizer 构建 Redis 进行测试"
echo ""

echo "编译带 ASAN 的 Redis:"
echo "  make -C src SANITIZER=address OPTIMIZATION=-O0 redis-server"
echo ""

echo "使用 Valgrind 运行:"
echo "  valgrind --tool=memcheck --leak-check=full ./redis-server"
echo ""

echo "[WARN] 请根据具体漏洞类型手动构造测试数据"
echo "建议查看提交 diff 以了解具体的输入触发条件"
"""


def generate_command_parsing_script(sha, repo, message, values, patches):
    """生成命令解析问题复现脚本"""
    commands = values.get("commands", [])
    cmd = commands[0] if commands else "BITFIELD"
    
    return f"""#!/usr/bin/env bash
# 复现脚本: 命令解析/输入验证问题
# 来源: {repo}@{sha}
# 生成时间: {datetime.now().isoformat()}

set -euo pipefail

echo "=== 命令解析问题复现 ==="
echo "来源提交: {sha}"
echo "描述: {message.split(chr(10))[0]}"
echo ""

if ! command -v redis-cli &> /dev/null; then
    echo "错误: redis-cli 未找到"
    exit 1
fi

# 尝试构造边界输入
echo "[INFO] 尝试构造边界输入..."
echo ""

# 根据命令类型构造测试用例
case "{cmd}" in
    BITFIELD|BITFIELD_RO)
        echo "测试 BITFIELD 边界输入..."
        redis-cli BITFIELD test_key GET i64 '#999999999999999999' 2>/dev/null || echo "已拒绝非法输入"
        ;;
    CONFIG)
        echo "测试 CONFIG 命令..."
        redis-cli CONFIG SET maxmemory 999999999999999999 2>/dev/null || echo "已拒绝非法输入"
        ;;
    *)
        echo "[WARN] 请手动查看提交 diff 构造测试命令"
        echo "涉及命令: {cmd}"
        ;;
esac

echo ""
echo "=== 复现完成 ==="
"""


def generate_general_script(sha, repo, message, values, patches):
    """通用复现脚本模板"""
    return f"""#!/usr/bin/env bash
# 复现脚本: 通用问题复现
# 来源: {repo}@{sha}
# 生成时间: {datetime.now().isoformat()}

set -euo pipefail

echo "=== 通用问题复现框架 ==="
echo "来源提交: {sha}"
echo "描述: {message.split(chr(10))[0]}"
echo ""

echo "[INFO] 此脚本为通用模板，请根据具体情况调整"
echo ""

echo "=== 步骤 1: 环境准备 ==="
echo "建议编译带 sanitizer 的 Redis 以检测问题:"
echo ""
echo "  # AddressSanitizer (内存问题)"
echo "  make -C src SANITIZER=address OPTIMIZATION=-O0 redis-server"
echo ""
echo "  # UndefinedBehaviorSanitizer (整数溢出等)"
echo "  make -C src SANITIZER=undefined OPTIMIZATION=-O0 redis-server"
echo ""
echo "  # Valgrind (内存泄漏检测)"
echo "  valgrind --tool=memcheck --leak-check=full ./redis-server"
echo ""

echo "=== 步骤 2: 分析提交内容 ==="
echo "查看完整 diff: https://github.com/{repo}/commit/{sha}"
echo ""

echo "=== 步骤 3: 构造测试用例 ==="
echo "根据 diff 中的修改，构造能触发原问题的输入"
echo ""

echo "=== 关键文件变更 ==="
""" + "\n".join([f"  - {p[:50]}..." for p in patches[:5]]) + """
"""


def generate_reproduce_script(sha, repo, commit_type, commit_data):
    """生成复现脚本"""
    message = commit_data["commit"]["message"]
    files = commit_data.get("files", [])
    patches = [f.get("patch", "") for f in files]
    
    # 检测漏洞类型
    vuln_types = detect_vulnerability_type(message, files, patches)
    values = extract_key_values(patches)
    
    # 根据类型选择生成器
    if "INTEGER_OVERFLOW" in vuln_types:
        script = generate_integer_overflow_script(sha, repo, message, values, patches)
    elif "BUFFER_OVERFLOW" in vuln_types or "MEMORY_LEAK" in vuln_types:
        script = generate_buffer_overflow_script(sha, repo, message, values, patches)
    elif "COMMAND_PARSING" in vuln_types:
        script = generate_command_parsing_script(sha, repo, message, values, patches)
    else:
        script = generate_general_script(sha, repo, message, values, patches)
    
    return script


def main():
    parser = argparse.ArgumentParser(description="生成复现脚本")
    parser.add_argument("--sha", required=True, help="提交 SHA")
    parser.add_argument("--repo", default="redis/redis", help="仓库名")
    parser.add_argument("--type", default="BUGFIX", help="提交类型")
    parser.add_argument("--output", required=True, help="输出文件路径")
    
    args = parser.parse_args()
    
    print(f"Generating reproduce script for {args.sha}...")
    
    # 获取提交数据
    commit_data = fetch_commit(args.repo, args.sha)
    if not commit_data:
        print("Failed to fetch commit data", file=sys.stderr)
        sys.exit(1)
    
    # 生成脚本
    script = generate_reproduce_script(args.sha, args.repo, args.type, commit_data)
    
    # 写入文件
    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        f.write(script)
    
    # 设置可执行权限
    os.chmod(args.output, 0o755)
    
    print(f"Reproduce script saved to: {args.output}")
    print(f"Run with: bash {args.output}")


if __name__ == "__main__":
    main()
