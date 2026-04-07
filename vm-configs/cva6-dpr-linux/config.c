#include <config.h>

/*
 * cva6-dpr-linux — Configuration BAO pour la démo DPR
 *
 * VM 0 : DPR Manager (baremetal, dpr_manager.bin)
 *   - Accès exclusif : HWICAP, accel1, accel2, DDR bitstreams
 *   - Chargé à 0x90000000 (pa = va)
 *   - Région bitstreams : 0x81000000 (pa = va, 7 Mo)
 *   - IPC partagée avec Linux @ 0xF0000000 (IRQ 52 en entrée)
 *
 * VM 1 : Linux (linux-rv64-cva6.bin)
 *   - Mémoire : va=0x80200000, pa=0x82400000, 220 Mo
 *   - IPC partagée avec DPR Manager @ 0xF0000000 (IRQ 52 en entrée)
 *
 * Mémoire partagée :
 *   shmem[0] : 64 Ko (protocole dpr_ipc.h)
 *
 * Layout physique (pas de chevauchement) :
 *   0x81000000 – 0x82000000 : bitstreams DDR  → VM0 (DPR Manager, 16 Mo)
 *   0x82400000 – 0x90000000 : Linux (220 Mo)  → VM1
 *   0x90000000 – 0x94000000 : code DPR Mgr    → VM0
 */

VM_IMAGE(dpr_manager_image, XSTR(BAO_WRKDIR_IMGS/dpr_manager.bin));
VM_IMAGE(linux_image,       XSTR(BAO_WRKDIR_IMGS/linux-rv64-cva6.bin));

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
                    {   /* Bitstreams partiels en DDR (chargés par GDB/OpenSBI) */
                        .base = 0x81000000,
                        .size = 0x01000000   /* 16 Mo : 4 slots A/B × accel1/accel2 → fin 0x82000000 */
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
                        .interrupts    = (irqid_t[]) {52}   /* IRQ reçu quand Linux notifie */
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

        /* ── VM 1 : Linux ───────────────────────────────────────────────── */
        {
            .image =
            {
                .base_addr = 0x80200000,
                .load_addr = VM_IMAGE_OFFSET(linux_image),
                .size      = VM_IMAGE_SIZE(linux_image)
            },
            .entry = 0x80200000,
            .platform =
            {
                .cpu_num    = 1,
                .region_num = 1,
                .regions = (struct vm_mem_region[])
                {
                    {
                        .base       = 0x80200000,
                        .size       = 0x0DC00000,   /* 220 Mo */
                        .place_phys = true,
                        .phys       = 0x82400000
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
                        .interrupts    = (irqid_t[]) {52}   /* IRQ reçu quand DPR Manager notifie */
                    }
                },
                .dev_num = 3,
                .devs = (struct vm_dev_region[])
                {
                    {   /* UART ns16750 */
                        .pa   = 0x10000000,
                        .va   = 0x10000000,
                        .size = 0x1000
                    },
                    {   /* APB Timer */
                        .pa   = 0x18000000,
                        .va   = 0x18000000,
                        .size = 0x1000
                    },
                    {   /* virtio */
                        .pa            = 0xa003000,
                        .va            = 0xa003000,
                        .size          = 0x1000,
                        .interrupt_num = 8,
                        .interrupts    = (irqid_t[]) {72,73,74,75,76,77,78,79}
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
