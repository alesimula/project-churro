/*
 *  Copyright (C) 1991, 1992  Linus Torvalds
 *  Copyright (C) 2000, 2001, 2002 Andi Kleen, SuSE Labs
 *
 *  Pentium III FXSR, SSE support
 *	Gareth Hughes <gareth@valinux.com>, May 2000
 */

/*
 * Handle hardware traps and faults.
 */

#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/context_tracking.h>
#include <linux/interrupt.h>
#include <linux/kallsyms.h>
#include <linux/kmsan.h>
#include <linux/spinlock.h>
#include <linux/kprobes.h>
#include <linux/uaccess.h>
#include <linux/kdebug.h>
#include <linux/kgdb.h>
#include <linux/kernel.h>
#include <linux/export.h>
#include <linux/ptrace.h>
#include <linux/moduleparam.h>
#include <linux/uprobes.h>
#include <linux/string.h>
#include <linux/delay.h>
#include <linux/errno.h>
#include <linux/kexec.h>
#include <linux/sched.h>
#include <linux/sched/task_stack.h>
#include <linux/timer.h>
#include <linux/init.h>
#include <linux/bug.h>
#include <linux/nmi.h>
#include <linux/mm.h>
#include <linux/smp.h>
#include <linux/cpu.h>
#include <linux/io.h>
#include <linux/hardirq.h>
#include <linux/atomic.h>
#include <linux/iommu.h>
#include <linux/ubsan.h>

#include <asm/stacktrace.h>
#include <asm/processor.h>
#include <asm/debugreg.h>
#include <asm/realmode.h>
#include <asm/text-patching.h>
#include <asm/ftrace.h>
#include <asm/traps.h>
#include <asm/desc.h>
#include <asm/fred.h>
#include <asm/fpu/api.h>
#include <asm/cpu.h>
#include <asm/cpu_entry_area.h>
#include <asm/mce.h>
#include <asm/fixmap.h>
#include <asm/mach_traps.h>
#include <asm/alternative.h>
#include <asm/fpu/xstate.h>
#include <asm/fpu/signal.h>
#include <asm/fpu/sched.h>
#include <asm/fpu/api.h>
#include <asm/thread_info.h>
#include <asm/vm86.h>
#include <asm/umip.h>
#include <asm/insn.h>
#include <asm/insn-eval.h>
#include <asm/vdso.h>
#include <asm/tdx.h>
#include <asm/cfi.h>
#include <asm/msr.h>

#ifdef CONFIG_X86_64
#include <asm/x86_init.h>
#else
#include <asm/processor-flags.h>
#include <asm/setup.h>
#endif

#include <asm/proto.h>

DECLARE_BITMAP(system_vectors, NR_VECTORS);

__always_inline int is_valid_bugaddr(unsigned long addr)
{
	if (addr < TASK_SIZE_MAX)
		return 0;

	/*
	 * We got #UD, if the text isn't readable we'd have gotten
	 * a different exception.
	 */
	return *(unsigned short *)addr == INSN_UD2;
}

/*
 * Check for UD1 or UD2, accounting for Address Size Override Prefixes.
 * If it's a UD1, further decode to determine its use:
 *
 * FineIBT:      d6                      udb
 * FineIBT:      f0 75 f9                lock jne . - 6
 * UBSan{0}:     67 0f b9 00             ud1    (%eax),%eax
 * UBSan{10}:    67 0f b9 40 10          ud1    0x10(%eax),%eax
 * static_call:  0f b9 cc                ud1    %esp,%ecx
 *
 * Notably UBSAN uses EAX, static_call uses ECX.
 */
__always_inline int decode_bug(unsigned long addr, s32 *imm, int *len)
{
	unsigned long start = addr;
	bool lock = false;
	u8 v;

	if (addr < TASK_SIZE_MAX)
		return BUG_NONE;

	v = *(u8 *)(addr++);
	if (v == INSN_ASOP)
		v = *(u8 *)(addr++);

	if (v == INSN_LOCK) {
		lock = true;
		v = *(u8 *)(addr++);
	}

	switch (v) {
	case 0x70 ... 0x7f: /* Jcc.d8 */
		addr += 1; /* d8 */
		*len = addr - start;
		WARN_ON_ONCE(!lock);
		return BUG_LOCK;

	case 0xd6:
		*len = addr - start;
		return BUG_UDB;

	case OPCODE_ESCAPE:
		break;

	default:
		return BUG_NONE;
	}

	v = *(u8 *)(addr++);
	if (v == SECOND_BYTE_OPCODE_UD2) {
		*len = addr - start;
		return BUG_UD2;
	}

	if (v != SECOND_BYTE_OPCODE_UD1)
		return BUG_NONE;

	*imm = 0;
	v = *(u8 *)(addr++);		/* ModRM */

	if (X86_MODRM_MOD(v) != 3 && X86_MODRM_RM(v) == 4)
		addr++;			/* SIB */

	/* Decode immediate, if present */
	switch (X86_MODRM_MOD(v)) {
	case 0: if (X86_MODRM_RM(v) == 5)
			addr += 4; /* RIP + disp32 */
		break;

	case 1: *imm = *(s8 *)addr;
		addr += 1;
		break;

	case 2: *imm = *(s32 *)addr;
		addr += 4;
		break;

	case 3: break;
	}

	/* record instruction length */
	*len = addr - start;

	if (X86_MODRM_REG(v) == 0)	/* EAX */
		return BUG_UD1_UBSAN;

	return BUG_UD1;
}


static nokprobe_inline int
do_trap_no_signal(struct task_struct *tsk, int trapnr, const char *str,
		  struct pt_regs *regs,	long error_code)
{
	if (v8086_mode(regs)) {
		/*
		 * Traps 0, 1, 3, 4, and 5 should be forwarded to vm86.
		 * On nmi (interrupt 2), do_trap should not be called.
		 */
		if (trapnr < X86_TRAP_UD) {
			if (!handle_vm86_trap((struct kernel_vm86_regs *) regs,
						error_code, trapnr))
				return 0;
		}
	} else if (!user_mode(regs)) {
		if (fixup_exception(regs, trapnr, error_code, 0))
			return 0;

		tsk->thread.error_code = error_code;
		tsk->thread.trap_nr = trapnr;
		die(str, regs, error_code);
	} else {
		if (fixup_vdso_exception(regs, trapnr, error_code, 0))
			return 0;
	}

	/*
	 * We want error_code and trap_nr set for userspace faults and
	 * kernelspace faults which result in die(), but not
	 * kernelspace faults which are fixed up.  die() gives the
	 * process no chance to handle the signal and notice the
	 * kernel fault information, so that won't result in polluting
	 * the information about previously queued, but not yet
	 * delivered, faults.  See also exc_general_protection below.
	 */
	tsk->thread.error_code = error_code;
	tsk->thread.trap_nr = trapnr;

	return -1;
}

static void show_signal(struct task_struct *tsk, int signr,
			const char *type, const char *desc,
			struct pt_regs *regs, long error_code)
{
	if (show_unhandled_signals && unhandled_signal(tsk, signr) &&
	    printk_ratelimit()) {
		pr_info("%s[%d] %s%s ip:%lx sp:%lx error:%lx",
			tsk->comm, task_pid_nr(tsk), type, desc,
			regs->ip, regs->sp, error_code);
		print_vma_addr(KERN_CONT " in ", regs->ip);
		pr_cont("\n");
	}
}

static void
do_trap(int trapnr, int signr, char *str, struct pt_regs *regs,
	long error_code, int sicode, void __user *addr)
{
	struct task_struct *tsk = current;

	if (!do_trap_no_signal(tsk, trapnr, str, regs, error_code))
		return;

	show_signal(tsk, signr, "trap ", str, regs, error_code);

	if (!sicode)
		force_sig(signr);
	else
		force_sig_fault(signr, sicode, addr);
}
NOKPROBE_SYMBOL(do_trap);

static void do_error_trap(struct pt_regs *regs, long error_code, char *str,
	unsigned long trapnr, int signr, int sicode, void __user *addr)
{
	RCU_LOCKDEP_WARN(!rcu_is_watching(), "entry code didn't wake RCU");

	if (notify_die(DIE_TRAP, str, regs, error_code, trapnr, signr) !=
			NOTIFY_STOP) {
		cond_local_irq_enable(regs);
		do_trap(trapnr, signr, str, regs, error_code, sicode, addr);
		cond_local_irq_disable(regs);
	}
}

/*
 * Posix requires to provide the address of the faulting instruction for
 * SIGILL (#UD) and SIGFPE (#DE) in the si_addr member of siginfo_t.
 *
 * This address is usually regs->ip, but when an uprobe moved the code out
 * of line then regs->ip points to the XOL code which would confuse
 * anything which analyzes the fault address vs. the unmodified binary. If
 * a trap happened in XOL code then uprobe maps regs->ip back to the
 * original instruction address.
 */
static __always_inline void __user *error_get_trap_addr(struct pt_regs *regs)
{
	return (void __user *)uprobe_get_trap_addr(regs);
}

DEFINE_IDTENTRY(exc_divide_error)
{
	do_error_trap(regs, 0, "divide error", X86_TRAP_DE, SIGFPE,
		      FPE_INTDIV, error_get_trap_addr(regs));
}

DEFINE_IDTENTRY(exc_overflow)
{
	do_error_trap(regs, 0, "overflow", X86_TRAP_OF, SIGSEGV, 0, NULL);
}


/*
 * Churro: emulate the VEX-encoded AVX-VNNI (vpdpbusd[s], vpdpwssd[s]),
 * AVX-IFMA (vpmadd52luq/huq), GFNI (gf2p8affine[inv]qb, gf2p8mulb) and the
 * legacy-encoded SHA-NI instructions (sha1rnds4/nexte/msg1/msg2,
 * sha256rnds2/msg1/msg2), VPCLMULQDQ and 256-bit VAES (vaesenc/enclast/dec/
 * declast ymm). The Googlebook userspace is built -march=pantherlake and runs
 * these unconditionally, but "Tier-1 gap" CPUs lack VNNI/IFMA-VEX (Ice Lake and
 * Zen 4; Alder/Raptor/Meteor Lake) and older ones also GFNI, SHA-NI and VAES
 * (Haswell..Comet Lake: BoringSSL's FIPS self-test in init runs vaesenc ymm),
 * and Haswell also ADX (adcx/adox: BoringSSL's RSA/ECC, Rust ring), so core boot
 * binaries (incl. second-stage init, odsign) die with SIGILL and the boot
 * panics or stalls. This only runs on #UD, i.e. it is dormant on CPUs with the
 * native forms. VAES/VPCLMULQDQ execute natively per 128-bit lane on the operand
 * copies when the CPU has AES-NI/PCLMULQDQ, vpdpwssd as pmaddwd+paddd (AVX2), and
 * after a SHA-NI or AVX-VNNI instruction the handler also interprets the following
 * allow-listed SSE/VEX code ("run-ahead"), so a loop costs ~1 trap instead of one
 * per instruction. Per-opcode trap counts are logged (ratelimited) as the
 * hotness gauge for a possible offline rewriter. churro.vexemu=0 in
 * bootconfig disables it.
 */
enum churro_vex_op {
	CHURRO_VPBUSD, CHURRO_VPBUSDS, CHURRO_VPWSSD, CHURRO_VPWSSDS,
	CHURRO_VPM52LQ, CHURRO_VPM52HQ,
	CHURRO_GFAFQ, CHURRO_GFAINVQ, CHURRO_GFMULB,
	CHURRO_SHA1NEXTE, CHURRO_SHA1MSG1, CHURRO_SHA1MSG2,
	CHURRO_SHA256RNDS2, CHURRO_SHA256MSG1, CHURRO_SHA256MSG2,
	CHURRO_SHA1RNDS4,
	CHURRO_PCLMULQDQ,
	CHURRO_VAESENC, CHURRO_VAESENCLAST, CHURRO_VAESDEC, CHURRO_VAESDECLAST,
	CHURRO_ADCX, CHURRO_ADOX,	/* integer-only: handle_adx_ud(), never handle_vex_ud() */
	CHURRO_NR_OPS
};

static bool churro_vexemu = true;
module_param(churro_vexemu, bool, 0644);
MODULE_PARM_DESC(churro_vexemu,
	"Emulate VEX AVX-VNNI/AVX-IFMA/GFNI/PCLMULQDQ/VAES and SHA-NI user instructions on #UD (gap CPUs)");

static int __init churro_vexemu_setup(char *str)
{
	return kstrtobool(str, &churro_vexemu) == 0;
}
__setup("churro.vexemu=", churro_vexemu_setup);

static atomic64_t churro_vexemu_count[CHURRO_NR_OPS];
static DEFINE_RATELIMIT_STATE(churro_vexemu_rs, DEFAULT_RATELIMIT_INTERVAL,
			      DEFAULT_RATELIMIT_BURST);

/* For the ratelimited trap line: " @ <file>(<fs id>)+0x<file offset>" of the trapping address,
 * so the hot library is known (the fs id tells a bind-mounted copy from the original). */
static void churro_where(unsigned long ip, char *buf, size_t n)
{
	struct mm_struct *mm = current->mm;
	struct vm_area_struct *vma;

	buf[0] = 0;
	if (!mm || !mmap_read_trylock(mm))
		return;
	vma = vma_lookup(mm, ip);
	if (vma && vma->vm_file)
		snprintf(buf, n, " @ %s(%s)+0x%lx", file_dentry(vma->vm_file)->d_name.name,
			 file_inode(vma->vm_file)->i_sb->s_id,
			 ip - vma->vm_start + (vma->vm_pgoff << PAGE_SHIFT));
	mmap_read_unlock(mm);
}

static const char * const churro_vexemu_names[] = {
	"vpdpbusd", "vpdpbusds", "vpdpwssd", "vpdpwssds",
	"vpmadd52luq", "vpmadd52huq",
	"gf2p8affineqb", "gf2p8affineinvqb", "gf2p8mulb",
	"sha1nexte", "sha1msg1", "sha1msg2",
	"sha256rnds2", "sha256msg1", "sha256msg2", "sha1rnds4",
	"vpclmulqdq",
	"vaesenc", "vaesenclast", "vaesdec", "vaesdeclast",
	"adcx", "adox",
};

static inline s32 churro_sat_s32(s64 v)
{
	if (v > S32_MAX)
		return S32_MAX;
	if (v < S32_MIN)
		return S32_MIN;
	return v;
}

/*
 * vpdpwssd(s): d = acc + S16(a.lo)*S16(b.lo) + S16(a.hi)*S16(b.hi) per dword.
 * vpdpbusd(s): d = acc + Z8(a[k])*S8(b[k]) for the 4 bytes of each dword.
 * The 's' forms saturate the final accumulate (acc + product-sum) to s32.
 */
static void churro_vex_vnni(u32 *d, const u32 *acc, const u32 *a, const u32 *b,
			    int lanes, int op)
{
	int i, k;

	for (i = 0; i < lanes; i++) {
		u32 r = acc[i];

		if (op == CHURRO_VPWSSD || op == CHURRO_VPWSSDS) {
			const s16 *aw = (const s16 *)&a[i], *bw = (const s16 *)&b[i];
			s64 p = (s32)aw[0] * bw[0] + (s64)(s32)aw[1] * bw[1];

			if (op == CHURRO_VPWSSDS)
				r = churro_sat_s32((s64)(s32)r + p);
			else
				r += (u32)p;
		} else {
			const u8 *ab = (const u8 *)&a[i];
			const s8 *bb = (const s8 *)&b[i];
			s64 p = 0;

			for (k = 0; k < 4; k++)
				p += (s32)ab[k] * bb[k];
			if (op == CHURRO_VPBUSDS)
				r = churro_sat_s32((s64)(s32)r + p);
			else
				r += (u32)p;
		}
		d[i] = r;
	}
}

/*
 * Native fast path for vpdpwssd: it is exactly pmaddwd (the wrapping word dot
 * products are the VNNI arithmetic) followed by paddd, and both are AVX2 - the
 * image's own CPU floor, so every machine that boots this image has them. Runs
 * like the AES/CLMUL fast path, between save_fpregs_to_fpstate() and
 * restore_fpregs_from_fpstate() under fpregs_lock(), where xmm0-2 are scratch.
 * The C model stays for vpdpbusd(s) and the saturating forms (no native
 * equivalent: pmaddubsw saturates per word).
 */
#define CHURRO_VPWSSD_MADD(d, acc, a, b)				\
	asm volatile("movdqu %1, %%xmm0\n\t"				\
		     "movdqu %3, %%xmm2\n\t"				\
		     "movdqu %2, %%xmm1\n\t"				\
		     "pmaddwd %%xmm1, %%xmm2\n\t"			\
		     "paddd %%xmm0, %%xmm2\n\t"				\
		     "movdqu %%xmm2, %0"				\
		     : "=m" (*(u8 (*)[16])(d))				\
		     : "m" (*(const u8 (*)[16])(acc)),			\
		       "m" (*(const u8 (*)[16])(a)), "m" (*(const u8 (*)[16])(b)))

static void churro_vex_vnni_exec(u32 *d, const u32 *acc, const u32 *a,
				  const u32 *b, int lanes, int op)
{
	int i;

	/* lanes counts dwords (4 = 128-bit, 8 = 256-bit): one native op per 16-byte chunk */
	if (op == CHURRO_VPWSSD && boot_cpu_has(X86_FEATURE_AVX2)) {
		for (i = 0; i < lanes / 4; i++)
			CHURRO_VPWSSD_MADD((u8 *)d + 16 * i, (const u8 *)acc + 16 * i,
					   (const u8 *)a + 16 * i, (const u8 *)b + 16 * i);
		return;
	}
	churro_vex_vnni(d, acc, a, b, lanes, op);
}

/* vpmadd52l/huq: dst += low/high 52 bits of the 104-bit U52(a) * U52(b) */
static void churro_vex_madd52(u64 *d, const u64 *acc, const u64 *a,
			      const u64 *b, int lanes, bool high)
{
	const u64 m52 = (1ULL << 52) - 1, m26 = (1ULL << 26) - 1;
	int i;

	for (i = 0; i < lanes; i++) {
		u64 x = a[i] & m52, y = b[i] & m52;
		u64 p0 = (x & m26) * (y & m26);				/* < 2^52 */
		u64 p1 = (x & m26) * (y >> 26) + (x >> 26) * (y & m26);	/* < 2^53 */
		u64 p2 = (x >> 26) * (y >> 26);				/* < 2^52 */
		u64 lo = p0 + ((p1 & m26) << 26);			/* < 2^53 */

		d[i] = acc[i] + (high ? p2 + (p1 >> 26) + (lo >> 52) : (lo & m52));
	}
}

/*
 * GFNI, GF(2^8) with reduction poly x^8+x^4+x^3+x+1 (0x11B):
 * gf2p8mulb: bytewise multiplication.
 * gf2p8affine(inv)qb: dst.qword[j].byte[b] = affine_byte(A = SRC2.qword[j],
 * x = SRC1.qword[j].byte[b] [inverted for the 'inv' form], b-vec = imm8)
 * where retbyte.bit[i] = parity(A.byte[7-i] AND x) XOR imm8.bit[i].
 */
static u8 churro_gf_mul(u8 a, u8 b)
{
	u16 w = 0;
	int i;

	for (i = 0; i < 8; i++)
		if (b & (1 << i))
			w ^= (u16)a << i;
	for (i = 14; i >= 8; i--)
		if (w & (1 << i))
			w ^= 0x11b << (i - 8);
	return w & 0xff;
}

/* multiplicative inverse in GF(2^8); 0 maps to 0 (SDM table) */
static u8 churro_gf_inv(u8 x)
{
	u8 r = 1, b = x;
	u8 e = 254;

	if (!x)
		return 0;
	while (e) {
		r = churro_gf_mul(r, b);
		e--;
	}
	return r;
}

static void churro_vex_gfni(u8 *d, const u8 *a, const u8 *b, int len, int op,
			    u8 imm)
{
	int j, k, i;

	if (op == CHURRO_GFMULB) {
		for (j = 0; j < len; j++)
			d[j] = churro_gf_mul(a[j], b[j]);
		return;
	}
	for (j = 0; j < len / 8; j++) {
		u64 A;

		memcpy(&A, b + 8 * j, 8); /* SRC2 = A */
		for (k = 0; k < 8; k++) {
			u8 x = a[8 * j + k]; /* SRC1 */
			u8 r = 0;

			if (op == CHURRO_GFAINVQ)
				x = churro_gf_inv(x);
			for (i = 0; i < 8; i++) {
				u8 row = (A >> (8 * (7 - i))) & 0xff;

				r ^= (__builtin_parity(row & x) ^ ((imm >> i) & 1)) << i;
			}
			d[8 * j + k] = r;
		}
	}
}

/*
 * Native fast path for VAES/VPCLMULQDQ: the 256-bit forms are the 128-bit AES-NI/PCLMULQDQ
 * instruction once per lane, and those run natively on any CPU that has them (Intel since
 * Westmere, AMD since Bulldozer); without them the C code below is used. Only called from
 * handle_vex_ud() between save_fpregs_to_fpstate() and restore_fpregs_from_fpstate() under
 * fpregs_lock(): the task's registers are saved and fully reloaded around it, and no other
 * kernel FPU user can run meanwhile (irq_fpu_usable() is false while softirqs are disabled),
 * so xmm0/xmm1 are scratch. The kernel is built without SSE: the compiler never uses them.
 */
#define CHURRO_XMM_OP2(insn, d, a, b)					\
	asm volatile("movdqu %1, %%xmm0\n\t"				\
		     "movdqu %2, %%xmm1\n\t"				\
		     insn " %%xmm1, %%xmm0\n\t"				\
		     "movdqu %%xmm0, %0"				\
		     : "=m" (*(u8 (*)[16])(d))				\
		     : "m" (*(const u8 (*)[16])(a)), "m" (*(const u8 (*)[16])(b)))

/* vpclmulqdq: per 128-bit lane, imm8[0] picks a's qword, imm8[4] b's; 128-bit carryless product */
static void churro_pclmul_exec(u64 *d, const u64 *a, const u64 *b, int lanes, u8 imm)
{
	int i, j;

	if (boot_cpu_has(X86_FEATURE_PCLMULQDQ)) {
		for (i = 0; i < lanes; i++) {
			u64 x[2] = { a[2 * i + (imm & 1)], 0 };
			u64 y[2] = { b[2 * i + ((imm >> 4) & 1)], 0 };

			CHURRO_XMM_OP2("pclmulqdq $0,", &d[2 * i], x, y);
		}
		return;
	}
	for (i = 0; i < lanes; i++) {
		u64 x = a[2 * i + (imm & 1)];
		u64 y = b[2 * i + ((imm >> 4) & 1)];
		u64 lo = 0, hi = 0;

		for (j = 0; j < 64; j++)
			if ((y >> j) & 1) {
				lo ^= x << j;
				if (j)
					hi ^= x >> (64 - j);
			}
		d[2 * i] = lo;
		d[2 * i + 1] = hi;
	}
}

/*
 * VAES: one AES round per 128-bit lane, state = SRC1 (vvvv), round key = SRC2.
 * Byte r + 4c is row r, column c (FIPS-197 order). enc: ShiftRows, SubBytes,
 * MixColumns, AddRoundKey; dec: the Inv* forms (Intel's equivalent inverse
 * cipher); the 'last' forms skip (Inv)MixColumns. The S-boxes are built at boot
 * from the GF(2^8) inverse + affine map.
 */
static u8 churro_aes_sbox[256] __ro_after_init;
static u8 churro_aes_isbox[256] __ro_after_init;

static int __init churro_aes_init(void)
{
	int x, i;

	for (x = 0; x < 256; x++) {
		u8 b = churro_gf_inv(x), s = b ^ 0x63;

		for (i = 1; i < 5; i++)
			s ^= (u8)(b << i | b >> (8 - i));
		churro_aes_sbox[x] = s;
		churro_aes_isbox[s] = x;
	}
	return 0;
}
core_initcall(churro_aes_init);

/* ponytail: churro_gf_mul per MixColumns byte (only the fallback for CPUs without AES-NI) */
static void churro_vex_aes(u8 *d, const u8 *st, const u8 *key, int lanes, int op)
{
	static const u8 mix[2][4] = { { 2, 3, 1, 1 }, { 14, 11, 13, 9 } };
	bool dec = op == CHURRO_VAESDEC || op == CHURRO_VAESDECLAST;
	bool last = op == CHURRO_VAESENCLAST || op == CHURRO_VAESDECLAST;
	int l, c, r, k;

	if (boot_cpu_has(X86_FEATURE_AES)) {
		for (l = 0; l < lanes; l++, d += 16, st += 16, key += 16)
			switch (op) {
			case CHURRO_VAESENC:
				CHURRO_XMM_OP2("aesenc", d, st, key);
				break;
			case CHURRO_VAESENCLAST:
				CHURRO_XMM_OP2("aesenclast", d, st, key);
				break;
			case CHURRO_VAESDEC:
				CHURRO_XMM_OP2("aesdec", d, st, key);
				break;
			default:
				CHURRO_XMM_OP2("aesdeclast", d, st, key);
				break;
			}
		return;
	}
	for (l = 0; l < lanes; l++, d += 16, st += 16, key += 16) {
		u8 t[16];

		for (c = 0; c < 4; c++)
			for (r = 0; r < 4; r++) {
				u8 v = st[r + 4 * ((dec ? c - r + 4 : c + r) % 4)];

				t[r + 4 * c] = dec ? churro_aes_isbox[v] : churro_aes_sbox[v];
			}
		for (c = 0; c < 4; c++)
			for (r = 0; r < 4; r++) {
				u8 v = t[r + 4 * c];

				if (!last)
					for (v = 0, k = 0; k < 4; k++)
						v ^= churro_gf_mul(mix[dec][(k - r) & 3], t[k + 4 * c]);
				d[r + 4 * c] = v ^ key[r + 4 * c];
			}
	}
}

/* --- SHA-NI (legacy NP encoding) --- */
static u32 churro_ror32(u32 v, int n) { return (v >> n) | (v << (32 - n)); }
static u32 churro_rol32(u32 v, int n) { return (v << n) | (v >> (32 - n)); }
static u32 churro_s_sig0(u32 x) { return churro_ror32(x, 7) ^ churro_ror32(x, 18) ^ (x >> 3); }
static u32 churro_s_sig1(u32 x) { return churro_ror32(x, 17) ^ churro_ror32(x, 19) ^ (x >> 10); }
static u32 churro_s_big0(u32 x) { return churro_ror32(x, 2) ^ churro_ror32(x, 13) ^ churro_ror32(x, 22); }
static u32 churro_s_big1(u32 x) { return churro_ror32(x, 6) ^ churro_ror32(x, 11) ^ churro_ror32(x, 25); }

/*
 * s1 = the destination/source-1 operand content, s2 = the rm operand,
 * wk = xmm0 (used by sha256rnds2 only). All dword lanes per the SDM order.
 */
static void churro_sha_exec(u32 *d, const u32 *s1, const u32 *s2,
			    const u32 *wk, int op, u8 imm)
{
	u32 a, b, c, dd, e, f, g, h, t1, t2, W16, W17, W18, W19;
	u32 fval, kk;
	int i;

	switch (op) {
	case CHURRO_SHA256RNDS2:
		a = s2[3]; b = s2[2]; c = s1[3]; dd = s1[2];
		e = s2[1]; f = s2[0]; g = s1[1]; h = s1[0];
		for (i = 0; i < 2; i++) {
			t1 = h + churro_s_big1(e) + ((e & f) ^ (~e & g)) + wk[i];
			t2 = churro_s_big0(a) + ((a & b) ^ (a & c) ^ (b & c));
			h = g; g = f; f = e; e = t1 + dd;
			dd = c; c = b; b = a; a = t1 + t2;
		}
		d[3] = a; d[2] = b; d[1] = e; d[0] = f;
		return;
	case CHURRO_SHA256MSG1:
		d[3] = s1[3] + churro_s_sig0(s2[0]);
		d[2] = s1[2] + churro_s_sig0(s1[3]);
		d[1] = s1[1] + churro_s_sig0(s1[2]);
		d[0] = s1[0] + churro_s_sig0(s1[1]);
		return;
	case CHURRO_SHA256MSG2:
		W16 = s1[0] + churro_s_sig1(s2[2]);
		W17 = s1[1] + churro_s_sig1(s2[3]);
		W18 = s1[2] + churro_s_sig1(W16);
		W19 = s1[3] + churro_s_sig1(W17);
		d[3] = W19; d[2] = W18; d[1] = W17; d[0] = W16;
		return;
	case CHURRO_SHA1NEXTE:
		d[3] = s2[3] + churro_rol32(s1[3], 30);
		d[2] = s2[2]; d[1] = s2[1]; d[0] = s2[0];
		return;
	case CHURRO_SHA1MSG1:
		d[3] = s1[1] ^ s1[3];
		d[2] = s1[0] ^ s1[2];
		d[1] = s2[3] ^ s1[1];
		d[0] = s2[2] ^ s1[0];
		return;
	case CHURRO_SHA1MSG2:
		W16 = churro_rol32(s1[3] ^ s2[2], 1);
		W17 = churro_rol32(s1[2] ^ s2[1], 1);
		W18 = churro_rol32(s1[1] ^ s2[0], 1);
		W19 = churro_rol32(s1[0] ^ W16, 1);
		d[3] = W16; d[2] = W17; d[1] = W18; d[0] = W19;
		return;
	default: /* SHA1RNDS4: 4 rounds, state A..E, f/K selected by imm&3 */
		switch (imm & 3) {
		case 0: kk = 0x5a827999; break;
		case 1: kk = 0x6ed9eba1; break;
		case 2: kk = 0x8f1bbcdc; break;
		default: kk = 0xca62c1d6; break;
		}
		a = s1[3]; b = s1[2]; c = s1[1]; dd = s1[0]; e = 0;
		for (i = 0; i < 4; i++) {
			switch (imm & 3) {
			case 0:	fval = (b & c) ^ (~b & dd);	break;
			case 1:	fval = b ^ c ^ dd;		break;
			case 2:	fval = (b & c) ^ (b & dd) ^ (c & dd);	break;
			default: fval = b ^ c ^ dd;		break;
			}
			fval += churro_rol32(a, 5) + s2[3 - i] + kk;
			if (i)
				fval += e;
			e = dd; dd = c; c = churro_rol32(b, 30); b = a; a = fval;
		}
		d[3] = a; d[2] = b; d[1] = c; d[0] = dd;
		return;
	}
}

/*
 * A vector register lives in the task's xsave image: the low half in the
 * fxsave XMM area (architecturally fixed offset), the high half in the YMM
 * xfeature (offset from the kernel's xstate map). XSAVES does not write a
 * component that is in INIT state, so its area is stale and reads as zero.
 */
static void churro_vex_read(const struct xregs_state *xs, int n, u32 *v, bool y)
{
	const void *hi;

	if (xs->header.xfeatures & XFEATURE_MASK_SSE)
		memcpy(v, &xs->i387.xmm_space[4 * n], 16);
	else
		memset(v, 0, 16);
	if (!y)
		return;
	hi = xs->header.xfeatures & XFEATURE_MASK_YMM ?
	     get_xsave_addr((struct xregs_state *)xs, XFEATURE_YMM) : NULL;
	if (hi)
		memcpy((u8 *)v + 16, (u8 *)hi + 16 * n, 16);
	else
		memset((u8 *)v + 16, 0, 16);
}

static void churro_vex_write(struct xregs_state *xs, int n, const u32 *v, bool y,
			     bool legacy)
{
	void *hi;

	/*
	 * A write takes the component out of INIT state; its stale area must
	 * be zeroed first, or XRSTOR would load garbage into the other regs.
	 */
	if (!(xs->header.xfeatures & XFEATURE_MASK_SSE)) {
		memset(xs->i387.xmm_space, 0, sizeof(xs->i387.xmm_space));
		xs->header.xfeatures |= XFEATURE_MASK_SSE;
	}
	memcpy(&xs->i387.xmm_space[4 * n], v, 16);
	if (y) {
		if (!(xs->header.xfeatures & XFEATURE_MASK_YMM)) {
			xs->header.xfeatures |= XFEATURE_MASK_YMM;
			memset(get_xsave_addr(xs, XFEATURE_YMM), 0, 16 * 16);
		}
		hi = get_xsave_addr(xs, XFEATURE_YMM);
		memcpy((u8 *)hi + 16 * n, (const u8 *)v + 16, 16);
	} else if (!legacy && (xs->header.xfeatures & XFEATURE_MASK_YMM)) {
		/* a VEX.128 write zeroes the high half; legacy SSE keeps it */
		hi = get_xsave_addr(xs, XFEATURE_YMM);
		memset((u8 *)hi + 16 * n, 0, 16);
	}
}

/* --- run-ahead --- */
/*
 * After an emulated instruction, keep interpreting the straight-line code that follows
 * instead of returning to user space, so a loop costs ~1 trap instead of one per
 * instruction. Two allow-lists: legacy SSE for the SHA-NI loops (BoringSSL's SHA-256:
 * 56 SHA ops per 64-byte block interleaved with movdqa/movdqu/paddd/pshufd/palignr/
 * pshufb/punpck*qdq, lea and nops - the C model on XMM low halves, after the lock) and
 * VEX/AVX2 for the AVX-VNNI loops (the SIMD Adler-32 statically linked in
 * libicing_anywhere.so, codecs, RenderEngine: vmovdqu/vmovdqa loads, vpxor, vpaddd,
 * vpmaddwd, vpsadbw, vpmaddubsw and the four VNNI ops - natively on full YMM copies,
 * inside the lock). In both, anything else (stores, branches, flag-setting ops, other
 * prefixes, a load that would fault or #GP on alignment) ends the run and the CPU
 * executes it natively, so stopping is always correct; none of the allowed
 * instructions touch EFLAGS. churro.vexemu_runahead=0 in bootconfig disables it.
 */
#define CHURRO_RA_MAX	256

enum churro_ra_kind {
	CHURRO_RA_MOV, CHURRO_RA_PADDD, CHURRO_RA_PSHUFD, CHURRO_RA_PALIGNR,
	CHURRO_RA_PSHUFB, CHURRO_RA_PUNPCKLQDQ, CHURRO_RA_PUNPCKHQDQ, CHURRO_RA_SHA,
};

static bool churro_vexemu_runahead = true;
module_param(churro_vexemu_runahead, bool, 0644);
MODULE_PARM_DESC(churro_vexemu_runahead,
	"After an emulated SHA-NI or AVX-VNNI instruction, also interpret the following plain SSE / VEX AVX2 code");

static int __init churro_vexemu_runahead_setup(char *str)
{
	return kstrtobool(str, &churro_vexemu_runahead) == 0;
}
__setup("churro.vexemu_runahead=", churro_vexemu_runahead_setup);

static atomic64_t churro_runahead_count;

/* d = destination (in/out), s = a copy of the source, x0 = xmm0 (sha256rnds2's WK) */
static void churro_ra_exec(u32 *d, const u32 *s, const u32 *x0, int kind, int sha_op,
			   u8 imm)
{
	const u8 *sb = (const u8 *)s;
	u8 *db = (u8 *)d, b[32];
	u32 t[4];
	int i;

	switch (kind) {
	case CHURRO_RA_MOV:
		memcpy(d, s, 16);
		return;
	case CHURRO_RA_PADDD:
		for (i = 0; i < 4; i++)
			d[i] += s[i];
		return;
	case CHURRO_RA_PSHUFD:
		for (i = 0; i < 4; i++)
			t[i] = s[(imm >> (2 * i)) & 3];
		memcpy(d, t, 16);
		return;
	case CHURRO_RA_PALIGNR:	/* (dest:src) >> imm bytes, low 16 */
		memcpy(b, s, 16);
		memcpy(b + 16, d, 16);
		for (i = 0; i < 16; i++)
			db[i] = i + imm < 32 ? b[i + imm] : 0;
		return;
	case CHURRO_RA_PSHUFB:	/* bytes of dest, selected by src */
		memcpy(b, d, 16);
		for (i = 0; i < 16; i++)
			db[i] = sb[i] & 0x80 ? 0 : b[sb[i] & 15];
		return;
	case CHURRO_RA_PUNPCKLQDQ:
		d[2] = s[0];
		d[3] = s[1];
		return;
	case CHURRO_RA_PUNPCKHQDQ:
		d[0] = d[2];
		d[1] = d[3];
		d[2] = s[2];
		d[3] = s[3];
		return;
	default:
		churro_sha_exec(t, d, s, x0, sha_op, imm);
		memcpy(d, t, 16);
		return;
	}
}

/* interpret the allow-listed instruction at r->ip; false = stop here (the CPU runs it) */
static bool churro_ra_step(struct pt_regs *r, u32 (*x)[8], u16 *dirty)
{
	u8 buf[MAX_INSN_SIZE], pfx = 0, imm = 0, rex;
	int len, i, n, kind, sha_op = 0, dst;
	bool aligned = true;
	struct insn insn;
	insn_byte_t p;
	const u8 *ob;
	u32 m[4];

	len = MAX_INSN_SIZE - copy_from_user(buf, (void __user *)r->ip, MAX_INSN_SIZE);
	if (len < 1 || insn_decode(&insn, buf, len, INSN_MODE_64) || insn.vex_prefix.nbytes)
		return false;
	/* legacy prefixes (distinct bytes, as for_each_insn_prefix walks them): one 66 or F3 */
	for (i = 0; i < ARRAY_SIZE(insn.prefixes.bytes) && (p = insn.prefixes.bytes[i]); i++) {
		if ((p != 0x66 && p != 0xf3) || pfx)
			return false;
		pfx = p;
	}
	ob = insn.opcode.bytes;
	n = insn.opcode.nbytes;
	rex = insn.rex_prefix.nbytes ? insn.rex_prefix.bytes[0] : 0;

	/* nop (90) and the multi-byte nop (0F 1F /0) */
	if ((n == 1 && ob[0] == 0x90 && !pfx && !rex) ||
	    (n == 2 && ob[0] == 0x0f && ob[1] == 0x1f)) {
		r->ip += insn.length;
		return true;
	}
	/* lea r64, m */
	if (n == 1 && ob[0] == 0x8d && !pfx && X86_REX_W(rex) &&
	    X86_MODRM_MOD(insn.modrm.value) != 3) {
		void __user *ea = insn_get_addr_ref(&insn, r);
		unsigned long *reg = insn_get_modrm_reg_ptr(&insn, r);

		if (ea == (void __user *)-1L || !reg)
			return false;
		*reg = (unsigned long)ea;
		r->ip += insn.length;
		return true;
	}

	if (!pfx && n == 3 && ob[0] == 0x0f && ob[1] == 0x38 && ob[2] >= 0xc8 && ob[2] <= 0xcd) {
		kind = CHURRO_RA_SHA;
		sha_op = CHURRO_SHA1NEXTE + ob[2] - 0xc8;
	} else if (!pfx && n == 3 && ob[0] == 0x0f && ob[1] == 0x3a && ob[2] == 0xcc) {
		kind = CHURRO_RA_SHA;
		sha_op = CHURRO_SHA1RNDS4;
	} else if (pfx == 0xf3 && n == 2 && ob[0] == 0x0f && ob[1] == 0x6f) {
		kind = CHURRO_RA_MOV;		/* movdqu */
		aligned = false;
	} else if (pfx != 0x66 || ob[0] != 0x0f) {
		return false;
	} else if (n == 2 && ob[1] == 0x6f) {
		kind = CHURRO_RA_MOV;		/* movdqa */
	} else if (n == 2 && ob[1] == 0xfe) {
		kind = CHURRO_RA_PADDD;
	} else if (n == 2 && ob[1] == 0x70) {
		kind = CHURRO_RA_PSHUFD;
	} else if (n == 2 && ob[1] == 0x6c) {
		kind = CHURRO_RA_PUNPCKLQDQ;
	} else if (n == 2 && ob[1] == 0x6d) {
		kind = CHURRO_RA_PUNPCKHQDQ;
	} else if (n == 3 && ob[1] == 0x38 && ob[2] == 0x00) {
		kind = CHURRO_RA_PSHUFB;
	} else if (n == 3 && ob[1] == 0x3a && ob[2] == 0x0f) {
		kind = CHURRO_RA_PALIGNR;
	} else {
		return false;
	}

	if (insn.immediate.nbytes)
		imm = insn.immediate.value & 0xff;
	dst = X86_MODRM_REG(insn.modrm.value) + (X86_REX_R(rex) ? 8 : 0);
	if (X86_MODRM_MOD(insn.modrm.value) == 3) {
		memcpy(m, x[X86_MODRM_RM(insn.modrm.value) + (X86_REX_B(rex) ? 8 : 0)], 16);
	} else {
		void __user *ea = insn_get_addr_ref(&insn, r);

		/* legacy SSE m128 must be 16-byte aligned (but movdqu): let the CPU #GP/#PF */
		if (ea == (void __user *)-1L || (aligned && ((unsigned long)ea & 15)) ||
		    copy_from_user(m, ea, 16))
			return false;
	}
	churro_ra_exec(x[dst], m, x[0], kind, sha_op, imm);
	*dirty |= 1 << dst;
	r->ip += insn.length;
	return true;
}

/*
 * x = the XMM low halves right after the trapping instruction. Interprets from regs->ip on,
 * then writes back the touched XMM registers, the GPRs and the new ip. Returns the count.
 */
static int churro_runahead(struct pt_regs *regs, u32 (*x)[8])
{
	struct fpu *fpu = x86_task_fpu(current);
	struct pt_regs r = *regs;
	struct xregs_state *xs;
	u16 dirty = 0;
	int n = 0, i;

	if (!churro_vexemu_runahead || (regs->flags & X86_EFLAGS_TF))
		return 0;
	while (n < CHURRO_RA_MAX && churro_ra_step(&r, x, &dirty))
		n++;
	if (!n)
		return 0;
	if (dirty) {
		fpregs_lock();
		if (test_thread_flag(TIF_NEED_FPU_LOAD))
			switch_fpu_return();
		save_fpregs_to_fpstate(fpu);
		xs = &fpu->fpstate->regs.xsave;
		for (i = 0; i < 16; i++)
			if (dirty & (1 << i))
				churro_vex_write(xs, i, x[i], false, true);
		restore_fpregs_from_fpstate(fpu->fpstate, XFEATURE_MASK_FPSTATE);
		fpregs_unlock();
	}
	*regs = r;	/* ip, and GPRs a lea changed; nothing else touched them meanwhile */
	atomic64_add(n, &churro_runahead_count);
	return n;
}

/*
 * VEX run-ahead: the same idea as above for the AVX-VNNI loops. Runs inside
 * handle_vex_ud()'s fpregs_lock() window so the allowed instructions can execute
 * natively on the register copies (vpdpwssd as pmaddwd+paddd, the rest as the
 * plain AVX2 op) - which means memory operands and the instruction fetch must not
 * fault: both use non-faulting copies, and a fault simply ends the run and the
 * CPU faults on the real instruction instead. Works on full 32-byte copies;
 * a VEX.128 write zeroes the upper half. Needs AVX2 + SSSE3 (the image's floor).
 */
enum churro_rav_kind {
	CHURRO_RAV_MOV, CHURRO_RAV_PXOR, CHURRO_RAV_PADDD, CHURRO_RAV_PMADDWD,
	CHURRO_RAV_PSADBW, CHURRO_RAV_PMADDUBSW, CHURRO_RAV_VNNI,
};

static bool churro_ra_vex_step(struct pt_regs *r, u32 (*x)[8], u16 *dirty)
{
	u8 buf[MAX_INSN_SIZE], vex1 = 0, vex2;
	u32 a[8], b[8], saved_rex;
	void __user *ea;
	struct insn insn;
	const u8 *ob;
	unsigned long bad;
	bool aligned = false;
	int len, i, map, pp, kind = 0, vop = 0, s1, s2, dst, y;

	pagefault_disable();
	len = MAX_INSN_SIZE - __copy_from_user_inatomic(buf, (void __user *)r->ip,
							MAX_INSN_SIZE);
	pagefault_enable();
	if (len < 1 || insn_decode(&insn, buf, len, INSN_MODE_64) ||
	    insn.prefixes.bytes[0] || insn.immediate.nbytes)
		return false;

	if (!insn.vex_prefix.nbytes) {
		ob = insn.opcode.bytes;
		/* nop (90) and the multi-byte nop (0F 1F /0), lea r64, m: as above */
		if ((insn.opcode.nbytes == 1 && ob[0] == 0x90 &&
		     !insn.rex_prefix.nbytes) ||
		    (insn.opcode.nbytes == 2 && ob[0] == 0x0f && ob[1] == 0x1f)) {
			r->ip += insn.length;
			return true;
		}
		if (insn.opcode.nbytes == 1 && ob[0] == 0x8d &&
		    X86_REX_W(insn.rex_prefix.bytes[0]) &&
		    X86_MODRM_MOD(insn.modrm.value) != 3) {
			unsigned long *reg = insn_get_modrm_reg_ptr(&insn, r);

			ea = insn_get_addr_ref(&insn, r);
			if (ea == (void __user *)-1L || !reg)
				return false;
			*reg = (unsigned long)ea;
			r->ip += insn.length;
			return true;
		}
		return false;
	}
	if (insn.vex_prefix.nbytes == 3) {
		vex1 = insn.vex_prefix.bytes[1];
		vex2 = insn.vex_prefix.bytes[2];
		map = vex1 & 0x1f;
		dst = X86_MODRM_REG(insn.modrm.value) + (!X86_VEX_R(vex1) ? 8 : 0);
		s2 = X86_MODRM_RM(insn.modrm.value) + (!X86_VEX_B(vex1) ? 8 : 0);
	} else if (insn.vex_prefix.nbytes == 2) {
		vex2 = insn.vex_prefix.bytes[1];
		map = 1;
		dst = X86_MODRM_REG(insn.modrm.value) + (!X86_VEX_R(vex2) ? 8 : 0);
		s2 = X86_MODRM_RM(insn.modrm.value);
	} else {
		return false;
	}
	if (insn.opcode.nbytes != 1)
		return false;
	pp = vex2 & 3;
	y = X86_VEX_L(vex2) ? 1 : 0;
	s1 = ~X86_VEX_V(vex2) & 0xf;
	ob = insn.opcode.bytes;

	if (map == 1) {
		/* VEX.pp: 0 = none, 1 = 66, 2 = F3, 3 = F2 */
		if (ob[0] == 0x6f && (pp == 1 || pp == 2)) {
			kind = CHURRO_RAV_MOV;		/* vmovdqa / vmovdqu load */
			aligned = pp == 1;
		} else if (ob[0] == 0xef && pp == 1) {
			kind = CHURRO_RAV_PXOR;
		} else if (ob[0] == 0xfe && pp == 1) {
			kind = CHURRO_RAV_PADDD;
		} else if (ob[0] == 0xf5 && pp == 1) {
			kind = CHURRO_RAV_PMADDWD;	/* 0F F5 */
		} else if (ob[0] == 0xf6 && pp == 1) {
			kind = CHURRO_RAV_PSADBW;	/* 0F F6 */
		} else {
			return false;
		}
	} else if (map == 2) {
		if (pp == 1 && ob[0] >= 0x50 && ob[0] <= 0x53 && !insn_vex_w_bit(&insn)) {
			kind = CHURRO_RAV_VNNI;
			vop = CHURRO_VPBUSD + ob[0] - 0x50;
		} else if (ob[0] == 0x04 && pp == 1) {
			kind = CHURRO_RAV_PMADDUBSW;	/* 0F38 04 */
		} else {
			return false;
		}
	} else {
		return false;
	}

	memcpy(a, x[s1], y ? 32 : 16);		/* vvvv; unused by the MOV form */
	if (X86_MODRM_MOD(insn.modrm.value) == 3) {
		memcpy(b, x[s2], y ? 32 : 16);
	} else {
		/* VEX R/X/B live in the VEX bytes, not rex: see handle_vex_ud() */
		saved_rex = insn.rex_prefix.value;
		insn.rex_prefix.value = (!X86_VEX_R(vex1) ? 4 : 0);
		if (insn.vex_prefix.nbytes == 3)
			insn.rex_prefix.value |= (!X86_VEX_X(vex1) ? 2 : 0) |
						 (!X86_VEX_B(vex1) ? 1 : 0);
		ea = insn_get_addr_ref(&insn, r);
		insn.rex_prefix.value = saved_rex;
		if (ea == (void __user *)-1L ||
		    (aligned && ((unsigned long)ea & (y ? 31 : 15))))
			return false;	/* vmovdqa alignment: the CPU #GPs */
		pagefault_disable();
		bad = __copy_from_user_inatomic(b, ea, y ? 32 : 16);
		pagefault_enable();
		if (bad)
			return false;	/* real hw would fault #PF: end the run */
	}

	if (kind == CHURRO_RAV_MOV) {
		memcpy(x[dst], b, y ? 32 : 16);
	} else {
		/* per 128-bit lane, natively: dst = vvvv op rm (dst is the vvvv read-write) */
		for (i = 0; i <= y; i++) {
			u32 *d = (u32 *)((u8 *)x[dst] + 16 * i);
			const u32 *pa = (const u32 *)((const u8 *)a + 16 * i);
			const u32 *pb = (const u32 *)((const u8 *)b + 16 * i);

			if (kind == CHURRO_RAV_VNNI)
				churro_vex_vnni_exec(d, d, pa, pb, 4, vop);
			else if (kind == CHURRO_RAV_PXOR)
				CHURRO_XMM_OP2("pxor", d, pa, pb);
			else if (kind == CHURRO_RAV_PADDD)
				CHURRO_XMM_OP2("paddd", d, pa, pb);
			else if (kind == CHURRO_RAV_PMADDWD)
				CHURRO_XMM_OP2("pmaddwd", d, pa, pb);
			else if (kind == CHURRO_RAV_PSADBW)
				CHURRO_XMM_OP2("psadbw", d, pa, pb);
			else
				CHURRO_XMM_OP2("pmaddubsw", d, pa, pb);
		}
	}
	if (!y)
		memset((u8 *)x[dst] + 16, 0, 16);	/* a VEX.128 write zeroes bits 255:128 */
	*dirty |= 1 << dst;
	r->ip += insn.length;
	return true;
}

/*
 * x = full YMM copies right after the trapping instruction (regs->ip is already past
 * it). Interprets from regs->ip on and writes the touched registers back into the
 * saved fpstate; called inside handle_vex_ud()'s fpregs_lock() window. Returns the
 * count of interpreted instructions (0 = nothing done).
 */
static int churro_runahead_vex(struct pt_regs *regs, struct xregs_state *xs, u32 (*x)[8])
{
	u16 dirty = 0;
	int n = 0, i;

	if (!churro_vexemu_runahead || (regs->flags & X86_EFLAGS_TF) ||
	    !boot_cpu_has(X86_FEATURE_AVX2) || !boot_cpu_has(X86_FEATURE_SSSE3))
		return 0;
	while (n < CHURRO_RA_MAX && churro_ra_vex_step(regs, x, &dirty))
		n++;
	for (i = 0; i < 16; i++)
		if (dirty & (1 << i))
			churro_vex_write(xs, i, x[i], true, false);
	if (n)
		atomic64_add(n, &churro_runahead_count);
	return n;
}
/* --- end run-ahead --- */

/* --- ADX --- */
/*
 * adcx/adox (Broadwell+; Haswell lacks them): 66 [REX] 0F 38 F6 /r = adcx, F3 ... = adox.
 * dest += src + carry-in, with the carry taken from and written back to CF (adcx) or OF
 * (adox) only: no other flag changes. REX.W selects 64-bit, else 32-bit with the result
 * zero-extended into the 64-bit register. Without a prefix the same bytes are WRSS (CET),
 * which is not ours. Integer-only, so this runs before (and without) the xsave/xrstor path.
 */
static void churro_adx_exec(unsigned long *dst, unsigned long src, unsigned long *flags,
			    bool adox, bool w)
{
	unsigned long flag = adox ? X86_EFLAGS_OF : X86_EFLAGS_CF, t, res;
	bool cin = *flags & flag, c1, c2;

	if (w) {
		c1 = __builtin_add_overflow(*dst, src, &t);
		c2 = __builtin_add_overflow(t, (unsigned long)cin, &res);
	} else {
		u64 s = (u64)(u32)*dst + (u32)src + cin;

		res = (u32)s;
		c1 = s >> 32;
		c2 = false;
	}
	*dst = res;
	*flags = (*flags & ~flag) | (c1 || c2 ? flag : 0);
}

/* returns true when the #UD was an adcx/adox (emulated) */
static bool handle_adx_ud(struct pt_regs *regs)
{
	u8 buf[MAX_INSN_SIZE], pfx = 0, rex;
	unsigned long *dst, src = 0;
	struct insn insn;
	insn_byte_t p;
	int len, i, op, off;
	void __user *ea;

	if (!churro_vexemu)
		return false;
	len = MAX_INSN_SIZE - copy_from_user(buf, (void __user *)regs->ip, MAX_INSN_SIZE);
	/* every accepted encoding starts with its 66/F3 prefix: skip the decode for the
	 * VEX (C4/C5) and SHA-NI (0F/REX) traps that reach handle_vex_ud() next */
	if (len < 5 || (buf[0] != 0x66 && buf[0] != 0xf3) ||
	    insn_decode(&insn, buf, len, INSN_MODE_64) || insn.vex_prefix.nbytes ||
	    insn.opcode.nbytes != 3 || insn.opcode.bytes[0] != 0x0f ||
	    insn.opcode.bytes[1] != 0x38 || insn.opcode.bytes[2] != 0xf6)
		return false;
	for (i = 0; i < ARRAY_SIZE(insn.prefixes.bytes) && (p = insn.prefixes.bytes[i]); i++) {
		if ((p != 0x66 && p != 0xf3) || pfx)
			return false;
		pfx = p;
	}
	if (!pfx)
		return false;
	op = pfx == 0x66 ? CHURRO_ADCX : CHURRO_ADOX;
	rex = insn.rex_prefix.nbytes ? insn.rex_prefix.bytes[0] : 0;

	dst = insn_get_modrm_reg_ptr(&insn, regs);
	if (!dst)
		return false;
	if (X86_MODRM_MOD(insn.modrm.value) == 3) {
		off = insn_get_modrm_rm_off(&insn, regs);
		if (off < 0)
			return false;
		src = *(unsigned long *)((u8 *)regs + off);
	} else {
		ea = insn_get_addr_ref(&insn, regs);
		if (ea == (void __user *)-1L ||
		    copy_from_user(&src, ea, X86_REX_W(rex) ? 8 : 4))
			return false;	/* real hw would fault #PF, not #UD */
	}
	churro_adx_exec(dst, src, &regs->flags, op == CHURRO_ADOX, X86_REX_W(rex));

	regs->ip += insn.length;
	atomic64_inc(&churro_vexemu_count[op]);
	if (__ratelimit(&churro_vexemu_rs)) {
		char where[96];

		churro_where(regs->ip - insn.length, where, sizeof(where));
		pr_info("churro-vexemu: %s in %s[%d]%s, trap #%lld\n",
			churro_vexemu_names[op], current->comm, task_pid_nr(current), where,
			atomic64_read(&churro_vexemu_count[op]));
	}
	return true;
}
/* --- end ADX --- */

/* returns true when the #UD was one of the emulated instructions (see top) */
static bool handle_vex_ud(struct pt_regs *regs)
{
	u8 buf[MAX_INSN_SIZE];
	u32 va[8], vb[8], vd[8], vacc[8], ra[16][8];
	unsigned long tip;
	struct insn insn;
	struct fpu *fpu = x86_task_fpu(current);
	struct xregs_state *xs;
	bool legacy = false, vex_run = false;
	u32 saved_rex;
	void __user *ea;
	u8 vex1, vex2, imm = 0;
	int len, op, y, s1, s2, dst, map, i, ran = 0;

	if (!churro_vexemu)
		return false;

	/* no YMM xfeature area to edit on AVX-less machines */
	if (!boot_cpu_has(X86_FEATURE_AVX))
		return false;

	len = MAX_INSN_SIZE - copy_from_user(buf, (void __user *)regs->ip,
					     MAX_INSN_SIZE);
	if (len < 4 || insn_decode(&insn, buf, len, INSN_MODE_64))	/* sha1nexte xmm,xmm is 4 bytes */
		return false;
	tip = regs->ip;		/* the trapping instruction (run-ahead moves ip on) */

	/* VEX: only 3-byte VEX (0xC4), 66 prefix, map 0F38 or 0F3A */
	if (insn.vex_prefix.nbytes == 3) {
		map = insn_vex_m_bits(&insn);
		if (insn_vex_p_bits(&insn) != 1 || (map != 2 && map != 3))
			return false;
		if (map == 2) {
			switch (insn.opcode.bytes[0]) {
			case 0x50:	op = CHURRO_VPBUSD;	break;
			case 0x51:	op = CHURRO_VPBUSDS;	break;
			case 0x52:	op = CHURRO_VPWSSD;	break;
			case 0x53:	op = CHURRO_VPWSSDS;	break;
			case 0xb4:	op = CHURRO_VPM52LQ;	break;
			case 0xb5:	op = CHURRO_VPM52HQ;	break;
			case 0xcf:	op = CHURRO_GFMULB;	break; /* VEX.66.0F38.W0 */
			case 0xdc:	op = CHURRO_VAESENC;	break; /* VEX.66.0F38.WIG */
			case 0xdd:	op = CHURRO_VAESENCLAST; break;
			case 0xde:	op = CHURRO_VAESDEC;	break;
			case 0xdf:	op = CHURRO_VAESDECLAST; break;
			default:	return false;
			}
			/* IFMA has VEX.W=1, VNNI and GF2P8MULB have VEX.W=0, VAES ignores W */
			if (op < CHURRO_VAESENC &&
			    (op == CHURRO_VPM52LQ || op == CHURRO_VPM52HQ) !=
			    !!insn_vex_w_bit(&insn))
				return false;
		} else {
			/* map 0F3A: GF2P8AFFINEQB = 0xCE, GF2P8AFFINEINVQB = 0xCF
			 * (both VEX.W=1, imm8); VPCLMULQDQ = 0x44 (VEX.W=0, imm8) */
			switch (insn.opcode.bytes[0]) {
			case 0x44:
				if (insn_vex_w_bit(&insn))
					return false;
				op = CHURRO_PCLMULQDQ;
				break;
			case 0xce:
				if (!insn_vex_w_bit(&insn))
					return false;
				op = CHURRO_GFAFQ;
				break;
			case 0xcf:
				if (!insn_vex_w_bit(&insn))
					return false;
				op = CHURRO_GFAINVQ;
				break;
			default:	return false;
			}
			imm = insn.immediate.value & 0xff;
		}
		vex1 = insn.vex_prefix.bytes[1];	/* ~R ~X ~B mmmmm */
		vex2 = insn.vex_prefix.bytes[2];	/* W ~vvvv L pp */
		y = X86_VEX_L(vex2) ? 1 : 0;
		s1 = ~X86_VEX_V(vex2) & 0xf;
		dst = X86_MODRM_REG(insn.modrm.value) + (!X86_VEX_R(vex1) ? 8 : 0);
		s2 = X86_MODRM_RM(insn.modrm.value) + (!X86_VEX_B(vex1) ? 8 : 0);
	} else {
		/*
		 * SHA-NI, legacy NP encodings: [REX] 0F 38 C8..CD /r and
		 * [REX] 0F 3A CC /r ib (sha1rnds4). REX.R/REX.B select
		 * xmm8-15 (BoringSSL and liblzma use them); any other prefix
		 * byte makes it a different instruction -> plain SIGILL.
		 */
		const u8 *p = buf;
		u8 rex = 0;

		if ((p[0] & 0xf0) == 0x40)
			rex = *p++;
		if (p[0] != 0x0f)
			return false;
		if (p[1] == 0x38 && p[2] >= 0xc8 && p[2] <= 0xcd) {
			op = CHURRO_SHA1NEXTE + p[2] - 0xc8;
		} else if (p[1] == 0x3a && p[2] == 0xcc) {
			op = CHURRO_SHA1RNDS4;
			imm = insn.immediate.value & 0xff;
		} else {
			return false;
		}
		y = 0;
		legacy = true;
		dst = X86_MODRM_REG(insn.modrm.value) + (X86_REX_R(rex) ? 8 : 0);
		s2 = X86_MODRM_RM(insn.modrm.value) + (X86_REX_B(rex) ? 8 : 0);
		s1 = 0;		/* sha256rnds2's implicit third operand is xmm0 */
	}

	if (X86_MODRM_MOD(insn.modrm.value) != 3) {
		/*
		 * insn_get_addr_ref() computes ModRM/SIB/disp addresses (incl.
		 * RIP-relative) but takes extension bits from rex_prefix, which
		 * the decoder does not synthesize from VEX R/X/B - do it here.
		 */
		saved_rex = insn.rex_prefix.value;
		if (insn.vex_prefix.nbytes == 3)
			insn.rex_prefix.value = (!X86_VEX_R(vex1) ? 4 : 0) |
						(!X86_VEX_X(vex1) ? 2 : 0) |
						(!X86_VEX_B(vex1) ? 1 : 0);
		ea = insn_get_addr_ref(&insn, regs);
		insn.rex_prefix.value = saved_rex;
		if (ea == (void __user *)-1L)
			return false;
		if (copy_from_user(vb, ea, y ? 32 : 16))
			return false; /* real hw would fault #PF, not #UD */
	}

	fpregs_lock();
	/*
	 * Make the registers live first. If we were preempted above, the flag
	 * is set but the CPU may still hold our state; fpregs_state_valid()
	 * would then skip the XRSTOR on return to user and drop our edit.
	 */
	if (test_thread_flag(TIF_NEED_FPU_LOAD))
		switch_fpu_return();
	save_fpregs_to_fpstate(fpu);

	xs = &fpu->fpstate->regs.xsave;
	churro_vex_read(xs, s1, va, y);
	churro_vex_read(xs, dst, vacc, y);
	if (X86_MODRM_MOD(insn.modrm.value) == 3)
		churro_vex_read(xs, s2, vb, y);

	if (op >= CHURRO_VAESENC)
		churro_vex_aes((u8 *)vd, (u8 *)va, (u8 *)vb, y ? 2 : 1, op);
	else if (op == CHURRO_PCLMULQDQ)
		churro_pclmul_exec((u64 *)vd, (const u64 *)va, (const u64 *)vb,
				   y ? 2 : 1, imm);
	else if (op >= CHURRO_SHA1NEXTE)
		churro_sha_exec(vd, vacc, vb, va, op, imm);
	else if (op >= CHURRO_GFAFQ)
		churro_vex_gfni((u8 *)vd, (u8 *)va, (u8 *)vb, y ? 32 : 16, op,
				imm);
	else if (op >= CHURRO_VPM52LQ)
		churro_vex_madd52((u64 *)vd, (u64 *)vacc, (u64 *)va, (u64 *)vb,
				  y ? 4 : 2, op == CHURRO_VPM52HQ);
	else
		churro_vex_vnni_exec(vd, vacc, va, vb, y ? 8 : 4, op);
	churro_vex_write(xs, dst, vd, y, legacy);
	if (legacy) {
		/* run-ahead input: the XMM low halves as they are now */
		for (i = 0; i < 16; i++)
			churro_vex_read(xs, i, ra[i], false);
	} else if (op <= CHURRO_VPWSSDS) {
		/* VEX run-ahead input: the registers as they are now (full YMM). Runs
		 * inside the lock: the interpreter executes AVX2 natively on the copies.
		 */
		for (i = 0; i < 16; i++)
			churro_vex_read(xs, i, ra[i], true);
		regs->ip += insn.length;
		ran = churro_runahead_vex(regs, xs, ra);
		vex_run = true;
	}

	restore_fpregs_from_fpstate(fpu->fpstate, XFEATURE_MASK_FPSTATE);
	fpregs_unlock();

	if (!vex_run)	/* the VEX run moved ip past the trapping instruction already */
		regs->ip += insn.length;
	if (legacy)
		ran = churro_runahead(regs, ra);
	atomic64_inc(&churro_vexemu_count[op]);
	if (__ratelimit(&churro_vexemu_rs)) {
		char where[96];

		churro_where(tip, where, sizeof(where));
		pr_info("churro-vexemu: %s in %s[%d]%s, trap #%lld (+%d run-ahead, %lld total)\n",
			churro_vexemu_names[op], current->comm, task_pid_nr(current), where,
			atomic64_read(&churro_vexemu_count[op]), ran,
			atomic64_read(&churro_runahead_count));
	}
	return true;
}

#ifdef CONFIG_X86_F00F_BUG
void handle_invalid_op(struct pt_regs *regs)
#else
static inline void handle_invalid_op(struct pt_regs *regs)
#endif
{
	if (user_mode(regs)) {
		cond_local_irq_enable(regs);
		if (handle_adx_ud(regs) || handle_vex_ud(regs)) {
			cond_local_irq_disable(regs);
			return;
		}
		cond_local_irq_disable(regs);
	}
	do_error_trap(regs, 0, "invalid opcode", X86_TRAP_UD, SIGILL,
		      ILL_ILLOPN, error_get_trap_addr(regs));
}

static noinstr bool handle_bug(struct pt_regs *regs)
{
	unsigned long addr = regs->ip;
	bool handled = false;
	int ud_type, ud_len;
	s32 ud_imm;

	ud_type = decode_bug(addr, &ud_imm, &ud_len);
	if (ud_type == BUG_NONE)
		return handled;

	/*
	 * All lies, just get the WARN/BUG out.
	 */
	instrumentation_begin();
	/*
	 * Normally @regs are unpoisoned by irqentry_enter(), but handle_bug()
	 * is a rare case that uses @regs without passing them to
	 * irqentry_enter().
	 */
	kmsan_unpoison_entry_regs(regs);
	/*
	 * Since we're emulating a CALL with exceptions, restore the interrupt
	 * state to what it was at the exception site.
	 */
	if (regs->flags & X86_EFLAGS_IF)
		raw_local_irq_enable();

	switch (ud_type) {
	case BUG_UD2:
		if (report_bug(regs->ip, regs) == BUG_TRAP_TYPE_WARN) {
			handled = true;
			break;
		}
		fallthrough;

	case BUG_UDB:
	case BUG_LOCK:
		if (handle_cfi_failure(regs) == BUG_TRAP_TYPE_WARN) {
			handled = true;
			break;
		}
		break;

	case BUG_UD1_UBSAN:
		if (IS_ENABLED(CONFIG_UBSAN_TRAP)) {
			pr_crit("%s at %pS\n",
				report_ubsan_failure(ud_imm),
				(void *)regs->ip);
		}
		break;

	default:
		break;
	}

	/*
	 * When continuing, and regs->ip hasn't changed, move it to the next
	 * instruction. When not continuing execution, restore the instruction
	 * pointer.
	 */
	if (handled) {
		if (regs->ip == addr)
			regs->ip += ud_len;
	} else {
		regs->ip = addr;
	}

	if (regs->flags & X86_EFLAGS_IF)
		raw_local_irq_disable();
	instrumentation_end();

	return handled;
}

DEFINE_IDTENTRY_RAW(exc_invalid_op)
{
	irqentry_state_t state;

	/*
	 * We use UD2 as a short encoding for 'CALL __WARN', as such
	 * handle it before exception entry to avoid recursive WARN
	 * in case exception entry is the one triggering WARNs.
	 */
	if (!user_mode(regs) && handle_bug(regs))
		return;

	state = irqentry_enter(regs);
	instrumentation_begin();
	handle_invalid_op(regs);
	instrumentation_end();
	irqentry_exit(regs, state);
}

DEFINE_IDTENTRY(exc_coproc_segment_overrun)
{
	do_error_trap(regs, 0, "coprocessor segment overrun",
		      X86_TRAP_OLD_MF, SIGFPE, 0, NULL);
}

DEFINE_IDTENTRY_ERRORCODE(exc_invalid_tss)
{
	do_error_trap(regs, error_code, "invalid TSS", X86_TRAP_TS, SIGSEGV,
		      0, NULL);
}

DEFINE_IDTENTRY_ERRORCODE(exc_segment_not_present)
{
	do_error_trap(regs, error_code, "segment not present", X86_TRAP_NP,
		      SIGBUS, 0, NULL);
}

DEFINE_IDTENTRY_ERRORCODE(exc_stack_segment)
{
	do_error_trap(regs, error_code, "stack segment", X86_TRAP_SS, SIGBUS,
		      0, NULL);
}

DEFINE_IDTENTRY_ERRORCODE(exc_alignment_check)
{
	char *str = "alignment check";

	if (notify_die(DIE_TRAP, str, regs, error_code, X86_TRAP_AC, SIGBUS) == NOTIFY_STOP)
		return;

	if (!user_mode(regs))
		die("Split lock detected\n", regs, error_code);

	local_irq_enable();

	if (handle_user_split_lock(regs, error_code))
		goto out;

	do_trap(X86_TRAP_AC, SIGBUS, "alignment check", regs,
		error_code, BUS_ADRALN, NULL);

out:
	local_irq_disable();
}

#ifdef CONFIG_VMAP_STACK
__visible void __noreturn handle_stack_overflow(struct pt_regs *regs,
						unsigned long fault_address,
						struct stack_info *info)
{
	const char *name = stack_type_name(info->type);

	printk(KERN_EMERG "BUG: %s stack guard page was hit at %p (stack is %p..%p)\n",
	       name, (void *)fault_address, info->begin, info->end);

	die("stack guard page", regs, 0);

	/* Be absolutely certain we don't return. */
	panic("%s stack guard hit", name);
}
#endif

/*
 * Prevent the compiler and/or objtool from marking the !CONFIG_X86_ESPFIX64
 * version of exc_double_fault() as noreturn.  Otherwise the noreturn mismatch
 * between configs triggers objtool warnings.
 *
 * This is a temporary hack until we have compiler or plugin support for
 * annotating noreturns.
 */
#ifdef CONFIG_X86_ESPFIX64
#define always_true() true
#else
bool always_true(void);
bool __weak always_true(void) { return true; }
#endif

/*
 * Runs on an IST stack for x86_64 and on a special task stack for x86_32.
 *
 * On x86_64, this is more or less a normal kernel entry.  Notwithstanding the
 * SDM's warnings about double faults being unrecoverable, returning works as
 * expected.  Presumably what the SDM actually means is that the CPU may get
 * the register state wrong on entry, so returning could be a bad idea.
 *
 * Various CPU engineers have promised that double faults due to an IRET fault
 * while the stack is read-only are, in fact, recoverable.
 *
 * On x86_32, this is entered through a task gate, and regs are synthesized
 * from the TSS.  Returning is, in principle, okay, but changes to regs will
 * be lost.  If, for some reason, we need to return to a context with modified
 * regs, the shim code could be adjusted to synchronize the registers.
 *
 * The 32bit #DF shim provides CR2 already as an argument. On 64bit it needs
 * to be read before doing anything else.
 */
DEFINE_IDTENTRY_DF(exc_double_fault)
{
	static const char str[] = "double fault";
	struct task_struct *tsk = current;

#ifdef CONFIG_VMAP_STACK
	unsigned long address = read_cr2();
	struct stack_info info;
#endif

#ifdef CONFIG_X86_ESPFIX64
	extern unsigned char native_irq_return_iret[];

	/*
	 * If IRET takes a non-IST fault on the espfix64 stack, then we
	 * end up promoting it to a doublefault.  In that case, take
	 * advantage of the fact that we're not using the normal (TSS.sp0)
	 * stack right now.  We can write a fake #GP(0) frame at TSS.sp0
	 * and then modify our own IRET frame so that, when we return,
	 * we land directly at the #GP(0) vector with the stack already
	 * set up according to its expectations.
	 *
	 * The net result is that our #GP handler will think that we
	 * entered from usermode with the bad user context.
	 *
	 * No need for nmi_enter() here because we don't use RCU.
	 */
	if (((long)regs->sp >> P4D_SHIFT) == ESPFIX_PGD_ENTRY &&
		regs->cs == __KERNEL_CS &&
		regs->ip == (unsigned long)native_irq_return_iret)
	{
		struct pt_regs *gpregs = (struct pt_regs *)this_cpu_read(cpu_tss_rw.x86_tss.sp0) - 1;
		unsigned long *p = (unsigned long *)regs->sp;

		/*
		 * regs->sp points to the failing IRET frame on the
		 * ESPFIX64 stack.  Copy it to the entry stack.  This fills
		 * in gpregs->ss through gpregs->ip.
		 *
		 */
		gpregs->ip	= p[0];
		gpregs->cs	= p[1];
		gpregs->flags	= p[2];
		gpregs->sp	= p[3];
		gpregs->ss	= p[4];
		gpregs->orig_ax = 0;  /* Missing (lost) #GP error code */

		/*
		 * Adjust our frame so that we return straight to the #GP
		 * vector with the expected RSP value.  This is safe because
		 * we won't enable interrupts or schedule before we invoke
		 * general_protection, so nothing will clobber the stack
		 * frame we just set up.
		 *
		 * We will enter general_protection with kernel GSBASE,
		 * which is what the stub expects, given that the faulting
		 * RIP will be the IRET instruction.
		 */
		regs->ip = (unsigned long)asm_exc_general_protection;
		regs->sp = (unsigned long)&gpregs->orig_ax;

		return;
	}
#endif

	irqentry_nmi_enter(regs);
	instrumentation_begin();
	notify_die(DIE_TRAP, str, regs, error_code, X86_TRAP_DF, SIGSEGV);

	tsk->thread.error_code = error_code;
	tsk->thread.trap_nr = X86_TRAP_DF;

#ifdef CONFIG_VMAP_STACK
	/*
	 * If we overflow the stack into a guard page, the CPU will fail
	 * to deliver #PF and will send #DF instead.  Similarly, if we
	 * take any non-IST exception while too close to the bottom of
	 * the stack, the processor will get a page fault while
	 * delivering the exception and will generate a double fault.
	 *
	 * According to the SDM (footnote in 6.15 under "Interrupt 14 -
	 * Page-Fault Exception (#PF):
	 *
	 *   Processors update CR2 whenever a page fault is detected. If a
	 *   second page fault occurs while an earlier page fault is being
	 *   delivered, the faulting linear address of the second fault will
	 *   overwrite the contents of CR2 (replacing the previous
	 *   address). These updates to CR2 occur even if the page fault
	 *   results in a double fault or occurs during the delivery of a
	 *   double fault.
	 *
	 * The logic below has a small possibility of incorrectly diagnosing
	 * some errors as stack overflows.  For example, if the IDT or GDT
	 * gets corrupted such that #GP delivery fails due to a bad descriptor
	 * causing #GP and we hit this condition while CR2 coincidentally
	 * points to the stack guard page, we'll think we overflowed the
	 * stack.  Given that we're going to panic one way or another
	 * if this happens, this isn't necessarily worth fixing.
	 *
	 * If necessary, we could improve the test by only diagnosing
	 * a stack overflow if the saved RSP points within 47 bytes of
	 * the bottom of the stack: if RSP == tsk_stack + 48 and we
	 * take an exception, the stack is already aligned and there
	 * will be enough room SS, RSP, RFLAGS, CS, RIP, and a
	 * possible error code, so a stack overflow would *not* double
	 * fault.  With any less space left, exception delivery could
	 * fail, and, as a practical matter, we've overflowed the
	 * stack even if the actual trigger for the double fault was
	 * something else.
	 */
	if (get_stack_guard_info((void *)address, &info))
		handle_stack_overflow(regs, address, &info);
#endif

	pr_emerg("PANIC: double fault, error_code: 0x%lx\n", error_code);
	die("double fault", regs, error_code);
	if (always_true())
		panic("Machine halted.");
	instrumentation_end();
}

DEFINE_IDTENTRY(exc_bounds)
{
	if (notify_die(DIE_TRAP, "bounds", regs, 0,
			X86_TRAP_BR, SIGSEGV) == NOTIFY_STOP)
		return;
	cond_local_irq_enable(regs);

	if (!user_mode(regs))
		die("bounds", regs, 0);

	do_trap(X86_TRAP_BR, SIGSEGV, "bounds", regs, 0, 0, NULL);

	cond_local_irq_disable(regs);
}

enum kernel_gp_hint {
	GP_NO_HINT,
	GP_NON_CANONICAL,
	GP_CANONICAL
};

/*
 * When an uncaught #GP occurs, try to determine the memory address accessed by
 * the instruction and return that address to the caller. Also, try to figure
 * out whether any part of the access to that address was non-canonical.
 */
static enum kernel_gp_hint get_kernel_gp_address(struct pt_regs *regs,
						 unsigned long *addr)
{
	u8 insn_buf[MAX_INSN_SIZE];
	struct insn insn;
	int ret;

	if (copy_from_kernel_nofault(insn_buf, (void *)regs->ip,
			MAX_INSN_SIZE))
		return GP_NO_HINT;

	ret = insn_decode_kernel(&insn, insn_buf);
	if (ret < 0)
		return GP_NO_HINT;

	*addr = (unsigned long)insn_get_addr_ref(&insn, regs);
	if (*addr == -1UL)
		return GP_NO_HINT;

#ifdef CONFIG_X86_64
	/*
	 * Check that:
	 *  - the operand is not in the kernel half
	 *  - the last byte of the operand is not in the user canonical half
	 */
	if (*addr < ~__VIRTUAL_MASK &&
	    *addr + insn.opnd_bytes - 1 > __VIRTUAL_MASK)
		return GP_NON_CANONICAL;
#endif

	return GP_CANONICAL;
}

#define GPFSTR "general protection fault"

static bool fixup_iopl_exception(struct pt_regs *regs)
{
	struct thread_struct *t = &current->thread;
	unsigned char byte;
	unsigned long ip;

	if (!IS_ENABLED(CONFIG_X86_IOPL_IOPERM) || t->iopl_emul != 3)
		return false;

	if (insn_get_effective_ip(regs, &ip))
		return false;

	if (get_user(byte, (const char __user *)ip))
		return false;

	if (byte != 0xfa && byte != 0xfb)
		return false;

	if (!t->iopl_warn && printk_ratelimit()) {
		pr_err("%s[%d] attempts to use CLI/STI, pretending it's a NOP, ip:%lx",
		       current->comm, task_pid_nr(current), ip);
		print_vma_addr(KERN_CONT " in ", ip);
		pr_cont("\n");
		t->iopl_warn = 1;
	}

	regs->ip += 1;
	return true;
}

/*
 * The unprivileged ENQCMD instruction generates #GPs if the
 * IA32_PASID MSR has not been populated.  If possible, populate
 * the MSR from a PASID previously allocated to the mm.
 */
static bool try_fixup_enqcmd_gp(void)
{
#ifdef CONFIG_ARCH_HAS_CPU_PASID
	u32 pasid;

	/*
	 * MSR_IA32_PASID is managed using XSAVE.  Directly
	 * writing to the MSR is only possible when fpregs
	 * are valid and the fpstate is not.  This is
	 * guaranteed when handling a userspace exception
	 * in *before* interrupts are re-enabled.
	 */
	lockdep_assert_irqs_disabled();

	/*
	 * Hardware without ENQCMD will not generate
	 * #GPs that can be fixed up here.
	 */
	if (!cpu_feature_enabled(X86_FEATURE_ENQCMD))
		return false;

	/*
	 * If the mm has not been allocated a
	 * PASID, the #GP can not be fixed up.
	 */
	if (!mm_valid_pasid(current->mm))
		return false;

	pasid = mm_get_enqcmd_pasid(current->mm);

	/*
	 * Did this thread already have its PASID activated?
	 * If so, the #GP must be from something else.
	 */
	if (current->pasid_activated)
		return false;

	wrmsrq(MSR_IA32_PASID, pasid | MSR_IA32_PASID_VALID);
	current->pasid_activated = 1;

	return true;
#else
	return false;
#endif
}

static bool gp_try_fixup_and_notify(struct pt_regs *regs, int trapnr,
				    unsigned long error_code, const char *str,
				    unsigned long address)
{
	if (fixup_exception(regs, trapnr, error_code, address))
		return true;

	current->thread.error_code = error_code;
	current->thread.trap_nr = trapnr;

	/*
	 * To be potentially processing a kprobe fault and to trust the result
	 * from kprobe_running(), we have to be non-preemptible.
	 */
	if (!preemptible() && kprobe_running() &&
	    kprobe_fault_handler(regs, trapnr))
		return true;

	return notify_die(DIE_GPF, str, regs, error_code, trapnr, SIGSEGV) == NOTIFY_STOP;
}

static void gp_user_force_sig_segv(struct pt_regs *regs, int trapnr,
				   unsigned long error_code, const char *str)
{
	current->thread.error_code = error_code;
	current->thread.trap_nr = trapnr;
	show_signal(current, SIGSEGV, "", str, regs, error_code);
	force_sig(SIGSEGV);
}

DEFINE_IDTENTRY_ERRORCODE(exc_general_protection)
{
	char desc[sizeof(GPFSTR) + 50 + 2*sizeof(unsigned long) + 1] = GPFSTR;
	enum kernel_gp_hint hint = GP_NO_HINT;
	unsigned long gp_addr;

	if (user_mode(regs) && try_fixup_enqcmd_gp())
		return;

	cond_local_irq_enable(regs);

	if (static_cpu_has(X86_FEATURE_UMIP)) {
		if (user_mode(regs) && fixup_umip_exception(regs))
			goto exit;
	}

	if (v8086_mode(regs)) {
		local_irq_enable();
		handle_vm86_fault((struct kernel_vm86_regs *) regs, error_code);
		local_irq_disable();
		return;
	}

	if (user_mode(regs)) {
		if (fixup_iopl_exception(regs))
			goto exit;

		if (fixup_vdso_exception(regs, X86_TRAP_GP, error_code, 0))
			goto exit;

		gp_user_force_sig_segv(regs, X86_TRAP_GP, error_code, desc);
		goto exit;
	}

	if (gp_try_fixup_and_notify(regs, X86_TRAP_GP, error_code, desc, 0))
		goto exit;

	if (error_code)
		snprintf(desc, sizeof(desc), "segment-related " GPFSTR);
	else
		hint = get_kernel_gp_address(regs, &gp_addr);

	if (hint != GP_NO_HINT)
		snprintf(desc, sizeof(desc), GPFSTR ", %s 0x%lx",
			 (hint == GP_NON_CANONICAL) ? "probably for non-canonical address"
						    : "maybe for address",
			 gp_addr);

	/*
	 * KASAN is interested only in the non-canonical case, clear it
	 * otherwise.
	 */
	if (hint != GP_NON_CANONICAL)
		gp_addr = 0;

	die_addr(desc, regs, error_code, gp_addr);

exit:
	cond_local_irq_disable(regs);
}

static bool do_int3(struct pt_regs *regs)
{
	int res;

#ifdef CONFIG_KGDB_LOW_LEVEL_TRAP
	if (kgdb_ll_trap(DIE_INT3, "int3", regs, 0, X86_TRAP_BP,
			 SIGTRAP) == NOTIFY_STOP)
		return true;
#endif /* CONFIG_KGDB_LOW_LEVEL_TRAP */

#ifdef CONFIG_KPROBES
	if (kprobe_int3_handler(regs))
		return true;
#endif
	res = notify_die(DIE_INT3, "int3", regs, 0, X86_TRAP_BP, SIGTRAP);

	return res == NOTIFY_STOP;
}
NOKPROBE_SYMBOL(do_int3);

static void do_int3_user(struct pt_regs *regs)
{
	if (do_int3(regs))
		return;

	cond_local_irq_enable(regs);
	do_trap(X86_TRAP_BP, SIGTRAP, "int3", regs, 0, 0, NULL);
	cond_local_irq_disable(regs);
}

DEFINE_IDTENTRY_RAW(exc_int3)
{
	/*
	 * smp_text_poke_int3_handler() is completely self contained code; it does (and
	 * must) *NOT* call out to anything, lest it hits upon yet another
	 * INT3.
	 */
	if (smp_text_poke_int3_handler(regs))
		return;

	/*
	 * irqentry_enter_from_user_mode() uses static_branch_{,un}likely()
	 * and therefore can trigger INT3, hence smp_text_poke_int3_handler() must
	 * be done before. If the entry came from kernel mode, then use
	 * nmi_enter() because the INT3 could have been hit in any context
	 * including NMI.
	 */
	if (user_mode(regs)) {
		irqentry_enter_from_user_mode(regs);
		instrumentation_begin();
		do_int3_user(regs);
		instrumentation_end();
		irqentry_exit_to_user_mode(regs);
	} else {
		irqentry_state_t irq_state = irqentry_nmi_enter(regs);

		instrumentation_begin();
		if (!do_int3(regs))
			die("int3", regs, 0);
		instrumentation_end();
		irqentry_nmi_exit(regs, irq_state);
	}
}

#ifdef CONFIG_X86_64
/*
 * Help handler running on a per-cpu (IST or entry trampoline) stack
 * to switch to the normal thread stack if the interrupted code was in
 * user mode. The actual stack switch is done in entry_64.S
 */
asmlinkage __visible noinstr struct pt_regs *sync_regs(struct pt_regs *eregs)
{
	struct pt_regs *regs = (struct pt_regs *)current_top_of_stack() - 1;
	if (regs != eregs)
		*regs = *eregs;
	return regs;
}

#ifdef CONFIG_AMD_MEM_ENCRYPT
asmlinkage __visible noinstr struct pt_regs *vc_switch_off_ist(struct pt_regs *regs)
{
	unsigned long sp, *stack;
	struct stack_info info;
	struct pt_regs *regs_ret;

	/*
	 * In the SYSCALL entry path the RSP value comes from user-space - don't
	 * trust it and switch to the current kernel stack
	 */
	if (ip_within_syscall_gap(regs)) {
		sp = current_top_of_stack();
		goto sync;
	}

	/*
	 * From here on the RSP value is trusted. Now check whether entry
	 * happened from a safe stack. Not safe are the entry or unknown stacks,
	 * use the fall-back stack instead in this case.
	 */
	sp    = regs->sp;
	stack = (unsigned long *)sp;

	if (!get_stack_info_noinstr(stack, current, &info) || info.type == STACK_TYPE_ENTRY ||
	    info.type > STACK_TYPE_EXCEPTION_LAST)
		sp = __this_cpu_ist_top_va(VC2);

sync:
	/*
	 * Found a safe stack - switch to it as if the entry didn't happen via
	 * IST stack. The code below only copies pt_regs, the real switch happens
	 * in assembly code.
	 */
	sp = ALIGN_DOWN(sp, 8) - sizeof(*regs_ret);

	regs_ret = (struct pt_regs *)sp;
	*regs_ret = *regs;

	return regs_ret;
}
#endif

asmlinkage __visible noinstr struct pt_regs *fixup_bad_iret(struct pt_regs *bad_regs)
{
	struct pt_regs tmp, *new_stack;

	/*
	 * This is called from entry_64.S early in handling a fault
	 * caused by a bad iret to user mode.  To handle the fault
	 * correctly, we want to move our stack frame to where it would
	 * be had we entered directly on the entry stack (rather than
	 * just below the IRET frame) and we want to pretend that the
	 * exception came from the IRET target.
	 */
	new_stack = (struct pt_regs *)__this_cpu_read(cpu_tss_rw.x86_tss.sp0) - 1;

	/* Copy the IRET target to the temporary storage. */
	__memcpy(&tmp.ip, (void *)bad_regs->sp, 5*8);

	/* Copy the remainder of the stack from the current stack. */
	__memcpy(&tmp, bad_regs, offsetof(struct pt_regs, ip));

	/* Update the entry stack */
	__memcpy(new_stack, &tmp, sizeof(tmp));

	BUG_ON(!user_mode(new_stack));
	return new_stack;
}
#endif

static bool is_sysenter_singlestep(struct pt_regs *regs)
{
	/*
	 * We don't try for precision here.  If we're anywhere in the region of
	 * code that can be single-stepped in the SYSENTER entry path, then
	 * assume that this is a useless single-step trap due to SYSENTER
	 * being invoked with TF set.  (We don't know in advance exactly
	 * which instructions will be hit because BTF could plausibly
	 * be set.)
	 */
#ifdef CONFIG_X86_32
	return (regs->ip - (unsigned long)__begin_SYSENTER_singlestep_region) <
		(unsigned long)__end_SYSENTER_singlestep_region -
		(unsigned long)__begin_SYSENTER_singlestep_region;
#elif defined(CONFIG_IA32_EMULATION)
	return (regs->ip - (unsigned long)entry_SYSENTER_compat) <
		(unsigned long)__end_entry_SYSENTER_compat -
		(unsigned long)entry_SYSENTER_compat;
#else
	return false;
#endif
}

static __always_inline unsigned long debug_read_reset_dr6(void)
{
	unsigned long dr6;

	get_debugreg(dr6, 6);
	dr6 ^= DR6_RESERVED; /* Flip to positive polarity */

	/*
	 * The Intel SDM says:
	 *
	 *   Certain debug exceptions may clear bits 0-3 of DR6.
	 *
	 *   BLD induced #DB clears DR6.BLD and any other debug
	 *   exception doesn't modify DR6.BLD.
	 *
	 *   RTM induced #DB clears DR6.RTM and any other debug
	 *   exception sets DR6.RTM.
	 *
	 *   To avoid confusion in identifying debug exceptions,
	 *   debug handlers should set DR6.BLD and DR6.RTM, and
	 *   clear other DR6 bits before returning.
	 *
	 * Keep it simple: write DR6 with its architectural reset
	 * value 0xFFFF0FF0, defined as DR6_RESERVED, immediately.
	 */
	set_debugreg(DR6_RESERVED, 6);

	return dr6;
}

/*
 * Our handling of the processor debug registers is non-trivial.
 * We do not clear them on entry and exit from the kernel. Therefore
 * it is possible to get a watchpoint trap here from inside the kernel.
 * However, the code in ./ptrace.c has ensured that the user can
 * only set watchpoints on userspace addresses. Therefore the in-kernel
 * watchpoint trap can only occur in code which is reading/writing
 * from user space. Such code must not hold kernel locks (since it
 * can equally take a page fault), therefore it is safe to call
 * force_sig_info even though that claims and releases locks.
 *
 * Code in ./signal.c ensures that the debug control register
 * is restored before we deliver any signal, and therefore that
 * user code runs with the correct debug control register even though
 * we clear it here.
 *
 * Being careful here means that we don't have to be as careful in a
 * lot of more complicated places (task switching can be a bit lazy
 * about restoring all the debug state, and ptrace doesn't have to
 * find every occurrence of the TF bit that could be saved away even
 * by user code)
 *
 * May run on IST stack.
 */

static bool notify_debug(struct pt_regs *regs, unsigned long *dr6)
{
	/*
	 * Notifiers will clear bits in @dr6 to indicate the event has been
	 * consumed - hw_breakpoint_handler(), single_stop_cont().
	 *
	 * Notifiers will set bits in @virtual_dr6 to indicate the desire
	 * for signals - ptrace_triggered(), kgdb_hw_overflow_handler().
	 */
	if (notify_die(DIE_DEBUG, "debug", regs, (long)dr6, 0, SIGTRAP) == NOTIFY_STOP)
		return true;

	return false;
}

static noinstr void exc_debug_kernel(struct pt_regs *regs, unsigned long dr6)
{
	/*
	 * Disable breakpoints during exception handling; recursive exceptions
	 * are exceedingly 'fun'.
	 *
	 * Since this function is NOKPROBE, and that also applies to
	 * HW_BREAKPOINT_X, we can't hit a breakpoint before this (XXX except a
	 * HW_BREAKPOINT_W on our stack)
	 *
	 * Entry text is excluded for HW_BP_X and cpu_entry_area, which
	 * includes the entry stack is excluded for everything.
	 *
	 * For FRED, nested #DB should just work fine. But when a watchpoint or
	 * breakpoint is set in the code path which is executed by #DB handler,
	 * it results in an endless recursion and stack overflow. Thus we stay
	 * with the IDT approach, i.e., save DR7 and disable #DB.
	 */
	unsigned long dr7 = local_db_save();
	irqentry_state_t irq_state = irqentry_nmi_enter(regs);
	instrumentation_begin();

	/*
	 * If something gets miswired and we end up here for a user mode
	 * #DB, we will malfunction.
	 */
	WARN_ON_ONCE(user_mode(regs));

	if (test_thread_flag(TIF_BLOCKSTEP)) {
		/*
		 * The SDM says "The processor clears the BTF flag when it
		 * generates a debug exception." but PTRACE_BLOCKSTEP requested
		 * it for userspace, but we just took a kernel #DB, so re-set
		 * BTF.
		 */
		unsigned long debugctl;

		rdmsrq(MSR_IA32_DEBUGCTLMSR, debugctl);
		debugctl |= DEBUGCTLMSR_BTF;
		wrmsrq(MSR_IA32_DEBUGCTLMSR, debugctl);
	}

	/*
	 * Catch SYSENTER with TF set and clear DR_STEP. If this hit a
	 * watchpoint at the same time then that will still be handled.
	 */
	if (!cpu_feature_enabled(X86_FEATURE_FRED) &&
	    (dr6 & DR_STEP) && is_sysenter_singlestep(regs))
		dr6 &= ~DR_STEP;

	/*
	 * The kernel doesn't use INT1
	 */
	if (!dr6)
		goto out;

	if (notify_debug(regs, &dr6))
		goto out;

	/*
	 * The kernel doesn't use TF single-step outside of:
	 *
	 *  - Kprobes, consumed through kprobe_debug_handler()
	 *  - KGDB, consumed through notify_debug()
	 *
	 * So if we get here with DR_STEP set, something is wonky.
	 *
	 * A known way to trigger this is through QEMU's GDB stub,
	 * which leaks #DB into the guest and causes IST recursion.
	 */
	if (WARN_ON_ONCE(dr6 & DR_STEP))
		regs->flags &= ~X86_EFLAGS_TF;
out:
	instrumentation_end();
	irqentry_nmi_exit(regs, irq_state);

	local_db_restore(dr7);
}

static noinstr void exc_debug_user(struct pt_regs *regs, unsigned long dr6)
{
	bool icebp;

	/*
	 * If something gets miswired and we end up here for a kernel mode
	 * #DB, we will malfunction.
	 */
	WARN_ON_ONCE(!user_mode(regs));

	/*
	 * NB: We can't easily clear DR7 here because
	 * irqentry_exit_to_usermode() can invoke ptrace, schedule, access
	 * user memory, etc.  This means that a recursive #DB is possible.  If
	 * this happens, that #DB will hit exc_debug_kernel() and clear DR7.
	 * Since we're not on the IST stack right now, everything will be
	 * fine.
	 */

	irqentry_enter_from_user_mode(regs);
	instrumentation_begin();

	/*
	 * Start the virtual/ptrace DR6 value with just the DR_STEP mask
	 * of the real DR6. ptrace_triggered() will set the DR_TRAPn bits.
	 *
	 * Userspace expects DR_STEP to be visible in ptrace_get_debugreg(6)
	 * even if it is not the result of PTRACE_SINGLESTEP.
	 */
	current->thread.virtual_dr6 = (dr6 & DR_STEP);

	/*
	 * The SDM says "The processor clears the BTF flag when it
	 * generates a debug exception."  Clear TIF_BLOCKSTEP to keep
	 * TIF_BLOCKSTEP in sync with the hardware BTF flag.
	 */
	clear_thread_flag(TIF_BLOCKSTEP);

	/*
	 * If dr6 has no reason to give us about the origin of this trap,
	 * then it's very likely the result of an icebp/int01 trap.
	 * User wants a sigtrap for that.
	 */
	icebp = !dr6;

	if (notify_debug(regs, &dr6))
		goto out;

	/* It's safe to allow irq's after DR6 has been saved */
	local_irq_enable();

	if (v8086_mode(regs)) {
		handle_vm86_trap((struct kernel_vm86_regs *)regs, 0, X86_TRAP_DB);
		goto out_irq;
	}

	/* #DB for bus lock can only be triggered from userspace. */
	if (dr6 & DR_BUS_LOCK)
		handle_bus_lock(regs);

	/* Add the virtual_dr6 bits for signals. */
	dr6 |= current->thread.virtual_dr6;
	if (dr6 & (DR_STEP | DR_TRAP_BITS) || icebp)
		send_sigtrap(regs, 0, get_si_code(dr6));

out_irq:
	local_irq_disable();
out:
	instrumentation_end();
	irqentry_exit_to_user_mode(regs);
}

#ifdef CONFIG_X86_64
/* IST stack entry */
DEFINE_IDTENTRY_DEBUG(exc_debug)
{
	exc_debug_kernel(regs, debug_read_reset_dr6());
}

/* User entry, runs on regular task stack */
DEFINE_IDTENTRY_DEBUG_USER(exc_debug)
{
	exc_debug_user(regs, debug_read_reset_dr6());
}

#ifdef CONFIG_X86_FRED
/*
 * When occurred on different ring level, i.e., from user or kernel
 * context, #DB needs to be handled on different stack: User #DB on
 * current task stack, while kernel #DB on a dedicated stack.
 *
 * This is exactly how FRED event delivery invokes an exception
 * handler: ring 3 event on level 0 stack, i.e., current task stack;
 * ring 0 event on the #DB dedicated stack specified in the
 * IA32_FRED_STKLVLS MSR. So unlike IDT, the FRED debug exception
 * entry stub doesn't do stack switch.
 */
DEFINE_FREDENTRY_DEBUG(exc_debug)
{
	/*
	 * FRED #DB stores DR6 on the stack in the format which
	 * debug_read_reset_dr6() returns for the IDT entry points.
	 */
	unsigned long dr6 = fred_event_data(regs);

	if (user_mode(regs))
		exc_debug_user(regs, dr6);
	else
		exc_debug_kernel(regs, dr6);
}
#endif /* CONFIG_X86_FRED */

#else
/* 32 bit does not have separate entry points. */
DEFINE_IDTENTRY_RAW(exc_debug)
{
	unsigned long dr6 = debug_read_reset_dr6();

	if (user_mode(regs))
		exc_debug_user(regs, dr6);
	else
		exc_debug_kernel(regs, dr6);
}
#endif

/*
 * Note that we play around with the 'TS' bit in an attempt to get
 * the correct behaviour even in the presence of the asynchronous
 * IRQ13 behaviour
 */
static void math_error(struct pt_regs *regs, int trapnr)
{
	struct task_struct *task = current;
	struct fpu *fpu = x86_task_fpu(task);
	int si_code;
	char *str = (trapnr == X86_TRAP_MF) ? "fpu exception" :
						"simd exception";

	cond_local_irq_enable(regs);

	if (!user_mode(regs)) {
		if (fixup_exception(regs, trapnr, 0, 0))
			goto exit;

		task->thread.error_code = 0;
		task->thread.trap_nr = trapnr;

		if (notify_die(DIE_TRAP, str, regs, 0, trapnr,
			       SIGFPE) != NOTIFY_STOP)
			die(str, regs, 0);
		goto exit;
	}

	/*
	 * Synchronize the FPU register state to the memory register state
	 * if necessary. This allows the exception handler to inspect it.
	 */
	fpu_sync_fpstate(fpu);

	task->thread.trap_nr	= trapnr;
	task->thread.error_code = 0;

	si_code = fpu__exception_code(fpu, trapnr);
	/* Retry when we get spurious exceptions: */
	if (!si_code)
		goto exit;

	if (fixup_vdso_exception(regs, trapnr, 0, 0))
		goto exit;

	force_sig_fault(SIGFPE, si_code,
			(void __user *)uprobe_get_trap_addr(regs));
exit:
	cond_local_irq_disable(regs);
}

DEFINE_IDTENTRY(exc_coprocessor_error)
{
	math_error(regs, X86_TRAP_MF);
}

DEFINE_IDTENTRY(exc_simd_coprocessor_error)
{
	if (IS_ENABLED(CONFIG_X86_INVD_BUG)) {
		/* AMD 486 bug: INVD in CPL 0 raises #XF instead of #GP */
		if (!static_cpu_has(X86_FEATURE_XMM)) {
			__exc_general_protection(regs, 0);
			return;
		}
	}
	math_error(regs, X86_TRAP_XF);
}

DEFINE_IDTENTRY(exc_spurious_interrupt_bug)
{
	/*
	 * This addresses a Pentium Pro Erratum:
	 *
	 * PROBLEM: If the APIC subsystem is configured in mixed mode with
	 * Virtual Wire mode implemented through the local APIC, an
	 * interrupt vector of 0Fh (Intel reserved encoding) may be
	 * generated by the local APIC (Int 15).  This vector may be
	 * generated upon receipt of a spurious interrupt (an interrupt
	 * which is removed before the system receives the INTA sequence)
	 * instead of the programmed 8259 spurious interrupt vector.
	 *
	 * IMPLICATION: The spurious interrupt vector programmed in the
	 * 8259 is normally handled by an operating system's spurious
	 * interrupt handler. However, a vector of 0Fh is unknown to some
	 * operating systems, which would crash if this erratum occurred.
	 *
	 * In theory this could be limited to 32bit, but the handler is not
	 * hurting and who knows which other CPUs suffer from this.
	 */
}

static bool handle_xfd_event(struct pt_regs *regs)
{
	u64 xfd_err;
	int err;

	if (!IS_ENABLED(CONFIG_X86_64) || !cpu_feature_enabled(X86_FEATURE_XFD))
		return false;

	rdmsrq(MSR_IA32_XFD_ERR, xfd_err);
	if (!xfd_err)
		return false;

	wrmsrq(MSR_IA32_XFD_ERR, 0);

	/* Die if that happens in kernel space */
	if (WARN_ON(!user_mode(regs)))
		return false;

	local_irq_enable();

	err = xfd_enable_feature(xfd_err);

	switch (err) {
	case -EPERM:
		force_sig_fault(SIGILL, ILL_ILLOPC, error_get_trap_addr(regs));
		break;
	case -EFAULT:
		force_sig(SIGSEGV);
		break;
	}

	local_irq_disable();
	return true;
}

DEFINE_IDTENTRY(exc_device_not_available)
{
	unsigned long cr0 = read_cr0();

	if (handle_xfd_event(regs))
		return;

#ifdef CONFIG_MATH_EMULATION
	if (!boot_cpu_has(X86_FEATURE_FPU) && (cr0 & X86_CR0_EM)) {
		struct math_emu_info info = { };

		cond_local_irq_enable(regs);

		info.regs = regs;
		math_emulate(&info);

		cond_local_irq_disable(regs);
		return;
	}
#endif

	/* This should not happen. */
	if (WARN(cr0 & X86_CR0_TS, "CR0.TS was set")) {
		/* Try to fix it up and carry on. */
		write_cr0(cr0 & ~X86_CR0_TS);
	} else {
		/*
		 * Something terrible happened, and we're better off trying
		 * to kill the task than getting stuck in a never-ending
		 * loop of #NM faults.
		 */
		die("unexpected #NM exception", regs, 0);
	}
}

#ifdef CONFIG_INTEL_TDX_GUEST

#define VE_FAULT_STR "VE fault"

static void ve_raise_fault(struct pt_regs *regs, long error_code,
			   unsigned long address)
{
	if (user_mode(regs)) {
		gp_user_force_sig_segv(regs, X86_TRAP_VE, error_code, VE_FAULT_STR);
		return;
	}

	if (gp_try_fixup_and_notify(regs, X86_TRAP_VE, error_code,
				    VE_FAULT_STR, address)) {
		return;
	}

	die_addr(VE_FAULT_STR, regs, error_code, address);
}

/*
 * Virtualization Exceptions (#VE) are delivered to TDX guests due to
 * specific guest actions which may happen in either user space or the
 * kernel:
 *
 *  * Specific instructions (WBINVD, for example)
 *  * Specific MSR accesses
 *  * Specific CPUID leaf accesses
 *  * Access to specific guest physical addresses
 *
 * In the settings that Linux will run in, virtualization exceptions are
 * never generated on accesses to normal, TD-private memory that has been
 * accepted (by BIOS or with tdx_enc_status_changed()).
 *
 * Syscall entry code has a critical window where the kernel stack is not
 * yet set up. Any exception in this window leads to hard to debug issues
 * and can be exploited for privilege escalation. Exceptions in the NMI
 * entry code also cause issues. Returning from the exception handler with
 * IRET will re-enable NMIs and nested NMI will corrupt the NMI stack.
 *
 * For these reasons, the kernel avoids #VEs during the syscall gap and
 * the NMI entry code. Entry code paths do not access TD-shared memory,
 * MMIO regions, use #VE triggering MSRs, instructions, or CPUID leaves
 * that might generate #VE. VMM can remove memory from TD at any point,
 * but access to unaccepted (or missing) private memory leads to VM
 * termination, not to #VE.
 *
 * Similarly to page faults and breakpoints, #VEs are allowed in NMI
 * handlers once the kernel is ready to deal with nested NMIs.
 *
 * During #VE delivery, all interrupts, including NMIs, are blocked until
 * TDGETVEINFO is called. It prevents #VE nesting until the kernel reads
 * the VE info.
 *
 * If a guest kernel action which would normally cause a #VE occurs in
 * the interrupt-disabled region before TDGETVEINFO, a #DF (fault
 * exception) is delivered to the guest which will result in an oops.
 *
 * The entry code has been audited carefully for following these expectations.
 * Changes in the entry code have to be audited for correctness vs. this
 * aspect. Similarly to #PF, #VE in these places will expose kernel to
 * privilege escalation or may lead to random crashes.
 */
DEFINE_IDTENTRY(exc_virtualization_exception)
{
	struct ve_info ve;

	/*
	 * NMIs/Machine-checks/Interrupts will be in a disabled state
	 * till TDGETVEINFO TDCALL is executed. This ensures that VE
	 * info cannot be overwritten by a nested #VE.
	 */
	tdx_get_ve_info(&ve);

	cond_local_irq_enable(regs);

	/*
	 * If tdx_handle_virt_exception() could not process
	 * it successfully, treat it as #GP(0) and handle it.
	 */
	if (!tdx_handle_virt_exception(regs, &ve))
		ve_raise_fault(regs, 0, ve.gla);

	cond_local_irq_disable(regs);
}

#endif

#ifdef CONFIG_X86_32
DEFINE_IDTENTRY_SW(iret_error)
{
	local_irq_enable();
	if (notify_die(DIE_TRAP, "iret exception", regs, 0,
			X86_TRAP_IRET, SIGILL) != NOTIFY_STOP) {
		do_trap(X86_TRAP_IRET, SIGILL, "iret exception", regs, 0,
			ILL_BADSTK, (void __user *)NULL);
	}
	local_irq_disable();
}
#endif

void __init trap_init(void)
{
	/* Init cpu_entry_area before IST entries are set up */
	setup_cpu_entry_areas();

	/* Init GHCB memory pages when running as an SEV-ES guest */
	sev_es_init_vc_handling();

	/* Initialize TSS before setting up traps so ISTs work */
	cpu_init_exception_handling(true);

	/* Setup traps as cpu_init() might #GP */
	if (!cpu_feature_enabled(X86_FEATURE_FRED))
		idt_setup_traps();

	cpu_init();
}
