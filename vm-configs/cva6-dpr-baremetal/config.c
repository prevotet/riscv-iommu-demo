#include <config.h>

/*
 * cva6-dpr-baremetal — Configuration BAO pour la démo DPR ping-pong
 *
 * VM 0 : DPR Manager (dpr_manager.bin) — service de reconfiguration
 *   - Accès exclusif : HWICAP, accel1, accel2, DDR bitstreams
 *   - Chargé à 0x90000000 (pa = va)
 *   - Région bitstreams : 0x81000000 (16 Mo, 4 slots A/B × accel1/accel2)
 *   - IPC partagée avec VM1 @ 0xF0000000
 *
 * VM 1 : DPR Client (dpr_client.bin) — test ping-pong baremetal
 *   - Chargé à 0x70000000 (pa = va, 16 Mo)
 *   - Aucun accès HWICAP ni accélérateurs
 *   - IPC partagée avec VM0 @ 0xF0000000
 *
 * Layout physique (pas de chevauchement) :
 *   0x70000000 – 0x71000000 : code DPR Client   (16 Mo) → VM1
 *   0x81000000 – 0x82000000 : bitstreams DDR     (16 Mo) → VM0
 *   0x90000000 – 0x94000000 : code DPR Manager  (64 Mo) → VM0
 *
 * Mémoire partagée :
 *   shmem[0] : 64 Ko (protocole dpr_ipc.h)
 */

VM_IMAGE(dpr_manager_image, XSTR(BAO_WRKDIR_IMGS/dpr_manager.bin));
VM_IMAGE(dpr_client_image,  XSTR(BAO_WRKDIR_IMGS/dpr_client.bin));

struct config config =
{
    CONFIG_HEADER
    .shmemlist_size = 1,
    .shmemlist = (struct shmem[])
    {
        [0] = { .size = 0x00010000, }   /* 64 Ko — protocole dpr_ipc.h */
    },
    .vmlist_size = 2,
    .vmlist =
    {
        /* ── VM 0 : DPR Manager ────────────────────────────────────────── */
        {
            .image =
            {
                .base_addr = 0x90000000,
                .load_addr = VM_IMAGE_OFFSET(dpr_manager_image),
                .size      = VM_IMAGE_SIZE(dpr_manager_image)
            },
            .entry = 0x90000000,
            .platform =
            {
                .cpu_num    = 1,
                .region_num = 2,
                .regions = (struct vm_mem_region[])
                {
                    {   /* Code et données du DPR Manager */
                        .base = 0x90000000,
                        .size = 0x04000000   /* 64 Mo */
                    },
                    {   /* Bitstreams partiels en DDR (4 slots A/B × accel1/accel2) */
                        .base = 0x81000000,
                        .size = 0x01000000   /* 16 Mo → fin 0x82000000 */
                    }
                },
                .ipc_num = 1,
                .ipcs = (struct ipc[])
                {
                    {
                        .base          = 0xF0000000,
                        .size          = 0x00010000,
                        .shmem_id      = 0,
                        .interrupt_num = 1,
                        .interrupts    = (irqid_t[]) {52}
                    }
                },
                .dev_num = 5,
                .devs = (struct vm_dev_region[])
                {
                    {   /* UART ns16750 — console de debug */
                        .pa   = 0x10000000,
                        .va   = 0x10000000,
                        .size = 0x1000
                    },
                    {   /* APB Timer */
                        .pa   = 0x18000000,
                        .va   = 0x18000000,
                        .size = 0x1000,
                        .interrupt_num = 4,
                        .interrupts    = (irqid_t[]) {4, 5, 6, 7}
                    },
                    {   /* AXI HWICAP — contrôle de la reconfiguration */
                        .pa   = 0x40010000,
                        .va   = 0x40010000,
                        .size = 0x1000
                    },
                    {   /* Accel1 — zone reconfigurable 1 */
                        .pa   = 0x50000000,
                        .va   = 0x50000000,
                        .size = 0x1000,
                        .id   = 1
                    },
                    {   /* Accel2 — zone reconfigurable 2 */
                        .pa   = 0x50001000,
                        .va   = 0x50001000,
                        .size = 0x1000,
                        .id   = 2
                    }
                },
                .arch =
                {
                    .plic_base = 0xc000000
                }
            }
        },

        /* ── VM 1 : DPR Client (baremetal ping-pong) ────────────────────── */
        {
            .image =
            {
                .base_addr = 0x70000000,
                .load_addr = VM_IMAGE_OFFSET(dpr_client_image),
                .size      = VM_IMAGE_SIZE(dpr_client_image)
            },
            .entry = 0x70000000,
            .platform =
            {
                .cpu_num    = 1,
                .region_num = 1,
                .regions = (struct vm_mem_region[])
                {
                    {
                        .base = 0x70000000,
                        .size = 0x01000000   /* 16 Mo */
                    }
                },
                .ipc_num = 1,
                .ipcs = (struct ipc[])
                {
                    {
                        .base          = 0xF0000000,
                        .size          = 0x00010000,
                        .shmem_id      = 0,
                        .interrupt_num = 1,
                        .interrupts    = (irqid_t[]) {52}
                    }
                },
                .dev_num = 2,
                .devs = (struct vm_dev_region[])
                {
                    {   /* UART ns16750 — console de debug */
                        .pa   = 0x10000000,
                        .va   = 0x10000000,
                        .size = 0x1000
                    },
                    {   /* APB Timer */
                        .pa   = 0x18000000,
                        .va   = 0x18000000,
                        .size = 0x1000,
                        .interrupt_num = 4,
                        .interrupts    = (irqid_t[]) {4, 5, 6, 7}
                    }
                },
                .arch =
                {
                    .plic_base = 0xc000000
                }
            }
        }
    }
};
