/*
 * axp-off — cut power at the AXP2202/AXP717 PMIC, bypassing PSCI and BL31.
 *
 * The kernel's own power off — reboot(RB_POWER_OFF) -> PSCI SYSTEM_OFF -> BL31
 * -> the PMU — does not stay off on this board: with VBUS present the device
 * comes back within about seven seconds, every time, reporting
 * bootreason=charger. Measured repeatedly on an RG SP. That made "plugged in
 * and idle" a five-minute boot loop, because slot's doze timeout ends in a
 * poweroff.
 *
 * Writing the PMU's own soft-poweroff bit instead stays off, on a live charger,
 * from both button and charger boots. The AXP717 datasheet (6.15.2.26) gives
 * REG 27H as:
 *
 *   7:4 reserved (RO)
 *   3   PWROK pin pull low to restart the system  0=disable 1=enable  default 0
 *   2   PWRON 16s to shutdown the PMIC            0=disable 1=enable  default 1
 *   1   restart the system                        write 1 = restart   (RWAC)
 *   0   soft PWROFF                               write 1 = power off (RWAC)
 *
 * This board runs 27H = 0x08 — both configurable bits inverted from their
 * defaults by the vendor firmware, which reprograms the register on every boot.
 * Bit 3 was suspected of causing the restart and exonerated by measurement: the
 * device stays off with bit 3 left enabled, so this preserves it.
 *
 * rcK runs this last, after the frontend is stopped, the modules are unloaded
 * and /data and the card are unmounted. Nothing downstream of the write runs.
 *
 * Safety rules, in order of how badly they end if broken:
 *
 *  - Register 0x27 is a compile-time constant. There is no general poke path
 *    and no register argument: 0x10-0x2f is dense with DCDC and LDO enables and
 *    voltages, and a stray byte there drops a rail with the case shut.
 *  - Bit 1 is masked off every write. Setting it restarts instead of powering
 *    off, which is the exact failure this tool exists to avoid.
 *  - --now is mandatory, so the binary is safe to run just to read state.
 *
 * I2C_SLAVE_FORCE is required: the axp20x-i2c driver holds address 0x34, so the
 * polite ioctl returns EBUSY. Register 0x27 is outside the driver's regmap
 * cache (which covers 0x79-0x9f), so this neither reads nor leaves stale state.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define I2C_SLAVE_FORCE 0x0706
#define BUS  "/dev/i2c-5"
#define ADDR 0x34
#define REG  0x27   /* the only register this program will ever touch */

#define SOFT_PWROFF   (1 << 0)
#define RESTART       (1 << 1)   /* masked off every write — never set this */
#define PWROK_RESTART (1 << 3)

static int rd(int fd, unsigned char *out)
{
	unsigned char reg = REG;

	if (write(fd, &reg, 1) != 1)
		return -1;
	return read(fd, out, 1) == 1 ? 0 : -1;
}

int main(int argc, char **argv)
{
	int fd, i, arm = 0, drop_pwrok = 0;
	unsigned char cur, val, back;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--now"))
			arm = 1;
		else if (!strcmp(argv[i], "--no-pwrok"))
			drop_pwrok = 1;
		else {
			fprintf(stderr, "usage: axp-off [--now] [--no-pwrok]\n");
			return 2;
		}
	}

	if ((fd = open(BUS, O_RDWR)) < 0) {
		fprintf(stderr, "axp-off: open %s: %s\n", BUS, strerror(errno));
		return 1;
	}
	if (ioctl(fd, I2C_SLAVE_FORCE, ADDR) < 0) {
		fprintf(stderr, "axp-off: I2C_SLAVE_FORCE 0x%02x: %s\n", ADDR, strerror(errno));
		return 1;
	}
	if (rd(fd, &cur)) {
		fprintf(stderr, "axp-off: read REG27H: %s\n", strerror(errno));
		return 1;
	}

	val = (unsigned char)((cur & ~RESTART) | SOFT_PWROFF);
	if (drop_pwrok)
		val &= (unsigned char)~PWROK_RESTART;

	printf("axp-off: REG27H 0x%02x -> 0x%02x\n", cur, val);
	if (!arm) {
		printf("axp-off: not armed (pass --now to cut power)\n");
		return 0;
	}

	/* Last-resort flush. The caller has already unmounted everything; this
	 * only covers what a mistake in the calling script would leave behind. */
	fflush(stdout);
	sync();

	if (write(fd, (unsigned char[]){ REG, val }, 2) != 2) {
		fprintf(stderr, "axp-off: write REG27H: %s\n", strerror(errno));
		return 1;
	}

	/* Reaching this point means the PMIC did not cut the rails, which is
	 * itself the result: the caller falls through to reboot(RB_POWER_OFF). */
	if (!rd(fd, &back))
		fprintf(stderr, "axp-off: still running after write, REG27H reads 0x%02x\n", back);
	else
		fprintf(stderr, "axp-off: still running after write, REG27H unreadable\n");
	return 1;
}
