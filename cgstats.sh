#!/bin/sh
# cgstats.sh — live CPU/MEM/DISK via cgroups (POSIX sh)
# Usage:
#   ./cgstats.sh [-i SECONDS] [-p PATHS]
#       [--no-cpu] [--no-mem] [--no-disk]
#       [--cpu-limit CORES] [--mem-limit MIB]
#       [--cpu-warn PCT] [--cpu-crit PCT]
#       [--mem-warn PCT] [--mem-crit PCT]
#       [--disk-warn PCT] [--disk-crit PCT]
#       [--output table|json]
#
# Notes:
#   -p accepts a comma-separated list and/or may be repeated; all paths are merged.
#
# Examples:
#   ./cgstats.sh
#   ./cgstats.sh -i 2 -p "/home/jovyan,/data"
#   ./cgstats.sh -i 2 -p /home/jovyan -p /data
#   ./cgstats.sh --no-disk --output json
#   ./cgstats.sh --cpu-limit 2 --mem-limit 4096 --cpu-warn 60 --cpu-crit 85
#   ./cgstats.sh --output json -i 5

# Defaults
INTERVAL=1
MON_PATHS=""
SHOW_CPU=1
SHOW_MEM=1
SHOW_DISK=1
OVR_CPU_LIM=""
OVR_MEM_LIM_MIB=""
CPU_WARN=50
CPU_CRIT=80
MEM_WARN=70
MEM_CRIT=90
DISK_WARN=80
DISK_CRIT=90
OUTPUT_FORMAT=""   # json
ONCE=0

# ----- arg validation helpers -----
die() { printf 'cgstats: %s\n' "$*" >&2; exit 1; }
# non-negative integer
is_uint() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }
# non-negative number, optionally one decimal point (e.g. 0.5, 2)
is_num() {
  case "${1:-}" in
    '' | . | *[!0-9.]* | *.*.*) return 1 ;;
    *) return 0 ;;
  esac
}
# percentage in 0..100
is_pct() { is_uint "$1" && [ "$1" -le 100 ]; }

# ----- parse args (pure /bin/sh) -----
while [ $# -gt 0 ]; do
  case "$1" in
    -i) [ $# -ge 2 ] || die "-i requires a value"
        is_num "$2" || die "-i must be a number (seconds): $2"
        INTERVAL="$2"; shift 2 ;;
    -p) [ $# -ge 2 ] || die "-p requires a value"
        MON_PATHS="${MON_PATHS:+$MON_PATHS,}$2"; shift 2 ;;
    --once)    ONCE=1; shift ;;
    --no-cpu)  SHOW_CPU=0; shift ;;
    --no-mem)  SHOW_MEM=0; shift ;;
    --no-disk) SHOW_DISK=0; shift ;;
    --cpu-limit) [ $# -ge 2 ] || die "--cpu-limit requires a value"
        is_num "$2" || die "--cpu-limit must be a number (cores): $2"
        OVR_CPU_LIM="$2"; shift 2 ;;
    --mem-limit) [ $# -ge 2 ] || die "--mem-limit requires a value"
        is_uint "$2" || die "--mem-limit must be an integer (MiB): $2"
        OVR_MEM_LIM_MIB="$2"; shift 2 ;;
    --cpu-warn) [ $# -ge 2 ] || die "--cpu-warn requires a value"
        is_pct "$2" || die "--cpu-warn must be 0-100: $2"
        CPU_WARN="$2"; shift 2 ;;
    --cpu-crit) [ $# -ge 2 ] || die "--cpu-crit requires a value"
        is_pct "$2" || die "--cpu-crit must be 0-100: $2"
        CPU_CRIT="$2"; shift 2 ;;
    --mem-warn) [ $# -ge 2 ] || die "--mem-warn requires a value"
        is_pct "$2" || die "--mem-warn must be 0-100: $2"
        MEM_WARN="$2"; shift 2 ;;
    --mem-crit) [ $# -ge 2 ] || die "--mem-crit requires a value"
        is_pct "$2" || die "--mem-crit must be 0-100: $2"
        MEM_CRIT="$2"; shift 2 ;;
    --disk-warn) [ $# -ge 2 ] || die "--disk-warn requires a value"
        is_pct "$2" || die "--disk-warn must be 0-100: $2"
        DISK_WARN="$2"; shift 2 ;;
    --disk-crit) [ $# -ge 2 ] || die "--disk-crit requires a value"
        is_pct "$2" || die "--disk-crit must be 0-100: $2"
        DISK_CRIT="$2"; shift 2 ;;
    --output) [ $# -ge 2 ] || die "--output requires a value"
        case "$2" in table | json) ;; *) die "--output must be table or json: $2" ;; esac
        OUTPUT_FORMAT="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: $0 [-i SECONDS] [-p PATHS]
          [--no-cpu] [--no-mem] [--no-disk]
          [--cpu-limit CORES] [--mem-limit MIB]
          [--cpu-warn PCT] [--cpu-crit PCT]
          [--mem-warn PCT] [--mem-crit PCT]
          [--disk-warn PCT] [--disk-crit PCT]
          [--output table|json]

  -p accepts a comma-separated list and/or may be repeated; all paths are merged.
EOF
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# Colors (for table mode)
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

cg=/sys/fs/cgroup
is_v2=0
[ -f "$cg/cgroup.controllers" ] && is_v2=1

rd(){ [ -r "$1" ] && cat "$1" 2>/dev/null || printf "%s" "${2:-}"; }
h_mib(){ awk -v b="$1" 'BEGIN{printf("%d", b/1024/1024)}'; }

# --- percent color with guards (table) ---
pct_color() {
  # $1=VALUE_OR_DASH, $2=WARN, $3=CRIT
  v="$1"; w="$2"; c="$3"
  case "$v" in
    --) printf "%s" "$GREEN"; return ;;
    *[!0-9]*) printf "%s" "$GREEN"; return ;;
  esac
  if [ "$v" -ge "$c" ] 2>/dev/null; then
    printf "%s" "$RED"
  elif [ "$v" -ge "$w" ] 2>/dev/null; then
    printf "%s" "$YELLOW"
  else
    printf "%s" "$GREEN"
  fi
}

# Disk: robust parsing & fallback pct calc
disk_calc() {
  # in: $1 path
  P="$1"
  # df -P -k is POSIX (1K blocks); -B is a GNU extension that BusyBox/Alpine
  # lack. Convert KiB -> bytes here so downstream math/h_mib stays in bytes.
  line=$(df -P -k "$P" 2>/dev/null | awk 'NR==2 {print $2*1024, $3*1024, $5}')
  TOTAL=$(printf "%s\n" "$line" | awk '{print $1}')
  USED=$(printf "%s\n" "$line" | awk '{print $2}')
  RAWPCT=$(printf "%s\n" "$line" | awk '{print $3}')
  if [ -z "$TOTAL" ] || [ -z "$USED" ]; then
    DISK_AVAIL="0"; DISK_TOTAL="0"; DISK_USEPCT=""
    return
  fi
  USEP=$(printf "%s" "$RAWPCT" | tr -d '%')
  if [ -z "$USEP" ] || echo "$USEP" | grep -q '[^0-9]'; then
    USEP=$(awk -v u="$USED" -v t="$TOTAL" 'BEGIN{if(t>0){printf("%d", (u*100)/t)} else {print 0}}')
    RAWPCT="${USEP}%"
  fi
  DISK_AVAIL="$USED"
  DISK_TOTAL="$TOTAL"
  DISK_USEPCT="$USEP"
}

# Iterate MON_PATHS (comma-separated, possibly repeated -p) and call $1 with
# each non-empty path. Single source of truth for path splitting.
for_each_path() {
  _cb="$1"
  IFS=','; for p in $MON_PATHS; do
    [ -n "$p" ] || continue
    "$_cb" "$p"
  done; unset IFS
}

# memory (bytes)
mem_read(){
  if [ "$is_v2" -eq 1 ]; then
    MU=$(rd "$cg/memory.current" 0)
    ML=$(rd "$cg/memory.max" max)
  else
    MU=$(rd "$cg/memory/memory.usage_in_bytes" 0)
    ML=$(rd "$cg/memory/memory.limit_in_bytes" max)
  fi
  [ -n "$OVR_MEM_LIM_MIB" ] && ML=$(( OVR_MEM_LIM_MIB * 1024 * 1024 ))
}

# cpu sampler across ticks
CPU_PREV_U=""; CPU_PREV_T=""
cpu_sample(){
  NOW_T=$(date +%s.%N 2>/dev/null || date +%s)
  if [ "$is_v2" -eq 1 ]; then
    CUR_U=$(awk '/^usage_usec/ {print $2}' "$cg/cpu.stat" 2>/dev/null)
    line=$(rd "$cg/cpu.max" "max 100000")
    QUOTA=$(printf "%s" "$line" | awk '{print $1}')
    PERIOD=$(printf "%s" "$line" | awk '{print $2}')
    if [ -n "$OVR_CPU_LIM" ]; then
      CORES_LIM="$OVR_CPU_LIM"
    elif [ "$QUOTA" = "max" ] || [ -z "$PERIOD" ]; then
      CORES_LIM="inf"
    else
      CORES_LIM=$(awk -v q="$QUOTA" -v p="$PERIOD" 'BEGIN{printf("%.2f", q/p)}')
    fi
    if [ -n "$CPU_PREV_U" ] && [ -n "$CPU_PREV_T" ]; then
      DU=$(awk -v c="$CUR_U" -v p="$CPU_PREV_U" 'BEGIN{print c-p}')
      DT=$(awk -v n="$NOW_T" -v o="$CPU_PREV_T" 'BEGIN{print n-o}')
      [ "$DT" = "0" ] && DT="0.000001"
      CORES_USED=$(awk -v du="$DU" -v dt="$DT" 'BEGIN{printf("%.2f",(du/1000000.0)/dt)}')
    else
      CORES_USED="0.00"
    fi
  else
    CUR_U=$(rd "$cg/cpuacct/cpuacct.usage" 0)  # ns
    QUOTA=$(rd "$cg/cpu/cpu.cfs_quota_us" -1)
    PERIOD=$(rd "$cg/cpu/cpu.cfs_period_us" 100000)
    if [ -n "$OVR_CPU_LIM" ]; then
      CORES_LIM="$OVR_CPU_LIM"
    elif [ "$QUOTA" -lt 0 ] 2>/dev/null; then
      CORES_LIM="inf"
    else
      CORES_LIM=$(awk -v q="$QUOTA" -v p="$PERIOD" 'BEGIN{printf("%.2f", q/p)}')
    fi
    if [ -n "$CPU_PREV_U" ] && [ -n "$CPU_PREV_T" ]; then
      DU=$(awk -v c="$CUR_U" -v p="$CPU_PREV_U" 'BEGIN{print c-p}')
      DT=$(awk -v n="$NOW_T" -v o="$CPU_PREV_T" 'BEGIN{print n-o}')
      [ "$DT" = "0" ] && DT="0.000001"
      CORES_USED=$(awk -v du="$DU" -v dt="$DT" 'BEGIN{printf("%.2f",(du/1000000000.0)/dt)}')
    else
      CORES_USED="0.00"
    fi
  fi

  if [ "$CORES_LIM" = "inf" ]; then
    CPU_PCT="--"
  else
    CPU_PCT=$(awk -v u="$CORES_USED" -v l="$CORES_LIM" 'BEGIN{printf("%.0f",(l>0? (u/l)*100:0))}')
  fi

  CPU_PREV_U="$CUR_U"; CPU_PREV_T="$NOW_T"
}

# ---- output: TABLE ----
# Per-path callback for table mode (invoked via for_each_path).
disk_row_table() {
  p="$1"
  disk_calc "$p"
  if [ -z "$DISK_TOTAL" ] || [ "$DISK_TOTAL" = "0" ]; then
    printf '%b  • Disk %s: N/A%b\n' "$YELLOW" "$p" "$NC"
    return
  fi
  USED_MB=$(h_mib "$DISK_AVAIL"); TOTAL_MB=$(h_mib "$DISK_TOTAL")
  dcol=$(pct_color "$DISK_USEPCT" "$DISK_WARN" "$DISK_CRIT")
  printf '  • Disk %s: %b%s MiB / %s MiB (used%%: %s%%)%b\n' \
    "$p" "$dcol" "$USED_MB" "$TOTAL_MB" "$DISK_USEPCT" "$NC"
}

print_table() {
  # header
  printf '\033[H\033[J'
  printf '%b\n' "${CYAN}Container usage (cgroup $( [ -f "$cg/cgroup.controllers" ] && echo v2 || echo v1 ))${NC}"
  date

  # CPU
  if [ "$SHOW_CPU" -eq 1 ]; then
    if [ "$CORES_LIM" = "inf" ]; then
      ccol=$(pct_color "--" "$CPU_WARN" "$CPU_CRIT")
      printf '  • CPU: %b%s cores%b  (limit: ∞, used%%: --)\n' \
        "$ccol" "$CORES_USED" "$NC"
    else
      ccol=$(pct_color "$CPU_PCT" "$CPU_WARN" "$CPU_CRIT")
      printf '  • CPU: %b%s cores%b  (limit: %s cores, used%%: %s%%)\n' \
        "$ccol" "$CORES_USED" "$NC" "$CORES_LIM" "$CPU_PCT"
    fi
  fi
  
  # MEM
  if [ "$SHOW_MEM" -eq 1 ]; then
    if [ "$ML" = "max" ] || [ -z "$ML" ]; then
      MEM_LIM_STR="∞"; MEM_PCT="--"
    else
      MEM_LIM_STR="$(h_mib "$ML") MiB"
      MEM_PCT=$(awk -v u="$MU" -v l="$ML" 'BEGIN{printf("%d",(l>0? (u*100)/l:0))}')
    fi
    MEM_USED_STR="$(h_mib "$MU") MiB"
    mcol=$(pct_color "$MEM_PCT" "$MEM_WARN" "$MEM_CRIT")
    printf '  • MEM: %b%s%b  (limit: %s, used%%: %s%%)\n' \
      "$mcol" "$MEM_USED_STR" "$NC" "$MEM_LIM_STR" "$MEM_PCT"
  fi
  
  # DISK
  if [ "$SHOW_DISK" -eq 1 ]; then
    for_each_path disk_row_table
  fi
}

# ---- output: JSON ----
# Note: no jq dependency, escape manually
# Per-path callback for JSON mode (invoked via for_each_path). Uses the global
# `first` to emit comma separators between array elements.
disk_obj_json() {
  p="$1"
  disk_calc "$p"
  [ "$first" -eq 0 ] && printf ','
  first=0
  if [ -z "$DISK_TOTAL" ] || [ "$DISK_TOTAL" = "0" ]; then
    printf '{"path":"%s","used_mib":null,"total_mib":null,"percent":null}' "$p"
  else
    printf '{"path":"%s","used_mib":%d,"total_mib":%d,"percent":%d}' \
      "$p" "$(h_mib "$DISK_AVAIL")" "$(h_mib "$DISK_TOTAL")" "$DISK_USEPCT"
  fi
}

print_json() {
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  CG_VER=$( [ -f "$cg/cgroup.controllers" ] && echo v2 || echo v1 )

  printf '{'
  printf '"container_usage":{'
  printf '"cgroup_version":"%s",' "$CG_VER"
  printf '"timestamp":"%s"' "$TS"

  # CPU (leading comma keeps output valid regardless of which sections are on)
  if [ "$SHOW_CPU" -eq 1 ]; then
    printf ',"cpu":{'
    printf '"used_cores":%.2f,' "$CORES_USED"
    if [ "$CORES_LIM" = "inf" ]; then
      printf '"limit_cores":null,"percent":null'
    else
      printf '"limit_cores":%.2f,"percent":%d' "$CORES_LIM" "$CPU_PCT"
    fi
    printf '}'
  fi

  # Memory
  if [ "$SHOW_MEM" -eq 1 ]; then
    printf ',"memory":{'
    if [ "$ML" = "max" ] || [ -z "$ML" ]; then
      printf '"used_mib":%d,"limit_mib":null,"percent":null' "$(h_mib "$MU")"
    else
      printf '"used_mib":%d,"limit_mib":%d,"percent":%d' \
        "$(h_mib "$MU")" "$(h_mib "$ML")" \
        "$(awk -v u="$MU" -v l="$ML" 'BEGIN{printf("%d",(l>0? (u*100)/l:0))}')"
    fi
    printf '}'
  fi

  # Disks
  if [ "$SHOW_DISK" -eq 1 ]; then
    printf ',"disks":['
    first=1
    for_each_path disk_obj_json
    printf ']'
  fi

  printf '}}'
  printf '\n'
}


# --- main loop ---
trap 'printf "\n"; exit 0' INT TERM

# CPU usage is a delta between two samples. In --once mode the loop only runs
# a single iteration, so prime an initial sample and let one interval elapse;
# otherwise CPU would always report 0.00.
if [ "$ONCE" -eq 1 ] && [ "$SHOW_CPU" -eq 1 ]; then
  cpu_sample
  sleep "$INTERVAL"
fi

while :; do
  [ "$SHOW_CPU" -eq 1 ] && cpu_sample
  [ "$SHOW_MEM" -eq 1 ] && mem_read

  case "$OUTPUT_FORMAT" in
    json) print_json ;;
    *)    print_table ;;
  esac

  [ "$ONCE" -eq 1 ] && break
  sleep "$INTERVAL"
done