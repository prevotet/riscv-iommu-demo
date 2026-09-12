/**
 * SPDX-License-Identifier: Apache-2.0
 * Copyright (c) Bao Project and Contributors. All rights reserved.
 */

#include <interrupts.h>

#include <cpu.h>
#include <vm.h>
#include <bitmap.h>
#include <string.h>

BITMAP_ALLOC(hyp_interrupt_bitmap, MAX_INTERRUPTS);
BITMAP_ALLOC(global_interrupt_bitmap, MAX_INTERRUPTS);

irq_handler_t interrupt_handlers[MAX_INTERRUPTS];

inline void interrupts_cpu_sendipi(cpuid_t target_cpu, irqid_t ipi_id)
{
    interrupts_arch_ipi_send(target_cpu, ipi_id);
}

inline void interrupts_cpu_enable(irqid_t int_id, bool en)
{
    interrupts_arch_enable(int_id, en);
}

inline bool interrupts_check(irqid_t int_id)
{
    return interrupts_arch_check(int_id);
}

inline void interrupts_clear(irqid_t int_id)
{
    interrupts_arch_clear(int_id);
}

inline void interrupts_init()
{
    interrupts_arch_init();

    if (cpu()->id == CPU_MASTER) {
        interrupts_reserve(IPI_CPU_MSG, cpu_msg_handler);
    }

    interrupts_cpu_enable(IPI_CPU_MSG, true);
}

static inline bool interrupt_is_reserved(irqid_t int_id)
{
    return bitmap_get(hyp_interrupt_bitmap, int_id);
}

enum irq_res interrupts_handle(irqid_t int_id)
{
    if (vm_has_interrupt(cpu()->vcpu->vm, int_id)) {
        vcpu_inject_hw_irq(cpu()->vcpu, int_id);

        return FORWARD_TO_VM;

    } else if (interrupt_is_reserved(int_id)) {
        interrupt_handlers[int_id](int_id);

        return HANDLED_BY_HYP;

    } else {
        ERROR("received unknown interrupt id = %d", int_id);
    }
}

void interrupts_vm_assign(struct vm *vm, irqid_t id)
{
    if (interrupts_arch_conflict(global_interrupt_bitmap, id)) {
        ERROR("Interrupts conflict, id = %d\n", id);
    }

    /* SONDE 2026-09-12. Le wrapper ARMOR leve bien irq_o (sticky non nul,
     * CTRL[11] arme) et le guest configure correctement son vPLIC (prio 1,
     * enable pose, seuil 0), mais aucune interruption n'atteint le
     * gestionnaire. Deux hypotheses restaient : le PLIC physique ne voit pas
     * la source, ou Bao ne l'a jamais marquee comme materielle et n'a donc
     * jamais programme le PLIC physique. Cette ligne tranche la seconde. */
    INFO("ASSIGN irq %d to vm", id);

    interrupts_arch_vm_assign(vm, id);

    bitmap_set(vm->interrupt_bitmap, id);
    bitmap_set(global_interrupt_bitmap, id);
}

void interrupts_reserve(irqid_t int_id, irq_handler_t handler)
{
    if (int_id < MAX_INTERRUPTS) {
        interrupt_handlers[int_id] = handler;
        bitmap_set(hyp_interrupt_bitmap, int_id);
        bitmap_set(global_interrupt_bitmap, int_id);
    }
}
