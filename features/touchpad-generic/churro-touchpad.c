// churro-touchpad: long-running Android init service (/vendor/bin/churro-touchpad, started at
// post-fs-data, before Android's input system). Fixes touchpads whose driver declares a smaller
// ABS range than the pad really reports (e.g. hid-asus gives unknown ASUS docks 2240x1120).
// Android reads the range once when it opens /dev/input/eventN and treats touches past the
// declared edge as palms, so that strip of the pad is dead. The kernel never clamps, so the real
// values still reach us on the evdev node. We
//   - watch every touchpad (ABS_MT_POSITION_X/Y, INPUT_PROP_POINTER or BUTTONPAD, not DIRECT)
//   - learn the real range passively from the positions the user's fingers produce
//   - persist it per "<DMI product>|<bus:vendor:product:version>|<name>" in a text store, with
//     the driver's own range (an entry made for another driver range is dropped)
//   - apply it with EVIOCSABS (startup, hotplug, and whenever it grows), then "bounce" the node
//     (write remove + add to its sysfs uevent) once the pad has been idle for 3 s, no finger and
//     no button or key down, so that ueventd recreates /dev/input/eventN and Android's EventHub
//     reopens it and re-reads the range.
// Learning rule: a side of an axis grows only to a value that two separate touches both went
// beyond (the lesser of their two peaks), each with at least 3 events past the noise margin (2%
// of the span, min 8 units; a quarter of that once the side has grown). So a one-off spike, or
// one whole weird touch, is never accepted, whatever its size. Values more than one driver span
// outside the driver's range are garbage: ignored.
// A device is closed for good ("confirmed") after 15 minutes of touching with nothing out of
// range. Reaching the declared edges proves nothing (the pad may go on past them), so there is no
// shortcut.
// Paths can be overridden by CHURRO_TOUCHPAD_{STORE,DEV,SYS,KMSG} (used by the self-test).
// Built static by churro.sh; plain libc + linux/input.h, no bionic needed.

#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/input.h>
#include <poll.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define MAX_PADS 16
#define IDLE_MS 3000                   // growth comes in steps: one bounce for all of them
#define CONFIRM_MS (15 * 60 * 1000LL)  // touching time with nothing out of range
#define BITS_PER_LONG (8 * (int)sizeof(long))

// One edge of an axis. Distances are measured outwards from the declared bound (> 0 = outside).
struct side {
  int peak[2];  // two highest per-touch peaks so far, from different touches
  int cur;      // peak of the touch in progress
  int events;   // events of the touch in progress beyond the noise margin
  bool grown;   // this side has grown: a smaller margin from now on
};

struct axis {
  int min, max;        // declared range (what the kernel reports now)
  int dmin, dmax;      // the driver's own declared range
  int floor, ceiling;  // garbage limits: one driver span outside the driver's range
  struct side lo, hi;
};

struct pad {
  int fd;  // -1 = free slot
  dev_t rdev;
  char node[32], name[80], key[256];
  struct input_id id;
  bool has_st;  // also has ABS_X/ABS_Y (single-touch emulation of the same coordinates)
  struct axis x, y;
  unsigned long long slots;  // bitmask of slots with a contact
  int slot;
  int keys;  // buttons/keys down (a bounce would cancel a drag or a held key)
  bool btn_touch, bounce, garbage_logged;
  long long touch_start, last_event, quiet_ms;  // quiet_ms: touch time since last out-of-range
};

static struct pad pads[MAX_PADS];
static const char *store_path, *dev_dir, *sys_dir;
static char dmi[64];
static int kmsg_fd = -1;

__attribute__((format(printf, 2, 3))) static void say(int level, const char *fmt, ...) {
  char buf[512];
  int n = snprintf(buf, sizeof buf, "<%d>churro-touchpad: ", level);
  va_list ap;
  va_start(ap, fmt);
  n += vsnprintf(buf + n, sizeof buf - n - 1, fmt, ap);
  va_end(ap);
  if (n > (int)sizeof buf - 2) n = sizeof buf - 2;
  buf[n++] = '\n';
  if (write(kmsg_fd >= 0 ? kmsg_fd : 2, buf, n) < 0) return;  // nowhere left to complain
}

static long long now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000LL + ts.tv_nsec / 1000000;
}

static const char *env_or(const char *name, const char *fallback) {
  const char *v = getenv(name);
  return v && *v ? v : fallback;
}

static void setup(void) {
  store_path = env_or("CHURRO_TOUCHPAD_STORE", "/data/vendor/churro/touchpad-ranges");
  dev_dir = env_or("CHURRO_TOUCHPAD_DEV", "/dev/input");
  sys_dir = env_or("CHURRO_TOUCHPAD_SYS", "/sys");
  kmsg_fd = open(env_or("CHURRO_TOUCHPAD_KMSG", "/dev/kmsg"), O_WRONLY | O_CLOEXEC);
  for (int i = 0; i < MAX_PADS; i++) pads[i].fd = -1;

  char path[PATH_MAX];
  snprintf(path, sizeof path, "%s/class/dmi/id/product_name", sys_dir);
  FILE *f = fopen(path, "re");
  if (!f || !fgets(dmi, sizeof dmi, f)) say(4, "no DMI product name (%s)", strerror(errno));
  if (f) fclose(f);
  dmi[strcspn(dmi, "\r\n")] = 0;
  for (size_t n = strlen(dmi); n && dmi[n - 1] == ' '; n--) dmi[n - 1] = 0;
}

// --- store: one line per device, "<key>\t<xmin> <xmax> <ymin> <ymax>\t<the driver's 4>" ---

static bool line_has_key(const char *line, const char *key) {
  size_t n = strlen(key);
  return !strncmp(line, key, n) && line[n] == '\t';
}

static bool store_get(const char *key, int r[8]) {
  char line[512];
  bool found = false;
  FILE *f = fopen(store_path, "re");
  if (!f) return false;
  while (!found && fgets(line, sizeof line, f))
    found = line_has_key(line, key) &&
            sscanf(line + strlen(key), "%d %d %d %d %d %d %d %d", &r[0], &r[1], &r[2], &r[3], &r[4],
                   &r[5], &r[6], &r[7]) == 8;
  fclose(f);
  return found;
}

static void store_put(const char *key, const int r[8]) {
  char tmp[PATH_MAX], line[512];
  snprintf(tmp, sizeof tmp, "%s", store_path);
  char *slash = strrchr(tmp, '/');
  if (slash) {
    *slash = 0;
    if (mkdir(tmp, 0770) && errno != EEXIST) say(4, "mkdir %s: %s", tmp, strerror(errno));
  }
  snprintf(tmp, sizeof tmp, "%s.tmp", store_path);
  FILE *out = fopen(tmp, "we");
  if (!out) {
    say(4, "can't write %s: %s", tmp, strerror(errno));
    return;
  }
  FILE *in = fopen(store_path, "re");
  while (in && fgets(line, sizeof line, in))
    if (!line_has_key(line, key)) fputs(line, out);
  if (in) fclose(in);
  fprintf(out, "%s\t%d %d %d %d\t%d %d %d %d\n", key, r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7]);
  // Atomic: the old store stays in place unless the new one is completely on disk.
  bool ok = !fflush(out) && !fsync(fileno(out));
  ok = !fclose(out) && ok;
  if (!ok || rename(tmp, store_path)) say(4, "can't update %s: %s", store_path, strerror(errno));
}

// --- applying a range ---

static void set_range(struct pad *p, int code, const struct axis *a) {
  struct input_absinfo abs;  // fuzz, flat and resolution stay as the driver set them
  if (ioctl(p->fd, EVIOCGABS(code), &abs)) return;
  abs.minimum = a->min;
  abs.maximum = a->max;
  if (ioctl(p->fd, EVIOCSABS(code), &abs))
    say(4, "%s: EVIOCSABS %#x: %s", p->node, code, strerror(errno));
}

static void pad_apply(struct pad *p) {
  set_range(p, ABS_MT_POSITION_X, &p->x);
  set_range(p, ABS_MT_POSITION_Y, &p->y);
  if (p->has_st) {
    set_range(p, ABS_X, &p->x);
    set_range(p, ABS_Y, &p->y);
  }
}

// ueventd deletes and recreates the node, so Android's EventHub reopens it. Our fd stays valid.
static void pad_bounce(struct pad *p) {
  char path[PATH_MAX];
  snprintf(path, sizeof path, "%s/class/input/%s/uevent", sys_dir, p->node);
  int fd = open(path, O_WRONLY | O_APPEND | O_CLOEXEC);
  if (fd < 0 || write(fd, "remove", 6) != 6 || write(fd, "add", 3) != 3)
    say(4, "can't bounce %s: %s", path, strerror(errno));
  if (fd >= 0) close(fd);
  p->bounce = false;
}

static void pad_close(struct pad *p) {
  close(p->fd);
  p->fd = -1;
}

// --- learning ---

static int margin(const struct axis *a, const struct side *s) {
  int m = (a->max - a->min) / 50;
  if (m < 8) m = 8;
  return s->grown ? (m / 4 > 2 ? m / 4 : 2) : m;  // past a learned edge: only a hair of noise
}

// d = how far the value is beyond this side's bound. Returns true if it is out of range.
static bool side_value(struct side *s, int d, const struct axis *a) {
  if (d <= margin(a, s)) return false;
  if (d > s->cur) s->cur = d;
  s->events++;
  return true;
}

static void axis_value(struct pad *p, struct axis *a, int v) {
  if (v < a->floor || v > a->ceiling) {
    if (!p->garbage_logged) say(4, "%s: ignoring implausible position %d", p->name, v);
    p->garbage_logged = true;
    return;
  }
  bool lo = side_value(&a->lo, a->min - v, a), hi = side_value(&a->hi, v - a->max, a);
  if (lo || hi) p->quiet_ms = 0;
}

// A touch ended: file its peak (only if it was out of range for at least 3 events), and return
// how far this side may now grow (0 = not at all).
static int side_end(struct side *s, int margin) {
  if (s->events < 3) s->cur = 0;
  s->events = 0;
  if (s->cur > s->peak[0]) {
    s->peak[1] = s->peak[0];
    s->peak[0] = s->cur;
  } else if (s->cur > s->peak[1]) {
    s->peak[1] = s->cur;
  }
  s->cur = 0;
  if (s->peak[1] <= margin) return 0;
  int grow = s->peak[1];
  s->peak[0] -= grow;  // still a candidate, now measured from the new bound
  s->peak[1] = 0;
  s->grown = true;
  return grow;
}

static bool axis_end(struct axis *a) {
  int lo = side_end(&a->lo, margin(a, &a->lo)), hi = side_end(&a->hi, margin(a, &a->hi));
  a->min -= lo;
  a->max += hi;
  return lo || hi;
}

static void pad_store(const struct pad *p) {
  store_put(p->key, (int[8]){p->x.min, p->x.max, p->y.min, p->y.max, p->x.dmin, p->x.dmax,
                             p->y.dmin, p->y.dmax});
}

static void pad_touch_end(struct pad *p, long long now) {
  struct axis ox = p->x, oy = p->y;
  bool gx = axis_end(&p->x), gy = axis_end(&p->y);
  p->quiet_ms += now - p->touch_start;
  if (gx || gy) {
    pad_store(p);
    say(6, "%s (%04x:%04x:%04x): x %d..%d -> %d..%d, y %d..%d -> %d..%d", p->name, p->id.bustype,
        p->id.vendor, p->id.product, ox.min, ox.max, p->x.min, p->x.max, oy.min, oy.max, p->y.min,
        p->y.max);
    pad_apply(p);
    p->bounce = true;
  } else if (!p->bounce && p->quiet_ms >= CONFIRM_MS) {
    say(6, "%s: range x %d..%d, y %d..%d confirmed, done watching", p->name, p->x.min, p->x.max,
        p->y.min, p->y.max);
    pad_close(p);
  }
}

static bool touching(const struct pad *p) {
  return p->slots || p->btn_touch;
}

static bool idle(const struct pad *p) {
  return !touching(p) && !p->keys;
}

static void pad_event(struct pad *p, const struct input_event *e, long long now) {
  bool was = touching(p);
  p->last_event = now;
  if (e->type == EV_SYN && e->code == SYN_DROPPED) {
    // We lost events and can't know the contact state. Forget it without ending a touch here,
    // so that one physical touch can't count as two.
    p->slots = 0;
    p->btn_touch = false;
    p->keys = 0;
    return;
  }
  if (e->type == EV_KEY && e->code == BTN_TOUCH) p->btn_touch = e->value;
  // other buttons and keys (BTN_LEFT, or a keyboard on the same node); 2 = autorepeat
  if (e->type == EV_KEY && e->code != BTN_TOUCH && (e->code < BTN_TOOL_PEN || e->code > BTN_TOOL_QUADTAP) &&
      e->code != BTN_TOOL_QUINTTAP && e->value != 2) {
    p->keys += e->value ? 1 : -1;
    if (p->keys < 0) p->keys = 0;
  }
  if (e->type == EV_ABS && e->code == ABS_MT_SLOT) p->slot = e->value;
  if (e->type == EV_ABS && e->code == ABS_MT_TRACKING_ID && p->slot >= 0 && p->slot < 64) {
    if (e->value < 0) p->slots &= ~(1ULL << p->slot);
    else p->slots |= 1ULL << p->slot;
  }
  if (e->type == EV_ABS && e->code == ABS_MT_POSITION_X) axis_value(p, &p->x, e->value);
  if (e->type == EV_ABS && e->code == ABS_MT_POSITION_Y) axis_value(p, &p->y, e->value);
  if (!was && touching(p)) p->touch_start = now;
  if (was && !touching(p)) pad_touch_end(p, now);
}

static void pad_read(struct pad *p, long long now) {
  struct input_event ev[64];
  while (p->fd >= 0) {
    ssize_t n = read(p->fd, ev, sizeof ev);
    if (n < 0 && errno == EINTR) continue;
    if (n == 0 || (n < 0 && errno == EAGAIN)) return;
    if (n < 0) {  // ENODEV: unplugged
      say(6, "%s: gone (%s)", p->node, strerror(errno));
      pad_close(p);
      return;
    }
    for (size_t i = 0; i < n / sizeof *ev && p->fd >= 0; i++) pad_event(p, &ev[i], now);
  }
}

static void pad_tick(struct pad *p, long long now) {
  if (p->fd >= 0 && p->bounce && idle(p) && now - p->last_event >= IDLE_MS) pad_bounce(p);
}

// --- device discovery ---

static bool has_bit(const unsigned long *bits, int n) {
  return bits[n / BITS_PER_LONG] >> (n % BITS_PER_LONG) & 1;
}

// The garbage limits come from the driver's own range (dmin..dmax), not from a widened one.
static void axis_limits(struct axis *a, int dmin, int dmax) {
  int span = dmax - dmin;
  a->dmin = dmin;
  a->dmax = dmax;
  a->floor = dmin - span;
  a->ceiling = dmax + span;
}

static bool axis_init(struct pad *p, int code, struct axis *a) {
  struct input_absinfo abs;
  if (ioctl(p->fd, EVIOCGABS(code), &abs) || abs.maximum <= abs.minimum) return false;
  *a = (struct axis){.min = abs.minimum, .max = abs.maximum};
  axis_limits(a, abs.minimum, abs.maximum);
  return true;
}

// Fills in *p (fd and node already set) if the device is a touchpad in Android's eyes.
static bool pad_probe(struct pad *p) {
  unsigned long props[INPUT_PROP_CNT / BITS_PER_LONG + 1] = {0};
  unsigned long abs[ABS_CNT / BITS_PER_LONG + 1] = {0};
  if (ioctl(p->fd, EVIOCGPROP(sizeof props), props) < 0 ||
      ioctl(p->fd, EVIOCGBIT(EV_ABS, sizeof abs), abs) < 0)
    return false;
  // a touchpad: pointer or clickpad, not a touchscreen (Android classifies them the same way)
  if (!(has_bit(props, INPUT_PROP_POINTER) || has_bit(props, INPUT_PROP_BUTTONPAD)) ||
      has_bit(props, INPUT_PROP_DIRECT))
    return false;
  // ABS_MT_SLOT: protocol B, like Android requires for a touchpad (touch ends are known)
  if (!has_bit(abs, ABS_MT_POSITION_X) || !has_bit(abs, ABS_MT_POSITION_Y) || !has_bit(abs, ABS_MT_SLOT))
    return false;
  if (!axis_init(p, ABS_MT_POSITION_X, &p->x) || !axis_init(p, ABS_MT_POSITION_Y, &p->y))
    return false;
  struct input_absinfo slot;
  if (ioctl(p->fd, EVIOCGABS(ABS_MT_SLOT), &slot) < 0) return false;
  p->slot = slot.value;
  if (ioctl(p->fd, EVIOCGID, &p->id) < 0) return false;
  if (ioctl(p->fd, EVIOCGNAME(sizeof p->name - 1), p->name) < 0) strcpy(p->name, "?");
  for (char *c = p->name; *c; c++)
    if ((unsigned char)*c < ' ') *c = ' ';  // the name goes into a tab/newline separated store
  p->has_st = has_bit(abs, ABS_X) && has_bit(abs, ABS_Y);
  snprintf(p->key, sizeof p->key, "%s|%04x:%04x:%04x:%04x|%s", dmi, p->id.bustype, p->id.vendor,
           p->id.product, p->id.version, p->name);
  return true;
}

// Widens the device to the stored range, if that is wider. Returns true if anything changed.
// The entry must be for the same driver range: either the device still has it (a fresh boot or
// replug), or it already has the stored range (we restarted). Anything else, e.g. a kernel
// update that changed the driver's range, drops the entry: it is learned again.
static bool pad_restore(struct pad *p) {
  int r[8];
  if (!store_get(p->key, r)) return false;
  bool fresh = p->x.min == r[4] && p->x.max == r[5] && p->y.min == r[6] && p->y.max == r[7];
  bool applied = p->x.min == r[0] && p->x.max == r[1] && p->y.min == r[2] && p->y.max == r[3];
  if (applied) {  // the kernel still has our range: the limits come from the stored driver range
    axis_limits(&p->x, r[4], r[5]);
    axis_limits(&p->y, r[6], r[7]);
  }
  bool sane = r[0] <= r[4] && r[1] >= r[5] && r[2] <= r[6] && r[3] >= r[7] &&
              r[0] >= p->x.floor && r[1] <= p->x.ceiling && r[2] >= p->y.floor && r[3] <= p->y.ceiling;
  if ((!fresh && !applied) || !sane) {
    say(4, "%s: stored range is for another driver range or implausible, learning again", p->name);
    axis_limits(&p->x, p->x.min, p->x.max);
    axis_limits(&p->y, p->y.min, p->y.max);
    return false;
  }
  p->x.lo.grown = r[0] < r[4];
  p->x.hi.grown = r[1] > r[5];
  p->y.lo.grown = r[2] < r[6];
  p->y.hi.grown = r[3] > r[7];
  if (applied) return false;
  p->x.min = r[0];
  p->x.max = r[1];
  p->y.min = r[2];
  p->y.max = r[3];
  pad_apply(p);
  say(6, "%s: stored range x %d..%d, y %d..%d applied", p->name, p->x.min, p->x.max, p->y.min,
      p->y.max);
  return true;
}

// hot = the node appeared after startup, so Android may already have opened it.
static void open_node(const char *node, bool hot) {
  char path[PATH_MAX];
  struct stat st;
  struct pad *p = NULL;
  if (strncmp(node, "event", 5) || strlen(node) >= sizeof p->node) return;
  snprintf(path, sizeof path, "%s/%s", dev_dir, node);
  // ueventd creates the node with its final mode and label (no window to retry for)
  int fd = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
  if (fd < 0) return;
  if (fstat(fd, &st)) st.st_rdev = 0;
  for (int i = 0; i < MAX_PADS; i++) {
    if (pads[i].fd >= 0 && pads[i].rdev == st.st_rdev) {
      struct input_id id;
      // Our own bounce recreated the node: the device is the same one, keep watching it.
      if (!ioctl(pads[i].fd, EVIOCGID, &id)) goto ignore;
      pad_close(&pads[i]);  // unplugged and replugged before we saw it go: the old fd is dead
    }
    if (pads[i].fd < 0 && !p) p = &pads[i];
  }
  if (!p) {
    static bool full_logged;
    if (!full_logged) say(4, "more than %d touchpad nodes: %s not watched", MAX_PADS, node);
    full_logged = true;
    goto ignore;
  }
  *p = (struct pad){.fd = fd, .rdev = st.st_rdev, .last_event = now_ms()};
  strcpy(p->node, node);
  if (!pad_probe(p)) {
    p->fd = -1;
    goto ignore;
  }
  p->bounce = pad_restore(p) && hot;
  return;
ignore:
  close(fd);
}

static void scan_nodes(void) {
  DIR *d = opendir(dev_dir);
  if (!d) return;
  for (struct dirent *e; (e = readdir(d));) open_node(e->d_name, false);
  closedir(d);
}

static void read_inotify(int ino) {
  char buf[4096] __attribute__((aligned(__alignof__(struct inotify_event))));
  ssize_t n;
  while ((n = read(ino, buf, sizeof buf)) > 0)
    for (char *q = buf; q < buf + n;) {
      struct inotify_event *e = (struct inotify_event *)q;
      if (e->len) open_node(e->name, true);
      q += sizeof *e + e->len;
    }
}

int main(void) {
  setup();
  // Watch before scanning, so that a node created in between is not missed.
  int ino = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
  if (ino < 0 || inotify_add_watch(ino, dev_dir, IN_CREATE) < 0) {
    say(4, "can't watch %s: %s", dev_dir, strerror(errno));
    return 1;
  }
  scan_nodes();
  for (;;) {
    struct pollfd fds[MAX_PADS + 1] = {{.fd = ino, .events = POLLIN}};
    int timeout = -1;
    for (int i = 0; i < MAX_PADS; i++) {
      fds[i + 1] = (struct pollfd){.fd = pads[i].fd, .events = POLLIN};  // poll skips fd -1
      if (pads[i].fd >= 0 && pads[i].bounce) timeout = IDLE_MS;
    }
    if (poll(fds, MAX_PADS + 1, timeout) < 0) {
      if (errno == EINTR) continue;
      say(4, "poll: %s", strerror(errno));
      return 1;
    }
    long long now = now_ms();
    // Pads first: an unplugged one is forgotten before its node name can come back in inotify.
    for (int i = 0; i < MAX_PADS; i++) {
      if (fds[i + 1].revents) pad_read(&pads[i], now);
      pad_tick(&pads[i], now);
    }
    if (fds[0].revents) read_inotify(ino);
  }
}
