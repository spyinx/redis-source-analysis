#!/usr/bin/env python3
"""
analyze_commit.py - Redis 提交深度分析引擎
自动获取提交详情，生成结构化分析文档。
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime
from urllib.request import Request, urlopen
from urllib.error import HTTPError

# ============ 配置 ============
GH_TOKEN_PATH = os.path.expanduser("~/.config/gh/config.yml")

def get_token():
    """从 gh config 读取 token"""
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
    """调用 GitHub API"""
    req = Request(url)
    req.add_header("Accept", "application/vnd.github.v3+json")
    if TOKEN:
        req.add_header("Authorization", f"token {TOKEN}")
    try:
        with urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except HTTPError as e:
        print(f"API Error: {e.code} - {e.reason}", file=sys.stderr)
        if e.code == 403:
            print("Rate limit exceeded. Consider using a GitHub token.", file=sys.stderr)
        return None
    except Exception as e:
        print(f"Request Error: {e}", file=sys.stderr)
        return None


def fetch_commit(repo, sha):
    """获取提交详情"""
    return github_api(f"https://api.github.com/repos/{repo}/commits/{sha}")


def fetch_pr_for_commit(repo, sha):
    """查找提交关联的 PR"""
    prs = github_api(f"https://api.github.com/repos/{repo}/commits/{sha}/pulls")
    if prs and len(prs) > 0:
        return prs[0]
    return None


def fetch_issue(repo, issue_number):
    """获取 Issue 详情"""
    return github_api(f"https://api.github.com/repos/{repo}/issues/{issue_number}")


def analyze_diff(files):
    """分析文件变更"""
    analysis = {
        "new_files": [],
        "modified_files": [],
        "deleted_files": [],
        "c_files": [],
        "test_files": [],
        "doc_files": [],
        "build_files": [],
        "total_additions": 0,
        "total_deletions": 0,
        "key_functions": set(),
    }
    
    for f in files:
        filename = f.get("filename", "")
        status = f.get("status", "modified")
        additions = f.get("additions", 0)
        deletions = f.get("deletions", 0)
        patch = f.get("patch", "")
        
        analysis["total_additions"] += additions
        analysis["total_deletions"] += deletions
        
        # 文件分类
        if status == "added":
            analysis["new_files"].append(filename)
        elif status == "removed":
            analysis["deleted_files"].append(filename)
        else:
            analysis["modified_files"].append(filename)
        
        # 按类型分类
        if filename.endswith((".c", ".h", ".cpp")):
            analysis["c_files"].append(filename)
        elif "test" in filename.lower() or filename.endswith(".tcl"):
            analysis["test_files"].append(filename)
        elif filename.endswith((".md", ".rst", ".txt")) or "doc" in filename.lower():
            analysis["doc_files"].append(filename)
        elif filename.endswith(("Makefile", ".yml", ".yaml", ".json", ".cmake")):
            analysis["build_files"].append(filename)
        
        # 从 patch 中提取函数名
        if patch:
            func_pattern = r'(?:^|\n)(?:@@.*?@@\s*)?(?:[+-])?(?:static\s+)?(?:const\s+)?(?:[\w_]+\s+)+([\w_]+)\s*\('
            for match in re.finditer(func_pattern, patch):
                analysis["key_functions"].add(match.group(1))
    
    return analysis


def generate_analysis_doc(commit_data, commit_type, repo, pr_data=None):
    """生成分析文档"""
    
    sha = commit_data["sha"]
    short_sha = sha[:8]
    message = commit_data["commit"]["message"]
    first_line = message.split("\n")[0]
    body = "\n".join(message.split("\n")[1:]).strip()
    
    author = commit_data["commit"]["author"]["name"]
    author_email = commit_data["commit"]["author"].get("email", "")
    date = commit_data["commit"]["author"]["date"]
    
    files = commit_data.get("files", [])
    diff_analysis = analyze_diff(files)
    
    # 关联 PR
    pr_info = ""
    if pr_data:
        pr_info = f"""
### 关联 PR

- **PR**: [#{pr_data['number']}]({pr_data['html_url']}) - {pr_data['title']}
- **状态**: {pr_data.get('state', 'unknown')}
- **作者**: {pr_data.get('user', {}).get('login', 'unknown')}
"""
    
    # 构建文件变更摘要
    file_summary = f"""
### 文件变更

| 类型 | 文件 |
|------|------|
"""
    
    if diff_analysis["c_files"]:
        file_summary += f"| C 源码 | {', '.join(diff_analysis['c_files'][:5])}{'...' if len(diff_analysis['c_files']) > 5 else ''} |\n"
    if diff_analysis["test_files"]:
        file_summary += f"| 测试 | {', '.join(diff_analysis['test_files'][:5])}{'...' if len(diff_analysis['test_files']) > 5 else ''} |\n"
    if diff_analysis["doc_files"]:
        file_summary += f"| 文档 | {', '.join(diff_analysis['doc_files'][:5])}{'...' if len(diff_analysis['doc_files']) > 5 else ''} |\n"
    if diff_analysis["build_files"]:
        file_summary += f"| 构建 | {', '.join(diff_analysis['build_files'][:5])}{'...' if len(diff_analysis['build_files']) > 5 else ''} |\n"
    
    # 关键函数
    key_funcs = ""
    if diff_analysis["key_functions"]:
        key_funcs = f"""
### 涉及的关键函数

```
{', '.join(sorted(diff_analysis['key_functions'])[:10])}
```
"""
    
    # 根据类型生成不同的分析模板
    type_emoji = {
        "SECURITY": "🔴",
        "BUGFIX": "🐛",
        "FEATURE": "✨",
    }.get(commit_type, "📌")
    
    type_title = {
        "SECURITY": "安全漏洞修复分析",
        "BUGFIX": "Bug 修复分析",
        "FEATURE": "新功能分析",
    }.get(commit_type, "提交分析")
    
    # 尝试从 body 中提取 Issue 引用
    issue_refs = re.findall(r'#(\d+)', message)
    issue_section = ""
    if issue_refs:
        issue_section = "\n### 关联 Issue\n\n"
        for issue_num in issue_refs[:3]:
            issue_section += f"- [Issue #{issue_num}](https://github.com/{repo}/issues/{issue_num})\n"
    
    doc = f"""# {type_emoji} {type_title} - {short_sha}

## 基本信息

| 项目 | 内容 |
|------|------|
| **提交** | [{sha}](https://github.com/{repo}/commit/{sha}) |
| **作者** | {author} ({author_email}) |
| **日期** | {date} |
| **类型** | {commit_type} |
| **统计** | +{diff_analysis['total_additions']} -{diff_analysis['total_deletions']} ({len(files)} 个文件) |

## 提交消息

```
{first_line}
```

{body if body else '*无详细描述*'}

{issue_section}
{pr_info}
{file_summary}
{key_funcs}
## 变更分析

### 修改内容概述

"""
    
    # 为每个文件生成简要分析
    for f in files[:10]:
        filename = f.get("filename", "")
        patch = f.get("patch", "")
        status = f.get("status", "modified")
        additions = f.get("additions", 0)
        deletions = f.get("deletions", 0)
        
        doc += f"\n#### `{filename}` ({status}, +{additions}/-{deletions})\n\n"
        
        if patch and len(patch) < 2000:
            doc += f"```diff\n{patch[:1500]}\n```\n"
        elif patch:
            doc += f"_变更较大，详见 [完整 diff](https://github.com/{repo}/commit/{sha})_\n"
        else:
            doc += "_二进制文件或无 diff 内容_\n"
    
    # 修复建议 / 注意事项
    if commit_type == "SECURITY":
        doc += """
## ⚠️ 安全影响

### 攻击面分析

- **远程可利用性**: 需进一步分析
- **权限要求**: 需进一步分析  
- **影响范围**: 需进一步分析

### 修复验证

建议验证步骤：
1. 编译修复前后的代码
2. 运行相关测试用例
3. 检查是否引入回归问题

"""
    elif commit_type == "BUGFIX":
        doc += """
## 修复验证

### 验证步骤

1. 确认问题复现条件
2. 应用修复后重新测试
3. 检查边界情况

### 测试建议

- 运行相关单元测试: `./runtest --single unit/<module>`
- 检查回归测试

"""
    
    doc += f"""
---

*文档自动生成于 {datetime.now().isoformat()}*
*分析引擎: analyze_commit.py*
"""
    
    return doc


def main():
    parser = argparse.ArgumentParser(description="分析 Redis 提交")
    parser.add_argument("--sha", required=True, help="提交 SHA")
    parser.add_argument("--repo", default="redis/redis", help="仓库名")
    parser.add_argument("--type", default="OTHER", help="提交类型")
    parser.add_argument("--output", required=True, help="输出文件路径")
    
    args = parser.parse_args()
    
    print(f"Analyzing commit {args.sha}...")
    
    # 获取提交数据
    commit_data = fetch_commit(args.repo, args.sha)
    if not commit_data:
        print("Failed to fetch commit data", file=sys.stderr)
        sys.exit(1)
    
    # 查找关联 PR
    pr_data = fetch_pr_for_commit(args.repo, args.sha)
    
    # 生成文档
    doc = generate_analysis_doc(commit_data, args.type, args.repo, pr_data)
    
    # 写入文件
    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        f.write(doc)
    
    print(f"Analysis saved to: {args.output}")


if __name__ == "__main__":
    main()
