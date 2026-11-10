/* churro-drm: the screens the GPU drivers see, one line each, as the kernel decoded them:
 *   <panel|ext|fw> <width px> <height px> <width mm> <height mm> card<N>-<connector>
 * panel = built-in (eDP, LVDS, DSI, DPI), ext = monitor, fw = firmware framebuffer (simpledrm).
 * Sizes come from the kernel's EDID parsing (the EDID's screen size, in cm): the panel of the
 * MSI Vector 16 declares 640 mm in its first EDID timing, 35 cm there. 0 mm = unknown.
 * Waits (max 5 s) until every PCI display device has its DRM driver, or a built-in panel is
 * connected (it wins anyway): on hybrid laptops the GPU without the panel can be ready first.
 * Outputs a driver hasn't probed yet ("unknown": no status, no EDID; drivers without a framebuffer
 * console, like Google's xe, leave them so until the display HAL starts) are probed by writing
 * "detect" to their sysfs status, which works whoever holds the device (asking for a connector
 * with no mode buffer only probes when we are DRM master). Errors go to stderr (boot log).
 * Static (host compiler, like churro-mixer), run by churro-density. */
#include <dirent.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>

#define CARDS 16

static int driver(int fd, char *name, size_t len)	/* 0 = got the driver name */
{
	struct drm_version v = { .name = name, .name_len = len - 1 };

	memset(name, 0, len);
	return ioctl(fd, DRM_IOCTL_VERSION, &v);
}

static int gpu_present(void)	/* a DRM device other than simpledrm */
{
	char path[32], name[32];
	int i, fd, found = 0;

	for (i = 0; i < CARDS && !found; i++) {
		snprintf(path, sizeof(path), "/dev/dri/card%d", i);
		if ((fd = open(path, O_RDONLY | O_CLOEXEC)) < 0)
			continue;
		found = !driver(fd, name, sizeof(name)) && strcmp(name, "simpledrm");
		close(fd);
	}
	return found;
}

static int pci_gpus_pending(void)	/* PCI display devices without a DRM device yet */
{
	char path[300], cls[16] = "";
	struct dirent *e;
	DIR *d = opendir("/sys/bus/pci/devices");
	int fd, n = 0;

	while (d && (e = readdir(d))) {
		snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/class", e->d_name);
		if ((fd = open(path, O_RDONLY | O_CLOEXEC)) < 0)
			continue;
		memset(cls, 0, sizeof(cls));
		if (read(fd, cls, sizeof(cls) - 1) < 0)
			cls[0] = 0;
		close(fd);
		snprintf(path, sizeof(path), "/sys/bus/pci/devices/%s/drm", e->d_name);
		n += !strncmp(cls, "0x03", 4) && access(path, F_OK);
	}
	if (d)
		closedir(d);
	return n;
}

static const char *type_name(uint32_t t)
{
	static const char *n[] = { "Unknown", "VGA", "DVI-I", "DVI-D", "DVI-A", "Composite",
		"SVIDEO", "LVDS", "Component", "DIN", "DP", "HDMI-A", "HDMI-B", "TV", "eDP",
		"Virtual", "DSI", "DPI", "Writeback", "SPI", "USB" };

	return t < sizeof(n) / sizeof(n[0]) ? n[t] : "Unknown";
}

static int builtin(uint32_t t)
{
	return t == DRM_MODE_CONNECTOR_eDP || t == DRM_MODE_CONNECTOR_LVDS ||
	       t == DRM_MODE_CONNECTOR_DSI || t == DRM_MODE_CONNECTOR_DPI;
}

/* card(N, print, panels): probe card N's outputs (only built-in ones if panels), print the
 * connected ones if print; returns 1 if a built-in panel is connected */
static int card(int i, int print, int panels)
{
	struct drm_mode_card_res res = { 0 };
	uint32_t *ids;
	char path[32], name[32];
	unsigned c;
	int fd, fw, panel = 0;

	snprintf(path, sizeof(path), "/dev/dri/card%d", i);
	if ((fd = open(path, O_RDWR | O_CLOEXEC)) < 0)
		return 0;
	fw = !driver(fd, name, sizeof(name)) && !strcmp(name, "simpledrm");
	if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res) || !res.count_connectors ||
	    !(ids = calloc(res.count_connectors, sizeof(*ids)))) {
		close(fd);
		return 0;
	}
	res.connector_id_ptr = (uintptr_t)ids;
	res.count_fbs = res.count_crtcs = res.count_encoders = 0;
	if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res))
		res.count_connectors = 0;
	for (c = 0; c < res.count_connectors; c++) {
		struct drm_mode_get_connector conn = { .connector_id = ids[c] };
		struct drm_mode_modeinfo *modes, *m;
		unsigned k, n;

		if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &conn) ||	/* probes if master */
		    (panels && !builtin(conn.connector_type)))
			continue;
		if (conn.connection == 3) {	/* unknown: not probed yet */
			char st[64];
			int s;

			snprintf(st, sizeof(st), "/sys/class/drm/card%d-%s-%u/status", i,
				 type_name(conn.connector_type), conn.connector_type_id);
			if ((s = open(st, O_WRONLY | O_CLOEXEC)) < 0 || write(s, "detect", 6) != 6)
				perror(st);	/* stays unknown: skipped (stderr -> boot log) */
			if (s >= 0)
				close(s);
			conn.count_modes = conn.count_props = conn.count_encoders = 0;	/* no buffers */
			if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &conn))
				continue;
		}
		panel |= conn.connection == 1 && builtin(conn.connector_type) && !fw;
		if (!print || conn.connection != 1 || !(n = conn.count_modes) ||
		    !(modes = calloc(n, sizeof(*modes))))
			continue;
		conn.modes_ptr = (uintptr_t)modes;
		conn.count_props = conn.count_encoders = 0;
		if (!ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &conn) && conn.count_modes <= n) {
			for (m = modes, k = 0; k < conn.count_modes; k++)	/* preferred, else first */
				if (modes[k].type & DRM_MODE_TYPE_PREFERRED) {
					m = &modes[k];
					break;
				}
			printf("%s %u %u %u %u card%d-%s-%u\n",
			       fw ? "fw" : builtin(conn.connector_type) ? "panel" : "ext",
			       m->hdisplay, m->vdisplay, conn.mm_width, conn.mm_height, i,
			       type_name(conn.connector_type), conn.connector_type_id);
		}
		free(modes);
	}
	free(ids);
	close(fd);
	return panel;
}

int main(void)
{
	struct timespec t = { 0, 100 * 1000 * 1000 };
	int i, c, panel = 0;

	for (i = 0; i < 50; i++) {
		if (gpu_present()) {
			if (!pci_gpus_pending())
				break;
			for (c = 0; c < CARDS && !panel; c++)
				panel = card(c, 0, 1);
			if (panel)
				break;
		}
		nanosleep(&t, NULL);
	}
	for (c = 0; c < CARDS; c++)
		card(c, 1, 0);
	return 0;
}
