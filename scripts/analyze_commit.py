#!/usr/bin/env python3
"""
analyze_commit.py - Redis 提交深度分析引擎
按 PR 编号生成结构化分析文档。
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime
from urllib.request import Request, urlopen
from urllib.error import HTTPError

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
    except HTTPError as e:
        print(f"API Error: {e.code} - {e.reason}", file=sys.stderr)
        return None
    except Exception as e:
        print(f"Request Error: {e}", file=sys.stderr)
        return None

def get_pr_for_commit(repo, sha):
    """获取提交关联的 PR 编号"""
    prs = github_api(f"https://api.github.com/repos/{repo}/commits/{sha}/pulls")
    if prs and len(prs) > 0:
        return prs[0]
    return None

def get_pr_detail(repo, pr_num):
    """获取 PR 详情"""
    return github_api(f"https://api.github.com/repos/{repo}/pulls/{pr_num}")

def get_pr_comments(repo, pr_num):
    """获取 PR 评论"""
    comments = github_api(f"https://api.github.com/repos/{repo}/issues/{pr_num}/comments")
    review_comments = github_api(f"https://api.github.com/repos/{repo}/pulls/{pr_num}/comments")
    return comments or [], review_comments or []

def extract_issue_refs(text):
    """从文本中提取 Issue 引用"""
    return re.findall(r'#(\d+)', text or '')

def generate_analysis_doc(pr_data, commit_type, repo, sha):
    """生成分析文档"""
    pr = pr_data.get('pr', {})
    pr_num = pr.get('number', '')
    
    title = pr.get('title', '')
    author = pr.get('user', {}).get('login', '')
    merger = pr.get('merged_by', {}).get('login', '') if pr.get('merged_by') else ''
    created = pr.get('created_at', '')
    merged = pr.get('merged_at', '')
    branch = pr.get('base', {}).get('ref', '')
    body = pr.get('body', '')
    
    # 关联 Issue
    issue_refs = extract_issue_refs(body)
    
    # 类型标签
    type_emoji = {'SECURITY': '🔴', 'BUGFIX': '🐛', 'FEATURE': '✨'}
    type_title = {'SECURITY': '安全漏洞修复分析', 'BUGFIX': 'Bug 修复分析', 'FEATURE': '新功能分析'}
    emoji = type_emoji.get(commit_type, '📌')
    ttitle = type_title.get(commit_type, '提交分析')
    
    doc = f"""# Redis PR #{pr_num} 详细分析文档

## 一、基本信息

| 项目 | 内容 |
|------|------|
| **PR 标题** | {title} |
| **PR 链接** | https://github.com/{repo}/pull/{pr_num} |
| **作者** | {author} |
| **合并者** | {merger} |
| **创建时间** | {created[:10] if created else 'N/A'} |
| **合并时间** | {merged[:10] if merged else 'N/A'} |
| **目标分支** | {branch} |
| **关联 Issue** | {', '.join([f'#{r}' for r in issue_refs[:3]]) if issue_refs else '无'} |
| **类型** | {commit_type} |

---

## 二、概述

{body[:2000] if body else '*无详细描述*'}

---

*此文档由自动分析引擎生成，基于 PR #{pr_num} 公开信息整理。*
*生成时间：{datetime.now().isoformat()}*
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
    
    # 获取关联 PR
    pr = get_pr_for_commit(args.repo, args.sha)
    if not pr:
        print("No PR found for this commit", file=sys.stderr)
        sys.exit(1)
    
    pr_num = pr['number']
    
    # 获取 PR 详情
    pr_detail = get_pr_detail(args.repo, pr_num)
    if not pr_detail:
        pr_detail = pr  # 回退到 commit API 返回的 PR 数据
    
    # 获取评论
    comments, review_comments = get_pr_comments(args.repo, pr_num)
    
    pr_data = {
        'pr': pr_detail,
        'comments': comments,
        'review_comments': review_comments,
    }
    
    # 生成文档
    doc = generate_analysis_doc(pr_data, args.type, args.repo, args.sha)
    
    # 写入文件
    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        f.write(doc)
    
    print(f"Analysis saved to: {args.output}")

if __name__ == "__main__":
    main()
