#!/usr/bin/env python3
"""
reproduce_generator.py - 复现脚本生成器
按 PR 编号生成一键复现脚本。
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime
from urllib.request import Request, urlopen

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

def get_pr_for_commit(repo, sha):
    prs = github_api(f"https://api.github.com/repos/{repo}/commits/{sha}/pulls")
    if prs and len(prs) > 0:
        return prs[0]
    return None

def generate_reproduce_script(pr_num, repo, commit_type, title):
    """生成复现脚本"""
    
    script = f"""#!/usr/bin/env bash
# 复现脚本: {title}
# 来源: {repo} PR #{pr_num}
# 类型: {commit_type}
# 生成时间: {datetime.now().isoformat()}

set -euo pipefail

echo "=== 复现脚本: PR #{pr_num} ==="
echo "标题: {title}"
echo ""

# 请根据具体漏洞/bug 类型补充复现步骤
echo "[INFO] 此脚本为模板，请根据分析文档补充具体复现命令"
echo "详细分析文档: redis-pr-{pr_num}-analysis.md"
echo ""

# 通用环境检查
if ! command -v redis-cli &> /dev/null; then
    echo "错误: redis-cli 未找到"
    exit 1
fi

echo "[OK] 环境检查通过"
echo ""
echo "=== 请根据分析文档中的'复现步骤'章节执行具体命令 ==="
"""
    return script

def main():
    parser = argparse.ArgumentParser(description="生成复现脚本")
    parser.add_argument("--sha", required=True, help="提交 SHA")
    parser.add_argument("--repo", default="redis/redis", help="仓库名")
    parser.add_argument("--type", default="BUGFIX", help="提交类型")
    parser.add_argument("--output", required=True, help="输出文件路径")
    
    args = parser.parse_args()
    
    pr = get_pr_for_commit(args.repo, args.sha)
    if not pr:
        print("No PR found", file=sys.stderr)
        sys.exit(1)
    
    pr_num = pr['number']
    title = pr.get('title', '')
    
    script = generate_reproduce_script(pr_num, args.repo, args.type, title)
    
    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        f.write(script)
    os.chmod(args.output, 0o755)
    
    print(f"Reproduce script saved to: {args.output}")

if __name__ == "__main__":
    main()
