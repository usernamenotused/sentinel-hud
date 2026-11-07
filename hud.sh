#!/bin/bash
# Prints one JSON object of live readouts for the Sentinel HUD.
# Read-only: everything here works without root.
set -u
rt="${XDG_RUNTIME_DIR:-/tmp}/sentinel-hud.state"
cache="${XDG_STATE_HOME:-$HOME/.local/state}/sentinel-hud"
mkdir -p "$cache"
now_s=$(date +%s)

# Git repos under these roots (depth 3) are listed in the dev panel.
# Override in ~/.config/sentinel-hud/config (see config.example).
REPO_ROOTS=("$HOME/Projects" "$HOME/Work" "$HOME/Code" "$HOME/src" "$HOME/dev")
conf="${XDG_CONFIG_HOME:-$HOME/.config}/sentinel-hud/config"
# shellcheck source=/dev/null
[[ -f $conf ]] && source "$conf"
repo_roots=$(printf '%s\n' "${REPO_ROOTS[@]}" | sed "s|^$HOME|~|" | paste -sd, - | sed 's/,/, /g')

read -r up _ </proc/uptime
read -r l1 l5 l15 _ </proc/loadavg
read -r _ u n s i w q sq st _ </proc/stat
cpu_total=$((u + n + s + i + w + q + sq + st)); cpu_idle=$((i + w))
mem_total=$(awk '/^MemTotal/{print $2}' /proc/meminfo)
mem_avail=$(awk '/^MemAvailable/{print $2}' /proc/meminfo)

# CPU package temperature: Intel exposes x86_pkg_temp as a thermal zone; AMD
# (k10temp / zenpower) and some Intel setups (coretemp) only via hwmon.
temp=0
for z in /sys/class/thermal/thermal_zone*; do
  [[ -r $z/type && $(<"$z/type") == x86_pkg_temp ]] && temp=$(( $(<"$z/temp") / 1000 )) && break
done
if (( temp == 0 )); then
  for h in /sys/class/hwmon/hwmon*; do
    case "$(<"$h/name")" in
      k10temp | zenpower | coretemp)
        [[ -r $h/temp1_input ]] && temp=$(( $(<"$h/temp1_input") / 1000 )) && break ;;
    esac
  done 2>/dev/null
fi

# ── battery ──
bat_pct=-1; bat_state=""; bat_watts=0
for b in /sys/class/power_supply/BAT*; do
  [[ -d $b ]] || continue
  bat_pct=$(<"$b/capacity"); bat_state=$(<"$b/status")
  if [[ -f $b/power_now ]]; then bat_watts=$(( $(<"$b/power_now") / 100000 ))
  elif [[ -f $b/current_now && -f $b/voltage_now ]]; then
    bat_watts=$(( $(<"$b/current_now") / 1000 * ($(<"$b/voltage_now") / 1000) / 100000000 ))
  fi
  break
done

# ── disks ──
disks=$(df -P -x tmpfs -x devtmpfs -x efivarfs -x overlay -x squashfs 2>/dev/null | awk 'NR>1 && !seen[$1]++ {
  gsub("%","",$5); printf "%s\t%s\t%.0f\n", $6, $5, $2/1048576 }' | jq -Rsc 'split("\n") | map(select(length>0) | split("\t") | {mount: .[0], pct: (.[1]|tonumber), gb: (.[2]|tonumber)})')

# ── network ──
dev=$(ip -j route show default 2>/dev/null | jq -r '.[0].dev // empty')
gw=$(ip -j route show default 2>/dev/null | jq -r '.[0].gateway // empty')
ip4=""; rx=0; tx=0; dns=""; dot=""
if [[ -n $dev ]]; then
  ip4=$(ip -j -4 addr show dev "$dev" | jq -r '.[0].addr_info[0].local // empty')
  rx=$(<"/sys/class/net/$dev/statistics/rx_bytes"); tx=$(<"/sys/class/net/$dev/statistics/tx_bytes")
  dns=$(resolvectl dns "$dev" 2>/dev/null | sed -E 's/^[^:]*:[[:space:]]*//' | tr ' ' '\n' | grep -v '^$' | head -3 | paste -sd' ' -)
  dot=$(resolvectl status "$dev" 2>/dev/null | grep -o '[+-]DNSOverTLS' | head -1)
fi
ssid=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}')
vpn=$(ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^(wg|tun|tailscale)/{print $2}' | paste -sd, -)

now=$(date +%s%N)
cpu_pct=0; rx_rate=0; tx_rate=0
if [[ -f $rt ]]; then
  read -r p_now p_total p_idle p_rx p_tx p_dev <"$rt"
  dt=$(( (now - p_now) / 1000000 ))
  dtot=$((cpu_total - p_total))
  (( dtot > 0 )) && cpu_pct=$(( 100 * (dtot - (cpu_idle - p_idle)) / dtot ))
  if (( dt > 0 )) && [[ $p_dev == "$dev" ]]; then
    rx_rate=$(( (rx - p_rx) * 1000 / dt )); tx_rate=$(( (tx - p_tx) * 1000 / dt ))
  fi
fi
echo "$now $cpu_total $cpu_idle $rx $tx ${dev:--}" >"$rt"

# ── security ──
if systemctl cat ufw.service >/dev/null 2>&1; then
  fw=$(systemctl is-active ufw 2>/dev/null)
else
  fw="not installed"
fi
# Listeners reachable from other machines, with the owning process when it is
# ours to see (sockets owned by root or system users show as "system").
listen=$(ss -Htulnp 2>/dev/null | awk '{ proc="system"; if (match($0, /users:\(\("[^"]+"/)) proc=substr($0, RSTART+9, RLENGTH-10);
  print $1, $5, proc }' | grep -vE ' (127\.|\[::1\]|\[::ffff:127\.)' \
  | awk '{ n=split($2,a,":"); print $1"\t"a[n]"\t"$3 }' | sort -u -t$'\t' -k2,2n -k1,1 \
  | jq -Rsc 'split("\n") | map(select(length>0) | split("\t") | {proto: .[0], port: .[1], proc: .[2]})')
estab=$(ss -Htn state established 2>/dev/null | wc -l)
failed_units=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | paste -sd' ' -)
authfail=$(journalctl --since today -o cat --no-pager -q 2>/dev/null \
  | grep -ciE 'authentication failure|failed password|invalid user|incorrect password')

# Firewall blocks over the last hour: total, top sources, and a 12-bucket
# (5 minute) histogram for the sparkline.
fwstats=$(journalctl -k --since "-1h" -g 'UFW BLOCK' -o json --no-pager -q 2>/dev/null | jq -sc --argjson now "$now_s" '
  map({t: (.__REALTIME_TIMESTAMP | tonumber / 1000000 | floor),
       m: (.MESSAGE | if type == "array" then implode else tostring end)}
      | . + {src: ((.m | capture("SRC=(?<v>[^ ]+)").v) // "?"),
             port: ((((.m | capture("PROTO=(?<v>[A-Z0-9]+)").v) // "?")) + "/" + ((.m | capture("DPT=(?<v>[0-9]+)").v) // "-"))})
  | {total: length,
     spark: (reduce .[] as $e ([range(0;12)] | map(0);
               (11 - ((($now - $e.t) / 300) | floor)) as $i
               | if $i >= 0 and $i < 12 then .[$i] += 1 else . end)),
     top: (group_by(.src) | map({src: .[0].src, n: length, port: (map(.port) | group_by(.) | max_by(length)[0])})
           | sort_by(-.n) | .[0:3])}')

# ── updates (checkupdates hits the network, so at most once an hour) ──
upd_file="$cache/updates"
if [[ ! -f $upd_file ]] || (( now_s - $(stat -c %Y "$upd_file") > 3600 )); then
  [[ -f $upd_file ]] || echo "-1 -1" >"$upd_file"
  touch "$upd_file"
  ( n=$(checkupdates 2>/dev/null | wc -l)
    sec=-1
    command -v arch-audit >/dev/null && sec=$(arch-audit -u 2>/dev/null | wc -l)
    echo "$n $sec" >"$upd_file.tmp" && mv "$upd_file.tmp" "$upd_file" ) </dev/null >/dev/null 2>&1 &
  disown
fi
read -r upd_n upd_sec <"$upd_file"
upd_age=$(( now_s - $(stat -c %Y "$upd_file") ))

# ── git repos ──
repos="[]"
mapfile -t gits < <(for r in "${REPO_ROOTS[@]}"; do [[ -d $r ]] && find "$r" -maxdepth 3 -name .git -type d 2>/dev/null; done | sort | head -6)
if (( ${#gits[@]} > 0 )); then
  repos=$(for g in "${gits[@]}"; do
    d="${g%/.git}"
    st=$(git -C "$d" status --porcelain=v2 --branch 2>/dev/null) || continue
    br=$(awk '/^# branch.head/{print $3}' <<<"$st")
    ab=$(awk '/^# branch.ab/{print $3" "$4}' <<<"$st")
    dirty=$(grep -cv '^#' <<<"$st")
    printf '%s\t%s\t%s\t%s\n' "${d##*/}" "$br" "${ab:-no upstream}" "$dirty"
  done | jq -Rsc 'split("\n") | map(select(length>0) | split("\t") | {name: .[0], branch: .[1], ab: .[2], dirty: (.[3]|tonumber)})')
fi

log=$(journalctl -p warning -n 5 -o json --no-pager -q 2>/dev/null | jq -sc '
  map(
    (.__REALTIME_TIMESTAMP | tonumber / 1000000 | strflocaltime("%H:%M:%S")) as $t
    | (.MESSAGE | if type == "array" then implode else tostring end) as $m
    | if ($m | test("\\[UFW (BLOCK|AUDIT|DENY)")) then
        { t: $t, kind: "fw",
          msg: ("BLOCK " + (($m | capture("PROTO=(?<v>[A-Z0-9]+)").v) // "?")
                + " " + (($m | capture("SRC=(?<v>[^ ]+)").v) // "?")
                + " -> :" + (($m | capture("DPT=(?<v>[0-9]+)").v) // "-")) }
      else { t: $t, kind: "sys", msg: (((.SYSLOG_IDENTIFIER // "?") + ": " + $m) | .[0:90]) } end)')

jq -nc \
  --arg host "$(</proc/sys/kernel/hostname)" --arg user "$USER" --arg kernel "$(uname -r)" \
  --argjson up "${up%.*}" --arg load "$l1 $l5 $l15" --argjson cpu "$cpu_pct" \
  --argjson mem "$(( 100 * (mem_total - mem_avail) / mem_total ))" --argjson temp "$temp" \
  --argjson bat "$bat_pct" --arg batState "$bat_state" --argjson batWatts "$bat_watts" \
  --argjson disks "${disks:-[]}" \
  --arg dev "$dev" --arg ip "$ip4" --arg gw "$gw" --arg ssid "$ssid" --arg vpn "$vpn" \
  --arg dns "$dns" --arg dot "$dot" \
  --argjson rx "$rx_rate" --argjson tx "$tx_rate" \
  --arg fw "$fw" --argjson listen "${listen:-[]}" --argjson estab "$estab" \
  --arg failed "$failed_units" --argjson authfail "${authfail:-0}" \
  --argjson fwstats "${fwstats:-null}" \
  --argjson updates "${upd_n:--1}" --argjson secUpdates "${upd_sec:--1}" --argjson updAge "$upd_age" \
  --argjson repos "${repos:-[]}" --arg repoRoots "$repo_roots" --argjson log "${log:-[]}" \
  '$ARGS.named'
