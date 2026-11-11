// churro-logger: started by the kernel instead of /init (rdinit=/churro/logger, "debug" boot
// entries only). Forks children that copy
//   - the kernel log (which also carries Android init's messages) -> boot.log
//   - Android's own log (logcat: main/system/crash buffers, read from logd) -> logcat.log
//   - ALSA state (/proc/asound: card list, HD-audio codec dumps, logged on change) -> audio.log
// on the CHURRO-LOG partition (FAT32, readable from Windows), then execs the real /init as PID 1.
// The *.log / *.prev.log files are created by churro.sh at a fixed size, filled with blank lines;
// the logger only overwrites them in place (text ends at the first empty line), so the FAT and
// the directory never change at boot: a hang + power button can't corrupt the file system.
// Built static by churro.sh (host cc); runs before Android's init, so no bionic needed.
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define PARTNAME "CHURRO-LOG"
#define LOG_SIZE (64 << 20)  // only used to recreate a log file deleted from Windows
#define FULL_MSG "[churro-logger: log full, logging stopped]\n"
#define BUF_MAX 65536

static char io[65536];

// Find a CHURRO-LOG partition among the entries of a sysfs dir ("sys" is mounted in cwd):
// sys/class/block (any disk) or sys/class/block/<disk> (that disk's partitions); fills major/minor.
static int find_part(const char *dir, unsigned *maj, unsigned *min) {
  DIR *d = opendir(dir);
  struct dirent *e;
  int found = 0;
  while (d && !found && (e = readdir(d))) {
    char p[512], buf[1024];
    snprintf(p, sizeof p, "%s/%s/uevent", dir, e->d_name);
    FILE *f = fopen(p, "r");
    if (!f) continue;
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    buf[n] = 0;
    char *maj_s = strstr(buf, "MAJOR="), *min_s = strstr(buf, "MINOR=");
    if (strstr(buf, "PARTNAME=" PARTNAME "\n") && maj_s && min_s) {
      *maj = strtoul(maj_s + 6, NULL, 10);
      *min = strtoul(min_s + 6, NULL, 10);
      found = 1;
    }
  }
  if (d) closedir(d);
  return found;
}

static int read_str(const char *path, char *buf, size_t n) {  // first line, 0 = read
  FILE *f = fopen(path, "r");
  if (!f) return -1;
  int ok = fgets(buf, n, f) != NULL;
  fclose(f);
  if (ok) buf[strcspn(buf, "\n")] = 0;
  return ok ? 0 : -1;
}

// 1 if whole disk <name>'s GPT has a partition with unique GUID <uuid> (text, any case)
static int disk_has(const char *name, const char *uuid) {
  char p[300], v[64];
  unsigned ma, mi, lbs = 512;
  snprintf(p, sizeof p, "sys/class/block/%s/partition", name);
  if (!access(p, F_OK)) return 0;  // a partition, not a disk
  snprintf(p, sizeof p, "sys/class/block/%s/dev", name);
  if (read_str(p, v, sizeof v) || sscanf(v, "%u:%u", &ma, &mi) != 2) return 0;
  snprintf(p, sizeof p, "sys/class/block/%s/queue/logical_block_size", name);
  if (!read_str(p, v, sizeof v)) lbs = strtoul(v, NULL, 10);
  unlink("disk");
  if (mknod("disk", S_IFBLK | 0600, makedev(ma, mi))) return 0;
  int fd = open("disk", O_RDONLY | O_CLOEXEC), found = 0;
  unsigned char h[92], e[128];
  if (fd >= 0 && pread(fd, h, sizeof h, lbs) == sizeof h && !memcmp(h, "EFI PART", 8)) {
    uint64_t lba; uint32_t num, esz;
    memcpy(&lba, h + 72, 8); memcpy(&num, h + 80, 4); memcpy(&esz, h + 84, 4);
    for (uint32_t i = 0; i < num && i < 256 && esz >= 128 && !found; i++) {
      if (pread(fd, e, sizeof e, lba * lbs + (uint64_t)i * esz) != sizeof e) break;
      const unsigned char *g = e + 16;  // unique partition GUID, mixed-endian
      char t[40];
      snprintf(t, sizeof t, "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
               g[3], g[2], g[1], g[0], g[5], g[4], g[7], g[6], g[8], g[9], g[10], g[11], g[12], g[13], g[14], g[15]);
      found = !strcasecmp(t, uuid);
    }
  }
  if (fd >= 0) close(fd);
  unlink("disk");
  return found;
}

// The CHURRO-LOG to log to: the one on the disk GRUB booted from (androidboot.boot_part_uuid =
// the ID of its EFI partition, read fresh at every boot), so a second disk with a Churro on it
// (an install, a stick) never gets this boot's log. Without that ID, or if its disk hasn't shown
// up after <wait> polls, any CHURRO-LOG. 1 = found.
static int pick(unsigned *maj, unsigned *min, int poll, int wait) {
  static char cmd[4096];
  char uuid[64] = "", *u;
  if (!cmd[0]) read_str("proc/cmdline", cmd, sizeof cmd);
  if ((u = strstr(cmd, "androidboot.boot_part_uuid="))) sscanf(u + 27, "%63[0-9A-Fa-f-]", uuid);
  if (uuid[0]) {
    DIR *d = opendir("sys/class/block");
    struct dirent *e;
    int ok = 0;
    while (d && !ok && (e = readdir(d))) {
      if (e->d_name[0] == '.' || !disk_has(e->d_name, uuid)) continue;
      char dir[300];
      snprintf(dir, sizeof dir, "sys/class/block/%s", e->d_name);
      ok = find_part(dir, maj, min);
    }
    if (d) closedir(d);
    if (ok) return 1;
  }
  return (!uuid[0] || poll >= wait) && find_part("sys/class/block", maj, min);
}

// Report a failed step in the kernel log itself (visible on screen / serial / boot.log).
static void fail(const char *what) {
  char m[256];
  int e = errno, fd = open("kmsg", O_WRONLY | O_CLOEXEC);
  if (fd < 0) return;
  if (write(fd, m, snprintf(m, sizeof m, "<3>churro-logger: %s failed: %s\n", what, strerror(e)))) {}
  close(fd);
}

// Overwrite [from, to) with blank lines.
static int fill(int fd, off_t from, off_t to) {
  memset(io, '\n', sizeof io);
  while (from < to) {
    size_t n = to - from < (off_t)sizeof io ? (size_t)(to - from) : sizeof io;
    if (pwrite(fd, io, n, from) != (ssize_t)n) return -1;
    from += n;
  }
  return 0;
}

// Length of the log text at the start of the file: it ends at the first empty line.
static off_t text_len(int fd) {
  off_t pos = 0;
  char prev = '\n';  // a file that starts with a blank line holds no text
  ssize_t n;
  while ((n = pread(fd, io, sizeof io, pos)) > 0) {
    for (ssize_t i = 0; i < n; i++) {
      if (io[i] == '\n' && prev == '\n') return pos + i;
      prev = io[i];
    }
    pos += n;
  }
  return pos;
}

// Open a log file; if it was deleted (e.g. from Windows), recreate it once, blank, fixed size.
static int open_log(const char *path) {
  int fd = open(path, O_RDWR | O_CLOEXEC);
  if (fd >= 0 || errno != ENOENT) return fd;
  fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
  if (fd >= 0 && (fill(fd, 0, LOG_SIZE) || fsync(fd))) {
    close(fd);
    return -1;
  }
  return fd;
}

// A fixed-size log file written in place, with a write-behind buffer.
struct sink {
  int fd;
  off_t pos, end;
  size_t used;
  char buf[BUF_MAX + 8300];
};

// Rotate in place (last boot's text -> prev, blanking prev's older text; blank cur), then open.
static int sink_open(struct sink *s, const char *cur, const char *prv) {
  int out = open_log(cur), prev = open_log(prv);
  if (out < 0) return -1;
  off_t size = lseek(out, 0, SEEK_END), len = text_len(out);
  if (size < 4096) { errno = EFBIG; return -1; }
  if (prev >= 0) {
    off_t psize = lseek(prev, 0, SEEK_END), plen = text_len(prev), pos = 0;
    off_t keep = len < psize ? len : psize;
    while (pos < keep) {
      ssize_t n = pread(out, io, keep - pos < (off_t)sizeof io ? keep - pos : (off_t)sizeof io, pos);
      if (n <= 0 || pwrite(prev, io, n, pos) != n) break;
      pos += n;
    }
    if (plen > pos) fill(prev, pos, plen < psize ? plen : psize);
    fsync(prev);
    close(prev);
  }
  if (fill(out, 0, len) || fsync(out)) return -1;
  s->fd = out;
  s->pos = 0;
  s->end = size - (off_t)sizeof FULL_MSG;  // keep room for the "full" note
  s->used = 0;
  return 0;
}

// Write the buffer out and fsync. Returns -1 when the file is full (or broken): stop logging.
static int sink_flush(struct sink *s) {
  if (!s->used) return 0;
  int full = s->pos + (off_t)s->used > s->end;
  if (full) s->used = s->end - s->pos;  // ponytail: stop when full; ring buffer if that ever matters
  if (pwrite(s->fd, s->buf, s->used, s->pos) != (ssize_t)s->used) { fail("writing log"); return -1; }
  s->pos += s->used;
  s->used = 0;
  if (full && pwrite(s->fd, FULL_MSG, sizeof FULL_MSG - 1, s->pos) < 0) {}
  fsync(s->fd);
  return full ? -1 : 0;
}

// Kernel log: "6,1234,5678901,-;message" -> "[    5.678901] message"
static void kmsg_loop(int k) {
  static struct sink s;
  if (sink_open(&s, "mnt/boot.log", "mnt/boot.prev.log")) { fail("opening boot.log"); return; }
  static char rec[8193];
  for (;;) {
    ssize_t n = read(k, rec, sizeof rec - 1);
    int drained = 0;
    if (n > 0) {
      rec[n] = 0;
      char *semi = strchr(rec, ';'), *c1 = strchr(rec, ','), *c2 = c1 ? strchr(c1 + 1, ',') : NULL;
      if (rec[0] != ' ' && semi && c2) {  // skip continuation/dictionary lines
        unsigned long long us = strtoull(c2 + 1, NULL, 10);
        s.used += sprintf(s.buf + s.used, "[%5llu.%06llu] %s", us / 1000000, us % 1000000, semi + 1);
      }
    } else if (errno == EPIPE) {
      s.used += sprintf(s.buf + s.used, "[churro-logger: messages lost]\n");
    } else if (errno == EAGAIN) {
      drained = 1;
    } else {
      fail("reading kmsg");
      return;
    }
    if (!drained && s.used < BUF_MAX) continue;
    if (sink_flush(&s)) return;
    if (drained) {
      struct pollfd p = {k, POLLIN, 0};
      poll(&p, 1, -1);
    }
  }
}

// Android log, straight from logd's reader socket (what logcat does). The socket lives in init's
// mount namespace; proc/1/root reaches it from ours.
struct logger_entry {
  uint16_t len, hdr_size;
  int32_t pid;
  uint32_t tid, sec, nsec, lid, uid;
};

static void logcat_loop(void) {
  static struct sink s;
  if (sink_open(&s, "mnt/logcat.log", "mnt/logcat.prev.log")) { fail("opening logcat.log"); return; }
  static const char prio[] = "??VDIWEFS";
  static unsigned char pkt[5 * 1024 + 64];
  for (;;) {
    int fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    strcpy(a.sun_path, "proc/1/root/dev/socket/logdr");
    if (fd < 0) return;
    if (connect(fd, (struct sockaddr *)&a, sizeof a)) {  // logd not up yet (or restarting)
      close(fd);
      sleep(1);
      continue;
    }
    // big receive buffer: logd drops readers that fall behind (history burst at connect, fsyncs)
    int rcv = 16 << 20;
    if (setsockopt(fd, SOL_SOCKET, SO_RCVBUFFORCE, &rcv, sizeof rcv))
      setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, sizeof rcv);  // capped at rmem_max
    const char *cmd = "stream lids=0,1,3,4";  // main, radio, system, crash
    if (write(fd, cmd, strlen(cmd)) < 0) { close(fd); sleep(1); continue; }
    for (;;) {
      ssize_t n = recv(fd, pkt, sizeof pkt - 1, s.used ? MSG_DONTWAIT : 0);
      if (n < 0 && errno == EAGAIN) {  // drained: persist, then block for more
        if (sink_flush(&s)) return;
        continue;
      }
      if (n <= 0) break;  // logd went away: reconnect
      struct logger_entry *h = (struct logger_entry *)pkt;
      size_t hs = h->hdr_size >= 20 ? h->hdr_size : sizeof *h;
      if ((size_t)n < hs + 2) continue;
      pkt[n] = 0;
      unsigned char *p = pkt + hs, *end = pkt + n;
      const char *tag = (const char *)p + 1;
      char *msg = (char *)p + 1 + strnlen(tag, end - p - 1) + 1;
      if ((unsigned char *)msg > end) msg = (char *)end;
      time_t t = h->sec;
      struct tm tm;
      gmtime_r(&t, &tm);
      s.used += sprintf(s.buf + s.used, "%02d:%02d:%02d.%03u %5d %5u %c %s: ", tm.tm_hour, tm.tm_min,
                        tm.tm_sec, h->nsec / 1000000, h->pid, h->tid, p[0] < 9 ? prio[p[0]] : '?', tag);
      // one entry per line; continuation lines indented (an empty line would end the log text)
      for (char *c = msg; *c && s.used < BUF_MAX + 8000; c++) {
        if (*c == '\n') {
          if (c[1]) s.used += sprintf(s.buf + s.used, "\n    ");
        } else {
          s.buf[s.used++] = *c;
        }
      }
      s.buf[s.used++] = '\n';
      if (s.used >= BUF_MAX && sink_flush(&s)) return;
    }
    close(fd);
  }
}

// Read a small proc file (whole) into a static buffer; NULL if missing.
static char *slurp(const char *path) {
  static char b[256 << 10];
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  ssize_t n, len = 0;
  if (fd < 0) return NULL;
  while (len < (ssize_t)sizeof b - 1 && (n = read(fd, b + len, sizeof b - 1 - len)) > 0) len += n;
  close(fd);
  b[len] = 0;
  return b;
}

// Append text, each line prefixed with tag; skips empty lines (they would end the log text).
static int put(struct sink *s, const char *tag, const char *t) {
  for (const char *l = t, *e; t && *l; l = *e ? e + 1 : e) {
    e = strchrnul(l, '\n');
    if (e > l) s->used += sprintf(s->buf + s->used, "%s %.*s\n", tag, (int)(e - l > 8000 ? 8000 : e - l), l);
    if (s->used >= BUF_MAX && sink_flush(s)) return -1;
  }
  return 0;
}

// Log path's text when it changes: all of it the first time (or when its line count changes),
// then only the changed lines, each after its "Node 0x.." header. *prev keeps the last copy.
static int track(struct sink *s, const char *tag, const char *path, char **prev) {
  char *t = slurp(path), *o = *prev;
  if (!t || (o && !strcmp(o, t))) return 0;
  int nt = 0, no = 0;
  for (char *c = t; *c; c++) nt += *c == '\n';
  for (char *c = o; o && *c; c++) no += *c == '\n';
  if (!o || nt != no) {
    if (put(s, tag, t)) return -1;
  } else {
    const char *node = NULL, *shown = NULL;
    for (const char *l = t, *m = o; *l; ) {
      const char *e = strchrnul(l, '\n'), *f = strchrnul(m, '\n');
      if (!strncmp(l, "Node ", 5)) node = l;
      if (e - l != f - m || memcmp(l, m, e - l)) {
        if (node && node != shown && node != l) {
          s->used += sprintf(s->buf + s->used, "%s %.*s\n", tag, (int)(strchrnul(node, '\n') - node), node);
          shown = node;
        }
        if (e > l) s->used += sprintf(s->buf + s->used, "%s %.*s\n", tag, (int)(e - l > 8000 ? 8000 : e - l), l);
        if (s->used >= BUF_MAX && sink_flush(s)) return -1;
      }
      l = *e ? e + 1 : e;
      m = *f ? f + 1 : f;
    }
  }
  free(o);
  *prev = strdup(t);
  return 0;
}

// Audio debug: once a second, /proc/asound/cards and every HD-audio codec dump (pin controls,
// amp gain/mute, EAPD, and the DACs' "Converter: stream=N" - non-zero while Android streams to
// it), logged when they change: the mixer/codec state before, during and after playback.
// (The per-PCM status/hw_params files need CONFIG_SND_VERBOSE_PROCFS, which GKI leaves off and
// which changes struct snd_pcm_substream, i.e. the kABI the image's sound modules are built for.)
// Times are UTC, like logcat.log.
static void audio_loop(void) {
  static struct sink s;
  static char *prev[8 * 4 + 1];
  char p[64], tag[48];
  if (sink_open(&s, "mnt/audio.log", "mnt/audio.prev.log")) { fail("opening audio.log"); return; }
  s.used += sprintf(s.buf, "churro-logger: sampling /proc/asound once a second\n");
  for (;;) {
    struct timespec ts;
    struct tm tm;
    clock_gettime(CLOCK_REALTIME, &ts);
    gmtime_r(&ts.tv_sec, &tm);
    snprintf(tag, sizeof tag, "%02d:%02d:%02d cards", tm.tm_hour, tm.tm_min, tm.tm_sec);
    if (track(&s, tag, "proc/asound/cards", &prev[32])) return;
    for (int c = 0; c < 8; c++)
      for (int k = 0; k < 4; k++) {
        snprintf(p, sizeof p, "proc/asound/card%d/codec#%d", c, k);
        snprintf(tag, sizeof tag, "%02d:%02d:%02d C%d#%d", tm.tm_hour, tm.tm_min, tm.tm_sec, c, k);
        if (track(&s, tag, p, &prev[c * 4 + k])) return;
      }
    if (sink_flush(&s)) return;
    sleep(1);
  }
}

static void logger(void) {
  // Private mount namespace: first-stage init moves every mount it can see into the new root
  // and aborts if one fails, so ours must stay invisible to it.
  if (unshare(CLONE_NEWNS) || mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL)) return;
  mkdir("/churro-log", 0700);
  if (mount("tmpfs", "/churro-log", "tmpfs", 0, "mode=0700") || chdir("/churro-log")) return;
  // relative paths from here on: init later deletes the ramdisk (incl. /churro-log) but our cwd
  // keeps this tmpfs alive. No devtmpfs in GKI -> make the device nodes ourselves.
  mkdir("sys", 0700);
  mkdir("proc", 0700);
  mkdir("mnt", 0700);
  if (mount("sysfs", "sys", "sysfs", 0, NULL) || mount("proc", "proc", "proc", 0, NULL)) return;
  mknod("kmsg", S_IFCHR | 0600, makedev(1, 11));
  int k = open("kmsg", O_RDONLY | O_NONBLOCK | O_CLOEXEC);
  if (k < 0) return;

  // Poll fast: the disk usually appears just before Android loads its SELinux policy, and
  // mounting is easier (fewer rules) while that hasn't happened yet.
  // The boot disk's CHURRO-LOG (pick); any after 10 s if that disk never shows up.
  unsigned maj = 0, min = 0;
  for (int i = 0; !pick(&maj, &min, i, 100); i++) {
    if (i >= 3000) { errno = ENODEV; fail("finding partition " PARTNAME " (5 min)"); return; }
    usleep(100000);
  }
  if (mknod("part", S_IFBLK | 0600, makedev(maj, min))) { fail("mknod"); return; }
  if (mount("part", "mnt", "vfat", MS_NOATIME, NULL)) { fail("mounting " PARTNAME); return; }
  if (fork() == 0) {
    logcat_loop();
    _exit(0);
  }
  if (fork() == 0) {
    audio_loop();
    _exit(0);
  }
  kmsg_loop(k);
}

int main(int argc, char **argv) {
  (void)argc;
  if (fork() == 0) {
    logger();
    _exit(0);
  }
  argv[0] = "/init";
  execv("/init", argv);
  return 1;
}
