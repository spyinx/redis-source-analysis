#!/usr/bin/env bash
# daily_monitor.sh - Redis 源码每日提交监控入口
# 获取 Redis 官方仓库的最新提交，筛选重要提交并生成分析

set -euo pipefail

# ============ 配置 ============
REPO_OWNER="redis"
REPO_NAME="redis"
SINCE_DAYS="3"          # 监控最近 N 天的提交
MAX_COMMITS="50"        # 最多分析多少个提交
PROJECT_DIR="/root/.openclaw/workspace/redis-source-analysis"
SCRIPTS_DIR="${PROJECT_DIR}/scripts"

# ============ 颜色 ============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_success(){ echo -e "${GREEN}[OK]${NC} $1"; }

# ============ 获取提交列表 ============
fetch_commits() {
    local since_date
    since_date=$(date -u -d "${SINCE_DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ)
    
    log_info "Fetching commits since ${since_date}..."
    
    # 通过 GitHub API 获取最近提交
    local api_url="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/commits?since=${since_date}&per_page=${MAX_COMMITS}"
    local response
    response=$(curl -sL \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Authorization: token $(cat ~/.config/gh/config.yml | grep oauth_token | awk '{print $2}')" \
        "${api_url}")
    
    # 检查是否是错误响应
    if echo "${response}" | grep -q '"message":'; then
        log_error "API Error: $(echo "${response}" | grep '"message"' | head -1)"
        exit 1
    fi
    
    echo "${response}"
}

# ============ 判断提交类型 ============
classify_commit() {
    local message="$1"
    local files_changed="$2"
    
    local lower_msg
    lower_msg=$(echo "${message}" | tr '[:upper:]' '[:lower:]')
    
    # 安全相关关键词
    if echo "${lower_msg}" | grep -qiE \
        'secur|vulnerab|overflow|underflow|buffer|sanitize|asan|ubsan|cve|exploit|dos|crash|segfault|heap|stack|corrupt|inject|privilege|escalation|auth|leak|bypass|unsafe'; then
        echo "SECURITY"
        return
    fi
    
    # Bug 修复关键词
    if echo "${lower_msg}" | grep -qiE \
        'fix|bug|patch|repair|correct|resolve|issue #|closes #|fixes #|revert|broken|wrong|error|fail|assert|panic|deadlock|race|lock|mutex|memory leak|null|dangling'; then
        # 排除 "Fix formatting" "Fix typo" 这类小修复
        if echo "${lower_msg}" | grep -qiE 'fix (format|typo|style|whitespace|indent|lint|comment|doc|test|ci|build|merge|conflict)'; then
            echo "MINOR"
            return
        fi
        echo "BUGFIX"
        return
    fi
    
    # 新功能关键词
    if echo "${lower_msg}" | grep -qiE \
        'add|adds|add support|add new|add option|implement|introduce|feature|new command|new option|new api|new module|support|enable|allow|enhance|improve|optimize|perf|performance|speed|fast'; then
        # 排除测试相关的
        if echo "${files_changed}" | grep -q '^tests/'; then
            if ! echo "${files_changed}" | grep -v '^tests/' | grep -q '.'; then
                echo "TEST"
                return
            fi
        fi
        echo "FEATURE"
        return
    fi
    
    # 测试相关
    if echo "${lower_msg}" | grep -qiE 'test|tests|testing|unit test|integration test|spec|benchmark|bench|ci|travis|github action|workflow'; then
        echo "TEST"
        return
    fi
    
    # 文档相关
    if echo "${lower_msg}" | grep -qiE 'doc|docs|document|readme|changelog|release note|comment|typo|format|style|whitespace|indent'; then
        echo "DOC"
        return
    fi
    
    # 重构
    if echo "${lower_msg}" | grep -qiE 'refactor|cleanup|clean up|remove|delete|deprecat|rename|move|reorganize|simplify|reduce'; then
        echo "REFACTOR"
        return
    fi
    
    echo "OTHER"
}

# ============ 获取提交详情 ============
get_commit_details() {
    local sha="$1"
    
    curl -sL \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Authorization: token $(cat ~/.config/gh/config.yml | grep oauth_token | awk '{print $2}')" \
        "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/commits/${sha}"
}

# ============ 主流程 ============
main() {
    log_info "Starting Redis commit monitor for $(date +%Y-%m-%d)"
    
    # 确保目录存在
    mkdir -p "${SCRIPTS_DIR}"
    
    # 获取提交
    local commits_json
    commits_json=$(fetch_commits)
    
    # 解析提交列表
    local commit_count
    commit_count=$(echo "${commits_json}" | grep -c '"sha":' || true)
    
    if [ "${commit_count}" -eq 0 ]; then
        log_warn "No new commits found in the last ${SINCE_DAYS} day(s)."
        exit 0
    fi
    
    log_info "Found ${commit_count} commit(s) to analyze"
    
    # 创建当日目录
    local today_dir="${PROJECT_DIR}/$(date +%Y-%m-%d)"
    mkdir -p "${today_dir}"
    
    # 分析每个提交
    local important_count=0
    local summary_file="${today_dir}/commits.md"
    
    cat > "${summary_file}" << EOF
# Redis 提交分析 - $(date +%Y-%m-%d)

> 自动监控 Redis 官方仓库提交，筛选重要更新。
> 监控范围：最近 ${SINCE_DAYS} 天 | 最多 ${MAX_COMMITS} 个提交

## 提交概览

| 序号 | SHA | 类型 | 作者 | 消息摘要 |
|------|-----|------|------|----------|
EOF
    
    # 遍历每个提交
    local i=1
    while [ $i -le "${commit_count}" ]; do
        local commit_data
        commit_data=$(echo "${commits_json}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
idx = int(sys.argv[1]) - 1
if idx < len(data):
    c = data[idx]
    print(json.dumps(c))
" "${i}")
        
        local sha
        sha=$(echo "${commit_data}" | python3 -c "import json,sys; print(json.load(sys.stdin)['sha'][:8])")
        
        local message
        message=$(echo "${commit_data}" | python3 -c "import json,sys; print(json.load(sys.stdin)['commit']['message'].split('\n')[0])")
        
        local author
        author=$(echo "${commit_data}" | python3 -c "import json,sys; print(json.load(sys.stdin)['commit']['author']['name'])")
        
        # 获取文件变更详情
        local commit_detail
        commit_detail=$(get_commit_details "${sha}")
        
        local files_changed
        files_changed=$(echo "${commit_detail}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
files = data.get('files', [])
for f in files:
    print(f.get('filename', ''))
")
        
        # 分类
        local commit_type
        commit_type=$(classify_commit "${message}" "${files_changed}")
        
        # 类型标签和emoji
        local type_label
        case "${commit_type}" in
            SECURITY) type_label="🔴 Security" ;;
            BUGFIX)   type_label="🐛 Bug Fix" ;;
            FEATURE)  type_label="✨ Feature" ;;
            TEST)     type_label="🧪 Test" ;;
            DOC)      type_label="📝 Doc" ;;
            REFACTOR) type_label="🔧 Refactor" ;;
            MINOR)    type_label="⚪ Minor" ;;
            *)        type_label="📌 Other" ;;
        esac
        
        # 写入汇总表
        echo "| ${i} | [${sha}](https://github.com/${REPO_OWNER}/${REPO_NAME}/commit/${sha}) | ${type_label} | ${author} | ${message:0:60}... |" >> "${summary_file}"
        
        # 重要提交生成详细分析
        if [ "${commit_type}" = "SECURITY" ] || [ "${commit_type}" = "BUGFIX" ] || [ "${commit_type}" = "FEATURE" ]; then
            log_info "Analyzing ${type_label}: ${message:0:50}..."
            
            local analysis_file="${today_dir}/${sha}.md"
            
            # 调用 Python 分析脚本生成详细文档
            python3 "${SCRIPTS_DIR}/analyze_commit.py" \
                --sha "${sha}" \
                --repo "${REPO_OWNER}/${REPO_NAME}" \
                --type "${commit_type}" \
                --output "${analysis_file}" \
                2>&1 || log_warn "Analysis failed for ${sha}"
            
            # 如果有 bug fix 或 security 修复，生成复现脚本
            if [ "${commit_type}" = "SECURITY" ] || [ "${commit_type}" = "BUGFIX" ]; then
                local reproduce_file="${today_dir}/${sha}_reproduce.sh"
                python3 "${SCRIPTS_DIR}/reproduce_generator.py" \
                    --sha "${sha}" \
                    --repo "${REPO_OWNER}/${REPO_NAME}" \
                    --type "${commit_type}" \
                    --output "${reproduce_file}" \
                    2>&1 || log_warn "Reproduce script generation failed for ${sha}"
            fi
            
            ((important_count++)) || true
        else
            log_info "Skipping ${type_label}: ${message:0:50}..."
        fi
        
        i=$((i + 1))
    done
    
    # 追加总结到汇总文件
    cat >> "${summary_file}" << EOF

---

**统计**：共分析 ${commit_count} 个提交，其中 **${important_count} 个重要提交** 已生成详细分析文档。

- 🔴 Security: $(grep -c '🔴 Security' "${summary_file}" || echo 0)
- 🐛 Bug Fix: $(grep -c '🐛 Bug Fix' "${summary_file}" || echo 0)
- ✨ Feature: $(grep -c '✨ Feature' "${summary_file}" || echo 0)
- 🧪 Test: $(grep -c '🧪 Test' "${summary_file}" || echo 0)
- 📝 Doc: $(grep -c '📝 Doc' "${summary_file}" || echo 0)
- 🔧 Refactor: $(grep -c '🔧 Refactor' "${summary_file}" || echo 0)

*自动生成于 $(date -Iseconds)*
EOF
    
    log_success "Analysis complete! ${important_count} important commits analyzed."
    log_info "Results saved to: ${today_dir}/"
    
    # 推送到 GitHub
    cd "${PROJECT_DIR}"
    git add -A
    git commit -m "Daily analysis: $(date +%Y-%m-%d) - ${important_count} important commits" || true
    git push origin main 2>&1 || log_warn "Push failed, may need manual push"
    
    log_success "Done!"
}

main "$@"
