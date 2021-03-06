/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * Copyright (c) 2019 Western Digital Corporation or its affiliates.
 *
 * Authors:
 *   Anup Patel <anup.patel@wdc.com>
 */

#include <sbi/riscv_asm.h>
#include <sbi/riscv_encoding.h>
#include <sbi/sbi_platform.h>
#include <sbi/sbi_scratch.h>
#include <sbi/sbi_trap.h>

	.align 3
	.section .entry, "ax", %progbits
	.globl _start
	.globl _start_warm
_start:
	/*
	 * Jump to warm-boot if this is not the first core booting,
	 * that is, for mhartid != 0
	 */
	csrr	a6, CSR_MHARTID
	blt	zero, a6, _wait_for_boot_hart

	/* Zero-out BSS */
	la	a4, _bss_start
	la	a5, _bss_end
_bss_zero:
	REG_S	zero, (a4)
	add	a4, a4, __SIZEOF_POINTER__
	blt	a4, a5, _bss_zero

	/* Override pervious arg1 */
	add	s0, a0, zero
	add	s1, a1, zero
	call	fw_prev_arg1
	add	t1, a0, zero
	add	a0, s0, zero
	add	a1, s1, zero
	beqz	t1, _prev_arg1_override_done
	add	a1, t1, zero
_prev_arg1_override_done:

	/*
	 * Relocate Flatened Device Tree (FDT)
	 * source FDT address = previous arg1
	 * destination FDT address = next arg1
	 *
	 * Note: We will preserve a0 and a1 passed by
	 * previous booting stage.
	 */
	beqz	a1, _fdt_reloc_done
	/* Mask values in a3 and a4 */
	li	a3, ~0xf
	li	a4, 0xff
	/* t1 = destination FDT start address */
	add	s0, a0, zero
	add	s1, a1, zero
	call	fw_next_arg1
	add	t1, a0, zero
	add	a0, s0, zero
	add	a1, s1, zero
	beqz	t1, _fdt_reloc_done
	and	t1, t1, a3
	/* t0 = source FDT start address */
	add	t0, a1, zero
	and	t0, t0, a3
	/* t2 = source FDT size in big-endian */
#if __riscv_xlen == 64
	lwu	t2, 4(t0)
#else
	lw	t2, 4(t0)
#endif
	/* t3 = bit[15:8] of FDT size */
	add	t3, t2, zero
	srli	t3, t3, 16
	and	t3, t3, a4
	slli	t3, t3, 8
	/* t4 = bit[23:16] of FDT size */
	add	t4, t2, zero
	srli	t4, t4, 8
	and	t4, t4, a4
	slli	t4, t4, 16
	/* t5 = bit[31:24] of FDT size */
	add	t5, t2, zero
	and	t5, t5, a4
	slli	t5, t5, 24
	/* t2 = bit[7:0] of FDT size */
	srli	t2, t2, 24
	and	t2, t2, a4
	/* t2 = FDT size in little-endian */
	or	t2, t2, t3
	or	t2, t2, t4
	or	t2, t2, t5
	/* t2 = destination FDT end address */
	add	t2, t1, t2
	/* FDT copy loop */
	ble	t2, t1, _fdt_reloc_done
_fdt_reloc_again:
	REG_L	t3, 0(t0)
	REG_S	t3, 0(t1)
	add	t0, t0, __SIZEOF_POINTER__
	add	t1, t1, __SIZEOF_POINTER__
	blt	t1, t2, _fdt_reloc_again
_fdt_reloc_done:

	/* Update boot hart flag */
	la	a4, _boot_hart_done
	li	a5, 1
	REG_S	a5, (a4)
	j	_wait_for_boot_hart

	.align	3
_boot_hart_done:
	RISCV_PTR	0
	.align	3

	/* Wait for boot hart */
_wait_for_boot_hart:
	la	a4, _boot_hart_done
	REG_L	a5, (a4)
	beqz	a5, _wait_for_boot_hart

_start_warm:
	/* Disable and clear all interrupts */
	csrw	CSR_MIE, zero
	csrw	CSR_MIP, zero

	/* Preload per-HART details
	 * s6 -> HART ID
	 * s7 -> HART Count
	 * s8 -> HART Stack Size
	 */
	csrr	s6, CSR_MHARTID
	la	a4, platform
#if __riscv_xlen == 64
	lwu	s7, SBI_PLATFORM_HART_COUNT_OFFSET(a4)
	lwu	s8, SBI_PLATFORM_HART_STACK_SIZE_OFFSET(a4)
#else
	lw	s7, SBI_PLATFORM_HART_COUNT_OFFSET(a4)
	lw	s8, SBI_PLATFORM_HART_STACK_SIZE_OFFSET(a4)
#endif

	/* HART ID should be within expected limit */
	csrr	s6, CSR_MHARTID
	bge	s6, s7, _start_hang

	/* Setup scratch space */
	la	tp, _fw_end
	mul	a5, s7, s8
	add	tp, tp, a5
	mul	a5, s8, s6
	sub	tp, tp, a5
	li	a5, SBI_SCRATCH_SIZE
	sub	tp, tp, a5
	csrw	CSR_MSCRATCH, tp

	/* Initialize scratch space */
	la	a4, _fw_start
	la	a5, _fw_end
	mul	t0, s7, s8
	add	a5, a5, t0
	sub	a5, a5, a4
	REG_S	a4, SBI_SCRATCH_FW_START_OFFSET(tp)
	REG_S	a5, SBI_SCRATCH_FW_SIZE_OFFSET(tp)
	/* Note: fw_next_arg1() uses a0, a1, and ra */
	call	fw_next_arg1
	REG_S	a0, SBI_SCRATCH_NEXT_ARG1_OFFSET(tp)
	/* Note: fw_next_addr() uses a0, a1, and ra */
	call	fw_next_addr
	REG_S	a0, SBI_SCRATCH_NEXT_ADDR_OFFSET(tp)
	li	a4, PRV_S
	REG_S	a4, SBI_SCRATCH_NEXT_MODE_OFFSET(tp)
	la	a4, _start_warm
	REG_S	a4, SBI_SCRATCH_WARMBOOT_ADDR_OFFSET(tp)
	la	a4, platform
	REG_S	a4, SBI_SCRATCH_PLATFORM_ADDR_OFFSET(tp)
	la	a4, _hartid_to_scratch
	REG_S	a4, SBI_SCRATCH_HARTID_TO_SCRATCH_OFFSET(tp)
	REG_S	zero, SBI_SCRATCH_IPI_TYPE_OFFSET(tp)

	/* Setup stack */
	add	sp, tp, zero

	/* Setup trap handler */
	la	a4, _trap_handler
	csrw	CSR_MTVEC, a4

	/* Initialize SBI runtime */
	csrr	a0, CSR_MSCRATCH
	Call	sbi_init

	/* We don't expect to reach here hence just hang */
	j	_start_hang

	.align 3
	.section .entry, "ax", %progbits
	.globl _hartid_to_scratch
_hartid_to_scratch:
	add	sp, sp, -(3 * __SIZEOF_POINTER__)
	REG_S	s0, (sp)
	REG_S	s1, (__SIZEOF_POINTER__)(sp)
	REG_S	s2, (__SIZEOF_POINTER__ * 2)(sp)
	/*
	 * a0 -> HART ID (passed by caller)
	 * s0 -> HART Stack Size
	 * s1 -> HART Stack End
	 * s2 -> Temporary
	 */
	la	s2, platform
#if __riscv_xlen == 64
	lwu	s0, SBI_PLATFORM_HART_STACK_SIZE_OFFSET(s2)
	lwu	s2, SBI_PLATFORM_HART_COUNT_OFFSET(s2)
#else
	lw	s0, SBI_PLATFORM_HART_STACK_SIZE_OFFSET(s2)
	lw	s2, SBI_PLATFORM_HART_COUNT_OFFSET(s2)
#endif
	mul	s2, s2, s0
	la	s1, _fw_end
	add	s1, s1, s2
	mul	s2, s0, a0
	sub	s1, s1, s2
	li	s2, SBI_SCRATCH_SIZE
	sub	a0, s1, s2
	REG_L	s0, (sp)
	REG_L	s1, (__SIZEOF_POINTER__)(sp)
	REG_L	s2, (__SIZEOF_POINTER__ * 2)(sp)
	add	sp, sp, (3 * __SIZEOF_POINTER__)
	ret

	.align 3
	.section .entry, "ax", %progbits
	.globl _start_hang
_start_hang:
	wfi
	j	_start_hang

	.align 3
	.section .entry, "ax", %progbits
	.globl _trap_handler
_trap_handler:
	/* Swap SP and MSCRATCH */
	csrrw	sp, CSR_MSCRATCH, sp

	/* Setup exception stack */
	add	sp, sp, -(SBI_TRAP_REGS_SIZE)

	/* Save RA, T0, T1, and T2 */
	REG_S	ra, SBI_TRAP_REGS_OFFSET(ra)(sp)
	REG_S	t0, SBI_TRAP_REGS_OFFSET(t0)(sp)
	REG_S	t1, SBI_TRAP_REGS_OFFSET(t1)(sp)
	REG_S	t2, SBI_TRAP_REGS_OFFSET(t2)(sp)

	/* Save original SP and restore MSCRATCH */
	add	t0, sp, SBI_TRAP_REGS_SIZE
	csrrw	t0, CSR_MSCRATCH, t0
	REG_S	t0, SBI_TRAP_REGS_OFFSET(sp)(sp)

	/* Save MEPC and MSTATUS CSRs */
	csrr	t0, CSR_MEPC
	csrr	t1, CSR_MSTATUS

	/*
	 * Note: Fast path trap handling can be done here
	 * using SP, RA, T0, T1, and T2 registers where
	 * T0 <- MEPC
	 * T1 <- MSTATUS
	 */

	/* Save MEPC and MSTATUS CSRs */
	REG_S	t0, SBI_TRAP_REGS_OFFSET(mepc)(sp)
	REG_S	t1, SBI_TRAP_REGS_OFFSET(mstatus)(sp)

	/* Save all general regisers except SP, RA, T0, T1, and T2 */
	REG_S	zero, SBI_TRAP_REGS_OFFSET(zero)(sp)
	REG_S	gp, SBI_TRAP_REGS_OFFSET(gp)(sp)
	REG_S	tp, SBI_TRAP_REGS_OFFSET(tp)(sp)
	REG_S	s0, SBI_TRAP_REGS_OFFSET(s0)(sp)
	REG_S	s1, SBI_TRAP_REGS_OFFSET(s1)(sp)
	REG_S	a0, SBI_TRAP_REGS_OFFSET(a0)(sp)
	REG_S	a1, SBI_TRAP_REGS_OFFSET(a1)(sp)
	REG_S	a2, SBI_TRAP_REGS_OFFSET(a2)(sp)
	REG_S	a3, SBI_TRAP_REGS_OFFSET(a3)(sp)
	REG_S	a4, SBI_TRAP_REGS_OFFSET(a4)(sp)
	REG_S	a5, SBI_TRAP_REGS_OFFSET(a5)(sp)
	REG_S	a6, SBI_TRAP_REGS_OFFSET(a6)(sp)
	REG_S	a7, SBI_TRAP_REGS_OFFSET(a7)(sp)
	REG_S	s2, SBI_TRAP_REGS_OFFSET(s2)(sp)
	REG_S	s3, SBI_TRAP_REGS_OFFSET(s3)(sp)
	REG_S	s4, SBI_TRAP_REGS_OFFSET(s4)(sp)
	REG_S	s5, SBI_TRAP_REGS_OFFSET(s5)(sp)
	REG_S	s6, SBI_TRAP_REGS_OFFSET(s6)(sp)
	REG_S	s7, SBI_TRAP_REGS_OFFSET(s7)(sp)
	REG_S	s8, SBI_TRAP_REGS_OFFSET(s8)(sp)
	REG_S	s9, SBI_TRAP_REGS_OFFSET(s9)(sp)
	REG_S	s10, SBI_TRAP_REGS_OFFSET(s10)(sp)
	REG_S	s11, SBI_TRAP_REGS_OFFSET(s11)(sp)
	REG_S	t3, SBI_TRAP_REGS_OFFSET(t3)(sp)
	REG_S	t4, SBI_TRAP_REGS_OFFSET(t4)(sp)
	REG_S	t5, SBI_TRAP_REGS_OFFSET(t5)(sp)
	REG_S	t6, SBI_TRAP_REGS_OFFSET(t6)(sp)

	/* Call C routine */
	add	a0, sp, zero
	csrr	a1, CSR_MSCRATCH
	call	sbi_trap_handler

	/* Restore all general regisers except SP, RA, T0, T1, T2, and T3 */
	REG_L	gp, SBI_TRAP_REGS_OFFSET(gp)(sp)
	REG_L	tp, SBI_TRAP_REGS_OFFSET(tp)(sp)
	REG_L	s0, SBI_TRAP_REGS_OFFSET(s0)(sp)
	REG_L	s1, SBI_TRAP_REGS_OFFSET(s1)(sp)
	REG_L	a0, SBI_TRAP_REGS_OFFSET(a0)(sp)
	REG_L	a1, SBI_TRAP_REGS_OFFSET(a1)(sp)
	REG_L	a2, SBI_TRAP_REGS_OFFSET(a2)(sp)
	REG_L	a3, SBI_TRAP_REGS_OFFSET(a3)(sp)
	REG_L	a4, SBI_TRAP_REGS_OFFSET(a4)(sp)
	REG_L	a5, SBI_TRAP_REGS_OFFSET(a5)(sp)
	REG_L	a6, SBI_TRAP_REGS_OFFSET(a6)(sp)
	REG_L	a7, SBI_TRAP_REGS_OFFSET(a7)(sp)
	REG_L	s2, SBI_TRAP_REGS_OFFSET(s2)(sp)
	REG_L	s3, SBI_TRAP_REGS_OFFSET(s3)(sp)
	REG_L	s4, SBI_TRAP_REGS_OFFSET(s4)(sp)
	REG_L	s5, SBI_TRAP_REGS_OFFSET(s5)(sp)
	REG_L	s6, SBI_TRAP_REGS_OFFSET(s6)(sp)
	REG_L	s7, SBI_TRAP_REGS_OFFSET(s7)(sp)
	REG_L	s8, SBI_TRAP_REGS_OFFSET(s8)(sp)
	REG_L	s9, SBI_TRAP_REGS_OFFSET(s9)(sp)
	REG_L	s10, SBI_TRAP_REGS_OFFSET(s10)(sp)
	REG_L	s11, SBI_TRAP_REGS_OFFSET(s11)(sp)
	REG_L	t3, SBI_TRAP_REGS_OFFSET(t3)(sp)
	REG_L	t4, SBI_TRAP_REGS_OFFSET(t4)(sp)
	REG_L	t5, SBI_TRAP_REGS_OFFSET(t5)(sp)
	REG_L	t6, SBI_TRAP_REGS_OFFSET(t6)(sp)

	/* Load T0 and T1 with MEPC and MSTATUS */
	REG_L	t0, SBI_TRAP_REGS_OFFSET(mepc)(sp)
	REG_L	t1, SBI_TRAP_REGS_OFFSET(mstatus)(sp)

	/*
	 * Note: Jump here after fast trap handling
	 * using SP, RA, T0, T1, and T2
	 * T0 <- MEPC
	 * T1 <- MSTATUS
	 */

	/* Restore MEPC and MSTATUS CSRs */
	csrw	CSR_MEPC, t0
	csrw	CSR_MSTATUS, t1

	/* Restore RA, T0, T1, and T2 */
	REG_L	ra, SBI_TRAP_REGS_OFFSET(ra)(sp)
	REG_L	t0, SBI_TRAP_REGS_OFFSET(t0)(sp)
	REG_L	t1, SBI_TRAP_REGS_OFFSET(t1)(sp)
	REG_L	t2, SBI_TRAP_REGS_OFFSET(t2)(sp)

	/* Restore SP */
	REG_L	sp, SBI_TRAP_REGS_OFFSET(sp)(sp)

	mret
