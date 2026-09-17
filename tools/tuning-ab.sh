#!/usr/bin/env bash
# tuning-ab.sh — switch the running vs995 between stock and this repo's governor/HMP tuning, live.
#
#   ./tools/tuning-ab.sh stock | tuned | show
#
# Every knob in overlay/patches/device/lge/msm8996-common/0001-*.patch is a sysfs write, so the two
# states can be A/B-ed on one phone and one build without reflashing: `stock`, run
# forge/tools/bench-launch.sh, `tuned`, run it again. Needs root (Magisk su). Reboot restores the
# build's own values. Keep the two lists in step with the patch.
set -o pipefail
CPU=/sys/devices/system/cpu
case "${1:-}" in
  stock)
    W="$CPU/cpu0/cpufreq/interactive/go_hispeed_load 90
       $CPU/cpu0/cpufreq/interactive/hispeed_freq 960000
       $CPU/cpu0/cpufreq/interactive/target_loads 80
       $CPU/cpu2/cpufreq/interactive/go_hispeed_load 90
       $CPU/cpu2/cpufreq/interactive/hispeed_freq 1248000
       /sys/module/cpu_boost/parameters/input_boost_freq 0:1324800 2:1324800
       /sys/module/cpu_boost/parameters/input_boost_ms 40
       /proc/sys/kernel/sched_upmigrate 95
       /proc/sys/kernel/sched_downmigrate 90" ;;
  tuned)
    W="$CPU/cpu0/cpufreq/interactive/go_hispeed_load 85
       $CPU/cpu0/cpufreq/interactive/hispeed_freq 1113600
       $CPU/cpu0/cpufreq/interactive/target_loads 80 1113600:85 1401600:90
       $CPU/cpu2/cpufreq/interactive/go_hispeed_load 85
       $CPU/cpu2/cpufreq/interactive/hispeed_freq 1478400
       /sys/module/cpu_boost/parameters/input_boost_freq 0:1324800 2:1708800
       /sys/module/cpu_boost/parameters/input_boost_ms 60
       /proc/sys/kernel/sched_upmigrate 85
       /proc/sys/kernel/sched_downmigrate 75" ;;
  show) W="" ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1;;
esac

NODES="$CPU/cpu0/cpufreq/interactive/go_hispeed_load $CPU/cpu0/cpufreq/interactive/hispeed_freq
       $CPU/cpu0/cpufreq/interactive/target_loads $CPU/cpu2/cpufreq/interactive/go_hispeed_load
       $CPU/cpu2/cpufreq/interactive/hispeed_freq /sys/module/cpu_boost/parameters/input_boost_freq
       /sys/module/cpu_boost/parameters/input_boost_ms /proc/sys/kernel/sched_upmigrate
       /proc/sys/kernel/sched_downmigrate"

# One su invocation, the list on stdin: each line is "<node> <value...>", the value may contain
# spaces. The command is quoted once for the local shell and once for the phone's.
REMOTE='while read -r n v; do echo "$v" > "$n" || echo "!! $n"; done'
if [ -n "$W" ]; then
  printf '%s\n' "$W" | sed 's/^ *//' | adb shell "su -c '$REMOTE'" \
    || { echo "!! su failed -- is Magisk set up?" >&2; exit 1; }
fi
for n in $NODES; do printf '%-62s %s\n' "${n#/sys/devices/system/cpu/}" "$(adb shell "su -c 'cat $n'" 2>&1 | tr -d '\r')"; done
