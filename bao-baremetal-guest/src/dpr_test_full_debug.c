/**
 * dpr_test_full_debug.c — Démo DPR ping-pong Single VM sous BAO
 *
 * Version ultra-robuste avec patch IDCODE en DDR.
 */

#include <stdint.h>
#include <stdio.h>
#include <cpu.h>
#include <wfi.h>

#include "dpr_ipc.h"

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

#define GPIO_BASE       0x40000000ULL
#define GPIO_DATA       (GPIO_BASE + 0x00)
#define GPIO_TRI        (GPIO_BASE + 0x04)
#define DECOUPLE_ACCEL1 (1u << 31)
#define DECOUPLE_ACCEL2 (1u << 30)

#define ACCEL1_BASE 0x50000000ULL
#define ACCEL2_BASE 0x50001000ULL

#define NB_ROUNDS 4

static inline uint32_t bswap32(uint32_t x) {
    return ((x & 0xFF000000u) >> 24)
         | ((x & 0x00FF0000u) >>  8)
         | ((x & 0x0000FF00u) <<  8)
         | ((x & 0x000000FFu) << 24);
}

static inline uint32_t mmio_read32(uint64_t addr) {
    uint32_t val;
    asm volatile ("fence i, r" ::: "memory");
    val = *(volatile uint32_t *)addr;
    return val;
}

static inline void mmio_write32(uint64_t addr, uint32_t val) {
    *(volatile uint32_t *)addr = val;
    asm volatile ("fence w, o" ::: "memory");
}

void arch_init(void) {}

static void hwicap_fifo_reset(void) {
    mmio_write32(HWICAP_CR, HWICAP_CR_FIFO_RST);
    int timeout = HWICAP_TIMEOUT;
    while (mmio_read32(HWICAP_WFV) < HWICAP_WFV_MAX && timeout-- > 0);
    mmio_write32(HWICAP_CR, 0x00u);
}

static void hwicap_send_raw(const uint32_t *w, uint32_t n) {
    hwicap_fifo_reset();
    mmio_write32(HWICAP_SZ, n);
    for (uint32_t i = 0; i < n; i++)
        mmio_write32(HWICAP_WF, w[i]);
    mmio_write32(HWICAP_CR, HWICAP_CR_WRITE);
    int timeout = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_WRITE) && timeout-- > 0);
}

static uint32_t hwicap_read_stat(void) {
    static const uint32_t seq[] = {
        0xFFFFFFFF, 0xFFFFFFFF, 0xAA995566, 0x20000000,
        0x2800E001, /* Type 1 Read STAT */
        0x20000000, 0x20000000, 0x20000000, 0x20000000,
    };
    hwicap_send_raw(seq, sizeof(seq)/sizeof(seq[0]));
    mmio_write32(HWICAP_SZ, 1);
    mmio_write32(HWICAP_CR, HWICAP_CR_READ);
    int t = HWICAP_TIMEOUT;
    while ((mmio_read32(HWICAP_CR) & HWICAP_CR_READ) && t-- > 0);
    uint32_t val = mmio_read32(HWICAP_RF);
    static const uint32_t ds[] = { 0x30008001, 0x0000000D, 0x20000000 };
    hwicap_send_raw(ds, 3);
    return val;
}

static void patch_idcode(uint32_t *data, uint32_t n) {
    uint32_t count = 0;
    for (uint32_t i = 0; i < n; i++) {
        if (data[i] == 0x93106503) {
            data[i] = 0x93106543;
            count++;
        }
    }
    if (count) printf("[PATCH] %u IDCODE patchés (0x03->0x43)\n", (unsigned)count);
}

static int hwicap_write_bitstream(const uint32_t *data, uint32_t size_words, uint32_t decouple_mask) {
    mmio_write32(GPIO_TRI,  0x00000000u);
    mmio_write32(GPIO_DATA, mmio_read32(GPIO_DATA) | decouple_mask);

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
        if (timeout <= 0) return -1;
    }

    mmio_write32(GPIO_DATA, mmio_read32(GPIO_DATA) & ~decouple_mask);
    return 0;
}

void run_demo(void) {
    printf("[DEMO] Début du test ping-pong\n");
    
    patch_idcode((uint32_t*)(uintptr_t)DPR_BS_ACCEL1_A_PA, DPR_BS_ACCEL1_WORDS);
    patch_idcode((uint32_t*)(uintptr_t)DPR_BS_ACCEL1_B_PA, DPR_BS_ACCEL1_WORDS);
    patch_idcode((uint32_t*)(uintptr_t)DPR_BS_ACCEL2_A_PA, DPR_BS_ACCEL2_WORDS);
    patch_idcode((uint32_t*)(uintptr_t)DPR_BS_ACCEL2_B_PA, DPR_BS_ACCEL2_WORDS);

    for (int round=0; round<NB_ROUNDS; round++) {
        uint32_t rm_id = (round%2==0) ? DPR_RM_ACCEL_A : DPR_RM_ACCEL_B;
        const char *name = (rm_id==DPR_RM_ACCEL_A) ? "accel_A" : "accel_B";

        printf("\n--- ROUND %d : %s ---\n", round, name);

        uint64_t bs1_pa = (rm_id==DPR_RM_ACCEL_A) ? DPR_BS_ACCEL1_A_PA : DPR_BS_ACCEL1_B_PA;
        uint64_t bs2_pa = (rm_id==DPR_RM_ACCEL_A) ? DPR_BS_ACCEL2_A_PA : DPR_BS_ACCEL2_B_PA;

        hwicap_write_bitstream((uint32_t*)(uintptr_t)bs1_pa, DPR_BS_ACCEL1_WORDS, DECOUPLE_ACCEL1);
        hwicap_write_bitstream((uint32_t*)(uintptr_t)bs2_pa, DPR_BS_ACCEL2_WORDS, DECOUPLE_ACCEL2);

        uint32_t stat = hwicap_read_stat();
        printf("[ICAP] STAT=0x%08x (ID_ERR=%d CFGERR=%d DONE=%d)\n", 
               (unsigned)stat, (stat>>2)&1, (stat>>4)&1, (stat>>14)&1);

        for (volatile int i=0; i<1000000; i++);
        uint32_t id1 = mmio_read32(ACCEL1_BASE);
        uint32_t id2 = mmio_read32(ACCEL2_BASE);
        printf("[ROUND %d] Accel1: 0x%08x  Accel2: 0x%08x\n", round, (unsigned)id1, (unsigned)id2);
        
        uint32_t expected = (rm_id==DPR_RM_ACCEL_A) ? 0xAAAAAAu : 0xBBBBBBu;
        if ((id1 & 0xFFFFFFu) == expected) printf("[OK] Accel1\n"); else printf("[FAIL] Accel1\n");
    }
}

void dpr_test_full_debug(void) {
    printf("\n##############################################\n");
    printf("#   DPR Single VM Demo — RISC-V IOMMU       #\n");
    printf("##############################################\n\n");
    run_demo();
}
