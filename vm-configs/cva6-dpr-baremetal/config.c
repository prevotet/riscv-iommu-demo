#include <config.h>

/*
 * cva6-dpr-baremetal — Configuration BAO pour la démo DPR ping-pong
 *
 * VM UNIQUE : DPR Service (dpr_manager.bin) — service + test
 *   - Accès exclusif : HWICAP, accel1, accel2, DDR bitstreams
 *   - Chargé à 0x90000000 (pa = va)
 *   - Région bitstreams : 0x81000000 (16 Mo, 4 slots A/B × accel1/accel2)
 */

VM_IMAGE(dpr_manager_image, XSTR(BAO_WRKDIR_IMGS/dpr_manager.bin));

struct config config =
{
    CONFIG_HEADER
    .vmlist_size = 1,
    .vmlist =
    {
        /* ── VM 0 : DPR Service ────────────────────────────────────────── */
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
                    {   /* Code et données */
                        .base       = 0x90000000,
                        .size       = 0x04000000,
                        .place_phys = true,
                        .phys       = 0x90000000
                    },
                    {   /* Bitstreams partiels en DDR */
                        .base       = 0x81000000,
                        .size       = 0x01000000,
                        .place_phys = true,
                        .phys       = 0x81000000
                    }
                },
                .dev_num = 6,
                .devs = (struct vm_dev_region[])
                {
                    {   /* GPIO AXI — DECOUPLE accel1 (bit31) / accel2 (bit30) */
                        .pa   = 0x40000000,
                        .va   = 0x40000000,
                        .size = 0x1000
                    },
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
        }
    }
};
