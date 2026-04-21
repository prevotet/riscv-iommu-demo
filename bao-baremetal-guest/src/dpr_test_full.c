/**
 * dpr_test_full.c — Démo DPR ping-pong Single VM sous BAO
 *
 * Inspiré de dpr_test.c (standalone) adapté pour la config cva6-dpr-baremetal.
 * Tourne en S-mode sous BAO — pas d'override arch_init().
 * Les IDs accels sont lus uniquement après les deux reconfigurations.
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

#define ACCEL1_BASE  0x50000000ULL
#define ACCEL2_BASE  0x50001000ULL

/* =========================================================================
 * Override arch_init — pas d'interruptions pour ce guest polling
 * Identique à dpr_test.c : évite que plic_init() + sie/sstatus interfèrent
 * avec les longues séquences HWICAP (534K mots = plusieurs dizaines de ms)
 * ========================================================================= */

void arch_init(void) {}

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

/

/* =========================================================================
 * Diagnostics HWICAP (repris de dpr_test.c)
 * ========================================================================= */

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
 * Pilote HWICAP (repris de dpr_test.c)
 * ========================================================================= */

static void hwicap_fifo_reset(void) {
    mmio_write32(HWICAP_CR, HWICAP_CR_FIFO_RST);
    int timeout = HWICAP_TIMEOUT;
    while (mmio_read32(HWICAP_WFV) < HWICAP_WFV_MAX && timeout-- > 0);
    mmio_write32(HWICAP_CR, 0x00u);
    printf("[HWICAP] FIFO reset : WFV=0x%02x\r\n",
           (unsigned int)mmio_read32(HWICAP_WFV));
}

static int hwicap_write_bitstream(const uint32_t *data, uint32_t size_words) {
    hwicap_fifo_reset();
    print_status("debut write_bitstream");

    uint32_t written = 0;

    while (written < size_words) {
        uint32_t chunk = size_words - written;
        if (chunk > HWICAP_WFV_MAX) chunk = HWICAP_WFV_MAX;

        mmio_write32(HWICAP_SZ, chunk);

        uint32_t sent = 0;
        while (sent < chunk) {
            int timeout = HWICAP_TIMEOUT;
            while (mmio_read32(HWICAP_WFV) == 0 && timeout-- > 0);
            if (timeout <= 0) {
                printf("[HWICAP] ERROR: timeout WFV mot %u\r\n",
                       (unsigned int)(written + sent));
                print_status("timeout WFV");
                return -1;
            }

            uint32_t vacancy = mmio_read32(HWICAP_WFV);
            uint32_t to_write = chunk - sent;
            if (to_write > vacancy) to_write = vacancy;

            for (uint32_t i = 0; i < to_write; i++)
                mmio_write32(HWICAP_WF, data[written + sent++]);
        }

        mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);

        int timeout = HWICAP_TIMEOUT;
        while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && timeout-- > 0);
        if (timeout <= 0) {
            printf("[HWICAP] ERROR: timeout CR mot %u\r\n", (unsigned int)written);
            print_status("timeout CR");
            return -1;
        }

        written += chunk;
    }

    print_status("fin write_bitstream");
    printf("[HWICAP] %u mots envoyés\r\n", (unsigned int)size_words);
    return 0;
}

/* =========================================================================
 * Lecture IDCODE via ICAP — vérifie que l'ICAP communique avec le FPGA
 * Repris de dpr_test.c
 * ========================================================================= */

static void hwicap_read_idcode(void) {
    printf("\r\n[HWICAP] Lecture IDCODE FPGA\r\n");
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
    for (uint32_t i = 0; i < n; i++)
        mmio_write32(HWICAP_WF, seq[i]);
    mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);
    int t = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && t-- > 0);

    for (volatile int i = 0; i < 100000; i++);

    mmio_write32(HWICAP_SZ, 1);
    mmio_write32(HWICAP_CR, HWICAP_CR_READ);
    t = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_READ) && t-- > 0);

    uint32_t idcode = mmio_read32(HWICAP_RF);
    printf("[HWICAP] IDCODE = 0x%08x (attendu 0x0362D093) -> %s\r\n",
           (unsigned int)idcode,
           idcode == 0x0362D093 ? "OK" : "FAIL");

    // DESYNC : remet l'ICAP en état IDLE avant toute écriture de bitstream
    static const uint32_t desync_seq[] = {
        0x20000000,  // NOOP
        0x30008001,  // Type 1 Write 1 word → CMD register
        0x0000000D,  // DESYNC
        0x20000000,  // NOOP
        0x20000000,  // NOOP
    };
    uint32_t nd = sizeof(desync_seq)/sizeof(desync_seq[0]);
    hwicap_fifo_reset();
    mmio_write32(HWICAP_SZ, nd);
    for (uint32_t i = 0; i < nd; i++)
        mmio_write32(HWICAP_WF, desync_seq[i]);
    mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);
    int td = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && td-- > 0);
}

/* =========================================================================
 * Test Ping-Pong
 * Inspiré de dpr_test.c : lecture des IDs accel APRÈS les deux reconfigurations
 * ========================================================================= */

#define NB_ROUNDS 4

void run_demo(void) {
    printf("[DEMO] Début du test ping-pong (%d rounds)\r\n\r\n", NB_ROUNDS);

    for (int round = 0; round < NB_ROUNDS; round++) {
        uint32_t rm_id   = (round % 2 == 0) ? DPR_RM_ACCEL_A : DPR_RM_ACCEL_B;
        const char *name = (rm_id == DPR_RM_ACCEL_A) ? "accel_A" : "accel_B";

        printf("[ROUND %d] Reconfiguration vers %s\r\n", round, name);

        uint64_t bs1 = (rm_id == DPR_RM_ACCEL_A) ? DPR_BS_ACCEL1_A_PA : DPR_BS_ACCEL1_B_PA;
        uint64_t bs2 = (rm_id == DPR_RM_ACCEL_A) ? DPR_BS_ACCEL2_A_PA : DPR_BS_ACCEL2_B_PA;

        printf("[ROUND %d] Accel1...\r\n", round);
        if (hwicap_write_bitstream((const uint32_t *)bs1, DPR_BS_ACCEL1_WORDS) != 0) {
            printf("[ROUND %d] ERREUR accel1 — abandon\r\n", round);
            return;
        }

        printf("[ROUND %d] Accel2...\r\n", round);
        if (hwicap_write_bitstream((const uint32_t *)bs2, DPR_BS_ACCEL2_WORDS) != 0) {
            printf("[ROUND %d] ERREUR accel2 — abandon\r\n", round);
            return;
        }

        /* Délai post-DPR : laisse le temps au RM de stabiliser son AXI slave */
        for (volatile int i = 0; i < 5000000; i++);

        /* Lecture des IDs après les DEUX reconfigurations + stabilisation */
        asm volatile("fence i, r" ::: "memory");
        uint32_t id1_lo = mmio_read32(ACCEL1_BASE);
        uint32_t id1_hi = mmio_read32(ACCEL1_BASE + 4);
        uint32_t id2_lo = mmio_read32(ACCEL2_BASE);
        uint32_t id2_hi = mmio_read32(ACCEL2_BASE + 4);

        printf("[ROUND %d] Accel1 ID: 0x%08x%08x\r\n", round, id1_hi, id1_lo);
        printf("[ROUND %d] Accel2 ID: 0x%08x%08x\r\n", round, id2_hi, id2_lo);

        uint32_t expected = (rm_id == DPR_RM_ACCEL_A) ? 0xAAAAAAu : 0xBBBBBBu;
        if ((id1_lo & 0xFFFFFFu) == expected && (id2_lo & 0xFFFFFFu) == expected)
            printf("[ROUND %d] [OK] %s détecté\r\n\r\n", round, name);
        else
            printf("[ROUND %d] [FAIL] IDs inattendus\r\n\r\n", round);

        for (volatile int i = 0; i < 2000000; i++);
    }

    printf("[DEMO] Test terminé.\r\n");
}

/* =========================================================================
 * Point d'entrée
 * ========================================================================= */

void main(void) {
    if (!cpu_is_master()) {
        while (1) wfi();
    }

    printf("\r\n");
    printf("##############################################\r\n");
    printf("#   DPR Single VM Demo — RISC-V IOMMU       #\r\n");
    printf("##############################################\r\n\r\n");

    hwicap_diag();
    hwicap_read_idcode();
    /* Note : pas de lecture accel avant DPR — le RM initial (accel_blank)
     * retourne SLVERR ce qui lève une exception sous BAO S-mode.
     * Les accels ne sont lisibles qu'après une DPR réussie vers accel_A ou accel_B. */

    run_demo();

    while (1) wfi();
}
