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

/* GPIO DECOUPLE */
#define GPIO_BASE       0x40000000ULL
#define GPIO_DATA       (GPIO_BASE + 0x00)
#define GPIO_TRI        (GPIO_BASE + 0x04)
#define DECOUPLE_ACCEL1 (1u << 31)
#define DECOUPLE_ACCEL2 (1u << 30)

/* Adresses et tailles depuis dpr_ipc.h */

static inline uint32_t bswap32(uint32_t x) {
    return ((x & 0xFF000000u) >> 24)
         | ((x & 0x00FF0000u) >>  8)
         | ((x & 0x0000FF00u) <<  8)
         | ((x & 0x000000FFu) << 24);
}

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
           (sz_rb & 0xFFF) == 0xAA ? "OK" : "FAIL - shift probable");

    const char *names[] = {"WF ", "RF ", "SZ ", "CR ", "SR ", "WFV", "RFO"};
    for (int i = 0; i < 7; i++) {
        uint64_t addr = HWICAP_BASE + 0x100 + i * 4;
        printf("[HWICAP] [0x%03x] %s = 0x%08x\r\n",
               (unsigned int)(addr - HWICAP_BASE),
               names[i],
               (unsigned int)mmio_read32(addr));
    }
    printf("[HWICAP] === FIN DIAG ===\r\n");
}

/* =========================================================================
 * Pilote HWICAP
 * ========================================================================= */

static void hwicap_fifo_reset(void) {
    mmio_write32(HWICAP_CR, HWICAP_CR_FIFO_RST);
    int timeout = HWICAP_TIMEOUT;
    while (mmio_read32(HWICAP_WFV) < HWICAP_WFV_MAX && timeout-- > 0);
    mmio_write32(HWICAP_CR, 0x00u);
}

/* Envoie n mots logiques (séquences de contrôle, sans bswap). */
static void hwicap_send_raw(const uint32_t *w, uint32_t n) {
    hwicap_fifo_reset();
    mmio_write32(HWICAP_SZ, n);
    for (uint32_t i = 0; i < n; i++)
        mmio_write32(HWICAP_WF, w[i]);
    mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);
    int timeout = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && timeout-- > 0);
}

/* RCRC efface CRC_ERROR/CFGERR, DESYNC remet l'ICAP en IDLE.
 * À appeler avant toute séquence de DPR pour repartir d'un état propre. */
static void hwicap_rcrc_desync(void) {
    static const uint32_t s[] = {
        0xFFFFFFFF, 0xFFFFFFFF,
        0xAA995566, 0x20000000,
        0x30008001, 0x00000007,  /* CMD RCRC */
        0x20000000,
        0x30008001, 0x0000000D,  /* CMD DESYNC */
        0x20000000, 0x20000000,
    };
    hwicap_send_raw(s, sizeof(s)/sizeof(s[0]));
}

/* Masque les bits de version IDCODE [31:28] pour éviter ID_ERROR
 * quand le bitstream partiel embarque IDCODE=0x03651093 (version=0)
 * et que le device répond 0x43651093 (version=4). */
static void hwicap_set_idcode_mask(void) {
    static const uint32_t s[] = {
        0xFFFFFFFF, 0xFFFFFFFF,
        0xAA995566, 0x20000000,
        0x3000C001, 0xF0000000,  /* Type1 Write MASK */
        0x20000000, 0x20000000,
        0x30008001, 0x0000000D,  /* CMD DESYNC */
        0x20000000, 0x20000000,
    };
    hwicap_send_raw(s, sizeof(s)/sizeof(s[0]));
}

/* Écrit un bitstream .bin (GDB restore depuis DDR) chunk par chunk.
 * - bswap32 appliqué : octets DDR little-endian → mots WF valides pour ICAP
 * - fifo_reset avant chaque chunk : FIFO propre = pas d'accumulation d'état */
static int hwicap_write_bitstream(const uint32_t *data, uint32_t size_words, uint32_t decouple_mask) {
    mmio_write32(GPIO_TRI,  0x00000000u);
    mmio_write32(GPIO_DATA, mmio_read32(GPIO_DATA) | decouple_mask);

    print_status("debut write_bitstream");

    const uint32_t nchunks = (size_words + HWICAP_WFV_MAX - 1) / HWICAP_WFV_MAX;
    for (uint32_t ci = 0; ci < nchunks; ci++) {
        uint32_t offset = ci * HWICAP_WFV_MAX;
        uint32_t chunk  = size_words - offset;
        if (chunk > HWICAP_WFV_MAX) chunk = HWICAP_WFV_MAX;

        hwicap_fifo_reset();
        mmio_write32(HWICAP_SZ, chunk);
        for (uint32_t i = 0; i < chunk; i++)
            mmio_write32(HWICAP_WF, bswap32(data[offset + i]));
        mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);

        int timeout = HWICAP_TIMEOUT;
        while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && timeout-- > 0);
        if (timeout <= 0) {
            printf("[HWICAP] ERROR: timeout chunk %u\n", (unsigned int)ci);
            print_status("timeout CR");
            mmio_write32(GPIO_DATA, mmio_read32(GPIO_DATA) & ~decouple_mask);
            return -1;
        }
    }

    mmio_write32(GPIO_DATA, mmio_read32(GPIO_DATA) & ~decouple_mask);

    print_status("fin write_bitstream");
    printf("[HWICAP DEBUG] Finished write_bitstream (%u words, %u chunks)\n",
           (unsigned int)size_words, (unsigned int)nchunks);
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
        0x28018001,              // Type 1 Read IDCODE (reg 12), 1 word
        0x20000000, 0x20000000,
        0x20000000, 0x20000000,
    };
    uint32_t n = sizeof(seq)/sizeof(seq[0]);
    mmio_write32(HWICAP_SZ, n);
    print_status("avant sequence IDCODE");
    for (uint32_t i=0;i<n;i++)
        mmio_write32(HWICAP_WF, seq[i]);
    mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);

    int t = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && t-- > 0);
    print_status("apres write IDCODE");
    for (volatile int i=0;i<100000;i++);
    mmio_write32(HWICAP_SZ, 1);
    mmio_write32(HWICAP_CR, HWICAP_CR_READ);
    t = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_READ) && t-- > 0);
    print_status("apres read IDCODE");
    uint32_t idcode = mmio_read32(HWICAP_RF);
    printf("[HWICAP] IDCODE = 0x%08x (attendu 0x43651093) -> %s\n",
           (unsigned int)idcode,
           idcode==0x43651093 ? "OK":"FAIL");

    // DESYNC : remet l'ICAP en IDLE avant toute écriture de bitstream
    static const uint32_t desync_seq[] = {
        0x20000000,
        0x30008001, 0x0000000D,  // CMD = DESYNC
        0x20000000, 0x20000000,
    };
    uint32_t nd = sizeof(desync_seq)/sizeof(desync_seq[0]);
    hwicap_fifo_reset();
    mmio_write32(HWICAP_SZ, nd);
    for (uint32_t i=0;i<nd;i++)
        mmio_write32(HWICAP_WF, desync_seq[i]);
    mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);
    t = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && t-- > 0);
    print_status("apres desync");
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

    /* Pré-DPR : effacer CFGERR résiduel du boot, puis masquer version IDCODE.
     * Sans set_idcode_mask, chaque PR déclenche ID_ERROR (version 4 vs 0)
     * et le CFGERR accumulé finit par faire ignorer les bitstreams suivants. */
    printf("[DEMO] RCRC+DESYNC...\n");
    hwicap_rcrc_desync();
    printf("[DEMO] MASK IDCODE version bits...\n");
    hwicap_set_idcode_mask();

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
        if (hwicap_write_bitstream(bs1, DPR_BS_ACCEL1_WORDS, DECOUPLE_ACCEL1) != 0) {
            printf("[ROUND %d] ERREUR accel1 — abandon\n", round);
            return;
        }

        printf("[ROUND %d] Accel2...\n", round);
        if (hwicap_write_bitstream(bs2, DPR_BS_ACCEL2_WORDS, DECOUPLE_ACCEL2) != 0) {
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