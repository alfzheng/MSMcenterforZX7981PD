#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <libubox/blobmsg.h>
#include <libubox/uloop.h>
#include <libubus.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <uci.h>

#define CONFIG_PACKAGE "modem-sms-broker"
#define CONFIG_SECTION "main"
#define DEFAULT_OBJECT "modem.smsat"
#define DEFAULT_TTY "/dev/ttyUSB2"
#define DEFAULT_BAUD 115200
#define DEFAULT_TIMEOUT_MS 2000
#define DEFAULT_LEASE_TIMEOUT_MS 300000
#define DEFAULT_RESPONSE_LIMIT 32768
#define MAX_STORAGE 3
#define MAX_PDU 1024
#define MAX_RESPONSE 32768
#define MAX_SCAN_TOTAL 4096

struct scan_record {
	int empty;
	char status[64];
	char pdu[MAX_PDU + 1];
};

struct broker_state {
	struct ubus_context *ubus;
	struct ubus_object object;
	int fd;
	char object_name[64];
	char tty[128];
	int baud;
	int timeout_ms;
	int lease_timeout_ms;
	size_t response_limit;
	uint64_t owner_nonce;
	uint64_t generation;
	uint64_t next_scan_id;
	int active;
	uint64_t scan_id;
	char storage[MAX_STORAGE];
	int used;
	int total;
	int read_failed;
	struct scan_record *records;
	int phase;
	int next_index;
	int nonempty_count;
	int complete;
	struct uloop_timeout lease_timer;
};

static struct broker_state g_state = {
	.fd = -1,
	.object_name = DEFAULT_OBJECT,
	.tty = DEFAULT_TTY,
	.baud = DEFAULT_BAUD,
	.timeout_ms = DEFAULT_TIMEOUT_MS,
	.lease_timeout_ms = DEFAULT_LEASE_TIMEOUT_MS,
	.response_limit = DEFAULT_RESPONSE_LIMIT,
};
static struct blob_buf g_blob;

static uint64_t now_nonce(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ((uint64_t)ts.tv_sec << 32) ^ (uint64_t)ts.tv_nsec ^ (uint64_t)getpid();
}

static const char *uci_option(struct uci_context *ctx, struct uci_section *section,
	const char *name, const char *fallback, char *buffer, size_t buffer_size)
{
	struct uci_option *option = uci_lookup_option(ctx, section, name);
	if (!option || option->type != UCI_TYPE_STRING || !option->v.string)
		return fallback;
	strncpy(buffer, option->v.string, buffer_size - 1);
	buffer[buffer_size - 1] = '\0';
	return buffer;
}

static void load_config(void)
{
	struct uci_context *ctx = uci_alloc_context();
	struct uci_package *package = NULL;
	struct uci_section *section = NULL;
	char value[128];

	if (!ctx || uci_load(ctx, CONFIG_PACKAGE, &package) != UCI_OK)
		goto out;
	section = uci_lookup_section(ctx, package, CONFIG_SECTION);
	if (!section)
		goto out;

	strncpy(g_state.object_name, uci_option(ctx, section, "object", DEFAULT_OBJECT,
		value, sizeof(value)), sizeof(g_state.object_name) - 1);
	g_state.object_name[sizeof(g_state.object_name) - 1] = '\0';
	strncpy(g_state.tty, uci_option(ctx, section, "tty", DEFAULT_TTY,
		value, sizeof(value)), sizeof(g_state.tty) - 1);
	g_state.tty[sizeof(g_state.tty) - 1] = '\0';

	const char *timeout = uci_option(ctx, section, "read_timeout_ms", "2000",
		value, sizeof(value));
	char *end = NULL;
	long parsed = strtol(timeout, &end, 10);
	if (end && *end == '\0' && parsed >= 100 && parsed <= 60000)
		g_state.timeout_ms = (int)parsed;

	const char *baud = uci_option(ctx, section, "baud", "115200",
		value, sizeof(value));
	end = NULL;
	parsed = strtol(baud, &end, 10);
	if (end && *end == '\0' && (parsed == 9600 || parsed == 19200 ||
		parsed == 38400 || parsed == 57600 || parsed == 115200 || parsed == 230400))
		g_state.baud = (int)parsed;

	const char *limit = uci_option(ctx, section, "response_limit", "32768",
		value, sizeof(value));
	end = NULL;
	parsed = strtol(limit, &end, 10);
	if (end && *end == '\0' && parsed >= 1024 && parsed <= MAX_RESPONSE)
		g_state.response_limit = (size_t)parsed;

	const char *lease_timeout = uci_option(ctx, section, "lease_timeout_ms", "300000",
		value, sizeof(value));
	end = NULL;
	parsed = strtol(lease_timeout, &end, 10);
	if (end && *end == '\0' && parsed >= 1000 && parsed <= 900000)
		g_state.lease_timeout_ms = (int)parsed;

out:
	if (package)
		uci_unload(ctx, package);
	if (ctx)
		uci_free_context(ctx);
	g_state.owner_nonce = now_nonce();
}

static speed_t serial_speed(void)
{
	switch (g_state.baud) {
	case 9600: return B9600;
	case 19200: return B19200;
	case 38400: return B38400;
	case 57600: return B57600;
	case 230400: return B230400;
	default: return B115200;
	}
}

static int open_serial(void)
{
	struct termios tty;

	if (g_state.fd >= 0)
		return 0;
	g_state.fd = open(g_state.tty, O_RDWR | O_NOCTTY | O_CLOEXEC);
	if (g_state.fd < 0)
		return -errno;
	if (flock(g_state.fd, LOCK_EX | LOCK_NB) < 0) {
		int error = -errno;
		close(g_state.fd);
		g_state.fd = -1;
		return error;
	}
	if (tcgetattr(g_state.fd, &tty) < 0) {
		int error = -errno;
		close(g_state.fd);
		g_state.fd = -1;
		return error;
	}
	cfmakeraw(&tty);
	cfsetispeed(&tty, serial_speed());
	cfsetospeed(&tty, serial_speed());
	tty.c_cflag |= (CLOCAL | CREAD);
	if (tcsetattr(g_state.fd, TCSANOW, &tty) < 0) {
		int error = -errno;
		close(g_state.fd);
		g_state.fd = -1;
		return error;
	}
	tcflush(g_state.fd, TCIOFLUSH);
	return 0;
}

static void release_serial(void)
{
	if (g_state.fd < 0)
		return;
	flock(g_state.fd, LOCK_UN);
	close(g_state.fd);
	g_state.fd = -1;
}

static void reset_scan(void)
{
	free(g_state.records);
	g_state.records = NULL;
	g_state.phase = 0;
	g_state.next_index = 0;
	g_state.nonempty_count = 0;
	g_state.complete = 0;
}

static void lease_timeout_cb(struct uloop_timeout *timeout)
{
	if (!g_state.active)
		return;
	g_state.active = 0;
	g_state.read_failed = 1;
	g_state.generation++;
	release_serial();
	reset_scan();
}

static void arm_lease_timer(void)
{
	g_state.lease_timer.cb = lease_timeout_cb;
	uloop_timeout_set(&g_state.lease_timer, g_state.lease_timeout_ms);
}

static void cancel_lease_timer(void)
{
	uloop_timeout_cancel(&g_state.lease_timer);
}

static int write_all(const char *data, size_t length)
{
	while (length) {
		ssize_t written = write(g_state.fd, data, length);
		if (written > 0) {
			data += written;
			length -= (size_t)written;
			continue;
		}
		if (written < 0 && errno == EINTR)
			continue;
		return written < 0 ? -errno : -EIO;
	}
	return 0;
}

static int terminal_line(const char *line, int *is_error)
{
	while (*line == ' ' || *line == '\t' || *line == '\r')
		line++;
	if (!strncmp(line, "OK\n", 3) || !strcmp(line, "OK")) {
		*is_error = 0;
		return 1;
	}
	if (!strncmp(line, "ERROR\n", 6) || !strcmp(line, "ERROR") ||
		!strncmp(line, "+CME ERROR", 10) || !strncmp(line, "+CMS ERROR", 10)) {
		*is_error = 1;
		return 1;
	}
	return 0;
}

static int response_terminal(const char *response, int *is_error)
{
	const char *cursor = response;
	while (*cursor) {
		const char *end = strchr(cursor, '\n');
		char line[256];
		size_t length = end ? (size_t)(end - cursor + 1) : strlen(cursor);
		if (length >= sizeof(line))
			length = sizeof(line) - 1;
		memcpy(line, cursor, length);
		line[length] = '\0';
		if (terminal_line(line, is_error))
			return 1;
		if (!end)
			break;
		cursor = end + 1;
	}
	return 0;
}

static int serial_command(const char *command, char *response, size_t response_size,
	int *is_error)
{
	struct pollfd pollfd = { .fd = g_state.fd, .events = POLLIN };
	struct timespec deadline;
	char wire[256];
	size_t used = 0;
	size_t limit = g_state.response_limit;
	int result;

	if (limit > response_size)
		limit = response_size;
	if (g_state.fd < 0 || limit < 2 || strlen(command) + 2 >= sizeof(wire))
		return -EINVAL;
	if (clock_gettime(CLOCK_MONOTONIC, &deadline) < 0)
		return -errno;
	deadline.tv_sec += g_state.timeout_ms / 1000;
	deadline.tv_nsec += (long)(g_state.timeout_ms % 1000) * 1000000L;
	if (deadline.tv_nsec >= 1000000000L) {
		deadline.tv_sec++;
		deadline.tv_nsec -= 1000000000L;
	}
	memcpy(wire, command, strlen(command));
	wire[strlen(command)] = '\r';
	wire[strlen(command) + 1] = '\0';
	if (tcflush(g_state.fd, TCIOFLUSH) < 0 || write_all(wire, strlen(command) + 1) < 0)
		return -EIO;
	response[0] = '\0';
	*is_error = 0;

	for (;;) {
		struct timespec now;
		int timeout;
		if (clock_gettime(CLOCK_MONOTONIC, &now) < 0)
			return -errno;
		timeout = (int)((deadline.tv_sec - now.tv_sec) * 1000 +
			(deadline.tv_nsec - now.tv_nsec) / 1000000);
		if (timeout <= 0)
			return -ETIMEDOUT;
		result = poll(&pollfd, 1, timeout);
		if (result < 0 && errno == EINTR)
			continue;
		if (result < 0)
			return -errno;
		if (!result)
			return -ETIMEDOUT;
		if (!(pollfd.revents & POLLIN))
			return -EIO;
		ssize_t read_count = read(g_state.fd, response + used,
			limit - used - 1);
		if (read_count < 0 && errno == EINTR)
			continue;
		if (read_count <= 0)
			return -EIO;
		used += (size_t)read_count;
		response[used] = '\0';
		if (response_terminal(response, is_error))
			return 0;
		if (used + 1 >= limit)
			return -E2BIG;
	}
}

static int parse_capacity(const char *response, int *used, int *total)
{
	const char *line = strstr(response, "+CPMS:");
	if (!line)
		return -EINVAL;
	if (sscanf(line, "+CPMS: \"%*[^\"]\",%d,%d", used, total) == 2)
		return 0;
	if (sscanf(line, "+CPMS: %d,%d", used, total) == 2)
		return 0;
	return -EINVAL;
}

static int valid_storage(const char *storage)
{
	return storage && (!strcmp(storage, "SM") || !strcmp(storage, "ME"));
}

static int select_storage(const char *storage, char *response, size_t response_size,
	int *is_error, int *used, int *total)
{
	char command[64];
	if (!valid_storage(storage))
		return -EINVAL;
	snprintf(command, sizeof(command), "AT+CPMS=\"%s\",\"%s\",\"%s\"",
		storage, storage, storage);
	int result = serial_command(command, response, response_size, is_error);
	if (result || *is_error)
		return result ? result : -EIO;
	return parse_capacity(response, used, total);
}

static int hex_line(const char *line, char *pdu, size_t pdu_size)
{
	size_t out = 0;
	while (*line && *line != '\r' && *line != '\n') {
		if (*line == ' ' || *line == '\t') {
			line++;
			continue;
		}
		if (!((*line >= '0' && *line <= '9') || (*line >= 'A' && *line <= 'F') ||
			(*line >= 'a' && *line <= 'f')) || out + 1 >= pdu_size)
			return -EINVAL;
		pdu[out++] = *line++;
	}
	if (out < 20 || out % 2)
		return -EINVAL;
	pdu[out] = '\0';
	for (size_t i = 0; i < out; i++)
		if (pdu[i] >= 'a' && pdu[i] <= 'f')
			pdu[i] = (char)(pdu[i] - 'a' + 'A');
	return (int)out;
}

static int parse_cmgr(const char *response, char *status, size_t status_size,
	char *pdu, size_t pdu_size, int *pdu_bytes)
{
	const char *header = strstr(response, "+CMGR:");
	const char *cursor = response;
	char header_line[256];
	char *last_comma, *end_number;
	long declared_length;
	int pdu_chars = 0;
	if (!header)
		return -EINVAL;
	const char *header_end = strchr(header, '\n');
	size_t header_length = header_end ? (size_t)(header_end - header) : strlen(header);
	if (header_length >= sizeof(header_line))
		return -EINVAL;
	memcpy(header_line, header, header_length);
	header_line[header_length] = '\0';
	while (header_length && (header_line[header_length - 1] == '\r' ||
		header_line[header_length - 1] == ' ' || header_line[header_length - 1] == '\t'))
		header_line[--header_length] = '\0';
	last_comma = strrchr(header_line, ',');
	if (!last_comma)
		return -EINVAL;
	declared_length = strtol(last_comma + 1, &end_number, 10);
	while (*end_number == ' ' || *end_number == '\t')
		end_number++;
	if (end_number == last_comma + 1 || *end_number || declared_length < 0 ||
		declared_length > MAX_PDU / 2)
		return -EINVAL;
	header += strlen("+CMGR:");
	while (*header == ' ' || *header == '\t')
		header++;
	if (*header == '"')
		header++;
	const char *status_end = strchr(header, '"');
	if (!status_end)
		status_end = strchr(header, ',');
	if (!status_end || (size_t)(status_end - header) >= status_size)
		return -EINVAL;
	memcpy(status, header, (size_t)(status_end - header));
	status[status_end - header] = '\0';

	while (*cursor) {
		const char *end = strchr(cursor, '\n');
		char line[1100];
		size_t length = end ? (size_t)(end - cursor) : strlen(cursor);
		if (length >= sizeof(line))
			length = sizeof(line) - 1;
		memcpy(line, cursor, length);
		line[length] = '\0';
		int line_chars = hex_line(line, pdu, pdu_size);
		if (line_chars > 0) {
			if (pdu_chars || line_chars % 2)
				return -EINVAL;
			pdu_chars = line_chars;
		}
		if (!end)
			break;
		cursor = end + 1;
	}
	if (!pdu_chars)
		return -EINVAL;
	unsigned int smsc_length = 0;
	if (sscanf(pdu, "%2x", &smsc_length) != 1)
		return -EINVAL;
	*pdu_bytes = pdu_chars / 2;
	if (*pdu_bytes != (int)(1 + smsc_length + declared_length))
		return -EMSGSIZE;
	return 0;
}

static void reply_error(struct ubus_context *ctx, struct ubus_request_data *request,
	const char *error, int status)
{
	blob_buf_init(&g_blob, 0);
	blobmsg_add_u32(&g_blob, "schema_version", 1);
	blobmsg_add_u8(&g_blob, "ok", 0);
	blobmsg_add_string(&g_blob, "error_code", error);
	if (status)
		blobmsg_add_u32(&g_blob, "backend_status", (uint32_t)status);
	ubus_send_reply(ctx, request, g_blob.head);
}

static int method_capabilities(struct ubus_context *ctx, struct ubus_object *object,
	struct ubus_request_data *request, const char *method, struct blob_attr *message)
{
	blob_buf_init(&g_blob, 0);
	blobmsg_add_u32(&g_blob, "schema_version", 1);
	blobmsg_add_u8(&g_blob, "ok", g_state.fd >= 0);
	blobmsg_add_string(&g_blob, "backend_id", "smsat-v1");
	blobmsg_add_string(&g_blob, "transport", "exclusive-tty");
	blobmsg_add_u8(&g_blob, "serial_owner", 1);
	blobmsg_add_u8(&g_blob, "serial_ready", g_state.fd >= 0);
	blobmsg_add_u64(&g_blob, "owner_nonce", g_state.owner_nonce);
	blobmsg_add_u8(&g_blob, "indexed_read", 1);
	blobmsg_add_u8(&g_blob, "device_delete", 0);
	return ubus_send_reply(ctx, request, g_blob.head);
}

enum {
	BEGIN_STORAGE,
	__BEGIN_MAX
};
static const struct blobmsg_policy begin_policy[__BEGIN_MAX] = {
	[BEGIN_STORAGE] = { .name = "storage", .type = BLOBMSG_TYPE_STRING },
};

static int method_scan_begin(struct ubus_context *ctx, struct ubus_object *object,
	struct ubus_request_data *request, const char *method, struct blob_attr *message)
{
	struct blob_attr *tb[__BEGIN_MAX];
	char response[MAX_RESPONSE];
	int is_error = 0, used = 0, total = 0, result;
	blobmsg_parse(begin_policy, __BEGIN_MAX, tb, blob_data(message), blob_len(message));
	if (!tb[BEGIN_STORAGE] || g_state.active) {
		reply_error(ctx, request, g_state.active ? "BROKER_BUSY" : "INVALID_STORAGE", -EINVAL);
		return 0;
	}
	const char *storage = blobmsg_get_string(tb[BEGIN_STORAGE]);
	if (!valid_storage(storage)) {
		reply_error(ctx, request, "INVALID_STORAGE", -EINVAL);
		return 0;
	}
	result = open_serial();
	if (result) {
		reply_error(ctx, request, "BROKER_TTY_UNAVAILABLE", result);
		return 0;
	}
	result = select_storage(storage, response, sizeof(response), &is_error, &used, &total);
	if (result || used < 0 || total < 0 || used > total) {
		release_serial();
		reply_error(ctx, request, result == -E2BIG ? "BROKER_RESPONSE_TOO_LARGE" :
			"BROKER_CPMS_FAILED", result ? result : -EINVAL);
		return 0;
	}
	if (total > MAX_SCAN_TOTAL) {
		release_serial();
		reply_error(ctx, request, "BROKER_CAPACITY_UNSUPPORTED", -E2BIG);
		return 0;
	}
	reset_scan();
	g_state.records = calloc((size_t)total + 1, sizeof(*g_state.records));
	if (!g_state.records) {
		release_serial();
		reply_error(ctx, request, "BROKER_MEMORY_FAILED", -ENOMEM);
		return 0;
	}
	g_state.active = 1;
	g_state.scan_id = ++g_state.next_scan_id;
	g_state.generation++;
	strncpy(g_state.storage, storage, sizeof(g_state.storage) - 1);
	g_state.used = used;
	g_state.total = total;
	g_state.read_failed = 0;
	g_state.phase = total ? 0 : 2;
	g_state.next_index = total ? 1 : 0;
	g_state.nonempty_count = 0;
	g_state.complete = total ? 0 : 1;
	arm_lease_timer();
	blob_buf_init(&g_blob, 0);
	blobmsg_add_u32(&g_blob, "schema_version", 1);
	blobmsg_add_u8(&g_blob, "ok", 1);
	blobmsg_add_u64(&g_blob, "scan_id", g_state.scan_id);
	blobmsg_add_u64(&g_blob, "generation", g_state.generation);
	blobmsg_add_string(&g_blob, "storage", g_state.storage);
	blobmsg_add_u32(&g_blob, "used", (uint32_t)used);
	blobmsg_add_u32(&g_blob, "total", (uint32_t)total);
	return ubus_send_reply(ctx, request, g_blob.head);
}

enum {
	READ_SCAN_ID,
	READ_INDEX,
	__READ_MAX
};
static const struct blobmsg_policy read_policy[__READ_MAX] = {
	[READ_SCAN_ID] = { .name = "scan_id", .type = BLOBMSG_TYPE_INT64 },
	[READ_INDEX] = { .name = "index", .type = BLOBMSG_TYPE_INT32 },
};

static int method_scan_read(struct ubus_context *ctx, struct ubus_object *object,
	struct ubus_request_data *request, const char *method, struct blob_attr *message)
{
	struct blob_attr *tb[__READ_MAX];
	char response[MAX_RESPONSE], command[64], status[64], pdu[MAX_PDU + 1];
	struct scan_record current = { 0 };
	int is_error = 0, result, pdu_bytes = 0, pass_complete = 0;
	blobmsg_parse(read_policy, __READ_MAX, tb, blob_data(message), blob_len(message));
	if (!g_state.active || !tb[READ_SCAN_ID] || !tb[READ_INDEX] ||
		blobmsg_get_u64(tb[READ_SCAN_ID]) != g_state.scan_id) {
		reply_error(ctx, request, "BROKER_LEASE_INVALID", -EINVAL);
		return 0;
	}
	if (g_state.read_failed) {
		reply_error(ctx, request, "BROKER_SCAN_ABORTED", -EPIPE);
		return 0;
	}
	if (g_state.complete) {
		reply_error(ctx, request, "BROKER_SCAN_COMPLETE", -EALREADY);
		return 0;
	}
	int index = (int)blobmsg_get_u32(tb[READ_INDEX]);
	if (index < 1 || index > g_state.total || index != g_state.next_index) {
		g_state.read_failed = 1;
		reply_error(ctx, request, index < 1 || index > g_state.total ?
			"INDEX_OUT_OF_RANGE" : "BROKER_SCAN_ORDER", -EINVAL);
		return 0;
	}
	snprintf(command, sizeof(command), "AT+CMGR=%d", index);
	result = serial_command(command, response, sizeof(response), &is_error);
	if (result == -E2BIG) {
		g_state.read_failed = 1;
		reply_error(ctx, request, "BROKER_RESPONSE_TOO_LARGE", result);
		return 0;
	}
	if (result == -ETIMEDOUT) {
		g_state.read_failed = 1;
		reply_error(ctx, request, "BROKER_READ_TIMEOUT", result);
		return 0;
	}
	if (result) {
		g_state.read_failed = 1;
		reply_error(ctx, request, "BROKER_READ_FAILED", result);
		return 0;
	}
	if (is_error) {
		/* A generic AT error is not proof that the slot is empty. */
		g_state.read_failed = 1;
		reply_error(ctx, request, "BROKER_EMPTY_UNCERTAIN", -EBADE);
		return 0;
	}
	result = parse_cmgr(response, status, sizeof(status), pdu, sizeof(pdu), &pdu_bytes);
	if (result) {
		g_state.read_failed = 1;
		reply_error(ctx, request, result == -EMSGSIZE ?
			"BROKER_PDU_LENGTH_MISMATCH" : "BROKER_READ_PARSE_FAILED", result);
		return 0;
	}
	current.empty = 0;
	strncpy(current.status, status, sizeof(current.status) - 1);
	strncpy(current.pdu, pdu, sizeof(current.pdu) - 1);
	if (g_state.phase == 0) {
		g_state.records[index] = current;
		g_state.nonempty_count++;
	} else if (g_state.phase == 1) {
		if (g_state.records[index].empty != current.empty ||
			strcmp(g_state.records[index].status, current.status) ||
			strcmp(g_state.records[index].pdu, current.pdu)) {
			g_state.read_failed = 1;
			reply_error(ctx, request, "BROKER_SCAN_CONTENT_CHANGED", -ESTALE);
			return 0;
		}
		g_state.nonempty_count++;
	}
	g_state.next_index++;
	if (g_state.next_index > g_state.total) {
		pass_complete = 1;
		if (g_state.nonempty_count != g_state.used) {
			g_state.read_failed = 1;
			reply_error(ctx, request, "BROKER_COUNT_MISMATCH", -EBADMSG);
			return 0;
		}
		if (g_state.phase == 0) {
			g_state.phase = 1;
			g_state.next_index = 1;
			g_state.nonempty_count = 0;
		} else {
			g_state.phase = 2;
			g_state.next_index = 0;
			g_state.complete = 1;
		}
	}
	if (!g_state.complete)
		arm_lease_timer();
	blob_buf_init(&g_blob, 0);
	blobmsg_add_u32(&g_blob, "schema_version", 1);
	blobmsg_add_u8(&g_blob, "ok", 1);
	blobmsg_add_u8(&g_blob, "empty", 0);
	blobmsg_add_u32(&g_blob, "index", (uint32_t)index);
	blobmsg_add_string(&g_blob, "status", current.status);
	blobmsg_add_string(&g_blob, "pdu", current.pdu);
	blobmsg_add_u32(&g_blob, "pdu_bytes", (uint32_t)pdu_bytes);
	blobmsg_add_u8(&g_blob, "pass_complete", pass_complete);
	blobmsg_add_u8(&g_blob, "complete", g_state.complete);
	blobmsg_add_u8(&g_blob, "phase", (uint8_t)g_state.phase);
	return ubus_send_reply(ctx, request, g_blob.head);
}

enum {
	END_SCAN_ID,
	__END_MAX
};
static const struct blobmsg_policy end_policy[__END_MAX] = {
	[END_SCAN_ID] = { .name = "scan_id", .type = BLOBMSG_TYPE_INT64 },
};

static int method_scan_end(struct ubus_context *ctx, struct ubus_object *object,
	struct ubus_request_data *request, const char *method, struct blob_attr *message)
{
	struct blob_attr *tb[__END_MAX];
	char response[MAX_RESPONSE];
	int is_error = 0, used = 0, total = 0, result;
	blobmsg_parse(end_policy, __END_MAX, tb, blob_data(message), blob_len(message));
	if (!g_state.active || !tb[END_SCAN_ID] ||
		blobmsg_get_u64(tb[END_SCAN_ID]) != g_state.scan_id) {
		reply_error(ctx, request, "BROKER_LEASE_INVALID", -EINVAL);
		return 0;
	}
	result = select_storage(g_state.storage, response, sizeof(response), &is_error, &used, &total);
	int scan_complete = g_state.complete;
	int read_failed = g_state.read_failed;
	int stable = scan_complete && !result && !is_error && !read_failed &&
		used == g_state.used && total == g_state.total;
	g_state.active = 0;
	cancel_lease_timer();
	release_serial();
	if (!stable) {
		const char *error_code = result ? "BROKER_CPMS_RECHECK_FAILED" :
			(is_error ? "BROKER_CPMS_RECHECK_FAILED" :
			(!scan_complete ? "BROKER_SCAN_INCOMPLETE" :
			(read_failed ? "BROKER_SCAN_INCOMPLETE" : "BROKER_CAPACITY_CHANGED")));
		reset_scan();
		reply_error(ctx, request,
			error_code,
			result ? result : -ESTALE);
		return 0;
	}
	reset_scan();
	blob_buf_init(&g_blob, 0);
	blobmsg_add_u32(&g_blob, "schema_version", 1);
	blobmsg_add_u8(&g_blob, "ok", 1);
	blobmsg_add_u8(&g_blob, "stable", 1);
	blobmsg_add_u64(&g_blob, "generation", g_state.generation);
	blobmsg_add_u32(&g_blob, "used", (uint32_t)used);
	blobmsg_add_u32(&g_blob, "total", (uint32_t)total);
	return ubus_send_reply(ctx, request, g_blob.head);
}

static const struct ubus_method broker_methods[] = {
	UBUS_METHOD_NOARG("capabilities", method_capabilities),
	UBUS_METHOD("scan_begin", method_scan_begin, begin_policy),
	UBUS_METHOD("scan_read", method_scan_read, read_policy),
	UBUS_METHOD("scan_end", method_scan_end, end_policy),
};

static struct ubus_object_type broker_object_type =
	UBUS_OBJECT_TYPE("modem_sms_broker", broker_methods);

static void signal_handler(int signal)
{
	uloop_end();
}

int main(void)
{
	int result;
	load_config();
	open_serial();
	uloop_init();
	signal(SIGTERM, signal_handler);
	signal(SIGINT, signal_handler);
	g_state.ubus = ubus_connect(NULL);
	if (!g_state.ubus) {
		fprintf(stderr, "modem-sms-broker: ubus unavailable\n");
		return 1;
	}
	ubus_add_uloop(g_state.ubus);
	g_state.object.name = g_state.object_name;
	g_state.object.type = &broker_object_type;
	g_state.object.methods = broker_methods;
	g_state.object.n_methods = sizeof(broker_methods) / sizeof(broker_methods[0]);
	result = ubus_add_object(g_state.ubus, &g_state.object);
	if (result) {
		fprintf(stderr, "modem-sms-broker: ubus registration failed: %d\n", result);
		ubus_free(g_state.ubus);
		return 1;
	}
	uloop_run();
	cancel_lease_timer();
	release_serial();
	reset_scan();
	ubus_free(g_state.ubus);
	uloop_done();
	return 0;
}
