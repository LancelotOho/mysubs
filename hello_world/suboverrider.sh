#!/bin/bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERBOSE=0
CONFIG_FILE=""
SUCCESS_COUNT=0
TOTAL_COUNT=0

usage() {
    echo "用法: $0 -c <配置文件> [-v]"
    echo "  -c  指定配置文件（必填）"
    echo "  -v  启用详细日志输出"
    exit 1
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_verbose() {
    if [[ "$VERBOSE" -eq 1 ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [详细] $*"
    fi
}

parse_args() {
    while getopts "c:v" opt; do
        case $opt in
            c)
                CONFIG_FILE="$OPTARG"
                ;;
            v)
                VERBOSE=1
                ;;
            \?)
                usage
                ;;
        esac
    done

    if [[ -z "$CONFIG_FILE" ]]; then
        echo "错误: 请指定配置文件"
        usage
    fi

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "错误: 配置文件不存在: $CONFIG_FILE"
        exit 1
    fi
}

get_override_files() {
    local config="$1"
    local project_name="$2"
    yq eval ".mysubs.$project_name.override_file | .[]" "$config" 2>/dev/null
}

get_project_names() {
    local config="$1"
    yq eval '.mysubs | keys | .[]' "$config" 2>/dev/null
}

download_subscription() {
    local url="$1"
    local download_path="$2"
    local ori_config_name="$3"
    local max_retries=2
    local retry_interval=5

    log_verbose "正在下载: $url"
    log_verbose "保存至: $download_path/$ori_config_name"

    mkdir -p "$download_path"

    local attempt=0
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0"
    local http_code
    while [[ "$attempt" -le "$max_retries" ]]; do
            
        http_code=$(curl -sL -m 30 --connect-timeout 10 -H "User-Agent: $ua" -w "%{http_code}" -o "${download_path}/${ori_config_name}" "$url")
        
        if [[ "$http_code" != "200" ]]; then
            log "错误: HTTP状态码 ${http_code}: $url"
            rm -f "${download_path}/${ori_config_name}"
            attempt=$((attempt + 1))
            if [[ "$attempt" -le "$max_retries" ]]; then
                log "HTTP错误，${retry_interval}秒后重试 ($attempt/$max_retries)"
                sleep "$retry_interval"
            fi
            continue
        fi
        
        log_verbose "下载成功: ${download_path}/${ori_config_name}"    
            
            local downloaded_file="${download_path}/${ori_config_name}"
            
            if [[ ! -s "$downloaded_file" ]]; then
                log "错误: 下载的文件为空: $url"
                rm -f "$downloaded_file"
                attempt=$((attempt + 1))
                if [[ "$attempt" -le "$max_retries" ]]; then
                    log "文件为空，${retry_interval}秒后重试 ($attempt/$max_retries)"
                    sleep "$retry_interval"
                fi
                continue
            fi
            
            if head -c 100 "$downloaded_file" | grep -qiE '<!DOCTYPE|<html|<head>|<body>|<title>.*(404|500|Error|Access Denied|Forbidden|Not Found)'; then
                log "错误: 下载的内容可能是HTML错误页: $url"
                rm -f "$downloaded_file"
                attempt=$((attempt + 1))
                if [[ "$attempt" -le "$max_retries" ]]; then
                    log "HTML错误页，${retry_interval}秒后重试 ($attempt/$max_retries)"
                    sleep "$retry_interval"
                fi
                continue
            fi
            
            if ! yq eval '.' "$downloaded_file" >/dev/null 2>&1; then
                log "错误: 下载的文件不是有效的YAML: $url"
                rm -f "$downloaded_file"
                attempt=$((attempt + 1))
                if [[ "$attempt" -le "$max_retries" ]]; then
                    log "无效YAML，${retry_interval}秒后重试 ($attempt/$max_retries)"
                    sleep "$retry_interval"
                fi
                continue
            fi
            
            log_verbose "内容验证通过: $downloaded_file"         
            return 0

        attempt=$((attempt + 1))
        if [[ "$attempt" -le "$max_retries" ]]; then
            log "下载失败，${retry_interval}秒后重试 ($attempt/$max_retries): $url"
            sleep "$retry_interval"
        fi
    done

    log "错误: 下载失败: $url"
    return 1
}

extract_topkey() {
    local ori_file="$1"
    local tar_topkey="$2"
    local only_proxy_file="$3"

    log_verbose "正在提取键值: $tar_topkey 来自 $ori_file"

    if ! yq eval "has(\"$tar_topkey\")" "$ori_file" >/dev/null 2>&1; then
        log "错误: 目标键 '$tar_topkey' 不存在于 $ori_file"
        return 1
    fi
    
    if yq eval "{\"$tar_topkey\": .$tar_topkey}" "$ori_file" > "$only_proxy_file" 2>/dev/null; then
        log_verbose "提取成功: $only_proxy_file"
        return 0
    else
        log "错误: 提取键值失败 '$tar_topkey' 来自 $ori_file"
        return 1
    fi
}

process_project() {
    local project_name="$1"
    local config="$2"

    log "========================================="
    log "正在处理项目: $project_name"

    local url download_path ori_config_name tar_topkey only_proxy_file f_config_path f_config_name

    url=$(yq eval ".mysubs.$project_name.url" "$config")
    download_path=$(yq eval ".mysubs.$project_name.download_path" "$config")
    ori_config_name=$(yq eval ".mysubs.$project_name.ori_config_name" "$config")
    tar_topkey=$(yq eval ".mysubs.$project_name.tar_topkey" "$config")
    only_proxy_file=$(yq eval ".mysubs.$project_name.only_proxy_file" "$config")
    f_config_path=$(yq eval ".mysubs.$project_name.f_config_path" "$config")
    f_config_name=$(yq eval ".mysubs.$project_name.f_config_name" "$config")

    if [[ "$url" == "null" ]] || [[ -z "$url" ]]; then
        log "错误: 项目 $project_name 未配置 URL"
        return 1
    fi

    if ! download_subscription "$url" "$download_path" "$ori_config_name"; then
        return 1
    fi

    local ori_file="${download_path}/${ori_config_name}"
    if [[ ! -f "$ori_file" ]]; then
        log "错误: 下载的文件不存在: $ori_file"
        return 1
    fi

    local only_proxy_path="${download_path}/${only_proxy_file}"
    if ! extract_topkey "$ori_file" "$tar_topkey" "$only_proxy_path"; then
        return 1
    fi

    mkdir -p "$f_config_path"

    local final_file="${f_config_path}/${f_config_name}"

    : > "$final_file"

    local override_files
    override_files=$(get_override_files "$config" "$project_name")
    while IFS= read -r override; do
        [[ -z "$override" ]] && continue
        override=$(echo "$override" | xargs)
        if [[ -f "${SCRIPT_DIR}/${override}" ]]; then
            cat "${SCRIPT_DIR}/${override}" >> "$final_file"
            log_verbose "已添加: ${SCRIPT_DIR}/${override}"
        else
            log "警告: 覆写文件不存在: ${SCRIPT_DIR}/${override}"
        fi
    done <<< "$override_files"

    if [[ -f "$only_proxy_path" ]]; then
        echo >> "$final_file"
        cat "$only_proxy_path" >> "$final_file"
    else
        log "错误: 文件不存在: $only_proxy_path"
        return 1
    fi

    log_verbose "合并完成: $final_file"

    log "项目 $project_name 处理成功"
    return 0
}

main() {
    parse_args "$@"

    log_verbose "配置文件: $CONFIG_FILE"
    log_verbose "详细模式: 已启用"

    local project_names
    project_names=$(get_project_names "$CONFIG_FILE")

    if [[ -z "$project_names" ]]; then
        log "错误: 配置文件中未找到项目"
        exit 1
    fi

    TOTAL_COUNT=0
    while IFS= read -r project; do
        [[ -z "$project" ]] && continue
        ((TOTAL_COUNT++))
    done <<< "$project_names"

    log "发现 $TOTAL_COUNT 个项目待处理"

    SUCCESS_COUNT=0
    while IFS= read -r project; do
        [[ -z "$project" ]] && continue

        if process_project "$project" "$CONFIG_FILE"; then
            ((SUCCESS_COUNT++))
        else
            log "警告: 项目 $project 处理失败，将继续处理下一个项目"
        fi
    done <<< "$project_names"

    log "========================================="
    log "所有项目处理完成"
    log "最终结果: 成功 ${SUCCESS_COUNT}/${TOTAL_COUNT}"

    if [[ "$SUCCESS_COUNT" -eq "$TOTAL_COUNT" ]]; then
        exit 0
    else
        exit 1
    fi
}

main "$@"
