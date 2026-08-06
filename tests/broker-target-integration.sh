#!/bin/sh
set -eu

FAKE_MODEM="${1:-/tmp/modem-sms-fake-pty}"
BROKER="${2:-/usr/sbin/modem-sms-broker}"
CONFIG=/etc/config/modem-sms-broker
CONFIG_BACKUP=/tmp/modem-sms-broker.before-test
TTY_LINK=/tmp/modem-sms-fake-tty
FAKE_LOG=/tmp/modem-sms-fake-pty.log
BROKER_LOG=/tmp/modem-sms-broker-test.log
FAKE_PID=''
BROKER_PID=''
WATCHDOG_PID=''

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	[ ! -f "$BROKER_LOG" ] || tail -n 80 "$BROKER_LOG" >&2 || true
	[ ! -f "$FAKE_LOG" ] || tail -n 40 "$FAKE_LOG" >&2 || true
	exit 1
}

cleanup() {
	[ -z "$WATCHDOG_PID" ] || kill "$WATCHDOG_PID" 2>/dev/null || true
	[ -z "$BROKER_PID" ] || kill "$BROKER_PID" 2>/dev/null || true
	[ -z "$FAKE_PID" ] || kill "$FAKE_PID" 2>/dev/null || true
	[ -z "$BROKER_PID" ] || wait "$BROKER_PID" 2>/dev/null || true
	[ -z "$FAKE_PID" ] || wait "$FAKE_PID" 2>/dev/null || true
	[ ! -f "$CONFIG_BACKUP" ] || cp -p "$CONFIG_BACKUP" "$CONFIG"
	rm -f "$CONFIG_BACKUP" "$TTY_LINK" "$FAKE_LOG" "$BROKER_LOG"
}

assert_json() {
	value="$(printf '%s' "$1" | jsonfilter -e "$2" 2>/dev/null || true)"
	[ "$value" = "$3" ] || fail "$4: got $value from $1"
}

[ "$(id -u)" = 0 ] || fail 'run as root'
[ -x "$FAKE_MODEM" ] || fail "missing fake modem: $FAKE_MODEM"
[ -x "$BROKER" ] || fail "missing broker: $BROKER"
command -v ubus >/dev/null 2>&1 || fail 'ubus not found'
command -v jsonfilter >/dev/null 2>&1 || fail 'jsonfilter not found'
[ -f "$CONFIG" ] || fail "missing config: $CONFIG"

trap cleanup EXIT INT TERM
( sleep 45; kill -TERM $$ 2>/dev/null ) &
WATCHDOG_PID=$!
cp -p "$CONFIG" "$CONFIG_BACKUP"
cat > "$CONFIG" <<'EOF'
config broker 'main'
	option enabled '1'
	option object 'modem.smsat'
	option tty '/tmp/modem-sms-fake-tty'
	option baud '115200'
	option read_timeout_ms '1000'
	option lease_timeout_ms '5000'
	option response_limit '32768'
	option empty_cms_error_code '321'
EOF

rm -f "$TTY_LINK" "$FAKE_LOG" "$BROKER_LOG"
"$FAKE_MODEM" "$TTY_LINK" >"$FAKE_LOG" 2>&1 &
FAKE_PID=$!
sleep 1
[ -L "$TTY_LINK" ] || fail 'fake PTY did not appear'

"$BROKER" >"$BROKER_LOG" 2>&1 &
BROKER_PID=$!
i=0
until ubus list modem.smsat >/dev/null 2>&1; do
	i=$((i + 1))
	[ "$i" -lt 30 ] || fail 'broker did not register modem.smsat'
	kill -0 "$BROKER_PID" 2>/dev/null || fail 'broker exited during startup'
	sleep 1
done

capabilities="$(ubus call modem.smsat capabilities '{}')"
assert_json "$capabilities" '@.ok' 'true' 'capabilities'
assert_json "$capabilities" '@.serial_owner' 'true' 'serial owner'
assert_json "$capabilities" '@.device_delete' 'false' 'delete capability'
owner_nonce="$(printf '%s' "$capabilities" | jsonfilter -e '@.owner_nonce')"
[ -n "$owner_nonce" ] || fail 'missing owner nonce'

begin="$(ubus call modem.smsat scan_begin "$(printf '{"storage":"SM","owner_nonce":%s}' "$owner_nonce")")"
assert_json "$begin" '@.ok' 'true' 'scan begin'
scan_id="$(printf '%s' "$begin" | jsonfilter -e '@.scan_id')"
[ -n "$scan_id" ] || fail 'missing scan id'

read_one="$(ubus call modem.smsat scan_read "$(printf '{"scan_id":%s,"index":1,"owner_nonce":%s}' "$scan_id" "$owner_nonce")")"
assert_json "$read_one" '@.empty' 'false' 'first non-empty read'
assert_json "$read_one" '@.status' 'REC READ' 'first status'
assert_json "$read_one" '@.pdu' '00AABBCCDDEEFF001122' 'first PDU'
assert_json "$read_one" '@.pdu_bytes' '10' 'first PDU byte count'
assert_json "$read_one" '@.phase' '0' 'first phase'

read_two="$(ubus call modem.smsat scan_read "$(printf '{"scan_id":%s,"index":2,"owner_nonce":%s}' "$scan_id" "$owner_nonce")")"
assert_json "$read_two" '@.empty' 'true' 'classified empty read'
assert_json "$read_two" '@.phase' '1' 'first pass completion'

read_three="$(ubus call modem.smsat scan_read "$(printf '{"scan_id":%s,"index":1,"owner_nonce":%s}' "$scan_id" "$owner_nonce")")"
assert_json "$read_three" '@.empty' 'false' 'second pass non-empty read'
assert_json "$read_three" '@.phase' '1' 'second pass'

read_four="$(ubus call modem.smsat scan_read "$(printf '{"scan_id":%s,"index":2,"owner_nonce":%s}' "$scan_id" "$owner_nonce")")"
assert_json "$read_four" '@.empty' 'true' 'second pass empty read'
assert_json "$read_four" '@.complete' 'true' 'scan completion'
assert_json "$read_four" '@.phase' '2' 'final phase'

ended="$(ubus call modem.smsat scan_end "$(printf '{"scan_id":%s,"owner_nonce":%s}' "$scan_id" "$owner_nonce")")"
assert_json "$ended" '@.stable' 'true' 'stable scan end'
assert_json "$ended" '@.used' '1' 'stable used count'
assert_json "$ended" '@.total' '2' 'stable total count'

lease_begin="$(ubus call modem.smsat scan_begin "$(printf '{"storage":"SM","owner_nonce":%s}' "$owner_nonce")")"
assert_json "$lease_begin" '@.ok' 'true' 'lease timeout begin'
lease_scan_id="$(printf '%s' "$lease_begin" | jsonfilter -e '@.scan_id')"
[ -n "$lease_scan_id" ] || fail 'missing lease timeout scan id'
sleep 6
lease_read="$(ubus call modem.smsat scan_read "$(printf '{"scan_id":%s,"index":1,"owner_nonce":%s}' "$lease_scan_id" "$owner_nonce")")"
assert_json "$lease_read" '@.error_code' 'BROKER_LEASE_INVALID' 'expired lease rejection'
retry_begin="$(ubus call modem.smsat scan_begin "$(printf '{"storage":"SM","owner_nonce":%s}' "$owner_nonce")")"
assert_json "$retry_begin" '@.ok' 'true' 'post-timeout retry'
retry_scan_id="$(printf '%s' "$retry_begin" | jsonfilter -e '@.scan_id')"
[ -n "$retry_scan_id" ] || fail 'missing post-timeout scan id'
incomplete_end="$(ubus call modem.smsat scan_end "$(printf '{"scan_id":%s,"owner_nonce":%s}' "$retry_scan_id" "$owner_nonce")")"
assert_json "$incomplete_end" '@.error_code' 'BROKER_SCAN_INCOMPLETE' 'incomplete release'
released_capabilities="$(ubus call modem.smsat capabilities '{}')"
assert_json "$released_capabilities" '@.serial_owner' 'false' 'serial release after incomplete scan'

bad="$(ubus call modem.smsat scan_begin "$(printf '{"storage":"SM","owner_nonce":%s}' "$((owner_nonce + 1))")")"
assert_json "$bad" '@.error_code' 'BROKER_OWNER_INVALID' 'owner nonce rejection'

printf '%s\n' 'broker-target-integration.sh: fake-PTY, real C broker, ubus, two-pass empty scan, owner nonce and stable release passed'
