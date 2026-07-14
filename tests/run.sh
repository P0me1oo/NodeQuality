#!/usr/bin/env bash
set -u

root_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
failures=0

run_test(){
    local name="$1"
    shift
    if "$@"; then
        printf 'ok - %s\n' "$name"
    else
        printf 'not ok - %s\n' "$name" >&2
        failures=$((failures + 1))
    fi
}

test_syntax(){ bash -n "$root_dir/NodeQuality.sh"; }

test_release_line_endings(){
    ! LC_ALL=C grep -q $'\r' "$root_dir/NodeQuality.sh"
}

test_noninteractive_term_default(){
    [[ $(env -u TERM bash -c 'source "$1"; printf "%s" "$TERM"' _ "$root_dir/NodeQuality.sh") == xterm ]]
}

test_module_timeout_wrapper(){
    source "$root_dir/NodeQuality.sh"
    captured=""
    timeout(){ captured="$*"; return 124; }
    chroot_run_timeout 1800 "true"
    [[ $? -eq 124 && "$captured" == *'--signal=TERM --kill-after=30s 1800s'* ]]
}

test_version(){
    local output
    output=$(bash "$root_dir/NodeQuality.sh" --version)
    [[ "$output" == *"NodeQuality 1.0.0"* && "$output" == *"nq-webhook/1.0"* ]]
}

test_plain_token_rejected(){
    bash "$root_dir/NodeQuality.sh" --webhook-token secret >/dev/null 2>&1
    [[ $? -eq 64 ]]
}

test_backward_compatible_defaults(){
    source "$root_dir/NodeQuality.sh"
    webhook_url=""; webhook_job_id=""; webhook_token=""; webhook_token_fd=""
    nq_validate_webhook_config
    [[ $webhook_enabled -eq 0 ]]
}

test_webhook_config(){
    source "$root_dir/NodeQuality.sh"
    webhook_url="https://example.com/event"
    webhook_job_id="job-123"
    webhook_token="12345678901234567890123456789012"
    webhook_version="1.0"
    nq_validate_webhook_config
    [[ $webhook_enabled -eq 1 ]]
}

test_event_sequence_and_retry_id(){
    source "$root_dir/NodeQuality.sh"
    webhook_enabled=1
    webhook_url="https://example.com/event"
    webhook_job_id="job-123"
    webhook_token="12345678901234567890123456789012"
    nq_sequence=0
    nq_progress=0
    payloads=()
    nq_send_payload(){ payloads+=("$1"); return 0; }
    nq_emit_event module.started hardware running hardware.cpu "正在检测 CPU" 20
    nq_emit_event module.completed hardware succeeded hardware.completed "硬件检测完成" 40
    [[ $nq_sequence -eq 2 ]] || return 1
    [[ "${payloads[0]}" == *'"sequence":1'* ]] || return 1
    [[ "${payloads[1]}" == *'"sequence":2'* ]] || return 1
    [[ "${payloads[1]}" == *'"current":40'* ]]
}

test_progress_never_moves_back(){
    source "$root_dir/NodeQuality.sh"
    webhook_enabled=1; webhook_job_id="job-123"; nq_progress=60; nq_sequence=0
    captured=""
    nq_send_payload(){ captured="$1"; return 0; }
    nq_emit_event job.progress network_quality running network_quality.running "检测中" 40
    [[ "$captured" == *'"current":60'* ]]
}

test_request_body_limit(){
    source "$root_dir/NodeQuality.sh"
    webhook_enabled=1; webhook_url="https://example.com/event"; webhook_token="12345678901234567890123456789012"
    local large
    large=$(printf '%9000s' '')
    ! nq_send_payload "$large" 0
}

test_report_url_allowlist(){
    source "$root_dir/NodeQuality.sh"
    nq_validate_report_url 'https://report.check.place/hardware/example.svg' || return 1
    ! nq_validate_report_url 'https://ads.example.com/example.svg'
}

test_cleanup_blocks_delete_with_mounts(){
    source "$root_dir/NodeQuality.sh"
    work_dir="/tmp/nodequality-test"
    webhook_enabled=0; nq_cleanup_started=0; nq_cleanup_finished=0
    clear_mount(){ return 0; }
    nq_mounts_under_workdir(){ printf '%s\n' '/tmp/nodequality-test/BenchOs/dev'; }
    umount(){ return 1; }
    ! nq_cleanup
    [[ "$nq_cleanup_status" == failed ]]
}

test_final_payload_is_bounded_json(){
    source "$root_dir/NodeQuality.sh"
    webhook_job_id="job-123"; webhook_context_json='{"source":"test"}'
    nq_exit_category="partial"; nq_exit_code=2; nq_sequence=10
    nq_official_upload_status="failed"; nq_official_upload_error="上传失败"
    nq_cleanup_status="succeeded"
    for module in hardware ip_quality network_quality backroute; do
        NQ_MODULE_SUMMARY[$module]='{}'
    done
    NQ_MODULE_ENABLED[hardware]=true; NQ_MODULE_STATUS[hardware]=succeeded
    nq_build_final_payload
    [[ $(LC_ALL=C printf '%s' "$nq_final_payload" | wc -c) -le 65536 ]] || return 1
    FINAL_PAYLOAD="$nq_final_payload" node -e 'JSON.parse(process.env.FINAL_PAYLOAD)'
}

test_token_not_in_payload(){
    source "$root_dir/NodeQuality.sh"
    webhook_enabled=1; webhook_job_id="job-123"; webhook_token="private-token-12345678901234567890"
    captured=""
    nq_send_payload(){ captured="$1"; return 0; }
    nq_emit_event job.progress core running core.running "检测中" 10
    [[ "$captured" != *"$webhook_token"* ]]
}

test_network_tcp_phase_event(){
    source "$root_dir/NodeQuality.sh"
    result_directory=$(mktemp -d)
    webhook_enabled=1; webhook_job_id="job-123"; nq_sequence=0; nq_progress=0
    captured=""
    nq_send_payload(){ captured+="$1"; return 0; }
    chroot_run(){ return 0; }
    fake_network(){
        printf '%s\n' 'network_quality.tcp_latency.domestic' \
            >> "$result_directory/network_quality.phases"
        printf '{}' > "$result_directory/net.json"
        sleep 2
    }
    nq_run_module network_quality 55 75 network_quality.running "网络检测" net.log net.json fake_network
    rm -rf "$result_directory"
    [[ "$captured" == *'network_quality.tcp_latency.domestic'* ]]
}

test_terminal_text_phase_fallback(){
    source "$root_dir/NodeQuality.sh"
    result_directory=$(mktemp -d)
    webhook_enabled=1; webhook_job_id="job-123"; nq_sequence=0; nq_progress=0
    captured=""
    nq_send_payload(){ captured+="$1"; return 0; }
    chroot_run(){ return 0; }
    fake_network(){
        printf '%s\r' '正在检测大陆三网TCP大包延迟'
        printf '{}' > "$result_directory/net.json"
        sleep 2
    }
    nq_run_module network_quality 55 75 network_quality.running "网络检测" net.log net.json fake_network
    rm -rf "$result_directory"
    [[ "$captured" == *'network_quality.tcp_latency.domestic'* ]]
}

test_phase_hook_uses_function_boundaries(){
    source "$root_dir/NodeQuality.sh"
    local temp_dir hook_file phase_file
    temp_dir=$(mktemp -d)
    hook_file="$temp_dir/hook.sh"
    phase_file="$temp_dir/phases"
    nq_write_phase_hook > "$hook_file"
    NQ_PHASE_MODULE=network_quality NQ_PHASE_FILE="$phase_file" BASH_ENV="$hook_file" \
        bash -c '
            db_bgptools(){ :; }
            get_tcp(){ :; }
            get_delay(){ :; }
            get_route(){ :; }
            speedtest_test(){ :; }
            iperf_test(){ :; }
            check_Net(){
                db_bgptools 4
                get_tcp
                get_delay 4
                get_route 4
                speedtest_test
                iperf_test 4
            }
            check_Net
        '
    local expected
    expected=$'network_quality.bgp\nnetwork_quality.tcp_settings\nnetwork_quality.tcp_latency.domestic\nnetwork_quality.route_summary\nnetwork_quality.speed.domestic\nnetwork_quality.tcp_latency.international'
    [[ $(cat "$phase_file") == "$expected" ]]
    rm -rf "$temp_dir"
}

run_test 'Bash 语法' test_syntax
run_test '发布脚本使用 LF 换行' test_release_line_endings
run_test '非交互环境提供 TERM 默认值' test_noninteractive_term_default
run_test '第三方模块使用有限执行超时' test_module_timeout_wrapper
run_test '版本与协议版本' test_version
run_test '拒绝命令行明文 Token' test_plain_token_rejected
run_test '未启用 Webhook 向后兼容' test_backward_compatible_defaults
run_test '完整 Webhook 配置' test_webhook_config
run_test '事件 sequence 递增' test_event_sequence_and_retry_id
run_test '乱序进度不倒退' test_progress_never_moves_back
run_test '普通请求体上限' test_request_body_limit
run_test '报告 URL 域名白名单' test_report_url_allowlist
run_test '残留挂载阻止递归删除' test_cleanup_blocks_delete_with_mounts
run_test '最终结果是有界合法 JSON' test_final_payload_is_bounded_json
run_test 'Token 不进入事件请求体' test_token_not_in_payload
run_test 'TCP 延迟结构化 phase sidecar' test_network_tcp_phase_event
run_test 'TCP 延迟阶段文案有限回退' test_terminal_text_phase_fallback
run_test '第三方函数边界生成稳定 phase' test_phase_hook_uses_function_boundaries

exit "$failures"
