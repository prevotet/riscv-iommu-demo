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
#define MHA_MSI_ADDR_OFF        (0x38ULL)

#define LHA_BASE_ADDR           (0x50000000ULL)
#define LHA_CTRL_OFF            (0x00ULL)
#define LHA_STATUS_OFF          (0x08ULL)
#define LHA_BASE_ADDR_OFF       (0x10ULL)
#define LHA_SIZE_OFF            (0x18ULL)
#define LHA_CONFIG_OFF          (0x20ULL)

/* CSR des sec_wrappers ARMOR (interface CPU du wrapper).
 * Sans cette configuration, ENFORCE vaut 0 au reset : les moniteurs observent
 * mais ne bloquent jamais, et la campagne mesurerait 0 % de detection. */
#define WRAP1_BASE_ADDR         (0x50002000ULL)   /* sec_wrapper du LHA (ID=1) */
#define WRAP2_BASE_ADDR         (0x50003000ULL)   /* sec_wrapper du MHA (ID=2) */
#define WRAP_ID_CFG_OFF         (0x00ULL)
#define WRAP_MSI_ADDR_OFF       (0x08ULL)
#define WRAP_CTRL_OFF           (0x10ULL)
#define WRAP_STATUS_OFF         (0x18ULL)
#define WRAP_STICKY_OFF         (0x20ULL)
#define WRAP_FAILCNT_OFF        (0x28ULL)
#define WRAP_CNT_BANNED_OFF     (0x30ULL)
#define WRAP_CNT_STORM_OFF      (0x38ULL)
#define WRAP_CNT_OUTS_OFF       (0x40ULL)
#define WRAP_CNT_MSI_OFF        (0x48ULL)
#define WRAP_DEVID_LAST_OFF     (0x50ULL)
#define WRAP_MAGIC_OFF          (0x58ULL)

#define WRAP_CTRL_ENFORCE       (1ULL << 0)
#define WRAP_CTRL_STICKY_CLR    (1ULL << 1)
#define WRAP_CTRL_CNT_CLR       (1ULL << 2)
#define WRAP_MAGIC_EXPECTED     (0x41524D4F52000001ULL)

#define IOMMU_BASE_ADDR         (0x50010000ULL)
#define IOMMU_DDTP_OFF          (0x10ULL)
#define DDT_BASE_ADDR           (0xAFFFF000ULL)

#define ATTACK_DST              (0x80000000ULL)   /* zone OpenSBI (interdite) */
#define LEGIT_DST               (0x91000000ULL)   /* zone guest (autorisée) */
/* Adresse surveillée par le msi_detector, VOLONTAIREMENT distincte de
 * LEGIT_DST. Le détecteur classe en MSI toute écriture vers l'adresse
 * configurée : les faire coïncider comptait tout le trafic légitime comme des
 * MSI et saturait interrupt_monitor (mesuré : 1 024 012 événements pour 1000
 * transactions). Seul le mode 6 vise cette adresse. */
#define MSI_TARGET_DST          (0x91008000ULL)
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
static volatile uint64_t *mha_msi_addr= (volatile uint64_t *)(MHA_BASE_ADDR + MHA_MSI_ADDR_OFF);

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

/* Arme les deux sec_wrappers ARMOR.
 *   ID_CFG   : identifiant legitime attendu = STREAM_ID cable dans accel_wrap
 *              (1 pour le LHA, 2 pour le MHA). id_comparator exige fixed_id != 0,
 *              donc sans cette ecriture legit_hit reste a 0 et request_manager
 *              fermerait tout le chemin des que ENFORCE passe a 1.
 *   MSI_ADDR : adresse surveillee par msi_detector. Le scenario SC04 ecrit sur
 *              LEGIT_DST, c'est donc cette adresse qu'il faut declarer.
 *   ENFORCE  : arme le blocage. A 0 (reset) le wrapper est transparent, ce qui
 *              donne la baseline "sans ARMOR" dans le meme bitstream.
 */
static void armor_wrap_init(int enforce) {
    volatile uint64_t *w1 = (volatile uint64_t *)WRAP1_BASE_ADDR;
    volatile uint64_t *w2 = (volatile uint64_t *)WRAP2_BASE_ADDR;

    uint64_t m1 = w1[WRAP_MAGIC_OFF / 8];
    uint64_t m2 = w2[WRAP_MAGIC_OFF / 8];
    printf("# ARMOR CSR magic : wrap1=0x%08x%08x wrap2=0x%08x%08x\r\n",
           (unsigned)(m1 >> 32), (unsigned)m1,
           (unsigned)(m2 >> 32), (unsigned)m2);
    if (m1 != WRAP_MAGIC_EXPECTED || m2 != WRAP_MAGIC_EXPECTED) {
        printf("# ATTENTION : magic ARMOR inattendu — bitstream sans interface CSR ?\r\n");
    }

    w1[WRAP_ID_CFG_OFF   / 8] = 1ULL;         /* LHA : STREAM_ID = 1 */
    w2[WRAP_ID_CFG_OFF   / 8] = 2ULL;         /* MHA : STREAM_ID = 2 */
    w2[WRAP_MSI_ADDR_OFF / 8] = MSI_TARGET_DST;   /* cible des ecritures SC04 */
    *mha_msi_addr             = MSI_TARGET_DST;   /* meme adresse cote accel */

    uint64_t ctrl = (enforce ? WRAP_CTRL_ENFORCE : 0ULL)
                  | WRAP_CTRL_STICKY_CLR | WRAP_CTRL_CNT_CLR;
    w1[WRAP_CTRL_OFF / 8] = ctrl;
    w2[WRAP_CTRL_OFF / 8] = ctrl;
    fence();

    printf("# ARMOR arme : ENFORCE=%d, ID_CFG w1=1 w2=2, MSI_ADDR=0x%08x\r\n",
           enforce, (unsigned)MSI_TARGET_DST);
    printf("# ARMOR devid_last : w1=%lu w2=%lu\r\n",
           (unsigned long)w1[WRAP_DEVID_LAST_OFF / 8],
           (unsigned long)w2[WRAP_DEVID_LAST_OFF / 8]);
}

/* Vide les compteurs d'evenements ARMOR entre deux scenarios. */
static void armor_wrap_clear(void) {
    volatile uint64_t *w1 = (volatile uint64_t *)WRAP1_BASE_ADDR;
    volatile uint64_t *w2 = (volatile uint64_t *)WRAP2_BASE_ADDR;
    w1[WRAP_CTRL_OFF / 8] = w1[WRAP_CTRL_OFF / 8] | WRAP_CTRL_STICKY_CLR | WRAP_CTRL_CNT_CLR;
    w2[WRAP_CTRL_OFF / 8] = w2[WRAP_CTRL_OFF / 8] | WRAP_CTRL_STICKY_CLR | WRAP_CTRL_CNT_CLR;
    fence();
}

/* Imprime les compteurs des DEUX wrappers : mesure independante des verdicts
 * vus par l'accelerateur, utile pour recouper les FN. Ne lire que le wrapper 2
 * laissait aveugle sur les scenarios LHA (SC06), qui passent par le wrapper 1.
 * NB : fail= est le failure_count interne au security_monitor ; il est libre,
 * non remis a zero par CNT_CLR, et repasse par 0 tous les 256. */
static void armor_wrap_report_one(const char *tag, const char *who, uint64_t base) {
    volatile uint64_t *w = (volatile uint64_t *)base;
    printf("# ARMORCNT,%s,%s,sticky=0x%08x,fail=%lu,ban=%lu,storm=%lu,outs=%lu,msi=%lu\r\n",
           tag, who,
           (unsigned)w[WRAP_STICKY_OFF      / 8],
           (unsigned long)w[WRAP_FAILCNT_OFF    / 8],
           (unsigned long)w[WRAP_CNT_BANNED_OFF / 8],
           (unsigned long)w[WRAP_CNT_STORM_OFF  / 8],
           (unsigned long)w[WRAP_CNT_OUTS_OFF   / 8],
           (unsigned long)w[WRAP_CNT_MSI_OFF    / 8]);
}

static void armor_wrap_report(const char *tag) {
    armor_wrap_report_one(tag, "w1", WRAP1_BASE_ADDR);
    armor_wrap_report_one(tag, "w2", WRAP2_BASE_ADDR);
}

/* Initialise la DDT (copié de main.c) :
 *   DDT[0] = invalide
 *   DDT[1] = VALIDE (LHA, ID=1 -> passthrough)
 *   DDT[2] = VALIDE (MHA, ID=2 -> passthrough)
 * IMPORTANT : sans cette init la DDT contient du garbage et LHA peut être
 * bloqué (boucle infinie sur wait_done) tandis que MHA peut passer.
 *
 * DDT[2] est posée UNE SEULE FOIS et n'est plus rebasculée pendant la
 * campagne. La version précédente la rendait valide avant chaque scénario MHA
 * et invalide après, avec un simple `fence rw, rw`. Or l'IOMMU RISC-V met en
 * cache les entrées du répertoire de devices : la spec impose une commande
 * IODIR.INVAL_DDT après toute modification, et ce bench ne configure aucune
 * file de commandes (seul `ddtp` est écrit). Le fence n'ordonne que les accès
 * du CPU, il ne touche ni le cache de l'IOMMU ni la recopie en DDR de la ligne
 * de cache CPU, que l'IOMMU relit par son propre port. L'entrée cachée pour
 * DID=2 restait donc invalide quoi qu'on écrive en mémoire : toutes les
 * requêtes MHA fautaient (FQ : CAUSE 258, DID 2), ne se complétaient jamais et
 * restaient en travers du multiplexeur AXI 2:1 partagé — le LHA, pourtant
 * autorisé, se retrouvait bloqué en tête de file derrière elles.
 *
 * Bloquer le MHA au niveau de l'IOMMU n'était de toute façon pas souhaitable :
 * c'est le rôle d'ARMOR de rattraper l'usurpation d'ID, et mesurer un scénario
 * où l'IOMMU bloque déjà en parallèle brouille l'attribution du verdict.
 */
static void setup_iommu_ddt(void) {
    volatile uint64_t *ddt = (volatile uint64_t *)DDT_BASE_ADDR;
    for (int i = 0; i < 512; i++) ddt[i] = 0;
    ddt[(1 * DDT_ENTRY_BYTES) / 8] = 0x1ULL;   /* DDT[1].tc.V = 1 */
    ddt[(2 * DDT_ENTRY_BYTES) / 8] = 0x1ULL;   /* DDT[2].tc.V = 1 */
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
#ifdef BENCH_TRACE_MMIO
/* Nombre d'appels traces PAR SCENARIO. Reamorce dans run_scenario : sinon les
 * premieres traces sont consommees par le premier scenario de la campagne et
 * celui qui gele n'en a plus une seule -- l'erreur du build precedent. */
#  ifndef TRACE_N
#    define TRACE_N 3
#  endif
static int g_trace_left = TRACE_N;
#  define TRACE_ARM() do { g_trace_left = TRACE_N; } while (0)
#else
#  define TRACE_ARM() do { } while (0)
#endif

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
#ifdef BENCH_TRACE_MMIO
    /* DIAGNOSTIC (-DBENCH_TRACE_MMIO) — pas un mode de campagne.
     *
     * Le gel constaté sur carte est dans fire_one : la boucle de sondage
     * ci-dessous est bornée par `to`, donc si les lectures revenaient on en
     * sortirait et l'itération s'imprimerait. Un accès MMIO isolé ne revient
     * donc jamais, et les FSM des ports de config (cw_state_q / cr_state_q de
     * accel_wrap, w_state_q / r_state_q du wrapper) n'ont ni timeout ni
     * échappatoire : un handshake perdu les verrouille définitivement.
     *
     * Chaque accès est encadré d'une trace. La DERNIÈRE ligne imprimée nomme
     * l'accès qui ne revient pas. L'UART est un autre périphérique et continue
     * de fonctionner pendant que le port de config est bloqué.
     *
     * Limité aux TRACE_N premiers appels, sinon la sortie noie la campagne. */
    int tr = (g_trace_left > 0);
    if (tr) g_trace_left--;
#  define TRACE(msg) do { if (tr) printf("#   MMIO %s\r\n", (msg)); } while (0)
#else
#  define TRACE(msg) do { } while (0)
#endif

    TRACE("-> ecriture ATTACK_MODE");
    if (amode) *amode = mode;
    TRACE("   ecriture ATTACK_MODE OK ; -> BASE");
    *base = dst;
    TRACE("   BASE OK ; -> SIZE");
    *sz   = XFER_SIZE;
    TRACE("   SIZE OK ; -> CONFIG");
    *cfg  = cfg_bits;
    TRACE("   CONFIG OK");
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
    TRACE("-> ecriture CTRL=1 (lancement)");
    *ctrl = 1;
    TRACE("   CTRL OK ; -> 1re lecture STATUS");
    int first_read = 1;
    do {
        st = *status;
        if (first_read) { TRACE("   1re lecture STATUS OK, sondage en cours"); first_read = 0; }
        if (!got_event && (st & (ST_ANY_BLOCK | ST_DONE | ST_ERROR))) {
            t_event   = read_mcycle();   /* instant du 1er verdict (détection) */
            got_event = 1;
        }
    } while ((st & ST_BUSY) && --to);
    uint64_t t1 = read_mcycle();         /* fin de transaction (BUSY=0 / timeout) */
    if (!got_event) t_event = t1;        /* aucun verdict vu -> détection = tx */
    *out_det = t_event - t0;
    *out_tx  = t1 - t0;
    TRACE("-> lecture STATUS finale");
    st = *status;
    TRACE("   lecture STATUS finale OK");
    return st;
}
#undef TRACE

/* ============================================================
 * Run un scénario : N transactions, accumule stats
 *   expected_block = 1 si on attend qu'ARMOR (ou IOMMU) bloque
 * ============================================================ */
static void run_scenario(const char *tag, char accel, uint64_t mode,
                         uint64_t dst, uint64_t cfg_bits, int N,
                         int expected_block, stats_t *st)
{
    stat_init(st, tag);
    TRACE_ARM();            /* tracer les premiers acces MMIO DE CE scenario */
    armor_wrap_clear();     /* compteurs ARMOR remis a zero par scenario */
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
    armor_wrap_report(tag);   /* recoupement cote wrapper, independant de l'accel */
}

/* ============================================================
 * Variante "low-and-slow" pour SC-08
 * On envoie K AW, on attend WINDOW+1 cycles, on recommence.
 * Si flow_monitor a WINDOW=100 cy en BENCH, on attend 200 cy.
 * On compte combien de transactions PASSENT (FN attendu).
 *
 * MODE 0, PAS MODE 4. Le mode 4 est le mode tempête : il émet
 * STORM_REQS = 16 requêtes par appel, si bien que LAS_BURST=7 faisait
 * 7 x 16 = 112 requêtes par salve — très au-dessus du seuil de 8 sous
 * lequel ce scénario est censé rester. Il était donc systématiquement
 * détecté et ne mesurait rien qu'SC02 ne mesure déjà. Le mode 0 émet
 * une requête par appel, donc LAS_BURST requêtes par salve.
 *
 * Vérifié en simulation (armor/tb, scénario 3), à salve et écart
 * identiques (12 salves x 7, gap 200 cy) :
 *   mode 4 -> 0 passées, 84 bloquées, verdict STORM
 *   mode 0 -> 84 passées, 0 bloquées, aucun verdict  <- l'évasion voulue
 * ============================================================ */
#define LAS_BURST   7      /* sous le seuil de 8 */
#define LAS_REPEAT  100    /* nb de salves */
#define LAS_GAP_CY  200    /* > WINDOW_CYCLES BENCH */

static void run_sc08(stats_t *st) {
    stat_init(st, "SC08-LAS");
    TRACE_ARM();
    printf("# === SC08 low-and-slow : %d salves x %d AW gap=%d cy\r\n",
           LAS_REPEAT, LAS_BURST, LAS_GAP_CY);
    int passed = 0, blocked = 0;
    for (int s = 0; s < LAS_REPEAT; s++) {
        for (int k = 0; k < LAS_BURST; k++) {
            uint64_t lat_det = 0, lat_tx = 0;
            uint64_t status = fire_one('M', 0 /* trafic normal : 1 requete */,
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
    /* Moyenne sur le nombre d'echantillons REELLEMENT accumules (a->n), pas sur
     * le nombre d'iterations du scenario (s->N). lat_add() rejette les valeurs
     * nulles : diviser par s->N sous-estimait la moyenne d'un facteur n/N des
     * que l'un des deux accumulateurs comptait un zero. C'est ce qui faisait
     * lire SUMMARY-DET a ~0,52 x SUMMARY-TX sur la campagne du 2026-09-08, alors
     * que le FSM de accel_wrap pose busy_q=0 et done_q=1 dans le meme cycle et
     * que les deux latences devraient donc etre quasi egales.
     *
     * La colonne `n` est emise pour que l'ecart n < N reste visible dans le CSV
     * au lieu d'etre absorbe par la moyenne. */
    uint64_t avg  = a->n ? (a->L_sum / (uint64_t)a->n) : 0;
    uint64_t lmin = a->n ? a->L_min : 0;
    uint64_t p50  = pctl_int(a, 50);
    uint64_t p99  = pctl_int(a, 99);
    printf("%s,%s,%d,%d,%d,%d,%d,%d,%lu,%lu,%lu,%lu,%lu\r\n",
           tag, s->name, s->N, a->n, s->TP, s->FP, s->FN, s->TN,
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
    printf("# SUMMARY-DET / SUMMARY-TX,name,N,n,TP,FP,FN,TN,Lmin,Lavg,Lp50,Lp99,Lmax\r\n");

    /* IOMMU activé (mode 1LVL) pour tous les tests */
    setup_iommu_ddt();      /* DOIT précéder set_iommu_mode(2) */
    set_iommu_mode(2);
    printf("# IOMMU DDT init OK (DDT @ 0x%08x, LHA=allow ID=1, MHA=allow ID=2)\r\n",
           (unsigned)DDT_BASE_ADDR);

    /* Arme ARMOR. Compiler avec -DARMOR_ENFORCE=0 pour la baseline sans
     * blocage (meme bitstream, meme binaire a un define pres). */
#ifndef ARMOR_ENFORCE
#define ARMOR_ENFORCE 1
#endif
    armor_wrap_init(ARMOR_ENFORCE);

    /* Configurer DDT : LHA(id=1) et MHA(id=2) autorisés sur 0x91000000.
     * Le filtrage des accès illégitimes est le rôle d'ARMOR, pas de la DDT. */
    /* (à adapter selon ton init DDT existante de main.c) */

    /* IMPORTANT : 'static' obligatoire — ce tableau pèse ~64 KiB et la pile
     * baremetal-guest est limitée à STACK_SIZE = 0x4000 (16 KiB), cf.
     * src/arch/riscv/start.S. Sans 'static' → stack overflow → "no emulation
     * handler for abort" sous Bao. */
    static stats_t s[9];
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
     * (LEGIT_DST = 0x91000000). DDT[1] et DDT[2] sont valides pour toute la
     * campagne (cf. setup_iommu_ddt) : les requêtes traversent l'IOMMU et sont
     * effectivement vues par les moniteurs ARMOR, qui seuls décident du
     * blocage.
     * ==================================================================== */

    /* ====================================================================
     * ORDRE : les scénarios LÉGITIMES ET SC08 D'ABORD, les attaques ensuite.
     *
     * Ce n'est pas cosmétique. security_monitor maintient block_ip_o pendant
     * BLOCK_DURATION_C = 100 000 cycles, soit ~2 ms à 50 MHz, et AUCUN CSR ne
     * l'efface : STICKY_CLR ne vide que le registre collant, CNT_CLR que les
     * compteurs, et failure_count reste à 3 pour le reste de la campagne. Tout
     * scénario démarrant dans cette fenêtre après SC01 hérite du verdict
     * BANNED, quel que soit son trafic.
     *
     * Dans l'ordre numérique précédent (SC01, SC02, SC04, SC06, SC07, SC08,
     * SC03), SC02 et SC04 démarraient forcément dans cette fenêtre et les
     * premières itérations de SC06 pouvaient y être encore : une source de
     * faux positifs indépendante de tout défaut de détecteur.
     *
     * Vérifié en simulation (armor/tb, scénario 3) : le trafic de SC07 rejoué
     * juste après SC01 sort verdict BANNED avec err 8/8, contre aucun verdict
     * et err 0/8 sur un wrapper vierge.
     *
     * SC03-OUTS reste en dernier pour la raison d'origine, ci-dessous.
     *
     * Fond LHA continu : coupé pendant SC06 (qui pilote lui-même le LHA) et
     * SC07, actif pour SC08 et les attaques.
     * ==================================================================== */

    /* SC-06 : LHA légitime seul, sur un wrapper vierge de tout verdict. */
    run_scenario("SC06-LHAOK", 'L', /*mode*/0, LEGIT_DST, /*cfg*/0, N_OK, 0, &s[n++]);

    /* SC-07 : MHA légitime (mode 0) — en ÉCRITURE (cfg=0).
     * Ce baseline était mesuré en lecture parce qu'un write MHA passant ARMOR
     * n'obtenait jamais sa réponse B et gelait le bus partagé. C'était la
     * conséquence du décalage resp_t/resp_slv_t sur la réponse aval : le
     * wrapper voyait aw_ready, w_ready et b_valid câblés à 0. Corrigé, et le
     * write légitime aboutit — vérifié en simulation (armor/tb, scénario 3) :
     * 17 cycles, aucun verdict, err 0/8.
     *
     * Le retour en écriture rend ce baseline comparable aux scénarios
     * d'attaque, qui sont tous des écritures sauf SC03. Les campagnes
     * antérieures à ce correctif mesuraient une lecture : leurs latences SC07
     * ne sont pas comparables à celles-ci. */
    run_scenario("SC07-MHAOK", 'M', /*mode*/0, LEGIT_DST, /*cfg*/0, N_OK, 0, &s[n++]);

    /* Trafic de fond : LHA continu pour SC08 puis les attaques.
     *
     * -DBENCH_NO_LHA_BG le supprime. DIAGNOSTIC : l'ecriture de CTRL=1 de la
     * premiere iteration de SC01 ne revient jamais, alors que les quatre
     * ecritures precedentes passent par la meme FSM. CTRL est la seule a avoir
     * un effet de bord -- elle lance l'accelerateur sur axi_dma, donc vers
     * ARMOR, le mux 2:1 et l'IOMMU. Sans fond LHA, ce chemin n'est plus
     * partage :
     *   ne gele plus -> le gel exige la contention, le wedge est dans le mux
     *                   ou l'IOMMU ;
     *   gele encore  -> le spoof seul suffit, c'est la retenue d'ARMOR sur le
     *                   wrapper 2. */
#ifndef BENCH_NO_LHA_BG
    lha_bg_start();
#else
    printf("# DIAG : fond LHA DESACTIVE (-DBENCH_NO_LHA_BG)\r\n");
#endif
    printf("# LHA background CONTINU arme (%s) base=0x%08x\r\n",
           LHA_BG_READ ? "READ" : "WRITE", (unsigned)LEGIT_DST);

    /* SC-08 : low-and-slow — AVANT tout spoof, sinon il est mesuré sur un
     * device banni et tout y paraît bloqué. Fond LHA actif pour la contention. */
    run_sc08(&s[n++]);

    /* SC-01 : ID spoofing — attendu BANNED par ARMOR
     *   Le détecteur de spoof regarde le TID AXI : indépendant de la dest.
     *   À partir d'ici et pour ~2 ms, le device reste banni. */
    run_scenario("SC01-SPOOF", 'M', /*mode*/1, LEGIT_DST, /*cfg*/0, N_ATK, 1, &s[n++]);

    /* SC-02 : Request storm — attendu STORM. */
    run_scenario("SC02-STORM", 'M', /*mode*/4, LEGIT_DST, /*cfg*/0, N_ATK, 1, &s[n++]);

    /* SC-04 : MSI storm — attendu MSI
     *   Le MSI-monitor voit l'AW avant l'IOMMU, donc la dest configurée
     *   sur le MHA importe peu (le mode 6 redirige vers la zone MSI). On
     *   reste néanmoins sur LEGIT_DST pour homogénéité. */
    run_scenario("SC04-MSI",   'M', /*mode*/6, LEGIT_DST, /*cfg*/0, N_ATK, 1, &s[n++]);

    /* SC-03 : Outstanding overflow — attendu OUTS — EXÉCUTÉ EN DERNIER.
     * Le mode 5 inonde des lectures AR avec r_ready=0 : ces lectures ne se
     * complètent jamais, donc le compteur outstanding du wrapper reste saturé
     * et `outs_i` reste asserté pour le RESTE de la campagne. Tant qu'il tournait
     * avant SC04/SC07, ces scénarios héritaient d'un OUTS parasite (sticky_outs
     * se re-latche après chaque clear-au-start). En le plaçant tout à la fin,
     * plus aucun scénario ne s'exécute après -> aucune contamination. */
    run_scenario("SC03-OUTS",  'M', /*mode*/5, LEGIT_DST, /*cfg*/0, N_ATK, 1, &s[n++]);
#ifndef BENCH_NO_LHA_BG
    lha_bg_stop();   /* arrêt du trafic de fond */
#endif

    printf("\r\n###### RESUME ######\r\n");
    for (int i = 0; i < n; i++) dump(&s[i]);
    printf("###### END ######\r\n");

    /* Fin : on rentre en wfi forever */
    while (1) asm volatile("wfi");
}
