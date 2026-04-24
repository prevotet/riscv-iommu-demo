#include <stdint.h>
#include <stdio.h>

/* HWICAP Register Map */
#define HWICAP_BASE  0x40010000ULL
#define HWICAP_GIER  (HWICAP_BASE + 0x1C)
#define HWICAP_ASR   (HWICAP_BASE + 0x120)
#define HWICAP_WF    (HWICAP_BASE + 0x100)
#define HWICAP_RF    (HWICAP_BASE + 0x104)
#define HWICAP_SZ    (HWICAP_BASE + 0x108)
#define HWICAP_CR    (HWICAP_BASE + 0x10C)
#define HWICAP_SR    (HWICAP_BASE + 0x110)
#define HWICAP_WFV   (HWICAP_BASE + 0x114)
#define HWICAP_RFO   (HWICAP_BASE + 0x118)

/* ICAP Opcodes/Commands */
#define SYNC_WORD       0xAA995566
#define NOOP            0x20000000
#define TYPE1_RD_STAT   0x2800E001  /* Read STAT (Reg 7) */
#define TYPE1_RD_IDCODE 0x28018001  /* Read IDCODE (Reg 12) */

#define TIMEOUT      2000000

/* Primitives MMIO avec barrières pour CVA6 */
static inline void wait_cycles(uint32_t n) {
    for (volatile uint32_t i = 0; i < n; i++);
}

static inline uint32_t mmio_r(uint64_t a) {
    uint32_t v;
    asm volatile("fence i,r" ::: "memory");
    v = *(volatile uint32_t *)a;
    return v;
}

static inline void mmio_w(uint64_t a, uint32_t v) {
    *(volatile uint32_t *)a = v;
    asm volatile("fence w,o" ::: "memory");
}

/* Reset de la FIFO */
static void hwicap_reset_fifo(void) {
    mmio_w(HWICAP_CR, 0x04); /* FIFO_RST */
    int t = TIMEOUT;
    while (mmio_r(HWICAP_WFV) < 0x3F && t-- > 0);
    mmio_w(HWICAP_CR, 0);
}

/* Envoi d'une séquence brute */
static int send_raw_seq(const uint32_t *seq, uint32_t n) {
    hwicap_reset_fifo();
    mmio_w(HWICAP_SZ, n);
    for (uint32_t i = 0; i < n; i++) mmio_w(HWICAP_WF, seq[i]);
    mmio_w(HWICAP_CR, 0x01); /* WRITE */
    
    int t = TIMEOUT;
    while ((mmio_r(HWICAP_CR) & 0x01) && t-- > 0);
    return (t <= 0) ? -1 : 0;
}

/* Lecture d'un mot dans la RF */
static uint32_t read_rf_word(void) {
    mmio_w(HWICAP_SZ, 1);
    mmio_w(HWICAP_CR, 0x02); /* READ */
    int t = TIMEOUT;
    while ((mmio_r(HWICAP_CR) & 0x02) && t-- > 0);
    if (t <= 0) return 0xDEADBEEF;
    return mmio_r(HWICAP_RF);
}

void dpr2_test(void) {
    printf("\r\n--- HWICAP HARDWARE PURE TEST (DPR2) ---\r\n");

    /* TEST 0: IP Internal Logic Check */
    printf("0. IP Internal Check:\r\n");
    mmio_w(HWICAP_GIER, 0x80000000); /* Enable Global Interrupts (bit 31) */
    uint32_t gier = mmio_r(HWICAP_GIER);
    printf("   GIER R/W Test: 0x%08x (Expected 0x80000000)\r\n", (unsigned)gier);
    
    uint32_t asr = mmio_r(HWICAP_ASR);
    printf("   ASR (Abort Status): 0x%08x (Expected 0x00000000)\r\n", (unsigned)asr);
    if (asr != 0) {
        printf("   [WARN] IP was in ABORT state. Clearing...\r\n");
        mmio_w(HWICAP_CR, 0x08); /* SW_RESET / Abort Clear */
    }

    /* TEST 1: AXI Connectivity & Initial State */
    uint32_t sr = mmio_r(HWICAP_SR);
    uint32_t wfv = mmio_r(HWICAP_WFV);
    uint32_t rfo = mmio_r(HWICAP_RFO);
    printf("1. AXI Check:\r\n");
    printf("   SR  = 0x%08x (Expected 0x...5)\r\n", (unsigned)sr);
    printf("   WFV = 0x%08x (Expected 0x0000003F)\r\n", (unsigned)wfv);
    printf("   RFO = 0x%08x (Expected 0x00000000)\r\n", (unsigned)rfo);
    
    if ((sr & 0x7) != 0x05) {
        printf("   [FAIL] HWICAP IP not in IDLE state. Check bitstream/clocks.\r\n");
    } else {
        printf("   [OK] AXI Bridge & IP Status registers reachable.\r\n");
    }

    /* TEST 2: FIFO Write/Read Back Mechanism */
    hwicap_reset_fifo();
    mmio_w(HWICAP_WF, 0x55AA55AA);
    uint32_t wfv_after = mmio_r(HWICAP_WFV);
    printf("2. FIFO Check:\r\n");
    printf("   WFV after 1 word = 0x%x (Expected 0x3E)\r\n", (unsigned)wfv_after);
    if (wfv_after == 0x3E) {
        printf("   [OK] Write FIFO is decrementing correctly.\r\n");
    } else {
        printf("   [FAIL] Write FIFO behavior abnormal.\r\n");
    }

    /* TEST 3: ICAP Sync & Status Register Readback */
    /* 
     * Sequence: 
     * [0..1] Dummy Words
     * [2] Sync Word
     * [3] NOOP
     * [4] Read STAT Type 1 (Reg 7)
     * [5..8] 4 NOOPs (Mandatory for ICAP Read Pipeline)
     * [9..10] DESYNC
     */
    static const uint32_t stat_seq[] = {
        0xFFFFFFFF, 0xFFFFFFFF, 
        SYNC_WORD,
        NOOP,
        TYPE1_RD_STAT,
        NOOP, NOOP, NOOP, NOOP,
        0x30008001, 0x0000000D,
        NOOP, NOOP
    };
    
    printf("3. ICAP STAT Readback:\r\n");
    if (send_raw_seq(stat_seq, 13) < 0) {
        printf("   [FAIL] Sequence Write Timeout.\r\n");
    } else {
        /* On observe le Status Byte dans SR (poussé par l'IP à chaque transaction) */
        uint8_t status_byte = (uint8_t)(mmio_r(HWICAP_SR) & 0xFF);
        printf("   Status Byte (SR bits 0-7): 0x%02x\r\n", status_byte);
        printf("     - DALIGN: %d\r\n", (status_byte >> 3) & 1); /* Bit 3 of status byte */
        
        uint32_t stat_reg = read_rf_word();
        printf("   STAT Register (Reg 7): 0x%08x\r\n", (unsigned)stat_reg);
        if (stat_reg != 0xDEADBEEF) {
            printf("     - CFGERR: %d\r\n", (stat_reg >> 12) & 1);
            printf("     - DALIGN: %d\r\n", (stat_reg >> 15) & 1);
            printf("     - IDCODE_ERR: %d\r\n", (stat_reg >> 10) & 1);
            printf("     - DONE: %d\r\n", (stat_reg >> 9) & 1);
            if ((stat_reg >> 15) & 1) printf("   [OK] ICAP is Synchronized.\r\n");
            else printf("   [FAIL] ICAP NOT Synchronized.\r\n");
        }
    }

    /* TEST 4: IDCODE Verification */
    static const uint32_t id_seq[] = {
        0xFFFFFFFF, 0xFFFFFFFF,
        SYNC_WORD,
        NOOP,
        TYPE1_RD_IDCODE,
        NOOP, NOOP, NOOP, NOOP,
        0x30008001, 0x0000000D,
        NOOP, NOOP
    };

    printf("4. ICAP IDCODE Verification:\r\n");
    send_raw_seq(id_seq, 13);
    uint32_t idcode = read_rf_word();
    printf("   Read IDCODE: 0x%08x\r\n", (unsigned)idcode);
    
    uint32_t masked_id = idcode & 0x0FFFFFFF;
    if (masked_id == 0x03651093) {
        printf("   [MATCH] Kintex-7 (XC7K325T) detected.\r\n");
    } else {
        printf("   [MISMATCH] Expected 0x*3651093. Check if correct device is targeted.\r\n");
    }

    /* TEST 5: Advanced Timing & Stress */
    printf("5. Performance & Stress Test:\r\n");
    {
        uint64_t t0, t1, t2;
        hwicap_reset_fifo();
        
        /* Mesure 5.1 : Remplissage FIFO (CPU -> AXI) */
        asm volatile("rdcycle %0" : "=r"(t0));
        for(int i=0; i<63; i++) {
            *(volatile uint32_t *)HWICAP_WF = 0x20000000; /* NOOP */
        }
        asm volatile("fence w,o" ::: "memory");
        asm volatile("rdcycle %0" : "=r"(t1));
        
        /* Mesure 5.2 : Vidage FIFO (IP -> ICAP) */
        mmio_w(HWICAP_SZ, 63);
        mmio_w(HWICAP_CR, 0x01); /* WRITE */
        while (mmio_r(HWICAP_CR) & 0x01);
        asm volatile("rdcycle %0" : "=r"(t2));

        uint64_t fill_cycles = t1 - t0;
        uint64_t drain_cycles = t2 - t1;

        /* Fix: Use %u and cast/split to avoid formatting issues on some printf implementations */
        printf("   - CPU-to-FIFO (63 words): %u cycles\r\n", (unsigned int)fill_cycles);
        printf("   - FIFO-to-ICAP (63 words): %u cycles\r\n", (unsigned int)drain_cycles);
        
        if (drain_cycles > 0 && fill_cycles > 0) {
            printf("   - Speeds: CPU=%u cy/w, ICAP=%u cy/w\r\n", 
                   (unsigned int)(fill_cycles/63), (unsigned int)(drain_cycles/63));
        }
        
        /* Diagnostic de saturation */
        if (drain_cycles < fill_cycles) {
            printf("   -> Note: CPU is the bottleneck.\r\n");
        } else {
            printf("   -> Note: ICAP/Bridge is the bottleneck.\r\n");
        }
    }

    /* TEST 6: Protocol & Handshake (ACKs) */
    printf("6. Protocol & Handshake Validation:\r\n");
    {
        /* 6.1 Check DALIGN transition */
        hwicap_reset_fifo();
        static const uint32_t noop_seq[] = { NOOP, NOOP, NOOP, NOOP, NOOP, NOOP };
        send_raw_seq(noop_seq, 6);
        uint8_t sb1 = (uint8_t)(mmio_r(HWICAP_SR) & 0xFF);
        printf("   - Status after NOOPs: 0x%02x (DALIGN expected 0)\r\n", sb1);

        static const uint32_t sync_seq[] = { 
            0xFFFFFFFF, 0xFFFFFFFF, 
            SYNC_WORD, 
            NOOP, NOOP 
        };
        send_raw_seq(sync_seq, 5);
        uint8_t sb2 = (uint8_t)(mmio_r(HWICAP_SR) & 0xFF);
        printf("   - Status after SYNC:  0x%02x (DALIGN bit 3 expected 1)\r\n", sb2);

        if ((sb2 >> 3) & 1) {
            printf("   [OK] Protocol Handshake: ICAP ACKs Synchronization.\r\n");
        } else {
            printf("   [FAIL] Protocol Violation: ICAP is deaf to SYNC.\r\n");
        }

        /* 6.2 Full Cleanup (RCRC + DESYNC) to clear CFGERR */
        printf("   - Sending Full Cleanup (RCRC + DESYNC)...\r\n");
        static const uint32_t cleanup_seq[] = {
            0xFFFFFFFF, SYNC_WORD,
            NOOP,
            0x30008001, 0x00000007, /* CMD RCRC */
            NOOP, NOOP,
            0x30008001, 0x0000000D, /* CMD DESYNC */
            NOOP, NOOP, NOOP, NOOP
        };
        send_raw_seq(cleanup_seq, 13);
        uint8_t sb3 = (uint8_t)(mmio_r(HWICAP_SR) & 0xFF);
        printf("   - Status after Cleanup: 0x%02x (CFGERR bit 2 should be 0)\r\n", sb3);
    }

    /* TEST 7: Endianness Discovery */
    printf("7. Endianness Discovery:\r\n");
    {
        /* 7.1 Register R/W check */
        uint32_t pattern = 0x11223344;
        mmio_w(HWICAP_SZ, pattern);
        uint32_t readback = mmio_r(HWICAP_SZ);
        printf("   - Register Write: 0x%08x -> Readback: 0x%08x\r\n", (unsigned)pattern, (unsigned)readback);
        
        if (readback == pattern) {
            printf("     [OK] 32-bit Word order preserved (No byte-swap in Bridge).\r\n");
        } else if (readback == 0x44332211) {
            printf("     [INFO] Bridge/Bus is performing a Byte-Swap.\r\n");
        } else {
            printf("     [FAIL] Data corruption or bits dropped.\r\n");
        }

        /* 7.2 SYNC Orientation Check */
        printf("   - Testing SYNC orientations (checking DALIGN):\r\n");
        
        // Try Native
        hwicap_reset_fifo();
        static const uint32_t native_sync[] = { 0xFFFFFFFF, 0xAA995566, NOOP };
        send_raw_seq(native_sync, 3);
        uint8_t sb_native = (uint8_t)(mmio_r(HWICAP_SR) & 0xFF);
        printf("     * Native (0xAA995566) DALIGN = %d\r\n", (sb_native >> 3) & 1);

        // Try Byte-Swapped
        hwicap_reset_fifo();
        static const uint32_t swapped_sync[] = { 0xFFFFFFFF, 0x665599AA, NOOP };
        send_raw_seq(swapped_sync, 3);
        uint8_t sb_swapped = (uint8_t)(mmio_r(HWICAP_SR) & 0xFF);
        printf("     * Swapped (0x665599AA) DALIGN = %d\r\n", (sb_swapped >> 3) & 1);

        if ((sb_native >> 3) & 1) {
            printf("   -> CONCLUSION: Hardware expects NATIVE words (CPU matches ICAP).\r\n");
        } else if ((sb_swapped >> 3) & 1) {
            printf("   -> CONCLUSION: Hardware expects SWAPPED words (Bridge/IP inverts bytes).\r\n");
        } else {
            printf("   -> CONCLUSION: Neither worked. Check clocks or core reset.\r\n");
        }
    }

    printf("--- DPR2 Test Complete ---\r\n");
}
