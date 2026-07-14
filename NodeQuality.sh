#!/bin/bash

NQ_VERSION="1.0.0"
NQ_WEBHOOK_PROTOCOL="nq-webhook"
NQ_WEBHOOK_PROTOCOL_VERSION="1.0"
NQ_EVENT_BODY_LIMIT=8192
NQ_FINAL_BODY_LIMIT=65536
NQ_ERROR_SUMMARY_LIMIT=512
if [[ -z "${TERM:-}" || "$TERM" == "dumb" ]]; then
    export TERM=xterm
else
    export TERM
fi
script_source_dir=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    script_source_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
fi

current_time="$(date +%Y_%m_%d_%H_%M_%S)"
work_dir=".nodequality$current_time"
bench_os_url="https://github.com/LloydAsp/NodeQuality/releases/download/v0.0.2/BenchOs.tar.gz"
raw_file_prefix="${NQ_RESOURCE_BASE_URL:-https://raw.githubusercontent.com/P0me1oo/NodeQuality/v$NQ_VERSION}"

if uname -m | grep -Eq 'arm|aarch64'; then
    bench_os_url="https://github.com/LloydAsp/NodeQuality/releases/download/v0.0.2/BenchOs-arm.tar.gz"
fi

header_info_filename=header_info.log
ip_quality_filename=ip_quality.log
ip_quality_json_filename=ip_quality.json
hardware_quality_filename=hardware_quality.log
hardware_quality_json_filename=hardware_quality.json
net_quality_filename=net_quality.log
net_quality_json_filename=net_quality.json
backroute_trace_filename=backroute_trace.log
backroute_trace_json_filename=backroute_trace.json
port_filename=port.log

lang="cn"
opt_ipv=""
opt_lang=""
err_code=0

webhook_enabled=0
webhook_url="${NQ_WEBHOOK_URL:-}"
webhook_job_id="${NQ_WEBHOOK_JOB_ID:-}"
webhook_token="${NQ_WEBHOOK_TOKEN:-}"
webhook_version="${NQ_WEBHOOK_VERSION:-$NQ_WEBHOOK_PROTOCOL_VERSION}"
webhook_context_json="${NQ_WEBHOOK_CONTEXT_JSON:-{}}"
webhook_token_fd=""
non_interactive="${NQ_NON_INTERACTIVE:-0}"
hardware_mode="${NQ_HARDWARE_MODE:-}"
ip_mode="${NQ_IP_MODE:-}"
network_mode="${NQ_NETWORK_MODE:-}"
route_mode="${NQ_ROUTE_MODE:-}"

nq_sequence=0
nq_progress=0
nq_started_at=""
nq_signal=""
nq_exit_category="succeeded"
nq_exit_code=0
nq_terminal_event_sent=0
nq_cleanup_started=0
nq_cleanup_finished=0
nq_cleanup_status="not_started"
nq_cleanup_error=""
nq_remaining_mounts=""
nq_official_upload_status="not_started"
nq_official_report_url=""
nq_official_upload_error=""
nq_final_payload=""
nq_webhook_final_failed=0
nq_workdir_removed=false

declare -A NQ_MODULE_ENABLED=(
    [hardware]=false
    [ip_quality]=false
    [network_quality]=false
    [backroute]=false
)
declare -A NQ_MODULE_STATUS=(
    [hardware]=skipped
    [ip_quality]=skipped
    [network_quality]=skipped
    [backroute]=skipped
)
declare -A NQ_MODULE_EXIT=(
    [hardware]=0
    [ip_quality]=0
    [network_quality]=0
    [backroute]=0
)
declare -A NQ_MODULE_ERROR
declare -A NQ_MODULE_REPORT_URL
declare -A NQ_MODULE_SUMMARY

function nq_now(){
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

function nq_json_escape(){
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\r'/\\r}
    value=${value//$'\n'/\\n}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

function nq_limit_text(){
    local value="$1" limit="${2:-$NQ_ERROR_SUMMARY_LIMIT}"
    LC_ALL=C printf '%s' "$value" | head -c "$limit"
}

function nq_write_phase_hook(){
    cat <<'EOF'
#!/bin/bash
[[ -n "${NQ_PHASE_FILE:-}" && -n "${NQ_PHASE_MODULE:-}" ]] || return 0
nq_phase_hook(){
    local phase=""
    [[ "${FUNCNAME[1]:-}" == "check_Net" ]] || return 0
    case "$NQ_PHASE_MODULE:$BASH_COMMAND" in
        network_quality:db_bgptools\ *) phase="network_quality.bgp" ;;
        network_quality:get_tcp*) phase="network_quality.tcp_settings" ;;
        network_quality:get_delay\ *) phase="network_quality.tcp_latency.domestic" ;;
        network_quality:get_route\ *) phase="network_quality.route_summary" ;;
        network_quality:speedtest_test*) phase="network_quality.speed.domestic" ;;
        network_quality:iperf_test\ *) phase="network_quality.tcp_latency.international" ;;
        backroute:get_route_mode\ *) phase="backroute.trace" ;;
    esac
    [[ -n "$phase" ]] || return 0
    case "|${NQ_PHASE_SEEN:-}|" in
        *"|$phase|"*) return 0 ;;
    esac
    NQ_PHASE_SEEN="${NQ_PHASE_SEEN:+$NQ_PHASE_SEEN|}$phase"
    printf '%s\n' "$phase" >> "$NQ_PHASE_FILE"
}
set -o functrace
trap nq_phase_hook DEBUG
EOF
}

function nq_event_id(){
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        tr -d '\r\n' < /proc/sys/kernel/random/uuid
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr 'A-Z' 'a-z'
    else
        printf '%s-%06d-%s' "${webhook_job_id:-local}" "$nq_sequence" "$(date +%s%N 2>/dev/null || date +%s)"
    fi
}

function nq_validate_https_url(){
    local value="$1"
    [[ "$value" =~ ^https://[^[:space:]#]+$ ]] || return 1
    [[ "$value" != *"@"* ]]
}

function nq_validate_webhook_config(){
    local supplied=0
    [[ -n "$webhook_url" ]] && ((supplied++))
    [[ -n "$webhook_job_id" ]] && ((supplied++))
    [[ -n "$webhook_token" || -n "$webhook_token_fd" ]] && ((supplied++))
    [[ -n "${NQ_WEBHOOK_VERSION:-}" || -n "$webhook_url" ]] && ((supplied++))
    [[ $supplied -eq 0 ]] && return 0

    if [[ -n "$webhook_token_fd" ]]; then
        [[ "$webhook_token_fd" =~ ^[0-9]+$ ]] || return 64
        IFS= read -r webhook_token <&"$webhook_token_fd" || return 64
    fi
    unset NQ_WEBHOOK_TOKEN

    nq_validate_https_url "$webhook_url" || return 64
    [[ "$webhook_job_id" =~ ^[A-Za-z0-9._~-]{1,128}$ ]] || return 64
    [[ ${#webhook_token} -ge 32 && ${#webhook_token} -le 256 ]] || return 64
    [[ "$webhook_token" =~ ^[A-Za-z0-9._~-]+$ ]] || return 64
    [[ "$webhook_version" == "$NQ_WEBHOOK_PROTOCOL_VERSION" ]] || return 64
    [[ ${#webhook_context_json} -le 4096 ]] || return 64
    webhook_enabled=1
}

function nq_send_payload(){
    local payload="$1" final="${2:-0}"
    [[ $webhook_enabled -eq 1 ]] || return 0
    local bytes attempts max_attempts connect_timeout max_time delays response_code
    bytes=$(LC_ALL=C printf '%s' "$payload" | wc -c | tr -d ' ')
    if [[ $final -eq 1 ]]; then
        [[ $bytes -le $NQ_FINAL_BODY_LIMIT ]] || return 1
        max_attempts=4; connect_timeout=3; max_time=10; delays=(0 1 3 7)
    else
        [[ $bytes -le $NQ_EVENT_BODY_LIMIT ]] || return 1
        max_attempts=2; connect_timeout=2; max_time=5; delays=(0 1)
    fi
    for ((attempts=0; attempts<max_attempts; attempts++)); do
        (( delays[attempts] > 0 )) && sleep "${delays[attempts]}"
        response_code=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
            --proto '=https' --proto-redir '=https' --connect-timeout "$connect_timeout" --max-time "$max_time" \
            --request POST --header 'Content-Type: application/json' \
            --config <(printf 'header = "Authorization: Bearer %s"\n' "$webhook_token") \
            --header "X-NodeQuality-Protocol: $NQ_WEBHOOK_PROTOCOL_VERSION" \
            --data-binary "$payload" "$webhook_url" 2>/dev/null) || response_code=000
        case "$response_code" in
            200|201|202|204) return 0 ;;
            408|425|429|500|502|503|504|000) ;;
            *) return 1 ;;
        esac
    done
    return 1
}

function nq_emit_event(){
    local event_type="$1" module="$2" module_status="$3" phase_code="$4" message="$5" progress="$6"
    local error_code="${7:-}" error_summary="${8:-}" event_id payload timestamp
    [[ $webhook_enabled -eq 1 ]] || return 0
    (( progress < nq_progress )) && progress=$nq_progress
    (( progress > 100 )) && progress=100
    nq_progress=$progress
    ((nq_sequence++))
    event_id=$(nq_event_id)
    timestamp=$(nq_now)
    payload=$(printf '{"protocol":"%s","protocol_version":"%s","schema":"event","nodequality_version":"%s","job_id":"%s","event_id":"%s","sequence":%d,"event_type":"%s","job_status":"%s","module":"%s","module_status":"%s","progress":{"current":%d,"total":100,"unit":"percent"},"phase":{"code":"%s","status":"%s","message":"%s"},"timestamp":"%s","error":' \
        "$NQ_WEBHOOK_PROTOCOL" "$NQ_WEBHOOK_PROTOCOL_VERSION" "$NQ_VERSION" \
        "$(nq_json_escape "$webhook_job_id")" "$(nq_json_escape "$event_id")" "$nq_sequence" \
        "$(nq_json_escape "$event_type")" "$(nq_json_escape "$nq_exit_category")" \
        "$(nq_json_escape "$module")" "$(nq_json_escape "$module_status")" "$progress" \
        "$(nq_json_escape "$phase_code")" "$(nq_json_escape "$module_status")" "$(nq_json_escape "$message")" "$timestamp")
    if [[ -n "$error_code" ]]; then
        payload+=$(printf '{"code":"%s","summary":"%s"}' "$(nq_json_escape "$error_code")" "$(nq_json_escape "$(nq_limit_text "$error_summary")")")
    else
        payload+='null'
    fi
    payload+='}'
    nq_send_payload "$payload" 0 || true
}

declare -A LANG
# ===== English =====
LANG[en.err01]="Error: work_dir does not contain 'nodequality'!"
LANG[en.err02]="Error: Unsupported parameters!"
LANG[en.err03]="Error: the specified work_dir does not exist or is not readable/writable!"
LANG[en.cleanup]="Cleaning, please wait a moment."
LANG[en.clean_fail]="An unexpected situation occurred: the BenchOS directory mount was not cleaned up properly. For safety, please reboot and then delete this directory."
LANG[en.ask_hq]="Run HardwareQuality test? (Enter for default 'y', 'f' for fast mode, 'v' for all test details) [y/f/v/n]: "
LANG[en.ask_iq]="Run IPQuality test? (Enter for default 'y') [y/n]: "
LANG[en.ask_nq]="Run NetQuality test? (Enter for default 'y', 'l' for low-data mode) [y/l/n]: "
LANG[en.ask_bt]="Run Backroute Trace test? (Enter for default 'y') [y/n]: "
LANG[en.cleanup_before]="Clean Up before Installation"
LANG[en.loadbench]="Load BenchOs"
LANG[en.basicinfo]="Hardware Info"
LANG[en.run_hq]="Running Hardware Quality Test..."
LANG[en.run_iq]="Running IP Quality Test..."
LANG[en.run_nq]="Running Network Quality Test..."
LANG[en.run_bt]="Running Backroute Trace..."
LANG[en.cleanup_after]="Clean Up after Installation"
# ===== Chinese =====
LANG[cn.err01]="错误：work_dir不包含'nodequality'！"
LANG[cn.err02]="错误：不支持的参数！"
LANG[cn.err03]="错误：指定的 work_dir 不存在，或不可读/不可写！"
LANG[cn.cleanup]="清理中，请稍后。"
LANG[cn.clean_fail]="出现了预料之外的情况，BenchOS目录的挂载未被清理干净，保险起见请重启后删除该目录。"
LANG[cn.ask_hq]="运行 HardwareQuality 测试？（回车默认 'y'，'f' 为快速模式，'v' 为深度模式）[y/f/v/n]："
LANG[cn.ask_iq]="运行 IPQuality 测试？（回车默认 'y'）[y/n]："
LANG[cn.ask_nq]="运行 NetQuality 测试？（回车默认 'y'，'l' 为低流量模式）[y/l/n]："
LANG[cn.ask_bt]="运行 回程路由追踪（Backroute Trace）测试？（回车默认 'y'）[y/n]："
LANG[cn.cleanup_before]="安装前清理"
LANG[cn.loadbench]="加载 BenchOs"
LANG[cn.basicinfo]="硬件信息"
LANG[cn.run_hq]="正在运行硬件质量测试..."
LANG[cn.run_iq]="正在运行 IP 质量测试..."
LANG[cn.run_nq]="正在运行网络质量测试..."
LANG[cn.run_bt]="正在运行回程路由追踪..."
LANG[cn.cleanup_after]="安装后清理"

function L(){
    local key="${lang}.${1}"
    echo "${LANG[$key]:-${LANG[en.$1]}}"
}


function start_ascii() {
    echo -e "\e[1;36m"
    cat <<'EOF'

███╗   ██╗ ██████╗ ██████╗ ███████╗ ██████╗ ██╗   ██╗ █████╗ ██╗     ██╗████████╗██╗   ██╗
████╗  ██║██╔═══██╗██╔══██╗██╔════╝██╔═══██╗██║   ██║██╔══██╗██║     ██║╚══██╔══╝╚██╗ ██╔╝
██╔██╗ ██║██║   ██║██║  ██║█████╗  ██║   ██║██║   ██║███████║██║     ██║   ██║    ╚████╔╝ 
██║╚██╗██║██║   ██║██║  ██║██╔══╝  ██║▄▄ ██║██║   ██║██╔══██║██║     ██║   ██║     ╚██╔╝  
██║ ╚████║╚██████╔╝██████╔╝███████╗╚██████╔╝╚██████╔╝██║  ██║███████╗██║   ██║      ██║   
╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚══════╝ ╚══▀▀═╝  ╚═════╝ ╚═╝  ╚═╝╚══════╝╚═╝   ╚═╝      ╚═╝   

EOF
    if [[ "$lang" == "en" ]]; then
        cat <<'EOF'
Benchmark script for server, collects basic hardware information, IP quality and network quality

The benchmark will be performed in a temporary system, and all traces will be deleted after that.
Therefore, it has no impact on the original environment and supports almost all linux systems.

Author: Lloyd@nodeseek.com
Github: github.com/LloydAsp/NodeQuality
Command: bash <(curl -sL https://run.NodeQuality.com)
EOF
    else
        cat <<'EOF'
网络服务器的专业测评脚本，检测硬件质量、IP质量和网络质量

脚本测试是纯净的，在临时系统中执行，之后所有的痕迹都会被删除
因此，它不会对原始环境产生任何影响，并且支持几乎所有 Linux 系统

作者：Lloyd@nodeseek.com
仓库：github.com/LloydAsp/NodeQuality
命令：bash <(curl -sL https://run.NodeQuality.com)
EOF
    fi
    echo -e "\033[0m"
}

function _red() {
    echo -e "\033[0;31m$1\033[0m"
}

function _yellow() {
    echo -e "\033[0;33m$1\033[0m"
}

function _blue() {
    echo -e "\033[0;36m$1\033[0m"
}

function _green() {
    echo -e "\033[0;32m$1\033[0m"
}

function _red_bold() {
    echo -e "\033[1;31m$1\033[0m"
}

function _yellow_bold() {
    echo -e "\033[1;33m$1\033[0m"
}

function _blue_bold() {
    echo -e "\033[1;36m$1\033[0m"
}

function _green_bold() {
    echo -e "\033[1;32m$1\033[0m"
}

function get_opts(){
    local args=("$@") index=0 opt opt_dir
    while (( index < ${#args[@]} )); do
        opt="${args[index]}"
        case "$opt" in
            -4)
                if [[ "$opt_ipv" == "-6" ]]; then opt_ipv=""; else opt_ipv="-4"; fi
                ;;
            -6)
                if [[ "$opt_ipv" == "-4" ]]; then opt_ipv=""; else opt_ipv="-6"; fi
                ;;
            -D|-d)
                ((index++))
                opt_dir="${args[index]:-}"
                opt_dir="${opt_dir%/}"
                if [[ ! -d "$opt_dir" || ! -r "$opt_dir" || ! -w "$opt_dir" ]]; then
                    echo "$(L err03)"
                    return 64
                else
                    work_dir="${opt_dir}/${work_dir}"
                fi
                ;;
            -E|-e)
                lang="en"
                opt_lang="-E"
                ;;
            --webhook-url)
                ((index++)); webhook_url="${args[index]:-}"
                ;;
            --webhook-job-id)
                ((index++)); webhook_job_id="${args[index]:-}"
                ;;
            --webhook-version)
                ((index++)); webhook_version="${args[index]:-}"
                ;;
            --webhook-token-env)
                ((index++)); local token_env_name="${args[index]:-}"
                [[ "$token_env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 64
                webhook_token="${!token_env_name:-}"
                unset "$token_env_name"
                ;;
            --webhook-token-fd)
                ((index++)); webhook_token_fd="${args[index]:-}"
                ;;
            --webhook-token|--webhook-token=*)
                echo "错误：不支持在命令行中传入明文 Webhook Token，请使用环境变量或 --webhook-token-fd。" >&2
                return 64
                ;;
            --webhook-context-file)
                ((index++)); local context_file="${args[index]:-}"
                [[ -r "$context_file" ]] || return 64
                webhook_context_json=$(LC_ALL=C head -c 4097 "$context_file")
                ;;
            --non-interactive)
                non_interactive=1
                ;;
            --hardware)
                ((index++)); hardware_mode="${args[index]:-}"
                ;;
            --ip)
                ((index++)); ip_mode="${args[index]:-}"
                ;;
            --network)
                ((index++)); network_mode="${args[index]:-}"
                ;;
            --route)
                ((index++)); route_mode="${args[index]:-}"
                ;;
            --version)
                printf 'NodeQuality %s\nWebhook %s/%s\n' "$NQ_VERSION" "$NQ_WEBHOOK_PROTOCOL" "$NQ_WEBHOOK_PROTOCOL_VERSION"
                exit 0
                ;;
            --help|-h)
                printf '%s\n' "NodeQuality $NQ_VERSION" \
                    "  -4 / -6                         指定 IP 协议" \
                    "  -d, -D <目录>                   指定临时工作目录父目录" \
                    "  -e, -E                          使用英文输出" \
                    "  --non-interactive               使用非交互检测选项" \
                    "  --hardware standard|fast|deep|skip" \
                    "  --ip run|skip" \
                    "  --network standard|low|skip" \
                    "  --route run|skip" \
                    "  --webhook-url <HTTPS URL>" \
                    "  --webhook-job-id <ID>" \
                    "  --webhook-version 1.0" \
                    "  --webhook-token-env <环境变量名>" \
                    "  --webhook-token-fd <文件描述符>"
                exit 0
                ;;
            *)
                echo "$(L err02) $opt" >&2
                return 64
                ;;
        esac
        ((index++))
    done
}

function normalize_modes(){
    local enabled_count=0
    if [[ "$non_interactive" == "1" ]]; then
        case "${hardware_mode:-standard}" in
            standard) run_hardware_quality_test=y ;;
            fast) run_hardware_quality_test=f ;;
            deep) run_hardware_quality_test=v ;;
            skip) run_hardware_quality_test=n ;;
            *) return 64 ;;
        esac
        case "${ip_mode:-run}" in run) run_ip_quality_test=y ;; skip) run_ip_quality_test=n ;; *) return 64 ;; esac
        case "${network_mode:-standard}" in standard) run_net_quality_test=y ;; low) run_net_quality_test=l ;; skip) run_net_quality_test=n ;; *) return 64 ;; esac
        case "${route_mode:-run}" in run) run_net_trace_test=y ;; skip) run_net_trace_test=n ;; *) return 64 ;; esac
    else
        ask_question
    fi
    [[ "$run_hardware_quality_test" =~ ^[YyFfVv]$ ]] && NQ_MODULE_ENABLED[hardware]=true
    [[ "$run_ip_quality_test" =~ ^[Yy]$ ]] && NQ_MODULE_ENABLED[ip_quality]=true
    [[ "$run_net_quality_test" =~ ^[YyLl]$ ]] && NQ_MODULE_ENABLED[network_quality]=true
    [[ "$run_net_trace_test" =~ ^[Yy]$ ]] && NQ_MODULE_ENABLED[backroute]=true
    [[ "${NQ_MODULE_ENABLED[hardware]}" == true ]] && ((enabled_count++))
    [[ "${NQ_MODULE_ENABLED[ip_quality]}" == true ]] && ((enabled_count++))
    [[ "${NQ_MODULE_ENABLED[network_quality]}" == true ]] && ((enabled_count++))
    [[ "${NQ_MODULE_ENABLED[backroute]}" == true ]] && ((enabled_count++))
    (( enabled_count > 0 ))
}

function pre_init(){
    mkdir -p "$work_dir"
    cd "$work_dir" || return 1
    work_dir="$(pwd)"
}

function pre_cleanup(){
    clear_mount || true
    [[ "$work_dir" == *"nodequality"* ]] || return 1
    find "$work_dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || return 1
}

function clear_mount(){
    local bench="$work_dir/BenchOs"
    swapoff "$work_dir/swap" 2>/dev/null || true
    umount -R "$bench/dev" 2>/dev/null || true
    umount "$bench/proc" 2>/dev/null || true
    umount "$bench/sys" 2>/dev/null || true
}

function nq_mount_targets(){
    if command -v findmnt >/dev/null 2>&1; then
        findmnt -rn -o TARGET 2>/dev/null
    else
        awk '{print $5}' /proc/self/mountinfo 2>/dev/null
    fi
}

function nq_mounts_under_workdir(){
    nq_mount_targets | awk -v root="$work_dir" '$0 == root || index($0, root "/") == 1'
}

function load_bench_os(){
    cd "$work_dir" || return 1
    rm -rf BenchOs

    curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 30 --max-time 300 -o BenchOs.tar.gz "$bench_os_url" || return 1
    tar -xzf BenchOs.tar.gz || return 1
    cd "$work_dir/BenchOs" || return 1

    mount -t proc /proc proc/ || return 1
    mount --bind /sys sys/ || return 1
    mount --rbind /dev dev/ || return 1
    mount --make-rslave dev || return 1

    rm etc/resolv.conf 2>/dev/null
    cp /etc/resolv.conf etc/resolv.conf

    # 第三方模块的报告上传响应通过 curl 包装器写入受控 sidecar；广告资源请求返回空内容。
    if [[ -x usr/bin/curl && ! -e usr/bin/curl.nq-real ]]; then
        mv usr/bin/curl usr/bin/curl.nq-real
    fi
    mkdir -p usr/local/bin
    cat > usr/local/bin/curl <<'EOF'
#!/bin/bash
real_curl=/usr/bin/curl.nq-real
for arg in "$@"; do
    case "$arg" in
        */ref/ad*.ans|*/ref/sponsor.ans)
            exit 0
            ;;
    esac
done
is_report_upload=0
for arg in "$@"; do
    case "$arg" in
        http://upload.check.place|https://upload.check.place) is_report_upload=1 ;;
    esac
done
if [[ $is_report_upload -eq 1 && -n "${NQ_REPORT_SLOT:-}" ]]; then
    response=$("$real_curl" "$@")
    code=$?
    if [[ $code -eq 0 ]]; then
        printf '%s' "$response" > "/result/${NQ_REPORT_SLOT}_report_url.txt"
    fi
    printf '%s' "$response"
    exit "$code"
fi
exec "$real_curl" "$@"
EOF
    chmod 755 usr/local/bin/curl

    # 通过第三方脚本的函数调用边界写入稳定 phase code，不解析终端文案或动画。
    mkdir -p usr/local/lib
    nq_write_phase_hook > usr/local/lib/nq-phase-hook.sh
    chmod 644 usr/local/lib/nq-phase-hook.sh
}

function chroot_run(){
    chroot "$work_dir/BenchOs" /bin/bash -c "$*"
}

function chroot_run_timeout(){
    local seconds="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout --signal=TERM --kill-after=30s "${seconds}s" \
            chroot "$work_dir/BenchOs" /bin/bash -c "$*"
    else
        chroot_run "$*"
    fi
}

function load_part(){
    if [[ -n "$script_source_dir" && -r "$script_source_dir/part/swap.sh" ]]; then
        . "$script_source_dir/part/swap.sh"
    else
        . <(curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' "$raw_file_prefix/part/swap.sh")
    fi
}

function load_3rd_program(){
    chroot_run wget https://github.com/nxtrace/NTrace-core/releases/download/v1.3.7/nexttrace_linux_amd64 -qO /usr/local/bin/nexttrace
    chroot_run chmod u+x /usr/local/bin/nexttrace
}

function run_header(){
    if [[ -n "$script_source_dir" && -r "$script_source_dir/part/header.sh" ]]; then
        chroot_run bash -s < "$script_source_dir/part/header.sh"
    else
        chroot_run bash <(curl -Ls "$raw_file_prefix/part/header.sh")
    fi
}

function detect_virt() {
    if [[ -f /run/systemd/container ]]; then
        cat /run/systemd/container
        return
    fi
    if [[ -f /.dockerenv ]]; then
        echo docker
        return
    fi
    if [[ -f /run/.containerenv ]]; then
        echo podman
        return
    fi
    if grep -qa 'lxc' /proc/1/cgroup 2>/dev/null; then
        echo lxc
        return
    fi
    if grep -qa 'hypervisor' /proc/cpuinfo 2>/dev/null; then
        echo kvm
        return
    fi
    echo none
}

############ 以下内容为HQ预处理部分 ############
function detect_testdev_type(){
    local dev="$1"
    dev="$(readlink -f "$dev" 2>/dev/null)"
    if [[ "$dev" == /dev/md* ]]; then
        local lvl
        lvl=$(
            awk -v md="$(basename "$dev")" '
                $1 == md {
                    for (i=1;i<=NF;i++)
                        if ($i ~ /^raid[0-9]+$/) {
                            print toupper($i)
                            exit
                        }
                }
            ' /proc/mdstat
        )
        [[ -n "$lvl" ]] && echo "$lvl" || echo "RAID"
        return
    fi
    if [[ "$dev" == /dev/mapper/* || "$dev" == /dev/dm-* ]]; then
        echo "LVM"
        return
    fi
    if lsblk -no TYPE "$dev" 2>/dev/null | grep -qE 'disk|part'; then
        echo "DISK"
        return
    fi
    echo ""
}

function get_testdev_members_from_diskinfo(){
    local dev="$1"
    local i
    for ((i=1; i<=diskinfo[raid_count]; i++)); do
        if [[ "${diskinfo[raid$i.name]}" == "$dev" ]]; then
            echo "${diskinfo[raid$i.devs]}"
            return
        fi
    done
}

function get_testdev_mount_from_diskinfo(){
    local dev="$1"
    local i
    for ((i=1; i<=diskinfo[raid_count]; i++)); do
        if [[ "${diskinfo[raid$i.name]}" == "$dev" ]]; then
            echo "${diskinfo[raid$i.mount]}"
            return
        fi
    done
}

function get_md_mount(){
    local md="$1"
    local mp=""
    mp="$(findmnt -n -o TARGET "/dev/$md" 2>/dev/null)"
    [[ -n "$mp" ]] && { echo "$mp"; return; }
    mp="$(
        lsblk -o NAME,PKNAME,TYPE,MOUNTPOINT -r 2>/dev/null \
        | awk -v md="$md" '$2==md && $4!="" {print $4}' \
        | sort -u | paste -sd "," -
    )"
    [[ -n "$mp" ]] && echo "$mp"
}

function pre_fetch_info(){
    local virt_type="$(detect_virt)"
    declare -gA osinfo
    osinfo[proc]=$(ps -e 2>/dev/null | wc -l | tr -d ' ')
    if command -v loginctl >/dev/null 2>&1; then
        tmpuc="$(loginctl list-users 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
        [[ "$tmpuc" -gt 0 ]] && osinfo[user]="$tmpuc"
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        tmpuc="$(stat -f '%Su' /dev/console 2>/dev/null | wc -l | tr -d ' ')"
        [[ "$tmpuc" -gt 0 ]] && osinfo[user]="$tmpuc"
    else
        tmpuc="$(who 2>/dev/null | wc -l | tr -d ' ')"
        [[ "$tmpuc" -gt 0 ]] && osinfo[user]="$tmpuc"
    fi
    if [[ "${virt_type}" =~ ^(docker|podman|lxc|container)$ ]] && [[ "$(ps -p 1 -o comm= 2>/dev/null)" != "systemd" ]]; then
        osinfo[svcr]=""
        osinfo[svct]=""
    elif command -v systemctl >/dev/null 2>&1; then
        osinfo[svcr]=$(systemctl list-units --type=service --state=running 2>/dev/null | grep '\.service' | wc -l | tr -d ' ')
        osinfo[svct]=$(systemctl list-unit-files --type=service 2>/dev/null | grep '\.service' | wc -l | tr -d ' ')
    elif command -v rc-service >/dev/null 2>&1; then
        osinfo[svcr]=$(rc-service -r 2>/dev/null | wc -l | tr -d ' ')
        osinfo[svct]=$(rc-service -l 2>/dev/null | wc -l | tr -d ' ')
    elif [[ "$(uname -s)" == "Darwin" ]] && command -v launchctl >/dev/null 2>&1; then
        osinfo[svcr]=$(launchctl list 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
        osinfo[svct]="${osinfo[svcr]}"
    fi
    declare -gA meminfo
    case "${virt_type}" in
        kvm)
            if lsmod 2>/dev/null | grep -q '^virtio_balloon'; then
                meminfo[balloon]=1
            else
                meminfo[balloon]=0
            fi
            if [[ -r /sys/kernel/mm/ksm/run ]] && [[ "$(cat /sys/kernel/mm/ksm/run)" == "1" ]]; then
                meminfo[ksm]=1
            else
                meminfo[ksm]=0
            fi
            ;;
        lxc)
            meminfo[neighbor]=$(ls /sys/devices/virtual/block 2>/dev/null | grep -c '^dm')
            ;;
    esac
    declare -gA diskinfo
    local ridx=0
    if [[ -r /proc/mdstat ]]; then
        while read -r line; do
            if [[ "$line" =~ ^(md[0-9]+)[[:space:]]*:[[:space:]]*active[[:space:]]+([a-z0-9]+)[[:space:]]+(.*)$ ]]; then
                ((ridx++))
                local rname="${BASH_REMATCH[1]}"
                local rlevel="${BASH_REMATCH[2]}"
                local rdevs="${BASH_REMATCH[3]}"
                rlevel="${rlevel^^}"
                rdevs="$(awk '{for(i=1;i<=NF;i++) if ($i ~ /\[[0-9]+\]/) printf "%s ", $i}' <<<"$rdevs")"
                rdevs="${rdevs% }"
                diskinfo["raid$ridx.name"]="$rname"
                diskinfo["raid$ridx.level"]="$rlevel"
                diskinfo["raid$ridx.devs"]="$rdevs"
                diskinfo["raid$ridx.mount"]="$(get_md_mount "$rname")"
            fi
        done < /proc/mdstat
    fi
    diskinfo[raid_count]="$ridx"
    diskinfo[testdir]="${work_dir%/*}"
    diskinfo[testdev]=$(df --output=source "$work_dir" | awk 'NR==2')
    diskinfo[testdev_type]=$(detect_testdev_type "${diskinfo[testdev]}")
    diskinfo[testdev]="${diskinfo[testdev]#/dev/}"
    if [[ "${diskinfo[testdev_type]}" == RAID* ]]; then
        diskinfo[testdev_members]=$(get_testdev_members_from_diskinfo "${diskinfo[testdev]}")
        diskinfo[testdev_mount]=$(get_testdev_mount_from_diskinfo "${diskinfo[testdev]}")
    fi
}
############ 以上内容为HQ预处理部分 ############

function run_HardwareQuality(){
    local params=""
    [[ "$run_hardware_quality_test" =~ ^[Ff]$ ]] && params=" -F"
    [[ "$run_hardware_quality_test" =~ ^[Vv]$ ]] && params=" -V"
    pre_fetch_info # HQ预处理
    payload=$(declare -p osinfo meminfo diskinfo) # HQ预处理
    curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' https://Hardware.Check.Place | chroot_run_timeout 3600 "env NQ_REPORT_SLOT=hardware NQENV=$(printf '%q' "$payload") bash -s -- $opt_lang $params -y -o /result/$hardware_quality_json_filename"
    # 原始语句为：chroot_run bash <(curl -Ls https://Hardware.Check.Place) $opt_lang -y -o /result/$hardware_quality_json_filename
}


function run_ip_quality(){
    chroot_run_timeout 1800 "env NQ_REPORT_SLOT=ip_quality bash <(curl -Ls https://IP.Check.Place) $opt_ipv $opt_lang -y -o /result/$ip_quality_json_filename"
}

function run_net_quality(){
    local params=""
    [[ "$run_net_quality_test" =~ ^[Ll]$ ]] && params=" -L"
    chroot_run_timeout 3600 "env NQ_REPORT_SLOT=network_quality NQ_PHASE_MODULE=network_quality NQ_PHASE_FILE=/result/network_quality.phases BASH_ENV=/usr/local/lib/nq-phase-hook.sh bash <(curl -Ls https://Net.Check.Place) $opt_ipv $opt_lang $params -y -o /result/$net_quality_json_filename"
}

function run_net_trace(){
    chroot_run_timeout 2400 "env NQ_REPORT_SLOT=backroute NQ_PHASE_MODULE=backroute NQ_PHASE_FILE=/result/backroute.phases BASH_ENV=/usr/local/lib/nq-phase-hook.sh bash <(curl -Ls https://Net.Check.Place) $opt_ipv $opt_lang -R -n -S 123 -o /result/$backroute_trace_json_filename"
}

uploadAPI="https://api.nodequality.com/api/v1/record"
function upload_result(){
    local response_file="$work_dir/upload-response.txt" response code
    nq_official_upload_status="running"
    chroot_run "rm -rf /tmp/nodequality-upload && mkdir -p /tmp/nodequality-upload; \
        for file in /result/*.json /result/header_info.log; do [ -f \"\$file\" ] && cp \"\$file\" /tmp/nodequality-upload/; done; \
        for file in /result/hardware_quality.log /result/ip_quality.log /result/net_quality.log /result/backroute_trace.log; do \
            [ -f \"\$file\" ] || continue; \
            sed -E '/(Checks Today|检测量|Thanks for running|感谢使用.*脚本|sponsor|赞助|邀请码|折扣码)/Id' \"\$file\" > /tmp/nodequality-upload/\"\$(basename \"\$file\")\"; \
        done; \
        cd /tmp/nodequality-upload && zip -q -j /tmp/nodequality-result.zip ./*" || {
        nq_official_upload_status="failed"
        nq_official_upload_error="无法创建官方报告归档"
        return 1
    }
    cp "$work_dir/BenchOs/tmp/nodequality-result.zip" "$work_dir/result.zip" || {
        nq_official_upload_status="failed"
        nq_official_upload_error="无法读取官方报告归档"
        return 1
    }
    code=$(base64 "$work_dir/result.zip" | curl --silent --show-error --output "$response_file" --write-out '%{http_code}' \
        --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 \
        --request POST --data-binary @- "$uploadAPI" 2>/dev/null) || code=000
    response=$(LC_ALL=C head -c 8192 "$response_file" 2>/dev/null)
    if [[ "$code" != 2* ]]; then
        nq_official_upload_status="failed"
        nq_official_upload_error="官方汇总报告上传失败（HTTP $code）"
        return 1
    fi
    if [[ "$response" =~ https://nodequality\.com/r/[A-Za-z0-9._~-]{1,128} ]]; then
        nq_official_report_url="${BASH_REMATCH[0]}"
        nq_official_upload_status="succeeded"
        printf '%s\n' "$nq_official_report_url"
        return 0
    fi
    nq_official_upload_status="failed"
    nq_official_upload_error="官方上传响应未包含有效报告 URL"
    return 1
}

function nq_validate_report_url(){
    local value="$1" pattern='^https://report\.check\.place/[A-Za-z0-9._~/?=&%+-]+$'
    shopt -s nocasematch
    [[ "$value" =~ $pattern ]]
    local code=$?
    shopt -u nocasematch
    return "$code"
}

function nq_collect_report_urls(){
    local module value
    for module in hardware ip_quality network_quality backroute; do
        value=$(LC_ALL=C head -c 2048 "$result_directory/${module}_report_url.txt" 2>/dev/null | tr -d '\r\n')
        if nq_validate_report_url "$value"; then
            NQ_MODULE_REPORT_URL[$module]="$value"
        elif [[ "${NQ_MODULE_ENABLED[$module]}" == true && "${NQ_MODULE_STATUS[$module]}" == succeeded ]]; then
            NQ_MODULE_STATUS[$module]=partial
            NQ_MODULE_ERROR[$module]="检测结果有效，但模块在线报告 URL 缺失或无效"
        fi
    done
}

function nq_module_summary(){
    local module="$1" file filter fallback_filter result bytes
    case "$module" in
        hardware)
            file="/$hardware_quality_json_filename"
            filter='{Head:(.Head // {} | del(.Command,.GitHub)),OS:(.OS // {}),Motherboard:(.Motherboard // {}),CPU:(.CPU // {}),GPU:(.GPU // {}),Memory:(.Memory // {}),Disk:(.Disk // {}),Benchmark:(.Benchmark // {})}'
            fallback_filter='{Head:(.Head // {} | del(.Command,.GitHub)),OS:(.OS // {}),CPU:(.CPU // {}),Memory:(.Memory // {}),Benchmark:(.Benchmark // {})}'
            ;;
        ip_quality)
            file="/$ip_quality_json_filename"
            filter='{Head:(.Head // {} | del(.Command,.GitHub)),Info:(.Info // {}),Type:(.Type // {}),Score:(.Score // {}),Factor:(.Factor // {}),Media:(.Media // {}),Mail:(.Mail // {})}'
            fallback_filter='{Head:(.Head // {} | del(.Command,.GitHub)),Info:(.Info // {}),Type:(.Type // {}),Score:(.Score // {}),Media:(.Media // {})}'
            ;;
        network_quality|backroute)
            [[ "$module" == network_quality ]] && file="/$net_quality_json_filename" || file="/$backroute_trace_json_filename"
            filter='{Head:(.Head // {} | del(.Command,.GitHub)),BGP:(.BGP // {}),Local:(.Local // {}),Connectivity:((.Connectivity // [])[0:20]),Delay:((.Delay // [])[0:40]),Speedtest:((.Speedtest // [])[0:20]),Transfer:((.Transfer // [])[0:20])}'
            fallback_filter='{Head:(.Head // {} | del(.Command,.GitHub)),BGP:(.BGP // {}),Local:(.Local // {}),Delay:((.Delay // [])[0:12]),Speedtest:((.Speedtest // [])[0:8]),Transfer:((.Transfer // [])[0:8])}'
            ;;
    esac
    [[ -s "$result_directory/${file#/}" ]] || { printf '{}'; return; }
    result=$(chroot_run "jq -c '$filter' /result/$file 2>/dev/null")
    bytes=$(LC_ALL=C printf '%s' "$result" | wc -c | tr -d ' ')
    if (( bytes > 12288 )); then
        result=$(chroot_run "jq -c '$fallback_filter' /result/$file 2>/dev/null")
    fi
    if [[ "$result" == \{*\} ]]; then printf '%s' "$result"; else printf '{}'; fi
}

function nq_collect_module_summaries(){
    local module
    for module in hardware ip_quality network_quality backroute; do
        if [[ "${NQ_MODULE_ENABLED[$module]}" == true ]]; then
            NQ_MODULE_SUMMARY[$module]=$(nq_module_summary "$module")
        else
            NQ_MODULE_SUMMARY[$module]='{}'
        fi
    done
}

function nq_cleanup(){
    [[ $nq_cleanup_finished -eq 1 ]] && return 0
    [[ $nq_cleanup_started -eq 1 ]] && return 1
    nq_cleanup_started=1
    nq_cleanup_status="running"
    nq_emit_event cleanup.started cleanup running cleanup.stop_children "正在清理临时资源" 94
    clear_mount
    nq_remaining_mounts=$(nq_mounts_under_workdir)
    if [[ -n "$nq_remaining_mounts" ]]; then
        while IFS= read -r target; do
            [[ -n "$target" ]] && umount "$target" 2>/dev/null || true
        done < <(printf '%s\n' "$nq_remaining_mounts" | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-)
        nq_remaining_mounts=$(nq_mounts_under_workdir)
    fi
    if [[ -n "$nq_remaining_mounts" ]]; then
        nq_cleanup_status="failed"
        nq_cleanup_error="BenchOS 工作目录下仍有挂载点，已阻止递归删除"
        nq_emit_event cleanup.failed cleanup failed cleanup.verify_mounts "临时资源清理失败" 99 NQ_CLEANUP_MOUNT_REMAINING "$nq_cleanup_error"
        nq_cleanup_finished=1
        return 1
    fi
    rm -rf -- "$work_dir/BenchOs" "$work_dir/BenchOs.tar.gz" "$work_dir/result.zip" "$work_dir/upload-response.txt" 2>/dev/null || {
        nq_cleanup_status="partial"
        nq_cleanup_error="部分临时文件删除失败"
        nq_emit_event cleanup.partial cleanup partial cleanup.remove_benchos "临时资源部分清理完成" 99 NQ_CLEANUP_REMOVE_FAILED "$nq_cleanup_error"
        nq_cleanup_finished=1
        return 1
    }
    nq_cleanup_status="succeeded"
    nq_cleanup_finished=1
    nq_emit_event cleanup.completed cleanup succeeded cleanup.completed "临时资源清理完成" 99
    return 0
}

function nq_determine_final_status(){
    local succeeded=0 failed=0 partial=0 module
    for module in hardware ip_quality network_quality backroute; do
        [[ "${NQ_MODULE_ENABLED[$module]}" == true ]] || continue
        case "${NQ_MODULE_STATUS[$module]}" in
            succeeded) ((succeeded++)) ;;
            partial) ((partial++)) ;;
            failed) ((failed++)) ;;
        esac
    done
    if [[ "$nq_exit_category" == cancelled || "$nq_exit_category" == terminated ]]; then return; fi
    if (( succeeded == 0 && partial == 0 )); then
        nq_exit_category="failed"; nq_exit_code=3
    elif (( failed > 0 || partial > 0 )) || [[ "$nq_official_upload_status" != succeeded || "$nq_cleanup_status" != succeeded ]]; then
        nq_exit_category="partial"; nq_exit_code=2
    else
        nq_exit_category="succeeded"; nq_exit_code=0
    fi
}

function nq_bool_json(){ [[ "$1" == true ]] && printf true || printf false; }
function nq_nullable_json(){ [[ -n "$1" ]] && printf '"%s"' "$(nq_json_escape "$1")" || printf null; }
function nq_lines_json_array(){
    local input="$1" line output="" separator="" count=0
    while IFS= read -r line && (( count < 16 )); do
        [[ -n "$line" ]] || continue
        output+="$separator\"$(nq_json_escape "$(nq_limit_text "$line" 512)")\""
        separator=,
        ((count++))
    done <<< "$input"
    printf '[%s]' "$output"
}

function nq_build_final_payload(){
    local event_id timestamp event_type module enabled status report summary error_json modules_json="" separator=""
    ((nq_sequence++)); event_id=$(nq_event_id); timestamp=$(nq_now)
    case "$nq_exit_category" in
        succeeded|partial) event_type="job.completed" ;;
        cancelled) event_type="job.cancelled" ;;
        terminated) event_type="job.terminated" ;;
        *) event_type="job.failed" ;;
    esac
    for module in hardware ip_quality network_quality backroute; do
        enabled=$(nq_bool_json "${NQ_MODULE_ENABLED[$module]}")
        status="${NQ_MODULE_STATUS[$module]}"
        report=$(nq_nullable_json "${NQ_MODULE_REPORT_URL[$module]:-}")
        summary="${NQ_MODULE_SUMMARY[$module]:-}"
        [[ -n "$summary" ]] || summary='{}'
        if [[ -n "${NQ_MODULE_ERROR[$module]:-}" ]]; then
            error_json=$(printf '[{"code":"NQ_%s_EXEC_FAILED","summary":"%s"}]' "${module^^}" "$(nq_json_escape "$(nq_limit_text "${NQ_MODULE_ERROR[$module]}")")")
        else error_json='[]'; fi
        modules_json+="$separator\"$module\":{\"enabled\":$enabled,\"status\":\"$status\",\"exit_code\":${NQ_MODULE_EXIT[$module]},\"report_url\":$report,\"summary\":$summary,\"errors\":$error_json}"
        separator=,
    done
    nq_final_payload=$(printf '{"protocol":"%s","protocol_version":"%s","schema":"final_result","nodequality_version":"%s","job_id":"%s","event_id":"%s","sequence":%d,"event_type":"%s","timestamp":"%s","status":"%s","exit":{"category":"%s","code":%d,"signal":%s},"progress":{"current":100,"total":100,"unit":"percent"},"reports":{"nodequality":%s,"hardware_svg":%s,"ip_svg":%s,"network_svg":%s,"backroute":%s},"modules":{%s},"official_upload":{"status":"%s","report_url":%s,"error":%s},"cleanup":{"status":"%s","remaining_mounts":%s,"work_directory_removed":true,"errors":%s},"context":%s}' \
        "$NQ_WEBHOOK_PROTOCOL" "$NQ_WEBHOOK_PROTOCOL_VERSION" "$NQ_VERSION" "$(nq_json_escape "$webhook_job_id")" "$(nq_json_escape "$event_id")" "$nq_sequence" "$event_type" "$timestamp" "$nq_exit_category" "$nq_exit_category" "$nq_exit_code" "$(nq_nullable_json "$nq_signal")" \
        "$(nq_nullable_json "$nq_official_report_url")" "$(nq_nullable_json "${NQ_MODULE_REPORT_URL[hardware]:-}")" "$(nq_nullable_json "${NQ_MODULE_REPORT_URL[ip_quality]:-}")" "$(nq_nullable_json "${NQ_MODULE_REPORT_URL[network_quality]:-}")" "$(nq_nullable_json "${NQ_MODULE_REPORT_URL[backroute]:-}")" "$modules_json" "$nq_official_upload_status" "$(nq_nullable_json "$nq_official_report_url")" "$(nq_nullable_json "$nq_official_upload_error")" "$nq_cleanup_status" "$(nq_lines_json_array "$nq_remaining_mounts")" "$([[ -n "$nq_cleanup_error" ]] && printf '[{"code":"NQ_CLEANUP_FAILED","summary":"%s"}]' "$(nq_json_escape "$(nq_limit_text "$nq_cleanup_error")")" || printf '[]')" "$webhook_context_json")
    nq_final_payload=${nq_final_payload/\"work_directory_removed\":true/\"work_directory_removed\":$nq_workdir_removed}
}

function nq_send_final(){
    [[ $webhook_enabled -eq 1 ]] || return 0
    [[ $nq_terminal_event_sent -eq 1 ]] && return 0
    nq_terminal_event_sent=1
    nq_build_final_payload
    if ! nq_send_payload "$nq_final_payload" 1; then
        nq_webhook_final_failed=1
        return 1
    fi
}

function nq_handle_signal(){
    local signal="$1"
    [[ -n "$nq_signal" ]] && return
    nq_signal="$signal"
    case "$signal" in
        INT) nq_exit_category="cancelled"; nq_exit_code=4 ;;
        TERM|HUP) nq_exit_category="terminated"; nq_exit_code=5 ;;
    esac
    exit "$nq_exit_code"
}

function nq_handle_exit(){
    local original_code="$1"
    trap - EXIT INT TERM HUP
    if [[ "$nq_exit_category" == succeeded && $original_code -ne 0 ]]; then
        nq_exit_category="failed"; nq_exit_code=3
    fi
    if [[ -n "${result_directory:-}" && -d "${result_directory:-}" ]]; then
        nq_collect_report_urls
        nq_collect_module_summaries
    fi
    nq_cleanup || true
    nq_determine_final_status
    if [[ -z "$nq_remaining_mounts" && "$work_dir" == *nodequality* ]]; then
        if rm -rf -- "$work_dir" 2>/dev/null; then
            nq_workdir_removed=true
        else
            nq_cleanup_status="partial"
            nq_cleanup_error="工作目录删除失败"
            nq_determine_final_status
        fi
    fi
    nq_send_final || true
    webhook_token=""
    if [[ $nq_webhook_final_failed -eq 1 && "$nq_exit_category" == succeeded ]]; then
        exit 6
    fi
    exit "$nq_exit_code"
}


function ask_question(){
    local yellow='\033[1;33m'  # Set yellow color
    local reset='\033[0m'      # Reset to default color

    echo -en "${yellow}$(L ask_hq)${reset}"
    read run_hardware_quality_test
    run_hardware_quality_test=${run_hardware_quality_test:-y}

    echo -en "${yellow}$(L ask_iq)${reset}"
    read run_ip_quality_test
    run_ip_quality_test=${run_ip_quality_test:-y}

    echo -en "${yellow}$(L ask_nq)${reset}"
    read run_net_quality_test
    run_net_quality_test=${run_net_quality_test:-y}

    echo -en "${yellow}$(L ask_bt)${reset}"
    read run_net_trace_test
    run_net_trace_test=${run_net_trace_test:-y}
}

function nq_emit_recorded_phases(){
    local module="$1" phase_file="$2" code
    local -n seen_ref="$3"
    [[ -s "$phase_file" ]] || return 0
    while IFS= read -r code; do
        [[ -n "$code" && "${seen_ref[$code]:-0}" -eq 0 ]] || continue
        case "$module:$code" in
            network_quality:network_quality.bgp)
                nq_emit_event job.progress "$module" running "$code" "正在检测 BGP 数据库" 57 ;;
            network_quality:network_quality.tcp_settings)
                nq_emit_event job.progress "$module" running "$code" "正在检测 TCP 设置" 59 ;;
            network_quality:network_quality.tcp_latency.domestic)
                nq_emit_event job.progress "$module" running "$code" "正在检测国内三网 TCP 延迟" 63 ;;
            network_quality:network_quality.route_summary)
                nq_emit_event job.progress "$module" running "$code" "正在检测国内三网回程线路" 66 ;;
            network_quality:network_quality.speed.domestic)
                nq_emit_event job.progress "$module" running "$code" "正在检测国内三网速度" 69 ;;
            network_quality:network_quality.tcp_latency.international)
                nq_emit_event job.progress "$module" running "$code" "正在检测国际互连 TCP 延迟" 72 ;;
            backroute:backroute.trace)
                nq_emit_event job.progress "$module" running "$code" "正在检测 TCP 回程详细路由" 81 ;;
            *) continue ;;
        esac
        seen_ref[$code]=1
    done < "$phase_file"
}

function nq_run_module(){
    local module="$1" start_progress="$2" end_progress="$3" phase="$4" message="$5" logfile="$6" jsonfile="$7"
    shift 7
    local code error_code
    NQ_MODULE_STATUS[$module]=running
    nq_emit_event module.started "$module" running "$phase" "$message" "$start_progress"
    if [[ $webhook_enabled -eq 1 && ( "$module" == network_quality || "$module" == backroute ) ]]; then
        local pid snapshot phase_file="$result_directory/${module}.phases"
        local -A seen_phases=()
        : > "$phase_file"
        "$@" > >(tee "$result_directory/$logfile") 2>&1 &
        pid=$!
        while kill -0 "$pid" 2>/dev/null; do
            nq_emit_recorded_phases "$module" "$phase_file" seen_phases
            snapshot=$(LC_ALL=C tail -c 32768 "$result_directory/$logfile" 2>/dev/null | tr '\r' '\n')
            if [[ $module == network_quality ]]; then
                if [[ "${seen_phases[network_quality.bgp]:-0}" -eq 0 && "$snapshot" =~ (正在检测BGP数据库|Checking[[:space:]]BGP[[:space:]]database) ]]; then
                    printf '%s\n' network_quality.bgp >> "$phase_file"
                fi
                if [[ "${seen_phases[network_quality.tcp_settings]:-0}" -eq 0 && "$snapshot" =~ (正在检测TCP设置|Checking[[:space:]]TCP[[:space:]]Settings) ]]; then
                    printf '%s\n' network_quality.tcp_settings >> "$phase_file"
                fi
                if [[ "${seen_phases[network_quality.tcp_latency.domestic]:-0}" -eq 0 && "$snapshot" =~ (正在检测大陆三网TCP大包延迟|Checking[[:space:]]China[[:space:]]Mainland[[:space:]]TCP[[:space:]]Delay) ]]; then
                    printf '%s\n' network_quality.tcp_latency.domestic >> "$phase_file"
                fi
                if [[ "${seen_phases[network_quality.route_summary]:-0}" -eq 0 && "$snapshot" =~ (正在检测大陆三网回程线路|Checking[[:space:]]Route[[:space:]]to[[:space:]]China[[:space:]]Mainland) ]]; then
                    printf '%s\n' network_quality.route_summary >> "$phase_file"
                fi
                if [[ "${seen_phases[network_quality.speed.domestic]:-0}" -eq 0 && "$snapshot" =~ (正在检测三网Speedtest|Checking[[:space:]]Speedtest[[:space:]]of[[:space:]]China) ]]; then
                    printf '%s\n' network_quality.speed.domestic >> "$phase_file"
                fi
                if [[ "${seen_phases[network_quality.tcp_latency.international]:-0}" -eq 0 && "$snapshot" =~ (正在检测国际互连TCP大包延迟|Checking[[:space:]]Global[[:space:]]TCP[[:space:]]Delay) ]]; then
                    printf '%s\n' network_quality.tcp_latency.international >> "$phase_file"
                fi
            elif [[ "${seen_phases[backroute.trace]:-0}" -eq 0 && "$snapshot" =~ (正在检测TCP回程详细路由|Checking[[:space:]]Route[[:space:]]details) ]]; then
                printf '%s\n' backroute.trace >> "$phase_file"
            fi
            nq_emit_recorded_phases "$module" "$phase_file" seen_phases
            sleep 1
        done
        wait "$pid"; code=$?
        nq_emit_recorded_phases "$module" "$phase_file" seen_phases
    else
        "$@" 2>&1 | tee "$result_directory/$logfile"
        code=${PIPESTATUS[0]}
    fi
    NQ_MODULE_EXIT[$module]=$code
    if [[ $code -eq 0 && -s "$result_directory/$jsonfile" ]] && chroot_run "jq -e . /result/$jsonfile >/dev/null 2>&1"; then
        NQ_MODULE_STATUS[$module]=succeeded
        nq_emit_event module.completed "$module" succeeded "${module}.completed" "检测模块执行完成" "$end_progress"
        return 0
    fi
    NQ_MODULE_STATUS[$module]=failed
    if [[ $code -ne 0 ]]; then
        NQ_MODULE_ERROR[$module]="检测模块退出码为 $code"
    elif [[ ! -s "$result_directory/$jsonfile" ]]; then
        NQ_MODULE_ERROR[$module]="检测模块未生成结构化结果文件"
    else
        NQ_MODULE_ERROR[$module]="检测模块生成的 JSON 无效"
    fi
    error_code="NQ_${module^^}_EXEC_FAILED"
    nq_emit_event module.failed "$module" failed "${module}.failed" "检测模块执行失败" "$end_progress" "$error_code" "${NQ_MODULE_ERROR[$module]}"
    return 1
}

function main(){
    trap 'nq_handle_signal INT' INT
    trap 'nq_handle_signal TERM' TERM
    trap 'nq_handle_signal HUP' HUP
    trap 'nq_handle_exit $?' EXIT

    nq_started_at=$(nq_now)
    nq_exit_category="starting"
    nq_emit_event job.started core running core.started "NodeQuality 已启动" 0

    start_ascii
    normalize_modes || { echo "错误：非交互检测选项无效。" >&2; return 64; }

    _green_bold "$(L cleanup_before)"
    nq_exit_category="preparing"
    nq_emit_event module.started environment running environment.pre_cleanup "正在执行环境预清理" 5
    pre_init || return 3
    pre_cleanup || return 3
    _green_bold "$(L loadbench)"
    nq_emit_event job.progress environment running environment.benchos_download "正在下载并准备 BenchOS" 10
    load_bench_os || {
        nq_emit_event module.failed environment failed environment.benchos_download "BenchOS 准备失败" 20 NQ_ENV_BENCHOS_DOWNLOAD_FAILED "无法下载、解压或挂载 BenchOS"
        return 3
    }
    printf '%s' "$webhook_context_json" > "$work_dir/BenchOs/tmp/nq-context.json"
    if ! chroot_run "jq -e 'type == \"object\"' /tmp/nq-context.json >/dev/null 2>&1"; then
        webhook_context_json='{}'
    else
        webhook_context_json=$(chroot_run "jq -c . /tmp/nq-context.json")
    fi
    rm -f "$work_dir/BenchOs/tmp/nq-context.json"
    nq_emit_event module.completed environment succeeded environment.ready "BenchOS 环境准备完成" 20

    load_part
    load_3rd_program

    _green_bold "$(L basicinfo)"

    result_directory="$work_dir/BenchOs/result"
    mkdir -p "$result_directory"
    run_header > "$result_directory/$header_info_filename"
    nq_exit_category="running"

    if [[ "$run_hardware_quality_test" =~ ^[YyFfVv]$ ]]; then
        _green_bold "$(L run_hq)"
        nq_run_module hardware 20 40 hardware.collecting_system_info "正在检测硬件信息与性能" "$hardware_quality_filename" "$hardware_quality_json_filename" run_HardwareQuality || true
    else
        nq_emit_event module.skipped hardware skipped hardware.skipped "已跳过硬件质量检测" 40
    fi

    if [[ "$run_ip_quality_test" =~ ^[Yy]$ ]]; then
        _green_bold "$(L run_iq)"
        nq_run_module ip_quality 40 55 ip_quality.reputation "正在检测 IP 质量与风险数据库" "$ip_quality_filename" "$ip_quality_json_filename" run_ip_quality || true
    else
        nq_emit_event module.skipped ip_quality skipped ip_quality.skipped "已跳过 IP 质量检测" 55
    fi

    if [[ "$run_net_quality_test" =~ ^[YyLl]$ ]]; then
        _green_bold "$(L run_nq)"
        nq_run_module network_quality 55 75 network_quality.running "正在检测网络质量、TCP 延迟与吞吐" "$net_quality_filename" "$net_quality_json_filename" run_net_quality || true
    else
        nq_emit_event module.skipped network_quality skipped network_quality.skipped "已跳过网络质量检测" 75
    fi

    if [[ "$run_net_trace_test" =~ ^[Yy]$ ]]; then
        _green_bold "$(L run_bt)"
        nq_run_module backroute 75 88 backroute.trace "正在检测三网回程路由" "$backroute_trace_filename" "$backroute_trace_json_filename" run_net_trace || true
    else
        nq_emit_event module.skipped backroute skipped backroute.skipped "已跳过回程路由检测" 88
    fi

    nq_collect_report_urls
    nq_collect_module_summaries
    nq_exit_category="uploading"
    nq_emit_event module.started report_upload running report_upload.archive "正在生成并上传 NodeQuality 汇总报告" 88
    if upload_result; then
        nq_emit_event module.completed report_upload succeeded report_upload.completed "NodeQuality 汇总报告上传完成" 94
    else
        nq_emit_event module.failed report_upload failed report_upload.failed "NodeQuality 汇总报告上传失败" 94 NQ_UPLOAD_REQUEST_FAILED "$nq_official_upload_error"
    fi
    _green_bold "$(L cleanup_after)"
    nq_exit_category="cleaning"
    nq_cleanup || true
    nq_determine_final_status
    return "$nq_exit_code"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    get_opts "$@" || exit $?
    nq_validate_webhook_config || {
        echo "错误：Webhook 配置不完整或无效。" >&2
        exit 64
    }
    main
fi
