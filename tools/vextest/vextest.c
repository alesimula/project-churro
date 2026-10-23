// vextest — userspace exerciser for the Churro VEX #UD emulator (kmod/patches/vex-emulate.patch).
// Static, nostdlib: also usable as /init in a bare initramfs for the gap-CPU QEMU test.
//
// For each of the 9 emulated instructions (VEX.66.0F38 0x50-0x53, 0xb4/0xb5;
// VEX.66.0F3A 0xCE/0xCF GFNI), in 128/256-bit
// form, with register and memory operands (incl. SIB, RIP-relative and extended-register forms),
// run the instruction via hand-encoded .byte sequences and compare against a scalar reference.
// If the CPU has the instruction natively (CPUID), the same run validates the reference model.
//
// Verdict lines on stdout (fd 1):  VEXTEST <op>[/<width>/<form>] <native|emu> ok|FAIL
// Summary: VEXTEST PASS <n>/<m>  (exit code 0) or VEXTEST FAIL <failed> (exit 1-ish via exit syscall).

typedef unsigned char u8;
typedef unsigned int u32;
typedef unsigned long long u64;

extern void op50_128_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void op50_256_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void op51_128_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void op51_256_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void op52_128_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void op52_256_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void op53_128_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void op53_256_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void opb4_128_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void opb4_256_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void opb5_128_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void opb5_256_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void op52_256_mem_ind(u32 *r, const u32 *a, const u32 *b, const u32 *acc);  // [rax-8]
extern void op52_256_mem_sib(u32 *r, const u32 *a, const u32 *b, const u32 *acc);  // [r9+r10*2+64]
extern void op52_256_mem_rip(u32 *r, const u32 *a, const u32 *b, const u32 *acc);  // [rip+disp]
extern void op52_256_reghi(u32 *r, const u32 *a, const u32 *b, const u32 *acc);    // ymm8,ymm9,ymm10
extern void opb4_256_mem_sib(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void opgb_128_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);    // gf2p8affineqb imm=0x63
extern void opgb_256_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void opge_128_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);    // gf2p8affineinvqb imm=0xa4
extern void opge_256_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void opgf_128_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);    // gf2p8mulb
extern void opgf_256_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void opgb_256_mem_sib(u32 *r, const u32 *a, const u32 *b, const u32 *acc); // affineqb ymm [r9+r10*2+64] imm=0x63
extern void sha256rnds2_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void sha256msg1_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void sha256msg2_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void sha256msg2_mem_sib(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void sha1nexte_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void sha1msg1_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void sha1msg2_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void sha1rnds4_i0(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void sha1rnds4_i1(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void sha1rnds4_i2(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void sha1rnds4_i3(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void pc_128_i00(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void pc_256_i00(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void pc_256_i11(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void pc_256_i01(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void pc_256_i10(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void sha256msg1_rex45(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void sha256msg2_rex44(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void sha1nexte_rex41(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void sha256rnds2_rex45(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void ra_chain(u32 *x, const u32 *m);
extern void rav_chain(u32 *x, const u32 *m);
extern void adcx_r64_rex(u64 *s), adox_r64(u64 *s), adcx_r32(u64 *s), adox_m64_rex(u64 *s), adcx_m32(u64 *s);
extern void vaesenc_256_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void vaesenclast_256_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void vaesdec_256_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void vaesdeclast_256_reg(u32 *r, const u32 *a, const u32 *b, const u32 *acc);
extern void wssd_chain_256(u32 *out, const u32 *a, const u32 *b, const u32 *acc, unsigned long rounds);
extern void wssd_chain_256r1(u32 *out, const u32 *a, const u32 *b, const u32 *acc, unsigned long rounds);
extern void xavg_chain_256(u32 *out, const u32 *a, const u32 *b, const u32 *acc, unsigned long rounds);
extern void xpadd_chain_256(u32 *out, const u32 *a, const u32 *b, const u32 *acc, unsigned long rounds);
extern void m52_chain_256(u32 *out, const u32 *a, const u32 *b, const u32 *acc, unsigned long rounds);

// ------- syscalls -------
static long sys1(long n, long a) {
	long r;
	__asm__ volatile("syscall" : "=a"(r) : "a"(n), "D"(a) : "rcx", "r11", "memory");
	return r;
}
static long sys3(long n, long a, long b, long c) {
	long r;
	__asm__ volatile("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c) : "rcx", "r11", "memory");
	return r;
}
static long outfd = 1;
static int guest_mode;
static void say(const char *s) { long n = 0; while (s[n]) n++; sys3(1, outfd, (long)s, n); }
static char lbuf[256];
static int lpos;
static void lb_flush(void) {
	if (!lpos)
		return;
	if (guest_mode) {
		// fresh fd per record: avoids devkmsg "continuation" swallowing later lines
		lbuf[lpos] = 0;
		long f = sys3(2, (long)"/dev/kmsg", 1, 0);
		if (f >= 0) {
			sys3(1, f, (long)lbuf, lpos);
			sys1(3, f);
		}
	} else {
		sys3(1, outfd, (long)lbuf, lpos);
	}
	lpos = 0;
}
static void lbs(const char *s) { while (*s && lpos < 250) lbuf[lpos++] = *s++; }
static void lbx(u64 v) { char b[17]; int i = 16; b[i] = 0; do b[--i] = "0123456789abcdef"[v & 15], v >>= 4; while (v); lbs(b + i); }
static void lbd(u64 v) { char b[21]; int i = 20; b[i] = 0; do b[--i] = '0' + (v % 10), v /= 10; while (v); lbs(b + i); }
static void sayx(u64 v) { char b[17]; int i = 16; b[i] = 0; do b[--i] = "0123456789abcdef"[v & 15], v >>= 4; while (v); say(b + i); }
static void sayd(u64 v) { char b[21]; int i = 20; b[i] = 0; do b[--i] = '0' + (v % 10), v /= 10; while (v); say(b + i); }

// cpuid leaf 7 subleaf 1: EAX bit 4 = AVX_VNNI, EAX bit 23 = AVX_IFMA (the VEX forms)
static void cpuid71(u32 *eax, u32 *edx) {
	u32 a = 7, c = 1, bx, cx, dx;
	__asm__ volatile("cpuid" : "+a"(a), "=b"(bx), "+c"(c), "=d"(dx) : : "memory");
	*eax = a; *edx = dx;
}
// cpuid leaf 7 subleaf 0: ECX bit 8 = GFNI, bit 9 = VAES, bit 10 = VPCLMULQDQ; EBX bit 29 = SHA-NI
static u32 cpuid70_ecx(void) {
	u32 a = 7, c = 0, bx, dx;
	__asm__ volatile("cpuid" : "+a"(a), "=b"(bx), "+c"(c), "=d"(dx) : : "memory");
	return c;	// ECX comes back in c
}
static u32 cpuid70_ebx(void) {
	u32 a = 7, c = 0, bx, cx, dx;
	__asm__ volatile("cpuid" : "+a"(a), "=b"(bx), "+c"(c), "=d"(dx) : : "memory");
	return bx;
}

// ------- reference model (same semantics as the kernel emulator) -------
static int sat32(long long v) { return v > 2147483647LL ? 2147483647LL : v < -2147483648LL ? -2147483648LL : (int)v; }

static void ref_50(u32 *d, const u32 *acc, const u32 *a, const u32 *b, int lanes) {
	for (int i = 0; i < lanes; i++) {
		const unsigned char *ab = (const unsigned char *)&a[i];
		const signed char *bb = (const signed char *)&b[i];
		int p = 0;
		for (int k = 0; k < 4; k++) p += (int)ab[k] * bb[k];
		d[i] = acc[i] + (u32)p;
	}
}
static void ref_51(u32 *d, const u32 *acc, const u32 *a, const u32 *b, int lanes) {
	for (int i = 0; i < lanes; i++) {
		const unsigned char *ab = (const unsigned char *)&a[i];
		const signed char *bb = (const signed char *)&b[i];
		int p = 0;
		for (int k = 0; k < 4; k++) p += (int)ab[k] * bb[k];
		d[i] = (u32)sat32((long long)(int)acc[i] + p);
	}
}
static void ref_52(u32 *d, const u32 *acc, const u32 *a, const u32 *b, int lanes) {
	for (int i = 0; i < lanes; i++) {
		const short *aw = (const short *)&a[i], *bw = (const short *)&b[i];
		d[i] = acc[i] + (u32)((int)aw[0] * bw[0] + (int)aw[1] * bw[1]);
	}
}
static void ref_53(u32 *d, const u32 *acc, const u32 *a, const u32 *b, int lanes) {
	for (int i = 0; i < lanes; i++) {
		const short *aw = (const short *)&a[i], *bw = (const short *)&b[i];
		d[i] = (u32)sat32((long long)(int)acc[i] + (long long)(int)aw[0] * bw[0] + (long long)(int)aw[1] * bw[1]);
	}
}
static void ref_m52(u32 *d_, const u32 *acc_, const u32 *a_, const u32 *b_, int lanes, int high) {
	u64 *d = (u64 *)d_;
	const u64 *acc = (const u64 *)acc_, *a = (const u64 *)a_, *b = (const u64 *)b_;
	const u64 m52 = (1ULL << 52) - 1, m26 = (1ULL << 26) - 1;
	for (int i = 0; i < lanes; i++) {
		u64 x = a[i] & m52, y = b[i] & m52;
		u64 p0 = (x & m26) * (y & m26);
		u64 p1 = (x & m26) * (y >> 26) + (x >> 26) * (y & m26);
		u64 p2 = (x >> 26) * (y >> 26);
		u64 lo = p0 + ((p1 & m26) << 26);
		d[i] = acc[i] + (high ? p2 + (p1 >> 26) + (lo >> 52) : (lo & m52));
	}
}
static void ref_b4(u32 *d, const u32 *acc, const u32 *a, const u32 *b, int lanes) { ref_m52(d, acc, a, b, lanes / 2, 0); }
static void ref_b5(u32 *d, const u32 *acc, const u32 *a, const u32 *b, int lanes) { ref_m52(d, acc, a, b, lanes / 2, 1); }

// GFNI references (GF(2^8), poly 0x11b). acc unused; lanes = dwords.
static unsigned gfmul8(unsigned a, unsigned b) {
	unsigned w = 0; int i;
	for (i = 0; i < 8; i++) if ((b >> i) & 1) w ^= a << i;
	for (i = 14; i >= 8; i--) if ((w >> i) & 1) w ^= 0x11b << (i - 8);
	return w & 255;
}
static unsigned gfinv8(unsigned x) { unsigned r = 1; int e; if (!x) return 0; for (e = 254; e; e--) r = gfmul8(r, x); return r; }
static int par8(unsigned x) { x ^= x >> 4; x ^= x >> 2; x ^= x >> 1; return x & 1; }
static void ref_gfaff(u32 *d, const u32 *acc, const u32 *a, const u32 *b, int lanes, int imm, int inv) {
	const unsigned char *A = (const unsigned char *)a, *B = (const unsigned char *)b;
	unsigned char *D = (unsigned char *)d; int nb = lanes * 4;
	for (int j = 0; j < nb / 8; j++)
		for (int k = 0; k < 8; k++) {
			unsigned char x = A[8 * j + k];
			unsigned char r = 0;
			if (inv) x = (unsigned char)gfinv8(x);
			for (int i = 0; i < 8; i++)
				r ^= (par8(B[8 * j + (7 - i)] & x) ^ ((imm >> i) & 1)) << i;
			D[8 * j + k] = r;
		}
}
static void ref_gb(u32 *d, const u32 *acc, const u32 *a, const u32 *b, int lanes) { ref_gfaff(d, acc, a, b, lanes, 0x63, 0); }
static void ref_ge(u32 *d, const u32 *acc, const u32 *a, const u32 *b, int lanes) { ref_gfaff(d, acc, a, b, lanes, 0xa4, 1); }
static void ref_gfmulb(u32 *d, const u32 *acc, const u32 *a, const u32 *b, int lanes) {
	const unsigned char *A = (const unsigned char *)a, *B = (const unsigned char *)b;
	unsigned char *D = (unsigned char *)d;
	for (int i = 0; i < lanes * 4; i++) D[i] = (unsigned char)gfmul8(A[i], B[i]);
}

// SHA-NI references (mirror churro_sha_exec): s1 = acc (DEST/SRC1), s2 = b, wk = a (xmm0)
static u32 ror32(u32 v, int n) { return (v >> n) | (v << (32 - n)); }
static u32 rol32(u32 v, int n) { return (v << n) | (v >> (32 - n)); }
static u32 ssig0(u32 x) { return ror32(x, 7) ^ ror32(x, 18) ^ (x >> 3); }
static u32 ssig1(u32 x) { return ror32(x, 17) ^ ror32(x, 19) ^ (x >> 10); }
static u32 sbig0(u32 x) { return ror32(x, 2) ^ ror32(x, 13) ^ ror32(x, 22); }
static u32 sbig1(u32 x) { return ror32(x, 6) ^ ror32(x, 11) ^ ror32(x, 25); }

static void ref_s256r2(u32 *d, const u32 *s1, const u32 *wk, const u32 *s2, int lanes) {
	u32 a = s2[3], b = s2[2], c = s1[3], dd = s1[2], e = s2[1], f = s2[0], g = s1[1], h = s1[0];
	for (int i = 0; i < 2; i++) {
		u32 t1 = h + sbig1(e) + ((e & f) ^ (~e & g)) + wk[i];
		u32 t2 = sbig0(a) + ((a & b) ^ (a & c) ^ (b & c));
		h = g; g = f; f = e; e = t1 + dd;
		dd = c; c = b; b = a; a = t1 + t2;
	}
	d[3] = a; d[2] = b; d[1] = e; d[0] = f;
}
static void ref_s256m1(u32 *d, const u32 *s1, const u32 *a, const u32 *s2, int lanes) {
	d[3] = s1[3] + ssig0(s2[0]);
	d[2] = s1[2] + ssig0(s1[3]);
	d[1] = s1[1] + ssig0(s1[2]);
	d[0] = s1[0] + ssig0(s1[1]);
}
static void ref_s256m2(u32 *d, const u32 *s1, const u32 *a, const u32 *s2, int lanes) {
	u32 w16 = s1[0] + ssig1(s2[2]), w17 = s1[1] + ssig1(s2[3]);
	u32 w18 = s1[2] + ssig1(w16), w19 = s1[3] + ssig1(w17);
	d[3] = w19; d[2] = w18; d[1] = w17; d[0] = w16;
}
static void ref_s1ne(u32 *d, const u32 *s1, const u32 *a, const u32 *s2, int lanes) {
	d[3] = s2[3] + rol32(s1[3], 30); d[2] = s2[2]; d[1] = s2[1]; d[0] = s2[0];
}
static void ref_s1m1(u32 *d, const u32 *s1, const u32 *a, const u32 *s2, int lanes) {
	d[3] = s1[1] ^ s1[3]; d[2] = s1[0] ^ s1[2]; d[1] = s2[3] ^ s1[1]; d[0] = s2[2] ^ s1[0];
}
static void ref_s1m2(u32 *d, const u32 *s1, const u32 *a, const u32 *s2, int lanes) {
	u32 w16 = rol32(s1[3] ^ s2[2], 1), w17 = rol32(s1[2] ^ s2[1], 1);
	u32 w18 = rol32(s1[1] ^ s2[0], 1), w19 = rol32(s1[0] ^ w16, 1);
	d[3] = w16; d[2] = w17; d[1] = w18; d[0] = w19;
}
static void ref_s1r4(u32 *d, const u32 *s1, const u32 *a, const u32 *s2, int lanes, int imm) {
	static const u32 K[4] = { 0x5a827999u, 0x6ed9eba1u, 0x8f1bbcdcu, 0xca62c1d6u };
	u32 aa = s1[3], b = s1[2], c = s1[1], dd = s1[0], e = 0;
	for (int i = 0; i < 4; i++) {
		u32 f;
		switch (imm & 3) {
		case 0: f = (b & c) ^ (~b & dd); break;
		case 1: f = b ^ c ^ dd; break;
		case 2: f = (b & c) ^ (b & dd) ^ (c & dd); break;
		default: f = b ^ c ^ dd; break;
		}
		f += rol32(aa, 5) + s2[3 - i] + K[imm & 3];
		if (i) f += e;
		e = dd; dd = c; c = rol32(b, 30); b = aa; aa = f;
	}
	d[3] = aa; d[2] = b; d[1] = c; d[0] = dd;
}
static void ref_s1r4_0(u32 *d, const u32 *s1, const u32 *a, const u32 *b, int lanes) { ref_s1r4(d, s1, a, b, lanes, 0); }
static void ref_s1r4_1(u32 *d, const u32 *s1, const u32 *a, const u32 *b, int lanes) { ref_s1r4(d, s1, a, b, lanes, 1); }
static void ref_s1r4_2(u32 *d, const u32 *s1, const u32 *a, const u32 *b, int lanes) { ref_s1r4(d, s1, a, b, lanes, 2); }
static void ref_s1r4_3(u32 *d, const u32 *s1, const u32 *a, const u32 *b, int lanes) { ref_s1r4(d, s1, a, b, lanes, 3); }

// vpclmulqdq reference: lanes = dwords; imm selects qwords per 128-bit lane
static void ref_pcm(u32 *d, const u32 *acc, const u32 *a, const u32 *b, int lanes, int imm) {
	u64 *D = (u64 *)d;
	const u64 *A = (const u64 *)a, *B = (const u64 *)b;
	for (int i = 0; i < lanes / 4; i++) {
		u64 x = A[2 * i + (imm & 1)], y = B[2 * i + ((imm >> 4) & 1)];
		u64 lo = 0, hi = 0;
		for (int j = 0; j < 64; j++)
			if ((y >> j) & 1) { lo ^= x << j; if (j) hi ^= x >> (64 - j); }
		D[2 * i] = lo; D[2 * i + 1] = hi;
	}
}
static void ref_pcm_i00(u32 *d, const u32 *acc, const u32 *a, const u32 *b, int lanes) { ref_pcm(d, acc, a, b, lanes, 0x00); }
static void ref_pcm_i11(u32 *d, const u32 *acc, const u32 *a, const u32 *b, int lanes) { ref_pcm(d, acc, a, b, lanes, 0x11); }
static void ref_pcm_i01(u32 *d, const u32 *acc, const u32 *a, const u32 *b, int lanes) { ref_pcm(d, acc, a, b, lanes, 0x01); }
static void ref_pcm_i10(u32 *d, const u32 *acc, const u32 *a, const u32 *b, int lanes) { ref_pcm(d, acc, a, b, lanes, 0x10); }

// VAES reference: one AES round per 128-bit lane, state = a (vvvv), key = b; byte r+4c = row r, col c
static unsigned aes_sub(unsigned x, int inv) {
	if (inv) {	// invert the forward S-box by search: slow but obviously right
		for (unsigned y = 0; y < 256; y++) if (aes_sub(y, 0) == x) return y;
	}
	unsigned b = gfinv8(x), s = b ^ 0x63;
	for (int i = 1; i < 5; i++) s ^= ((b << i) | (b >> (8 - i))) & 255;
	return s;
}
static void ref_aes(u32 *d, const u32 *acc, const u32 *a, const u32 *b, int lanes, int dec, int last) {
	static const unsigned m[2][4] = { { 2, 3, 1, 1 }, { 14, 11, 13, 9 } };
	const unsigned char *S = (const unsigned char *)a, *K = (const unsigned char *)b;
	unsigned char *D = (unsigned char *)d;
	for (int l = 0; l < lanes / 4; l++, S += 16, K += 16, D += 16) {
		unsigned char t[16];
		for (int c = 0; c < 4; c++)
			for (int r = 0; r < 4; r++)
				t[r + 4 * c] = (unsigned char)aes_sub(S[r + 4 * ((dec ? c - r + 4 : c + r) % 4)], dec);
		for (int c = 0; c < 4; c++)
			for (int r = 0; r < 4; r++) {
				unsigned v = t[r + 4 * c];
				if (!last) {
					v = 0;
					for (int k = 0; k < 4; k++) v ^= gfmul8(m[dec][(k - r) & 3], t[k + 4 * c]);
				}
				D[r + 4 * c] = (unsigned char)(v ^ K[r + 4 * c]);
			}
	}
}
static void ref_aesenc(u32 *d, const u32 *acc, const u32 *a, const u32 *b, int lanes) { ref_aes(d, acc, a, b, lanes, 0, 0); }
static void ref_aesenclast(u32 *d, const u32 *acc, const u32 *a, const u32 *b, int lanes) { ref_aes(d, acc, a, b, lanes, 0, 1); }
static void ref_aesdec(u32 *d, const u32 *acc, const u32 *a, const u32 *b, int lanes) { ref_aes(d, acc, a, b, lanes, 1, 0); }
static void ref_aesdeclast(u32 *d, const u32 *acc, const u32 *a, const u32 *b, int lanes) { ref_aes(d, acc, a, b, lanes, 1, 1); }

// ra_chain's straight-line code (vexops.S), op by op: x = 16 xmm (u32 lanes), m = data buffer.
// On a gap CPU only the first sha256rnds2 traps; the kernel's run-ahead interprets the rest.
static void cp4(u32 *d, const u32 *s) { for (int i = 0; i < 4; i++) d[i] = s[i]; }
static void ra_model(u32 x[16][4], const u32 *m) {
	u32 t[4], s[4];
	unsigned char b[32], *db; const unsigned char *sb;
	int i;
	ref_s256r2(t, x[2], x[0], x[1], 4); cp4(x[2], t);		// sha256rnds2 %xmm0,%xmm1,%xmm2
	cp4(s, x[0]); for (i = 0; i < 4; i++) x[0][i] = s[(0x0e >> (2 * i)) & 3];	// pshufd $0xe
	cp4(x[9], x[1]);						// movdqa %xmm1,%xmm9
	ref_s256m1(t, x[3], x[0], x[4], 4); cp4(x[3], t);		// sha256msg1 %xmm4,%xmm3
	for (i = 0; i < 4; i++) x[0][i] += m[4 + i];			// paddd 0x10(%rsi),%xmm0
	sb = (const unsigned char *)x[5]; db = (unsigned char *)x[7];	// palignr $4,%xmm5,%xmm7
	for (i = 0; i < 16; i++) { b[i] = sb[i]; b[16 + i] = db[i]; }
	for (i = 0; i < 16; i++) db[i] = b[i + 4];
	sb = (const unsigned char *)x[8]; db = (unsigned char *)x[6];	// pshufb %xmm8,%xmm6
	for (i = 0; i < 16; i++) b[i] = db[i];
	for (i = 0; i < 16; i++) db[i] = sb[i] & 0x80 ? 0 : b[sb[i] & 15];
	ref_s256m2(t, x[3], x[0], x[6], 4); cp4(x[3], t);		// sha256msg2 %xmm6,%xmm3
	x[10][2] = x[0][0]; x[10][3] = x[0][1];				// punpcklqdq %xmm0,%xmm10
	x[12][0] = x[12][2]; x[12][1] = x[12][3]; x[12][2] = x[11][2]; x[12][3] = x[11][3];	// punpckhqdq
	m += 8;								// lea 0x20(%rsi),%rsi
	cp4(x[13], m);							// movdqa (%rsi),%xmm13
	cp4(x[14], m + 9);						// movdqu 0x24(%rsi),%xmm14
	ref_s256r2(t, x[11], x[0], x[9], 4); cp4(x[11], t);		// sha256rnds2 %xmm0,%xmm9,%xmm11
	ref_s1r4(t, x[14], x[0], x[15], 4, 1); cp4(x[14], t);		// sha1rnds4 $1,%xmm15,%xmm14
}
static int ra_chain_test(void) {
	static u32 got[16][4], want[16][4], m[24] __attribute__((aligned(64)));
	u32 seed = 0x5eed1234;
	for (int i = 0; i < 16; i++)
		for (int j = 0; j < 4; j++) { seed = seed * 1103515245 + 12345; got[i][j] = want[i][j] = seed; }
	for (int i = 0; i < 24; i++) { seed = seed * 1103515245 + 12345; m[i] = seed; }
	ra_chain(&got[0][0], m);
	ra_model(want, m);
	int bad = 0;
	for (int i = 0; i < 16; i++)
		for (int j = 0; j < 4; j++)
			if (got[i][j] != want[i][j]) {
				if (!bad++) { lpos = 0; lbs("VEXTEST runahead/sha-chain FAIL xmm"); lbd(i); lbs(" got="); lbx(got[i][j]); lbs(" want="); lbx(want[i][j]); lbs("\n"); lb_flush(); }
			}
	return bad;
}

// rav_chain's straight-line code (vexops.S), op by op: x = 16 ymm (u32[8] lanes), m = data.
// On a gap CPU the first vpdpwssd and the one after the `add` trap; the kernel's VEX
// run-ahead interprets everything between them, the lea included (so rax = m + 0x20 when
// the run stops, and the CPU's addl makes the load read from m + 0x21).
static void cp8(u32 *d, const u32 *s) { for (int i = 0; i < 8; i++) d[i] = s[i]; }
static void ref_sad(u32 *d, const u32 *a, const u32 *b) {
	const u8 *pa = (const u8 *)a, *pb = (const u8 *)b;	// symmetric in a/b
	for (int g = 0; g < 4; g++) {
		u32 s = 0;
		for (int i = 0; i < 8; i++) {
			int v = (int)pa[g * 8 + i] - (int)pb[g * 8 + i];
			s += (u32)(v < 0 ? -v : v);
		}
		d[2 * g] = s;
		d[2 * g + 1] = 0;
	}
}
static void ref_mubsw(u32 *d, const u32 *u_, const u32 *s_) {	// unsigned u_ * signed s_
	const u8 *pu = (const u8 *)u_;
	const signed char *ps = (const signed char *)s_;
	signed short *pd = (signed short *)d;
	for (int i = 0; i < 16; i++) {
		int v = (int)pu[2 * i] * (int)ps[2 * i] + (int)pu[2 * i + 1] * (int)ps[2 * i + 1];
		pd[i] = v > 32767 ? 32767 : v < -32768 ? -32768 : (short)v;
	}
}
static void ref_mwd(u32 *d, const u32 *a_, const u32 *b_) {	// pmaddwd: wrapping s16 dot products
	const signed short *pa = (const signed short *)a_, *pb = (const signed short *)b_;
	for (int i = 0; i < 8; i++) {
		int v = (int)pa[2 * i] * pb[2 * i] + (int)pa[2 * i + 1] * pb[2 * i + 1];
		d[i] = (u32)v;
	}
}
static void rav_model(u32 x[16][8], const u32 *m) {
	u32 t[8];
	const u8 *mb = (const u8 *)m;
	int i;
	ref_52(t, x[1], x[2], x[3], 8); cp8(x[1], t);		// vpdpwssd %ymm3,%ymm2,%ymm1
	cp8(x[4], m);						// vmovdqu 0x00(%rsi),%ymm4
	cp8(x[5], m + 7);					// vmovdqu 0x1c(%rsi),%ymm5
	cp8(x[6], m + 16);					// vmovdqa 0x40(%rsi),%ymm6
	ref_sad(x[7], x[5], x[4]);				// vpsadbw %ymm4,%ymm5,%ymm7
	ref_mubsw(x[8], x[5], x[4]);				// vpmaddubsw %ymm4,%ymm5,%ymm8
	for (i = 0; i < 8; i++) x[9][i] = x[8][i] + x[7][i];	// vpaddd %ymm7,%ymm8,%ymm9
	ref_mwd(x[9], x[9], x[4]);				// vpmaddwd %ymm4,%ymm9,%ymm9
	for (i = 0; i < 8; i++) x[10][i] ^= x[9][i];		// vpxor %ymm9,%ymm10,%ymm10
	ref_52(t, x[11], x[4], x[8], 8); cp8(x[11], t);		// vpdpwssd %ymm8,%ymm4,%ymm11
	ref_52(t, x[12], x[6], m + 24, 8); cp8(x[12], t);	// vpdpwssd 0x60(%rsi),%ymm6,%ymm12
	ref_50(t, x[13], x[6], x[7], 8); cp8(x[13], t);		// vpdpbusd %ymm7,%ymm6,%ymm13
	// lea 0x20(%rsi),%rax (interpreted) then addl $1,%eax (native): rax = m + 0x21
	ref_52(t, x[14], x[13], x[12], 8); cp8(x[14], t);	// vpdpwssd %ymm12,%ymm13,%ymm14
	ref_52(t, x[15], x[11], x[10], 8); cp8(x[15], t);	// vpdpwssd %ymm10,%ymm11,%ymm15
	for (i = 0; i < 16; i++) ((u8 *)x[0])[i] = mb[0x21 + i];	// vmovdqu (%rax),%xmm0
	for (i = 4; i < 8; i++) x[0][i] = 0;			// VEX.128 zeroes the upper half
	ref_52(t, x[2], x[1], x[0], 4);				// vpdpwssd %xmm0,%xmm1,%xmm2
	for (i = 0; i < 4; i++) x[2][i] = t[i];
	for (i = 4; i < 8; i++) x[2][i] = 0;			// VEX.128 zeroes the upper half
}
static int rav_chain_test(void) {
	static u32 got[16][8], want[16][8], m[32] __attribute__((aligned(64)));
	u32 seed = 0xcafe1234;
	for (int i = 0; i < 16; i++)
		for (int j = 0; j < 8; j++) { seed = seed * 1103515245 + 12345; got[i][j] = want[i][j] = seed; }
	for (int i = 0; i < 32; i++) { seed = seed * 1103515245 + 12345; m[i] = seed; }
	rav_chain(&got[0][0], m);
	rav_model(want, m);
	int bad = 0;
	for (int i = 0; i < 16; i++)
		for (int j = 0; j < 8; j++)
			if (got[i][j] != want[i][j]) {
				if (!bad++) { lpos = 0; lbs("VEXTEST runahead/vex-chain FAIL ymm"); lbd(i); lbs(" lane"); lbd(j);
					lbs(" got="); lbx(got[i][j]); lbs(" want="); lbx(want[i][j]); lbs("\n"); lb_flush(); }
			}
	return bad;
}

// ADX reference: dest += src + carry-in; carry via CF (adcx) or OF (adox) only, nothing else changes
static void ref_adx(u64 *s, int adox, int w) {
	u64 flag = adox ? 0x800 : 0x1, cin = (s[2] & flag) ? 1 : 0, c;
	if (w) {
		u64 r = s[0] + s[1], r2 = r + cin;
		c = (r < s[0]) | (r2 < r);
		s[0] = r2;
	} else {
		u64 t = (u64)(u32)s[0] + (u32)s[1] + cin;
		s[0] = (u32)t;
		c = t >> 32;
	}
	s[2] = (s[2] & ~flag) | (c ? flag : 0);
}
static int adx_tests(int *total) {
	static const struct { const char *name; void (*fn)(u64 *); int adox, w; } t[] = {
		{ "adcx/r64-rex", adcx_r64_rex, 0, 1 }, { "adox/r64", adox_r64, 1, 1 },
		{ "adcx/r32", adcx_r32, 0, 0 }, { "adox/m64-rex", adox_m64_rex, 1, 1 },
		{ "adcx/m32", adcx_m32, 0, 0 },
	};
	// carry chains and edges: ~0 + 0 + 1, ~0 + 1, 32-bit wrap with a high half, plain sums
	static const u64 in[][3] = {
		{ ~0ull, 0, 0xad7 }, { ~0ull, 1, 0x202 }, { 0x12345678ffffffffull, 1, 0xa03 },
		{ 0x8000000000000000ull, 0x8000000000000000ull, 0x2c2 }, { 5, 7, 0x203 }, { 0xfffffffe, 1, 0x803 },
	};
	int bad = 0;
	for (unsigned i = 0; i < sizeof t / sizeof t[0]; i++) {
		int ok = 1;
		for (unsigned j = 0; j < sizeof in / sizeof in[0]; j++) {
			u64 got[3] = { in[j][0], in[j][1], in[j][2] }, want[3] = { in[j][0], in[j][1], in[j][2] };
			t[i].fn(got);
			ref_adx(want, t[i].adox, t[i].w);
			if (got[0] != want[0] || ((got[2] ^ want[2]) & 0x8d5)) {	/* CF PF AF ZF SF OF */
				if (ok) { lpos = 0; lbs("VEXTEST "); lbs(t[i].name); lbs(" FAIL in"); lbd(j);
					lbs(" got="); lbx(got[0]); lbs("/"); lbx(got[2]); lbs(" want="); lbx(want[0]);
					lbs("/"); lbx(want[2]); lbs("\n"); lb_flush(); }
				ok = 0;
			}
		}
		(*total)++;
		bad += !ok;
		if (ok) { lpos = 0; lbs("VEXTEST "); lbs(t[i].name); lbs(" ok\n"); lb_flush(); }
	}
	return bad;
}

// ------- drivers -------
typedef void (*stub_t)(u32 *, const u32 *, const u32 *, const u32 *);
typedef void (*ref_t)(u32 *, const u32 *, const u32 *, const u32 *, int);

// REX SHA stubs return the full ymm DEST: low lane = SHA result, upper lane kept from acc (legacy SSE)
static void keephi(ref_t f, u32 *d, const u32 *acc, const u32 *a, const u32 *b) {
	f(d, acc, a, b, 4);
	for (int i = 4; i < 8; i++) d[i] = acc[i];
}
static void ref_s256m1_hi(u32 *d, const u32 *acc, const u32 *a, const u32 *b, int l) { keephi(ref_s256m1, d, acc, a, b); }
static void ref_s256m2_hi(u32 *d, const u32 *acc, const u32 *a, const u32 *b, int l) { keephi(ref_s256m2, d, acc, a, b); }
static void ref_s1ne_hi(u32 *d, const u32 *acc, const u32 *a, const u32 *b, int l) { keephi(ref_s1ne, d, acc, a, b); }
static void ref_s256r2_hi(u32 *d, const u32 *acc, const u32 *a, const u32 *b, int l) { keephi(ref_s256r2, d, acc, a, b); }

struct tc {
	const char *name; // "vpdpwssd/256/reg"
	stub_t stub;
	ref_t ref;
	char native_flag;   // 'v' = AVX-VNNI, 'i' = AVX-IFMA, 'g' = GFNI, 's' = SHA, 'p' = VPCLMULQDQ, 'a' = VAES
};

static const struct tc tests[] = {
	{ "vpdpbusd/128/reg", op50_128_reg, ref_50, 'v' },
	{ "vpdpbusd/256/reg", op50_256_reg, ref_50, 'v' },
	{ "vpdpbusds/128/reg", op51_128_reg, ref_51, 'v' },
	{ "vpdpbusds/256/reg", op51_256_reg, ref_51, 'v' },
	{ "vpdpwssd/128/reg", op52_128_reg, ref_52, 'v' },
	{ "vpdpwssd/256/reg", op52_256_reg, ref_52, 'v' },
	{ "vpdpwssds/128/reg", op53_128_reg, ref_53, 'v' },
	{ "vpdpwssds/256/reg", op53_256_reg, ref_53, 'v' },
	{ "vpmadd52luq/128/reg", opb4_128_reg, ref_b4, 'i' },
	{ "vpmadd52luq/256/reg", opb4_256_reg, ref_b4, 'i' },
	{ "vpmadd52huq/128/reg", opb5_128_reg, ref_b5, 'i' },
	{ "vpmadd52huq/256/reg", opb5_256_reg, ref_b5, 'i' },
	{ "vpdpwssd/256/mem", op52_256_mem_ind, ref_52, 'v' },
	{ "vpdpwssd/256/sib", op52_256_mem_sib, ref_52, 'v' },
	{ "vpdpwssd/256/rip", op52_256_mem_rip, ref_52, 'v' },
	{ "vpdpwssd/256/hireg", op52_256_reghi, ref_52, 'v' },
	{ "vpmadd52luq/256/sib", opb4_256_mem_sib, ref_b4, 'i' },
	// GFNI: matrix from b (SRC2), bytes from a (SRC1); imms baked into stubs
	{ "vgf2p8affineqb/128/reg", opgb_128_reg, ref_gb, 'g' },
	{ "vgf2p8affineqb/256/reg", opgb_256_reg, ref_gb, 'g' },
	{ "vgf2p8affineinvqb/128/reg", opge_128_reg, ref_ge, 'g' },
	{ "vgf2p8affineinvqb/256/reg", opge_256_reg, ref_ge, 'g' },
	{ "vgf2p8mulb/128/reg", opgf_128_reg, ref_gfmulb, 'g' },
	{ "vgf2p8mulb/256/reg", opgf_256_reg, ref_gfmulb, 'g' },
	{ "vgf2p8affineqb/256/sib", opgb_256_mem_sib, ref_gb, 'g' },
	// SHA-NI (legacy NP): dst/SRC1 = acc, SRC2 = b, xmm0/WK = a
	{ "sha256rnds2/reg", sha256rnds2_reg, ref_s256r2, 's' },
	{ "sha256msg1/reg", sha256msg1_reg, ref_s256m1, 's' },
	{ "sha256msg2/reg", sha256msg2_reg, ref_s256m2, 's' },
	{ "sha256msg2/sib", sha256msg2_mem_sib, ref_s256m2, 's' },
	{ "sha1nexte/reg", sha1nexte_reg, ref_s1ne, 's' },
	{ "sha1msg1/reg", sha1msg1_reg, ref_s1m1, 's' },
	{ "sha1msg2/reg", sha1msg2_reg, ref_s1m2, 's' },
	{ "sha1rnds4/reg@i0", sha1rnds4_i0, ref_s1r4_0, 's' },
	{ "sha1rnds4/reg@i1", sha1rnds4_i1, ref_s1r4_1, 's' },
	{ "sha1rnds4/reg@i2", sha1rnds4_i2, ref_s1r4_2, 's' },
	{ "sha1rnds4/reg@i3", sha1rnds4_i3, ref_s1r4_3, 's' },
	// REX (xmm8-15) forms; "/256" = compare all 8 lanes (upper half must survive)
	{ "sha256msg1/256/rex45-keephi", sha256msg1_rex45, ref_s256m1_hi, 's' },
	{ "sha256msg2/256/rex44-keephi", sha256msg2_rex44, ref_s256m2_hi, 's' },
	{ "sha1nexte/256/rex41-keephi", sha1nexte_rex41, ref_s1ne_hi, 's' },
	{ "sha256rnds2/256/rex45-keephi", sha256rnds2_rex45, ref_s256r2_hi, 's' },
	// vpclmulqdq: imms vary qword select per lane
	{ "vpclmulqdq/128/i00", pc_128_i00, ref_pcm_i00, 'p' },
	{ "vpclmulqdq/256/i00", pc_256_i00, ref_pcm_i00, 'p' },
	{ "vpclmulqdq/256/i11", pc_256_i11, ref_pcm_i11, 'p' },
	{ "vpclmulqdq/256/i01", pc_256_i01, ref_pcm_i01, 'p' },
	{ "vpclmulqdq/256/i10", pc_256_i10, ref_pcm_i10, 'p' },
	// VAES 256: state = a (vvvv), round key = b
	{ "vaesenc/256/reg", vaesenc_256_reg, ref_aesenc, 'a' },
	{ "vaesenclast/256/reg", vaesenclast_256_reg, ref_aesenclast, 'a' },
	{ "vaesdec/256/reg", vaesdec_256_reg, ref_aesdec, 'a' },
	{ "vaesdeclast/256/reg", vaesdeclast_256_reg, ref_aesdeclast, 'a' },
};

// vector presets: cover sign edges, saturation, u8*s8 extremes, >52-bit masks
static u32 vec_acc[8], vec_a[8], vec_b[8], out[8], want[8];
static void fill(int preset) {
	static const u32 pa[8] = { 0x01020304u, 0x80018002u, 0x7fff8000u, 0xffffffffu,
				   0x00010001u, 0xdeadbeefu, 0x12345678u, 0xff00ff00u };
	static const u32 pb[8] = { 0x0a0b0c0du, 0xff7f0080u, 0x7fffffffu, 0x80008000u,
				   0xffffffffu, 0xcafebabeu, 0x00008000u, 0x00ff00ffu };
	static const u32 pc[8] = { 0u, 1u, 0xffffffffu, 0x80000000u, 0x7fffffffu, 5u, 0xffff0000u, 42u };
	static const u32 pa2[8] = { 0u, 0u, 0xff3838ffu, 0u, 0u, 0u, 0xffffffffu, 0u }; // a52>x, b52 huge for ifma
	static const u32 pb2[8] = { 0u, 0u, 0u, 0u, 0xffffffffu, 0xffffffffu, 0xffffffffu, 0u };
	// preset 3: saturation triggers. l0: acc=INT32_MAX + 2; l1: acc=INT32_MIN - 65280;
	// l2: acc=5 + 2^31 (word-pair sum exactly 0x80000000)
	static const u32 pa3[8] = { 0x00010001u, 0xffffffffu, 0x80008000u, 0u, 0u, 0u, 0u, 0u };
	static const u32 pb3[8] = { 0x00010001u, 0x80008000u, 0x80008000u, 0u, 0u, 0u, 0u, 0u };
	static const u32 pc3[8] = { 0x7fffffffu, 0x80000000u, 5u, 0u, 0u, 0u, 0u, 0u };
	const u32 *sa = pa, *sb = pb, *sc = pc;
	if (preset == 2) { sa = pa2; sb = pb2; }
	if (preset == 3) { sa = pa3; sb = pb3; sc = pc3; }
	for (int i = 0; i < 8; i++) { vec_a[i] = sa[i]; vec_b[i] = sb[i]; vec_acc[i] = sc[i]; }
}

__asm__(".globl _start\n_start:\nmovq %rsp, %rdi\njmp cstart\n");

// ------- oracle: textbook SHA-256 compress vs chained sha256rnds2 -------
// rnds2(dst=SRC1, s2=SRC2, wk=xmm0);  X=(F,E,B,A) for SRC2-position, (H,G,D,C) for SRC1-
static inline void x_rnds2(u32 *dst, const u32 *s2, const u32 *wk) {
	__asm__ volatile(
		"vmovdqu %1,%%xmm1\n"
		"vmovdqu %2,%%xmm2\n"
		"vmovdqu %3,%%xmm0\n"
		".byte 0x0f,0x38,0xcb,0xd1\n"
		"vmovdqu %%xmm2,%0\n"
		: "=m"(*(u32(*)[4])dst)
		: "m"(*(const u32(*)[4])s2), "m"(*(const u32(*)[4])dst), "m"(*(const u32(*)[2])wk)
		: "xmm0", "xmm1", "xmm2", "memory");
}
static const u32 K256[64] = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};
// textbook compress one block: s = 8 dwords (A..H), w16 = message words
static void sha_compress(u32 *s, const u32 *w16) {
	u32 W[64];
	for (int i = 0; i < 16; i++) W[i] = w16[i];
	for (int i = 16; i < 64; i++)
		W[i] = ssig1(W[i-2]) + W[i-7] + ssig0(W[i-16]) + W[i-15];
	u32 a=s[0],b=s[1],c=s[2],d=s[3],e=s[4],f=s[5],g=s[6],h=s[7];
	for (int i = 0; i < 64; i++) {
		u32 t1 = h + sbig1(e) + ((e&f)^(~e&g)) + K256[i] + W[i];
		u32 t2 = sbig0(a) + ((a&b)^(a&c)^(b&c));
		h=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
	}
	s[0]+=a; s[1]+=b; s[2]+=c; s[3]+=d; s[4]+=e; s[5]+=f; s[6]+=g; s[7]+=h;
}
// same via 32 chained sha256rnds2 (NI state machine)
static void sha_compress_ni(u32 *s, const u32 *w16) {
	u32 W[64];
	for (int i = 0; i < 16; i++) W[i] = w16[i];
	for (int i = 16; i < 64; i++)
		W[i] = ssig1(W[i-2]) + W[i-7] + ssig0(W[i-16]) + W[i-15];
	u32 X0[4] = { s[5], s[4], s[1], s[0] };	// SRC2 position: [F,E,B,A]
	u32 X1[4] = { s[7], s[6], s[3], s[2] };	// SRC1/DEST position: [H,G,D,C]
	for (int t = 0; t < 64; t += 2) {
		u32 wk[2] = { W[t] + K256[t], W[t+1] + K256[t+1] };
		if ((t / 2) & 1)
			x_rnds2(X0, X1, wk);
		else
			x_rnds2(X1, X0, wk);
	}
	// after 32 calls: ABEF in X0, CDGH in X1
	s[0]+=X0[3]; s[1]+=X0[2]; s[2]+=X1[3]; s[3]+=X1[2];
	s[4]+=X0[1]; s[5]+=X0[0]; s[6]+=X1[1]; s[7]+=X1[0];
}
// deterministic stream: 512 compress blocks, block[i+1] derived from the digest.
// Returns NI-path final digest in out[8]; returns 1 if NI != textbook at any point, else 0.
static int sha_stream(u32 out[8]) {
	static const u32 iv[8] = { 0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19 };
	u32 a[8], b[8], blk[16];
	for (int i = 0; i < 8; i++) a[i] = b[i] = iv[i];
	for (int i = 0; i < 16; i++) blk[i] = 0x900dc0deu ^ (u32)(0x9e3779b9u * (i + 1));
	for (int it = 0; it < 512; it++) {
		sha_compress(a, blk);
		sha_compress_ni(b, blk);
		for (int i = 0; i < 8; i++)
			if (a[i] != b[i]) return 1;
		for (int i = 0; i < 8; i++)
			blk[i] = a[i] ^ (u32)(it * 2654435761u + i);
		for (int i = 8; i < 16; i++)
			blk[i] = ~a[i & 7] + (u32)it;
	}
	for (int i = 0; i < 8; i++) out[i] = b[i];
	return 0;
}
static int sha_oracle(void) { u32 tmp[8]; return sha_stream(tmp); }

// chained accumulate stress: zlib-like acc-dependent vpdpwssd streams
static u32 ch_a[64][8], ch_b[64][8], ch_acc[8];
static void wssd_ref_chain(u32 *acc, unsigned long rounds) {
	for (unsigned long i = 0; i < rounds; i++) {
		const u32 *A = ch_a[i & 63], *B = ch_b[i & 63];
		for (int j = 0; j < 8; j++) {
			const short aw[2] = { (short)(A[j] & 0xffff), (short)(A[j] >> 16) };
			const short bw[2] = { (short)(B[j] & 0xffff), (short)(B[j] >> 16) };
			// vpdpwssd (non-satinating) = wraparound dword accumulate
			u32 t = (u32)((unsigned)(aw[0] * bw[0]) + (unsigned)(aw[1] * bw[1]));
			acc[j] = t + acc[j];
		}
	}
}
static int chain_stress(void) {
	u32 seed = 0x1234abcd;
	for (int i = 0; i < 64; i++)
		for (int j = 0; j < 8; j++) {
			seed = seed * 0x41c64e6d + 12345; ch_a[i][j] = seed;
			seed = seed * 0x41c64e6d + 12345; ch_b[i][j] = seed;
		}
	for (int j = 0; j < 8; j++) ch_acc[j] = 0x100 * j;
	u32 sim[8];
	for (int j = 0; j < 8; j++) sim[j] = ch_acc[j];
	int fails = 0;
	for (int call = 0; call < 4; call++) {
		wssd_chain_256(out, &ch_a[0][0], &ch_b[0][0], ch_acc, 2048);
		wssd_ref_chain(sim, 2048);
		for (int j = 0; j < 8; j++)
			ch_acc[j] = sim[j];	// continue chained state through next call
		for (int j = 0; j < 8; j++) {
			if (out[j] != sim[j]) {
				fails++;
				lpos = 0;
				lbs("VEXTEST wssd-chain FAIL lane"); lbd(j);
				lbs(" call"); lbd(call); lbs(" got="); lbx(out[j]); lbs(" want="); lbx(sim[j]); lbs("\n"); lb_flush();
				break;
			}
		}
	}
	return fails;
}

// === multiprocess variant: fork N children, each running an INDEPENDENT chained stream
// against the same global mul-operand tables with its own acc + scalar mirror.
// Exits nonzero per child on divergence => catches cross-task FPU state corruption
// during #UD emulation (the i7 device's failing domain).
#define MT_N 4
#define MT_ROUNDS 512
static u32 mt_acc[8], mt_sim[8];

static long sys6(long n, long a, long b, long c, long d, long e, long f) {
	long r;
	register long r10 __asm__("r10") = d, r8_ __asm__("r8") = e, r9_ __asm__("r9") = f;
	__asm__ volatile("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c), "r"(r10), "r"(r8_), "r"(r9_) : "rcx", "r11", "memory");
	return r;
}

static u32 *mt_page;	// MAP_SHARED page for child failure reports

static void m52_ref_chain(u32 *acc, unsigned long rounds) {
	const u64 m52 = (1ULL << 52) - 1;
	for (unsigned long i = 0; i < rounds; i++) {
		const u32 *A = ch_a[i & 63], *B = ch_b[i & 63];
		for (int j = 0; j < 4; j++) {
			const u64 *qa = (const u64 *)A, *qb = (const u64 *)B;
			u64 m52a = qa[j] & m52, m52b = qb[j] & m52;
			u64 *qacc = (u64 *)acc;
			// vpmadd52luq: dst += product low 52 bits
			u64 lo52 = (m52a * m52b) & m52;
			qacc[j] += lo52;
		}
	}
}

static int chain_mt_ifma(void) {
	int fails = 0, reaped = 0;
	for (int t = 0; t < MT_N; t++) {
		long pid = sys1(57, 0);
		if (pid != 0)
			continue;
		for (int j = 0; j < 8; j++) {
			mt_acc[j] = 0x1000 * (t + 1) + j;
			mt_sim[j] = mt_acc[j];
		}
		int bad = 0;
		for (int call = 0; call < 4 && !bad; call++) {
			m52_chain_256(out, &ch_a[0][0], &ch_b[0][0], mt_acc, MT_ROUNDS);
			m52_ref_chain(mt_sim, MT_ROUNDS);
			for (int j = 0; j < 8; j++)
				mt_acc[j] = mt_sim[j];
			for (int j = 0; j < 8 && !bad; j++)
				if (out[j] != mt_sim[j])
					bad = 2 + j;
		}
		sys6(60, bad, 0, 0, 0, 0, 0);
	}
	while (reaped < MT_N) {
		long st = 0;
		long r = sys6(61, -1, (long)&st, 0, 0, 0, 0);
		if (r < 0)
			break;
		reaped++;
		long code = (st >> 8) & 0xff, sig = st & 0x7f;
		if (code) fails++;
		if (sig) fails++;
	}
	return fails;
}

static int chain_stress_mt(void); /* fwd decl used below */

// single-process IFMA chain (same machinery, no forks): separates TCG mistranslation
// from context-switch corruption on gap CPU models.
static int chain_single_ifma(void) {
	u32 seed = 0x9e3779b9;
	for (int i = 0; i < 64; i++)
		for (int j = 0; j < 8; j++) {
			seed = seed * 22695477 + 1; ch_a[i][j] = seed;
			seed = seed * 22695477 + 1; ch_b[i][j] = seed;
		}
	for (int j = 0; j < 8; j++) mt_acc[j] = 0x1000 + j;
	for (int j = 0; j < 8; j++) mt_sim[j] = mt_acc[j];
	int bad = 0;
	for (int call = 0; call < 4 && !bad; call++) {
		m52_chain_256(out, &ch_a[0][0], &ch_b[0][0], mt_acc, MT_ROUNDS);
		m52_ref_chain(mt_sim, MT_ROUNDS);
		for (int j = 0; j < 8; j++)
			mt_acc[j] = mt_sim[j];
		for (int j = 0; j < 8 && !bad; j++)
			if (out[j] != mt_sim[j]) {
				bad = 2 + j;
				lpos = 0;
				lbs("VEXTEST ifma-single FAIL lane"); lbd(j);
				lbs(" got="); lbx(out[j]); lbs(" want="); lbx(mt_sim[j]);
				lbs("\n"); lb_flush();
			}
	}
	return bad;
}

static int chain_stress_mt(void) {
	u32 seed = 0x9e3779b9;
	mt_page = (u32 *)sys6(9, 0, 4096, 3, 0x22, -1, 0);	// mmap(NULL,4096,RW,SH|ANON,-1,0)
	for (int i = 0; i < 64; i++)
		for (int j = 0; j < 8; j++) {
			seed = seed * 22695477 + 1; ch_a[i][j] = seed;
			seed = seed * 22695477 + 1; ch_b[i][j] = seed;
		}
	u32 noreport = 0;
	if ((long)mt_page < 0)
		noreport = (u32)-(long)mt_page;	// errno
	for (int t = 0; t < MT_N; t++) {
		long pid = sys1(57, 0);	// fork()
		if (pid != 0)
			continue;
		for (int j = 0; j < 8; j++) {
			mt_acc[j] = 0x1000 * (t + 1) + j;
			mt_sim[j] = mt_acc[j];
		}
		int bad = 0;
		for (int call = 0; call < 4 && !bad; call++) {
			wssd_chain_256r1(out, &ch_a[0][0], &ch_b[0][0], mt_acc, MT_ROUNDS);
			wssd_ref_chain(mt_sim, MT_ROUNDS);
			for (int j = 0; j < 8; j++)
				mt_acc[j] = mt_sim[j];
			for (int j = 0; j < 8 && !bad; j++)
				if (out[j] != mt_sim[j]) {
					bad = 2 + j;
				}
		}
		sys6(60, bad, 0, 0, 0, 0, 0);	// exit child
	}
	int fails = 0, reaped = 0;
	while (reaped < MT_N) {
		long st = 0;
		long r = sys6(61, -1, (long)&st, 0, 0, 0, 0);	// wait4
		if (r < 0)
			break;
		reaped++;
		long code = (st >> 8) & 0xff, sig = st & 0x7f;
		if (code >= 2) {
			fails++;
			lpos = 0;
			lbs("VEXTEST mtFAIL lane"); lbd(code - 2); lbs("\n"); lb_flush();
		} else if (code)
			fails++;
		if (sig) {	// signalled (e.g. SIGILL/SIGSEGV) => bad
			fails++;
			lpos = 0;
			lbs("VEXTEST mt-chain child signalled sig="); lbd(sig); lbs("\n"); lb_flush();
		}
	}
	if (noreport) {
		lpos = 0;
		lbs("VEXTEST mtFAIL page-mmap-failed errno="); lbd(noreport); lbs("\n"); lb_flush();
	}
	if (fails && (long)mt_page > 0)
		for (int s = 0; s < 16; s++) {
			volatile u32 *p = mt_page;
			if ((p[s * 8] & 0xFFFF0000) == 0xDEAD0000) {
				lpos = 0;
				lbs("VEXTEST mtFAIL t"); lbd(p[s * 8] & 0xffff);
				lbs(" call"); lbd(p[s * 8 + 1]); lbs(" lane"); lbd(p[s * 8 + 2]);
				lbs(" got="); lbx(p[s * 8 + 3]); lbs(" want="); lbx(p[s * 8 + 4]);
				lbs("\n"); lb_flush();
			}
		}
	return fails;
}

// TCG-native equivalent probe: same shape (fork+chains), but the accumulate ops are
// vpaddd/vpsubd ymm0,ymm0,ymm3/4 — natively supported on every target AND by TCG
// (no #UD anywhere, zero emulation involvement). If THIS ever fails in the guest,
// QEMU's FPU state/context switching is broken, not our #UD handler.
static int chain_mt_native(void) {
	int fails = 0, reaped = 0;
	for (int t = 0; t < MT_N; t++) {
		long pid = sys1(57, 0);
		if (pid != 0)
			continue;
		for (int j = 0; j < 8; j++) {
			mt_acc[j] = 0x1000 * (t + 1) + j;
			mt_sim[j] = mt_acc[j];
		}
		int bad = 0;
		for (int call = 0; call < 4 && !bad; call++) {
			xpadd_chain_256(out, &ch_a[0][0], &ch_b[0][0], mt_acc, MT_ROUNDS);
			for (unsigned long i = 0; i < MT_ROUNDS; i++) {
				const u32 *A = ch_a[i & 63], *B = ch_b[i & 63];
				for (int j = 0; j < 8; j++)
					mt_sim[j] = (mt_sim[j] + A[j]) - B[j];
			}
			for (int j = 0; j < 8; j++)
				mt_acc[j] = mt_sim[j];
			for (int j = 0; j < 8 && !bad; j++)
				if (out[j] != mt_sim[j])
					bad = 1;
		}
		sys6(60, bad, 0, 0, 0, 0, 0);
	}
	while (reaped < MT_N) {
		long st = 0;
		long r = sys6(61, -1, (long)&st, 0, 0, 0, 0);
		if (r < 0)
			break;
		reaped++;
		long code = (st >> 8) & 0xff, sig = st & 0x7f;
		if (code) fails++;
		if (sig) fails++;
	}
	return fails;
}

void cstart(long *sp) {
	long argc = sp[0];
	char **argv = (char **)(sp + 1);
	int native_only = argc > 1 && argv[1][0] == 'n';
	u32 e71, d71;
	if (argc <= 1) {			// initramfs /init mode → printk/serial
		guest_mode = 1;
		long f = sys3(2, (long)"/dev/kmsg", 1, 0);	// open O_WRONLY
		if (f < 0)
			f = sys3(2, (long)"/dev/ttyS0", 1, 0);
		if (f > 0)
			outfd = f;
	}
	cpuid71(&e71, &d71);
	int have_vnni = (e71 & 0x10) != 0;
	int have_ifma = (e71 & 0x800000) != 0;
	int have_gfni = (cpuid70_ecx() & 0x100) != 0;
	int have_sha = (cpuid70_ebx() & 0x20000000) != 0;
	int have_pcl = (cpuid70_ecx() & 0x400) != 0;
	int have_vaes = (cpuid70_ecx() & 0x200) != 0;
	int pass = 0, total = 0;

	say("VEXTEST cpuid avx_vnni="); sayd(have_vnni); say(" avx_ifma="); sayd(have_ifma);
	say(" gfni="); sayd(have_gfni); say(" sha="); sayd(have_sha); say(" pclmul="); sayd(have_pcl); say(" vaes="); sayd(have_vaes);
	say(native_only ? " (native-only)\n" : "\n");
	lpos = 0;
	for (unsigned t = 0; t < sizeof(tests) / sizeof(tests[0]); t++) {
		for (int p = 1; p <= 3; p++) {
			if (p == 2 && tests[t].native_flag != 'i')
				continue;	// preset 2 is for IFMA masking
			if (p == 3 && tests[t].native_flag != 'v')
				continue;	// preset 3 is VNNI saturation
			int slash = 0;
			while (tests[t].name[slash] && tests[t].name[slash] != '/') slash++;
			int lanes = tests[t].name[slash + 1] == '2' ? 8 : 4;
			total++;
			int nat0 = tests[t].native_flag == 'v' ? have_vnni :
				   tests[t].native_flag == 'i' ? have_ifma :
				   tests[t].native_flag == 'g' ? have_gfni :
				   tests[t].native_flag == 'p' ? have_pcl :
				   tests[t].native_flag == 'a' ? have_vaes : have_sha;
			if (native_only && !nat0) { pass++; continue; }
			fill(p);
			tests[t].stub(out, vec_a, vec_b, vec_acc);
			tests[t].ref(want, vec_acc, vec_a, vec_b, lanes);
			int ok = 1;
			for (int i = 0; i < lanes; i++)
				if (out[i] != want[i]) ok = 0;
			int len = 0; while (tests[t].name[len]) len++;
			char wname[32];
			for (int i = 0; i < len; i++) wname[i] = tests[t].name[i];
			wname[len] = 0;
			int nat = tests[t].native_flag == 'v' ? have_vnni :
				  tests[t].native_flag == 'i' ? have_ifma :
				  tests[t].native_flag == 'g' ? have_gfni :
				  tests[t].native_flag == 'p' ? have_pcl :
				   tests[t].native_flag == 'a' ? have_vaes : have_sha;
			if (ok) pass++;
			say("VEXTEST "); say(wname); say(p == 2 ? "<mask52>" : ""); say(nat ? " native " : " emu ");
			say(ok ? "ok\n" : "FAIL ");
			if (!ok) {
				for (int i = 0; i < lanes; i++) {
					say("  lane"); sayd(i); say(" got="); sayx(out[i]); say(" want="); sayx(want[i]); say("\n");
				}
			}
		}
	}
	u32 digest[8];
	int orc = sha_stream(digest);
	int stage_fail = 0;
	total++;
	if (!orc) pass++;
	else stage_fail |= 2;
	int op_fail = pass < (total - 1);	// any per-op test failed
	if (op_fail) stage_fail |= 1;
	(void)op_fail;
	lpos = 0;
	lbs("VEXTEST sha256/compress-oracle ");
	lbs(have_sha ? "native " : "emu "); lbs(orc ? "FAIL" : "ok");
	lbs(" digest=");
	for (int i = 0; i < 8; i++) lbx(digest[i]);
	lbs("\n"); lb_flush();
	int at = 0, af = adx_tests(&at);
	total += at;
	pass += at - af;
	if (af) stage_fail |= 1;
	int rf = ra_chain_test();
	total++;
	if (!rf) pass++;
	else stage_fail |= 1;
	lpos = 0;
	lbs("VEXTEST runahead/sha-chain ");
	lbs(rf ? "FAIL" : (have_sha ? "native ok" : "emu ok"));
	lbs("\n"); lb_flush();
	int rrf = rav_chain_test();
	total++;
	if (!rrf) pass++;
	else stage_fail |= 1;
	lpos = 0;
	lbs("VEXTEST runahead/vex-chain ");
	lbs(rrf ? "FAIL" : (have_vnni ? "native ok" : "emu ok"));
	lbs("\n"); lb_flush();
	int cf = chain_stress();
	total++;
	if (!cf) pass++;
	else stage_fail |= 4;
	lpos = 0;
	lbs("VEXTEST vpdpwssd/chain-2048x4 ");
	lbs(cf ? "FAIL" : (have_vnni ? "native ok" : "emu ok"));
	lbs(" chain-acc=");
	for (int i = 0; i < 8; i++) lbx(ch_acc[i]);
	lbs("\n"); lb_flush();
	int mf = chain_stress_mt();
	total++;
	if (!mf) pass++;
	else stage_fail |= 8;
	lpos = 0;
	lbs("VEXTEST vpdpwssd/chain-mt-x4 ");
	lbs(mf ? "FAIL" : (have_vnni ? "native ok" : "emu ok"));
	lbs("\n"); lb_flush();
	int nf = chain_mt_native();
	total++;
	if (!nf) pass++;
	else stage_fail |= 0x10;
	lpos = 0;
	lbs("VEXTEST vpaddd/chain-mt-x4-nativeok ");
	lbs(nf ? "FAIL" : "ok");
	lbs("\n"); lb_flush();
	int ff = chain_mt_ifma();
	total++;
	if (!ff) pass++;
	else stage_fail |= 0x20;
	lpos = 0;
	lbs("VEXTEST vpmadd52luq/chain-mt-x4 ");
	lbs(ff ? "FAIL" : (have_ifma ? "native ok" : "emu ok"));
	lbs("\n"); lb_flush();
	int sf = chain_single_ifma();
	total++;
	if (!sf) pass++;
	else stage_fail |= 0x40;
	lpos = 0;
	lbs("VEXTEST vpmadd52luq/chain-single ");
	lbs(sf ? "FAIL" : (have_ifma ? "native ok" : "emu ok"));
	lbs("\n"); lb_flush();
	lpos = 0;
	lbs("VEXTEST ");
	lbs(pass == total ? "PASS " : "FAIL ");
	lbd(pass); lbs("/"); lbd(total); lbs("\n"); lb_flush();
	sys1(60, pass == total ? 0 : (0x80 | stage_fail));
	__builtin_unreachable();
}
