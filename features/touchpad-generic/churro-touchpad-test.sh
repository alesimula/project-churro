#!/bin/bash
# Self-test for churro-touchpad. Needs no root and no input devices: the program's source is
# compiled together with a test main, with ioctl() and fstat() replaced by fakes that describe
# made-up evdev devices; the device nodes, sysfs, store and kmsg are plain files in a temp dir.
set -eu
src=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The real program must build clean and static, the way churro.sh builds it.
cc -static -Os -s -Wall -Wextra -Werror -o "$tmp/churro-touchpad" "$src/churro-touchpad.c"
echo "ok static build without warnings"

N=8
mkdir -p "$tmp/dev" "$tmp/sys/class/dmi/id"
echo "T300FA  " > "$tmp/sys/class/dmi/id/product_name"
: > "$tmp/kmsg"
for n in $(seq 0 $((N - 1))); do
  : > "$tmp/dev/event$n"
  mkdir -p "$tmp/sys/class/input/event$n"
  : > "$tmp/sys/class/input/event$n/uevent"
done
export CHURRO_TOUCHPAD_STORE="$tmp/data/touchpad-ranges" CHURRO_TOUCHPAD_DEV="$tmp/dev"
export CHURRO_TOUCHPAD_SYS="$tmp/sys" CHURRO_TOUCHPAD_KMSG="$tmp/kmsg"

cat > "$tmp/test.c" <<'EOF'
#define _GNU_SOURCE
#include <linux/input.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

// Fake evdev devices, one per node event0..event7. abs[]: MT x, MT y, ABS_X, ABS_Y, MT slot.
struct fake {
  const char *name;
  int prop;
  bool no_slot;  // protocol A: no ABS_MT_SLOT
  struct input_absinfo abs[5];
  int sets;   // number of EVIOCSABS calls
  int dead_fd;  // this fd's device was unplugged: its ioctls fail (0 = none)
};
#define PAD_ABS {{.maximum = 2240, .resolution = 31}, {.maximum = 1120, .resolution = 32}, \
                 {.maximum = 2240, .resolution = 31}, {.maximum = 1120, .resolution = 32}, {.maximum = 9}}
static const struct fake pristine[8] = {
    {"Asus TouchPad", INPUT_PROP_POINTER, 0, PAD_ABS, 0, 0}, {"Spike Pad", INPUT_PROP_POINTER, 0, PAD_ABS, 0, 0},
    {"Garbage Pad", INPUT_PROP_POINTER, 0, PAD_ABS, 0, 0},   {"Screen", INPUT_PROP_DIRECT, 0, PAD_ABS, 0, 0},
    {"Good Pad", INPUT_PROP_POINTER, 0, PAD_ABS, 0, 0},      {"Flip Pad", INPUT_PROP_BUTTONPAD, 0, PAD_ABS, 0, 0},
    {"Slow Pad", INPUT_PROP_POINTER, 0, PAD_ABS, 0, 0},      {"Old Pad", INPUT_PROP_POINTER, 1, PAD_ABS, 0, 0}};
static struct fake fakes[8];

static int fake_index(int fd) {
  char link[64], path[512];
  snprintf(link, sizeof link, "/proc/self/fd/%d", fd);
  ssize_t n = readlink(link, path, sizeof path - 1);
  if (n < 6) abort();
  return path[n - 1] - '0';  // .../eventN
}

static int abs_index(int code) {
  switch (code) {
    case ABS_MT_POSITION_X: return 0;
    case ABS_MT_POSITION_Y: return 1;
    case ABS_X: return 2;
    case ABS_Y: return 3;
    case ABS_MT_SLOT: return 4;
  }
  abort();
}

static int fake_ioctl(int fd, unsigned long req, ...) {
  va_list ap;
  va_start(ap, req);
  void *arg = va_arg(ap, void *);
  va_end(ap);
  struct fake *f = &fakes[fake_index(fd)];
  if (f->dead_fd && fd == f->dead_fd) return -1;
  int nr = _IOC_NR(req);
  if (nr == _IOC_NR(EVIOCGID)) {
    *(struct input_id *)arg = (struct input_id){BUS_USB, 0x0b05, 0x1807, 0x0100};
  } else if (nr == _IOC_NR(EVIOCGNAME(0))) {
    strcpy(arg, f->name);
  } else if (nr == _IOC_NR(EVIOCGPROP(0))) {
    *(unsigned long *)arg = 1UL << f->prop;
  } else if (nr == _IOC_NR(EVIOCGBIT(EV_ABS, 0))) {
    unsigned long *bits = arg;
    int codes[5] = {ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_X, ABS_Y, ABS_MT_SLOT};
    for (int i = 0; i < 5 - f->no_slot; i++)
      bits[codes[i] / (8 * sizeof(long))] |= 1UL << codes[i] % (8 * sizeof(long));
  } else if (nr >= 0x40 && nr < 0x80) {
    *(struct input_absinfo *)arg = f->abs[abs_index(nr - 0x40)];
  } else if (nr >= 0xc0) {
    f->abs[abs_index(nr - 0xc0)] = *(struct input_absinfo *)arg;
    f->sets++;
  } else {
    abort();
  }
  return 0;
}

// Regular files have no st_rdev: give each fake node its own.
static int fake_fstat(int fd, struct stat *st) {
  int r = fstat(fd, st);
  st->st_rdev = 100 + fake_index(fd);
  return r;
}

#define ioctl fake_ioctl
#define fstat fake_fstat
#define main churro_main
#include "churro-touchpad.c"
#undef main

static int failed;
static void check(bool ok, const char *what) {
  printf("%s %s\n", ok ? "ok" : "FAILED", what);
  if (!ok) failed = 1;
}

static struct pad *find(const char *node) {
  for (int i = 0; i < MAX_PADS; i++)
    if (pads[i].fd >= 0 && !strcmp(pads[i].node, node)) return &pads[i];
  return NULL;
}

static int watched(void) {
  int n = 0;
  for (int i = 0; i < MAX_PADS; i++) n += pads[i].fd >= 0;
  return n;
}

static const char *slurp(const char *path) {
  static char buf[8192];
  FILE *f = fopen(path, "r");
  size_t n = f ? fread(buf, 1, sizeof buf - 1, f) : 0;
  if (f) fclose(f);
  buf[n] = 0;
  return buf;
}

static const char *uevent(const char *node) {
  char path[PATH_MAX];
  snprintf(path, sizeof path, "%s/class/input/%s/uevent", sys_dir, node);
  return slurp(path);
}

static int count(const char *hay, const char *needle) {
  int n = 0;
  for (; (hay = strstr(hay, needle)); hay++) n++;
  return n;
}

static void ev(struct pad *p, int type, int code, int value, long long now) {
  if (p->fd >= 0) pad_event(p, &(struct input_event){.type = type, .code = code, .value = value}, now);
}

// One touch: finger down, n positions, finger up (at time now + n).
static void touch(struct pad *p, int code, const int *v, int n, long long now) {
  static int id;
  ev(p, EV_ABS, ABS_MT_SLOT, 0, now);
  ev(p, EV_ABS, ABS_MT_TRACKING_ID, ++id, now);
  ev(p, EV_KEY, BTN_TOUCH, 1, now);
  ev(p, EV_KEY, BTN_TOOL_FINGER, 1, now);
  for (int i = 0; i < n; i++) {
    ev(p, EV_ABS, code, v[i], now + i);
    ev(p, EV_SYN, SYN_REPORT, 0, now + i);
  }
  ev(p, EV_ABS, ABS_MT_TRACKING_ID, -1, now + n);
  ev(p, EV_KEY, BTN_TOUCH, 0, now + n);
  ev(p, EV_KEY, BTN_TOOL_FINGER, 0, now + n);
  ev(p, EV_SYN, SYN_REPORT, 0, now + n);
}
#define TOUCH(p, code, now, ...) \
  touch(p, code, (int[]){__VA_ARGS__}, sizeof((int[]){__VA_ARGS__}) / sizeof(int), now)

int main(void) {
  memcpy(fakes, pristine, sizeof fakes);
  setup();
  scan_nodes();
  const char *kmsg = getenv("CHURRO_TOUCHPAD_KMSG");
  check(watched() == 6 && !find("event3") && !find("event7"),
        "touchscreen (INPUT_PROP_DIRECT) and a pad without ABS_MT_SLOT ignored, 6 touchpads watched");

  // (a) the T300FA case: x really goes to 3080 on a pad declared 0..2240
  struct pad *p = find("event0");
  TOUCH(p, ABS_MT_POSITION_X, 100, 40, 300);       // left edge
  TOUCH(p, ABS_MT_POSITION_Y, 200, 25, 400);       // top edge
  TOUCH(p, ABS_MT_POSITION_Y, 300, 700, 1095);     // bottom edge
  TOUCH(p, ABS_MT_POSITION_X, 400, 1500, 2000, 2230);  // right edge, but not past it yet
  check(p->fd >= 0, "(a) reaching all four declared edges does not end the watch");
  TOUCH(p, ABS_MT_POSITION_X, 1000, 1500, 2300, 2800, 3080, 3000);
  check(p->x.max == 2240 && !fakes[0].sets, "(a) one touch beyond the edge is not enough");
  TOUCH(p, ABS_MT_POSITION_X, 2000, 2000, 2900, 3080, 3050);  // ends at 2004
  check(p->x.min == 0 && p->x.max == 3080 && p->y.min == 0 && p->y.max == 1120, "(a) learned x 0..3080");
  check(!strcmp(slurp(store_path), "T300FA|0003:0b05:1807:0100|Asus TouchPad\t0 3080 0 1120\t0 2240 0 1120\n"),
        "(a) store line: learned range, then the driver's");
  check(fakes[0].sets == 4 && fakes[0].abs[0].maximum == 3080 && fakes[0].abs[2].maximum == 3080 &&
            fakes[0].abs[0].minimum == 0 && fakes[0].abs[0].resolution == 31 && fakes[0].abs[1].maximum == 1120,
        "(a) EVIOCSABS on MT and ABS_X/Y with the new range, resolution kept");
  check(strstr(slurp(kmsg), "<6>churro-touchpad: Asus TouchPad (0003:0b05:1807): x 0..2240 -> 0..3080, y 0..1120 -> 0..1120\n"),
        "(a) log line");
  pad_tick(p, 2004 + 2999);
  check(!*uevent("event0"), "(a) no bounce before 3 s idle");
  ev(p, EV_KEY, BTN_LEFT, 1, 2500);  // the physical button is held (a drag)
  pad_tick(p, 9000);
  check(!*uevent("event0"), "(a) no bounce while a button is down");
  ev(p, EV_KEY, BTN_LEFT, 0, 9000);
  ev(p, EV_ABS, ABS_MT_TRACKING_ID, 77, 9500);  // a new touch starts
  pad_tick(p, 15000);
  check(!*uevent("event0"), "(a) no bounce while touching");
  ev(p, EV_ABS, ABS_MT_TRACKING_ID, -1, 15100);
  pad_tick(p, 18099);
  pad_tick(p, 18100);
  pad_tick(p, 30000);
  check(!strcmp(uevent("event0"), "removeadd"), "(a) one bounce (remove, add) once idle");
  open_node("event0", true);  // the node ueventd recreated
  pad_tick(find("event0"), 40000);
  check(watched() == 6 && find("event0") == p && !strcmp(uevent("event0"), "removeadd"),
        "(a) recreated node is the same device: no second bounce");
  TOUCH(p, ABS_MT_POSITION_X, 41000, 3000, 3100, 3100, 3100);
  TOUCH(p, ABS_MT_POSITION_X, 42000, 3000, 3100, 3100, 3100);
  check(p->x.max == 3100, "(a) past a learned edge, 20 units (under the first margin) are learned");

  // (b) spikes and noise
  p = find("event1");
  TOUCH(p, ABS_MT_POSITION_X, 1000, 1000, 3000, 1000);
  for (int i = 0; i < 5; i++) TOUCH(p, ABS_MT_POSITION_X, 2000 + 100 * i, 500, 1500, 2200);
  check(p->x.max == 2240, "(b) single spike ignored");
  TOUCH(p, ABS_MT_POSITION_X, 2600, 1000, 3000, 3000, 3000, 1000);  // one weird touch...
  TOUCH(p, ABS_MT_POSITION_X, 2700, 1000, 2950, 1000);              // ...and a one-event spike
  check(p->x.max == 2240, "(b) one weird touch plus a one-event spike in another touch ignored");
  TOUCH(p, ABS_MT_POSITION_Y, 3000, 500, 1125, 1126, 1127);
  TOUCH(p, ABS_MT_POSITION_Y, 3100, 500, 1127, 1128, 1128);
  check(p->y.max == 1120, "(b) jitter within the noise margin ignored");
  pad_tick(p, 99999);
  check(!fakes[1].sets && !*uevent("event1") && !strstr(slurp(store_path), "Spike"), "(b) nothing applied, stored or bounced");

  // (c) more than one span beyond the declared range
  p = find("event2");
  for (int i = 0; i < 4; i++) TOUCH(p, ABS_MT_POSITION_X, 1000 + 100 * i, 5000, 4481, -2300, 5000);
  check(p->x.min == 0 && p->x.max == 2240 && !fakes[2].sets, "(c) values beyond 2x span rejected");
  check(count(slurp(kmsg), "<4>churro-touchpad: Garbage Pad: ignoring") == 1, "(c) logged once, as a warning");

  // (f) two fingers, interleaved slots: one touch
  p = find("event4");
  ev(p, EV_ABS, ABS_MT_SLOT, 0, 100);
  ev(p, EV_ABS, ABS_MT_TRACKING_ID, 1, 100);
  ev(p, EV_ABS, ABS_MT_POSITION_X, 2600, 100);
  ev(p, EV_ABS, ABS_MT_SLOT, 1, 101);
  ev(p, EV_ABS, ABS_MT_TRACKING_ID, 2, 101);
  ev(p, EV_ABS, ABS_MT_POSITION_X, 2700, 101);
  ev(p, EV_ABS, ABS_MT_SLOT, 0, 102);
  ev(p, EV_ABS, ABS_MT_POSITION_X, 2650, 102);
  ev(p, EV_ABS, ABS_MT_TRACKING_ID, -1, 103);
  ev(p, EV_ABS, ABS_MT_SLOT, 1, 104);
  ev(p, EV_ABS, ABS_MT_POSITION_X, 2750, 104);
  ev(p, EV_ABS, ABS_MT_TRACKING_ID, -1, 105);
  check(p->x.max == 2240 && p->x.hi.peak[0] == 510, "(f) a two-finger touch counts as one touch");

  // (g) y goes negative (and a SYN_DROPPED); events arrive through read() on the node
  p = find("event5");
  struct input_event evs[] = {
      {.type = EV_ABS, .code = ABS_MT_TRACKING_ID, .value = 1},
      {.type = EV_ABS, .code = ABS_MT_POSITION_Y, .value = 300},
      {.type = EV_ABS, .code = ABS_MT_POSITION_Y, .value = -300},
      {.type = EV_ABS, .code = ABS_MT_POSITION_Y, .value = -560},
      {.type = EV_ABS, .code = ABS_MT_POSITION_Y, .value = -560},
      {.type = EV_ABS, .code = ABS_MT_TRACKING_ID, .value = -1},
      {.type = EV_SYN, .code = SYN_DROPPED},
      {.type = EV_ABS, .code = ABS_MT_TRACKING_ID, .value = 2},
      {.type = EV_ABS, .code = ABS_MT_POSITION_Y, .value = -560},
      {.type = EV_ABS, .code = ABS_MT_POSITION_Y, .value = -560},
      {.type = EV_ABS, .code = ABS_MT_POSITION_Y, .value = -500},
      {.type = EV_ABS, .code = ABS_MT_TRACKING_ID, .value = -1},
  };
  char path[PATH_MAX];
  snprintf(path, sizeof path, "%s/event5", dev_dir);
  FILE *f = fopen(path, "w");
  fwrite(evs, sizeof evs, 1, f);
  fclose(f);
  pad_read(p, 5000);
  check(p->fd >= 0 && p->y.min == -560 && p->y.max == 1120 && p->x.max == 2240, "(g) learned y -560..1120");
  check(strstr(slurp(store_path), "T300FA|0003:0b05:1807:0100|Flip Pad\t0 2240 -560 1120\t0 2240 0 1120\n") &&
            strstr(slurp(store_path), "Asus TouchPad\t0 3100 0 1120\t0 2240 0 1120\n"),
        "(g) store has both devices");
  check(strstr(slurp(kmsg), "Flip Pad (0003:0b05:1807): x 0..2240 -> 0..2240, y 0..1120 -> -560..1120\n") &&
            fakes[5].abs[1].minimum == -560 && fakes[5].abs[3].minimum == -560,
        "(g) logged and applied");

  // (h) 15 minutes of touching with nothing out of range: done watching
  p = find("event6");
  TOUCH(p, ABS_MT_POSITION_X, 0, 1000);
  ev(p, EV_ABS, ABS_MT_TRACKING_ID, 5, 1000);
  ev(p, EV_ABS, ABS_MT_TRACKING_ID, -1, 1000 + 14 * 60 * 1000);
  check(p->fd >= 0, "(h) still watched after 14 minutes of touching");
  ev(p, EV_ABS, ABS_MT_TRACKING_ID, 6, 0);
  ev(p, EV_ABS, ABS_MT_TRACKING_ID, -1, 60 * 1000);
  check(!find("event6"), "(h) closed after 15 minutes of touching");
  check(count(slurp(kmsg), "Slow Pad: range x 0..2240, y 0..1120 confirmed") == 1, "(h) logged once");

  // (d) reboot: the driver's ranges are back, the store is applied, no bounce
  for (int i = 0; i < MAX_PADS; i++)
    if (pads[i].fd >= 0) pad_close(&pads[i]);
  memcpy(fakes, pristine, sizeof fakes);
  scan_nodes();
  p = find("event0");
  check(p && p->x.max == 3100 && fakes[0].sets == 4 && fakes[0].abs[0].maximum == 3100 && fakes[0].abs[2].maximum == 3100,
        "(d) reboot: stored range applied at startup");
  check(find("event5")->y.min == -560 && fakes[5].abs[1].minimum == -560, "(d) reboot: negative y min applied");
  for (int i = 0; i < MAX_PADS; i++) pad_tick(&pads[i], now_ms() + 100000);
  check(!strcmp(uevent("event0"), "removeadd") && !*uevent("event5"), "(d) no bounce at startup");
  check(p->x.ceiling == 4480 && p->x.hi.grown, "(d) reboot: garbage limit from the driver's range, side marked grown");

  // (r) the daemon restarts without a reboot: the kernel keeps our range; nothing to do, limits stay
  for (int i = 0; i < MAX_PADS; i++)
    if (pads[i].fd >= 0) pad_close(&pads[i]);
  int sets = fakes[0].sets;
  scan_nodes();
  p = find("event0");
  check(p && p->x.max == 3100 && p->x.ceiling == 4480 && fakes[0].sets == sets,
        "(r) restart: range kept, garbage limit still from the driver's range, nothing re-applied");

  // (k) a kernel update changed the driver's range: the entry is dropped and learned again
  pad_close(p);
  memcpy(fakes, pristine, sizeof fakes);
  fakes[0].abs[0].maximum = fakes[0].abs[2].maximum = 2640;
  open_node("event0", false);
  p = find("event0");
  check(p && p->x.max == 2640 && !fakes[0].sets && strstr(slurp(kmsg), "Asus TouchPad: stored range is for another driver range"),
        "(k) stored entry for another driver range not applied");

  // hotplug after startup: stored range applied, then a bounce so that Android sees it
  pad_close(p);
  memcpy(fakes, pristine, sizeof fakes);
  open_node("event0", true);
  p = find("event0");
  check(p && fakes[0].abs[0].maximum == 3100 && !strcmp(uevent("event0"), "removeadd"), "hotplug: stored range applied");
  pad_tick(p, now_ms() + 3100);
  check(!strcmp(uevent("event0"), "removeaddremoveadd"), "hotplug: bounced once idle");

  // replugged before we saw it go: same device number, the old fd is dead -> adopt the new one
  p = find("event4");
  int fd_old = p->fd;
  fakes[4].dead_fd = fd_old;
  open_node("event4", true);
  check(find("event4") && find("event4")->fd != fd_old, "replug with a dead old fd: the new device is adopted");

  if (failed) return 1;
  return 0;
}
EOF
cc -Wall -Wextra -Werror -I"$src" -o "$tmp/test" "$tmp/test.c"
"$tmp/test"

# The real binary: stays up watching a directory without touchpads, fails without the directory.
rc=0; timeout 0.5 "$tmp/churro-touchpad" || rc=$?
[ $rc = 124 ] && echo "ok real binary keeps running on a dev dir without touchpads" || { echo "FAILED real binary exited $rc"; exit 1; }
rc=0; CHURRO_TOUCHPAD_DEV="$tmp/nowhere" "$tmp/churro-touchpad" || rc=$?
[ $rc = 1 ] && grep -q "<4>churro-touchpad: can't watch $tmp/nowhere" "$tmp/kmsg" \
  && echo "ok real binary exits 1 when it can't watch the dev dir" || { echo "FAILED fatal setup error, rc $rc"; exit 1; }

echo "all passed"
