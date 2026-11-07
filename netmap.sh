#!/bin/bash
# Prints the network map for the Sentinel HUD as one JSON object.
#
# Passive sources: the kernel neighbour table (devices this machine has
# exchanged traffic with), established TCP sockets, and UFW block entries in
# the kernel log. Names come from cached mDNS / reverse-DNS lookups and the
# MAC vendor list in /usr/share/hwdata/oui.txt.
#
# Active: a ping sweep of the local /24 (nmap -sn when nmap is installed), at
# most every SWEEP_EVERY seconds, and ONLY when the current gateway's MAC is
# listed in ~/.config/sentinel-hud/sweep-networks (or a sweep-networks
# file next to this script). Without that file the HUD stays fully passive.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
state="${XDG_STATE_HOME:-$HOME/.local/state}/sentinel-hud"
mkdir -p "$state"
known="$state/known-macs"   # "<mac> <first-seen-epoch>"
names="$state/names"        # "<key> <name>" cache for ip/mac lookups
touch "$names"
now=$(date +%s)
SWEEP_EVERY=300
BLOCK_WINDOW=600            # seconds a firewall block stays on the map
NEW_FOR=86400               # a device stays "new" for a day

cached() { awk -v k="$1" '$1==k{ $1=""; sub(/^ /,""); print; exit }' "$names"; }
remember() { printf '%s %s\n' "$1" "${2:--}" >>"$names"; }

# Reverse names are looked up a few at a time and cached for good, so the
# map never waits on DNS.
LOOKUPS=0
name_for_ip() {
  local ip="$1" n
  n=$(cached "ip:$ip")
  if [[ -z $n && $LOOKUPS -lt 4 ]]; then
    LOOKUPS=$((LOOKUPS + 1))
    n=$(timeout 1 avahi-resolve -a "$ip" 2>/dev/null | awk '{print $2}')
    [[ -z $n ]] && n=$(timeout 1 getent hosts "$ip" | awk '{print $2}')
    remember "ip:$ip" "${n:--}"
  fi
  [[ $n == "-" ]] && n=""
  printf '%s' "${n%.local}"
}

vendor_for_mac() {
  local mac="${1,,}" v first
  first=$((16#${mac:0:2}))
  if (( first & 2 )); then printf 'private MAC'; return; fi
  v=$(cached "mac:${mac:0:8}")
  if [[ -z $v ]]; then
    local oui="${mac:0:8}"; oui="${oui//:/-}"
    v=$(grep -i -m1 "^${oui}" /usr/share/hwdata/oui.txt 2>/dev/null \
      | sed -E 's/^[0-9A-Fa-f-]+[[:space:]]+\(hex\)[[:space:]]+//' | cut -c1-24 | sed 's/[[:space:]]*$//')
    remember "mac:${mac:0:8}" "${v:--}"
  fi
  [[ $v == "-" ]] && v=""
  printf '%s' "$v"
}

# Registered-domain grouping: lb-140-82-112-3.github.com -> github.com
group_label() {
  local n="$1"
  [[ -z $n ]] && return
  awk -F. '{ if (NF>=2) print $(NF-1)"."$NF; else print $0 }' <<<"$n"
}

dev=$(ip -j route show default 2>/dev/null | jq -r '.[0].dev // empty')
gw=$(ip -j route show default 2>/dev/null | jq -r '.[0].gateway // empty')
if [[ -z $dev ]]; then
  jq -nc '{online:false}'
  exit 0
fi
read -r myip prefix < <(ip -j -4 addr show dev "$dev" | jq -r '.[0].addr_info[0] | "\(.local) \(.prefixlen)"')
gwmac=$(ip -j neigh show "$gw" dev "$dev" 2>/dev/null | jq -r '.[0].lladdr // empty')
net3="${myip%.*}"

in_lan() { [[ $prefix -ge 24 && ${1%.*} == "$net3" ]] || { [[ $prefix -lt 24 ]] && [[ ${1%%.*} == "${myip%%.*}" ]]; }; }

# ── optional active sweep ──
sweep="off"
allow="${XDG_CONFIG_HOME:-$HOME/.config}/sentinel-hud/sweep-networks"
[[ -f $allow ]] || allow="$here/sweep-networks"
if [[ -n $gwmac && -f $allow ]] && grep -qi "^${gwmac}\b" "$allow"; then
  sweep="armed"
  last=$(cat "$state/last-sweep" 2>/dev/null || echo 0)
  if (( now - last >= SWEEP_EVERY )) && (( prefix >= 24 )); then
    echo "$now" >"$state/last-sweep"
    sweep="running"
    (
      if command -v nmap >/dev/null; then
        nmap -sn -n "$net3.0/24" >/dev/null 2>&1
      else
        for i in $(seq 1 254); do ping -c1 -W1 -q "$net3.$i" >/dev/null 2>&1 & done; wait
      fi
    ) </dev/null >/dev/null 2>&1 &
    disown
  fi
fi

# ── first run: everything already present counts as known ──
[[ -f $known ]] || : >"$known"
[[ -f $state/since ]] || echo "$now" >"$state/since"
since=$(<"$state/since")
BASELINE=900

# ── established connections ──
declare -A conn=()
while read -r peer; do
  ip="${peer%:*}"; ip="${ip#[}"; ip="${ip%]}"; ip="${ip#::ffff:}"
  [[ $ip =~ ^[0-9.]+$ ]] || continue
  [[ $ip == 127.* || $ip == "$myip" ]] && continue
  conn[$ip]=$(( ${conn[$ip]:-0} + 1 ))
done < <(ss -Htn state established 2>/dev/null | awk '{print $4}')

# ── firewall blocks in the window ──
declare -A blk_age=() blk_port=()
while IFS=$'\t' read -r ts src dpt proto; do
  [[ -n $src ]] || continue
  age=$(( now - ts ))
  if [[ -z ${blk_age[$src]+x} || $age -lt ${blk_age[$src]} ]]; then
    blk_age[$src]=$age; blk_port[$src]="$proto/$dpt"
  fi
done < <(journalctl -k --since "-${BLOCK_WINDOW}s" -g 'UFW BLOCK' -o json --no-pager -q 2>/dev/null | jq -r '
  (.__REALTIME_TIMESTAMP | tonumber / 1000000 | floor) as $t
  | (.MESSAGE | if type == "array" then implode else tostring end) as $m
  | [$t, (($m | capture("SRC=(?<v>[0-9.]+)").v) // ""),
     (($m | capture("DPT=(?<v>[0-9]+)").v) // "-"),
     (($m | capture("PROTO=(?<v>[A-Z0-9]+)").v) // "?")] | @tsv')

nodes=()
add() { nodes+=("$(jq -nc "$@" '$ARGS.named')"); }

# ── LAN devices from the neighbour table ──
declare -A seen_lan=()
while IFS=$'\t' read -r ip mac st; do
  [[ -n $mac ]] || continue
  seen_lan[$ip]=1
  first=$(awk -v m="$mac" '$1==m{print $2; exit}' "$known")
  if [[ -z $first ]]; then
    first=$now
    (( now - since < BASELINE )) && first=0
    echo "$mac $first" >>"$known"
  fi
  isnew=false; (( first > 0 && now - first < NEW_FOR )) && isnew=true
  name=$(name_for_ip "$ip")
  [[ $ip == "$gw" ]] && kind=gateway || kind=lan
  add --arg id "$ip" --arg kind "$kind" --arg label "${name:-$ip}" --arg ip "$ip" \
      --arg vendor "$(vendor_for_mac "$mac")" --arg state "$st" \
      --argjson conns "${conn[$ip]:-0}" --argjson isnew "$isnew" \
      --argjson blocked "${blk_age[$ip]:--1}" --arg port "${blk_port[$ip]:-}"
done < <(ip -j -4 neigh show dev "$dev" 2>/dev/null | jq -r '
  .[] | select(.lladdr and ((.state // []) | index("FAILED") | not)) | [.dst, .lladdr, ((.state // ["?"])[0])] | @tsv')

# ── remote hosts, grouped by registered domain ──
declare -A g_conns=() g_block=() g_port=() g_ips=()
for ip in "${!conn[@]}"; do
  in_lan "$ip" && continue
  label=$(group_label "$(name_for_ip "$ip")"); label="${label:-$ip}"
  g_conns[$label]=$(( ${g_conns[$label]:-0} + ${conn[$ip]} ))
  g_ips[$label]=$(( ${g_ips[$label]:-0} + 1 ))
done
for ip in "${!blk_age[@]}"; do
  if in_lan "$ip"; then
    [[ -n ${seen_lan[$ip]+x} ]] && continue
    add --arg id "$ip" --arg kind lan --arg label "$(name_for_ip "$ip")" --arg ip "$ip" \
        --arg vendor "" --arg state "BLOCKED" --argjson conns 0 --argjson isnew false \
        --argjson blocked "${blk_age[$ip]}" --arg port "${blk_port[$ip]}"
    continue
  fi
  label=$(group_label "$(name_for_ip "$ip")"); label="${label:-$ip}"
  if [[ -z ${g_block[$label]+x} || ${blk_age[$ip]} -lt ${g_block[$label]} ]]; then
    g_block[$label]=${blk_age[$ip]}; g_port[$label]=${blk_port[$ip]}
  fi
done
for label in $(printf '%s\n' "${!g_conns[@]}" "${!g_block[@]}" | sort -u); do
  add --arg id "wan:$label" --arg kind wan --arg label "$label" --arg ip "" --arg vendor "" --arg state "" \
      --argjson conns "${g_conns[$label]:-0}" --argjson isnew false \
      --argjson blocked "${g_block[$label]:--1}" --arg port "${g_port[$label]:-}" \
      --argjson hosts "${g_ips[$label]:-0}"
done

# Keep the names cache from growing without bound.
if (( $(wc -l <"$names") > 2000 )); then tail -n 1000 "$names" >"$names.tmp" && mv "$names.tmp" "$names"; fi

printf '%s\n' "${nodes[@]}" | jq -sc \
  --arg host "$(</proc/sys/kernel/hostname)" --arg ip "$myip" --arg prefix "$prefix" \
  --arg gw "$gw" --arg sweep "$sweep" --argjson window "$BLOCK_WINDOW" '
  {online: true, host: $host, ip: $ip, net: ($ip | sub("\\.[0-9]+$"; ".0") + "/" + $prefix),
   gw: $gw, sweep: $sweep, window: $window,
   lan: map(select(.kind != "wan")) | sort_by(.ip | split(".") | map(tonumber)),
   wan: map(select(.kind == "wan")) | sort_by(-(.conns), .label) | .[0:12]}'
