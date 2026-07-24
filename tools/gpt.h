/* Shared GPT primitives for BaseOS partition tools.
 *
 * Header-only, zero-dependency, freestanding-friendly: the tools that use it
 * are built with `gcc -static -O2` into the rootfs (see build-tools.sh).
 *
 * NOTE: gptgrow.c deliberately still carries its own copies of these helpers.
 * It is hardware-proven on the first-boot path and has no offline regression
 * test of its own, so it is not worth refactoring for 40 shared lines. Migrate
 * it here once it has one.
 */
#ifndef BASEOS_GPT_H
#define BASEOS_GPT_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#define SECTOR 512
#define NUM_ENTRIES 8
#define ENTRY_SIZE 128
#define TABLE_BYTES (NUM_ENTRIES * ENTRY_SIZE)

/* Entry field offsets. */
#define GPT_E_TYPE 0
#define GPT_E_START 32
#define GPT_E_END 40
#define GPT_E_ATTR 48
#define GPT_E_NAME 56

static uint32_t gpt_crc32_tab[256];

static void gpt_crc32_init(void) {
	for (uint32_t i = 0; i < 256; i++) {
		uint32_t c = i;
		for (int k = 0; k < 8; k++)
			c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
		gpt_crc32_tab[i] = c;
	}
}

static uint32_t gpt_crc32(const uint8_t *p, size_t n) {
	uint32_t c = 0xFFFFFFFFu;
	for (size_t i = 0; i < n; i++)
		c = gpt_crc32_tab[(c ^ p[i]) & 0xFF] ^ (c >> 8);
	return c ^ 0xFFFFFFFFu;
}

static uint64_t gpt_rd64(const uint8_t *p) {
	uint64_t v = 0;
	for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
	return v;
}

static void gpt_wr64(uint8_t *p, uint64_t v) {
	for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i));
}

static uint32_t gpt_rd32(const uint8_t *p) {
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
	       ((uint32_t)p[3] << 24);
}

static void gpt_wr32(uint8_t *p, uint32_t v) {
	for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i));
}

static int gpt_entry_empty(const uint8_t *e) {
	for (int i = 0; i < 16; i++)
		if (e[GPT_E_TYPE + i]) return 0;
	return 1;
}

/* Partition names are UTF-16LE; every name BaseOS cares about is ASCII. */
static int gpt_name_is(const uint8_t *e, const char *ascii) {
	const uint8_t *n = e + GPT_E_NAME;
	size_t i = 0;
	for (; ascii[i]; i++) {
		if ((i * 2 + 1) >= (ENTRY_SIZE - GPT_E_NAME)) return 0;
		if (n[i * 2] != (uint8_t)ascii[i] || n[i * 2 + 1] != 0) return 0;
	}
	return n[i * 2] == 0 && n[i * 2 + 1] == 0;
}

#endif /* BASEOS_GPT_H */
