/**
 * dpr_test.c — Diagnostic matériel HWICAP/ICAP pas à pas
 *
 * Chaque test isole un niveau de la chaîne matérielle :
 *   T0 : Bridge AXI → registres HWICAP lisibles/écrivables
 *   T1 : FIFO Write — WFV décrémente mot par mot (accès WF confirmé)
 *   T2 : CR_WRITE timing — nombre de cycles CPU pour N mots → fréquence ICAP
 *   T3 : ICAP communication — IDCODE lu via config readback
 *   T4 : RFO après CR_WRITE — ICAP a-t-il sorti des données sur O[] ?
 *   T5 : Premier chunk bitstream — trace complète SR/WFV/RFO avant/après
 *   T6 : DPR complet — progress + timing par tranche de 500 chunks
 *   T7 : STAT ICAP après DPR — CFGERR / ID_ERROR / PART_DONE
 *   T8 : Accel1 ID avant et après — verdict final
 *
 * Convention bswap32 :
 *   Séquences manuelles : écrire les mots logiques directement (0xAA995566…)
 *   Bitstream .bin en DDR little-endian : bswap32() avant écriture dans WF
 */

#include <stdint.h>
#include <stdio.h>

/* =========================================================================
 * Adresses
 * ========================================================================= */

#define HWICAP_BASE  0x40010000ULL
#define HWICAP_WF    (HWICAP_BASE + 0x100)
#define HWICAP_RF    (HWICAP_BASE + 0x104)
#define HWICAP_SZ    (HWICAP_BASE + 0x108)
#define HWICAP_CR    (HWICAP_BASE + 0x10C)
#define HWICAP_SR    (HWICAP_BASE + 0x110)
#define HWICAP_WFV   (HWICAP_BASE + 0x114)
#define HWICAP_RFO   (HWICAP_BASE + 0x118)
#define HWICAP_ASR   (HWICAP_BASE + 0x120)  /* Abort Status Register */

#define ACCEL1_BASE  0x50000000ULL
#define BS1_ADDR     0x81000000ULL

/* partial_accel_B_accel1.bin — 3_build_B_dpr rebuild */
#define BS1_NWORDS   534823UL

#define CR_WRITE     0x01
#define CR_READ      0x02
#define CR_FIFO_RST  0x04
#define WFV_MAX      0x3F
#define TIMEOUT      2000000

/* =========================================================================
 * Primitives
 * ========================================================================= */

static inline uint32_t mmio_r(uint64_t a) {
    uint32_t v;
    asm volatile("fence i,r":::"memory");
    v = *(volatile uint32_t *)a;
    return v;
}
static inline void mmio_w(uint64_t a, uint32_t v) {
    *(volatile uint32_t *)a = v;
    asm volatile("fence w,o":::"memory");
}
static inline uint64_t cycle(void) {
    uint64_t c;
    asm volatile("rdcycle %0" : "=r"(c));
    return c;
}
static inline uint32_t bswap32(uint32_t x) {
    return ((x & 0xFFu) << 24) | ((x & 0xFF00u) << 8)
         | ((x >> 8) & 0xFF00u) | ((x >> 24) & 0xFFu);
}

/* =========================================================================
 * HWICAP helpers
 * ========================================================================= */

static void fifo_reset(void) {
    mmio_w(HWICAP_CR, CR_FIFO_RST);
    int t = TIMEOUT;
    while (mmio_r(HWICAP_WFV) < WFV_MAX && t-- > 0);
    mmio_w(HWICAP_CR, 0);
}

/* Envoie n mots logiques (pas de bswap), retourne cycles écoulés ou -1 si timeout */
static int64_t send_raw(const uint32_t *w, uint32_t n) {
    fifo_reset();
    mmio_w(HWICAP_SZ, n);
    for (uint32_t i = 0; i < n; i++) mmio_w(HWICAP_WF, w[i]);
    mmio_w(HWICAP_CR, CR_WRITE);
    uint64_t t0 = cycle();
    int t = TIMEOUT;
    while ((mmio_r(HWICAP_CR) & CR_WRITE) && t-- > 0);
    uint64_t dt = cycle() - t0;
    return (t <= 0) ? -1 : (int64_t)dt;
}

/* Envoie n mots depuis .bin DDR (bswap32 appliqué), retourne cycles ou -1 */
static int64_t send_bin(const uint32_t *d, uint32_t n) {
    mmio_w(HWICAP_SZ, n);
    for (uint32_t i = 0; i < n; i++) mmio_w(HWICAP_WF, bswap32(d[i]));
    mmio_w(HWICAP_CR, CR_WRITE);
    uint64_t t0 = cycle();
    int t = TIMEOUT;
    while ((mmio_r(HWICAP_CR) & CR_WRITE) && t-- > 0);
    uint64_t dt = cycle() - t0;
    return (t <= 0) ? -1 : (int64_t)dt;
}

static uint32_t read_rf(void) {
    for (volatile int i = 0; i < 50000; i++);
    mmio_w(HWICAP_SZ, 1);
    mmio_w(HWICAP_CR, CR_READ);
    int t = TIMEOUT;
    while ((mmio_r(HWICAP_CR) & CR_READ) && t-- > 0);
    return mmio_r(HWICAP_RF);
}

static void desync(void) {
    static const uint32_t s[] = {
        0xFFFFFFFF, 0xFFFFFFFF,
        0xAA995566, 0x20000000,
        0x30008001, 0x0000000D,
        0x20000000, 0x20000000,
    };
    send_raw(s, 8);
}

static uint32_t read_stat(void) {
    static const uint32_t s[] = {
        0xFFFFFFFF, 0xFFFFFFFF,
        0xAA995566, 0x20000000,
        0x2800E001,               /* Type1 Read STAT (reg 7) */
        0x20000000, 0x20000000, 0x20000000, 0x20000000,
    };
    send_raw(s, 9);
    uint32_t v = read_rf();
    desync();
    return v;
}

static uint32_t read_idcode(void) {
    static const uint32_t s[] = {
        0xFFFFFFFF, 0xFFFFFFFF,
        0xAA995566, 0x20000000,
        0x28018001,               /* Type1 Read IDCODE (reg 12) */
        0x20000000, 0x20000000, 0x20000000, 0x20000000,
    };
    send_raw(s, 9);
    uint32_t v = read_rf();
    desync();
    return v;
}

static void print_hwicap(const char *label) {
    printf("    %-20s SR=0x%02x  WFV=0x%02x  RFO=0x%02x  ASR=0x%08x\r\n", label,
           (unsigned)mmio_r(HWICAP_SR),
           (unsigned)mmio_r(HWICAP_WFV),
           (unsigned)mmio_r(HWICAP_RFO),
           (unsigned)mmio_r(HWICAP_ASR));
}

/* =========================================================================
 * Tests
 * ========================================================================= */

void dpr_test(void) {
    printf("\r\n============================================================\r\n");
    printf(" Diagnostic HWICAP/ICAP — DPR accel1\r\n");
    printf("============================================================\r\n");

    /* ------------------------------------------------------------------ */
    printf("\r\n[T0] Bridge AXI — registres HWICAP de base\r\n");
    print_hwicap("initial:");
    {
        uint32_t sr  = mmio_r(HWICAP_SR);
        uint32_t wfv = mmio_r(HWICAP_WFV);
        uint32_t rfo = mmio_r(HWICAP_RFO);
        int ok = (sr == 0x05) && (wfv == 0x3F) && (rfo == 0x00);
        printf("    SR=0x%02x (att 0x05)  WFV=0x%02x (att 0x3F)  RFO=0x%02x (att 0x00)  %s\r\n",
               (unsigned)sr, (unsigned)wfv, (unsigned)rfo,
               ok ? "[OK]" : "[WARN] valeurs inattendues — reprogram FPGA ?");
    }

    /* ------------------------------------------------------------------ */
    printf("\r\n[T1] FIFO Write — WFV décrémente mot par mot\r\n");
    {
        fifo_reset();
        printf("    WFV apres FIFO_RST = 0x%02x (att 0x3F)\r\n",
               (unsigned)mmio_r(HWICAP_WFV));

        /* Ecrire 4 mots sans CR_WRITE, observer WFV */
        mmio_w(HWICAP_SZ, 4);
        for (int i = 0; i < 4; i++) {
            mmio_w(HWICAP_WF, 0xFFFFFFFF);
            printf("    apres mot %d : WFV=0x%02x (att 0x%02x)\r\n",
                   i + 1, (unsigned)mmio_r(HWICAP_WFV), (unsigned)(0x3F - i - 1));
        }
        /* Envoyer et vider */
        mmio_w(HWICAP_CR, CR_WRITE);
        int t = TIMEOUT;
        while ((mmio_r(HWICAP_CR) & CR_WRITE) && t-- > 0);
        printf("    CR_WRITE complete : t_restant=%d  WFV=0x%02x  RFO=0x%02x\r\n",
               t, (unsigned)mmio_r(HWICAP_WFV), (unsigned)mmio_r(HWICAP_RFO));
        printf("    -> RFO apres 4 mots dummy : %s\r\n",
               mmio_r(HWICAP_RFO) > 0 ? "[ICAP sort des donnees en USER mode]"
                                       : "[RFO=0 — ICAP muet meme en USER mode]");
    }

    /* ------------------------------------------------------------------ */
    printf("\r\n[T2] CR_WRITE timing — cycles CPU par mot (fréquence ICAP)\r\n");
    {
        static const uint32_t dummy1[]  = { 0xFFFFFFFF };
        static const uint32_t dummy8[]  = {
            0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF,
            0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF };
        static const uint32_t dummy63[63];  /* zéros, inoffensifs avant SYNC */

        int64_t dt1  = send_raw(dummy1,  1);
        int64_t dt8  = send_raw(dummy8,  8);
        int64_t dt63 = send_raw(dummy63, 63);

        /* Newlib embedded: utiliser %u avec cast uint32_t (valeurs < 2^32) */
        printf("     1 mot  : %6u cycles\r\n", (uint32_t)dt1);
        printf("     8 mots : %6u cycles  (%u cy/mot)\r\n",
               (uint32_t)dt8,  dt8  > 0 ? (uint32_t)(dt8 / 8)  : 0u);
        printf("    63 mots : %6u cycles  (%u cy/mot)\r\n",
               (uint32_t)dt63, dt63 > 0 ? (uint32_t)(dt63 / 63) : 0u);
        printf("    -> cy/mot = freq_CPU / freq_ICAP (attendu ~1 si meme horloge)\r\n");
    }

    /* ------------------------------------------------------------------ */
    printf("\r\n[T3] ICAP communication — lecture IDCODE\r\n");
    {
        uint32_t rfo_avant = mmio_r(HWICAP_RFO);
        static const uint32_t seq[] = {
            0xFFFFFFFF, 0xFFFFFFFF,
            0xAA995566, 0x20000000,
            0x28018001,
            0x20000000, 0x20000000, 0x20000000, 0x20000000,
        };
        fifo_reset();
        mmio_w(HWICAP_SZ, 9);
        for (int i = 0; i < 9; i++) mmio_w(HWICAP_WF, seq[i]);
        mmio_w(HWICAP_CR, CR_WRITE);
        int t = TIMEOUT;
        while ((mmio_r(HWICAP_CR) & CR_WRITE) && t-- > 0);
        uint32_t rfo_apres = mmio_r(HWICAP_RFO);
        printf("    RFO avant seq = %u  apres CR_WRITE = %u\r\n",
               (unsigned)rfo_avant, (unsigned)rfo_apres);
        printf("    -> RFO doit augmenter : ICAP a sorti des donnees sur O[]\r\n");

        uint32_t id = read_rf();
        desync();
        printf("    IDCODE = 0x%08x  %s\r\n", (unsigned)id,
               id == 0x43651093 ? "[OK]" : "[WARN] attendu 0x43651093");
    }

    /* ------------------------------------------------------------------ */
    printf("\r\n[T4] Accel1 ID AVANT DPR\r\n");
    uint32_t id_before = mmio_r(ACCEL1_BASE) & 0x00FFFFFFu;
    printf("    accel1 ID = 0x%06x  %s\r\n", (unsigned)id_before,
           id_before == 0xAAAAAA ? "[accel_A — OK]"
         : id_before == 0xBBBBBB ? "[accel_B — deja reconfigure ?]"
         : "[inconnu]");

    /* ------------------------------------------------------------------ */
    printf("\r\n[T5] STAT ICAP avant DPR\r\n");
    uint32_t stat_pre = read_stat();
    printf("    STAT = 0x%08x\r\n", (unsigned)stat_pre);
    if ((stat_pre >> 12) & 1) {
        printf("    CFGERR=1 — effacement RCRC+DESYNC\r\n");
        static const uint32_t rcrc[] = {
            0xFFFFFFFF,0xFFFFFFFF,
            0xAA995566,0x20000000,
            0x30008001,0x00000007,
            0x20000000,
            0x30008001,0x0000000D,
            0x20000000,0x20000000,
        };
        send_raw(rcrc, 11);
        uint32_t sc = read_stat();
        printf("    STAT apres RCRC = 0x%08x  CFGERR=%d\r\n",
               (unsigned)sc, (sc >> 12) & 1);
        stat_pre = sc;
    }

    /* ------------------------------------------------------------------ */
    printf("\r\n[T6] Analyse header bitstream DDR @ 0x%08x\r\n",
           (unsigned)BS1_ADDR);
    {
        const uint32_t *bs = (const uint32_t *)BS1_ADDR;
        /* Chercher le mot SYNC (raw=0x665599AA) dans les 32 premiers mots */
        int sync_pos = -1;
        for (int i = 0; i < 32; i++) {
            if (bs[i] == 0x665599AAu) { sync_pos = i; break; }
        }
        printf("    SYNC (0x665599AA) : position %d %s\r\n",
               sync_pos, sync_pos >= 0 ? "[OK]" : "[NON TROUVE — format .bin incorrect ?]");

        if (sync_pos >= 0 && sync_pos + 8 < 32) {
            int p = sync_pos;
            printf("    [%2d] SYNC  raw=0x%08x bswap=0x%08x\r\n",
                   p, (unsigned)bs[p], (unsigned)bswap32(bs[p]));
            printf("    [%2d] NOOP  raw=0x%08x bswap=0x%08x\r\n",
                   p+1, (unsigned)bs[p+1], (unsigned)bswap32(bs[p+1]));
            printf("    [%2d] CMD?  raw=0x%08x bswap=0x%08x  %s\r\n",
                   p+2, (unsigned)bs[p+2], (unsigned)bswap32(bs[p+2]),
                   bswap32(bs[p+2]) == 0x30008001 ? "(Type1 Write CMD)" : "");
            printf("    [%2d] VAL?  raw=0x%08x bswap=0x%08x  %s\r\n",
                   p+3, (unsigned)bs[p+3], (unsigned)bswap32(bs[p+3]),
                   bswap32(bs[p+3]) == 0x00000007 ? "(RCRC)" :
                   bswap32(bs[p+3]) == 0x00000001 ? "(WCFG)" : "");

            /* Chercher le mot IDCODE (Type1 Write IDCODE = 0x30018001) */
            for (int i = p; i < p + 20 && i < 32; i++) {
                if (bswap32(bs[i]) == 0x30018001u) {
                    uint32_t idcode_bs = bswap32(bs[i+1]);
                    printf("    [%2d] IDCODE dans bitstream = 0x%08x %s\r\n",
                           i+1, (unsigned)idcode_bs,
                           (idcode_bs & 0x0FFFFFFFu) == (0x43651093u & 0x0FFFFFFFu)
                           ? "[OK — version masquee]" : "[WARN — mismatch IDCODE]");
                    break;
                }
            }
        }
    }

    /* ------------------------------------------------------------------ */
    if (BS1_NWORDS == 0) {
        printf("\r\n[T7-T8] SKIP : BS1_NWORDS == 0\r\n");
        printf("    Mettre a jour #define BS1_NWORDS dans dpr_test.c\r\n");
        printf("    (sortie de : RM_TARGET=accel_B ./3_build_B2.sh load)\r\n");
        goto done;
    }

    /* ------------------------------------------------------------------ */
    printf("\r\n[T7] DPR write — %u mots, %u chunks\r\n",
           (unsigned)BS1_NWORDS, (unsigned)((BS1_NWORDS + 62) / 63));
    {
        const uint32_t *bs = (const uint32_t *)BS1_ADDR;
        const uint32_t nchunks = (BS1_NWORDS + 62) / 63;

        /* Trace du premier chunk */
        print_hwicap("avant chunk 0 :");
        uint32_t rfo_c0 = mmio_r(HWICAP_RFO);

        fifo_reset();
        int64_t dt0 = send_bin(bs, 63);
        print_hwicap("apres chunk 0 :");
        printf("    chunk 0 : %u cycles  RFO avant=%u apres=%u  %s\r\n",
               (uint32_t)dt0, (unsigned)rfo_c0, (unsigned)mmio_r(HWICAP_RFO),
               dt0 < 0 ? "[TIMEOUT]" : "[OK]");
        if (dt0 < 0) { printf("    [FAIL] timeout chunk 0\r\n"); goto done; }

        /* Chunks 1..fin — tmin/tmax/tsum en uint32_t (valeurs < 2^32) */
        uint32_t tsum = 0, tmin = 0xFFFFFFFFu, tmax = 0;
        int failed = 0;

        for (uint32_t ci = 1; ci < nchunks; ci++) {
            uint32_t i = ci * 63;
            uint32_t chunk = (BS1_NWORDS - i > 63) ? 63 : (BS1_NWORDS - i);

            /* Trace détaillée pour chunk 1 uniquement */
            if (ci == 1) {
                printf("    [ci=%u DBG1] WFV=0x%02x RFO=0x%02x ASR=0x%08x\r\n",
                       (unsigned)ci,
                       (unsigned)mmio_r(HWICAP_WFV),
                       (unsigned)mmio_r(HWICAP_RFO),
                       (unsigned)mmio_r(HWICAP_ASR));
                mmio_w(HWICAP_CR, CR_FIFO_RST);
                printf("    [DBG2] WFV apres CR=FIFO_RST : 0x%02x\r\n",
                       (unsigned)mmio_r(HWICAP_WFV));
                int tf = TIMEOUT;
                while (mmio_r(HWICAP_WFV) < WFV_MAX && tf-- > 0);
                printf("    [DBG3] WFV apres poll (tf=%d) : 0x%02x\r\n",
                       tf, (unsigned)mmio_r(HWICAP_WFV));
                mmio_w(HWICAP_CR, 0);
                printf("    [DBG4] WFV apres CR=0 : 0x%02x\r\n",
                       (unsigned)mmio_r(HWICAP_WFV));
                mmio_w(HWICAP_SZ, chunk);
                printf("    [DBG5] SZ=%u ecrit  WFV=0x%02x\r\n",
                       (unsigned)chunk, (unsigned)mmio_r(HWICAP_WFV));
                /* Ecrire les 3 premiers mots et vérifier WFV */
                for (int dbg = 0; dbg < 3 && dbg < (int)chunk; dbg++) {
                    mmio_w(HWICAP_WF, bswap32(bs[i + dbg]));
                    printf("    [DBG6.%d] mot%d=0x%08x  WFV=0x%02x\r\n",
                           dbg, dbg, (unsigned)bswap32(bs[i + dbg]),
                           (unsigned)mmio_r(HWICAP_WFV));
                }
                /* Ecrire les mots restants */
                for (uint32_t j = 3; j < chunk; j++)
                    mmio_w(HWICAP_WF, bswap32(bs[i + j]));
                printf("    [DBG7] tous mots ecrits  WFV=0x%02x  CR=0x%02x\r\n",
                       (unsigned)mmio_r(HWICAP_WFV), (unsigned)mmio_r(HWICAP_CR));
                mmio_w(HWICAP_CR, CR_WRITE);
                printf("    [DBG8] CR_WRITE set  CR=0x%02x  ASR=0x%08x\r\n",
                       (unsigned)mmio_r(HWICAP_CR), (unsigned)mmio_r(HWICAP_ASR));
                int tc = TIMEOUT;
                while ((mmio_r(HWICAP_CR) & CR_WRITE) && tc-- > 0);
                printf("    [DBG9] apres poll  tc=%d  CR=0x%02x  WFV=0x%02x  ASR=0x%08x\r\n",
                       tc, (unsigned)mmio_r(HWICAP_CR),
                       (unsigned)mmio_r(HWICAP_WFV), (unsigned)mmio_r(HWICAP_ASR));
                if (tc <= 0) { printf("    [FAIL] timeout chunk 1\r\n"); failed = 1; break; }
                tsum += 0; /* chunk 1 timing skipped */
                continue;
            }

            /* CR_FIFO_RST minimal (sans poll) avant chaque chunk :
             * remet HWICAP en état IDLE avant que le bus AXI soit potentiellement
             * perturbé par la reconfiguration des frames non-nulles du pblock. */
            mmio_w(HWICAP_CR, CR_FIFO_RST);
            mmio_w(HWICAP_CR, 0);

            int64_t dt = send_bin(bs + i, chunk);
            if (dt < 0) {
                printf("    [FAIL] CR_WRITE timeout chunk=%u/%u  ASR=0x%08x\r\n",
                       (unsigned)ci, (unsigned)nchunks,
                       (unsigned)mmio_r(HWICAP_ASR));
                print_hwicap("etat au timeout:");
                failed = 1;
                break;
            }
            uint32_t udt = (uint32_t)dt;
            tsum += udt;
            if (udt < tmin) tmin = udt;
            if (udt > tmax) tmax = udt;

            printf("    %u/%u  SR=0x%02x WFV=0x%02x RFO=0x%02x  dt=%u cy\r\n",
                   (unsigned)ci, (unsigned)nchunks,
                   (unsigned)mmio_r(HWICAP_SR),
                   (unsigned)mmio_r(HWICAP_WFV),
                   (unsigned)mmio_r(HWICAP_RFO),
                   (unsigned)udt);
        }

        if (!failed) {
            printf("    [OK] DPR write termine\r\n");
            printf("    Timing : min=%u max=%u moy=%u cy/chunk\r\n",
                   (unsigned)tmin,
                   (unsigned)tmax,
                   (unsigned)(tsum / (nchunks - 1)));
        }
        print_hwicap("apres DPR :");
    }

    /* ------------------------------------------------------------------ */
    printf("\r\n[T8] STAT ICAP apres DPR\r\n");
    {
        for (volatile int i = 0; i < 500000; i++);
        uint32_t stat_post = read_stat();
        printf("    STAT avant = 0x%08x\r\n", (unsigned)stat_pre);
        printf("    STAT apres = 0x%08x  (delta=0x%08x)\r\n",
               (unsigned)stat_post, (unsigned)(stat_post ^ stat_pre));
        printf("    CFGERR  (bit 12) = %d  %s\r\n",
               (stat_post >> 12) & 1,
               (stat_post >> 12) & 1 ? "[WARN] erreur CRC/config" : "[OK]");
        printf("    ID_ERR  (bit 10) = %d  %s\r\n",
               (stat_post >> 10) & 1,
               (stat_post >> 10) & 1 ? "[WARN] IDCODE mismatch" : "[OK]");
        printf("    DONE    (bit  9) = %d\r\n", (stat_post >>  9) & 1);
        printf("    EOS     (bit 17) = %d\r\n", (stat_post >> 17) & 1);
    }

    /* ------------------------------------------------------------------ */
    printf("\r\n[T9] Accel1 ID APRES DPR\r\n");
    {
        for (volatile int i = 0; i < 200000; i++);
        uint32_t id_after = mmio_r(ACCEL1_BASE) & 0x00FFFFFFu;
        printf("    accel1 ID avant = 0x%06x\r\n", (unsigned)id_before);
        printf("    accel1 ID apres = 0x%06x\r\n", (unsigned)id_after);

        printf("\r\n");
        if (id_after == 0xBBBBBB) {
            printf("  *** DPR [SUCCES] : accel_A -> accel_B ***\r\n");
        } else if (id_after == id_before) {
            printf("  [FAIL] ID inchange\r\n");
            printf("    -> Verifier CFGERR et ID_ERR ci-dessus\r\n");
            printf("    -> Si STAT delta=0 : bitstream n'a pas atteint ICAP\r\n");
            printf("    -> Si CFGERR=1 : CRC error dans bitstream\r\n");
            printf("    -> Si ID_ERR=1 : IDCODE mismatch\r\n");
        } else {
            printf("  [?] ID = 0x%06x — reconfiguration partielle ?\r\n",
                   (unsigned)id_after);
        }
    }

done:
    printf("\r\n============================================================\r\n");
}

void arch_init(void) {}
