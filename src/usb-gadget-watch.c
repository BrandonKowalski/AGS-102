/*
 * Keep the H700 adb configfs gadget bound across USB-C disconnects.
 *
 * The vendor sunxi OTG manager clears usb_gadget/g1/UDC whenever VBUS drops.
 * Re-writing the UDC name is sufficient to enumerate again, but polling would
 * add a permanent timer wake and CONFIG_UEVENT_HELPER would fork a shell for
 * every kernel event. This process blocks on NETLINK_KOBJECT_UEVENT instead,
 * filters events in-process, and runs the idempotent shell rebind action only
 * while the gadget is actually unbound.
 */

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/netlink.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define UEVENT_BUFFER_SIZE 8192

static const char *sys_root(void)
{
	const char *root = getenv("BASEOS_SYS_ROOT");

	return root && root[0] ? root : "/sys";
}

static const char *rebind_program(void)
{
	const char *program = getenv("BASEOS_REBIND_PROGRAM");

	return program && program[0] ? program : "/usr/sbin/usb-gadget-adb";
}

static int gadget_udc_path(char *path, size_t size)
{
	int written = snprintf(path, size,
			       "%s/kernel/config/usb_gadget/g1/UDC", sys_root());

	return written > 0 && (size_t)written < size ? 0 : -1;
}

static bool gadget_is_unbound(void)
{
	char path[512];
	char value[128];
	int fd;
	ssize_t size;

	if (gadget_udc_path(path, sizeof(path)) < 0)
		return false;

	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return false;
	size = read(fd, value, sizeof(value));
	close(fd);

	if (size <= 0)
		return size == 0;
	for (ssize_t i = 0; i < size; i++) {
		if (!isspace((unsigned char)value[i]))
			return false;
	}
	return true;
}

static int run_rebind(void)
{
	pid_t pid;
	int status;

	if (!gadget_is_unbound())
		return 0;

	pid = fork();
	if (pid < 0)
		return -1;
	if (pid == 0) {
		const char *program = rebind_program();

		execl(program, program, "rebind", (char *)NULL);
		_exit(127);
	}

	while (waitpid(pid, &status, 0) < 0) {
		if (errno != EINTR)
			return -1;
	}
	return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
}

static bool event_has_field(const char *buf, ssize_t size, const char *field)
{
	size_t field_size = strlen(field);
	ssize_t offset = 0;

	while (offset < size) {
		const char *item = buf + offset;
		size_t item_size = strnlen(item, (size_t)(size - offset));

		if (item_size == field_size && !memcmp(item, field, field_size))
			return true;
		offset += (ssize_t)item_size + 1;
	}
	return false;
}

static bool event_can_change_usb_role(const char *buf, ssize_t size)
{
	return event_has_field(buf, size, "SUBSYSTEM=power_supply")
		|| event_has_field(buf, size, "SUBSYSTEM=android_usb")
		|| event_has_field(buf, size, "SUBSYSTEM=udc");
}

static int open_uevent_socket(void)
{
	struct sockaddr_nl addr = {
		.nl_family = AF_NETLINK,
		.nl_pid = (unsigned int)getpid(),
		.nl_groups = 1,
	};
	int fd = socket(AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC,
			NETLINK_KOBJECT_UEVENT);

	if (fd < 0)
		return -1;
	if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		close(fd);
		return -1;
	}
	return fd;
}

int main(int argc, char **argv)
{
	int fd;

	if (argc == 2 && !strcmp(argv[1], "--once"))
		return run_rebind() == 0 ? 0 : 1;
	if (argc != 1)
		return 2;

	fd = open_uevent_socket();
	if (fd < 0)
		return 1;

	/* Cover a disconnect that happened immediately before the socket bind. */
	run_rebind();

	for (;;) {
		char buf[UEVENT_BUFFER_SIZE];
		struct sockaddr_nl source = { 0 };
		struct iovec iov = {
			.iov_base = buf,
			.iov_len = sizeof(buf) - 1,
		};
		struct msghdr msg = {
			.msg_name = &source,
			.msg_namelen = sizeof(source),
			.msg_iov = &iov,
			.msg_iovlen = 1,
		};
		ssize_t size = recvmsg(fd, &msg, 0);

		if (size < 0) {
			if (errno == EINTR)
				continue;
			close(fd);
			return 1;
		}
		if (size == 0 || (msg.msg_flags & MSG_TRUNC) || source.nl_pid != 0)
			continue;

		buf[size] = '\0';
		if (event_can_change_usb_role(buf, size))
			run_rebind();
	}
}
