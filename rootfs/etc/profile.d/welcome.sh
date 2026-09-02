#!/bin/sh

# Only show on interactive shell logins.
case "$-" in
  *i*) ;;
  *) return 0 2>/dev/null || exit 0 ;;
esac

RUNTIME_ENV_FILE="/etc/landscape/runtime.env"
LANDSCAPE_INIT_CONFIG="/root/.landscape-router/landscape_init.toml"
LANDSCAPE_ADMIN_USER="${LANDSCAPE_ADMIN_USER:-}"
LANDSCAPE_ADMIN_PASS="${LANDSCAPE_ADMIN_PASS:-}"
MASKED_PASS=""
PRIMARY_IP=""
WEB_UI_PORT="6443"
WEB_UI_URL=""
DEFAULT_ROUTE=""
DNS_SERVERS=""
INTERFACE_LINES=""

read_web_ui_port() {
  [ -r "$LANDSCAPE_INIT_CONFIG" ] || return 1

  awk '
    /^\[\[static_nat_mappings\.mapping_pair_ports\]\]/ {
      if (in_mapping && lan_port == "6443" && wan_port != "") {
        print wan_port
        exit
      }
      in_mapping = 1
      wan_port = ""
      lan_port = ""
      next
    }
    in_mapping && /^[[:space:]]*wan_port[[:space:]]*=/ {
      line = $0
      sub(/^[^=]*=[[:space:]]*/, "", line)
      sub(/[[:space:]]*#.*/, "", line)
      wan_port = line
      next
    }
    in_mapping && /^[[:space:]]*lan_port[[:space:]]*=/ {
      line = $0
      sub(/^[^=]*=[[:space:]]*/, "", line)
      sub(/[[:space:]]*#.*/, "", line)
      lan_port = line
      next
    }
    END {
      if (in_mapping && lan_port == "6443" && wan_port != "") {
        print wan_port
      }
    }
  ' "$LANDSCAPE_INIT_CONFIG"
}

CONFIGURED_WEB_UI_PORT="$(read_web_ui_port 2>/dev/null)"
if [ -n "$CONFIGURED_WEB_UI_PORT" ]; then
  WEB_UI_PORT="$CONFIGURED_WEB_UI_PORT"
fi

if [ -r "$RUNTIME_ENV_FILE" ]; then
  . "$RUNTIME_ENV_FILE"
fi

if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
  C_RESET="$(printf '\033[0m')"
  C_TITLE="$(printf '\033[1;36m')"
  C_BORDER="$(printf '\033[1;34m')"
  C_LABEL="$(printf '\033[1;33m')"
  C_VALUE="$(printf '\033[0;37m')"
else
  C_RESET=""
  C_TITLE=""
  C_BORDER=""
  C_LABEL=""
  C_VALUE=""
fi

if [ -n "$LANDSCAPE_ADMIN_PASS" ]; then
  PASS_LEN=${#LANDSCAPE_ADMIN_PASS}
  PASS_FIRST=$(printf '%s' "$LANDSCAPE_ADMIN_PASS" | cut -c1)
  PASS_LAST=$(printf '%s' "$LANDSCAPE_ADMIN_PASS" | awk '{print substr($0, length($0), 1)}')

  if [ "$PASS_LEN" -eq 1 ]; then
    MASKED_PASS="$PASS_FIRST"
  elif [ "$PASS_LEN" -eq 2 ]; then
    MASKED_PASS="$LANDSCAPE_ADMIN_PASS"
  else
    MASKED_PASS="${PASS_FIRST}***${PASS_LAST}"
  fi
fi

PRIMARY_IP="$(ip -o -4 addr show up scope global 2>/dev/null | awk 'NR == 1 {split($4, ip, "/"); print ip[1]; exit}')"
if [ -z "$PRIMARY_IP" ]; then
  PRIMARY_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi

if [ -n "$PRIMARY_IP" ]; then
  WEB_UI_URL="https://${PRIMARY_IP}:${WEB_UI_PORT}"
fi

DEFAULT_ROUTE="$(ip route show default 2>/dev/null | awk 'NR == 1 {printf "%s via %s", $5, $3; exit}')"
DNS_SERVERS="$(awk '/^nameserver[[:space:]]+/ { if (out) out = out ", "; out = out $2 } END { print out }' /etc/resolv.conf 2>/dev/null)"
INTERFACE_LINES="$(ip -o -4 addr show up scope global 2>/dev/null | awk '
{
  iface = $2
  split($4, ip, "/")
  if (!(iface in seen)) {
    seen[iface] = 1
    order[++count] = iface
  }
  if (ips[iface] != "") {
    ips[iface] = ips[iface] ", "
  }
  ips[iface] = ips[iface] ip[1] "/" ip[2]
}
END {
  for (i = 1; i <= count; i++) {
    iface = order[i]
    print iface ": " ips[iface]
  }
}')"

printf '\n%s========================================%s\n' "$C_BORDER" "$C_RESET"
printf '%s      Welcome to Landscape Mini !%s\n' "$C_TITLE" "$C_RESET"
printf '%s========================================%s\n' "$C_BORDER" "$C_RESET"

if [ -n "$LANDSCAPE_ADMIN_USER" ] || [ -n "$MASKED_PASS" ] || [ -n "$WEB_UI_URL" ]; then
  printf '%s[ Access ]%s\n' "$C_TITLE" "$C_RESET"
  if [ -n "$LANDSCAPE_ADMIN_USER" ]; then
    printf '%s%-14s%s %s%s%s\n' "$C_LABEL" 'Web UI user:' "$C_RESET" "$C_VALUE" "$LANDSCAPE_ADMIN_USER" "$C_RESET"
  fi
  if [ -n "$MASKED_PASS" ]; then
    printf '%s%-14s%s %s%s%s\n' "$C_LABEL" 'Web UI pass:' "$C_RESET" "$C_VALUE" "$MASKED_PASS" "$C_RESET"
  fi
  if [ -n "$WEB_UI_URL" ]; then
    printf '%s%-14s%s %s%s%s\n' "$C_LABEL" 'Web UI url:' "$C_RESET" "$C_VALUE" "$WEB_UI_URL" "$C_RESET"
  fi
fi

printf '%s[ Network ]%s\n' "$C_TITLE" "$C_RESET"
printf '%s%-14s%s %s%s%s\n' "$C_LABEL" 'Primary IP:' "$C_RESET" "$C_VALUE" "${PRIMARY_IP:-unavailable}" "$C_RESET"
printf '%s%-14s%s %s%s%s\n' "$C_LABEL" 'Gateway:' "$C_RESET" "$C_VALUE" "${DEFAULT_ROUTE:-unavailable}" "$C_RESET"
printf '%s%-14s%s %s%s%s\n' "$C_LABEL" 'DNS:' "$C_RESET" "$C_VALUE" "${DNS_SERVERS:-unavailable}" "$C_RESET"

if [ -n "$INTERFACE_LINES" ]; then
  printf '%sInterfaces:%s\n' "$C_LABEL" "$C_RESET"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '  %s- %s%s\n' "$C_VALUE" "$line" "$C_RESET"
  done <<EOF
$INTERFACE_LINES
EOF
fi

# landscape-kit guidance (only when the build embedded lkit).
if [ -x /usr/local/bin/lkit ]; then
  printf '%s[ landscape-kit ]%s\n' "$C_TITLE" "$C_RESET"
  printf '%s%-14s%s %s%s%s\n' "$C_LABEL" 'Managed by:' "$C_RESET" "$C_VALUE" "lkit (landscape-kit)" "$C_RESET"
  printf '%s%-14s%s %s%s%s\n' "$C_LABEL" 'Status:' "$C_RESET" "$C_VALUE" "lkit check" "$C_RESET"
  printf '%s%-14s%s %s%s%s\n' "$C_LABEL" 'Update:' "$C_RESET" "$C_VALUE" "lkit update" "$C_RESET"
  printf '%s%-14s%s %s%s%s\n' "$C_LABEL" 'More:' "$C_RESET" "$C_VALUE" "lkit --help" "$C_RESET"
fi

printf '%s========================================%s\n\n' "$C_BORDER" "$C_RESET"
