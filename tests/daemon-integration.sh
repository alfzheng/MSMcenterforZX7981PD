#!/bin/sh
set -eu

ROOT="${1:?usage: daemon-integration.sh STAGED_REPOSITORY_ROOT}"
DAEMON="$ROOT/packages/modem-smsd/files/usr/sbin/modem-smsd"
CORE="$ROOT/packages/modem-smsd/files/usr/share/modem-sms/core.uc"
FAKE="$ROOT/tests/backend-fake.uc"
STATE='/tmp/modem-sms-daemon-test-state.json'
LOG='/tmp/modem-sms-daemon-test.log'
MODE='/tmp/modem-sms-fake-mode'
PID=''

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	[ ! -f "$LOG" ] || tail -n 80 "$LOG" >&2 || true
	exit 1
}

stop_daemon() {
	if [ -n "$PID" ]; then
		kill "$PID" 2>/dev/null || true
		wait "$PID" 2>/dev/null || true
		PID=''
	fi
	i=0
	while ubus -S list modem.sms 2>/dev/null | grep -q '^modem\.sms$'; do
		i=$((i + 1))
		[ "$i" -lt 30 ] || fail 'ubus object did not disappear after daemon stop'
		sleep 1
	done
}

cleanup() {
	stop_daemon || true
	rm -f "$STATE" "$STATE.new" "$STATE.purge-backup" "$LOG" "$MODE" \
		/tmp/modem-sms-send-1.json /tmp/modem-sms-send-2.json \
		/tmp/modem-sms-fake-blocked /tmp/modem-sms-blocked-client.json \
		/tmp/modem-sms-fake-delete-called
	rm -f /etc/config/modem-sms
	rm -f /usr/share/modem-sms/core.uc /usr/share/modem-sms/backend-lteat.uc
	rmdir /usr/share/modem-sms 2>/dev/null || true
}

start_daemon() {
	: > "$LOG"
	ucode "$DAEMON" >>"$LOG" 2>&1 &
	PID=$!
	i=0
	until ubus -S list modem.sms 2>/dev/null | grep -q '^modem\.sms$'; do
		i=$((i + 1))
		[ "$i" -lt 50 ] || fail 'daemon did not register modem.sms'
		kill -0 "$PID" 2>/dev/null || fail 'daemon exited during startup'
		sleep 1
	done
}

assert_true() {
	value="$(printf '%s' "$1" | jsonfilter -e '@.ok' 2>/dev/null || true)"
	[ "$value" = 'true' ] || fail "$2: $1"
}

wait_sent() {
	request_id="$1"
	i=0
	while [ "$i" -lt 20 ]; do
		reply="$(ubus call modem.sms status "$(printf '{"request_id":"%s"}' "$request_id")")"
		state="$(printf '%s' "$reply" | jsonfilter -e '@.state' 2>/dev/null || true)"
		[ "$state" = 'sent' ] && return 0
		[ "$state" != 'failed' ] || fail "request $request_id failed: $reply"
		i=$((i + 1))
		sleep 1
	done
	fail "request $request_id did not reach sent"
}

wait_state() {
	request_id="$1"
	expected="$2"
	i=0
	while [ "$i" -lt 20 ]; do
		reply="$(ubus call modem.sms status "$(printf '{"request_id":"%s"}' "$request_id")")"
		state="$(printf '%s' "$reply" | jsonfilter -e '@.state' 2>/dev/null || true)"
		[ "$state" = "$expected" ] && return 0
		i=$((i + 1))
		sleep 1
	done
	fail "request $request_id did not reach $expected: $reply"
}

wait_blocked() {
	expected="$1"
	i=0
	while [ "$i" -lt 10 ]; do
		value="$(cat /tmp/modem-sms-fake-blocked 2>/dev/null || true)"
		[ "$value" = "$expected" ] && return 0
		i=$((i + 1))
		sleep 1
	done
	fail "fake backend did not reach $expected"
}

wait_loaded_list() {
	box="$1"
	i=0
	while [ "$i" -lt 70 ]; do
		reply="$(ubus call modem.sms list "$(printf '{"box":"%s","storage":"ALL","limit":10,"refresh":false}' "$box")")"
		assert_true "$reply" 'list poll failed'
		loading="$(printf '%s' "$reply" | jsonfilter -e '@.loading' 2>/dev/null || true)"
		[ "$loading" != 'true' ] && {
			printf '%s' "$reply"
			return 0
		}
		i=$((i + 1))
		sleep 1
	done
	fail 'cold list did not finish within 70 seconds'
}

crash_daemon() {
	[ -n "$PID" ] || fail 'daemon PID missing at crash point'
	kill -9 "$PID"
	wait "$PID" 2>/dev/null || true
	PID=''
	i=0
	while ubus -S list modem.sms 2>/dev/null | grep -q '^modem\.sms$'; do
		i=$((i + 1))
		[ "$i" -lt 10 ] || fail 'ubus object remained after forced daemon crash'
		sleep 1
	done
}

[ "$(id -u)" = '0' ] || fail 'run as root'
[ -f "$DAEMON" ] || fail "missing daemon: $DAEMON"
[ -f "$CORE" ] || fail "missing core: $CORE"
[ -f "$FAKE" ] || fail "missing fake backend: $FAKE"
command -v ubus >/dev/null || fail 'ubus not found'
command -v ucode >/dev/null || fail 'ucode not found'
command -v jsonfilter >/dev/null || fail 'jsonfilter not found'
[ ! -e /etc/config/modem-sms ] || fail '/etc/config/modem-sms already exists; refusing to overwrite'
[ ! -e /usr/share/modem-sms ] || fail '/usr/share/modem-sms already exists; refusing to overwrite'
if ubus -S list modem.sms 2>/dev/null | grep -q '^modem\.sms$'; then
	fail 'modem.sms is already registered; refusing to disturb it'
fi

trap cleanup EXIT INT TERM
mkdir -p /usr/share/modem-sms
cp "$CORE" /usr/share/modem-sms/core.uc
cp "$FAKE" /usr/share/modem-sms/backend-lteat.uc

cat > /etc/config/modem-sms <<'EOF'
config service 'main'
	option backend 'lteat'
	option cache_seconds '60'
	option list_limit_max '200'
	option request_history_max '20'
	option minimum_free_slots '4'
	option concat_window_seconds '600'
	option send_queue_max '20'
	option send_rate_limit_seconds '0'
	option request_state_path '/tmp/modem-sms-daemon-test-state.json'

config backend 'lteat'
	option default_storage 'SM'
	option storage_order 'SM ME'
	option read_call_timeout_seconds '120'
	option send_call_timeout_seconds '120'
EOF

printf '%s\n' '[1/13] cold summary returns loading without waiting for the backend'
start_daemon
capabilities="$(ubus call modem.sms capabilities '{}')"
assert_true "$capabilities" 'capabilities failed'
delete_feature="$(printf '%s' "$capabilities" | jsonfilter -e '@.features.delete' 2>/dev/null || true)"
delete_error="$(printf '%s' "$capabilities" | jsonfilter -e '@.delete_error_code' 2>/dev/null || true)"
[ "$delete_feature" = 'false' ] && [ "$delete_error" = 'DEVICE_DELETE_DISABLED' ] || \
	fail "device delete capability did not fail closed: $capabilities"
reply="$(ubus call modem.sms summary '{}')"
assert_true "$reply" 'cold summary failed'
[ "$(printf '%s' "$reply" | jsonfilter -e '@.loaded' 2>/dev/null || true)" = 'false' ] || \
	fail "cold summary did not report an unloaded cache: $reply"
[ "$(printf '%s' "$reply" | jsonfilter -e '@.loading' 2>/dev/null || true)" = 'true' ] || \
	fail "cold summary did not return loading state: $reply"

printf '%s\n' '[2/13] cold list through real ubus daemon'
stop_daemon
start_daemon
reply="$(ubus call modem.sms list '{"box":"all","storage":"ALL","limit":10,"refresh":true}')"
assert_true "$reply" 'cold list failed'
[ "$(printf '%s' "$reply" | jsonfilter -e '@.loading' 2>/dev/null || true)" = 'true' ] || \
	fail "cold list did not return loading state: $reply"
reply="$(wait_loaded_list all)"
message_id="$(printf '%s' "$reply" | jsonfilter -e '@.messages[0].id' 2>/dev/null || true)"
[ -n "$message_id" ] || fail "cold list returned no message: $reply"

printf '%s\n' '[3/13] direct get after restart with an empty cache'
stop_daemon
start_daemon
reply="$(ubus call modem.sms get "$(printf '{"id":"%s"}' "$message_id")")"
assert_true "$reply" 'cold get failed'

printf '%s\n' '[4/13] one-storage failure preserves the successful snapshot'
printf '%s\n' 'ME_FAIL' > "$MODE"
reply="$(ubus call modem.sms list '{"box":"all","storage":"ALL","limit":10,"refresh":true}')"
assert_true "$reply" 'ME fault refresh failed'
stale="$(printf '%s' "$reply" | jsonfilter -e '@.stale' 2>/dev/null || true)"
[ "$stale" = 'true' ] || fail "ME fault did not mark response stale: $reply"
printf '%s\n' 'SM_FAIL' > "$MODE"
reply="$(ubus call modem.sms list '{"box":"all","storage":"ALL","limit":10,"refresh":true}')"
assert_true "$reply" 'SM fault refresh failed'
preserved_id="$(printf '%s' "$reply" | jsonfilter -e '@.messages[0].id' 2>/dev/null || true)"
[ "$preserved_id" = "$message_id" ] || fail "SM snapshot was lost after injected failure: $reply"
rm -f "$MODE"

printf '%s\n' '[5/13] cold send is queued only after capacity is loaded'
stop_daemon
start_daemon
reply="$(ubus call modem.sms send '{"to":"10010","text":"daemon cold send","request_id":"daemon-cold-send-0001"}')"
assert_true "$reply" 'cold send was not accepted'
wait_sent 'daemon-cold-send-0001'

printf '%s\n' '[6/13] concurrent cold sends reserve capacity independently'
stop_daemon
start_daemon
ubus call modem.sms send '{"to":"10010","text":"parallel one","request_id":"daemon-parallel-send-0001"}' >/tmp/modem-sms-send-1.json &
p1=$!
ubus call modem.sms send '{"to":"10010","text":"parallel two","request_id":"daemon-parallel-send-0002"}' >/tmp/modem-sms-send-2.json &
p2=$!
wait "$p1"
wait "$p2"
assert_true "$(cat /tmp/modem-sms-send-1.json)" 'parallel send 1 was not accepted'
assert_true "$(cat /tmp/modem-sms-send-2.json)" 'parallel send 2 was not accepted'
wait_sent 'daemon-parallel-send-0001'
wait_sent 'daemon-parallel-send-0002'

printf '%s\n' '[7/13] sent state survives daemon restart'
stop_daemon
start_daemon
reply="$(ubus call modem.sms status '{"request_id":"daemon-cold-send-0001"}')"
assert_true "$reply" 'persisted status lookup failed'
state="$(printf '%s' "$reply" | jsonfilter -e '@.state' 2>/dev/null || true)"
[ "$state" = 'sent' ] || fail "persisted request was not sent: $reply"
reference="$(printf '%s' "$reply" | jsonfilter -e '@.message_references[0]' 2>/dev/null || true)"
[ "$reference" = '42' ] || fail "message reference was not persisted: $reply"

printf '%s\n' '[8/13] explicit idempotency-history purge remains usable'
reply="$(ubus call modem.sms history_clear '{"confirm":"PURGE-IDEMPOTENCY-HISTORY"}')"
assert_true "$reply" 'history clear failed'
cleanup_pending="$(printf '%s' "$reply" | jsonfilter -e '@.cleanup_pending' 2>/dev/null || true)"
[ "$cleanup_pending" = 'false' ] || fail "history clear left cleanup pending: $reply"
sending_enabled="$(printf '%s' "$reply" | jsonfilter -e '@.sending_enabled' 2>/dev/null || true)"
[ "$sending_enabled" = 'true' ] || fail "history clear disabled sending: $reply"

printf '%s\n' '[9/13] outcome-unknown submit is terminal and durable'
printf '%s\n' 'SUBMIT_UNKNOWN' > "$MODE"
reply="$(ubus call modem.sms send '{"to":"10010","text":"unknown submit","request_id":"daemon-submit-unknown-0001"}')"
assert_true "$reply" 'unknown-outcome send was not accepted'
wait_state 'daemon-submit-unknown-0001' 'unknown'
reply="$(ubus call modem.sms status '{"request_id":"daemon-submit-unknown-0001"}')"
error_code="$(printf '%s' "$reply" | jsonfilter -e '@.error_code' 2>/dev/null || true)"
[ "$error_code" = 'SUBMIT_UNKNOWN' ] || fail "unknown-outcome send lost error code: $reply"
rm -f "$MODE"
stop_daemon
start_daemon
reply="$(ubus call modem.sms status '{"request_id":"daemon-submit-unknown-0001"}')"
state="$(printf '%s' "$reply" | jsonfilter -e '@.state' 2>/dev/null || true)"
[ "$state" = 'unknown' ] || fail "unknown outcome did not survive restart: $reply"

printf '%s\n' '[10/13] crash after durable acceptance does not auto-resend'
printf '%s\n' 'BLOCK_SEND' > "$MODE"
rm -f /tmp/modem-sms-fake-blocked
ubus call modem.sms send '{"to":"10010","text":"crash after accept","request_id":"daemon-crash-accept-0001"}' \
	>/tmp/modem-sms-blocked-client.json 2>&1 &
blocked_client=$!
wait_blocked 'BLOCK_SEND'
crash_daemon
wait "$blocked_client" 2>/dev/null || true
rm -f "$MODE" /tmp/modem-sms-fake-blocked
start_daemon
reply="$(ubus call modem.sms status '{"request_id":"daemon-crash-accept-0001"}')"
state="$(printf '%s' "$reply" | jsonfilter -e '@.state' 2>/dev/null || true)"
error_code="$(printf '%s' "$reply" | jsonfilter -e '@.error_code' 2>/dev/null || true)"
[ "$state" = 'unknown' ] && [ "$error_code" = 'INTERRUPTED_BY_RESTART' ] || \
	fail "accepted crash was not recovered safely: $reply"

printf '%s\n' '[11/13] crash during multipart submit remains unknown and is not resumed'
printf '%s\n' 'BLOCK_SECOND_SEND' > "$MODE"
rm -f /tmp/modem-sms-fake-blocked
long_text='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
payload="$(printf '{"to":"10010","text":"%s","request_id":"daemon-crash-multipart-0001"}' "$long_text")"
ubus call modem.sms send "$payload" >/tmp/modem-sms-blocked-client.json 2>&1 &
blocked_client=$!
wait_blocked 'BLOCK_SECOND_SEND'
crash_daemon
wait "$blocked_client" 2>/dev/null || true
rm -f "$MODE" /tmp/modem-sms-fake-blocked
start_daemon
reply="$(ubus call modem.sms status '{"request_id":"daemon-crash-multipart-0001"}')"
state="$(printf '%s' "$reply" | jsonfilter -e '@.state' 2>/dev/null || true)"
[ "$state" = 'unknown' ] || fail "multipart crash was not recovered as unknown: $reply"

printf '%s\n' '[12/13] legacy device delete fails closed before backend access'
rm -f /tmp/modem-sms-fake-delete-called
reply="$(ubus call modem.sms delete '{"id":"legacy-client-test","fingerprint":"obsolete"}')"
ok="$(printf '%s' "$reply" | jsonfilter -e '@.ok' 2>/dev/null || true)"
error_code="$(printf '%s' "$reply" | jsonfilter -e '@.error_code' 2>/dev/null || true)"
[ "$ok" = 'false' ] && [ "$error_code" = 'DEVICE_DELETE_DISABLED' ] || \
	fail "legacy delete did not fail closed: $reply"
[ ! -e /tmp/modem-sms-fake-delete-called ] || \
	fail "legacy delete reached fake backend: $(cat /tmp/modem-sms-fake-delete-called)"
kill -0 "$PID" 2>/dev/null || fail 'daemon exited after blocked legacy delete'

printf '%s\n' '[13/13] interrupted purge restores backup and blocks sends until cleanup'
stop_daemon
cp "$STATE" "$STATE.purge-backup"
printf '%s' '{"version":1,"requests":[]}' > "$STATE"
start_daemon
reply="$(ubus call modem.sms status '{"request_id":"daemon-crash-accept-0001"}')"
assert_true "$reply" 'purge backup did not restore request history'
reply="$(ubus call modem.sms send '{"to":"10010","text":"must remain blocked","request_id":"daemon-purge-blocked-0001"}')"
error_code="$(printf '%s' "$reply" | jsonfilter -e '@.error_code' 2>/dev/null || true)"
[ "$error_code" = 'IDEMPOTENCY_JOURNAL_UNHEALTHY' ] || fail "interrupted purge did not block sends: $reply"
reply="$(ubus call modem.sms history_clear '{"confirm":"PURGE-IDEMPOTENCY-HISTORY"}')"
assert_true "$reply" 'interrupted purge cleanup failed'
cleanup_pending="$(printf '%s' "$reply" | jsonfilter -e '@.cleanup_pending' 2>/dev/null || true)"
[ "$cleanup_pending" = 'false' ] || fail "interrupted purge cleanup remains pending: $reply"

printf '%s\n' 'PASS: 13 real modem-smsd/ubus integration tests completed with fake backend; no real SMS was sent'
