/* gptslot — A/B root-slot arithmetic for the BaseOS GPT.
 *
 * The H700 boot chain hard-codes root=/dev/mmcblk0p5 in the U-Boot environment
 * (p3), which BaseOS never modifies. That names a partition *number*, not an
 * address: nothing in boot0, U-Boot or the env references p5's start LBA, and
 * U-Boot builds the kernel cmdline's partitions= map from GPT partition
 * *names*. So the GPT itself can be the boot-slot selector — entry 5 keeps its
 * name, type GUID and unique GUID forever and only its start/end LBAs move
 * between two halves of a reserved region.
 *
 * The inactive half is unallocated space, not a partition, so A/B costs zero
 * visible partitions and is invisible to desktop operating systems.
 *
 * Geometry is derived from the GPT alone — there is no state file to lose:
 *
 *   slot_base    = boot.end + 1          (immediately after partition 4)
 *   slot_sectors = rootfs.end - rootfs.start + 1
 *   active       = A if rootfs.start == slot_base else B
 *
 * Usage:
 *   gptslot <device> geometry   print eval-able SLOT_* variables
 *   gptslot <device> flip       point `rootfs` at the inactive half
 *
 * Exit: 0 success, 2 usage/IO/invalid-layout. Fails closed on any layout that
 * is not a BaseOS A/B layout, which is what stops it applying to a pre-1.0
 * eight-partition card.
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/types.h>

#include "gpt.h"

#define IDX_BOOT 3
#define IDX_ROOTFS 4
#define IDX_AFTER 5 /* UDISK: the first partition after the slot region */

struct slots {
	uint64_t base;      /* first LBA of the two-slot region */
	uint64_t sectors;   /* sectors per slot */
	uint64_t active;    /* start LBA of the active (mounted) slot */
	uint64_t inactive;  /* start LBA of the slot being written */
	char letter;        /* 'A' or 'B' */
};

static int fail(const char *msg) {
	fprintf(stderr, "gptslot: %s\n", msg);
	return 2;
}

/* Read the primary header and entry table. Returns 0 on success. */
static int read_gpt(int fd, uint8_t *hdr, uint8_t *table) {
	if (pread(fd, hdr, SECTOR, 1 * SECTOR) != SECTOR) return -1;
	if (memcmp(hdr, "EFI PART", 8) != 0) return -1;
	if (gpt_rd32(hdr + 80) != NUM_ENTRIES || gpt_rd32(hdr + 84) != ENTRY_SIZE) return -1;
	uint64_t entries_lba = gpt_rd64(hdr + 72);
	if (pread(fd, table, TABLE_BYTES, entries_lba * SECTOR) != TABLE_BYTES) return -1;
	return 0;
}

/* Derive and validate the A/B geometry. Returns 0 on success. */
static int derive(const uint8_t *table, struct slots *s) {
	const uint8_t *boot = table + IDX_BOOT * ENTRY_SIZE;
	const uint8_t *root = table + IDX_ROOTFS * ENTRY_SIZE;
	const uint8_t *after = table + IDX_AFTER * ENTRY_SIZE;

	if (gpt_entry_empty(boot) || gpt_entry_empty(root) || gpt_entry_empty(after))
		return -1;
	if (!gpt_name_is(boot, "boot") || !gpt_name_is(root, "rootfs")) return -1;

	uint64_t root_start = gpt_rd64(root + GPT_E_START);
	uint64_t root_end = gpt_rd64(root + GPT_E_END);
	if (root_end <= root_start) return -1;

	s->base = gpt_rd64(boot + GPT_E_END) + 1;
	s->sectors = root_end - root_start + 1;

	if (root_start == s->base) {
		s->letter = 'A';
		s->active = s->base;
		s->inactive = s->base + s->sectors;
	} else if (root_start == s->base + s->sectors) {
		s->letter = 'B';
		s->active = s->base + s->sectors;
		s->inactive = s->base;
	} else {
		return -1;
	}

	/* The partition after the slot region must start exactly two slots in.
	 * A pre-1.0 layout puts `appfs` one slot in, so this is what makes an
	 * old card fail closed rather than get a slot written over its data. */
	if (gpt_rd64(after + GPT_E_START) != s->base + 2 * s->sectors) return -1;
	return 0;
}

static int commit(int fd, uint8_t *hdr, uint8_t *table) {
	uint32_t table_crc = gpt_crc32(table, TABLE_BYTES);
	uint64_t backup_hdr_lba = gpt_rd64(hdr + 32);
	uint64_t backup_entries_lba = backup_hdr_lba - 2;
	uint64_t primary_entries_lba = gpt_rd64(hdr + 72);

	uint8_t backup[SECTOR];
	if (pread(fd, backup, SECTOR, backup_hdr_lba * SECTOR) != SECTOR ||
	    memcmp(backup, "EFI PART", 8) != 0)
		return fail("no backup GPT header");
	if (gpt_rd64(backup + 72) != backup_entries_lba)
		return fail("backup GPT entry table is not where the header says");

	/* Refresh both headers' entry-table CRC, then their own CRC. Usable-LBA
	 * bounds and every other field are left exactly as found: a slot flip
	 * changes partition 5's range and nothing else. */
	gpt_wr32(hdr + 88, table_crc);
	gpt_wr32(hdr + 16, 0);
	gpt_wr32(hdr + 16, gpt_crc32(hdr, 92));
	gpt_wr32(backup + 88, table_crc);
	gpt_wr32(backup + 16, 0);
	gpt_wr32(backup + 16, gpt_crc32(backup, 92));

	/* Backup copy first. If power is lost mid-commit the primary still
	 * describes the old slot, so the device boots exactly as before —
	 * every consumer here (boot0, U-Boot, the kernel) reads the primary. */
	if (pwrite(fd, table, TABLE_BYTES, backup_entries_lba * SECTOR) != TABLE_BYTES)
		return fail("write backup entries");
	if (pwrite(fd, backup, SECTOR, backup_hdr_lba * SECTOR) != SECTOR)
		return fail("write backup header");
	if (fsync(fd) != 0) return fail("fsync backup");

	if (pwrite(fd, table, TABLE_BYTES, primary_entries_lba * SECTOR) != TABLE_BYTES)
		return fail("write primary entries");
	if (pwrite(fd, hdr, SECTOR, 1 * SECTOR) != SECTOR)
		return fail("write primary header");
	if (fsync(fd) != 0) return fail("fsync primary");
	return 0;
}

int main(int argc, char **argv) {
	if (argc != 3) {
		fprintf(stderr, "usage: gptslot <device> geometry|flip\n");
		return 2;
	}
	const char *dev = argv[1], *cmd = argv[2];
	int flip = 0;
	if (strcmp(cmd, "flip") == 0) flip = 1;
	else if (strcmp(cmd, "geometry") != 0) {
		fprintf(stderr, "usage: gptslot <device> geometry|flip\n");
		return 2;
	}

	gpt_crc32_init();

	int fd = open(dev, flip ? O_RDWR : O_RDONLY);
	if (fd < 0) return fail("cannot open device");

	uint8_t hdr[SECTOR], table[TABLE_BYTES];
	if (read_gpt(fd, hdr, table) != 0) {
		close(fd);
		return fail("no usable primary GPT");
	}

	struct slots s;
	if (derive(table, &s) != 0) {
		close(fd);
		return fail("not a BaseOS A/B layout");
	}

	if (!flip) {
		printf("SLOT_ACTIVE=%c\n", s.letter);
		printf("SLOT_BASE=%llu\n", (unsigned long long)s.base);
		printf("SLOT_SECTORS=%llu\n", (unsigned long long)s.sectors);
		printf("SLOT_ACTIVE_START=%llu\n", (unsigned long long)s.active);
		printf("SLOT_INACTIVE_START=%llu\n", (unsigned long long)s.inactive);
		close(fd);
		return 0;
	}

	uint8_t *root = table + IDX_ROOTFS * ENTRY_SIZE;
	gpt_wr64(root + GPT_E_START, s.inactive);
	gpt_wr64(root + GPT_E_END, s.inactive + s.sectors - 1);

	int rc = commit(fd, hdr, table);
	close(fd);
	if (rc != 0) return rc;

	printf("rootfs slot %c -> %c (start %llu)\n", s.letter, s.letter == 'A' ? 'B' : 'A',
	       (unsigned long long)s.inactive);
	return 0;
}
