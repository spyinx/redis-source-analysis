#!/usr/bin/env bash
# hourly_monitor.sh - Redis 每小时监控入口
# 检查 Redis 仓库是否有新提交，有则分析并推送

set -euo pipefail

REPO_OWNER="redis"
REPO_NAME="redis"
PROJECT_DIR="/root/.openclaw/workspace/redis-source-analysis"
SCRIPTS_DIR="${PROJECT_DIR}/scripts"
STATE_FILE="${PROJECT_DIR}/.last_checked_sha"
MAX_COMMITS="50"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_success(){ echo -e "${GREEN}[OK]${NC} $1"; }

# 获取最新提交 SHA
get_latest_sha() {
    local api_url="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/commits?per_page=1"
    curl -sL \
        -H "Accept: application/vnd.github.v3+json" \
        "${api_url}" | python3 -c "import json,sys; data=json.load(sys.stdin); print(data[0]['sha'] if data else '')"
}

# 获取上次检查的 SHA
get_last_sha() {
    if [ -f "$STATE_FILE" ]; then
        cat "$STATE_FILE"
    else
        echo ""
    fi
}

# 保存当前 SHA
save_last_sha() {
    echo "$1" > "$STATE_FILE"
}

# 获取上次检查时间之后的所有新提交
fetch_new_commits() {
    local since_date
    # 获取最近1小时内的提交（留点余量）
    since_date=$(date -u -d "2 hours ago" +%Y-%m-%dT%H:%M:%SZ)
    
    local api_url="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/commits?since=${since_date}&per_page=${MAX_COMMITS}"
    local response
    response=$(curl -sL \
        -H "Accept: application/vnd.github.v3+json" \
        "${api_url}")
    
    if echo "${response}" | grep -q '"message":'; then
        log_error "API Error: $(echo "${response}" | grep '"message"' | head -1)"
        echo "[]"
        return
    fi
    
    echo "${response}"
}

# 提交分类（复用原有逻辑）
classify_commit() {
    local message="$1"
    local files_changed="$2"
    local lower_msg
    lower_msg=$(echo "${message}" | tr '[:upper:]' '[:lower:]')
    
    if echo "${lower_msg}" | grep -qiE \
        'secur|vulnerab|overflow|underflow|buffer|sanitize|asan|ubsan|cve|exploit|dos|crash|segfault|heap|stack|corrupt|inject|privilege|escalation|auth|leak|bypass|unsafe'; then
        echo "SECURITY"
        return
    fi
    
    if echo "${lower_msg}" | grep -qiE \
        'fix|bug|patch|repair|correct|resolve|issue #|closes #|fixes #|revert|broken|wrong|error|fail|assert|panic|deadlock|race|lock|mutex|memory leak|null|dangling'; then
        if echo "${lower_msg}" | grep -qiE 'fix (format|typo|style|whitespace|indent|lint|comment|doc|test|ci|build|merge|conflict)'; then
            echo "MINOR"
            return
        fi
        echo "BUGFIX"
        return
    fi
    
    if echo "${lower_msg}" | grep -qiE \
        'add|adds|add support|add new|add option|implement|introduce|feature|new command|new option|new api|new module|support|enable|allow|enhance|improve|optimize|perf|performance|speed|fast'; then
        echo "FEATURE"
        return
    fi
    
    if echo "${lower_msg}" | grep -qiE 'test|tests|testing|unit test|integration test|spec|benchmark|bench|ci|travis|github action|workflow'; then
        echo "TEST"
        return
    fi
    
    if echo "${lower_msg}" | grep -qiE 'doc|docs|document|readme|changelog|release note|comment|typo|format|style|whitespace|indent'; then
        echo "DOC"
        return
    fi
    
    if echo "${lower_msg}" | grep -qiE 'refactor|cleanup|clean up|remove|delete|deprecat|rename|move|reorganize|simplify|reduce'; then
        echo "REFACTOR"
        return
    fi
    
    echo "OTHER"
}

# 获取提交详情
get_commit_details() {
    local sha="$1"
    curl -sL \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/commits/${sha}"
}

# 主流程
main() {
    log_info "Hourly check started at $(date -Iseconds)"
    
    # 获取最新 SHA
    local latest_sha
    latest_sha=$(get_latest_sha)
    
    if [ -z "$latest_sha" ]; then
        log_error "Failed to get latest SHA"
        exit 1
    fi
    
    local last_sha
    last_sha=$(get_last_sha)
    
    # 检查是否有更新
    if [ "$latest_sha" = "$last_sha" ]; then
        log_info "No new commits since last check. Last: ${last_sha:0:8}"
        exit 0
    fi
    
    log_info "New commits detected! Latest: ${latest_sha:0:8}, Last checked: ${last_sha:0:8:-(none)}"
    
    # 获取新提交列表
    local commits_json
    commits_json=$(fetch_new_commits)
    
    local commit_count
    commit_count=$(echo "${commits_json}" | python3 -c "import json,sys; data=json.load(sys.stdin); print(len(data))")
    
    if [ "$commit_count" -eq 0 ]; then
        log_warn "No commits found in recent window, but SHA changed. Updating state."
        save_last_sha "$latest_sha"
        exit 0
    fi
    
    log_info "Found ${commit_count} new commit(s)"
    
    # 创建当日目录
    local today_dir="${PROJECT_DIR}/$(date +%Y-%m-%d)"
    mkdir -p "${today_dir}"
    
    # 分析每个提交
    local important_count=0
    local summary_file="${today_dir}/commits.md"
    
    # 如果汇总文件已存在，追加；否则新建
    local is_new_day=0
    if [ ! -f "$summary_file" ]; then
        is_new_day=1
        cat > "${summary_file}" << EOF
# Redis 提交分析 - $(date +%Y-%m-%d)

> 自动监控 Redis 官方仓库提交，筛选重要更新。

## 提交概览

| 序号 | SHA | 类型 | 作者 | 消息摘要 |
|------|-----|------|------|----------|
EOF
    fi
    
    local i=1
    while [ $i -le "${commit_count}" ]; do
        local commit_data
        commit_data=$(echo "${commits_json}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
idx = int(sys.argv[1]) - 1
if idx < len(data):
    print(json.dumps(data[idx]))
" "${i}")
        
        if [ -z "$commit_data" ]; then
            i=$((i + 1))
            continue
        fi
        
        local sha
        sha=$(echo "${commit_data}" | python3 -c "import json,sys; print(json.load(sys.stdin)['sha'][:8])")
        
        # 如果这个提交已经分析过（基于文件存在性判断），跳过
        if [ -f "${today_dir}/${sha}.md" ] || [ -f "${today_dir}/${sha}_reproduce.sh" ]; then
            log_info "Skipping already analyzed commit: ${sha}"
            i=$((i + 1))
            continue
        fi
        
        local message
        message=$(echo "${commit_data}" | python3 -c "import json,sys; print(json.load(sys.stdin)['commit']['message'].split('\n')[0])")
        
        local author
        author=$(echo "${commit_data}" | python3 -c "import json,sys; print(json.load(sys.stdin)['commit']['author']['name'])")
        
        # 获取文件变更
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
        
        # 类型标签
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
        
        # 追加到汇总表
        echo "| $(date +%H:%M) | [${sha}](https://github.com/${REPO_OWNER}/${REPO_NAME}/commit/${sha}) | ${type_label} | ${author} | ${message:0:55}... |" >> "${summary_file}"
        
        # 重要提交生成详细分析
        if [ "${commit_type}" = "SECURITY" ] || [ "${commit_type}" = "BUGFIX" ] || [ "${commit_type}" = "FEATURE" ]; then
            log_info "Analyzing ${type_label}: ${message:0:50}..."
            
            local analysis_file="${today_dir}/${sha}.md"
            
            # 调用 Python 分析脚本
            python3 "${SCRIPTS_DIR}/analyze_commit.py" \
                --sha "${sha}" \
                --repo "${REPO_OWNER}/${REPO_NAME}" \
                --type "${commit_type}" \
                --output "${analysis_file}" \
                2>&1 || log_warn "Analysis failed for ${sha}"
            
            # Security / Bugfix 生成复现脚本
            if [ "${commit_type}" = "SECURITY" ] || [ "${commit_type}" = "BUGFIX" ]; then
                local reproduce_file="${today_dir}/${sha}_reproduce.sh"
                python3 "${SCRIPTS_DIR}/reproduce_generator.py" \
                    --sha "${sha}" \
                    --repo "${REPO_OWNER}/${REPO_NAME}" \
                    --type "${commit_type}" \
                    --output "${reproduce_file}" \
                    2>&1 || log_warn "Reproduce script generation failed for ${sha}"
            fi
            
            important_count=$((important_count + 1))
        else
            log_info "Skipping ${type_label}: ${message:0:50}..."
        fi
        
        i=$((i + 1))
    done
    
    # 更新状态
    save_last_sha "$latest_sha"
    
    if [ $important_count -gt 0 ]; then
        log_success "${important_count} important commits analyzed."
        
        # 推送到 GitHub
        cd "${PROJECT_DIR}"
        git add -A
        git commit -m "Hourly update: $(date '+%Y-%m-%d %H:%M') - ${important_count} new important commits" || true
        git push origin main 2>&1 || log_warn "Push failed"
        
        log_success "Pushed to GitHub!"
    else
        log_info "No important commits to analyze this hour."
    fi
}

main "$@"
