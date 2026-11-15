// churro-splash: started by the kernel instead of /init (rdinit=/churro/splash, the normal boot
// entry only). Draws /churro/splash.tga (a square canvas with the logo in the middle) on the
// firmware framebuffer (simpledrm's fb0), scaled to the screen height and centred: the same
// picture, at the same size, as GRUB's theme (padding = fit). Then execs the real /init. The
// picture stays until the GPU driver takes the display over. Any failure: just /init.
// Built static by churro.sh (host cc); runs before Android's init, so no bionic needed.
// Test: splash --test <tga> <width> <height> <16|32> <out.ppm> (renders into a file, no fb0).
#define _GNU_SOURCE
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/kd.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

static uint8_t *img;  // decoded canvas, RGB, top row first
static int iw, ih, bx0, by0, bx1, by1;  // the canvas's non-black part (only that is scaled)

// TGA, true colour (type 2) or RLE true colour (type 10), 24 or 32 bpp, any origin.
static int load_tga(const char *path) {
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  struct stat st;
  if (fd < 0 || fstat(fd, &st) || st.st_size < 18) return -1;
  uint8_t *b = malloc(st.st_size), *p, *end = b + st.st_size;
  if (!b || read(fd, b, st.st_size) != st.st_size) return -1;
  close(fd);
  int type = b[2], bpp = b[16], desc = b[17], px = bpp / 8;
  iw = b[12] | b[13] << 8;
  ih = b[14] | b[15] << 8;
  if (b[1] || (type != 2 && type != 10) || (bpp != 24 && bpp != 32) || !iw || !ih) return -1;
  img = malloc((size_t)iw * ih * 3);
  if (!img) return -1;
  p = b + 18 + b[0];
  bx0 = iw, by0 = ih, bx1 = by1 = 0;
  for (long i = 0, n = (long)iw * ih; i < n;) {
    long cnt = 1;
    int rle = 0;
    if (type == 10) {
      if (p >= end) return -1;
      rle = *p & 0x80;
      cnt = (*p++ & 0x7f) + 1;
    }
    if (p + (rle ? 1 : cnt) * px > end) return -1;
    for (long k = 0; k < cnt && i < n; k++, i++) {
      long x = i % iw, y = i / iw;
      if (!(desc & 0x20)) y = ih - 1 - y;  // bottom-up
      if (desc & 0x10) x = iw - 1 - x;     // right-to-left
      uint8_t *s = rle ? p : p + k * px, *d = img + (y * iw + x) * 3;
      d[0] = s[2];  // TGA keeps BGR(A)
      d[1] = s[1];
      d[2] = s[0];
      if (d[0] | d[1] | d[2]) {
        if (x < bx0) bx0 = x;
        if (x > bx1) bx1 = x;
        if (y < by0) by0 = y;
        if (y > by1) by1 = y;
      }
    }
    p += (rle ? 1 : cnt) * px;
  }
  free(b);
  return 0;
}

// The canvas scaled to fit the screen (square -> the screen height on a landscape screen),
// centred, black around it: k x k bilinear samples per pixel (k = 1 when enlarging, more when
// shrinking, so thin lines and the sugar don't flicker away).
static void render(uint8_t *fb, int w, int h, int line, const struct fb_var_screeninfo *v) {
  int s = w < h ? w : h, x0 = (w - s) / 2, y0 = (h - s) / 2, bytes = (v->bits_per_pixel + 7) / 8;
  float r = (float)iw / s;
  int k = r > 1 ? (int)r + 1 : 1;
  memset(fb, 0, (size_t)line * h);
  // screen pixels whose samples can reach the non-black part (+2: bilinear neighbours, rounding)
  int ya = by0 / r - 2, yb = by1 / r + 2, xa = bx0 / r - 2, xb = bx1 / r + 2;
  for (int dy = ya < 0 ? 0 : ya; dy < s && dy <= yb; dy++)
    for (int dx = xa < 0 ? 0 : xa; dx < s && dx <= xb; dx++) {
      float acc[3] = {0, 0, 0};
      for (int sy = 0; sy < k; sy++)
        for (int sx = 0; sx < k; sx++) {
          float fx = (dx + (sx + 0.5f) / k) * r - 0.5f, fy = (dy + (sy + 0.5f) / k) * r - 0.5f;
          if (fx < 0) fx = 0;
          if (fy < 0) fy = 0;
          int ax = (int)fx, ay = (int)fy, bx = ax + 1 < iw ? ax + 1 : ax, by = ay + 1 < ih ? ay + 1 : ay;
          float tx = fx - ax, ty = fy - ay;
          const uint8_t *a = img + ((size_t)ay * iw + ax) * 3, *b = img + ((size_t)ay * iw + bx) * 3,
                        *c = img + ((size_t)by * iw + ax) * 3, *d = img + ((size_t)by * iw + bx) * 3;
          for (int ch = 0; ch < 3; ch++)
            acc[ch] += (a[ch] * (1 - tx) + b[ch] * tx) * (1 - ty) + (c[ch] * (1 - tx) + d[ch] * tx) * ty;
        }
      const struct fb_bitfield *f[3] = {&v->red, &v->green, &v->blue};
      uint32_t px = 0;
      for (int ch = 0; ch < 3; ch++) {
        unsigned val = (unsigned)(acc[ch] / (k * k) + 0.5f);
        px |= (val > 255 ? 255 : val) >> (8 - f[ch]->length) << f[ch]->offset;
      }
      uint8_t *o = fb + (size_t)(y0 + dy) * line + (size_t)(x0 + dx) * bytes;
      for (int i = 0; i < bytes; i++) o[i] = px >> (8 * i);  // little-endian
    }
}

static int bits_ok(const struct fb_var_screeninfo *v) {
  const struct fb_bitfield *f[3] = {&v->red, &v->green, &v->blue};
  for (int ch = 0; ch < 3; ch++)
    if (!f[ch]->length || f[ch]->length > 8 || f[ch]->offset + f[ch]->length > v->bits_per_pixel) return 0;
  return v->bits_per_pixel == 16 || v->bits_per_pixel == 24 || v->bits_per_pixel == 32;
}

static void splash(void) {
  // No devtmpfs in GKI: our own nodes, removed again (first-stage init sets up /dev itself).
  mknod("/churro-fb0", S_IFCHR | 0600, makedev(29, 0));
  mknod("/churro-tty0", S_IFCHR | 0600, makedev(4, 0));
  int fb = -1;
  for (int i = 0; i < 20 && fb < 0; i++)  // simpledrm may still be probing: up to 1 s
    if ((fb = open("/churro-fb0", O_RDWR | O_CLOEXEC)) < 0) usleep(50000);
  int tty = open("/churro-tty0", O_RDWR | O_CLOEXEC);
  unlink("/churro-fb0");
  unlink("/churro-tty0");
  struct fb_var_screeninfo v;
  struct fb_fix_screeninfo fx;
  if (fb < 0 || ioctl(fb, FBIOGET_VSCREENINFO, &v) || ioctl(fb, FBIOGET_FSCREENINFO, &fx) ||
      fx.visual != FB_VISUAL_TRUECOLOR || !bits_ok(&v) || !v.xres || !v.yres ||
      fx.line_length < v.xres * (v.bits_per_pixel / 8) || load_tga("/churro/splash.tga"))
    return;
  uint8_t *buf = malloc((size_t)fx.line_length * v.yres);
  if (!buf) return;
  // text mode off: fbcon would draw its cursor and messages over the picture
  if (tty >= 0) ioctl(tty, KDSETMODE, KD_GRAPHICS);
  render(buf, v.xres, v.yres, fx.line_length, &v);
  // write(), not mmap: simpledrm's fbdev flushes written ranges itself
  if (pwrite(fb, buf, (size_t)fx.line_length * v.yres, (off_t)fx.line_length * v.yoffset) < 0) return;
}

int main(int argc, char **argv) {
  if (argc == 7 && !strcmp(argv[1], "--test")) {
    int w = atoi(argv[3]), h = atoi(argv[4]), bpp = atoi(argv[5]);
    struct fb_var_screeninfo v = {.bits_per_pixel = bpp};
    if (bpp == 16) v.red = (struct fb_bitfield){11, 5, 0}, v.green = (struct fb_bitfield){5, 6, 0}, v.blue = (struct fb_bitfield){0, 5, 0};
    else v.red = (struct fb_bitfield){16, 8, 0}, v.green = (struct fb_bitfield){8, 8, 0}, v.blue = (struct fb_bitfield){0, 8, 0};
    int line = w * bpp / 8 + 64;  // padded lines, like real framebuffers
    uint8_t *buf = malloc((size_t)line * h);
    if (w <= 0 || h <= 0 || !bits_ok(&v) || !buf || load_tga(argv[2])) return 1;
    render(buf, w, h, line, &v);
    FILE *o = fopen(argv[6], "wb");
    if (!o) return 1;
    fprintf(o, "P6\n%d %d\n255\n", w, h);
    for (int y = 0; y < h; y++)
      for (int x = 0; x < w; x++) {
        uint32_t px = 0;
        for (int i = 0; i < bpp / 8; i++) px |= (uint32_t)buf[(size_t)y * line + x * (bpp / 8) + i] << (8 * i);
        const struct fb_bitfield *f[3] = {&v.red, &v.green, &v.blue};
        for (int ch = 0; ch < 3; ch++) fputc((px >> f[ch]->offset & ((1u << f[ch]->length) - 1)) << (8 - f[ch]->length), o);
      }
    return fclose(o) != 0;
  }
  splash();
  argv[0] = "/init";
  execv("/init", argv);
  return 1;
}
