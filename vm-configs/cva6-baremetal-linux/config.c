#include <config.h>

VM_IMAGE(baremetal_image, XSTR(BAO_WRKDIR_IMGS/baremetal.bin));
VM_IMAGE(linux_image,     XSTR(BAO_WRKDIR_IMGS/linux-rv64-cva6.bin));

struct config config =
{
    CONFIG_HEADER
    .shmemlist_size = 1,
    .shmemlist = (struct shmem[])
    {
        [0] = { .size = 0x00010000, }
    },
    .vmlist_size = 2,
    .vmlist =
    {
        /* ── VM 0 : baremetal ───────────────────────────────────────── */
        {
            .image =
            {
                .base_addr = 0x90000000,
                .load_addr = VM_IMAGE_OFFSET(baremetal_image),
                .size      = VM_IMAGE_SIZE(baremetal_image)
            },
            .entry = 0x90000000,
            .platform =
            {
                .cpu_num    = 1,
                .region_num = 1,
                .regions = (struct vm_mem_region[])
                {
                    {
                        .base = 0x90000000,
                        .size = 0x20000000
                    }
                },
                .dev_num = 7,
                .devs = (struct vm_dev_region[])
                {
                    {
                         /*UART ns16750 */
                        .pa   = 0x10000000,
                        .va   = 0x10000000,
                        .size = 0x1000
                        /*.interrupt_num = 1,
                        .interrupts = (irqid_t[]) {1}*/
                    },
                    {
                        /* APB Timer */
                        .pa   = 0x18000000,
                        .va   = 0x18000000,
                        .size = 0x1000,
                        /* APB Timer interrupts */
                        .interrupt_num = 4,
                        .interrupts    = (irqid_t[]) {4, 5, 6, 7}
                    },
                    {   // SPI
                        .pa = 0x20000000,   
                        .va = 0x20000000,  
                        .size = 0x00001000,  
                        .interrupt_num = 1,
                        .interrupts = (irqid_t[]) {2}
                    },
                    {   // Ethernet
                        .pa = 0x30000000,   
                        .va = 0x30000000,  
                        .size = 0x00008000,  
                        .interrupt_num = 1,
                        .interrupts = (irqid_t[]) {3}
                    },
                    {   // GPIO
                        .pa = 0x40000000,   
                        .va = 0x40000000,  
                        .size = 0x00010000,  
                        .interrupt_num = 0,
                        .interrupts = (irqid_t[]) {}
                    },
                    {   // iDMA
                        .pa = 0x50000000,
                        .va = 0x50000000,
                        .size = 0x00001000,
                        .interrupt_num = 0,
                        .interrupts = (irqid_t[]) {},
                        .id = 1
                    },
                    {   // IOMMU (demo only)
                        .pa = 0x50010000,   
                        .va = 0x50010000,  
                        .size = 0x00001000,  
                        .interrupt_num = 0,
                        .interrupts = (irqid_t[]) {}
                    },

                },
                .arch =
                {
                    .plic_base = 0xc000000
                }
            }
        },

        /* ── VM 1 : Linux ───────────────────────────────────────────── */
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
                        .size       = 0x0DC00000,
                        .place_phys = true,
                        .phys       = 0x82400000
                    }
                },
                .ipc_num = 1,
                .ipcs = (struct ipc[])
                {
                    {
                        .base          = 0xf0000000,
                        .size          = 0x00010000,
                        .shmem_id      = 0,
                        .interrupt_num = 1,
                        .interrupts    = (irqid_t[]) {52}
                    }
                },
                .dev_num = 3,
                .devs = (struct vm_dev_region[])
                {
                    {
                        /* UART ns16750 */
                        .pa   = 0x10000000,
                        .va   = 0x10000000,
                        .size = 0x1000,
                    },
                    {
                        /* APB Timer */
                        .pa   = 0x18000000,
                        .va   = 0x18000000,
                        .size = 0x1000,
                    },
                    {
                        /* virtio devices */
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