// gptgrow — grow the last GPT partition to fill the whole disk.
//
//   gptgrow /dev/mmcblk0
//
// Reads the primary GPT, extends the highest-numbered partition's ending LBA to
// the last usable sector of the actual device, and rewrites both the primary
// and backup GPTs (headers + entry tables) with corrected CRCs, plus the
// protective MBR size. Idempotent: exits 1 (no change) if already at the end,
// 0 if it grew the partition, 2 on error. Zero dependencies (static).
//
// Layout conventions match tools/mkgpt.py (verified on H700 hardware): 8 entries
// of 128 bytes at LBA 2-3, first usable LBA 4; backup entries at total-3..-2,
// backup header at total-1, last usable = total-4.
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/blkpg.h>

#define SECTOR 512
#define NUM_ENTRIES 8
#define ENTRY_SIZE 128

static uint32_t crc32_tab[256];
static void crc32_init(void) {
	for (uint32_t i = 0; i < 256; i++) {
		uint32_t c = i;
		for (int k = 0; k < 8; k++)
			c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
		crc32_tab[i] = c;
	}
}
static uint32_t crc32(const uint8_t *p, size_t n) {
	uint32_t c = 0xFFFFFFFFu;
	for (size_t i = 0; i < n; i++)
		c = crc32_tab[(c ^ p[i]) & 0xff] ^ (c >> 8);
	return c ^ 0xFFFFFFFFu;
}

static uint64_t rd64(const uint8_t *p) {
	uint64_t v = 0;
	for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
	return v;
}
static void wr64(uint8_t *p, uint64_t v) {
	for (int i = 0; i < 8; i++) { p[i] = v & 0xff; v >>= 8; }
}
static uint32_t rd32(const uint8_t *p) {
	return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24);
}
static void wr32(uint8_t *p, uint32_t v) {
	for (int i = 0; i < 4; i++) { p[i] = v & 0xff; v >>= 8; }
}

int main(int argc, char **argv) {
	if (argc < 2) { fprintf(stderr, "usage: gptgrow /dev/blk\n"); return 2; }
	crc32_init();

	int fd = open(argv[1], O_RDWR);
	if (fd < 0) { perror("open"); return 2; }

	off_t bytes = lseek(fd, 0, SEEK_END);
	if (bytes <= 0) { fprintf(stderr, "cannot size device\n"); return 2; }
	uint64_t total = (uint64_t)bytes / SECTOR;

	uint8_t hdr[SECTOR];
	if (pread(fd, hdr, SECTOR, 1 * SECTOR) != SECTOR) { perror("read gpt"); return 2; }
	if (memcmp(hdr, "EFI PART", 8) != 0) { fprintf(stderr, "no primary GPT\n"); return 2; }

	uint64_t entries_lba = rd64(hdr + 72);
	uint32_t n_entries = rd32(hdr + 80), esz = rd32(hdr + 84);
	if (n_entries != NUM_ENTRIES || esz != ENTRY_SIZE) {
		fprintf(stderr, "unexpected GPT shape %u x %u\n", n_entries, esz);
		return 2;
	}

	uint8_t table[NUM_ENTRIES * ENTRY_SIZE];
	if (pread(fd, table, sizeof(table), entries_lba * SECTOR) != (ssize_t)sizeof(table)) {
		perror("read entries"); return 2;
	}

	// Highest-numbered non-empty partition = the one we grow.
	int last = -1;
	for (int i = 0; i < NUM_ENTRIES; i++) {
		const uint8_t *e = table + i * ENTRY_SIZE;
		int empty = 1;
		for (int j = 0; j < 16; j++) if (e[j]) { empty = 0; break; }
		if (!empty) last = i;
	}
	if (last < 0) { fprintf(stderr, "no partitions\n"); return 2; }

	uint64_t last_usable = total - 4;
	uint8_t *e = table + last * ENTRY_SIZE;
	uint64_t cur_end = rd64(e + 40);
	uint64_t start = rd64(e + 32);
	if (cur_end >= last_usable) {
		printf("p%d already fills disk (end=%llu, last_usable=%llu)\n",
		       last + 1, (unsigned long long)cur_end, (unsigned long long)last_usable);
		return 1;
	}
	if (start >= last_usable) { fprintf(stderr, "partition start past disk end\n"); return 2; }

	wr64(e + 40, last_usable);

	uint32_t table_crc = crc32(table, sizeof(table));
	uint64_t backup_entries_lba = total - 3;
	uint64_t backup_hdr_lba = total - 1;

	// Build a header for either copy: current_lba, other_lba, entries_lba vary.
	uint8_t out[SECTOR];
	for (int copy = 0; copy < 2; copy++) {
		memset(out, 0, SECTOR);
		memcpy(out, hdr, 92);
		wr32(out + 16, 0);  // header CRC placeholder
		if (copy == 0) {
			wr64(out + 24, 1); wr64(out + 32, backup_hdr_lba); wr64(out + 72, 2);
		} else {
			wr64(out + 24, backup_hdr_lba); wr64(out + 32, 1); wr64(out + 72, backup_entries_lba);
		}
		wr64(out + 40, 4);            // first usable
		wr64(out + 48, last_usable);  // last usable
		wr32(out + 88, table_crc);
		wr32(out + 16, crc32(out, 92));
		uint64_t at = (copy == 0) ? 1 : backup_hdr_lba;
		if (pwrite(fd, out, SECTOR, at * SECTOR) != SECTOR) { perror("write hdr"); return 2; }
	}
	if (pwrite(fd, table, sizeof(table), 2 * SECTOR) != (ssize_t)sizeof(table)) { perror("write pri entries"); return 2; }
	if (pwrite(fd, table, sizeof(table), backup_entries_lba * SECTOR) != (ssize_t)sizeof(table)) { perror("write bak entries"); return 2; }

	// Protective MBR: cover the whole disk.
	uint8_t mbr[SECTOR];
	if (pread(fd, mbr, SECTOR, 0) == SECTOR) {
		uint32_t sz = total - 1 > 0xFFFFFFFFu ? 0xFFFFFFFFu : (uint32_t)(total - 1);
		wr32(mbr + 446 + 12, sz);
		pwrite(fd, mbr, SECTOR, 0);
	}

	fsync(fd);

	// Live-resize the partition in the kernel so /dev/<disk>pN reflects the new
	// size without a full partition-table reread — which the kernel refuses
	// while a sibling partition (the mounted rootfs) is busy. Harmless ENOTTY
	// when run against a regular file (offline testing).
	struct blkpg_partition part;
	memset(&part, 0, sizeof(part));
	part.start = (long long)start * SECTOR;
	part.length = (long long)(last_usable - start + 1) * SECTOR;
	part.pno = last + 1;
	struct blkpg_ioctl_arg arg;
	memset(&arg, 0, sizeof(arg));
	arg.op = BLKPG_RESIZE_PARTITION;
	arg.datalen = sizeof(part);
	arg.data = &part;
	if (ioctl(fd, BLKPG, &arg) != 0)
		perror("BLKPG resize (kernel view unchanged; reread may be needed)");

	close(fd);
	printf("p%d grown: end %llu -> %llu (disk %llu sectors)\n",
	       last + 1, (unsigned long long)cur_end, (unsigned long long)last_usable,
	       (unsigned long long)total);
	return 0;
}
