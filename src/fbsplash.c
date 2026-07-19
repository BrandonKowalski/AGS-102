// Minimal framebuffer boot splash for the H700 base OS.
//
//   fbsplash <progress 0-100> [message]
//
// Renders a monochrome "BASE OS" wordmark that illuminates left-to-right in
// proportion to <progress>: the reveal reaching the last letter is the moment
// the frontend takes over. Optional [message] is shown dim below (error/status
// states). Text is crisp anti-aliased Lexend via freetype; if the font is
// missing it falls back to a built-in bitmap so boot never blocks.
#include <ctype.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <ft2build.h>
#include FT_FREETYPE_H

#define FONT_PATH "/usr/share/baseos/boot.ttf"

typedef struct {
	uint8_t rows[7];
} Glyph;

typedef struct {
	char c;
	Glyph g;
} GlyphMap;

// 5x7 bitmap font — fallback only (used when the TTF is unavailable).
static const GlyphMap glyphs[] = {
	{' ', {{0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}}},
	{'.', {{0x00, 0x00, 0x00, 0x00, 0x00, 0x0c, 0x0c}}},
	{'0', {{0x0e, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0e}}},
	{'1', {{0x04, 0x0c, 0x04, 0x04, 0x04, 0x04, 0x0e}}},
	{'A', {{0x0e, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11}}},
	{'B', {{0x1e, 0x11, 0x11, 0x1e, 0x11, 0x11, 0x1e}}},
	{'E', {{0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x1f}}},
	{'O', {{0x0e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e}}},
	{'S', {{0x0f, 0x10, 0x10, 0x0e, 0x01, 0x01, 0x1e}}},
	{'V', {{0x11, 0x11, 0x11, 0x11, 0x11, 0x0a, 0x04}}},
};

static const Glyph *glyph_for(char c) {
	c = (char)toupper((unsigned char)c);
	for (size_t i = 0; i < sizeof(glyphs) / sizeof(glyphs[0]); i++) {
		if (glyphs[i].c == c)
			return &glyphs[i].g;
	}
	return &glyphs[0].g;
}

static uint32_t make_pixel(struct fb_var_screeninfo *v, uint8_t r, uint8_t g, uint8_t b) {
	uint32_t pixel = 0;
	pixel |= ((uint32_t)(r >> (8 - v->red.length))) << v->red.offset;
	pixel |= ((uint32_t)(g >> (8 - v->green.length))) << v->green.offset;
	pixel |= ((uint32_t)(b >> (8 - v->blue.length))) << v->blue.offset;
	return pixel;
}

static void put_pixel(uint8_t *fb, struct fb_var_screeninfo *v, struct fb_fix_screeninfo *f, int x, int y, uint32_t pixel) {
	if (x < 0 || y < 0 || x >= (int)v->xres || y >= (int)v->yres)
		return;
	uint8_t *dst = fb + y * f->line_length + x * (v->bits_per_pixel / 8);
	switch (v->bits_per_pixel) {
		case 16: *(uint16_t *)dst = (uint16_t)pixel; break;
		case 24: dst[0] = pixel & 0xff; dst[1] = (pixel >> 8) & 0xff; dst[2] = (pixel >> 16) & 0xff; break;
		case 32: *(uint32_t *)dst = pixel; break;
	}
}

// Subtle vertical ground gradient (top slightly lighter than bottom).
static void bg_rgb(int y, int yres, uint8_t *r, uint8_t *g, uint8_t *b) {
	double t = yres > 1 ? (double)y / (yres - 1) : 0.0;
	*r = (uint8_t)(0x0C + t * (0x09 - 0x0C));
	*g = (uint8_t)(0x0F + t * (0x0B - 0x0F));
	*b = (uint8_t)(0x12 + t * (0x0D - 0x12));
}

static int clampi(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }

// --- freetype path ---------------------------------------------------------

static int ft_measure(FT_Face face, const char *s, int tracking) {
	int w = 0;
	for (; *s; s++) {
		if (FT_Load_Char(face, (unsigned char)*s, FT_LOAD_DEFAULT))
			continue;
		w += face->glyph->advance.x >> 6;
		if (s[1])
			w += tracking;
	}
	return w;
}

// Draw a line of text. Each pixel's colour is interpolated between dim and
// bright by its position relative to reveal_x (a soft ramp), giving the
// left-to-right illumination; pass reveal_x >= right edge for solid bright.
static void ft_draw(uint8_t *fb, struct fb_var_screeninfo *v, struct fb_fix_screeninfo *f,
                    FT_Face face, const char *s, int x, int baseline, int tracking,
                    int reveal_x, int ramp, const int dim[3], const int bright[3]) {
	int pen = x;
	for (; *s; s++) {
		if (FT_Load_Char(face, (unsigned char)*s, FT_LOAD_RENDER))
			continue;
		FT_Bitmap *bm = &face->glyph->bitmap;
		int gx = pen + face->glyph->bitmap_left;
		int gy = baseline - face->glyph->bitmap_top;
		for (unsigned row = 0; row < bm->rows; row++) {
			for (unsigned col = 0; col < bm->width; col++) {
				unsigned a = bm->buffer[row * bm->pitch + col];
				if (!a)
					continue;
				int ax = gx + (int)col, ay = gy + (int)row;
				double t = ramp > 0 ? ((double)(reveal_x - ax)) / ramp + 0.5 : (ax <= reveal_x);
				if (t < 0) t = 0;
				if (t > 1) t = 1;
				int tr = dim[0] + (int)(t * (bright[0] - dim[0]));
				int tg = dim[1] + (int)(t * (bright[1] - dim[1]));
				int tb = dim[2] + (int)(t * (bright[2] - dim[2]));
				uint8_t br, bgc, bb;
				bg_rgb(ay, v->yres, &br, &bgc, &bb);
				int orr = (tr * a + br * (255 - a)) / 255;
				int org = (tg * a + bgc * (255 - a)) / 255;
				int orb = (tb * a + bb * (255 - a)) / 255;
				put_pixel(fb, v, f, ax, ay, make_pixel(v, orr, org, orb));
			}
		}
		pen += face->glyph->advance.x >> 6;
		if (s[1])
			pen += tracking;
	}
}

// --- bitmap fallback -------------------------------------------------------

static void bmp_text(uint8_t *fb, struct fb_var_screeninfo *v, struct fb_fix_screeninfo *f,
                     int x, int y, const char *text, int scale, uint32_t pixel) {
	for (const char *p = text; *p; p++, x += 6 * scale) {
		const Glyph *g = glyph_for(*p);
		for (int row = 0; row < 7; row++)
			for (int col = 0; col < 5; col++)
				if (g->rows[row] & (1 << (4 - col)))
					for (int sy = 0; sy < scale; sy++)
						for (int sx = 0; sx < scale; sx++)
							put_pixel(fb, v, f, x + col * scale + sx, y + row * scale + sy, pixel);
	}
}

static void render(uint8_t *fb, struct fb_var_screeninfo *vp, struct fb_fix_screeninfo *fp, int prog, const char *msg) {
	struct fb_var_screeninfo v = *vp;
	struct fb_fix_screeninfo f = *fp;
	int W = (int)v.xres, H = (int)v.yres;

	// Ground.
	for (int y = 0; y < H; y++) {
		uint8_t r, g, b;
		bg_rgb(y, H, &r, &g, &b);
		uint32_t px = make_pixel(&v, r, g, b);
		for (int x = 0; x < W; x++)
			put_pixel(fb, &v, &f, x, y, px);
	}

	const int dim[3] = {0x33, 0x3B, 0x40};
	const int bright[3] = {0xEA, 0xF0, 0xF0};
	const int msgcol[3] = {0x7C, 0x8A, 0x8A};
	const int vercol[3] = {0x2F, 0x35, 0x39};

	FT_Library lib;
	FT_Face face;
	int have_ft = 0;
	if (!FT_Init_FreeType(&lib) && !FT_New_Face(lib, FONT_PATH, 0, &face))
		have_ft = 1;

	if (have_ft) {
		// Wordmark — illuminated to progress.
		int size = clampi((int)(H * 0.085), 18, 200);
		FT_Set_Pixel_Sizes(face, 0, size);
		int tracking = (int)(size * 0.34);
		int wordw = ft_measure(face, "BASE OS", tracking);
		int wx = (W - wordw) / 2;
		int baseline = (int)(H * 0.44 + size * 0.35);
		int ramp = clampi((int)(size * 0.55), 1, 400);
		int reveal_x = wx + (int)((double)prog / 100.0 * wordw);
		ft_draw(fb, &v, &f, face, "BASE OS", wx, baseline, tracking, reveal_x, ramp, dim, bright);

		// Optional status/error message (solid dim, centred below).
		if (msg) {
			int ms = clampi((int)(H * 0.045), 12, 80);
			FT_Set_Pixel_Sizes(face, 0, ms);
			int mt = (int)(ms * 0.12);
			int mw = ft_measure(face, msg, mt);
			int mx = (W - mw) / 2;
			int mb = (int)(H * 0.63 + ms * 0.35);
			ft_draw(fb, &v, &f, face, msg, mx, mb, mt, W + 999, 1, msgcol, msgcol);
		}

		// Version footer (tiny, very dim).
		int vs = clampi((int)(H * 0.028), 10, 40);
		FT_Set_Pixel_Sizes(face, 0, vs);
		int vt = (int)(vs * 0.36);
		int vw = ft_measure(face, "V0.1", vt);
		ft_draw(fb, &v, &f, face, "V0.1", (W - vw) / 2, (int)(H * 0.93), vt, W + 999, 1, vercol, vercol);
	} else {
		// Bitmap fallback: wordmark bright + optional message, no illumination.
		int scale = W < 600 ? 4 : 5;
		int tw = (int)strlen("BASE OS") * 6 * scale - scale;
		bmp_text(fb, &v, &f, (W - tw) / 2, (int)(H * 0.42), "BASE OS", scale, make_pixel(&v, 0xEA, 0xF0, 0xF0));
		if (msg) {
			int ms = W < 600 ? 2 : 3;
			int mw = (int)strlen(msg) * 6 * ms - ms;
			bmp_text(fb, &v, &f, (W - mw) / 2, (int)(H * 0.60), msg, ms, make_pixel(&v, 0x7C, 0x8A, 0x8A));
		}
	}

	if (have_ft) {
		FT_Done_Face(face);
		FT_Done_FreeType(lib);
	}
}

#ifdef FBSPLASH_TEST
// Offline render harness: draw to an in-memory 640x480 BGRA buffer and write a
// PPM so the splash can be eyeballed without a real framebuffer or device.
#include <arpa/inet.h>
int main(int argc, char **argv) {
	int prog = argc > 1 ? atoi(argv[1]) : 0;
	prog = clampi(prog, 0, 100);
	const char *msg = (argc > 2 && argv[2][0]) ? argv[2] : NULL;
	const char *out = argc > 3 ? argv[3] : "/out/render.ppm";
	int W = 640, H = 480;

	struct fb_var_screeninfo v;
	struct fb_fix_screeninfo f;
	memset(&v, 0, sizeof(v));
	memset(&f, 0, sizeof(f));
	v.xres = W; v.yres = H; v.bits_per_pixel = 32;
	v.red.offset = 16; v.red.length = 8;
	v.green.offset = 8; v.green.length = 8;
	v.blue.offset = 0; v.blue.length = 8;
	f.line_length = W * 4;
	f.smem_len = f.line_length * H;

	uint8_t *fb = calloc(1, f.smem_len);
	render(fb, &v, &f, prog, msg);

	FILE *fp = fopen(out, "wb");
	fprintf(fp, "P6\n%d %d\n255\n", W, H);
	for (int y = 0; y < H; y++) {
		for (int x = 0; x < W; x++) {
			uint32_t px = *(uint32_t *)(fb + y * f.line_length + x * 4);
			uint8_t rgb[3] = {(px >> 16) & 0xff, (px >> 8) & 0xff, px & 0xff};
			fwrite(rgb, 1, 3, fp);
		}
	}
	fclose(fp);
	free(fb);
	return 0;
}
#else
int main(int argc, char **argv) {
	int prog = argc > 1 ? atoi(argv[1]) : 0;
	prog = clampi(prog, 0, 100);
	const char *msg = (argc > 2 && argv[2][0]) ? argv[2] : NULL;

	int fd = open("/dev/fb0", O_RDWR);
	if (fd < 0)
		return 1;
	struct fb_var_screeninfo v;
	struct fb_fix_screeninfo f;
	if (ioctl(fd, FBIOGET_VSCREENINFO, &v) < 0 || ioctl(fd, FBIOGET_FSCREENINFO, &f) < 0) {
		close(fd);
		return 1;
	}
	if (v.bits_per_pixel != 16 && v.bits_per_pixel != 24 && v.bits_per_pixel != 32) {
		close(fd);
		return 1;
	}
	size_t map_len = f.smem_len ? f.smem_len : (size_t)f.line_length * v.yres;
	uint8_t *fb = mmap(NULL, map_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (fb == MAP_FAILED) {
		close(fd);
		return 1;
	}

	render(fb, &v, &f, prog, msg);
	msync(fb, map_len, MS_SYNC);

	// Force the panel to scan out this buffer: on Allwinner disp2 "smooth boot"
	// kernels the display can stay latched to U-Boot's logo until a pan/unblank.
	ioctl(fd, FBIOBLANK, FB_BLANK_UNBLANK);
	v.xoffset = 0;
	v.yoffset = 0;
	if (ioctl(fd, FBIOPAN_DISPLAY, &v) < 0) {
		v.activate = FB_ACTIVATE_NOW | FB_ACTIVATE_FORCE;
		ioctl(fd, FBIOPUT_VSCREENINFO, &v);
	}

	munmap(fb, map_len);
	close(fd);
	return 0;
}
#endif
