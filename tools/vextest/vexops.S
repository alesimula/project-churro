// vexops.S — hand-encoded VEX AVX-VNNI / AVX-IFMA stubs for vextest.c.
// All reg stubs: ymm1/xmm1 = a (vvvv), ymm2/xmm2 = b (rm), ymm0/xmm0 = acc+dst.
// Encodings: C4 E2 <W'vvvv'Lpp> <op> <modrm>; byte2 = 0x71 (VNNI.128), 0x75 (VNNI.256),
// 0xF1 (IFMA.128, W1), 0xF5 (IFMA.256, W1); reg-form modrm = mod11 reg000 rm010 = 0xC2.
	.text
	.p2align 4

#define REGSTUB(name, b2, op)			\
	.globl name;				\
name:						\
	vmovdqu	(%rsi), %ymm1;			\
	vmovdqu	(%rdx), %ymm2;			\
	vmovdqu	(%rcx), %ymm0;			\
	.byte	0xc4, 0xe2, b2, op, 0xc2;	\
	vmovdqu	%ymm0, (%rdi);			\
	vzeroupper;				\
	ret

REGSTUB(op50_128_reg, 0x71, 0x50)
REGSTUB(op50_256_reg, 0x75, 0x50)
REGSTUB(op51_128_reg, 0x71, 0x51)
REGSTUB(op51_256_reg, 0x75, 0x51)
REGSTUB(op52_128_reg, 0x71, 0x52)
REGSTUB(op52_256_reg, 0x75, 0x52)
REGSTUB(op53_128_reg, 0x71, 0x53)
REGSTUB(op53_256_reg, 0x75, 0x53)
REGSTUB(opb4_128_reg, 0xf1, 0xb4)
REGSTUB(opb4_256_reg, 0xf5, 0xb4)
REGSTUB(opb5_128_reg, 0xf1, 0xb5)
REGSTUB(opb5_256_reg, 0xf5, 0xb5)

// vpdpwssd ymm0, ymm1, [rax]
	.globl op52_256_mem_ind
op52_256_mem_ind:
	vmovdqu	(%rsi), %ymm1
	vmovdqu	(%rcx), %ymm0
	movq	%rdx, %rax
	.byte	0xc4, 0xe2, 0x75, 0x52, 0x00
	vmovdqu	%ymm0, (%rdi)
	vzeroupper
	ret

// vpdpwssd ymm0, ymm1, [r9 + r10*2 + 64]  (SIB, extended index/base -> VEX X/B)
	.globl op52_256_mem_sib
op52_256_mem_sib:
	vmovdqu	(%rsi), %ymm1
	vmovdqu	(%rcx), %ymm0
	movq	%rdx, %r9
	subq	$64, %r9
	xorl	%r10d, %r10d
	.byte	0xc4, 0x82, 0x75, 0x52, 0x44, 0x51, 0x40
	vmovdqu	%ymm0, (%rdi)
	vzeroupper
	ret

// vpdpwssd ymm0, ymm1, [rip + vripdata]
	.globl op52_256_mem_rip
op52_256_mem_rip:
	vmovdqu	(%rsi), %ymm1
	vmovdqu	(%rcx), %ymm0
	movl	$32, %ecx
	pushq	%rdi
	pushq	%rsi
	movq	%rdx, %rsi
	leaq	vripdata(%rip), %rdi
	rep movsb
	popq	%rsi
	popq	%rdi
	.byte	0xc4, 0xe2, 0x75, 0x52, 0x05
	.long	vripdata - . - 4
	vmovdqu	%ymm0, (%rdi)
	vzeroupper
	ret

// vpdpwssd ymm8, ymm9, ymm10  (extended dst/src registers -> VEX R/B)
	.globl op52_256_reghi
op52_256_reghi:
	vmovdqu	(%rsi), %ymm9
	vmovdqu	(%rdx), %ymm10
	vmovdqu	(%rcx), %ymm8
	.byte	0xc4, 0x42, 0x35, 0x52, 0xc2
	vmovdqu	%ymm8, (%rdi)
	vzeroupper
	ret

// vpmadd52luq ymm0, ymm1, [r9 + r10*2 + 64]
	.globl opb4_256_mem_sib
opb4_256_mem_sib:
	vmovdqu	(%rsi), %ymm1
	vmovdqu	(%rcx), %ymm0
	movq	%rdx, %r9
	subq	$64, %r9
	xorl	%r10d, %r10d
	.byte	0xc4, 0x82, 0xf5, 0xb4, 0x44, 0x51, 0x40
	vmovdqu	%ymm0, (%rdi)
	vzeroupper
	ret

// --- GFNI: AFFINEQB = 66.0F3A.W1 0xCE /r ib, AFFINEINVQB = 66.0F3A.W1 0xCF /r ib,
//     MULB = 66.0F38.W0 0xCF /r (no imm) ---
#define GFSTUB(name, b2, op, imm...)		\
	.globl name;				\
name:						\
	vmovdqu	(%rsi), %ymm1;			\
	vmovdqu	(%rdx), %ymm2;			\
	.byte	0xc4, 0xe3, b2, op, 0xc2, imm;	\
	vmovdqu	%ymm0, (%rdi);			\
	vzeroupper;				\
	ret

GFSTUB(opgb_128_reg, 0xf1, 0xce, 0x63)
GFSTUB(opgb_256_reg, 0xf5, 0xce, 0x63)
GFSTUB(opge_128_reg, 0xf1, 0xcf, 0xa4)
GFSTUB(opge_256_reg, 0xf5, 0xcf, 0xa4)

	.globl opgf_128_reg
opgf_128_reg:
	vmovdqu	(%rsi), %ymm1
	vmovdqu	(%rdx), %ymm2
	.byte	0xc4, 0xe2, 0x71, 0xcf, 0xc2
	vmovdqu	%ymm0, (%rdi)
	vzeroupper
	ret

	.globl opgf_256_reg
opgf_256_reg:
	vmovdqu	(%rsi), %ymm1
	vmovdqu	(%rdx), %ymm2
	.byte	0xc4, 0xe2, 0x75, 0xcf, 0xc2
	vmovdqu	%ymm0, (%rdi)
	vzeroupper
	ret

// vgf2p8affineqb ymm0, ymm1, [r9 + r10*2 + 64], 0x63  (map3: byte1 0x83)
	.globl opgb_256_mem_sib
opgb_256_mem_sib:
	vmovdqu	(%rsi), %ymm1
	movq	%rdx, %r9
	subq	$64, %r9
	xorl	%r10d, %r10d
	.byte	0xc4, 0x83, 0xf5, 0xce, 0x44, 0x51, 0x40, 0x63
	vmovdqu	%ymm0, (%rdi)
	vzeroupper
	ret

// --- SHA-NI, legacy NP: 0F 38 C8..CD /r, 0F 3A CC /r ib ---
// Convention: xmm2 = DEST/SRC1 (<- acc = rcx), xmm1 = SRC2 (<- b = rdx),
// xmm0 = implicit WK operand for sha256rnds2 (<- a = rsi)
#define SHASTUB(name, op)			\
	.globl name;				\
name:						\
	vmovdqu	(%rsi), %xmm0;			\
	vmovdqu	(%rdx), %xmm1;			\
	vmovdqu	(%rcx), %xmm2;			\
	.byte	0x0f, 0x38, op, 0xd1;		\
	vmovdqu	%xmm2, (%rdi);			\
	ret

SHASTUB(sha256rnds2_reg, 0xcb)
SHASTUB(sha256msg1_reg, 0xcc)
SHASTUB(sha256msg2_reg, 0xcd)
SHASTUB(sha1nexte_reg, 0xc8)
SHASTUB(sha1msg1_reg, 0xc9)
SHASTUB(sha1msg2_reg, 0xca)

// sha256msg2 xmm2, [rdx]  (mem operand; NP legacy cannot name r9/r10)
	.globl sha256msg2_mem_sib
sha256msg2_mem_sib:
	vmovdqu	(%rcx), %xmm2
	.byte	0x0f, 0x38, 0xcd, 0x12
	vmovdqu	%xmm2, (%rdi)
	ret

// sha1rnds4 xmm2, xmm1, imm  (NP 0F 3A CC /r ib)
#define SHA4STUB(name, imm)			\
	.globl name;				\
name:						\
	vmovdqu	(%rdx), %xmm1;			\
	vmovdqu	(%rcx), %xmm2;			\
	.byte	0x0f, 0x3a, 0xcc, 0xd1, imm;	\
	vmovdqu	%xmm2, (%rdi);			\
	ret

SHA4STUB(sha1rnds4_i0, 0)
SHA4STUB(sha1rnds4_i1, 1)
SHA4STUB(sha1rnds4_i2, 2)
SHA4STUB(sha1rnds4_i3, 3)

// REX forms (xmm8-15, as in BoringSSL/liblzma) + legacy-SSE upper-half check: DEST is loaded as a
// full ymm from acc, so out[4..7] must come back as acc[4..7]. modrm 0xd1: reg=2, rm=1;
// REX.R -> xmm10, REX.B -> xmm9. xmm0 = WK for sha256rnds2.
#define SHAREX(name, rex, op, dreg)		\
	.globl name;				\
name:						\
	vmovdqu	(%rsi), %ymm0;			\
	vmovdqu	(%rdx), %ymm1;			\
	vmovdqu	(%rdx), %ymm9;			\
	vmovdqu	(%rcx), %ymm2;			\
	vmovdqu	(%rcx), %ymm10;			\
	.byte	rex, 0x0f, 0x38, op, 0xd1;	\
	vmovdqu	dreg, (%rdi);			\
	vzeroupper;				\
	ret

SHAREX(sha256msg1_rex45, 0x45, 0xcc, %ymm10)
SHAREX(sha256msg2_rex44, 0x44, 0xcd, %ymm10)
SHAREX(sha1nexte_rex41, 0x41, 0xc8, %ymm2)
SHAREX(sha256rnds2_rex45, 0x45, 0xcb, %ymm10)

// ADX (adcx/adox): s = rdi: s[0] = dest in/out, s[1] = source, s[2] = RFLAGS in/out.
// Only caller-saved registers; 32-bit forms zero-extend into the 64-bit dest.
#define ADXSTUB(name, d64, s64, op, src, dst)	\
	.globl name;				\
name:						\
	mov	0(%rdi), d64;			\
	mov	8(%rdi), s64;			\
	pushq	16(%rdi);			\
	popfq;					\
	op	src, dst;			\
	pushfq;					\
	popq	16(%rdi);			\
	mov	d64, 0(%rdi);			\
	ret

ADXSTUB(adcx_r64_rex, %r8, %r9, adcx, %r9, %r8)
ADXSTUB(adox_r64, %rax, %rcx, adox, %rcx, %rax)
ADXSTUB(adcx_r32, %rax, %rcx, adcx, %ecx, %eax)
ADXSTUB(adox_m64_rex, %r11, %rsi, adox, 8(%rdi), %r11)
ADXSTUB(adcx_m32, %rdx, %rsi, adcx, 8(%rdi), %edx)

// ra_chain(x = rdi: 16 xmm in/out, m = rsi: 64-byte-aligned 96-byte buffer): one trapping
// SHA-NI op followed by straight-line plain SSE in the shape of BoringSSL's SHA-256 loop, so the
// kernel's run-ahead interprets everything up to the stores. Mirrored by ra_model() in vextest.c.
	.globl ra_chain
ra_chain:
	movdqu	0x00(%rdi), %xmm0
	movdqu	0x10(%rdi), %xmm1
	movdqu	0x20(%rdi), %xmm2
	movdqu	0x30(%rdi), %xmm3
	movdqu	0x40(%rdi), %xmm4
	movdqu	0x50(%rdi), %xmm5
	movdqu	0x60(%rdi), %xmm6
	movdqu	0x70(%rdi), %xmm7
	movdqu	0x80(%rdi), %xmm8
	movdqu	0x90(%rdi), %xmm9
	movdqu	0xa0(%rdi), %xmm10
	movdqu	0xb0(%rdi), %xmm11
	movdqu	0xc0(%rdi), %xmm12
	movdqu	0xd0(%rdi), %xmm13
	movdqu	0xe0(%rdi), %xmm14
	movdqu	0xf0(%rdi), %xmm15
	sha256rnds2 %xmm0, %xmm1, %xmm2		// traps on a gap CPU; the rest is run-ahead
	pshufd	$0x0e, %xmm0, %xmm0
	nop
	movdqa	%xmm1, %xmm9
	sha256msg1 %xmm4, %xmm3
	paddd	0x10(%rsi), %xmm0
	palignr	$4, %xmm5, %xmm7
	pshufb	%xmm8, %xmm6
	sha256msg2 %xmm6, %xmm3
	punpcklqdq %xmm0, %xmm10
	punpckhqdq %xmm11, %xmm12
	lea	0x20(%rsi), %rsi
	movdqa	(%rsi), %xmm13
	movdqu	0x24(%rsi), %xmm14
	sha256rnds2 %xmm0, %xmm9, %xmm11
	sha1rnds4 $1, %xmm15, %xmm14
	nopl	0x0(%rax,%rax,1)
	movdqu	%xmm0, 0x00(%rdi)
	movdqu	%xmm1, 0x10(%rdi)
	movdqu	%xmm2, 0x20(%rdi)
	movdqu	%xmm3, 0x30(%rdi)
	movdqu	%xmm4, 0x40(%rdi)
	movdqu	%xmm5, 0x50(%rdi)
	movdqu	%xmm6, 0x60(%rdi)
	movdqu	%xmm7, 0x70(%rdi)
	movdqu	%xmm8, 0x80(%rdi)
	movdqu	%xmm9, 0x90(%rdi)
	movdqu	%xmm10, 0xa0(%rdi)
	movdqu	%xmm11, 0xb0(%rdi)
	movdqu	%xmm12, 0xc0(%rdi)
	movdqu	%xmm13, 0xd0(%rdi)
	movdqu	%xmm14, 0xe0(%rdi)
	movdqu	%xmm15, 0xf0(%rdi)
	ret

// rav_chain(x = rdi: 16 ymm in/out, m = rsi: 32-byte-aligned 128-byte buffer): one trapping
// vpdpwssd, the straight-line AVX2 of a zlib Adler-32 style loop (the shape the kernel's VEX
// run-ahead is for), a run-stopping integer op, then a second trapping vpdpwssd with VEX.128
// forms. Mirrored by rav_model() in vextest.c.
	.globl rav_chain
rav_chain:
	vmovdqu	0x000(%rdi), %ymm0
	vmovdqu	0x020(%rdi), %ymm1
	vmovdqu	0x040(%rdi), %ymm2
	vmovdqu	0x060(%rdi), %ymm3
	vmovdqu	0x080(%rdi), %ymm4
	vmovdqu	0x0a0(%rdi), %ymm5
	vmovdqu	0x0c0(%rdi), %ymm6
	vmovdqu	0x0e0(%rdi), %ymm7
	vmovdqu	0x100(%rdi), %ymm8
	vmovdqu	0x120(%rdi), %ymm9
	vmovdqu	0x140(%rdi), %ymm10
	vmovdqu	0x160(%rdi), %ymm11
	vmovdqu	0x180(%rdi), %ymm12
	vmovdqu	0x1a0(%rdi), %ymm13
	vmovdqu	0x1c0(%rdi), %ymm14
	vmovdqu	0x1e0(%rdi), %ymm15
	// the VNNI ops are hand-encoded VEX (gas emits EVEX for the mnemonics; the emulator
	// only handles VEX). C4 E2 <W~vvvvLpp> <op> <modrm> [disp8]
	.byte	0xc4, 0xe2, 0x6d, 0x52, 0xcb		// vpdpwssd %ymm3,%ymm2,%ymm1  <- traps; 2..13 is run-ahead
	vmovdqu	0x00(%rsi), %ymm4
	vmovdqu	0x1c(%rsi), %ymm5
	vmovdqa	0x40(%rsi), %ymm6
	vpsadbw	%ymm4, %ymm5, %ymm7
	vpmaddubsw %ymm4, %ymm5, %ymm8
	vpaddd	%ymm7, %ymm8, %ymm9
	vpmaddwd %ymm4, %ymm9, %ymm9
	vpxor	%ymm9, %ymm10, %ymm10
	.byte	0xc4, 0x42, 0x5d, 0x52, 0xd8		// vpdpwssd %ymm8,%ymm4,%ymm11
	.byte	0xc4, 0x62, 0x4d, 0x52, 0x66, 0x60	// vpdpwssd 0x60(%rsi),%ymm6,%ymm12
	.byte	0xc4, 0x62, 0x4d, 0x50, 0xef		// vpdpbusd %ymm7,%ymm6,%ymm13
	lea	0x20(%rsi), %rax			// interpreted: rax = m + 0x20
	.byte	0xc4, 0x42, 0x15, 0x52, 0xf4		// vpdpwssd %ymm12,%ymm13,%ymm14
	addl	$1, %eax				// not allow-listed: run stops, CPU runs it
	.byte	0xc4, 0x42, 0x25, 0x52, 0xfa		// vpdpwssd %ymm10,%ymm11,%ymm15  <- second run
	vmovdqu	(%rax), %xmm0				// VEX.128 load: rax = m + 0x21
	.byte	0xc4, 0xe2, 0x71, 0x52, 0xd0		// vpdpwssd %xmm0,%xmm1,%xmm2 (VEX.128)
	vmovdqu	%ymm0, 0x000(%rdi)
	vmovdqu	%ymm1, 0x020(%rdi)
	vmovdqu	%ymm2, 0x040(%rdi)
	vmovdqu	%ymm3, 0x060(%rdi)
	vmovdqu	%ymm4, 0x080(%rdi)
	vmovdqu	%ymm5, 0x0a0(%rdi)
	vmovdqu	%ymm6, 0x0c0(%rdi)
	vmovdqu	%ymm7, 0x0e0(%rdi)
	vmovdqu	%ymm8, 0x100(%rdi)
	vmovdqu	%ymm9, 0x120(%rdi)
	vmovdqu	%ymm10, 0x140(%rdi)
	vmovdqu	%ymm11, 0x160(%rdi)
	vmovdqu	%ymm12, 0x180(%rdi)
	vmovdqu	%ymm13, 0x1a0(%rdi)
	vmovdqu	%ymm14, 0x1c0(%rdi)
	vmovdqu	%ymm15, 0x1e0(%rdi)
	vzeroupper
	ret

// --- vpclmulqdq: VEX.66.0F3A.W0 0x44 /r ib ---
#define PCMSTUB(name, b2, imm)			\
	.globl name;				\
name:						\
	vmovdqu	(%rsi), %ymm1;			\
	vmovdqu	(%rdx), %ymm2;			\
	.byte	0xc4, 0xe3, b2, 0x44, 0xc2, imm;\
	vmovdqu	%ymm0, (%rdi);			\
	vzeroupper;				\
	ret

PCMSTUB(pc_128_i00, 0x71, 0x00)
PCMSTUB(pc_256_i00, 0x75, 0x00)
PCMSTUB(pc_256_i11, 0x75, 0x11)
PCMSTUB(pc_256_i01, 0x75, 0x01)
PCMSTUB(pc_256_i10, 0x75, 0x10)

// VAES (VEX.256.66.0F38.WIG DC..DF): ymm0 = round(state = ymm1, key = ymm2)
REGSTUB(vaesenc_256_reg, 0x75, 0xdc)
REGSTUB(vaesenclast_256_reg, 0x75, 0xdd)
REGSTUB(vaesdec_256_reg, 0x75, 0xde)
REGSTUB(vaesdeclast_256_reg, 0x75, 0xdf)

// wssd_chain_256(out=rdi, a=rsi, b=rdx, acc=rcx, rounds=r8)
// acc ymm0 chained: acc = vpdpwssd(acc, a[i & 63], b[i & 63]) for i in 0..rounds-1.
// vpdpwssd ymm0, ymm3, ymm4  =  c4 e2 65 52 c4  (vvvv=3 -> Vy=3, rm=4)
	.globl wssd_chain_256
wssd_chain_256:
	vmovdqu	(%rcx), %ymm0
	xorq	%r9, %r9
	cmpq	%r8, %r9
	jae	2f
1:	movq	%r9, %rax
	andq	$63, %rax
	shlq	$5, %rax
	vmovdqu	(%rsi,%rax), %ymm3
	vmovdqu	(%rdx,%rax), %ymm4
	.byte	0xc4, 0xe2, 0x65, 0x52, 0xc4
	incq	%r9
	cmpq	%r8, %r9
	jb	1b
2:	vmovdqu	%ymm0, (%rdi)
	vzeroupper
	ret

// same chaining shape but TCG-native ops (no #UD): used to isolate whether
// divergence comes from the emulation path or from the VM's context switching.
// xavg_chain_256: ymm0 = vpavgw(ymm0, ymm3, ymm4) chained — 66 0F E3 → C4 E2 65 E3 C4
	.globl xavg_chain_256
xavg_chain_256:
	vmovdqu	(%rcx), %ymm0
	xorq	%r9, %r9
	cmpq	%r8, %r9
	jae	2f
1:	movq	%r9, %rax
	andq	$63, %rax
	shlq	$5, %rax
	vmovdqu	(%rsi,%rax), %ymm3
	vmovdqu	(%rdx,%rax), %ymm4
	.byte	0xc4, 0xe2, 0x65, 0xe3, 0xc4
	incq	%r9
	cmpq	%r8, %r9
	jb	1b
2:	vmovdqu	%ymm0, (%rdi)
	vzeroupper
	ret

// wssd_chain_256r1: same chain but acc = ymm1 (vpdpwssd ymm1, ymm3, ymm4 = c4 e2 65 52 cc)
	.globl wssd_chain_256r1
wssd_chain_256r1:
	vmovdqu	(%rcx), %ymm1
	xorq	%r9, %r9
	cmpq	%r8, %r9
	jae	2f
1:	movq	%r9, %rax
	andq	$63, %rax
	shlq	$5, %rax
	vmovdqu	(%rsi,%rax), %ymm3
	vmovdqu	(%rdx,%rax), %ymm4
	.byte	0xc4, 0xe2, 0x65, 0x52, 0xcc
	incq	%r9
	cmpq	%r8, %r9
	jb	1b
2:	vmovdqu	%ymm1, (%rdi)
	vzeroupper
	ret

// m52_chain_256: chained IFMA: per round ymm0 = vpmadd52luq(ymm0, ymm3, ymm4)
// (accumulate into dst like vpdpwssd, but natively supported by TCG) — C4 E3 F5 B4 C4
	.globl m52_chain_256
m52_chain_256:
	vmovdqu	(%rcx), %ymm0
	xorq	%r9, %r9
	cmpq	%r8, %r9
	jae	2f
1:	movq	%r9, %rax
	andq	$63, %rax
	shlq	$5, %rax
	vmovdqu	(%rsi,%rax), %ymm3
	vmovdqu	(%rdx,%rax), %ymm4
	.byte	0xc4, 0xe2, 0xe5, 0xb4, 0xc4
	incq	%r9
	cmpq	%r8, %r9
	jb	1b
2:	vmovdqu	%ymm0, (%rdi)
	vzeroupper
	ret

// xpadd_chain_256: chained TCG-native accumulate: per round ymm0 = ymm0 + ymm3 - ymm4
// vpaddd ymm0,ymm0,ymm3 = c4 e1 7d fe c3  (vvvv=0)  vpsubd ymm0,ymm0,ymm4 = c4 e1 7d fa c4
	.globl xpadd_chain_256
xpadd_chain_256:
	vmovdqu	(%rcx), %ymm0
	xorq	%r9, %r9
	cmpq	%r8, %r9
	jae	2f
1:	movq	%r9, %rax
	andq	$63, %rax
	shlq	$5, %rax
	vmovdqu	(%rsi,%rax), %ymm3
	vmovdqu	(%rdx,%rax), %ymm4
	.byte	0xc4, 0xe1, 0x7d, 0xfe, 0xc3
	.byte	0xc4, 0xe1, 0x7d, 0xfa, 0xc4
	incq	%r9
	cmpq	%r8, %r9
	jb	1b
2:	vmovdqu	%ymm0, (%rdi)
	vzeroupper
	ret

	.data
	.p2align 5
vripdata:
	.fill	32, 1, 0
	.section .note.GNU-stack,"",@progbits
