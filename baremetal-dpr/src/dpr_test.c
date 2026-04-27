/**
 * dpr_test.c — Suite de tests HWICAP / ICAP / DPR
 *
 * Sélection à la compilation (mis à jour par 3_build_B2.sh via sed) :
 *   test1 : Infrastructure HWICAP + lecture registres ICAP (IDCODE, STAT, MASK)
 *   test2 : IDCODE / MASK — vérification complète avant DPR
 *   test3 : Écriture chunk-by-chunk + détection abort ICAP
 *   test4 : DPR complet accel1 (accel_A → accel_B)
 *   test5 : Ping-pong accel_A ↔ accel_B
 *
 * Constantes BS_*_NWORDS mises à jour automatiquement par 3_build_B2.sh.
 */

#ifndef TEST_SELECT
#define TEST_SELECT 3
#endif

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
#define HWICAP_ASR   (HWICAP_BASE + 0x120)

#define ACCEL1_BASE  0x50000000ULL
#define ACCEL2_BASE  0x50001000ULL

/* Adresses DDR des bitstreams (chargés par GDB restore) */
#define BS1_ADDR     0x81000000ULL   /* partiel accel1 — RM_TARGET */
#define BS2_ADDR     0x81300000ULL   /* partiel accel1 — RM_INIT (ping-pong) */

/* Tailles en mots 32 bits — mises à jour par 3_build_B2.sh */
#define BS1_NWORDS   57231UL
#define BS2_NWORDS   95829UL

#define GPIO_BASE       0x40000000ULL
#define GPIO_DATA       (GPIO_BASE + 0x00)
#define GPIO_TRI        (GPIO_BASE + 0x04)  /* tri-state : 0=output, 1=input (défaut) */
#define DECOUPLE_ACCEL1 (1u << 31)
#define DECOUPLE_ACCEL2 (1u << 30)

#define CR_WRITE     0x01
#define CR_READ      0x02
#define CR_FIFO_RST  0x04
#define WFV_MAX      0x3F
#define TIMEOUT      2000000

/* =========================================================================
 * Primitives bas niveau
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

/* Envoie n mots logiques (sans bswap). Retourne cycles écoulés ou -1 si timeout. */
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

/* Envoie n mots depuis .bin DDR (bswap32 appliqué). */
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

/*
 * Lit un mot depuis le RF (Read FIFO) de l'HWICAP.
 *
 * Séquence conforme au driver Xilinx SDK (xhwicap.c / XHwIcap_GetConfigReg) :
 *   - Pas de délai entre CR_WRITE et CR_READ (délai = bug dans ancien code)
 *   - CR_READ déclenché immédiatement après CR_WRITE
 *   - RF lu sans vérifier RFO (SDK ne le fait pas non plus)
 *
 * Affiche RFO pour diagnostic ; retourne RF quel que soit RFO.
 */
static uint32_t read_rf(void) {
    mmio_w(HWICAP_SZ, 1);
    mmio_w(HWICAP_CR, CR_READ);
    int t = TIMEOUT;
    while ((mmio_r(HWICAP_CR) & CR_READ) && t-- > 0);
    if (t <= 0) {
        printf("    [read_rf] TIMEOUT CR_READ\r\n");
        return 0xDEADBEEF;
    }
    uint32_t rfo = mmio_r(HWICAP_RFO);
    uint32_t val = mmio_r(HWICAP_RF);
    if (rfo == 0)
        printf("    [read_rf] RFO=0 (ICAP muet) — RF=0x%08x (peut etre invalide)\r\n",
               (unsigned)val);
    return val;
}

static void desync(void) {
    static const uint32_t s[] = {
        0xFFFFFFFF, 0xFFFFFFFF,
        0xAA995566, 0x20000000,
        0x30008001, 0x0000000D,   /* CMD DESYNC */
        0x20000000, 0x20000000,
    };
    send_raw(s, 8);
}

/*
 * Lecture d'un registre de configuration ICAP.
 * Séquence : sync + NOOP + Type1 Read <reg> + 8 NOOPs flush + CR_READ immédiat.
 */
static uint32_t icap_read_reg(uint32_t type1_hdr) {
    uint32_t s[12];
    s[0]  = 0xFFFFFFFF; s[1]  = 0xFFFFFFFF;
    s[2]  = 0xAA995566; s[3]  = 0x20000000;
    s[4]  = type1_hdr;
    s[5]  = 0x20000000; s[6]  = 0x20000000;
    s[7]  = 0x20000000; s[8]  = 0x20000000;
    s[9]  = 0x20000000; s[10] = 0x20000000;
    s[11] = 0x20000000;
    send_raw(s, 12);
    uint32_t v = read_rf();
    desync();
    return v;
}

/* Registres de configuration ICAP (adresses UG470 Table 5-6)
 *   Type1 Read reg N : (0b001 << 29) | (0b01 << 27) | (N << 13) | 1
 *   = 0x28000001 | (N << 13)
 */
#define ICAP_READ_IDCODE  0x28018001   /* reg 0x0C — Type1 Read (opcode=01) */
#define ICAP_READ_STAT    0x2800E001   /* reg 0x07 */
#define ICAP_READ_MASK    0x2800C001   /* reg 0x06 */
#define ICAP_READ_BOOTSTS 0x28036001   /* reg 0x1B */

static uint32_t read_idcode(void) { return icap_read_reg(ICAP_READ_IDCODE); }
static uint32_t read_stat(void)   { return icap_read_reg(ICAP_READ_STAT);   }
static uint32_t read_mask(void)   { return icap_read_reg(ICAP_READ_MASK);   }

static void print_hwicap(const char *label) {
    printf("    %-22s SR=0x%02x  WFV=0x%02x  RFO=0x%02x  ASR=0x%08x\r\n", label,
           (unsigned)mmio_r(HWICAP_SR),
           (unsigned)mmio_r(HWICAP_WFV),
           (unsigned)mmio_r(HWICAP_RFO),
           (unsigned)mmio_r(HWICAP_ASR));
}

/*
 * Préambule MASK : ignore les bits de version IDCODE [31:28].
 *
 * Sémantique MASK (UG470) : bit MASK=1 → "don't care" (ignoré)
 *                           bit MASK=0 → vérifié contre IDCODE bitstream
 *
 * Device : 0x43651093  bits[31:28]=4
 * Vivado  : 0x03651093  bits[31:28]=0  → différence uniquement sur version
 *
 * MASK=0xF0000000 : bits[31:28]=1 (ignorés) + bits[27:0]=0 (vérifiés, identiques)
 *
 * ERREUR PRECEDENTE : 0x0FFFFFFF avait bits[31:28]=0 → vérifiait les bits
 * qui diffèrent → ID_ERROR garanti !
 *
 * RCRC ne réinitialise pas MASK (UG470, confirmé test2 [2.2]) → survit au
 * RCRC embarqué dans le bitstream partiel.
 */
static void set_idcode_mask(void) {
    static const uint32_t s[] = {
        0xFFFFFFFF, 0xFFFFFFFF,
        0xAA995566, 0x20000000,
        0x3000C001, 0xF0000000,   /* Type1 Write MASK : bits[31:28]=1 = version ignoree */
        0x20000000, 0x20000000,
        0x30008001, 0x0000000D,   /* CMD DESYNC */
        0x20000000, 0x20000000,
    };
    send_raw(s, 12);
}

/* =========================================================================
 * Test 1 — Infrastructure HWICAP + lecture registres ICAP
 *
 * Valide de bas en haut :
 *   1.1 Registres HWICAP à l'état initial (SR, WFV, RFO, ASR)
 *   1.2 Reset FIFO et décrémentation WFV mot par mot
 *   1.3 Baseline timing CR_WRITE (cycles/mot)
 *   1.4 Lecture IDCODE ICAP — corrige bug timing (plus de délai 50k cycles)
 *   1.5 Décodage IDCODE : version, numéro de composant, fabricant
 *   1.6 Lecture STAT et décodage bit à bit (UG470 Table 5-25)
 *   1.7 Lecture MASK — valeur après programmation JTAG
 *
 * Critères de succès :
 *   IDCODE == 0x43651093 (version 4, XC7K325T)
 *   STAT : DONE=1, EOS=1
 *   MASK : valeur après full bitstream Vivado (attendu 0x00000000)
 * ========================================================================= */

static void print_stat_decode(uint32_t stat) {
    printf("    STAT raw = 0x%08x\r\n", (unsigned)stat);
    printf("    Decode (UG470 Table 5-25, 7-series) :\r\n");
    printf("      bit 0  CRC_ERROR   = %d  %s\r\n",
           (stat >> 0) & 1, (stat >> 0) & 1 ? "[WARN]" : "[ok]");
    printf("      bit 1  DCMLOCK     = %d  (PLL/DCM verrouilles)\r\n",
           (stat >> 1) & 1);
    printf("      bit 2  ID_ERROR    = %d  %s\r\n",
           (stat >> 2) & 1, (stat >> 2) & 1 ? "[WARN] IDCODE mismatch" : "[ok]");
    printf("      bit 3  TRIG        = %d\r\n",           (stat >> 3) & 1);
    printf("      bit 4  CFGERR      = %d  %s\r\n",
           (stat >> 4) & 1, (stat >> 4) & 1 ? "[WARN] config error" : "[ok]");
    printf("      bit 5  INIT_B      = %d  (etat pin INIT_B)\r\n", (stat >> 5) & 1);
    printf("      bit 6  reserved    = %d\r\n",           (stat >> 6) & 1);
    printf("      bit 7  reserved    = %d\r\n",           (stat >> 7) & 1);
    printf("      bit 8  reserved    = %d\r\n",           (stat >> 8) & 1);
    printf("      bit 9  HSWAPEN     = %d\r\n",           (stat >> 9) & 1);
    printf("      bit10  reserved    = %d\r\n",           (stat >> 10) & 1);
    printf("      bit11  reserved    = %d\r\n",           (stat >> 11) & 1);
    printf("      bit12  EOS         = %d  %s\r\n",
           (stat >> 12) & 1, (stat >> 12) & 1 ? "[ok] startup done" : "[WARN]");
    printf("      bit13  reserved    = %d\r\n",           (stat >> 13) & 1);
    printf("      bit14  DONE        = %d  %s\r\n",
           (stat >> 14) & 1, (stat >> 14) & 1 ? "[ok] configured" : "[WARN]");
    printf("      bit15  release_done= %d\r\n",           (stat >> 15) & 1);
    printf("      bits[31:16]        = 0x%04x  (boot status / mode)\r\n",
           (unsigned)(stat >> 16));
}

static void test1(void) {
    printf("\r\n");
    printf("============================================================\r\n");
    printf(" Test 1 : Infrastructure HWICAP + Registres ICAP\r\n");
    printf("============================================================\r\n");

    /* ------------------------------------------------------------------ */
    printf("\r\n[1.1] Registres HWICAP a l'etat initial\r\n");
    {
        uint32_t sr  = mmio_r(HWICAP_SR);
        uint32_t wfv = mmio_r(HWICAP_WFV);
        uint32_t rfo = mmio_r(HWICAP_RFO);
        uint32_t asr = mmio_r(HWICAP_ASR);
        printf("    SR  = 0x%02x  (att 0x05 : bit0=send_done, bit2=EOS) %s\r\n",
               (unsigned)sr,  sr  == 0x05 ? "[OK]" : "[WARN]");
        printf("    WFV = 0x%02x  (att 0x3F : FIFO write vide)          %s\r\n",
               (unsigned)wfv, wfv == 0x3F ? "[OK]" : "[WARN]");
        printf("    RFO = 0x%02x  (att 0x00 : FIFO read vide)           %s\r\n",
               (unsigned)rfo, rfo == 0x00 ? "[OK]" : "[WARN]");
        printf("    ASR = 0x%08x  (att 0 : pas d'abort ICAP)        %s\r\n",
               (unsigned)asr, asr == 0    ? "[OK]" : "[WARN]");
        if (sr != 0x05 || wfv != 0x3F) {
            printf("    [WARN] Bridge AXI anormal — verifier programmation FPGA\r\n");
        }
    }

    /* ------------------------------------------------------------------ */
    printf("\r\n[1.2] Reset FIFO + decrementation WFV\r\n");
    {
        fifo_reset();
        uint32_t wfv_reset = mmio_r(HWICAP_WFV);
        printf("    WFV apres fifo_reset() = 0x%02x  %s\r\n",
               (unsigned)wfv_reset, wfv_reset == 0x3F ? "[OK]" : "[FAIL]");

        mmio_w(HWICAP_SZ, 8);
        int ok = 1;
        for (int i = 0; i < 8; i++) {
            mmio_w(HWICAP_WF, 0xFFFFFFFF);
            uint32_t wfv = mmio_r(HWICAP_WFV);
            uint32_t expected = 0x3F - i - 1;
            printf("    apres mot %d : WFV=0x%02x (att 0x%02x) %s\r\n",
                   i+1, (unsigned)wfv, (unsigned)expected,
                   wfv == expected ? "" : "[WARN]");
            if (wfv != expected) ok = 0;
        }
        mmio_w(HWICAP_CR, CR_WRITE);
        int t = TIMEOUT;
        while ((mmio_r(HWICAP_CR) & CR_WRITE) && t-- > 0);
        printf("    WFV apres CR_WRITE : 0x%02x (att 0x3F)  ASR=0x%08x\r\n",
               (unsigned)mmio_r(HWICAP_WFV), (unsigned)mmio_r(HWICAP_ASR));
        printf("    => WFV decrement/recovery : %s\r\n", ok ? "[OK]" : "[FAIL verifier bus AXI]");
    }

    /* ------------------------------------------------------------------ */
    printf("\r\n[1.3] Baseline timing CR_WRITE (cycles CPU / mot)\r\n");
    {
        static const uint32_t d1[1]  = { 0xFFFFFFFF };
        static const uint32_t d8[8]  = { [0 ... 7] = 0xFFFFFFFF };
        static const uint32_t d63[63];   /* zeros avant SYNC — inoffensifs */

        int64_t dt1  = send_raw(d1,  1);
        int64_t dt8  = send_raw(d8,  8);
        int64_t dt63 = send_raw(d63, 63);
        printf("     1 mot  : %6u cycles\r\n", (uint32_t)dt1);
        printf("     8 mots : %6u cycles (%u cy/mot)\r\n",
               (uint32_t)dt8,  dt8  > 0 ? (uint32_t)(dt8/8)   : 0u);
        printf("    63 mots : %6u cycles (%u cy/mot)\r\n",
               (uint32_t)dt63, dt63 > 0 ? (uint32_t)(dt63/63) : 0u);
        printf("    (freq_ICAP = freq_CPU / cy_par_mot)\r\n");
    }

    /* ------------------------------------------------------------------ */
    printf("\r\n[1.4] Lecture IDCODE ICAP\r\n");
    printf("    Sequence : sync + NOOP + Type1 Read IDCODE (reg 0x0C) + 8 NOOPs\r\n");
    printf("    Puis CR_READ immediat (sans delai — conforme driver Xilinx SDK)\r\n");
    {
        uint32_t rfo_avant = mmio_r(HWICAP_RFO);
        uint32_t idcode = read_idcode();
        uint32_t rfo_apres = mmio_r(HWICAP_RFO);

        printf("    RFO avant sequence  = %u\r\n", (unsigned)rfo_avant);
        printf("    RFO apres CR_READ   = %u\r\n", (unsigned)rfo_apres);
        printf("    IDCODE lu           = 0x%08x\r\n", (unsigned)idcode);
        printf("    IDCODE attendu      = 0x43651093  (XC7K325T version=4)\r\n");

        if (idcode == 0x43651093) {
            printf("    => [OK] IDCODE correct\r\n");
        } else if ((idcode & 0x0FFFFFFF) == (0x43651093 & 0x0FFFFFFF)) {
            printf("    => [WARN] IDCODE bits[27:0] corrects mais version=%u (att 4)\r\n",
                   (unsigned)(idcode >> 28));
        } else {
            printf("    => [FAIL] IDCODE incorrect\r\n");
            printf("       Variants possibles :\r\n");
            printf("         bswap32     = 0x%08x\r\n", (unsigned)bswap32(idcode));
            uint32_t bitrev = 0;
            for (int b = 0; b < 32; b++)
                if (idcode & (1u << b)) bitrev |= (1u << (31-b));
            printf("         bit-reverse = 0x%08x\r\n", (unsigned)bitrev);
            printf("       => Timing CR_READ toujours incorrect ?\r\n");
            printf("          Verifier : oscilloscope sur ICAP CLK / check EOS\r\n");
        }
    }

    /* ------------------------------------------------------------------ */
    printf("\r\n[1.5] Decodage IDCODE — version et composant\r\n");
    {
        uint32_t id = read_idcode();
        uint32_t version = (id >> 28) & 0xF;
        uint32_t family  = (id >> 13) & 0x7FFF; /* bits 27:13 */
        uint32_t mfg     = (id >> 1)  & 0x7FF;  /* bits 11:1 = JTAG manufacturer */
        uint32_t lsb     = id & 1;

        printf("    IDCODE = 0x%08x\r\n", (unsigned)id);
        printf("      bits[31:28] version     = %u  (Vivado ecrit 0, silicium = 4)\r\n",
               (unsigned)version);
        printf("      bits[27:13] part/family = 0x%04x\r\n", (unsigned)family);
        printf("      bits[11: 1] manufacturer= 0x%03x  %s\r\n",
               (unsigned)mfg, mfg == 0x049 ? "(Xilinx [OK])" : "(inconnu)");
        printf("      bit [0]     always-1    = %u  %s\r\n",
               (unsigned)lsb, lsb ? "[ok]" : "[WARN JTAG IDCODE invalide]");
        printf("    Vivado genere IDCODE=0x03651093 (version=0) dans les bitstreams.\r\n");
        printf("    Ce silicium repond 0x%08x (version=%u).\r\n",
               (unsigned)id, (unsigned)version);
        if (version != 0)
            printf("    => Mismatch version : MASK=0xF0000000 necessaire avant DPR.\r\n");
        else
            printf("    => Pas de mismatch version.\r\n");
    }

    /* ------------------------------------------------------------------ */
    printf("\r\n[1.6] Lecture STAT ICAP et decodage\r\n");
    {
        uint32_t stat = read_stat();
        print_stat_decode(stat);
        printf("\r\n");
        if ((stat >> 14) & 1)
            printf("    DONE=1 : FPGA configure  [OK]\r\n");
        else
            printf("    DONE=0 : FPGA NON configure  [FAIL]\r\n");
        if ((stat >> 12) & 1)
            printf("    EOS=1  : startup sequence terminee  [OK]\r\n");
        else
            printf("    EOS=0  : startup sequence incomplete  [WARN]\r\n");
        if ((stat >> 4) & 1) {
            printf("    CFGERR=1 : erreur de configuration  [WARN]\r\n");
            if ((stat >> 2) & 1)
                printf("      ID_ERROR=1 : mismatch IDCODE (attendu apres full .bit Vivado)\r\n");
            if ((stat >> 0) & 1)
                printf("      CRC_ERROR=1 : erreur CRC\r\n");
        } else {
            printf("    CFGERR=0 : pas d'erreur  [OK]\r\n");
        }
    }

    /* ------------------------------------------------------------------ */
    printf("\r\n[1.7] Lecture MASK ICAP\r\n");
    {
        uint32_t mask = read_mask();
        printf("    MASK lu = 0x%08x\r\n", (unsigned)mask);
        printf("    Interpretation : bit=0 → verifie, bit=1 → ignore\r\n");
        if (mask == 0x00000000)
            printf("    => MASK=0 : verification IDCODE stricte (defaut apres full .bit)\r\n");
        else if (mask == 0xFFFFFFFF)
            printf("    => MASK=0xFFFFFFFF : aucune verification IDCODE (POR/reset)\r\n");
        else if (mask == 0xF0000000)
            printf("    => MASK=0xF0000000 : version masquee (notre preamble actif)\r\n");
        else
            printf("    => MASK inconnu — a cross-reference avec UG470\r\n");

        printf("\r\n    Test preamble MASK=0xF0000000 :\r\n");
        set_idcode_mask();
        uint32_t mask2 = read_mask();
        printf("    MASK apres set_idcode_mask() = 0x%08x  %s\r\n",
               (unsigned)mask2,
               mask2 == 0xF0000000 ? "[OK] preamble actif" : "[FAIL] preamble non applique");
    }

    /* ------------------------------------------------------------------ */
    printf("\r\n[BILAN TEST 1]\r\n");
    {
        uint32_t id   = read_idcode();
        uint32_t stat = read_stat();
        int id_ok    = (id == 0x43651093);
        int id_part  = ((id & 0x0FFFFFFF) == (0x43651093 & 0x0FFFFFFF));
        int done     = (stat >> 14) & 1;
        int eos      = (stat >> 12) & 1;
        int cfgerr   = (stat >> 4)  & 1;

        printf("    IDCODE  : 0x%08x  %s\r\n", (unsigned)id,
               id_ok   ? "[OK]"   :
               id_part ? "[WARN version field]" : "[FAIL lecture ICAP incorrecte]");
        printf("    DONE    : %d  %s\r\n", done,  done  ? "[OK]" : "[FAIL]");
        printf("    EOS     : %d  %s\r\n", eos,   eos   ? "[OK]" : "[WARN]");
        printf("    CFGERR  : %d  %s\r\n", cfgerr, cfgerr ? "[WARN attendu si full .bit Vivado]" : "[OK]");

        if (id_ok || id_part) {
            printf("\r\n  => Test 1 PASSE : lectures ICAP fonctionnelles\r\n");
            printf("     Lancer test2 : ./3_build_B2.sh test2\r\n");
        } else {
            printf("\r\n  => Test 1 ECHOUE : relire IDCODE toujours faux\r\n");
            printf("     Causes possibles :\r\n");
            printf("       - ICAP_7SERIES mal place (doit etre ICAP_X0Y0)\r\n");
            printf("       - Horloge ICAP incorrecte dans le design\r\n");
            printf("       - EOS non asserte (STARTUPE2 non connecte)\r\n");
        }
    }

    printf("\r\n============================================================\r\n");
}

/* =========================================================================
 * Helpers test2
 * ========================================================================= */

/* Écrit MASK via ICAP (Type1 Write MASK reg6 = 0x3000C001). */
static void icap_write_mask(uint32_t value) {
    uint32_t s[] = {
        0xFFFFFFFF, 0xFFFFFFFF,
        0xAA995566, 0x20000000,
        0x3000C001, value,
        0x20000000, 0x20000000,
        0x30008001, 0x0000000D,   /* CMD DESYNC */
        0x20000000, 0x20000000,
    };
    send_raw(s, 12);
}

/* Envoie RCRC + DESYNC (début typique d'un bitstream partiel). */
static void icap_rcrc_desync(void) {
    static const uint32_t s[] = {
        0xFFFFFFFF, 0xFFFFFFFF,
        0xAA995566, 0x20000000,
        0x30008001, 0x00000007,   /* CMD RCRC */
        0x20000000,
        0x30008001, 0x0000000D,   /* CMD DESYNC */
        0x20000000, 0x20000000,
    };
    send_raw(s, 11);
}

/* Décode et affiche un mot du bitstream partiel (format DDR : appliquer bswap32). */
static void print_bs_packet(int pos, uint32_t raw) {
    uint32_t w = bswap32(raw);
    if (raw == 0xFFFFFFFF) { printf("    [%3d] DUMMY\r\n", pos); return; }
    if (w   == 0xAA995566) { printf("    [%3d] SYNC WORD\r\n", pos); return; }
    if (w   == 0x20000000) { printf("    [%3d] NOOP\r\n", pos); return; }

    uint32_t type   = (w >> 29) & 0x7;
    uint32_t opcode = (w >> 27) & 0x3;

    if (type == 1) {
        uint32_t reg   = (w >> 13) & 0x3FFF;
        uint32_t count = w & 0x7FF;
        const char *op = (opcode == 1) ? "READ " : (opcode == 2) ? "WRITE" : "?    ";
        const char *rname = "?";
        switch (reg) {
            case  0: rname = "CRC";     break;  case  1: rname = "FAR";   break;
            case  2: rname = "FDRI";    break;  case  4: rname = "CMD";   break;
            case  5: rname = "CTL0";    break;  case  6: rname = "MASK";  break;
            case  7: rname = "STAT";    break;  case  9: rname = "COR0";  break;
            case 12: rname = "IDCODE";  break;  case 13: rname = "AXSS";  break;
            case 18: rname = "WBSTAR";  break;  case 19: rname = "TIMER"; break;
        }
        printf("    [%3d] Type1 %s reg=0x%02x (%s) count=%u\r\n",
               pos, op, (unsigned)reg, rname, (unsigned)count);
        /* Décoder valeur CMD si applicable */
        if (reg == 4 && opcode == 2 && count == 1) {
            /* La valeur CMD sera imprimée lors du prochain appel (pos+1) */
        }
    } else if (type == 2) {
        uint32_t count = w & 0x7FFFFFF;
        printf("    [%3d] Type2 WRITE count=%u (donnees frame)\r\n",
               pos, (unsigned)count);
    } else {
        printf("    [%3d] raw=0x%08x  bswap=0x%08x (type=%u)\r\n",
               pos, (unsigned)raw, (unsigned)w, (unsigned)type);
    }
}

/* =========================================================================
 * Test 2 — IDCODE / MASK : validation complète avant DPR
 *
 * Prerequis : Test 1 passe (IDCODE lisible = 0x43651093)
 *
 * Valide :
 *   2.1 Baseline IDCODE / STAT / MASK
 *   2.2 RCRC réinitialise-t-il MASK ? (UG470 dit non — à vérifier)
 *   2.3 Décodage header bitstream partiel : MASK + IDCODE dans le .bin
 *   2.4 Simulation complète : MASK=0 → preamble → RCRC → IDCODE check
 *
 * Critère de succès :
 *   MASK survit à RCRC ET bitstream n'écrit pas MASK=0 après notre preamble
 * ========================================================================= */
static void test2(void) {
    printf("\r\n");
    printf("============================================================\r\n");
    printf(" Test 2 : IDCODE / MASK — validation complete\r\n");
    printf("============================================================\r\n");

    /* ------------------------------------------------------------------ */
    printf("\r\n[2.1] Baseline — IDCODE, STAT, MASK\r\n");
    {
        uint32_t id   = read_idcode();
        uint32_t stat = read_stat();
        uint32_t mask = read_mask();
        printf("    IDCODE = 0x%08x  %s\r\n", (unsigned)id,
               id == 0x43651093 ? "[OK]" : "[WARN]");
        printf("    STAT   = 0x%08x  DONE=%d EOS=%d CFGERR=%d ID_ERR=%d\r\n",
               (unsigned)stat,
               (stat>>14)&1, (stat>>12)&1, (stat>>4)&1, (stat>>2)&1);
        printf("    MASK   = 0x%08x  %s\r\n", (unsigned)mask,
               mask == 0x00000000 ? "(strict — etat apres reprogram JTAG)" :
               mask == 0xF0000000 ? "(version masquee — preamble precedent actif)" :
               "(autre)");
        /* Forcer MASK=0 pour avoir une base propre */
        if (mask != 0x00000000) {
            icap_write_mask(0x00000000);
            mask = read_mask();
            printf("    MASK force a 0 = 0x%08x  %s\r\n",
                   (unsigned)mask, mask == 0 ? "[OK]" : "[FAIL]");
        }
    }

    /* ------------------------------------------------------------------ */
    printf("\r\n[2.2] RCRC reinitialise-t-il MASK ?\r\n");
    printf("    UG470 : RCRC reinitialise UNIQUEMENT le CRC, pas MASK.\r\n");
    {
        /* Test depuis MASK=0 */
        icap_write_mask(0x00000000);
        uint32_t m0 = read_mask();
        printf("    MASK avant RCRC         = 0x%08x\r\n", (unsigned)m0);
        icap_rcrc_desync();
        uint32_t m1 = read_mask();
        printf("    MASK apres RCRC (base0) = 0x%08x  %s\r\n", (unsigned)m1,
               m1 == 0x00000000 ? "[OK] non modifie" : "[WARN] modifie !");

        /* Test depuis MASK=0xF0000000 (notre preamble) */
        icap_write_mask(0xF0000000);
        uint32_t m2 = read_mask();
        printf("    MASK avant RCRC (preamble) = 0x%08x\r\n", (unsigned)m2);
        icap_rcrc_desync();
        uint32_t m3 = read_mask();
        printf("    MASK apres RCRC (preamble) = 0x%08x  %s\r\n", (unsigned)m3,
               m3 == 0xF0000000 ? "[OK] preamble survit a RCRC" :
               "[FAIL] preamble EFFACE par RCRC — strategie a revoir");
    }

    /* ------------------------------------------------------------------ */
    printf("\r\n[2.3] Header bitstream partiel — decodage complet (32 premiers mots)\r\n");
    printf("    (BS1_ADDR=0x%08x, format DDR little-endian : bswap32 applique)\r\n",
           (unsigned)BS1_ADDR);
    {
        const uint32_t *bs = (const uint32_t *)BS1_ADDR;
        int mask_write_found = 0;
        uint32_t mask_in_bs  = 0xDEADBEEF;
        int idcode_found     = 0;
        uint32_t idcode_in_bs = 0xDEADBEEF;
        int prev_is_mask_hdr  = 0;
        int prev_is_idcode_hdr = 0;
        int prev_is_cmd_hdr   = 0;

        for (int i = 0; i < 32; i++) {
            uint32_t w = bswap32(bs[i]);
            /* Capturer valeur après headers détectés au tour précédent */
            if (prev_is_mask_hdr)   { mask_in_bs  = w; mask_write_found  = 1; prev_is_mask_hdr  = 0; }
            if (prev_is_idcode_hdr) { idcode_in_bs = w; idcode_found      = 1; prev_is_idcode_hdr = 0; }
            if (prev_is_cmd_hdr) {
                const char *cmd = "?";
                switch (w) {
                    case 1: cmd="WCFG";   break; case 7: cmd="RCRC";   break;
                    case 13:cmd="DESYNC"; break; case 15:cmd="IPROG";  break;
                }
                printf("    [%3d]   -> CMD value = %u (%s)\r\n", i, (unsigned)w, cmd);
                prev_is_cmd_hdr = 0;
                continue;
            }
            print_bs_packet(i, bs[i]);
            /* Détecter les headers pour le tour suivant */
            if ((w & 0xFFFFE7FF) == 0x3000C001)  prev_is_mask_hdr   = 1; /* Type1 Write MASK */
            if ((w & 0xFFFFE7FF) == 0x30018001)  prev_is_idcode_hdr = 1; /* Type1 Write IDCODE */
            if ((w >> 13) == (0x30008001 >> 13) && (w & 0x7FF) == 1) prev_is_cmd_hdr = 1;
        }

        printf("\r\n    Résumé header bitstream :\r\n");
        if (mask_write_found)
            printf("    MASK dans bitstream = 0x%08x  %s\r\n",
                   (unsigned)mask_in_bs,
                   mask_in_bs == 0x00000000 ? "[WARN] ecrase notre preamble !" :
                   mask_in_bs == 0xFFFFFFFF ? "[OK] all-don't-care" :
                   "[INFO]");
        else
            printf("    Pas de Type1 Write MASK dans les 32 premiers mots\r\n");

        if (idcode_found)
            printf("    IDCODE dans bitstream = 0x%08x  %s\r\n",
                   (unsigned)idcode_in_bs,
                   (idcode_in_bs & 0x0FFFFFFF) == (0x43651093 & 0x0FFFFFFF)
                   ? "[OK] compatible" : "[WARN mismatch]");
    }

    /* ------------------------------------------------------------------ */
    printf("\r\n[2.4] Simulation complete : MASK=0 → preamble → RCRC → check IDCODE\r\n");
    {
        /* État initial : MASK=0 comme après full bitstream Vivado */
        icap_write_mask(0x00000000);
        printf("    MASK reset a 0\r\n");

        /* Appliquer notre preamble */
        set_idcode_mask();
        uint32_t m1 = read_mask();
        printf("    MASK apres preamble       = 0x%08x  %s\r\n",
               (unsigned)m1, m1 == 0xF0000000 ? "[OK]" : "[FAIL]");

        /* Simuler le RCRC en tête de bitstream partiel */
        icap_rcrc_desync();
        uint32_t m2 = read_mask();
        printf("    MASK apres RCRC bitstream = 0x%08x  %s\r\n",
               (unsigned)m2,
               m2 == 0xF0000000 ? "[OK] preamble actif" :
               m2 == 0x00000000 ? "[FAIL] preamble efface" : "[?]");

        /* Vérification finale IDCODE */
        uint32_t id    = read_idcode();
        uint32_t id_bs = 0x03651093;
        int pass = ((id & ~m2) == (id_bs & ~m2));
        printf("    IDCODE device    = 0x%08x\r\n", (unsigned)id);
        printf("    IDCODE bitstream = 0x%08x\r\n", (unsigned)id_bs);
        printf("    Check (dev & ~MASK) == (bs & ~MASK) : %s\r\n",
               pass ? "[PASS] DPR devrait fonctionner" :
                      "[FAIL] IDCODE mismatch — DPR va echouer");
    }

    /* ------------------------------------------------------------------ */
    printf("\r\n[BILAN TEST 2]\r\n");
    {
        icap_write_mask(0x00000000);
        set_idcode_mask();
        icap_rcrc_desync();
        uint32_t mf = read_mask();
        uint32_t id = read_idcode();
        /* Vérification conforme ICAP : (device & ~MASK) == (bs & ~MASK)
         * Avec MASK=0xF0000000, ~MASK=0x0FFFFFFF → vérifie bits[27:0] */
        int ok = (mf == 0xF0000000) &&
                 ((id & ~mf) == (0x03651093 & ~mf));
        printf("    MASK apres preamble+RCRC = 0x%08x\r\n", (unsigned)mf);
        printf("    IDCODE device            = 0x%08x\r\n", (unsigned)id);
        if (ok) {
            printf("\r\n  => Test 2 PASSE : preamble suffisant\r\n");
            printf("     Lancer test3 : ./3_build_B2.sh test3\r\n");
        } else if (mf != 0xF0000000) {
            printf("\r\n  => Test 2 ECHOUE : preamble efface par RCRC ou bitstream\r\n");
            printf("     Voir [2.3] pour identifier si le bitstream ecrit MASK=0\r\n");
        } else {
            printf("\r\n  => Test 2 ECHOUE : IDCODE mismatch persistant\r\n");
        }
    }

    printf("\r\n============================================================\r\n");
}

/* =========================================================================
 * Patch IDCODE en DDR
 *
 * Vivado génère toujours IDCODE=0x03651093. Si le silicium est v4 (0x43651093),
 * le bitstream est rejeté. On le patche directement en RAM.
 * ========================================================================= */
static void patch_idcode_in_ddr(uint32_t *addr, uint32_t nwords) {
    uint32_t count = 0;
    /* IDCODE attendu par Vivado : 0x03651093. 
       En DDR (Little-Endian par octets), il est vu par le CPU RISC-V comme 0x93106503. */
    uint32_t old_val = 0x93106503; 
    uint32_t new_val = 0x93106543; // 0x43651093 version 4

    for (uint32_t i = 0; i < nwords; i++) {
        if (addr[i] == old_val) {
            addr[i] = new_val;
            count++;
        }
    }
    if (count > 0)
        printf("    [PATCH] %u occurrences de l'IDCODE patchées (0x03... -> 0x43...)\r\n", (unsigned)count);
    else
        printf("    [PATCH] IDCODE non trouvé dans le bitstream (déjà patché ?)\r\n");
}

/* =========================================================================
 * Test 3 — Écriture chunk-by-chunk avec détection abort ICAP
 *
 * Prerequis : Test 2 passe (MASK=0xF0000000 confirme suffisant)
 *
 * Valide :
 *   3.1 État ICAP + accel ID avant DPR
 *   3.2 Préambule MASK=0xF0000000
 *   3.3 Chunks 0..9 — trace détaillée SR/ASR par chunk
 *   3.4 Chunks 10..fin — écriture silencieuse, détection abort
 *   3.5 STAT après écriture complète
 *   3.6 Accel1 ID après DPR → verdict
 *
 * Critère de succès : SR=0x05 + ASR=0 après tout, accel1 ID = 0xBBBBBB
 * ========================================================================= */
static void test3(void) {
    printf("\r\n");
    printf("============================================================\r\n");
    printf(" Test 3 : Ecriture chunk-by-chunk\r\n");
    printf("============================================================\r\n");

    /* GPIO TRI=0 : bits 31 et 30 en sortie (decouple accel1/accel2) */
    mmio_w(GPIO_TRI, 0x00000000u);  /* tout en sortie */

    if (BS1_NWORDS == 0) {
        printf("  BS1_NWORDS == 0 — lancer : RM_TARGET=accel_B ./3_build_B2.sh test3\r\n");
        printf("============================================================\r\n");
        return;
    }

    const uint32_t *bs     = (const uint32_t *)BS1_ADDR;
    const uint32_t nchunks = (BS1_NWORDS + 62) / 63;

    /* ------------------------------------------------------------------ */
    printf("\r\n[3.1] Etat ICAP + accel1 avant DPR\r\n");
    {
        uint32_t id   = read_idcode();
        uint32_t stat = read_stat();
        uint32_t mask = read_mask();
        uint32_t acc  = mmio_r(ACCEL1_BASE) & 0x00FFFFFFu;
        print_hwicap("etat initial :");
        printf("    IDCODE = 0x%08x  %s\r\n", (unsigned)id,
               id == 0x43651093 ? "[OK]" : "[WARN]");
        printf("    STAT   = 0x%08x  DONE=%d EOS=%d CFGERR=%d\r\n",
               (unsigned)stat, (stat>>14)&1, (stat>>12)&1, (stat>>4)&1);
        printf("    MASK   = 0x%08x\r\n", (unsigned)mask);
        printf("    accel1 = 0x%06x  %s\r\n", (unsigned)acc,
               acc == 0xAAAAAA ? "[accel_A]" :
               acc == 0xBBBBBB ? "[accel_B — deja reconfigure]" : "[inconnu]");
    }

    /* ------------------------------------------------------------------ */
    printf("\r\n[3.2] Preamble MASK=0xF0000000\r\n");
    {
        set_idcode_mask();
        uint32_t m = read_mask();
        printf("    MASK apres preamble = 0x%08x  %s\r\n",
               (unsigned)m, m == 0xF0000000 ? "[OK]" : "[FAIL]");
        if (m != 0xF0000000) {
            printf("    [ABORT] preamble non applique\r\n");
            goto t3_end;
        }
    }

    /* Découplage matériel : isolation accel1 pendant l'écriture DPR */
    mmio_w(GPIO_DATA, mmio_r(GPIO_DATA) | DECOUPLE_ACCEL1);
    printf("    [DPR] decouplage accel1 actif (GPIO=0x%08x)\r\n", (unsigned)mmio_r(GPIO_DATA));

    /* ------------------------------------------------------------------ */
    printf("\r\n[3.3] Chunks 0..9 — trace detaillee\r\n");
    {
        for (uint32_t ci = 0; ci < 10 && ci < nchunks; ci++) {
            uint32_t i     = ci * 63;
            uint32_t chunk = (BS1_NWORDS - i > 63) ? 63 : (BS1_NWORDS - i);
            uint32_t sr0   = mmio_r(HWICAP_SR);
            uint32_t asr0  = mmio_r(HWICAP_ASR);

            fifo_reset();
            int64_t dt = send_bin(bs + i, chunk);

            uint32_t sr1  = mmio_r(HWICAP_SR);
            uint32_t asr1 = mmio_r(HWICAP_ASR);

            printf("    chunk %2u (%3u mots) : %5u cy  SR %02x→%02x  ASR %08x→%08x  %s\r\n",
                   (unsigned)ci, (unsigned)chunk, (unsigned)(dt < 0 ? 0 : dt),
                   (unsigned)sr0, (unsigned)sr1, (unsigned)asr0, (unsigned)asr1,
                   (dt < 0)    ? "[TIMEOUT]" :
                   (asr1 != 0) ? "[ABORT]"   :
                   (sr1 != 0x05) ? "[SR-WARN]" : "[OK]");

            if (dt < 0 || asr1 != 0) {
                printf("    [STOP] anomalie chunk %u\r\n", (unsigned)ci);
                goto t3_end;
            }
        }
    }

    /* ------------------------------------------------------------------ */
    printf("\r\n[3.4] Chunks 10..%u — trace chunk par chunk\r\n", (unsigned)(nchunks-1));
    {
        uint32_t anomalies = 0;
        int failed = 0;

        for (uint32_t ci = 10; ci < nchunks; ci++) {
            uint32_t i        = ci * 63;
            uint32_t chunk    = (BS1_NWORDS - i > 63) ? 63 : (BS1_NWORDS - i);
            uint32_t sr_pre   = mmio_r(HWICAP_SR);
            uint32_t asr_pre  = mmio_r(HWICAP_ASR);

            fifo_reset();
            int64_t dt = send_bin(bs + i, chunk);

            uint32_t sr_post  = mmio_r(HWICAP_SR);
            uint32_t asr_post = mmio_r(HWICAP_ASR);

            const char *status =
                (dt < 0)          ? "[TIMEOUT]" :
                (asr_post != 0)   ? "[ABORT]"   :
                (sr_post != 0x05) ? "[SR-WARN]" : "[OK]";

            printf("    chunk %3u (%2u mots) : %5u cy  SR %02x->%02x  ASR %08x->%08x  %s\r\n",
                   (unsigned)ci, (unsigned)chunk,
                   (unsigned)(dt < 0 ? 0 : dt),
                   (unsigned)sr_pre,  (unsigned)sr_post,
                   (unsigned)asr_pre, (unsigned)asr_post,
                   status);

            if (dt < 0) { failed = 1; break; }
            if (sr_post != 0x05 || asr_post != 0) anomalies++;
        }
        if (!failed)
            printf("    ecriture terminee  anomalies=%u  %s\r\n",
                   (unsigned)anomalies, anomalies == 0 ? "[OK]" : "[WARN]");
        print_hwicap("apres ecriture :");
    }

    /* ------------------------------------------------------------------ */
    printf("\r\n[3.5] STAT ICAP apres DPR\r\n");
    {
        /* Attendre 2M cycles : RP initialise ses registres apres reconfiguration */
        for (volatile int i = 0; i < 2000000; i++);
        uint32_t stat = read_stat();
        printf("    STAT = 0x%08x  DONE=%d EOS=%d CFGERR=%d ID_ERR=%d CRC_ERR=%d\r\n",
               (unsigned)stat,
               (stat>>14)&1, (stat>>12)&1, (stat>>4)&1, (stat>>2)&1, stat&1);
        /* Note : CFGERR=1 peut persister du full bitstream JTAG (ID_ERROR)
         * meme apres un DPR reussi — ce n'est pas necessairement un echec. */
        if ((stat>>4)&1)
            printf("    [NOTE] CFGERR=1 (peut venir du full bitstream JTAG, pas du DPR)\r\n");
        else
            printf("    [OK] CFGERR=0\r\n");
    }

    /* ------------------------------------------------------------------ */
    printf("\r\n[3.6] Sante bus AXI + ID accels apres DPR\r\n");
    {
        /* --- Accel2 (non reconfigure) : verification sante bus AXI --- */
        printf("    [3.6a] accel2 (non reconfigure, att 0xAAAAAA) :\r\n");
        for (volatile int i = 0; i < 500000; i++);
        uint32_t id2 = mmio_r(ACCEL2_BASE) & 0x00FFFFFFu;
        printf("    accel2 ID = 0x%06x  %s\r\n", (unsigned)id2,
               id2 == 0xAAAAAA ? "[OK] bus AXI sain, accel2 intact" :
               id2 == 0xBBBBBB ? "[WARN] accel2 reconfigure ?" : "[WARN]");
        if (id2 != 0xAAAAAA) {
            printf("    [STOP] bus AXI compromis — reprogram FPGA\r\n");
            goto t3_end;
        }

        /* --- Accel1 (reconfigure par DPR) : attente longue puis lecture --- */
        printf("    [3.6b] accel1 (DPR accel_B attendu) :\r\n");
        printf("    Attente 20M cycles (initialisation RP apres DPR)...\r\n");
        for (volatile int i = 0; i < 20000000; i++);

        /* Désactiver le découplage avant la lecture AXI */
        mmio_w(GPIO_DATA, mmio_r(GPIO_DATA) & ~DECOUPLE_ACCEL1);
        printf("    [DPR] decouplage accel1 desactive (GPIO=0x%08x)\r\n", (unsigned)mmio_r(GPIO_DATA));

        /* AVERTISSEMENT : si accel_B ne repond pas a l'AXI, ce read peut bloquer.
         * En cas de blocage : reset FPGA + ./3_build_B2.sh program + relancer. */
        printf("    Lecture AXI accel1 @ 0x%08x...\r\n", (unsigned)ACCEL1_BASE);
        uint32_t id_after = mmio_r(ACCEL1_BASE) & 0x00FFFFFFu;
        printf("    accel1 ID apres DPR = 0x%06x\r\n", (unsigned)id_after);

        if (id_after == 0xBBBBBB) {
            printf("\r\n  *** [SUCCES] DPR : accel_A -> accel_B ***\r\n");
            printf("     Lancer test4 : ./3_build_B2.sh test4\r\n");
        } else if (id_after == 0xAAAAAA) {
            printf("\r\n  [FAIL] accel_A toujours present : DPR n'a pas applique le bitstream\r\n");
            printf("    Causes possibles :\r\n");
            printf("    -> Preamble MASK non actif lors de l'ecriture bitstream\r\n");
            printf("    -> Bitstream partiel incompatible avec le checkpoint statique\r\n");
            printf("    -> Verifier : ./3_build_B2.sh program && ./3_build_B2.sh test3\r\n");
        } else {
            printf("\r\n  [?] ID = 0x%06x — reconfiguration partielle ?\r\n",
                   (unsigned)id_after);
        }
    }

t3_end:
    /* Safety : s'assurer que le découplage est désactivé en fin de test */
    mmio_w(GPIO_DATA, mmio_r(GPIO_DATA) & ~DECOUPLE_ACCEL1);
    printf("\r\n============================================================\r\n");
}

/* =========================================================================
 * Test 4 — DPR complet accel1 (accel_A → accel_B)
 *
 * Prerequis : Test 3 passe (aucun abort sur ecriture complete)
 *
 * Valide :
 *   4.1 ID accel1 avant DPR = 0xAAAAAA (accel_A)
 *   4.2 STAT avant DPR (CFGERR, MASK)
 *   4.3 Preamble MASK=0xF0000000
 *   4.4 Ecriture bitstream partiel accel_B (BS1_ADDR, BS1_NWORDS mots)
 *   4.5 STAT apres DPR (delta, CFGERR)
 *   4.6 ID accel1 apres DPR = 0xBBBBBB (accel_B)
 *
 * Critere de succes : ID accel1 = 0xBBBBBB apres DPR
 * ========================================================================= */
static void test4(void) {
    printf("\r\n");
    printf("============================================================\r\n");
    printf(" Test 4 : DPR complet accel1 (accel_A → accel_B)\r\n");
    printf("============================================================\r\n");

    /* GPIO TRI=0 : bits 31 et 30 en sortie (decouple accel1/accel2) */
    mmio_w(GPIO_TRI, 0x00000000u);  /* tout en sortie */

    if (BS1_NWORDS == 0) {
        printf("  BS1_NWORDS == 0 — lancer d'abord : RM_TARGET=accel_B ./3_build_B2.sh test4\r\n");
        printf("============================================================\r\n");
        return;
    }

    const uint32_t *bs = (const uint32_t *)BS1_ADDR;
    const uint32_t nchunks = (BS1_NWORDS + 62) / 63;

    printf("\r\n[4.1] ID accel1 AVANT DPR\r\n");
    uint32_t id_before = mmio_r(ACCEL1_BASE) & 0x00FFFFFFu;
    printf("    accel1 ID = 0x%06x  %s\r\n", (unsigned)id_before,
           id_before == 0xAAAAAA ? "[accel_A OK]"   :
           id_before == 0xBBBBBB ? "[accel_B — deja reconfigure ?]" : "[inconnu]");

    printf("\r\n[4.2] STAT + MASK avant DPR\r\n");
    uint32_t stat_pre = read_stat();
    uint32_t mask_pre = read_mask();
    print_hwicap("avant DPR :");
    print_stat_decode(stat_pre);
    printf("    MASK = 0x%08x\r\n", (unsigned)mask_pre);

    printf("\r\n[4.3] Preamble MASK=0xF0000000\r\n");
    set_idcode_mask();
    uint32_t mask_set = read_mask();
    printf("    MASK apres preamble = 0x%08x  %s\r\n",
           (unsigned)mask_set,
           mask_set == 0xF0000000 ? "[OK]" : "[FAIL preamble non applique]");

    printf("\r\n[4.4] Ecriture bitstream partiel — %u mots, %u chunks\r\n",
           (unsigned)BS1_NWORDS, (unsigned)nchunks);
    /* Découplage matériel : isolation accel1 pendant l'écriture DPR */
    mmio_w(GPIO_DATA, mmio_r(GPIO_DATA) | DECOUPLE_ACCEL1);
    printf("    [DPR] decouplage accel1 actif (GPIO=0x%08x)\r\n", (unsigned)mmio_r(GPIO_DATA));
    {
        uint32_t anomalies = 0;
        int failed = 0;
        print_hwicap("avant chunk 0 :");
        fifo_reset();
        int64_t dt0 = send_bin(bs, 63);
        if (dt0 < 0) { printf("    [FAIL] timeout chunk 0\r\n"); goto t4_end; }
        printf("    chunk 0 : %u cycles  ASR=0x%08x\r\n",
               (uint32_t)dt0, (unsigned)mmio_r(HWICAP_ASR));

        for (uint32_t ci = 1; ci < nchunks; ci++) {
            uint32_t i     = ci * 63;
            uint32_t chunk = (BS1_NWORDS - i > 63) ? 63 : (BS1_NWORDS - i);
            uint32_t sr_pre  = mmio_r(HWICAP_SR);
            uint32_t asr_pre = mmio_r(HWICAP_ASR);
            fifo_reset();
            int64_t dt = send_bin(bs + i, chunk);
            if (dt < 0) {
                printf("    [FAIL] timeout chunk %u  SR=0x%02x ASR=0x%08x\r\n",
                       (unsigned)ci, (unsigned)sr_pre, (unsigned)asr_pre);
                failed = 1; break;
            }
            if (sr_pre != 0x05 || asr_pre != 0) {
                anomalies++;
                printf("    [ABORT ci=%u] SR=0x%02x ASR=0x%08x\r\n",
                       (unsigned)ci, (unsigned)sr_pre, (unsigned)asr_pre);
            }
            if (ci % 1000 == 0)
                printf("    ... %u/%u  anomalies=%u  SR=0x%02x\r\n",
                       (unsigned)ci, (unsigned)nchunks,
                       (unsigned)anomalies, (unsigned)mmio_r(HWICAP_SR));
        }
        if (!failed) printf("    [OK] ecriture terminee  anomalies=%u\r\n", (unsigned)anomalies);
        print_hwicap("apres DPR :");
    }

t4_end:
    /* Safety : désactiver le découplage (idempotent si déjà fait) */
    mmio_w(GPIO_DATA, mmio_r(GPIO_DATA) & ~DECOUPLE_ACCEL1);
    printf("\r\n[4.5] STAT apres DPR\r\n");
    {
        for (volatile int i = 0; i < 200000; i++);
        uint32_t stat_post = read_stat();
        print_stat_decode(stat_post);
        printf("    delta STAT = 0x%08x\r\n", (unsigned)(stat_post ^ stat_pre));
    }

    printf("\r\n[4.6] ID accel1 APRES DPR\r\n");
    {
        for (volatile int i = 0; i < 200000; i++);
        /* Découplage déjà désactivé à t4_end — lecture AXI normale */
        uint32_t id_after = mmio_r(ACCEL1_BASE) & 0x00FFFFFFu;
        printf("    avant = 0x%06x\r\n", (unsigned)id_before);
        printf("    apres = 0x%06x\r\n", (unsigned)id_after);
        if (id_after == 0xBBBBBB) {
            printf("\r\n  *** [SUCCES] DPR : accel_A -> accel_B ***\r\n");
            printf("     Lancer test5 : ./3_build_B2.sh test5\r\n");
        } else if (id_after == id_before) {
            printf("\r\n  [FAIL] ID inchange — DPR n'a pas applique le bitstream\r\n");
            printf("    -> Verifier CFGERR / ID_ERROR dans [4.5]\r\n");
            printf("    -> Si MASK incorrect : relancer test2\r\n");
        } else {
            printf("\r\n  [?] ID = 0x%06x — reconfiguration partielle ?\r\n",
                   (unsigned)id_after);
        }
    }

    printf("\r\n============================================================\r\n");
}

/* =========================================================================
 * Test 5 — Ping-pong accel_A ↔ accel_B
 *
 * Prerequis : Test 4 passe (DPR accel1 fonctionne)
 *
 * BS1_ADDR (0x81000000) = partial_accel_B_accel1.bin
 * BS2_ADDR (0x81300000) = partial_accel_A_accel1.bin
 *
 * Boucle N fois :
 *   - Charge accel_B → verifie ID=0xBBBBBB
 *   - Charge accel_A → verifie ID=0xAAAAAA
 *
 * Critere de succes : N iterations sans erreur
 * ========================================================================= */
static void test5(void) {
    printf("\r\n");
    printf("============================================================\r\n");
    printf(" Test 5 : Ping-pong accel_A <-> accel_B\r\n");
    printf("============================================================\r\n");
    printf("  TODO : a implementer apres validation test4\r\n");
    printf("============================================================\r\n");
}

/* =========================================================================
 * Point d'entrée — dispatch par TEST_SELECT
 * ========================================================================= */

void dpr_test(void) {
#if   TEST_SELECT == 1
    test1();
#elif TEST_SELECT == 2
    test2();
#elif TEST_SELECT == 3
    test3();
#elif TEST_SELECT == 4
    test4();
#elif TEST_SELECT == 5
    test5();
#else
    test1();
#endif
}

void arch_init(void) {}
