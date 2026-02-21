#!/bin/bash

set -uo pipefail
shopt -s extglob

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SUCCESS=0
readonly FAILURE=1

readonly MAX_RETRIES=2
readonly RETRY_INTERVAL=5
readonly CURL_TIMEOUT=30
readonly CURL_CONNECT_TIMEOUT=10

VERBOSE=0
CONFIG_FILE=""
SUCCESS_COUNT=0
TOTAL_COUNT=0
TIMESTAMP=""

get_timestamp() {
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
}

usage() {
    echo "用法: $0 -c <配置文件> [-v]"
    echo "  -c  指定配置文件（必填）"
    echo "  -v  启用详细日志输出"
    exit 1
}

log() {
    get_timestamp
    echo "[$TIMESTAMP] $*"
}

log_verbose() {
    if [[ "$VERBOSE" -eq 1 ]]; then
        get_timestamp
        echo "[$TIMESTAMP] [详细] $*" >&2
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

validate_project_config() {
    local project_name="$1"
    local url="$2"
    local download_path="$3"
    local ori_config_name="$4"
    local tar_topkey="$5"
    local only_proxy_file="$6"
    local f_config_path="$7"
    local f_config_name="$8"
    local errors=0

    if [[ -z "$url" ]]; then
        log "错误: 项目 $project_name 未配置 URL"
        errors=$((errors + 1))
    fi
    if [[ -z "$download_path" ]]; then
        log "错误: 项目 $project_name 未配置 download_path"
        errors=$((errors + 1))
    fi
    if [[ -z "$ori_config_name" ]]; then
        log "错误: 项目 $project_name 未配置 ori_config_name"
        errors=$((errors + 1))
    fi
    if [[ -z "$tar_topkey" ]]; then
        log "错误: 项目 $project_name 未配置 tar_topkey"
        errors=$((errors + 1))
    fi
    if [[ -z "$only_proxy_file" ]]; then
        log "错误: 项目 $project_name 未配置 only_proxy_file"
        errors=$((errors + 1))
    fi
    if [[ -z "$f_config_path" ]]; then
        log "错误: 项目 $project_name 未配置 f_config_path"
        errors=$((errors + 1))
    fi
    if [[ -z "$f_config_name" ]]; then
        log "错误: 项目 $project_name 未配置 f_config_name"
        errors=$((errors + 1))
    fi

    return $errors
}

validate_all_projects() {
    local config="$1"
    local project_names="$2"
    local has_errors=0

    while IFS= read -r project; do
        [[ -z "$project" ]] && continue
        local url download_path ori_config_name tar_topkey only_proxy_file f_config_path f_config_name

        url=$(yq eval ".mysubs.$project.url // \"\"" "$config")
        download_path=$(yq eval ".mysubs.$project.download_path // \"\"" "$config")
        ori_config_name=$(yq eval ".mysubs.$project.ori_config_name // \"\"" "$config")
        tar_topkey=$(yq eval ".mysubs.$project.tar_topkey // \"\"" "$config")
        only_proxy_file=$(yq eval ".mysubs.$project.only_proxy_file // \"\"" "$config")
        f_config_path=$(yq eval ".mysubs.$project.f_config_path // \"\"" "$config")
        f_config_name=$(yq eval ".mysubs.$project.f_config_name // \"\"" "$config")

        if ! validate_project_config "$project" "$url" "$download_path" "$ori_config_name" \
                                     "$tar_topkey" "$only_proxy_file" "$f_config_path" "$f_config_name"; then
            has_errors=1
        fi
    done <<< "$project_names"

    return $has_errors
}

handle_download_failure() {
    local reason="$1"
    local url="$2"
    local file_path="$3"

    log "错误: $reason: $url"
    rm -f "$file_path"
}

download_subscription() {
    local url="$1"
    local download_path="$2"
    local ori_config_name="$3"

    log_verbose "正在下载: $url"
    log_verbose "保存至: $download_path/$ori_config_name"

    mkdir -p "$download_path"

    local downloaded_file="${download_path}/${ori_config_name}"
    local ua="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0"
    local http_code

    http_code=$(curl -sL \
        --max-time "$CURL_TIMEOUT" \
        --connect-timeout "$CURL_CONNECT_TIMEOUT" \
        --retry "$MAX_RETRIES" \
        --retry-delay "$RETRY_INTERVAL" \
        -H "User-Agent: $ua" \
        -w "%{http_code}" \
        -o "$downloaded_file" \
        "$url")

    if [[ "$http_code" != "200" ]]; then
        handle_download_failure "HTTP状态码 ${http_code}" "$url" "$downloaded_file"
        return $FAILURE
    fi

    if [[ ! -s "$downloaded_file" ]]; then
        handle_download_failure "下载的文件为空" "$url" "$downloaded_file"
        return $FAILURE
    fi

    local header_content
    header_content=$(head -c 100 "$downloaded_file" 2>/dev/null)
    if [[ "$header_content" =~ (<!DOCTYPE|<html|<head>|<body>|<title>|404|500|Error|Access Denied|Forbidden|Not Found) ]]; then
        handle_download_failure "下载的内容可能是HTML错误页" "$url" "$downloaded_file"
        return $FAILURE
    fi

    if ! yq eval '.' "$downloaded_file" >/dev/null 2>&1; then
        handle_download_failure "下载的文件不是有效的YAML" "$url" "$downloaded_file"
        return $FAILURE
    fi

    log_verbose "下载成功: $downloaded_file"
    log_verbose "内容验证通过: $downloaded_file"
    return $SUCCESS
}

extract_topkey() {
    local ori_file="$1"
    local tar_topkey="$2"
    local only_proxy_file="$3"

    log_verbose "正在提取键值: $tar_topkey 来自 $ori_file"

    if ! yq eval "has(\"$tar_topkey\")" "$ori_file" >/dev/null 2>&1; then
        log "错误: 目标键 '$tar_topkey' 不存在于 $ori_file"
        return $FAILURE
    fi

    if yq eval "{\"$tar_topkey\": .$tar_topkey}" "$ori_file" > "$only_proxy_file" 2>/dev/null; then
        log_verbose "提取成功: $only_proxy_file"
        return $SUCCESS
    else
        log "错误: 提取键值失败 '$tar_topkey' 来自 $ori_file"
        return $FAILURE
    fi
}

process_project() {
    local project_name="$1"
    local config="$2"

    log "========================================="
    log "正在处理项目: $project_name"

    local url download_path ori_config_name tar_topkey only_proxy_file f_config_path f_config_name

    url=$(yq eval ".mysubs.$project_name.url // \"\"" "$config")
    download_path=$(yq eval ".mysubs.$project_name.download_path // \"\"" "$config")
    ori_config_name=$(yq eval ".mysubs.$project_name.ori_config_name // \"\"" "$config")
    tar_topkey=$(yq eval ".mysubs.$project_name.tar_topkey // \"\"" "$config")
    only_proxy_file=$(yq eval ".mysubs.$project_name.only_proxy_file // \"\"" "$config")
    f_config_path=$(yq eval ".mysubs.$project_name.f_config_path // \"\"" "$config")
    f_config_name=$(yq eval ".mysubs.$project_name.f_config_name // \"\"" "$config")

    if [[ -z "$url" ]]; then
        log "错误: 项目 $project_name 未配置 URL"
        return $FAILURE
    fi

    if ! download_subscription "$url" "$download_path" "$ori_config_name"; then
        return $FAILURE
    fi

    local ori_file="${download_path}/${ori_config_name}"
    if [[ ! -f "$ori_file" ]]; then
        log "错误: 下载的文件不存在: $ori_file"
        return $FAILURE
    fi

    local only_proxy_path="${download_path}/${only_proxy_file}"
    if ! extract_topkey "$ori_file" "$tar_topkey" "$only_proxy_path"; then
        return $FAILURE
    fi

    mkdir -p "$f_config_path"

    local final_file="${f_config_path}/${f_config_name}"
    local temp_file="${final_file}.tmp"

    {
        echo "# updated $(date '+%Y-%m-%d %H:%M:%S')"

        local override_files
        override_files=$(get_override_files "$config" "$project_name")
        while IFS= read -r override; do
            [[ -z "$override" ]] && continue
            override=${override##+([[:space:]])}
            override=${override%%+([[:space:]])}
            if [[ -f "${SCRIPT_DIR}/${override}" ]]; then
                cat "${SCRIPT_DIR}/${override}"
                log_verbose "已添加: ${SCRIPT_DIR}/${override}"
            else
                log "警告: 覆写文件不存在: ${SCRIPT_DIR}/${override}"
            fi
        done <<< "$override_files"

        if [[ -f "$only_proxy_path" ]]; then
            cat "$only_proxy_path"
        else
            log "错误: 文件不存在: $only_proxy_path"
            return $FAILURE
        fi
    } > "$temp_file"

    mv -f "$temp_file" "$final_file"

    log_verbose "合并完成: $final_file"

    log "项目 $project_name 处理成功"
    return $SUCCESS
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

    local project_array=()
    while IFS= read -r project; do
        [[ -z "$project" ]] && continue
        project_array+=("$project")
    done <<< "$project_names"

    TOTAL_COUNT=${#project_array[@]}
    log "发现 $TOTAL_COUNT 个项目待处理"

    if ! validate_all_projects "$CONFIG_FILE" "$project_names"; then
        log "错误: 配置验证失败，请检查上述错误信息"
        exit 1
    fi

    SUCCESS_COUNT=0
    for project in "${project_array[@]}"; do
        if process_project "$project" "$CONFIG_FILE"; then
            ((SUCCESS_COUNT++))
        else
            log "警告: 项目 $project 处理失败，将继续处理下一个项目"
        fi
    done

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
