#!/bin/sh
set -eu

ROOT="${1:?usage: daemon-live-read.sh STAGED_REPOSITORY_ROOT}"
DAEMON="$ROOT/packages/modem-smsd/files/usr/sbin/modem-smsd"
CORE="$ROOT/packages/modem-smsd/files/usr/share/modem-sms/core.uc"
BACKEND="$ROOT/packages/modem-smsd/files/usr/share/modem-sms/backend-lteat.uc"
STATE='/tmp/modem-sms-live-read-state.json'
LOG='/tmp/modem-sms-live-read.log'
PID=''

stop_daemon() {
	if [ -n "$PID" ]; then
		kill "$PID" 2>/dev/null || true
		wait "$PID" 2>/dev/null || true
		PID=''
	fi
}

cleanup() {
	stop_daemon
	rm -f "$STATE" "$STATE.new" "$STATE.purge-backup" "$LOG"
	rm -f /etc/config/modem-sms
	rm -f /usr/share/modem-sms/core.uc /usr/share/modem-sms/backend-lteat.uc
	rmdir /usr/share/modem-sms 2>/dev/null || true
}

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	[ ! -f "$LOG" ] || tail -n 80 "$LOG" >&2 || true
	exit 1
}

[ "$(id -u)" = '0' ] || fail 'run as root'
[ -f "$DAEMON" ] && [ -f "$CORE" ] && [ -f "$BACKEND" ] || fail 'staged files are incomplete'
[ ! -e /etc/config/modem-sms ] || fail '/etc/config/modem-sms already exists; refusing to overwrite'
[ ! -e /usr/share/modem-sms ] || fail '/usr/share/modem-sms already exists; refusing to overwrite'
if ubus -S list modem.sms 2>/dev/null | grep -q '^modem\.sms$'; then
	fail 'modem.sms is already registered; refusing to disturb it'
fi

trap cleanup EXIT INT TERM
mkdir -p /usr/share/modem-sms
cp "$CORE" /usr/share/modem-sms/core.uc
cp "$BACKEND" /usr/share/modem-sms/backend-lteat.uc
cat > /etc/config/modem-sms <<'EOF'
config service 'main'
	option backend 'lteat'
	option cache_seconds '10'
	option list_limit_max '200'
	option request_history_max '20'
	option minimum_free_slots '4'
	option concat_window_seconds '600'
	option send_queue_max '20'
	option send_rate_limit_seconds '1'
	option request_state_path '/tmp/modem-sms-live-read-state.json'

config backend 'lteat'
	option object 'lteat'
	option switch_method 'send'
	option switch_argument 'cmd'
	option list_method 'get_sms'
	option send_method 'send_sms'
	option delete_method 'del_sms'
	option default_storage 'SM'
	option storage_order 'SM ME'
	option read_call_timeout_seconds '60'
	option send_call_timeout_seconds '120'
EOF

ucode "$DAEMON" >"$LOG" 2>&1 &
PID=$!
i=0
until ubus -S list modem.sms 2>/dev/null | grep -q '^modem\.sms$'; do
	i=$((i + 1))
	[ "$i" -lt 10 ] || fail 'daemon did not register modem.sms'
	kill -0 "$PID" 2>/dev/null || fail 'daemon exited during startup'
	sleep 1
done

capabilities="$(ubus call modem.sms capabilities '{}')"
[ "$(printf '%s' "$capabilities" | jsonfilter -e '@.ok' 2>/dev/null || true)" = 'true' ] || \
	fail "capabilities failed: $capabilities"
[ "$(printf '%s' "$capabilities" | jsonfilter -e '@.backend_available' 2>/dev/null || true)" = 'true' ] || \
	fail "lteat backend unavailable: $capabilities"

reply="$(ubus call modem.sms list '{"box":"all","storage":"ALL","limit":10,"refresh":true}')"
[ "$(printf '%s' "$reply" | jsonfilter -e '@.ok' 2>/dev/null || true)" = 'true' ] || \
	fail "live read failed: $reply"
[ "$(printf '%s' "$reply" | jsonfilter -e '@.loading' 2>/dev/null || true)" = 'true' ] || \
	fail "live cold read did not return loading state: $reply"
i=0
while [ "$i" -lt 70 ]; do
	reply="$(ubus call modem.sms list '{"box":"all","storage":"ALL","limit":10,"refresh":false}')"
	[ "$(printf '%s' "$reply" | jsonfilter -e '@.ok' 2>/dev/null || true)" = 'true' ] || \
		fail "live read poll failed: $reply"
	[ "$(printf '%s' "$reply" | jsonfilter -e '@.loading' 2>/dev/null || true)" != 'true' ] && break
	i=$((i + 1))
	sleep 1
done
[ "$i" -lt 70 ] || fail 'live cold read did not finish within 70 seconds'
sm="$(printf '%s' "$reply" | jsonfilter -e '@.storage.SM.available' 2>/dev/null || true)"
me="$(printf '%s' "$reply" | jsonfilter -e '@.storage.ME.available' 2>/dev/null || true)"
[ "$sm" = 'true' ] || [ "$me" = 'true' ] || fail "neither SM nor ME was readable: $reply"
first_id="$(printf '%s' "$reply" | jsonfilter -e '@.messages[0].id' 2>/dev/null || true)"
stale="$(printf '%s' "$reply" | jsonfilter -e '@.stale' 2>/dev/null || true)"
printf 'PASS: live lteat read; SM=%s ME=%s stale=%s first_message_present=%s\n' \
	"$sm" "$me" "$stale" "$([ -n "$first_id" ] && printf yes || printf no)"
