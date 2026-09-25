#include <config.h>

VM_IMAGE(baremetal_image, XSTR(BAO_WRKDIR_IMGS/baremetal.bin));

struct config config = {
    
    CONFIG_HEADER

    .vmlist_size = 1,
    .vmlist = {
        {
            .image = {
                .base_addr = 0x90000000,
                .load_addr = VM_IMAGE_OFFSET(baremetal_image),
                .size = VM_IMAGE_SIZE(baremetal_image)
            },

            .entry = 0x90000000,

            .platform = {
                .cpu_num = 1,
                
                .region_num = 1,
                .regions =  (struct vm_mem_region[]) {
                    {
                        .base = 0x90000000,
                        .size = 0x20000000,
                        .place_phys = true,
                        .phys = 0x90000000,
                    }
                },

                /* --------------------------------------------------------
                 * ORIGINAL : .dev_num = 7  (UART, Timer, SPI, Ethernet,
                 *            GPIO, LHA "DMA", IOMMU). Pas de MHA.
                 * MODIFIED : .dev_num = 8  -- ajout du MHA (DEVICE_ID=2)
                 * MODIFIED : .dev_num = 10 -- ajout des fenetres CSR des deux
                 *            sec_wrappers ARMOR (0x50002000 / 0x50003000).
                 *            Ce compteur est en dur : l'oublier fait ignorer
                 *            silencieusement les entrees ajoutees.
                 *            pour permettre au guest baremetal d'accéder
                 *            à ses registres MMIO. L'hyperviseur Bao doit
                 *            connaître tous les devices exposés au guest,
                 *            sinon trap d'accès.
                 * -------------------------------------------------------- */
                .dev_num = 10,
                .devs =  (struct vm_dev_region[]) {
                    {   // UART
                        .pa = 0x10000000,   
                        .va = 0x10000000,  
                        .size = 0x00010000,
                        .interrupt_num = 1,
                        .interrupts = (irqid_t[]) {1}
                    },
                    {   // Timer
                        .pa = 0x18000000,   
                        .va = 0x18000000,  
                        .size = 0x00001000,  
                        .interrupt_num = 4,
                        .interrupts = (irqid_t[]) {4,5,6,7}
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
                    {   // LHA (Legitimate Hardware Accelerator, DEVICE_ID=1)
                        .pa = 0x50000000,
                        .va = 0x50000000,
                        .size = 0x00001000,
                        .interrupt_num = 0,
                        .interrupts = (irqid_t[]) {},
                        .id = 1
                    },
                    /* ----------------------------------------------------
                     * ADDED : nouveau device MHA.
                     * Accélérateur malicieux ajouté à côté du LHA pour les
                     * scénarios d'attaque (spoofing ID + DoS storm).
                     * .id = 2 -> stream_id transmis à l'IOMMU pour la
                     *           vérification DDT[2].V (=0 -> blocage).
                     * ---------------------------------------------------- */
                    {   // MHA (Malicious Hardware Accelerator, DEVICE_ID=2)
                        .pa = 0x50001000,
                        .va = 0x50001000,
                        .size = 0x00001000,
                        .interrupt_num = 0,
                        .interrupts = (irqid_t[]) {},
                        .id = 2
                    },
                    /* ----------------------------------------------------
                     * Fenetres CSR des sec_wrappers ARMOR. Sans ces deux
                     * regions, la premiere lecture du registre MAGIC en
                     * 0x50002058 sort en "no emulation handler for abort" :
                     * l'adresse n'est pas mappee dans la VM.
                     * Pas de .id : ce sont de simples esclaves MMIO, ils
                     * n'emettent aucune transaction DMA vers l'IOMMU.
                     * ---------------------------------------------------- */
                    /* IRQ 13 et 14 : sorties irq_o des deux wrappers, ajoutees
                     * au bitstream v13. Sans ces deux lignes, Bao ne route pas
                     * la source PLIC vers la VM et le gestionnaire n'est jamais
                     * appele. Rappel : .dev_num est en dur au-dessus.
                     *
                     * ATTENTION AU DECALAGE D'UN. L'identifiant PLIC vaut
                     * l'index materiel PLUS UN, l'ID 0 etant reserve par la
                     * specification RISC-V. Toute cette table le fait deja :
                     * l'UART est cable sur irq_sources[0] et declare {1}, le
                     * SPI sur [1] et declare {2}, le timer sur [6:3] et declare
                     * {4,5,6,7}. Les wrappers sont cables sur irq_sources[12]
                     * et [13] : ils portent donc les ID 13 et 14. Les declarer
                     * 12 et 13 arme le voisin -- l'ID 13 designe le wrapper 1,
                     * dont le collant reste vide, et rien ne remonte jamais.
                     * Trois campagnes perdues dessus le 2026-09-12. */
                    {   // sec_wrapper #1 (surveille le LHA)
                        .pa = 0x50002000,
                        .va = 0x50002000,
                        .size = 0x00001000,
                        .interrupt_num = 1,
                        .interrupts = (irqid_t[]) {13}
                    },
                    {   // sec_wrapper #2 (surveille le MHA)
                        .pa = 0x50003000,
                        .va = 0x50003000,
                        .size = 0x00001000,
                        .interrupt_num = 1,
                        .interrupts = (irqid_t[]) {14}
                    },
                    {   // IOMMU (demo only)
                        .pa = 0x50010000,   
                        .va = 0x50010000,  
                        .size = 0x00001000,  
                        .interrupt_num = 0,
                        .interrupts = (irqid_t[]) {}
                    },
                },

                .arch = {
                   .plic_base = 0xc000000
                }
            }
        }
    }
};