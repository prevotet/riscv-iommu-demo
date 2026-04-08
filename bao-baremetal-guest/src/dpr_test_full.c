/**
 * dpr_test_full.c — Démo DPR complète en une seule VM (Baremetal)
 *
 * Cette VM fusionne le rôle de Manager et de Client pour fonctionner
 * sur des systèmes monocœurs sans scheduler complexe.
 */

#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <cpu.h>
#include <wfi.h>
#include <uart.h>

#include "dpr_ipc.h"

/* =========================================================================
 * Constantes HWICAP & Accélérateurs
 * ========================================================================= */

#define HWICAP_BASE   0x40010000ULL
#define HWICAP_WF     (HWICAP_BASE + 0x100)
#define HWICAP_SZ     (HWICAP_BASE + 0x108)
#define HWICAP_CR     (HWICAP_BASE + 0x10C)
#define HWICAP_SR     (HWICAP_BASE + 0x110)
#define HWICAP_WFV    (HWICAP_BASE + 0x114)

#define HWICAP_CR_WRITE    0x01u
#define HWICAP_CR_FIFO_RST 0x04u
#define HWICAP_WFV_MAX     0x3Fu
#define HWICAP_TIMEOUT     10000000

#define ACCEL1_BASE  0x50000000ULL
#define ACCEL2_BASE  0x50001000ULL

/* =========================================================================
 * Helpers MMIO & Cycles
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

static inline uint64_t read_cycles(void) {
    /* 
     * rdcycle peut provoquer une exception 22 (Virtual Instruction) 
     * si BAO ne l'autorise pas explicitement dans hcounteren.
     * On retourne 0 pour l'instant pour valider le flux HWICAP.
     */
    return 0;
}

/* =========================================================================
 * Pilote HWICAP
 * ========================================================================= */

static void hwicap_reset(void) {
    mmio_write32(HWICAP_CR, HWICAP_CR_FIFO_RST);
    int t = HWICAP_TIMEOUT;
    while (mmio_read32(HWICAP_WFV) < HWICAP_WFV_MAX && t-- > 0);
    mmio_write32(HWICAP_CR, 0x00u);
}

static uint32_t hwicap_load_bs(const uint32_t *data, uint32_t size_words, uint64_t *cycles_out) {
    hwicap_reset();
    uint64_t t0 = read_cycles();
    uint32_t written = 0;

    while (written < size_words) {
        uint32_t chunk = size_words - written;
        if (chunk > HWICAP_WFV_MAX) chunk = HWICAP_WFV_MAX;

        mmio_write32(HWICAP_SZ, chunk);
        for (uint32_t i = 0; i < chunk; i++) {
            while (mmio_read32(HWICAP_WFV) == 0);
            mmio_write32(HWICAP_WF, data[written++]);
        }

        mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);
        while (mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE);
    }

    *cycles_out = read_cycles() - t0;
    return 0;
}

/* =========================================================================
 * Utilitaires État
 * ========================================================================= */

static void check_accel_state(int idx) {
    uint64_t base = (idx == 1) ? ACCEL1_BASE : ACCEL2_BASE;
    uint32_t lo = mmio_read32(base);
    uint32_t hi = mmio_read32(base + 4);
    uint32_t suffix = lo & 0xFFFFFFu;
    const char *name = (suffix == 0xAAAAAAu) ? "ACCEL_A" : 
                       (suffix == 0xBBBBBBu) ? "ACCEL_B" : "DEFAULT";
    printf("[DPR] Accel%d ID: 0x%08x%08x -> %s\n", idx, hi, lo, name);
}

/* =========================================================================
 * Test Ping-Pong Direct
 * ========================================================================= */

#define NB_ROUNDS 4

void run_demo(void) {
    printf("[DEMO] Début du test ping-pong (%d rounds)\n\n", NB_ROUNDS);

    for (int round = 0; round < NB_ROUNDS; round++) {
        uint32_t rm_id = (round % 2 == 0) ? DPR_RM_ACCEL_A : DPR_RM_ACCEL_B;
        const char *rm_name = (rm_id == DPR_RM_ACCEL_A) ? "accel_A" : "accel_B";

        printf("[ROUND %d] Reconfiguration vers %s...\n", round, rm_name);

        /* Accel 1 */
        uint64_t cy1;
        uint64_t bs1_addr = (rm_id == DPR_RM_ACCEL_A) ? DPR_BS_ACCEL1_A_PA : DPR_BS_ACCEL1_B_PA;
        hwicap_load_bs((uint32_t*)bs1_addr, DPR_BS_ACCEL1_WORDS, &cy1);
        printf("[DEMO] Accel1 reconfiguré en %lu cycles.\n", cy1);
        check_accel_state(1);

        /* Accel 2 */
        uint64_t cy2;
        uint64_t bs2_addr = (rm_id == DPR_RM_ACCEL_A) ? DPR_BS_ACCEL2_A_PA : DPR_BS_ACCEL2_B_PA;
        hwicap_load_bs((uint32_t*)bs2_addr, DPR_BS_ACCEL2_WORDS, &cy2);
        printf("[DEMO] Accel2 reconfiguré en %lu cycles.\n", cy2);
        check_accel_state(2);

        printf("\n");
        for (volatile int i = 0; i < 2000000; i++); /* Pause */
    }

    printf("[DEMO] Test terminé.\n");
}

/* =========================================================================
 * Point d'entrée
 * ========================================================================= */

void main(void) {
    if (!cpu_is_master()) {
        while (1) wfi();
    }

    printf("\n");
    printf("##############################################\n");
    printf("#   DPR Single VM Demo — RISC-V IOMMU       #\n");
    printf("##############################################\n\n");

    /* Diagnostic initial */
    uint32_t sr = mmio_read32(HWICAP_SR);
    printf("[DPR] HWICAP SR: 0x%08x\n", sr);

    run_demo();

    while (1) wfi();
}
