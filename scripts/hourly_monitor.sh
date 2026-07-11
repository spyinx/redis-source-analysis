#!/usr/bin/env bash
# hourly_monitor.sh - Redis 每小时监控入口
# 检查 Redis 仓库是否有新提交，有则分析并推送
# 文件命名规则: redis-pr-{PR编号}-analysis.md

set -euo pipefail

REPO_OWNER="redis"
REPO_NAME="redis"
PROJECT_DIR="/root/.openclaw/workspace/redis-source-analysis"
SCRIPTS_DIR="${PROJECT_DIR}/scripts"
STATE_FILE="${PROJECT_DIR}/.last_checked_sha"
MAX_COMMITS="50"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_success(){ echo -e "${GREEN}[OK]${NC} $1"; }

get_token() {
    if [ -f ~/.config/gh/config.yml ]; then
        grep oauth_token ~/.config/gh/config.yml | awk '{print $2}'
    fi
}

get_latest_sha() {
    local api_url="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/commits?per_page=1"
    curl -sL -H "Accept: application/vnd.github.v3+json" \
        "${api_url}" | python3 -c "import json,sys; data=json.load(sys.stdin); print(data[0]['sha'] if data else '')"
}

get_last_sha() {
    if [ -f "$STATE_FILE" ]; then cat "$STATE_FILE"; else echo ""; fi
}

save_last_sha() { echo "$1" > "$STATE_FILE"; }

get_pr_for_commit() {
    local sha="$1"
    local token
    token=$(get_token)
    local hdrs="-H Accept:application/vnd.github.v3+json"
    [ -n "$token" ] && hdrs="$hdrs -H Authorization:token $token"
    curl -sL $hdrs "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/commits/${sha}/pulls" | \
        python3 -c "import json,sys; data=json.load(sys.stdin); print(data[0]['number'] if data else '')"
}

fetch_new_commits() {
    local since_date
    since_date=$(date -u -d "2 hours ago" +%Y-%m-%dT%H:%M:%SZ)
    local api_url="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/commits?since=${since_date}&per_page=${MAX_COMMITS}"
    curl -sL -H "Accept: application/vnd.github.v3+json" "${api_url}"
}

classify_commit() {
    local message="$1"
    local lower_msg
    lower_msg=$(echo "${message}" | tr '[:upper:]' '[:lower:]')
    
    if echo "${lower_msg}" | grep -qiE 'secur|vulnerab|overflow|underflow|buffer|sanitize|asan|ubsan|cve|exploit|dos|crash|segfault|heap|stack|corrupt|inject|privilege|escalation|auth|leak|bypass|unsafe'; then
        echo "SECURITY"
        return
    fi
    if echo "${lower_msg}" | grep -qiE 'fix|bug|patch|repair|correct|resolve|issue #|closes #|fixes #|revert|broken|wrong|error|fail|assert|panic|deadlock|race|lock|mutex|memory leak|null|dangling'; then
        if echo "${lower_msg}" | grep -qiE 'fix (format|typo|style|whitespace|indent|lint|comment|doc|test|ci|build|merge|conflict)'; then
            echo "MINOR"
            return
        fi
        echo "BUGFIX"
        return
    fi
    if echo "${lower_msg}" | grep -qiE 'add|adds|add support|add new|add option|implement|introduce|feature|new command|new option|new api|new module|support|enable|allow|enhance|improve|optimize|perf|performance|speed|fast'; then
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
    echo "OTHER"
}

main() {
    log_info "Hourly check started at $(date -Iseconds)"
    
    local latest_sha
    latest_sha=$(get_latest_sha)
    [ -z "$latest_sha" ] && { log_error "Failed to get latest SHA"; exit 1; }
    
    local last_sha
    last_sha=$(get_last_sha)
    
    if [ "$latest_sha" = "$last_sha" ]; then
        log_info "No new commits. Last: ${last_sha:0:8}"
        exit 0
    fi
    
    log_info "New commits detected! Latest: ${latest_sha:0:8}"
    
    local commits_json
    commits_json=$(fetch_new_commits)
    
    local commit_count
    commit_count=$(echo "${commits_json}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
    
    if [ "$commit_count" -eq 0 ]; then
        save_last_sha "$latest_sha"
        exit 0
    fi
    
    log_info "Found ${commit_count} new commit(s)"
    
    local today_dir="${PROJECT_DIR}/$(date +%Y-%m-%d)"
    mkdir -p "${today_dir}"
    
    local important_count=0
    local summary_file="${today_dir}/commits.md"
    
    # 确保汇总文件存在
    if [ ! -f "$summary_file" ]; then
        cat > "$summary_file" << EOF
# Redis 提交分析 - $(date +%Y-%m-%d)

> 自动监控 Redis 官方仓库提交，筛选重要更新。

## 提交概览

| 时间 | PR 编号 | 类型 | 作者 | 消息摘要 | 分析文档 |
|------|---------|------|------|----------|----------|
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
        
        [ -z "$commit_data" ] && { i=$((i+1)); continue; }
        
        local sha
        sha=$(echo "${commit_data}" | python3 -c "import json,sys; print(json.load(sys.stdin)['sha'][:8])")
        
        # 获取关联 PR 编号
        local pr_num
        pr_num=$(get_pr_for_commit "${sha}")
        
        # 确定文件名前缀
        local file_prefix
        if [ -n "$pr_num" ]; then
            file_prefix="redis-pr-${pr_num}"
        else
            file_prefix="${sha}"
        fi
        
        # 如果文件已存在，跳过
        if [ -f "${today_dir}/${file_prefix}-analysis.md" ]; then
            log_info "Skipping already analyzed: ${file_prefix}"
            i=$((i+1))
            continue
        fi
        
        local message
        message=$(echo "${commit_data}" | python3 -c "import json,sys; print(json.load(sys.stdin)['commit']['message'].split('\n')[0])")
        
        local author
        author=$(echo "${commit_data}" | python3 -c "import json,sys; print(json.load(sys.stdin)['commit']['author']['name'])")
        
        local commit_type
        commit_type=$(classify_commit "${message}")
        
        local type_label
        case "${commit_type}" in
            SECURITY) type_label="🔴 Security" ;;
            BUGFIX)   type_label="🐛 Bug Fix" ;;
            FEATURE)  type_label="✨ Feature" ;;
            TEST)     type_label="🧪 Test" ;;
            DOC)      type_label="📝 Doc" ;;
            *)        type_label="📌 Other" ;;
        esac
        
        local pr_link=""
        [ -n "$pr_num" ] && pr_link="[#${pr_num}](https://github.com/${REPO_OWNER}/${REPO_NAME}/pull/${pr_num})"
        
        echo "| $(date +%H:%M) | ${pr_link} | ${type_label} | ${author} | ${message:0:50}... | [分析](${file_prefix}-analysis.md) |" >> "$summary_file"
        
        if [ "${commit_type}" = "SECURITY" ] || [ "${commit_type}" = "BUGFIX" ] || [ "${commit_type}" = "FEATURE" ]; then
            log_info "Analyzing ${type_label}: ${message:0:50}..."
            
            local analysis_file="${today_dir}/${file_prefix}-analysis.md"
            python3 "${SCRIPTS_DIR}/analyze_commit.py" \
                --sha "${sha}" --repo "${REPO_OWNER}/${REPO_NAME}" \
                --type "${commit_type}" --output "${analysis_file}" 2>&1 || log_warn "Analysis failed"
            
            if [ "${commit_type}" = "SECURITY" ] || [ "${commit_type}" = "BUGFIX" ]; then
                local reproduce_file="${today_dir}/${file_prefix}-reproduce.sh"
                python3 "${SCRIPTS_DIR}/reproduce_generator.py" \
                    --sha "${sha}" --repo "${REPO_OWNER}/${REPO_NAME}" \
                    --type "${commit_type}" --output "${reproduce_file}" 2>&1 || log_warn "Reproduce failed"
            fi
            
            important_count=$((important_count + 1))
        else
            log_info "Skipping ${type_label}: ${message:0:50}..."
        fi
        
        i=$((i + 1))
    done
    
    save_last_sha "$latest_sha"
    
    if [ $important_count -gt 0 ]; then
        log_success "${important_count} important commits analyzed."
        cd "${PROJECT_DIR}"
        git add -A
        git commit -m "Hourly update: $(date '+%Y-%m-%d %H:%M') - ${important_count} new commits" || true
        git push origin main 2>&1 || log_warn "Push failed"
        log_success "Pushed!"
    else
        log_info "No important commits to analyze."
    fi
}

main "$@"
