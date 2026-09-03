/*
 * bench_runner.c — Runner batch non-interactif pour campagne ARMOR
 *
 * Usage : remplace main.c lors du build BENCH (ou compile à la place).
 *   - Boucle automatiquement sur tous les scénarios SC-01..SC-08
 *   - Émet UART CSV : scenario,iteration,attendu,observe,latence_cy
 *   - À la fin, dump récapitulatif : scenario,N,TP,FP,FN,TN,L_min,L_p50,L_p99
 *
 * Compilation : remplacer la ligne main.c dans Makefile par bench_runner.c
 *   (ou ajouter -DBENCH_MODE et wrap main.c dans #ifndef BENCH_MODE)
 *
 * IMPORTANT : nécessite le profil BENCH du bitstream (BLOCK_* courts) sinon
 *             chaque scénario gèle l'attaque pour 15 s.
 */

#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <cpu.h>
#include <wfi.h>
#include <uart.h>

/* ============================================================
 * MMIO map (identique à main.c)
 * ============================================================ */
#define MHA_BASE_ADDR           (0x50001000ULL)
#define MHA_CTRL_OFF            (0x00ULL)
#define MHA_STATUS_OFF          (0x08ULL)
#define MHA_BASE_ADDR_OFF       (0x10ULL)
#define MHA_SIZE_OFF            (0x18ULL)
#define MHA_CONFIG_OFF          (0x20ULL)
#define MHA_ATTACK_MODE_OFF     (0x28ULL)

#define LHA_BASE_ADDR           (0x50000000ULL)
#define LHA_CTRL_OFF            (0x00ULL)
#define LHA_STATUS_OFF          (0x08ULL)
#define LHA_BASE_ADDR_OFF       (0x10ULL)
#define LHA_SIZE_OFF            (0x18ULL)
#define LHA_CONFIG_OFF          (0x20ULL)

#define IOMMU_BASE_ADDR         (0x50010000ULL)
#define IOMMU_DDTP_OFF          (0x10ULL)
#define DDT_BASE_ADDR           (0xAFFFF000ULL)

#define ATTACK_DST              (0x80000000ULL)   /* zone OpenSBI (interdite) */
#define LEGIT_DST               (0x91000000ULL)   /* zone guest (autorisée) */
/* Taille de transfert réaliste (64 B = 8 beats @ 64 bits). NB : avec
 * MAX_REQ_PER_WINDOW=16, (64,16) GÈLE tant que le wedge SC04 n'est pas corrigé
 * en RTL (block_req sur write MSI -> AW orphelin -> B IOMMU non drainé). Voir
 * mémoire armor-sc07-storm-fp. XFER_SIZE=8 le masquait par timing mais n'est
 * pas déployable (les vrais accélérateurs font de gros bursts). */
#define XFER_SIZE               (64)

/* Trafic de fond : LHA en lecture/écriture PERMANENTE via le mode "continuous"
 * du RTL (CONFIG bit1). Sature le bus pendant que le MHA attaque.
 * LHA_BG_READ : 1 = lecture, 0 = écriture. */
#ifndef LHA_BG_READ
#define LHA_BG_READ             1
#endif
#define LHA_BG_CFG              (((LHA_BG_READ) ? 0x1ULL : 0x0ULL) | 0x2ULL)

/* CSV verbeux par transaction (1 = chaque ligne, 0 = SUMMARY only).
 * À 115200 bauds, 24700 lignes ~ 3 min de transmission UART. */
#ifndef VERBOSE_CSV
#define VERBOSE_CSV             0
#endif

/* Taille du buffer percentile par scénario (uint64_t). DEUX buffers par
 * stats_t (détection + transaction) : 2 * 512 * 8 = 8 KiB par stats_t.
 * 8 stats_t = 64 KiB en BSS (budget inchangé vs ancien buffer unique 1024). */
#define LAT_CAP                 512

/* STATUS bits */
#define ST_BUSY                 (1ULL << 0)
#define ST_DONE                 (1ULL << 1)
#define ST_ERROR                (1ULL << 2)
#define ST_BLOCKED              (1ULL << 3)
#define ST_BANNED               (1ULL << 4)
#define ST_STORM                (1ULL << 5)
#define ST_OUTS                 (1ULL << 6)
#define ST_MSI                  (1ULL << 7)
#define ST_ANY_BLOCK            (ST_BLOCKED|ST_BANNED|ST_STORM|ST_OUTS|ST_MSI)

/* ============================================================
 * Pointeurs MMIO
 * ============================================================ */
static volatile uint64_t *mha_ctrl    = (volatile uint64_t *)(MHA_BASE_ADDR + MHA_CTRL_OFF);
static volatile uint64_t *mha_status  = (volatile uint64_t *)(MHA_BASE_ADDR + MHA_STATUS_OFF);
static volatile uint64_t *mha_base    = (volatile uint64_t *)(MHA_BASE_ADDR + MHA_BASE_ADDR_OFF);
static volatile uint64_t *mha_size    = (volatile uint64_t *)(MHA_BASE_ADDR + MHA_SIZE_OFF);
static volatile uint64_t *mha_config  = (volatile uint64_t *)(MHA_BASE_ADDR + MHA_CONFIG_OFF);
static volatile uint64_t *mha_mode    = (volatile uint64_t *)(MHA_BASE_ADDR + MHA_ATTACK_MODE_OFF);

static volatile uint64_t *lha_ctrl    = (volatile uint64_t *)(LHA_BASE_ADDR + LHA_CTRL_OFF);
static volatile uint64_t *lha_status  = (volatile uint64_t *)(LHA_BASE_ADDR + LHA_STATUS_OFF);
static volatile uint64_t *lha_base    = (volatile uint64_t *)(LHA_BASE_ADDR + LHA_BASE_ADDR_OFF);
static volatile uint64_t *lha_size    = (volatile uint64_t *)(LHA_BASE_ADDR + LHA_SIZE_OFF);
static volatile uint64_t *lha_config  = (volatile uint64_t *)(LHA_BASE_ADDR + LHA_CONFIG_OFF);

/* ============================================================
 * Helpers
 * ============================================================ */
/* NOTE : `rdcycle` trappe sous Bao (VS-mode) avec exception 22
 * (Virtual Instruction) car `hcounteren.CY` n'est pas armé. On lit
 * `time` (CSR 0xC01) qui, lui, est typiquement autorisé via hcounteren.TM
 * et reflète mtime (≈ cycle/n selon le platform timer). Si même `time`
 * trappe, voir BENCH_NO_TIMER ci-dessous (latences = 0). */
#ifndef BENCH_NO_TIMER
static inline uint64_t read_mcycle(void) {
    uint64_t t;
    asm volatile("csrr %0, time" : "=r"(t));
    return t;
}
#else
static inline uint64_t read_mcycle(void) { return 0; }
#endif

static inline void fence(void) {
    asm volatile("fence rw, rw" ::: "memory");
}

static void set_iommu_mode(uint64_t mode) {
    /* 1 = BARE (passthrough), 2 = 1LVL (DDT actif) */
    volatile uint64_t *ddtp = (volatile uint64_t *)(IOMMU_BASE_ADDR + IOMMU_DDTP_OFF);
    uint64_t ppn = DDT_BASE_ADDR >> 12;
    *ddtp = (ppn << 10) | mode;
    fence();
}

#define DDT_ENTRY_BYTES 64

/* Initialise la DDT (copié de main.c) :
 *   DDT[0] = invalide
 *   DDT[1] = VALIDE   (LHA, ID=1 -> passthrough)
 *   DDT[2] = INVALIDE (MHA, ID=2 -> SLVERR)
 * IMPORTANT : sans cette init la DDT contient du garbage et LHA peut être
 * bloqué (boucle infinie sur wait_done) tandis que MHA peut passer.
 */
static void setup_iommu_ddt(void) {
    volatile uint64_t *ddt = (volatile uint64_t *)DDT_BASE_ADDR;
    for (int i = 0; i < 512; i++) ddt[i] = 0;
    ddt[(1 * DDT_ENTRY_BYTES) / 8] = 0x1ULL;   /* DDT[1].tc.V = 1 */
    fence();
}

static void wait_done(volatile uint64_t *status) {
    uint32_t to = 2000000;
    while ((*status & ST_BUSY) && to > 0) to--;
}

static void wait_cycles(uint64_t n) {
    uint64_t t0 = read_mcycle();
    while ((read_mcycle() - t0) < n) { /* spin */ }
}

/* Arme le LHA en lecture/écriture PERMANENTE (mode continu hardware) : un seul
 * start, l'accélérateur boucle tout seul et sature le bus en arrière-plan. */
static void lha_bg_start(void) {
    *lha_base   = LEGIT_DST;
    *lha_size   = XFER_SIZE;
    *lha_config = LHA_BG_CFG;   /* bit0=read/write + bit1=continuous */
    fence();
    *lha_ctrl   = 1;
}

/* Stoppe le fond : clear du bit continuous -> arrêt au prochain COMPLETE. */
static void lha_bg_stop(void) {
    *lha_config = 0;
    fence();
}

/* ============================================================
 * Classification du verdict (cascade priorité)
 *   retourne char ASCII : M=MSI O=OUTS S=STORM B=BANNED b=BLOCKED
 *                         D=DONE E=ERROR ?=unknown
 * ============================================================ */
static char classify(uint64_t st) {
    if (st & ST_MSI)     return 'M';
    if (st & ST_OUTS)    return 'O';
    if (st & ST_STORM)   return 'S';
    if (st & ST_BANNED)  return 'B';
    if (st & ST_BLOCKED) return 'b';
    if (st & ST_ERROR)   return 'E';
    if (st & ST_DONE)    return 'D';
    return '?';
}

/* "blocked-by-armor" = un des 5 bits ARMOR */
static int armor_blocked(uint64_t st) { return (st & ST_ANY_BLOCK) ? 1 : 0; }

/* ============================================================
 * Statistiques par scénario
 * ============================================================ */
/* Accumulateur de latence (réutilisé pour DÉTECTION et TRANSACTION). */
typedef struct {
    uint64_t L_min, L_max, L_sum;
    uint64_t lat[LAT_CAP];       /* pour percentiles — voir LAT_CAP */
    int n;
} lat_acc_t;

typedef struct {
    const char *name;
    int N;
    int TP, FP, FN, TN;          /* TP = attaque correctement bloquée */
    lat_acc_t det;               /* latence de DÉTECTION (lancement -> 1er verdict) */
    lat_acc_t tx;                /* latence de TRANSACTION (lancement -> BUSY=0)    */
} stats_t;

static void lat_init(lat_acc_t *a) {
    a->L_min = (uint64_t)-1;
    a->L_max = 0;
    a->L_sum = 0;
    a->n = 0;
}

static void lat_add(lat_acc_t *a, uint64_t v) {
    if (!v) return;
    if (v < a->L_min) a->L_min = v;
    if (v > a->L_max) a->L_max = v;
    a->L_sum += v;
    if (a->n < LAT_CAP) a->lat[a->n++] = v;
}

static void stat_init(stats_t *s, const char *name) {
    s->name = name;
    s->N = s->TP = s->FP = s->FN = s->TN = 0;
    lat_init(&s->det);
    lat_init(&s->tx);
}

/* Tri par insertion (n <= 2048) : pas de qsort -> pas de dep libc */
static void sort_u64(uint64_t *a, int n) {
    for (int i = 1; i < n; i++) {
        uint64_t k = a[i];
        int j = i - 1;
        while (j >= 0 && a[j] > k) { a[j + 1] = a[j]; j--; }
        a[j + 1] = k;
    }
}

/* Percentile en arithmetique entiere : p_num/100 (evite soft-float) */
static uint64_t pctl_int(lat_acc_t *a, unsigned p_num) {
    if (a->n == 0) return 0;
    sort_u64(a->lat, a->n);
    unsigned idx = (p_num * (a->n - 1)) / 100u;
    return a->lat[idx];
}

static void stat_add(stats_t *s, int expected_block, int observed_block,
                     uint64_t lat_det, uint64_t lat_tx) {
    s->N++;
    if (expected_block && observed_block)       s->TP++;
    else if (!expected_block && observed_block) s->FP++;
    else if (expected_block && !observed_block) s->FN++;
    else                                        s->TN++;
    lat_add(&s->det, lat_det);
    lat_add(&s->tx,  lat_tx);
}

/* ============================================================
 * Lancer une transaction et chronométrer
 *   accel : 'M' = MHA, 'L' = LHA
 *   return : status final
 * ============================================================ */
/* cfg_bits : registre CONFIG de l'accélérateur. 0 = écriture single (défaut),
 * 1 = lecture single (bit0=read). SC07 (MHA légitime) DOIT utiliser 1 : un
 * write MHA qui passe ARMOR n'obtient jamais sa réponse B dans ce bitstream et
 * deadlock le bus partagé (limitation RTL). En lecture, R/RVALID répond -> OK. */
static uint64_t fire_one(char accel, uint64_t mode, uint64_t dst,
                         uint64_t cfg_bits, uint64_t *out_det, uint64_t *out_tx) {
    volatile uint64_t *ctrl, *status, *base, *sz, *cfg, *amode;
    if (accel == 'M') {
        ctrl=mha_ctrl; status=mha_status; base=mha_base;
        sz=mha_size; cfg=mha_config; amode=mha_mode;
    } else {
        ctrl=lha_ctrl; status=lha_status; base=lha_base;
        sz=lha_size; cfg=lha_config; amode=NULL;
    }
    if (amode) *amode = mode;
    *base = dst;
    *sz   = XFER_SIZE;
    *cfg  = cfg_bits;
    fence();

    /* On capture DEUX latences en un seul vol :
     *  - DÉTECTION : lancement (*ctrl=1) -> PREMIÈRE apparition d'un bit de
     *    verdict. Pour une attaque = bit de blocage ARMOR (STORM/OUTS/MSI/
     *    BANNED/BLOCKED) = temps de réaction du moniteur ; pour du légitime =
     *    DONE/ERROR.
     *  - TRANSACTION : lancement -> BUSY=0 (round-trip complet, DDR incluse).
     * On poll jusqu'à BUSY=0 dans tous les cas pour laisser l'accélérateur idle
     * avant la prochaine itération (sinon le *ctrl=1 suivant est ignoré). */
    uint64_t st;
    uint64_t t_event = 0;
    int      got_event = 0;
    uint32_t to = 2000000;
    uint64_t t0 = read_mcycle();
    *ctrl = 1;
    do {
        st = *status;
        if (!got_event && (st & (ST_ANY_BLOCK | ST_DONE | ST_ERROR))) {
            t_event   = read_mcycle();   /* instant du 1er verdict (détection) */
            got_event = 1;
        }
    } while ((st & ST_BUSY) && --to);
    uint64_t t1 = read_mcycle();         /* fin de transaction (BUSY=0 / timeout) */
    if (!got_event) t_event = t1;        /* aucun verdict vu -> détection = tx */
    *out_det = t_event - t0;
    *out_tx  = t1 - t0;
    return *status;
}

/* ============================================================
 * Run un scénario : N transactions, accumule stats
 *   expected_block = 1 si on attend qu'ARMOR (ou IOMMU) bloque
 * ============================================================ */
static void run_scenario(const char *tag, char accel, uint64_t mode,
                         uint64_t dst, uint64_t cfg_bits, int N,
                         int expected_block, stats_t *st)
{
    stat_init(st, tag);
    printf("# === %s : N=%d accel=%c mode=%lu cfg=0x%lx expect_block=%d\r\n",
           tag, N, accel, (unsigned long)mode,
           (unsigned long)cfg_bits, expected_block);

    /* Compteurs par verdict pour visibilité par scénario sans VERBOSE_CSV.
     * Imprimé une fois en fin de scénario, plus utile que les SUMMARY
     * agrégés tout à la fin (qui peuvent ne jamais venir si on freeze). */
    int c_done=0, c_blk=0, c_ban=0, c_storm=0, c_outs=0, c_msi=0,
        c_err=0, c_unk=0;

    for (int i = 0; i < N; i++) {
        uint64_t lat_det = 0, lat_tx = 0;
        uint64_t status = fire_one(accel, mode, dst, cfg_bits, &lat_det, &lat_tx);
        char v = classify(status);
        int obs = armor_blocked(status) || (status & ST_ERROR);
        stat_add(st, expected_block, obs, lat_det, lat_tx);

        switch (v) {
            case 'D': c_done++;  break;
            case 'b': c_blk++;   break;
            case 'B': c_ban++;   break;
            case 'S': c_storm++; break;
            case 'O': c_outs++;  break;
            case 'M': c_msi++;   break;
            case 'E': c_err++;   break;
            default:  c_unk++;   break;
        }
#if VERBOSE_CSV
        printf("%s,%d,%d,%c,%lu,%lu\r\n",
               tag, i, expected_block, v,
               (unsigned long)lat_det, (unsigned long)lat_tx);
#endif
    }

    volatile uint64_t *st_reg = (accel == 'M') ? mha_status : lha_status;
    printf("# %s STATUS_final=0x%lx | DONE=%d BLOCK=%d BAN=%d STORM=%d "
           "OUTS=%d MSI=%d ERR=%d UNK=%d\r\n",
           tag, (unsigned long)*st_reg,
           c_done, c_blk, c_ban, c_storm, c_outs, c_msi, c_err, c_unk);
}

/* ============================================================
 * Variante "low-and-slow" pour SC-08
 * On envoie K AW, on attend WINDOW+1 cycles, on recommence.
 * Si flow_monitor a WINDOW=100 cy en BENCH, on attend 200 cy.
 * On compte combien de transactions PASSENT (FN attendu).
 * ============================================================ */
#define LAS_BURST   7      /* sous le seuil de 8 */
#define LAS_REPEAT  100    /* nb de salves */
#define LAS_GAP_CY  200    /* > WINDOW_CYCLES BENCH */

static void run_sc08(stats_t *st) {
    stat_init(st, "SC08-LAS");
    printf("# === SC08 low-and-slow : %d salves x %d AW gap=%d cy\r\n",
           LAS_REPEAT, LAS_BURST, LAS_GAP_CY);
    int passed = 0, blocked = 0;
    for (int s = 0; s < LAS_REPEAT; s++) {
        for (int k = 0; k < LAS_BURST; k++) {
            uint64_t lat_det = 0, lat_tx = 0;
            uint64_t status = fire_one('M', 4 /* mode storm */,
                                       LEGIT_DST, 0 /* write */, &lat_det, &lat_tx);
            if (armor_blocked(status)) { blocked++; }
            else                       { passed++;  }
            stat_add(st, /*expected*/1, armor_blocked(status), lat_det, lat_tx);
#if VERBOSE_CSV
            printf("SC08,%d,%d,%c,%lu,%lu\r\n",
                   s*LAS_BURST+k, 1, classify(status),
                   (unsigned long)lat_det, (unsigned long)lat_tx);
#endif
        }
        wait_cycles(LAS_GAP_CY);
    }
    printf("# SC08 : passed=%d blocked=%d (FN=%d, débit_évasion attendu)\r\n",
           passed, blocked, passed);
}

/* ============================================================
 * Récap final
 * ============================================================ */
/* Émet une ligne SUMMARY pour un accumulateur de latence donné (DET ou TX). */
static void dump_acc(const char *tag, const stats_t *s, lat_acc_t *a) {
    uint64_t avg  = s->N ? (a->L_sum / s->N) : 0;
    uint64_t lmin = a->n ? a->L_min : 0;
    uint64_t p50  = pctl_int(a, 50);
    uint64_t p99  = pctl_int(a, 99);
    printf("%s,%s,%d,%d,%d,%d,%d,%lu,%lu,%lu,%lu,%lu\r\n",
           tag, s->name, s->N, s->TP, s->FP, s->FN, s->TN,
           (unsigned long)lmin, (unsigned long)avg,
           (unsigned long)p50, (unsigned long)p99,
           (unsigned long)a->L_max);
}

static void dump(stats_t *s) {
    dump_acc("SUMMARY-DET", s, &s->det);   /* latence de détection  */
    dump_acc("SUMMARY-TX",  s, &s->tx);    /* latence de transaction */
}

/* ============================================================
 * main
 * ============================================================ */
void main(void) {
    uart_init();
    printf("\r\n\r\n###### ARMOR BENCH RUNNER ######\r\n");
    printf("# CSV header : scenario,iter,expected_block,verdict,det_lat_cy,tx_lat_cy\r\n");
    printf("# det_lat = DETECTION (lancement -> 1er verdict ARMOR/DONE)\r\n");
    printf("# tx_lat  = TRANSACTION (lancement -> BUSY=0, round-trip complet)\r\n");
    printf("# verdict : M=MSI O=OUTS S=STORM B=BANNED b=BLOCKED D=DONE E=ERROR\r\n");
    printf("# SUMMARY-DET / SUMMARY-TX,name,N,TP,FP,FN,TN,Lmin,Lavg,Lp50,Lp99,Lmax\r\n");

    /* IOMMU activé (mode 1LVL) pour tous les tests */
    setup_iommu_ddt();      /* DOIT précéder set_iommu_mode(2) */
    set_iommu_mode(2);
    printf("# IOMMU DDT init OK (DDT @ 0x%08x, LHA=allow ID=1, MHA=block ID=2)\r\n",
           (unsigned)DDT_BASE_ADDR);

    /* Configurer DDT : LHA(id=1) autorisé sur 0x91000000, MHA(id=2) interdit */
    /* (à adapter selon ton init DDT existante de main.c) */

    /* IMPORTANT : 'static' obligatoire — ce tableau pèse ~64 KiB et la pile
     * baremetal-guest est limitée à STACK_SIZE = 0x4000 (16 KiB), cf.
     * src/arch/riscv/start.S. Sans 'static' → stack overflow → "no emulation
     * handler for abort" sous Bao. */
    static stats_t s[8];
    int n = 0;

    /* Mode "smoke test" : N petits pour valider la chaîne complète et obtenir
     * le SUMMARY rapidement (~secondes au lieu de minutes). Compile avec
     * -DBENCH_QUICK pour l'activer ; sans le flag = campagne complète. */
#ifdef BENCH_QUICK
#  define N_ATK   50
#  define N_OK    100
#else
#  define N_ATK   1000
#  define N_OK    10000
#endif

    /* ====================================================================
     * Toutes les attaques ET le trafic légitime ciblent la zone guest
     * (LEGIT_DST = 0x91000000). Pour les scénarios MHA, on active DDT[2]
     * temporairement afin que les requêtes traversent l'IOMMU et soient
     * effectivement vues par les moniteurs ARMOR.
     * ==================================================================== */

    /* Ordre NUMÉRIQUE (campagne d'origine) : SC01..04 (attaques) -> SC06 (LHA
     * légitime) -> SC07 (MHA légitime write) -> SC08 (low-and-slow).
     * Fond LHA continu : actif pendant les attaques (SC01..04 et SC08), coupé
     * pendant les baselines légitimes (SC06 pilote lui-même le LHA ; SC07 write
     * doit être propre, et l'IOMMU réchauffé par SC01..04 l'empêche de geler). */

    /* Trafic de fond : LHA continu pour les attaques SC01..SC04. */
    lha_bg_start();
    printf("# LHA background CONTINU arme (%s) base=0x%08x\r\n",
           LHA_BG_READ ? "READ" : "WRITE", (unsigned)LEGIT_DST);

    /* SC-01 : ID spoofing — attendu BANNED par ARMOR
     *   Le détecteur de spoof regarde le TID AXI : indépendant de la dest. */
    {
        volatile uint64_t *ddt = (volatile uint64_t *)DDT_BASE_ADDR;
        ddt[(2 * DDT_ENTRY_BYTES) / 8] = 0x1ULL;
        fence();
        run_scenario("SC01-SPOOF", 'M', /*mode*/1, LEGIT_DST, /*cfg*/0, N_ATK, 1, &s[n++]);
        ddt[(2 * DDT_ENTRY_BYTES) / 8] = 0x0ULL;
        fence();
    }

    /* SC-02 : Request storm — attendu STORM, observé FN (cf. .tex).
     * NB : le STORM n'est PAS un bit coincé (vérifié : SC07 garde son FP storm
     * quelle que soit la position de SC02), donc l'ordre de SC02 n'a pas d'effet
     * de contamination. */
    {
        volatile uint64_t *ddt = (volatile uint64_t *)DDT_BASE_ADDR;
        ddt[(2 * DDT_ENTRY_BYTES) / 8] = 0x1ULL;
        fence();
        run_scenario("SC02-STORM", 'M', /*mode*/4, LEGIT_DST, /*cfg*/0, N_ATK, 1, &s[n++]);
        ddt[(2 * DDT_ENTRY_BYTES) / 8] = 0x0ULL;
        fence();
    }

    /* SC-04 : MSI storm — attendu MSI
     *   Le MSI-monitor voit l'AW avant l'IOMMU, donc la dest configurée
     *   sur le MHA importe peu (le mode 6 redirige vers la zone MSI). On
     *   reste néanmoins sur LEGIT_DST pour homogénéité. */
    {
        volatile uint64_t *ddt = (volatile uint64_t *)DDT_BASE_ADDR;
        ddt[(2 * DDT_ENTRY_BYTES) / 8] = 0x1ULL;
        fence();
        run_scenario("SC04-MSI",   'M', /*mode*/6, LEGIT_DST, /*cfg*/0, N_ATK, 1, &s[n++]);
        ddt[(2 * DDT_ENTRY_BYTES) / 8] = 0x0ULL;
        fence();
    }

    /* Coupe le fond LHA : SC06 (pilote le LHA) et SC07 (baseline write) propres. */
    lha_bg_stop();

    /* SC-06 : LHA légitime seul. */
    run_scenario("SC06-LHAOK", 'L', /*mode*/0, LEGIT_DST, /*cfg*/0, N_OK, 0, &s[n++]);

    /* SC-07 : MHA légitime (mode 0) — DDT[2] valide — en LECTURE (cfg=1).
     * IMPORTANT : un write MHA qui PASSE ARMOR n'obtient jamais sa réponse B
     * dans ce bitstream (l'AW reste outstanding -> deadlock du bus partagé) ;
     * c'est confirmé indépendamment de la position/réchauffage IOMMU. Les writes
     * d'ATTAQUE (SC01..04) ne gèlent pas car ARMOR synthétise leur verdict sans
     * dépendre d'un vrai B. On mesure donc le baseline MHA légitime en LECTURE
     * (R/RVALID répond) ; un baseline write nécessiterait un fix RTL. */
    {
        volatile uint64_t *ddt = (volatile uint64_t *)DDT_BASE_ADDR;
        ddt[(2 * DDT_ENTRY_BYTES) / 8] = 0x1ULL;
        fence();
        run_scenario("SC07-MHAOK", 'M', /*mode*/0, LEGIT_DST, /*cfg*/1, N_OK, 0, &s[n++]);
        ddt[(2 * DDT_ENTRY_BYTES) / 8] = 0x0ULL;
        fence();
    }

    /* SC-08 : low-and-slow — vise LEGIT_DST avec DDT[2] valide pour que les
     * rafales atteignent ARMOR (sinon IOMMU les tue avant). Fond LHA réactivé
     * pour la contention. */
    lha_bg_start();
    {
        volatile uint64_t *ddt = (volatile uint64_t *)DDT_BASE_ADDR;
        ddt[(2 * DDT_ENTRY_BYTES) / 8] = 0x1ULL;
        fence();
        run_sc08(&s[n++]);
        ddt[(2 * DDT_ENTRY_BYTES) / 8] = 0x0ULL;
        fence();
    }

    /* SC-03 : Outstanding overflow — attendu OUTS — EXÉCUTÉ EN DERNIER.
     * Le mode 5 inonde des lectures AR avec r_ready=0 : ces lectures ne se
     * complètent jamais, donc le compteur outstanding du wrapper reste saturé
     * et `outs_i` reste asserté pour le RESTE de la campagne. Tant qu'il tournait
     * avant SC04/SC07, ces scénarios héritaient d'un OUTS parasite (sticky_outs
     * se re-latche après chaque clear-au-start). En le plaçant tout à la fin,
     * plus aucun scénario ne s'exécute après -> aucune contamination. */
    {
        volatile uint64_t *ddt = (volatile uint64_t *)DDT_BASE_ADDR;
        ddt[(2 * DDT_ENTRY_BYTES) / 8] = 0x1ULL;
        fence();
        run_scenario("SC03-OUTS",  'M', /*mode*/5, LEGIT_DST, /*cfg*/0, N_ATK, 1, &s[n++]);
        ddt[(2 * DDT_ENTRY_BYTES) / 8] = 0x0ULL;
        fence();
    }
    lha_bg_stop();   /* arrêt du trafic de fond */

    printf("\r\n###### RESUME ######\r\n");
    for (int i = 0; i < n; i++) dump(&s[i]);
    printf("###### END ######\r\n");

    /* Fin : on rentre en wfi forever */
    while (1) asm volatile("wfi");
}
