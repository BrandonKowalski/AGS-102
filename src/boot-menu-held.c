// boot-menu-held — report whether the handheld's MENU button is held now.
//
// rcS calls this once before mounting a frontend card. H700 DTBs map the
// built-in MENU button to the standard BTN_MODE code on a BUS_HOST evdev
// device. EVIOCGKEY returns the current input-core state, so a user can hold
// MENU from power-on without a timing window, read loop, or resident daemon.
//
// Exit 0: held. Exit 1: not held or no matching built-in input device.

#include <fcntl.h>
#include <linux/input.h>
#include <stdbool.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define BITS_PER_LONG (sizeof(unsigned long) * 8U)
#define NBITS(max) (((max) / BITS_PER_LONG) + 1U)

static bool bit_is_set(const unsigned long *bits, unsigned int bit)
{
	return (bits[bit / BITS_PER_LONG] >> (bit % BITS_PER_LONG)) & 1UL;
}

static bool menu_is_held(const char *path)
{
	unsigned long supported[NBITS(KEY_MAX)] = {0};
	unsigned long pressed[NBITS(KEY_MAX)] = {0};
	struct input_id id = {0};
	int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);

	if (fd < 0)
		return false;
	if (ioctl(fd, EVIOCGID, &id) < 0 || id.bustype != BUS_HOST)
		goto not_held;
	if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(supported)), supported) < 0)
		goto not_held;
	if (!bit_is_set(supported, BTN_MODE))
		goto not_held;
	if (ioctl(fd, EVIOCGKEY(sizeof(pressed)), pressed) < 0)
		goto not_held;
	if (bit_is_set(pressed, BTN_MODE)) {
		close(fd);
		return true;
	}

not_held:
	close(fd);
	return false;
}

int main(void)
{
	char path[64];

	for (unsigned int event = 0; event < 32; ++event) {
		int length = snprintf(path, sizeof(path), "/dev/input/event%u", event);

		if (length > 0 && (size_t)length < sizeof(path) && menu_is_held(path))
			return 0;
	}
	return 1;
}
