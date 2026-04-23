#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_OUTPUT_DIR="$(cd "${SCRIPT_DIR}/../../outputs/server_monitor" 2>/dev/null && pwd 2>/dev/null || true)"
if [ -z "${DEFAULT_OUTPUT_DIR}" ]; then
  DEFAULT_OUTPUT_DIR="${SCRIPT_DIR}/data"
fi

OUTPUT_DIR="${OUTPUT_DIR:-${DEFAULT_OUTPUT_DIR}}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-60}"
RETENTION_SECONDS=$((48 * 60 * 60))
PROCESS_PATTERN="${PROCESS_PATTERN:-ww/datasource}"

HTML_TEMPLATE="${SCRIPT_DIR}/monitor_report.html"
REPORT_HTML="${OUTPUT_DIR}/monitor_report.html"
DATA_JS_FILE="${OUTPUT_DIR}/monitor_data.js"
RECORDS_FILE="${OUTPUT_DIR}/records.tsv"
EVENTS_FILE="${OUTPUT_DIR}/events.tsv"
STATE_FILE="${OUTPUT_DIR}/monitor.state"
PID_FILE="${OUTPUT_DIR}/monitor.pid"
LOG_FILE="${OUTPUT_DIR}/monitor.log"

usage() {
  cat <<'EOF'
Usage:
  ./server_monitor.sh start
  ./server_monitor.sh stop
  ./server_monitor.sh status
  ./server_monitor.sh run
  ./server_monitor.sh run-once
  ./server_monitor.sh render

Environment variables:
  OUTPUT_DIR         输出目录
  INTERVAL_SECONDS   采集间隔，默认 60
  PROCESS_PATTERN    进程匹配关键字，默认 ww/datasource
EOF
}

ensure_output_dir() {
  mkdir -p "${OUTPUT_DIR}"
}

init_data_files() {
  if [ ! -f "${RECORDS_FILE}" ]; then
    printf 'epoch\ttime\tcpu_used_pct\tmem_used_pct\tmem_used_mb\tmem_total_mb\tdisk_used_pct\tdisk_used_gb\tdisk_total_gb\tproc_found\tproc_pids\tproc_restarted\tproc_event\n' > "${RECORDS_FILE}"
  fi

  if [ ! -f "${EVENTS_FILE}" ]; then
    printf 'epoch\ttime\tevent_type\tdetail\n' > "${EVENTS_FILE}"
  fi

  if [ ! -f "${DATA_JS_FILE}" ]; then
    cat > "${DATA_JS_FILE}" <<EOF
window.MONITOR_META = {
  generatedAt: "",
  intervalSeconds: ${INTERVAL_SECONDS},
  retentionHours: 48,
  processPattern: "${PROCESS_PATTERN}"
};
window.MONITOR_RECORDS = [];
window.MONITOR_EVENTS = [];
EOF
  fi
}

deploy_html() {
  if [ -f "${HTML_TEMPLATE}" ]; then
    cp "${HTML_TEMPLATE}" "${REPORT_HTML}"
  fi
}

is_running() {
  [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null
}

load_state() {
  PREV_SIGNATURE=""
  STATE_INITIALIZED=0
  SEEN_NONEMPTY=0
  PREV_CPU_TOTAL=""
  PREV_CPU_IDLE=""

  if [ -f "${STATE_FILE}" ]; then
    # shellcheck disable=SC1090
    . "${STATE_FILE}"
    STATE_INITIALIZED=1
  fi
}

write_state() {
  cat > "${STATE_FILE}" <<EOF
PREV_SIGNATURE='${CURRENT_SIGNATURE}'
SEEN_NONEMPTY=${CURRENT_SEEN_NONEMPTY}
PREV_CPU_TOTAL=${CURRENT_CPU_TOTAL}
PREV_CPU_IDLE=${CURRENT_CPU_IDLE}
EOF
}

get_cpu_counters() {
  local user nice system idle iowait irq softirq steal
  read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
  CURRENT_CPU_IDLE=$((idle + iowait))
  CURRENT_CPU_TOTAL=$((user + nice + system + idle + iowait + irq + softirq + steal))
}

compute_cpu_usage() {
  get_cpu_counters

  if [ -n "${PREV_CPU_TOTAL}" ] && [ "${CURRENT_CPU_TOTAL}" -gt "${PREV_CPU_TOTAL}" ]; then
    local total_diff idle_diff
    total_diff=$((CURRENT_CPU_TOTAL - PREV_CPU_TOTAL))
    idle_diff=$((CURRENT_CPU_IDLE - PREV_CPU_IDLE))
    CPU_USED_PCT="$(awk -v total="${total_diff}" -v idle="${idle_diff}" 'BEGIN { if (total <= 0) { printf "0.00" } else { printf "%.2f", ((total - idle) * 100) / total } }')"
  else
    CPU_USED_PCT="0.00"
  fi
}

compute_memory_usage() {
  local mem_total_kb mem_available_kb mem_used_kb
  mem_total_kb="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
  mem_available_kb="$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)"
  mem_used_kb=$((mem_total_kb - mem_available_kb))

  MEM_USED_PCT="$(awk -v used="${mem_used_kb}" -v total="${mem_total_kb}" 'BEGIN { if (total <= 0) { printf "0.00" } else { printf "%.2f", (used * 100) / total } }')"
  MEM_USED_MB="$(awk -v used="${mem_used_kb}" 'BEGIN { printf "%.2f", used / 1024 }')"
  MEM_TOTAL_MB="$(awk -v total="${mem_total_kb}" 'BEGIN { printf "%.2f", total / 1024 }')"
}

compute_disk_usage() {
  local disk_total_bytes disk_used_bytes
  read -r disk_total_bytes disk_used_bytes < <(
    df -PT -B1 -l 2>/dev/null | awk '
      NR > 1 && $2 !~ /^(tmpfs|devtmpfs|overlay|squashfs|nsfs|ramfs)$/ {
        total += $3
        used += $4
      }
      END {
        print total + 0, used + 0
      }
    '
  )

  DISK_USED_PCT="$(awk -v used="${disk_used_bytes}" -v total="${disk_total_bytes}" 'BEGIN { if (total <= 0) { printf "0.00" } else { printf "%.2f", (used * 100) / total } }')"
  DISK_USED_GB="$(awk -v used="${disk_used_bytes}" 'BEGIN { printf "%.2f", used / 1024 / 1024 / 1024 }')"
  DISK_TOTAL_GB="$(awk -v total="${disk_total_bytes}" 'BEGIN { printf "%.2f", total / 1024 / 1024 / 1024 }')"
}

get_process_snapshot() {
  local pid pid_list=() signature_list=()
  CURRENT_FOUND=0
  CURRENT_PIDS=""
  CURRENT_SIGNATURE=""

  if ! command -v pgrep >/dev/null 2>&1; then
    return
  fi

  while IFS= read -r pid; do
    [ -z "${pid}" ] && continue
    local start_time
    start_time="$(ps -p "${pid}" -o lstart= 2>/dev/null | awk '{$1=$1; print}')"
    [ -z "${start_time}" ] && continue
    pid_list+=("${pid}")
    signature_list+=("${pid}@${start_time// /_}")
  done < <(pgrep -f "${PROCESS_PATTERN}" | sort -n || true)

  if [ "${#pid_list[@]}" -gt 0 ]; then
    CURRENT_FOUND=1
    CURRENT_PIDS="$(IFS=,; echo "${pid_list[*]}")"
    CURRENT_SIGNATURE="$(IFS=';'; echo "${signature_list[*]}")"
  fi
}

append_event() {
  local epoch="$1"
  local time_text="$2"
  local event_type="$3"
  local detail="$4"
  printf '%s\t%s\t%s\t%s\n' "${epoch}" "${time_text}" "${event_type}" "${detail}" >> "${EVENTS_FILE}"
}

evaluate_process_event() {
  PROC_RESTARTED=0
  PROC_EVENT="none"
  CURRENT_SEEN_NONEMPTY="${SEEN_NONEMPTY}"

  if [ "${STATE_INITIALIZED}" -eq 0 ]; then
    if [ "${CURRENT_FOUND}" -eq 1 ]; then
      CURRENT_SEEN_NONEMPTY=1
    fi
    return
  fi

  if [ -z "${PREV_SIGNATURE}" ] && [ -n "${CURRENT_SIGNATURE}" ]; then
    if [ "${SEEN_NONEMPTY}" -eq 1 ]; then
      PROC_EVENT="restarted"
      PROC_RESTARTED=1
    else
      PROC_EVENT="started"
    fi
    CURRENT_SEEN_NONEMPTY=1
    return
  fi

  if [ -n "${PREV_SIGNATURE}" ] && [ -z "${CURRENT_SIGNATURE}" ]; then
    PROC_EVENT="stopped"
    return
  fi

  if [ -n "${PREV_SIGNATURE}" ] && [ -n "${CURRENT_SIGNATURE}" ] && [ "${PREV_SIGNATURE}" != "${CURRENT_SIGNATURE}" ]; then
    PROC_EVENT="restarted"
    PROC_RESTARTED=1
    CURRENT_SEEN_NONEMPTY=1
    return
  fi

  if [ "${CURRENT_FOUND}" -eq 1 ]; then
    CURRENT_SEEN_NONEMPTY=1
  fi
}

prune_history() {
  local cutoff temp_records temp_events
  cutoff="$1"
  temp_records="${RECORDS_FILE}.tmp"
  temp_events="${EVENTS_FILE}.tmp"

  awk -F'\t' -v cutoff="${cutoff}" 'NR == 1 || $1 >= cutoff' "${RECORDS_FILE}" > "${temp_records}" && mv "${temp_records}" "${RECORDS_FILE}"
  awk -F'\t' -v cutoff="${cutoff}" 'NR == 1 || $1 >= cutoff' "${EVENTS_FILE}" > "${temp_events}" && mv "${temp_events}" "${EVENTS_FILE}"
}

render_data_js() {
  local generated_at tmp_file
  generated_at="$(date '+%Y-%m-%d %H:%M:%S %z')"
  tmp_file="${DATA_JS_FILE}.tmp"

  {
    printf 'window.MONITOR_META = {\n'
    printf '  generatedAt: "%s",\n' "${generated_at}"
    printf '  intervalSeconds: %s,\n' "${INTERVAL_SECONDS}"
    printf '  retentionHours: 48,\n'
    printf '  processPattern: "%s"\n' "${PROCESS_PATTERN}"
    printf '};\n'

    printf 'window.MONITOR_RECORDS = [\n'
    awk -F'\t' '
      NR == 1 { next }
      {
        printf "  {epoch:%s,time:\"%s\",cpuUsedPct:%s,memUsedPct:%s,memUsedMb:%s,memTotalMb:%s,diskUsedPct:%s,diskUsedGb:%s,diskTotalGb:%s,procFound:%s,procPids:\"%s\",procRestarted:%s,procEvent:\"%s\"},\n",
          $1, $2, $3, $4, $5, $6, $7, $8, $9,
          ($10 == 1 ? "true" : "false"),
          $11,
          ($12 == 1 ? "true" : "false"),
          $13
      }
    ' "${RECORDS_FILE}"
    printf '];\n'

    printf 'window.MONITOR_EVENTS = [\n'
    awk -F'\t' '
      NR == 1 { next }
      {
        printf "  {epoch:%s,time:\"%s\",eventType:\"%s\",detail:\"%s\"},\n", $1, $2, $3, $4
      }
    ' "${EVENTS_FILE}"
    printf '];\n'
  } > "${tmp_file}"

  mv "${tmp_file}" "${DATA_JS_FILE}"
}

collect_once() {
  local now_epoch now_text detail cutoff

  now_epoch="$(date +%s)"
  now_text="$(date '+%Y-%m-%d %H:%M:%S')"

  load_state
  compute_cpu_usage
  compute_memory_usage
  compute_disk_usage
  get_process_snapshot
  evaluate_process_event

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${now_epoch}" "${now_text}" "${CPU_USED_PCT}" "${MEM_USED_PCT}" "${MEM_USED_MB}" "${MEM_TOTAL_MB}" \
    "${DISK_USED_PCT}" "${DISK_USED_GB}" "${DISK_TOTAL_GB}" "${CURRENT_FOUND}" "${CURRENT_PIDS}" "${PROC_RESTARTED}" "${PROC_EVENT}" >> "${RECORDS_FILE}"

  if [ "${PROC_EVENT}" != "none" ]; then
    detail="prev=${PREV_SIGNATURE:-none};curr=${CURRENT_SIGNATURE:-none}"
    append_event "${now_epoch}" "${now_text}" "${PROC_EVENT}" "${detail}"
  fi

  cutoff=$((now_epoch - RETENTION_SECONDS))
  prune_history "${cutoff}"
  deploy_html
  render_data_js
  write_state
}

start_monitor() {
  ensure_output_dir
  init_data_files
  deploy_html

  if is_running; then
    echo "monitor is already running, pid=$(cat "${PID_FILE}")"
    exit 0
  fi

  nohup bash "$0" run >> "${LOG_FILE}" 2>&1 &
  echo $! > "${PID_FILE}"
  echo "monitor started, pid=$!"
  echo "report: ${REPORT_HTML}"
}

run_monitor() {
  ensure_output_dir
  init_data_files
  deploy_html
  echo $$ > "${PID_FILE}"
  trap 'rm -f "${PID_FILE}"' EXIT

  while true; do
    collect_once
    sleep "${INTERVAL_SECONDS}"
  done
}

stop_monitor() {
  if ! is_running; then
    echo "monitor is not running"
    rm -f "${PID_FILE}"
    exit 0
  fi

  kill "$(cat "${PID_FILE}")"
  rm -f "${PID_FILE}"
  echo "monitor stopped"
}

status_monitor() {
  ensure_output_dir
  init_data_files

  if is_running; then
    echo "running, pid=$(cat "${PID_FILE}")"
  else
    echo "stopped"
  fi

  if [ -f "${RECORDS_FILE}" ]; then
    echo "latest sample:"
    tail -n 1 "${RECORDS_FILE}"
  fi

  echo "report: ${REPORT_HTML}"
}

main() {
  local command="${1:-}"

  case "${command}" in
    start) start_monitor ;;
    stop) stop_monitor ;;
    status) status_monitor ;;
    run) run_monitor ;;
    run-once)
      ensure_output_dir
      init_data_files
      collect_once
      echo "sample collected"
      ;;
    render)
      ensure_output_dir
      init_data_files
      deploy_html
      render_data_js
      echo "html data rebuilt"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
