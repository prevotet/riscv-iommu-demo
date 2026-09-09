/**
 * SPDX-License-Identifier: Apache-2.0 
 * Copyright (c) Bao Project and Contributors. All rights reserved.
 */

#include <vm.h>
#include <page_table.h>
#include <arch/csrs.h>
#include <arch/vplic.h>
#include <arch/instructions.h>
#include <string.h>
#include <config.h>

void vm_arch_init(struct vm *vm, const struct vm_config *config)
{
    paddr_t root_pt_pa;
    mem_translate(&cpu()->as, (vaddr_t)vm->as.pt.root, &root_pt_pa);

    unsigned long hgatp = (root_pt_pa >> PAGE_SHIFT) | (HGATP_MODE_DFLT) |
                          ((vm->id << HGATP_VMID_OFF) & HGATP_VMID_MSK);

    CSRW(CSR_HGATP, hgatp);

    vplic_init(vm, config->platform.arch.plic_base);
}

void vcpu_arch_init(struct vcpu *vcpu, struct vm *vm) {
    vcpu->arch.sbi_ctx.lock = SPINLOCK_INITVAL;
    vcpu->arch.sbi_ctx.state = vcpu->id == 0 ?  STARTED : STOPPED;
}

void vcpu_arch_reset(struct vcpu *vcpu, vaddr_t entry)
{
    memset(&vcpu->regs, 0, sizeof(struct arch_regs));
    
    CSRW(sscratch, &vcpu->regs);

    vcpu->regs.hstatus = HSTATUS_SPV | HSTATUS_VSXL_64;
    vcpu->regs.sstatus = SSTATUS_SPP_BIT | SSTATUS_FS_DIRTY | SSTATUS_XS_DIRTY;
    vcpu->regs.sepc = entry;
    vcpu->regs.a0 = vcpu->arch.hart_id = vcpu->id;
    vcpu->regs.a1 = 0;  // according to sbi it should be the dtb load address

    /* MODIFIED : HCOUNTEREN_CY ajoute a HCOUNTEREN_TM.
     *
     * Sans le bit CY, un `rdcycle` depuis le guest part en exception 22
     * (Virtual Instruction) et le bench doit se rabattre sur `time`. Or CVA6
     * n'implemente PAS CSR_TIME (voir csr_regfile.sv : CSR_CYCLE est cable,
     * CSR_TIME n'a aucun cas) : `rdtime` leve une instruction illegale, que
     * hcounteren.TM laisse filer jusqu'en M-mode, ou OpenSBI l'emule en lisant
     * le mtime du CLINT sur le bus. Cout mesure le 2026-09-09 : 638 ticks, soit
     * ~1276 cycles coeur, PAR LECTURE D'HORLOGE.
     *
     * C'etait la moitie de chaque latence publiee par bench_runner.c. Avec le
     * bit CY, `rdcycle` s'execute en materiel en quelques cycles, et le bench
     * lit des cycles coeur directement -- plus de conversion x2, plus de trap.
     *
     * mcounteren vaut deja -1 cote OpenSBI (sbi_hart.c), il n'y a rien d'autre
     * a armer.
     *
     * Ce fichier vit dans bao-overlay/ et non dans le sous-module : celui-ci est
     * bien suivi, mais init_submodules y fait `git reset --hard` + `git clean
     * -fd` et emporterait la modification. */
    CSRW(CSR_HCOUNTEREN, HCOUNTEREN_TM | HCOUNTEREN_CY);
    CSRW(CSR_HTIMEDELTA, 0);
    CSRW(CSR_VSSTATUS, SSTATUS_SD | SSTATUS_FS_DIRTY | SSTATUS_XS_DIRTY);
    CSRW(CSR_HIE, 0);
    CSRW(CSR_VSTVEC, 0);
    CSRW(CSR_VSSCRATCH, 0);
    CSRW(CSR_VSEPC, 0);
    CSRW(CSR_VSCAUSE, 0);
    CSRW(CSR_VSTVAL, 0);
    CSRW(CSR_HVIP, 0);
    CSRW(CSR_VSATP, 0);
}

unsigned long vcpu_readreg(struct vcpu *vcpu, unsigned long reg)
{
    if ((reg <= 0) || (reg > 31)) return 0;
    return vcpu->regs.x[reg - 1];
}

void vcpu_writereg(struct vcpu *vcpu, unsigned long reg, unsigned long val)
{
    if ((reg <= 0) || (reg > 31)) return;
    vcpu->regs.x[reg - 1] = val;
}

unsigned long vcpu_readpc(struct vcpu *vcpu)
{
    return vcpu->regs.sepc;
}

void vcpu_writepc(struct vcpu *vcpu, unsigned long pc)
{
    vcpu->regs.sepc = pc;
}

void vcpu_arch_run(struct vcpu *vcpu){

    if(vcpu->arch.sbi_ctx.state == STARTED){
        vcpu_arch_entry();
    } else {
        cpu_idle();
    }    

}
