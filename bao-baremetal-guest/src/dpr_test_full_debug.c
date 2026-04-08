/**
 * dpr_test_full_debug.c — Démo DPR ping-pong Single VM sous BAO
 *
 * Version debug et S-mode safe.
 */

#include <stdint.h>
#include <stdio.h>
#include <cpu.h>
#include <wfi.h>

#include "dpr_ipc.h"

/* =========================================================================
 * Constantes HWICAP & Accélérateurs
 * ========================================================================= */

#define HWICAP_BASE   0x40010000ULL
#define HWICAP_WF     (HWICAP_BASE + 0x100)
#define HWICAP_RF     (HWICAP_BASE + 0x104)
#define HWICAP_SZ     (HWICAP_BASE + 0x108)
#define HWICAP_CR     (HWICAP_BASE + 0x10C)
#define HWICAP_SR     (HWICAP_BASE + 0x110)
#define HWICAP_WFV    (HWICAP_BASE + 0x114)
#define HWICAP_RFO    (HWICAP_BASE + 0x118)

#define HWICAP_CR_WRITE    0x01u
#define HWICAP_CR_READ     0x02u
#define HWICAP_CR_FIFO_RST 0x04u
#define HWICAP_WFV_MAX     0x3Fu
#define HWICAP_TIMEOUT     10000000

#define DPR_BS_ACCEL1_A_PA 0x81000000ULL
#define DPR_BS_ACCEL1_B_PA 0x81300000ULL
#define DPR_BS_ACCEL2_A_PA 0x81600000ULL
#define DPR_BS_ACCEL2_B_PA 0x81B00000ULL

#define DPR_BS_ACCEL1_WORDS (3*1024*1024/4) // 3 Mo / 4 = mots
#define DPR_BS_ACCEL2_WORDS (5*1024*1024/4) // 5 Mo / 4 = mots

/* =========================================================================
 * Bases AXI des accélérateurs
 * ========================================================================= */
#define ACCEL1_BASE 0x50000000
#define ACCEL2_BASE 0x50001000

/* =========================================================================
 * MMIO helpers
 * ========================================================================= */

static inline uint32_t mmio_read32(uint64_t addr) {
    uint32_t val;
    asm volatile("fence i, r" ::: "memory");
    val = *(volatile uint32_t *)addr;
    return val;
}

static inline void mmio_write32(uint64_t addr, uint32_t val) {
    *(volatile uint32_t *)addr = val;
    asm volatile("fence w, o" ::: "memory");
}

/* =========================================================================
 * Mapping S-mode pour bitstreams
 * ========================================================================= */

static inline const uint32_t *map_bitstream_sm(uint64_t phys_addr, uint32_t size_words) {
   // #define BASE_SMODE 0x80000000ULL  // ajuster selon BAO/linker
   /*if (phys_addr < 0x40000000ULL || phys_addr + size_words*4 > 0x50000000ULL) {
        printf("[ERROR] Bitstream phys_addr 0x%llx hors plage DDR\r\n", phys_addr);
        return NULL;
    }
    return (const uint32_t *)(BASE_SMODE + (phys_addr - 0x40000000ULL));*/
    return (const uint32_t *)phys_addr;
}

/* =========================================================================
 * Diagnostics HWICAP
 * ========================================================================= */
void arch_init(void) {
    // Pas de PLIC, pas d'interruptions en mode standalone
}


static void print_status(const char *label) {
    printf("[HWICAP] %s : SR=0x%08x WFV=0x%02x RFO=0x%02x\r\n",
           label,
           (unsigned int)mmio_read32(HWICAP_SR),
           (unsigned int)mmio_read32(HWICAP_WFV),
           (unsigned int)mmio_read32(HWICAP_RFO));
}

static void hwicap_diag(void) {
    printf("[HWICAP] === DIAG ===\r\n");
    uint32_t sz_orig = mmio_read32(HWICAP_SZ);
    mmio_write32(HWICAP_SZ, 0xAA);
    uint32_t sz_rb = mmio_read32(HWICAP_SZ);
    mmio_write32(HWICAP_SZ, sz_orig);
    printf("[HWICAP] SZ write 0xAA -> readback 0x%08x (%s)\r\n",
           (unsigned int)sz_rb,
           (sz_rb & 0xFFF) == 0xAA ? "OK" : "FAIL");
}

/* =========================================================================
 * Pilote HWICAP
 * ========================================================================= */

static void hwicap_fifo_reset(void) {
    mmio_write32(HWICAP_CR, HWICAP_CR_FIFO_RST);
    for (volatile int i=0;i<10000;i++); // petit délai
    int timeout = HWICAP_TIMEOUT;
    while (mmio_read32(HWICAP_WFV) < HWICAP_WFV_MAX && timeout-- > 0);
    mmio_write32(HWICAP_CR, 0x00u);
    printf("[HWICAP] FIFO reset : WFV=0x%02x\n", (unsigned int)mmio_read32(HWICAP_WFV));
}

static int hwicap_write_bitstream(const uint32_t *data, uint32_t size_words) {
    hwicap_fifo_reset();
    print_status("debut write_bitstream");

    uint32_t written = 0;
    printf("[DEBUG] First words of bitstream:\n");
    for (int i = 0; i < 8; i++) {
    printf("0x%08x\n", data[i]);
    }
    
    
    while (written < size_words) {
        uint32_t chunk = size_words - written;
        if (chunk > HWICAP_WFV_MAX) chunk = HWICAP_WFV_MAX;

        mmio_write32(HWICAP_SZ, chunk);
        uint32_t sent = 0;
        while (sent < chunk) {
            int timeout = HWICAP_TIMEOUT;
            while (mmio_read32(HWICAP_WFV) == 0 && timeout-- > 0) {
                asm volatile("nop");
            }
            if (timeout <= 0) {
                printf("[HWICAP] ERROR: timeout WFV mot %u\n", written+sent);
                print_status("timeout WFV");
                return -1;
            }

            uint32_t vacancy = mmio_read32(HWICAP_WFV);
            uint32_t to_write = chunk - sent;
            if (to_write > vacancy) to_write = vacancy;

            for (uint32_t i=0;i<to_write;i++)
                mmio_write32(HWICAP_WF, data[written+sent+i]);

            sent += to_write;

            // debug par chunk
            printf("[HWICAP DEBUG] Chunk sent=%u/%u, WFV=%u, SR=0x%08x\n",
                   sent, chunk,
                   (unsigned int)mmio_read32(HWICAP_WFV),
                   (unsigned int)mmio_read32(HWICAP_SR));
        }

        mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);

        int timeout = HWICAP_TIMEOUT;
        while (((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) || (mmio_read32(HWICAP_SR) & 0x1)) && timeout-- > 0) {
            asm volatile("nop");
        }
        if (timeout <= 0) {
            printf("[HWICAP] ERROR: timeout final CR/IDLE\n");
            print_status("final CR check");
            return -1;
        }

        written += chunk;
    }

    print_status("fin write_bitstream");
    printf("[HWICAP DEBUG] Finished write_bitstream (%u words written)\n", (unsigned int)size_words);
    return 0;
}

/* =========================================================================
 * Lecture IDCODE
 * ========================================================================= */

static void hwicap_read_idcode(void) {
    printf("[HWICAP] Lecture IDCODE FPGA\n");
    hwicap_fifo_reset();

    static const uint32_t seq[] = {
        0xFFFFFFFF, 0xFFFFFFFF,
        0xAA995566,
        0x20000000, 0x20000000,
        0x28012001,
        0x20000000, 0x20000000,
        0x20000000, 0x20000000,
    };
    uint32_t n = sizeof(seq)/sizeof(seq[0]);
    mmio_write32(HWICAP_SZ, n);
    for (uint32_t i=0;i<n;i++)
        mmio_write32(HWICAP_WF, seq[i]);
    mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);

    int t = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && t-- > 0);
    for (volatile int i=0;i<100000;i++);
    mmio_write32(HWICAP_SZ, 1);
    mmio_write32(HWICAP_CR, HWICAP_CR_READ);
    t = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_READ) && t-- > 0);
    uint32_t idcode = mmio_read32(HWICAP_RF);
    printf("[HWICAP] IDCODE = 0x%08x (attendu 0x03647093) -> %s\n",
           (unsigned int)idcode,
           idcode==0x03647093 ? "OK":"FAIL");
}

/* =========================================================================
 * Test Ping-Pong
 * ========================================================================= */

#define NB_ROUNDS 4

void run_demo(void) {
    printf("[DEMO] Début du test ping-pong (%d rounds)\n\n", NB_ROUNDS);
    hwicap_diag();
    hwicap_read_idcode();
    asm volatile ("fence" ::: "memory");
    uint32_t id1_lo = mmio_read32(ACCEL1_BASE);
    uint32_t id1_hi = mmio_read32(ACCEL1_BASE + 4);
    uint32_t id2_lo = mmio_read32(ACCEL2_BASE);
    uint32_t id2_hi = mmio_read32(ACCEL2_BASE + 4);

    printf("\r\n[1] IDs initiaux :\r\n");
    printf("  accel1 = 0x%08x%08x\r\n", id1_hi, id1_lo);
    printf("  accel2 = 0x%08x%08x\r\n", id2_hi, id2_lo);



    for (int round=0;round<NB_ROUNDS;round++) {
        uint32_t rm_id = (round%2==0)? DPR_RM_ACCEL_A : DPR_RM_ACCEL_B;
        const char *name = (rm_id==DPR_RM_ACCEL_A) ? "accel_A" : "accel_B";

        printf("[ROUND %d] Reconfiguration vers %s\n", round, name);

        const uint32_t *bs1 = map_bitstream_sm(
            (rm_id==DPR_RM_ACCEL_A) ? DPR_BS_ACCEL1_A_PA : DPR_BS_ACCEL1_B_PA,
            DPR_BS_ACCEL1_WORDS
        );
        if (!bs1) return;

        const uint32_t *bs2 = map_bitstream_sm(
            (rm_id==DPR_RM_ACCEL_A) ? DPR_BS_ACCEL2_A_PA : DPR_BS_ACCEL2_B_PA,
            DPR_BS_ACCEL2_WORDS
        );
        if (!bs2) return;



        printf("[ROUND %d] Accel1...\n", round);
        if (hwicap_write_bitstream(bs1, DPR_BS_ACCEL1_WORDS) != 0) {
            printf("[ROUND %d] ERREUR accel1 — abandon\n", round);
            return;
        }



        printf("[ROUND %d] Accel2...\n", round);
        if (hwicap_write_bitstream(bs2, DPR_BS_ACCEL2_WORDS) != 0) {
            printf("[ROUND %d] ERREUR accel2 — abandon\n", round);
            return;
        }

        // délai post-DPR
        for (volatile int i=0;i<5000000;i++);

        // lecture IDs après stabilisation
        asm volatile("fence i,r" ::: "memory");
        uint32_t id1_lo = mmio_read32(ACCEL1_BASE);
        uint32_t id1_hi = mmio_read32(ACCEL1_BASE+4);
        uint32_t id2_lo = mmio_read32(ACCEL2_BASE);
        uint32_t id2_hi = mmio_read32(ACCEL2_BASE+4);

        printf("[ROUND %d] Accel1 ID: 0x%08x%08x\n", round, id1_hi, id1_lo);
        printf("[ROUND %d] Accel2 ID: 0x%08x%08x\n", round, id2_hi, id2_lo);

        uint32_t expected = (rm_id==DPR_RM_ACCEL_A)? 0xAAAAAAu : 0xBBBBBBu;
        if ((id1_lo & 0xFFFFFFu) == expected && (id2_lo & 0xFFFFFFu) == expected)
            printf("[ROUND %d] [OK] %s détecté\n\n", round, name);
        else
            printf("[ROUND %d] [FAIL] IDs inattendus\n\n", round);

        for (volatile int i=0;i<2000000;i++);
    }

    printf("[DEMO] Test terminé.\n");
}

/* =========================================================================
 * Point d'entrée
 * ========================================================================= */

void dpr_test_full_debug(void) {
    

    printf("\n##############################################\n");
    printf("#   DPR Single VM Demo — RISC-V IOMMU       #\n");
    printf("##############################################\n\n");

   
    run_demo();
    
}