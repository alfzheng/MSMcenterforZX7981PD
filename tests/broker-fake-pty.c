#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static volatile sig_atomic_t running = 1;

static void stop_handler(int signal_number)
{
	(void)signal_number;
	running = 0;
}

static int write_all(int fd, const char *data)
{
	size_t length = strlen(data);
	while (length) {
		ssize_t written = write(fd, data, length);
		if (written > 0) {
			data += written;
			length -= (size_t)written;
			continue;
		}
		if (written < 0 && errno == EINTR)
			continue;
		return -1;
	}
	return 0;
}

static void reply(int master, const char *command)
{
	dprintf(STDERR_FILENO, "RX:%s\n", command);
	if (!strncmp(command, "AT+CPMS=\"ME\"", 12)) {
		write_all(master, "\r\n+CPMS: \"ME\",0,2\r\nOK\r\n");
		dprintf(STDERR_FILENO, "TX:ME\n");
		return;
	}
	if (!strncmp(command, "AT+CPMS=\"SM\"", 12)) {
		write_all(master, "\r\n+CPMS: \"SM\",1,2\r\nOK\r\n");
		dprintf(STDERR_FILENO, "TX:SM\n");
		return;
	}
	if (!strcmp(command, "AT+CMGR=1")) {
		write_all(master, "\r\n+CMGR: \"REC READ\",,,9\r\n00AABBCCDDEEFF001122\r\nOK\r\n");
		dprintf(STDERR_FILENO, "TX:CMGR1\n");
		return;
	}
	if (!strcmp(command, "AT+CMGR=2")) {
		write_all(master, "\r\n+CMS ERROR: 321\r\n");
		dprintf(STDERR_FILENO, "TX:EMPTY\n");
		return;
	}
	write_all(master, "\r\nERROR\r\n");
	dprintf(STDERR_FILENO, "TX:ERROR\n");
}

int main(int argc, char **argv)
{
	const char *link_path = argc > 1 ? argv[1] : "/tmp/modem-sms-fake-tty";
	int master = -1;
	char command[256];
	size_t used = 0;
	char *slave;

	signal(SIGTERM, stop_handler);
	signal(SIGINT, stop_handler);
	master = posix_openpt(O_RDWR | O_NOCTTY);
	if (master < 0 || grantpt(master) < 0 || unlockpt(master) < 0)
		return 1;
	slave = ptsname(master);
	if (!slave || (unlink(link_path) < 0 && errno != ENOENT) || symlink(slave, link_path) < 0) {
		close(master);
		return 1;
	}
	printf("FAKE_PTY=%s\n", link_path);
	fflush(stdout);

	while (running) {
		char buffer[128];
		ssize_t read_count = read(master, buffer, sizeof(buffer));
		if (read_count < 0 && (errno == EINTR || errno == EIO)) {
			usleep(10000);
			continue;
		}
		if (read_count <= 0)
			break;
		for (ssize_t i = 0; i < read_count; i++) {
			if (buffer[i] == '\r') {
				command[used] = '\0';
				reply(master, command);
				used = 0;
			}
			else if (buffer[i] != '\n' && used + 1 < sizeof(command))
				command[used++] = buffer[i];
		}
	}

	unlink(link_path);
	close(master);
	return 0;
}
