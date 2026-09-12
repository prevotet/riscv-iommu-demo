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
#define WRAP_CTRL_AWFIX         (1ULL << 3)   /* INERTE : tentative refutee */
#define WRAP_CTRL_WSKID         (1ULL << 4)   /* etage d'un emplacement sur W */
#define WRAP_CTRL_FRESH         (1ULL << 5)   /* verdict d'identite frais exige (v7) */
#define WRAP_CTRL_WCAP          (1ULL << 7)   /* dette W comptee a la capture (v8) */
#define WRAP_CTRL_RHOLD         (1ULL << 8)   /* reponses B/R tenues jusqu'au ready (v9) */
#define WRAP_CTRL_WFATE         (1ULL << 9)   /* sort de chaque AW, W des AW coupes absorbe (v10) */
#define WRAP_CTRL_BFATE         (1ULL << 10)  /* un B par ecriture, dans l'ordre (v12) */
/* CTRL[6] TX_BLOCK n'a volontairement AUCUNE option ici : nuisible seul
 * (retraits AW de SC04 : 1 -> 4 au banc). Voir wrapper.sv. */

/* Compiler avec -DARMOR_WSKID=1 pour activer l'etage W (CTRL[4]).
 *
 * C'est le correctif du retrait de VALID mesure le 2026-09-10 : la coupure d'un
 * beat W est decidee A LA CAPTURE, un beat entre est tenu jusqu'a son ready, et
 * le ready rendu au maitre est celui de l'etage. Le retrait devient impossible
 * par construction.
 *
 * A 0 (defaut) l'etage est en derivation : le MEME bitstream donne donc les deux
 * comportements, et c'est ainsi qu'on verifiera le correctif -- `retr=0/0/4/0`
 * et le gel a 0, `retr=0/0/0/0` et la campagne qui passe a 1.
 *
 * La simulation ne peut PAS valider ce correctif : le banc n'a jamais reproduit
 * le retrait sur W (ni IOMMU ni crossbar modelises, et la FSM de l'accelerateur
 * n'y chevauche pas ses ecritures). La carte est le seul juge. */
#ifndef ARMOR_WSKID
#define ARMOR_WSKID 0
#endif

/* Compiler avec -DARMOR_FRESH=1 pour exiger un verdict d'identite FRAIS
 * (CTRL[5], MAGIC v7).
 *
 * Ferme la fenetre de deux cycles ou une adresse etait jugee sur le verdict de
 * la requete PRECEDENTE (Device_ID_write_enable_o est registre). Supprime au
 * banc le retrait d'AW de SC01, le dernier scenario qui gele. Cout mesure au
 * banc : +2 cycles par transaction legitime.
 *
 * Independant de ARMOR_WSKID : valider FRESH seul d'abord, puis FRESH+WSKID. */
#ifndef ARMOR_FRESH
#define ARMOR_FRESH 0
#endif

/* Compiler avec -DARMOR_WCAP=1 pour compter la dette W A LA CAPTURE dans
 * l'etage W (CTRL[7], MAGIC v8). N'a d'effet qu'avec ARMOR_WSKID=1.
 *
 * Correctif d'un defaut de l'etage W invisible a tous les compteurs : sa
 * capture etait autorisee par la dette W comptee EN AVAL, qui ignore un dernier
 * beat deja entre dans l'etage. Pendant une tempete d'ecritures bloquee, le beat
 * d'une ecriture COUPEE y etait capture, restait presente en aval, et partait
 * avec l'adresse legitime suivante -- chaque ecriture decalee d'un cran ensuite.
 * Demontre au banc le 2026-09-11 (aval a W conditionne, latence W de 40 cycles :
 * 147 beats avec la donnee d'une autre ecriture) ; releve sur les trois runs
 * carte W_SKID=1 comme un beat `W V- last` bloque en aval avec w_owed=0. */
#ifndef ARMOR_WCAP
#define ARMOR_WCAP 0
#endif

/* Compiler avec -DARMOR_RHOLD=1 pour tenir toute reponse B/R presentee au maitre
 * a l'identique jusqu'a son ready (CTRL[8], MAGIC v9).
 *
 * Correctif du troisieme site de retrait de VALID : response_manager retirait
 * ses reponses des que sa branche changait -- SLVERR fabrique a la fin d'un
 * blocage, ou R reelle a l'ouverture d'une attente de verdict. SC03 sur carte :
 * b-r = 16 sans FRESH, 73 avec ; au banc, 8 -> 0 sur SC03. L'attente laisse
 * aussi passer les reponses de l'aval : risque de perte lu au RTL, jamais
 * observe au banc. */
#ifndef ARMOR_RHOLD
#define ARMOR_RHOLD 0
#endif

/* Compiler avec -DARMOR_WFATE=1 pour suivre le sort de chaque AW acquitte au
 * maitre -- admis en aval ou coupe -- et absorber le W des AW coupes meme hors
 * blocage (CTRL[9], MAGIC v10). N'a d'effet qu'avec ARMOR_WSKID=1 ; supplante
 * ARMOR_WCAP.
 *
 * Correctif des timeouts de l'accelerateur : pendant un blocage ARMOR fabrique
 * aw_ready, et si le blocage retombe avant le W de cet AW coupe, plus rien ne
 * l'absorbait. Sur carte sous ARMOR_WCAP : SC02 17 fois sur 50 au timeout. */
#ifndef ARMOR_WFATE
#define ARMOR_WFATE 0
#endif

/* Compiler avec -DARMOR_BFATE=1 pour rendre au maitre exactement un B par
 * ecriture, dans l'ordre (CTRL[10], MAGIC v12) : SLVERR fabrique pour un AW
 * coupe, une fois son W-last passe ; B de l'aval pour un AW admis. N'a d'effet
 * qu'avec ARMOR_WSKID=1 et ARMOR_WFATE=1.
 *
 * Correctif du canal B : pendant un blocage ARMOR presentait un SLVERR en
 * continu, que l'accelerateur (b_ready a 1) comptait une fois par cycle, et
 * apres le blocage le B d'un AW coupe ne venait jamais. Au banc, configuration
 * de reference : 2674 B en trop, 14 W-last sans reponse ; sans RESP_HOLD, un
 * timeout en DRAIN. Consequence sur la mesure : une iteration d'attaque ne se
 * termine plus sur le compte de B fabriques, mais sur un B par requete. */
#ifndef ARMOR_BFATE
#define ARMOR_BFATE 0
#endif
/* CONTROLE DE VERSION PAR SEUIL, ET NON PAR EGALITE.
 *
 * La version precedente comparait le magic a une constante exacte. Elle m'a
 * pris deux fois dans la journee : une fois pour une vraie erreur (firmware
 * perime flashe sur bitstream neuf, cf. le log de 14:16 -- le garde a bien
 * fonctionne), et une fois pour RIEN (le RTL passe a v6 alors que cette
 * constante etait restee a v5 : le log de 17:19 porte un « bitstream sans
 * interface CSR ? » alors que tout etait correctement apparie).
 *
 * Un garde qui crie au loup est pire que pas de garde : on apprend a l'ignorer,
 * et la vraie erreur passe. Le firmware verifie donc ce dont IL A BESOIN -- une
 * version AU MOINS egale a la sienne -- et non une egalite qui oblige a toucher
 * deux fichiers a chaque incrementation.
 *
 * En clair : une version PLUS RECENTE que prevu n'est pas un probleme, les
 * registres deja documentes ne bougent pas. Seule une version PLUS ANCIENNE
 * l'est, et le message dit alors precisement ce qui manquera. */
#define WRAP_MAGIC_PREFIX       (0x41524D4F52000000ULL)  /* "ARMOR" + version */
#define WRAP_MAGIC_MASK         (0xFFFFFFFFFFFFFF00ULL)
#define WRAP_MAGIC_VERSION(m)   ((unsigned)((m) & 0xFFULL))

/* Version minimale requise par CE firmware : il lit 0xF0/0xF8 (retraits de
 * VALID) et pilote CTRL[4] (etage W), donc v6. */
#define WRAP_MAGIC_MIN          6

/* Bloc d'observabilite du wrapper (MAGIC version 2). Lecture seule, remis a
 * zero par CNT_CLR comme les compteurs d'evenements. Carte complete dans
 * armor/SRC/wrapper.sv. */
#define WRAP_DBG_UP_OFF         (0x60ULL)   /* poignees de main cote maitre  */
#define WRAP_DBG_DN_OFF         (0x68ULL)   /* poignees de main cote aval    */
#define WRAP_DBG_STATE_OFF      (0x70ULL)   /* w_owed, verdicts, FSM, seuils */
#define WRAP_DBG_STALL_UP_OFF   (0x78ULL)   /* plus longue attente par canal */
#define WRAP_DBG_STALL_DN_OFF   (0x80ULL)
#define WRAP_CNT_CYC_OFF        (0x88ULL)   /* cycles de blocage | de HOLD   */
#define WRAP_CNT_REQ_OFF        (0x90ULL)   /* transferts amont | aval       */
#define WRAP_LAT_LAST_OFF       (0x98ULL)   /* det | tx de la derniere       */
#define WRAP_LAT_DET_SUM_OFF    (0xA0ULL)
#define WRAP_LAT_TX_SUM_OFF     (0xA8ULL)
#define WRAP_LAT_N_OFF          (0xB0ULL)   /* n | n avec verdict            */
#define WRAP_LAT_MINMAX_OFF     (0xB8ULL)
#define WRAP_LAT_CUR_OFF        (0xC0ULL)   /* transaction EN VOL            */
#define WRAP_CYC_TOTAL_OFF      (0xC8ULL)

/* Version 3 : les trois angles morts fermes apres le gel du 2026-09-10, qui
 * s'etait produit avec sticky=0, cyc_block=0, cyc_hold=0 et w_owed=0 -- soit
 * sans qu'aucun compteur existant ne voie quoi que ce soit. */
#define WRAP_CNT_BADID_OFF      (0xD0ULL)   /* fronts | cycles de bad_id      */
#define WRAP_CNT_WCH_OFF        (0xD8ULL)   /* AW aval | W-last aval          */
#define WRAP_CNT_WANOM_OFF      (0xE0ULL)   /* beats fantomes | W orphelins   */
#define WRAP_DBG_WOWED_OFF      (0xE8ULL)   /* w_owed courant | son maximum   */

/* Version 5 : VALID retire sans READY -- violation AXI4. Ces deux registres
 * sont les SEULS a pouvoir la voir : aucun handshake ne s'accomplit, donc aucun
 * compteur de handshake ne bouge. Confirme en simulation avant synthese, la
 * cause distinguant ARMOR (block_req, bad_id) du maitre (aucune cause : la FSM
 * de l'accelerateur abandonne sur timeout et lache son ar_valid). */
#define WRAP_CNT_RETRACT_OFF    (0xF0ULL)   /* aw | ar | w | b-r, 16 bits chacun */
#define WRAP_DBG_RETRACT_OFF    (0xF8ULL)   /* 1er retrait : cycle, cause, canal */

#define WRAP_RETR_FIELD(v, i)   (((v) >> (16 * (i))) & 0xFFFFULL)

/* DBG_WOWED : DEUX CHAMPS DE 4 BITS, pas de 8. w_owed_q fait 4 bits et sature a
 * 15. La premiere version de ce decodeur lisait 8 bits par champ -- parce que le
 * commentaire du RTL l'annoncait ainsi -- et sortait « w_owed=16 max=0 » dans le
 * log du 2026-09-10 12:36 : deux impossibilites a la fois, un compteur 4 bits a
 * 16 et un maximum sous la valeur courante. C'etait 0x10, soit max=1, owed=0. */
#define WRAP_WOWED_CUR(v)       ((unsigned long)((v)       & 0xF))
#define WRAP_WOWED_MAX(v)       ((unsigned long)(((v) >> 4) & 0xF))

/* Canaux surveilles par DBG_STALL_*, dans l'ordre des champs de 12 bits. */
#define WRAP_STALL_FIELD(v, i)  (((v) >> (12 * (i))) & 0xFFFULL)

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
/* CHOIX DU COMPTEUR — lire ceci avant d'interpréter la moindre latence.
 *
 * `cycle` (défaut). CVA6 l'implémente en matériel (`csr_regfile.sv`, cas
 * `CSR_CYCLE`). La lecture coûte quelques cycles et la valeur EST en cycles
 * cœur, à 50 MHz. Exige `hcounteren.CY` armé côté Bao, sinon exception 22
 * (Virtual Instruction) : c'est ce que fait `bao-overlay/src/arch/riscv/vm.c`.
 * `mcounteren` vaut déjà -1 côté OpenSBI, rien d'autre à armer.
 *
 * `time` (-DBENCH_USE_TIME), l'ancien défaut. À n'utiliser que sur un Bao SANS
 * l'overlay. CVA6 n'implémente PAS `CSR_TIME` : `rdtime` lève une instruction
 * illégale, hcounteren.TM la laisse filer jusqu'en M-mode, et OpenSBI l'émule
 * en lisant le mtime du CLINT sur le bus. Coût mesuré le 2026-09-09 :
 * **638 ticks, soit ~1276 cycles cœur, par lecture** — la moitié de chaque
 * latence publiée. Et la valeur est en ticks de 25 MHz, donc 2 cycles cœur
 * chacun : deux pièges d'un coup.
 *
 * La ligne `# UNITE` imprimée au démarrage dit lequel est compilé, et `# CALIB`
 * donne le coût réel. Si CALIB reste à ~638, l'overlay Bao n'est pas actif. */
#ifndef BENCH_NO_TIMER
#  ifdef BENCH_USE_TIME
#    define BENCH_COUNTER_NAME "time"
#    define BENCH_COUNTER_UNIT "ticks 25 MHz (1 tick = 2 cycles coeur)"
static inline uint64_t read_counter(void) {
    uint64_t t;
    asm volatile("csrr %0, time" : "=r"(t));
    return t;
}
#  else
#    define BENCH_COUNTER_NAME "cycle"
#    define BENCH_COUNTER_UNIT "cycles coeur 50 MHz"
static inline uint64_t read_counter(void) {
    uint64_t t;
    asm volatile("csrr %0, cycle" : "=r"(t));
    return t;
}
#  endif
#else
#  define BENCH_COUNTER_NAME "aucun"
#  define BENCH_COUNTER_UNIT "latences forcees a 0"
static inline uint64_t read_counter(void) { return 0; }
#endif

/* Cout d'une lecture de `time`, mesure en la lisant deux fois de suite.
 *
 * NON NEGLIGEABLE, et c'est le resultat le plus important du run 2026-09-09 :
 * l'ecart `tx - det` valait 645 a 675 ticks sur les SEPT scenarios, constant, y
 * compris sur SC03 qui dure 33 000 ticks. Or `det` et `tx` sont pris a la meme
 * iteration de la boucle de sondage et ne sont separes QUE par un appel a
 * read_counter() : cet ecart est donc le cout de l'appel lui-meme. Sous Bao en
 * VS-mode, `csrr time` trappe vers l'hyperviseur, d'ou ~650 ticks (~1300 cycles
 * coeur) par lecture.
 *
 * Consequence : ~48 % du chiffre publie pour SC06 (1351 ticks) est du temps de
 * sonde, pas du temps de transaction. On imprime la calibration pour que la
 * soustraction soit possible -- et pour qu'un lecteur voie l'ordre de grandeur
 * avant de comparer nos latences a celles d'une autre implementation. */
static void calib_timer(void) {
    uint64_t best = (uint64_t)-1, sum = 0;
    for (int i = 0; i < 64; i++) {
        uint64_t a = read_counter();
        uint64_t b = read_counter();
        uint64_t d = b - a;
        sum += d;
        if (d < best) best = d;
    }
    printf("# CALIB : une lecture de `%s` coute %lu (min) / %lu (moy sur 64)\r\n",
           BENCH_COUNTER_NAME,
           (unsigned long)best, (unsigned long)(sum / 64));
    printf("# CALIB : `det` et `tx` sont separes par exactement une de ces lectures\r\n");
    printf("# UNITE : compteur = %s, %s\r\n", BENCH_COUNTER_NAME, BENCH_COUNTER_UNIT);
}

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
    if ((m1 & WRAP_MAGIC_MASK) != WRAP_MAGIC_PREFIX ||
        (m2 & WRAP_MAGIC_MASK) != WRAP_MAGIC_PREFIX) {
        /* Ce n'est meme pas un magic ARMOR : bitstream sans interface CSR, ou
         * adresse de wrapper fausse. Rien de ce qui suit n'a de sens. */
        printf("# ATTENTION : magic ARMOR absent — bitstream sans interface CSR "
               "ou adresse de wrapper erronee ; RIEN de ce log n'est exploitable\r\n");
    } else {
        unsigned v1 = WRAP_MAGIC_VERSION(m1), v2 = WRAP_MAGIC_VERSION(m2);
        unsigned v  = (v1 < v2) ? v1 : v2;   /* le plus faible des deux decide */

        if (v1 != v2)
            printf("# ATTENTION : les deux wrappers n'ont pas la meme version "
                   "(w1=v%u, w2=v%u)\r\n", v1, v2);

        if (v < WRAP_MAGIC_MIN) {
            /* On nomme ce qui manquera, plutot que de laisser croire a une
             * panne. Un registre absent lit ZERO, et zero n'est pas « aucune
             * anomalie » : c'est « aucune mesure ». */
            printf("# ATTENTION : bitstream ARMOR v%u, ce firmware demande v%u "
                   "au minimum\r\n", v, WRAP_MAGIC_MIN);
            if (v < 2) printf("#   -> 0x60..0xC8 liront zero : aucune mesure materielle\r\n");
            if (v < 3) printf("#   -> 0xD0..0xE8 liront zero : ni bad_id ni canal W, et cyc_hold sous-compte\r\n");
            if (v < 5) printf("#   -> 0xF0/0xF8 liront zero : AUCUNE mesure de retrait de VALID (pas « aucun retrait »)\r\n");
            if (v < 6) printf("#   -> CTRL[4] sans effet : l'etage W ne peut pas etre active\r\n");
        }
        /* Hors du seuil : v7 n'est exige QUE si l'image demande FRESH. Sur un v6
         * le bit 5 est ignore sans rien dire, et le log se croirait protege. */
        if (ARMOR_FRESH && v < 7)
            printf("# ATTENTION : ARMOR_FRESH=1 mais bitstream v%u -- CTRL[5] "
                   "SANS EFFET, ce run mesure le comportement historique\r\n", v);
        if (ARMOR_WCAP && v < 8)
            printf("# ATTENTION : ARMOR_WCAP=1 mais bitstream v%u -- CTRL[7] "
                   "SANS EFFET, le canal W peut rester decale\r\n", v);
        if (ARMOR_WCAP && !ARMOR_WSKID)
            printf("# ATTENTION : ARMOR_WCAP=1 sans ARMOR_WSKID -- CTRL[7] "
                   "n'agit que sur l'etage W, il est ici sans effet\r\n");
        if (ARMOR_RHOLD && v < 9)
            printf("# ATTENTION : ARMOR_RHOLD=1 mais bitstream v%u -- CTRL[8] "
                   "SANS EFFET, les reponses B/R peuvent etre retirees\r\n", v);
        if (ARMOR_WFATE && v < 10)
            printf("# ATTENTION : ARMOR_WFATE=1 mais bitstream v%u -- CTRL[9] "
                   "SANS EFFET, le maitre peut caler jusqu'au timeout\r\n", v);
        if (ARMOR_WFATE && !ARMOR_WSKID)
            printf("# ATTENTION : ARMOR_WFATE=1 sans ARMOR_WSKID -- CTRL[9] "
                   "n'agit que sur l'etage W, il est ici sans effet\r\n");
        if (ARMOR_BFATE && v < 11)
            printf("# ATTENTION : ARMOR_BFATE=1 mais bitstream v%u -- CTRL[10] "
                   "SANS EFFET, le canal B reste fabrique en continu\r\n", v);
        else if (ARMOR_BFATE && v == 11)
            printf("# ATTENTION : ARMOR_BFATE=1 sur un bitstream v11 -- sa file de "
                   "sort ne fait que 16 entrees : elle DEBORDE (STATUS[24]) et GELE "
                   "la campagne dans SC04. Exiger v12.\r\n");
        if (ARMOR_BFATE && !(ARMOR_WSKID && ARMOR_WFATE))
            printf("# ATTENTION : ARMOR_BFATE=1 sans ARMOR_WSKID et ARMOR_WFATE -- "
                   "CTRL[10] n'agit qu'avec les deux, il est ici sans effet\r\n");
    }

    w1[WRAP_ID_CFG_OFF   / 8] = 1ULL;         /* LHA : STREAM_ID = 1 */
    w2[WRAP_ID_CFG_OFF   / 8] = 2ULL;         /* MHA : STREAM_ID = 2 */
    w2[WRAP_MSI_ADDR_OFF / 8] = MSI_TARGET_DST;   /* cible des ecritures SC04 */
    *mha_msi_addr             = MSI_TARGET_DST;   /* meme adresse cote accel */

    uint64_t ctrl = (enforce ? WRAP_CTRL_ENFORCE : 0ULL)
                  | (ARMOR_WSKID ? WRAP_CTRL_WSKID : 0ULL)
                  | (ARMOR_FRESH ? WRAP_CTRL_FRESH : 0ULL)
                  | (ARMOR_WCAP  ? WRAP_CTRL_WCAP  : 0ULL)
                  | (ARMOR_RHOLD ? WRAP_CTRL_RHOLD : 0ULL)
                  | (ARMOR_WFATE ? WRAP_CTRL_WFATE : 0ULL)
                  | (ARMOR_BFATE ? WRAP_CTRL_BFATE : 0ULL)
                  | WRAP_CTRL_STICKY_CLR | WRAP_CTRL_CNT_CLR;
    w1[WRAP_CTRL_OFF / 8] = ctrl;
    w2[WRAP_CTRL_OFF / 8] = ctrl;
    fence();

    printf("# ARMOR arme : ENFORCE=%d, W_SKID=%d, FRESH=%d, WCAP=%d, RHOLD=%d, WFATE=%d, "
           "BFATE=%d, ID_CFG w1=1 w2=2, MSI_ADDR=0x%08x\r\n",
           enforce, ARMOR_WSKID, ARMOR_FRESH, ARMOR_WCAP, ARMOR_RHOLD, ARMOR_WFATE,
           ARMOR_BFATE,
           (unsigned)MSI_TARGET_DST);

    /* Ce que le MATERIEL a retenu, et non ce qu'on lui a demande. Un bit que le
     * bitstream ne porte pas relit zero : deux images qui ne different que par
     * un bit se confondent vite, la relecture tranche. Les impulsions (b1, b2)
     * s'auto-effacent et sont hors du masque. */
    uint64_t want = ctrl & ~(WRAP_CTRL_STICKY_CLR | WRAP_CTRL_CNT_CLR);
    uint64_t got1 = w1[WRAP_CTRL_OFF / 8], got2 = w2[WRAP_CTRL_OFF / 8];
    printf("# ARMOR CTRL relu : w1=0x%02x w2=0x%02x (attendu 0x%02x)\r\n",
           (unsigned)got1, (unsigned)got2, (unsigned)want);
    if (got1 != want || got2 != want)
        printf("# ATTENTION : CTRL relu differe de CTRL ecrit -- la configuration "
               "annoncee ci-dessus N'EST PAS celle du materiel\r\n");
    printf("# ARMOR devid_last : w1=%lu w2=%lu\r\n",
           (unsigned long)w1[WRAP_DEVID_LAST_OFF / 8],
           (unsigned long)w2[WRAP_DEVID_LAST_OFF / 8]);
}

/* Vide les compteurs d'evenements ARMOR entre deux scenarios. */
/* NB : ce clear RELIT CTRL et n'ecrit que les bits d'impulsion par-dessus. Il
 * preserve donc ENFORCE, W_SKID, FRESH, WCAP et RHOLD. Ne pas le "simplifier" en ecrivant une
 * constante : on desarmerait l'etage W au premier scenario, et le correctif
 * serait teste sur un wrapper qui ne l'a plus. */
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

/* Compteurs MATERIELS du wrapper (MAGIC v2), lus en fin de scenario.
 *
 * Ce que ces chiffres apportent par rapport aux latences deja publiees : ils
 * sont pris DANS le wrapper, au cycle, sans instrument dans la boucle. Les
 * latences logicielles de ce fichier sont bornees par la sonde -- une lecture
 * de compteur coute ~1300 cycles coeur sous Bao, jusqu'a 48 % du chiffre
 * publie. `Lhw` n'a pas ce biais, et l'ecart `Lp50 - Lhw` chiffre la sonde.
 *
 * ATTENTION a ce qui est compte : le wrapper mesure UNE TRANSACTION AXI (front
 * de presentation -> reponse rendue au maitre), la ou le logiciel mesure UNE
 * ITERATION de l'accelerateur (`*ctrl = 1` -> BUSY = 0), qui en contient
 * plusieurs sur les modes de rafale. Les deux ne sont pas la meme grandeur :
 * en simulation, SC02-STORM donne n = 128 pour 8 iterations. Ne jamais les
 * mettre dans la meme colonne d'un tableau.
 *
 * Le chronometre ne suit qu'UNE transaction a la fois : celles qui arrivent
 * pendant qu'une mesure court ne sont pas echantillonnees. n est donc un
 * echantillon, pas un total -- c'est CNT_REQ qui donne le total.
 *
 * `n_verdict` compte les transactions pour lesquelles un verdict etait visible.
 * Une detection a 0 cycle y est comptee : elle signifie que la fenetre de
 * blocage etait deja ouverte a l'arrivee de la requete, pas que la mesure a
 * echoue.
 *
 * `req_up - req_dn` est la seule mesure DIRECTE de l'action d'ARMOR : le nombre
 * de transferts d'adresse qu'il a coupes. Tout le reste se deduisait des
 * verdicts vus par l'accelerateur.
 */
static void armor_wrap_perf_one(const char *tag, const char *who, uint64_t base) {
    volatile uint64_t *w = (volatile uint64_t *)base;

    uint64_t lat_n    = w[WRAP_LAT_N_OFF      / 8];
    uint64_t lat_last = w[WRAP_LAT_LAST_OFF   / 8];
    uint64_t lat_mm   = w[WRAP_LAT_MINMAX_OFF / 8];
    uint64_t det_sum  = w[WRAP_LAT_DET_SUM_OFF / 8];
    uint64_t tx_sum   = w[WRAP_LAT_TX_SUM_OFF  / 8];
    uint64_t cyc      = w[WRAP_CNT_CYC_OFF    / 8];
    uint64_t req      = w[WRAP_CNT_REQ_OFF    / 8];
    uint64_t total    = w[WRAP_CYC_TOTAL_OFF  / 8];

    uint32_t n     = (uint32_t)lat_n;
    uint32_t n_blk = (uint32_t)(lat_n >> 32);

    /* Moyennes calculees ici : le materiel accumule, il ne divise pas. */
    uint64_t det_avg = n ? det_sum / n : 0;
    uint64_t tx_avg  = n ? tx_sum  / n : 0;

    /* Les minima valent 0xFFFF au reset : sans echantillon ils ne veulent rien
     * dire, et les publier tels quels ferait croire a une latence de 65535. */
    if (n == 0) {
        /* Surtout PAS de return ici : ARMORSTALL et ARMORHW gardent tout leur
         * sens sans echantillon de latence -- c'est meme le cas ou ils sont le
         * plus utiles, celui ou rien n'a abouti. */
        printf("# ARMORLAT,%s,%s,n=0 (aucune transaction echantillonnee)\r\n",
               tag, who);
    } else {
    /* det_sum et tx_sum en fin de ligne : les moyennes ci-dessus sont TRONQUEES
     * (division entiere), et un surcout d'un cycle -- celui de FRESH_VERDICT sur
     * carte, 2026-09-11 -- disparait dedans (37 -> 37). La somme donne la
     * moyenne exacte ; c'est elle qu'on publie. */
    printf("# ARMORLAT,%s,%s,n=%lu,n_verdict=%lu,det_avg=%lu,tx_avg=%lu,"
           "det_last=%lu,tx_last=%lu,det_min=%lu,det_max=%lu,tx_min=%lu,tx_max=%lu,"
           "det_sum=%lu,tx_sum=%lu\r\n",
           tag, who,
           (unsigned long)n, (unsigned long)n_blk,
           (unsigned long)det_avg, (unsigned long)tx_avg,
           (unsigned long)(uint32_t)lat_last,
           (unsigned long)(uint32_t)(lat_last >> 32),
           (unsigned long)(lat_mm        & 0xFFFF),
           (unsigned long)((lat_mm >> 16) & 0xFFFF),
           (unsigned long)((lat_mm >> 32) & 0xFFFF),
           (unsigned long)((lat_mm >> 48) & 0xFFFF),
           (unsigned long)det_sum, (unsigned long)tx_sum);
    }

    printf("# ARMORHW,%s,%s,cyc_block=%lu,cyc_hold=%lu,req_up=%lu,req_dn=%lu,"
           "req_cut=%ld,cyc_total=%lu\r\n",
           tag, who,
           (unsigned long)(uint32_t)cyc,
           (unsigned long)(uint32_t)(cyc >> 32),
           (unsigned long)(uint32_t)req,
           (unsigned long)(uint32_t)(req >> 32),
           (long)((int64_t)(uint32_t)req - (int64_t)(uint32_t)(req >> 32)),
           (unsigned long)total);

    /* Attentes les plus longues, par canal. Une valeur a 4095 est SATUREE :
     * elle dit « coince », pas « 4095 cycles ». */
    /* Les memes grandeurs en fin de scenario, pour un run qui ne gele pas. */
    uint64_t bad = w[WRAP_CNT_BADID_OFF / 8];
    uint64_t wch = w[WRAP_CNT_WCH_OFF   / 8];
    uint64_t wan = w[WRAP_CNT_WANOM_OFF / 8];
    uint64_t wow = w[WRAP_DBG_WOWED_OFF / 8];
    printf("# ARMORW,%s,%s,bad_id=%lu fronts %lu cy | aw_dn=%lu wlast_dn=%lu "
           "ecart=%ld | fantome=%lu orphelin=%lu | w_owed_max=%lu\r\n",
           tag, who,
           (unsigned long)(uint32_t)bad,
           (unsigned long)(uint32_t)(bad >> 32),
           (unsigned long)(uint32_t)wch,
           (unsigned long)(uint32_t)(wch >> 32),
           (long)((int64_t)(uint32_t)wch - (int64_t)(uint32_t)(wch >> 32)),
           (unsigned long)(uint32_t)wan,
           (unsigned long)(uint32_t)(wan >> 32),
           WRAP_WOWED_MAX(wow));

    /* Retraits de VALID, et le detail du PREMIER : sa cause dit si la violation
     * est celle d'ARMOR (block_req, bad_id) ou celle du maitre (aucune cause --
     * la FSM de l'accelerateur lache son valid sur timeout). */
    uint64_t rtr = w[WRAP_CNT_RETRACT_OFF / 8];
    uint64_t rtd = w[WRAP_DBG_RETRACT_OFF / 8];
    if (rtr != 0) {
        printf("# ARMORRETR,%s,%s,aw=%lu ar=%lu w=%lu b-r=%lu | 1er a %lu cy, "
               "cause=%s%s%s%s, canal=%lu\r\n",
               tag, who,
               (unsigned long)WRAP_RETR_FIELD(rtr, 0),
               (unsigned long)WRAP_RETR_FIELD(rtr, 1),
               (unsigned long)WRAP_RETR_FIELD(rtr, 2),
               (unsigned long)WRAP_RETR_FIELD(rtr, 3),
               (unsigned long)(uint32_t)rtd,
               (rtd & (1ULL << 32)) ? "block_req " : "",
               (rtd & (1ULL << 33)) ? "!legit "    : "",
               (rtd & (1ULL << 34)) ? "!verdict "  : "",
               (rtd & (1ULL << 35)) ? "bad_id "    : "",
               (unsigned long)((rtd >> 36) & 0xF));
    } else {
        printf("# ARMORRETR,%s,%s,aucun retrait de VALID\r\n", tag, who);
    }

    uint64_t su = w[WRAP_DBG_STALL_UP_OFF / 8];
    uint64_t sd = w[WRAP_DBG_STALL_DN_OFF / 8];
    printf("# ARMORSTALL,%s,%s,up aw=%lu w=%lu b=%lu ar=%lu r=%lu | "
           "dn aw=%lu w=%lu b=%lu ar=%lu r=%lu\r\n",
           tag, who,
           (unsigned long)WRAP_STALL_FIELD(su, 0),
           (unsigned long)WRAP_STALL_FIELD(su, 1),
           (unsigned long)WRAP_STALL_FIELD(su, 2),
           (unsigned long)WRAP_STALL_FIELD(su, 3),
           (unsigned long)WRAP_STALL_FIELD(su, 4),
           (unsigned long)WRAP_STALL_FIELD(sd, 0),
           (unsigned long)WRAP_STALL_FIELD(sd, 1),
           (unsigned long)WRAP_STALL_FIELD(sd, 2),
           (unsigned long)WRAP_STALL_FIELD(sd, 3),
           (unsigned long)WRAP_STALL_FIELD(sd, 4));
}

static void armor_wrap_perf(const char *tag) {
    armor_wrap_perf_one(tag, "w1", WRAP1_BASE_ADDR);
    armor_wrap_perf_one(tag, "w2", WRAP2_BASE_ADDR);
}

/* Instantane des verdicts VIVANTS, juste avant un lancement (`*ctrl = 1`).
 *
 * Pourquoi : le gel de SC02-STORM se produit sur le `*ctrl = 1` de l'iteration 1,
 * apres que le blocage de tempete se soit engage une premiere fois. Le chemin
 * CPU -> port de config ne traverse pas ARMOR, donc pour qu'un store CPU reste
 * en l'air il faut que le canal d'ecriture du crossbar partage soit coince par
 * le chemin DMA. La derniere ligne ARMORSNAP imprimee donne l'etat exact
 * d'entree en gel.
 *
 * Registre 0x18 (STATUS) = verdicts INSTANTANES, non gates par ENFORCE pour les
 * bits bruts :
 *   [3] BLOCKED [4] BANNED [5] STORM [6] OUTS [7] MSI
 *   [8] threat  [9] storm_flag [10] outs_overflow [11] msi_storm
 *   [12] legit_hit [13] ENFORCE
 * `storm_flag` (niveau) encore haut alors que `STORM` (block_req) est retombe,
 * ou l'inverse, signe un moniteur qui n'a pas desarme.
 *
 * LECTURE SEULE : aucune ecriture, pour ne pas dependre du canal d'ecriture que
 * l'on soupconne justement d'etre coince. Le STATUS de l'accelerateur est lu au
 * passage : s'il porte encore BUSY a l'entree, l'iteration precedente est sortie
 * de sa boucle de sondage sur TIMEOUT et le materiel etait deja coince avant ce
 * `*ctrl = 1`.
 */
/* Decode un vecteur DBG_UP / DBG_DN. Meme disposition des deux cotes, donc un
 * seul decodeur : c'est tout l'interet de les avoir cables pareil.
 *   [0] aw_valid [1] aw_ready [2] w_valid [3] w_ready [4] w_last
 *   [5] b_valid  [6] b_ready  [7] ar_valid [8] ar_ready
 *   [9] r_valid [10] r_ready [11] r_last
 *
 * Un `V` sans `R` en face nomme le canal qui attend son ready -- exactement ce
 * qu'on cherche quand le bus est fige. */
static void armor_hs_print(const char *when, const char *who, const char *side,
                           uint64_t v)
{
    printf("# ARMORHS,%s,%s,%s,0x%03lx, AW %c%c  W %c%c%s  B %c%c  AR %c%c  R %c%c%s\r\n",
           when, who, side, (unsigned long)(v & 0xFFF),
           (v & (1ULL << 0))  ? 'V' : '-', (v & (1ULL << 1))  ? 'R' : '-',
           (v & (1ULL << 2))  ? 'V' : '-', (v & (1ULL << 3))  ? 'R' : '-',
           (v & (1ULL << 4))  ? " last" : "",
           (v & (1ULL << 5))  ? 'V' : '-', (v & (1ULL << 6))  ? 'R' : '-',
           (v & (1ULL << 7))  ? 'V' : '-', (v & (1ULL << 8))  ? 'R' : '-',
           (v & (1ULL << 9))  ? 'V' : '-', (v & (1ULL << 10)) ? 'R' : '-',
           (v & (1ULL << 11)) ? " last" : "");
}

static void armor_wrap_snapshot(const char *when, volatile uint64_t *accel_status)
{
    volatile uint64_t *w1 = (volatile uint64_t *)WRAP1_BASE_ADDR;
    volatile uint64_t *w2 = (volatile uint64_t *)WRAP2_BASE_ADDR;

    uint64_t a  = accel_status ? *accel_status : 0;
    uint64_t s1 = w1[WRAP_STATUS_OFF / 8];
    uint64_t s2 = w2[WRAP_STATUS_OFF / 8];
    uint64_t k1 = w1[WRAP_STICKY_OFF / 8];
    uint64_t k2 = w2[WRAP_STICKY_OFF / 8];

    printf("# ARMORSNAP,%s,accel_status=0x%lx%s\r\n",
           when, (unsigned long)a, (a & ST_BUSY) ? " BUSY-A-L-ENTREE" : "");
    printf("# ARMORSNAP,%s,w1,status=0x%lx sticky=0x%lx |%s%s%s%s%s%s%s%s%s%s\r\n",
           when, (unsigned long)s1, (unsigned long)k1,
           (s1 & (1ULL <<  3)) ? " BLOCKED"   : "",
           (s1 & (1ULL <<  4)) ? " BANNED"    : "",
           (s1 & (1ULL <<  5)) ? " STORM"     : "",
           (s1 & (1ULL <<  6)) ? " OUTS"      : "",
           (s1 & (1ULL <<  7)) ? " MSI"       : "",
           (s1 & (1ULL <<  9)) ? " stormflag" : "",
           (s1 & (1ULL << 10)) ? " outsovf"   : "",
           (s1 & (1ULL << 12)) ? " legit"     : "",
           (s1 & (1ULL << 13)) ? " ENF"       : "",
           (s1 & (1ULL << 14)) ? " BAD_ID"    : "");
    printf("# ARMORSNAP,%s,w2,status=0x%lx sticky=0x%lx |%s%s%s%s%s%s%s%s%s%s\r\n",
           when, (unsigned long)s2, (unsigned long)k2,
           (s2 & (1ULL <<  3)) ? " BLOCKED"   : "",
           (s2 & (1ULL <<  4)) ? " BANNED"    : "",
           (s2 & (1ULL <<  5)) ? " STORM"     : "",
           (s2 & (1ULL <<  6)) ? " OUTS"      : "",
           (s2 & (1ULL <<  7)) ? " MSI"       : "",
           (s2 & (1ULL <<  9)) ? " stormflag" : "",
           (s2 & (1ULL << 10)) ? " outsovf"   : "",
           (s2 & (1ULL << 12)) ? " legit"     : "",
           (s2 & (1ULL << 13)) ? " ENF"       : "",
           (s2 & (1ULL << 14)) ? " BAD_ID"    : "");

    /* Poignees de main VIVANTES des deux cotes de la coupure, et etat interne.
     * C'est ce bloc qui doit nommer le canal fige : si le gel vient d'un AW
     * admis en aval dont les W ne viennent jamais, on doit voir `w_owed != 0`
     * avec un `AW V-` cote aval. Le port CSR ne traverse pas ARMOR et les
     * lectures reviennent alors que le canal d'ecriture est coince, donc ce
     * bloc reste lisible dans l'etat meme ou tout le reste est muet. */
    armor_hs_print(when, "w1", "up", w1[WRAP_DBG_UP_OFF / 8]);
    armor_hs_print(when, "w1", "dn", w1[WRAP_DBG_DN_OFF / 8]);
    armor_hs_print(when, "w2", "up", w2[WRAP_DBG_UP_OFF / 8]);
    armor_hs_print(when, "w2", "dn", w2[WRAP_DBG_DN_OFF / 8]);

    for (int i = 0; i < 2; i++) {
        volatile uint64_t *w  = i ? w2 : w1;
        const char        *nm = i ? "w2" : "w1";
        uint64_t st  = w[WRAP_DBG_STATE_OFF / 8];
        uint64_t cur = w[WRAP_LAT_CUR_OFF   / 8];
        printf("# ARMORDBG,%s,%s,w_owed=%lu w_pending=%lu vk=%lu cvalid=%lu "
               "bad_id=%lu legit=%lu fail=%lu outs=%lu req_cnt=%lu "
               "fsm_w=%lu fsm_r=%lu | en_vol=%lu cyc=%lu verdict_vu=%lu\r\n",
               when, nm,
               (unsigned long)(st         & 0xF),
               (unsigned long)((st >>  4) & 1),
               (unsigned long)((st >>  5) & 1),
               (unsigned long)((st >>  6) & 1),
               (unsigned long)((st >>  7) & 1),
               (unsigned long)((st >>  8) & 1),
               (unsigned long)((st >> 16) & 0xFF),
               (unsigned long)((st >> 24) & 0xFF),
               (unsigned long)((st >> 32) & 0xFF),
               (unsigned long)((st >> 11) & 3),
               (unsigned long)((st >> 13) & 1),
               (unsigned long)((cur >> 32) & 1),
               (unsigned long)(uint32_t)cur,
               (unsigned long)((cur >> 33) & 1));

        /* Trafic et temps ACCUMULES DEPUIS LE DEBUT DU SCENARIO (CNT_CLR est
         * fait par armor_wrap_clear() dans run_scenario).
         *
         * Pourquoi cette ligne existe : le 2026-09-10, SC02-STORM a gele a
         * l'iteration 1 et le `armor_wrap_perf()` de fin de scenario n'a jamais
         * ete atteint -- on a donc perdu le seul chiffre qui dit combien de
         * requetes ARMOR avait deja coupees quand tout s'est arrete. Ici il est
         * imprime AVANT chaque lancement : le dernier bloc du log le portera.
         *
         * `cut` est la difference entre les transferts d'adresse presentes par
         * le maitre et ceux admis en aval. Sur du trafic legitime il doit valoir
         * zero (mesure du faux positif) ; sur une tempete il chiffre l'action
         * d'ARMOR sans passer par les verdicts vus par l'accelerateur. */
        uint64_t req = w[WRAP_CNT_REQ_OFF / 8];
        uint64_t cyc = w[WRAP_CNT_CYC_OFF / 8];
        uint32_t r_up = (uint32_t)req, r_dn = (uint32_t)(req >> 32);
        printf("# ARMORCUT,%s,%s,req_up=%lu req_dn=%lu cut=%ld | "
               "cyc_block=%lu cyc_hold=%lu\r\n",
               when, nm,
               (unsigned long)r_up, (unsigned long)r_dn,
               (long)((int64_t)r_up - (int64_t)r_dn),
               (unsigned long)(uint32_t)cyc,
               (unsigned long)(uint32_t)(cyc >> 32));

        /* bad_id et le canal W : les trois grandeurs qui etaient muettes quand
         * la campagne du 2026-09-10 a gele. `ecart` doit valoir zero -- un AW
         * admis en aval finit toujours par recevoir son W-last. Non nul, il dit
         * dans quel sens le canal est desaligne. `fantome` non nul prouve que
         * l'aval a pris un beat que le maitre croit refuse. */
        uint64_t bad  = w[WRAP_CNT_BADID_OFF / 8];
        uint64_t wch  = w[WRAP_CNT_WCH_OFF   / 8];
        uint64_t wan  = w[WRAP_CNT_WANOM_OFF / 8];
        uint64_t wow  = w[WRAP_DBG_WOWED_OFF / 8];
        uint32_t awdn = (uint32_t)wch, wldn = (uint32_t)(wch >> 32);
        printf("# ARMORW,%s,%s,bad_id=%lu fronts %lu cy | aw_dn=%lu wlast_dn=%lu "
               "ecart=%ld | fantome=%lu orphelin=%lu | w_owed=%lu max=%lu\r\n",
               when, nm,
               (unsigned long)(uint32_t)bad,
               (unsigned long)(uint32_t)(bad >> 32),
               (unsigned long)awdn, (unsigned long)wldn,
               (long)((int64_t)awdn - (int64_t)wldn),
               (unsigned long)(uint32_t)wan,
               (unsigned long)(uint32_t)(wan >> 32),
               WRAP_WOWED_CUR(wow),
               WRAP_WOWED_MAX(wow));
    }
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
    uint64_t t0 = read_counter();
    while ((read_counter() - t0) < n) { /* spin */ }
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
    int n;                       /* échantillons accumulés dans L_sum (non borné) */
    int n_lat;                   /* remplissage de lat[] : min(n, LAT_CAP)        */
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
    a->n_lat = 0;
}

static void lat_add(lat_acc_t *a, uint64_t v) {
    if (!v) return;
    if (v < a->L_min) a->L_min = v;
    if (v > a->L_max) a->L_max = v;
    a->L_sum += v;
    a->n++;                                   /* compte TOUT ce qui entre dans L_sum */
    if (a->n_lat < LAT_CAP) a->lat[a->n_lat++] = v;   /* le buffer, lui, sature */
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
/* Percentile sur les LAT_CAP premiers echantillons : au-dela, lat[] sature et le
 * percentile ne porte que sur ce debut de scenario. C'est le cas de SC08 (700
 * salves pour LAT_CAP=512) — ne pas confondre n_lat avec n. */
static uint64_t pctl_int(lat_acc_t *a, unsigned p_num) {
    if (a->n_lat == 0) return 0;
    sort_u64(a->lat, a->n_lat);
    unsigned idx = (p_num * (a->n_lat - 1)) / 100u;
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
static int g_iter        = 0;   /* index d'iteration, pour le digest */
#  define TRACE_ARM() do { g_trace_left = TRACE_N; g_iter = 0; } while (0)
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
#ifdef BENCH_TRACE_MMIO
    /* Etat ARMOR a l'entree, AVANT le chronometre : les iterations tracees sont
     * de toute facon exclues des statistiques (voir plus bas), mais autant ne
     * pas melanger le cout de trois printf avec la mesure. */
    if (tr) armor_wrap_snapshot("pre-ctrl", status);
#endif
    uint64_t t0 = read_counter();
    TRACE("-> ecriture CTRL=1 (lancement)");
    *ctrl = 1;
    TRACE("   CTRL OK ; -> 1re lecture STATUS");
    int first_read = 1;
    do {
        st = *status;
        if (first_read) { TRACE("   1re lecture STATUS OK, sondage en cours"); first_read = 0; }
        if (!got_event && (st & (ST_ANY_BLOCK | ST_DONE | ST_ERROR))) {
            t_event   = read_counter();   /* instant du 1er verdict (détection) */
            got_event = 1;
        }
    } while ((st & ST_BUSY) && --to);
    uint64_t t1 = read_counter();         /* fin de transaction (BUSY=0 / timeout) */
    if (!got_event) t_event = t1;        /* aucun verdict vu -> détection = tx */
    *out_det = t_event - t0;
    *out_tx  = t1 - t0;

#ifdef BENCH_TRACE_MMIO
    /* Les TRACE() ci-dessus sont des printf UART places A L'INTERIEUR de la
     * fenetre chronometree -- il le faut, c'est la seule facon de nommer l'acces
     * qui ne revient pas. Mais une ligne de ~40 caracteres a 115200 bauds coute
     * ~3,5 ms, soit ~87 000 ticks, et il y en a trois : les iterations 0, 1 et 2
     * de chaque scenario mesuraient l'UART, pas le materiel. C'est l'origine des
     * outliers a ~318 000 ticks du run 2026-09-09, qui ecrasaient Lavg (SC06 :
     * Lp50 = 1376 contre Lavg = 10894).
     *
     * On les sort donc des statistiques. lat_add() rejette les zeros et la
     * colonne `n` du CSV rend l'exclusion visible : n = N - TRACE_N sur un build
     * trace, n = N sinon. */
    if (tr) { *out_det = 0; *out_tx = 0; }
#endif
    TRACE("-> lecture STATUS finale");
    st = *status;
    TRACE("   lecture STATUS finale OK");

#ifdef BENCH_TRACE_MMIO
    /* DIGEST D'UNE LIGNE PAR ITERATION.
     *
     * Pourquoi il a fallu l'ajouter : le 2026-09-10 a 12:36, le gel de
     * SC02-STORM s'est produit APRES l'iteration 2, donc au-dela des TRACE_N = 3
     * snapshots verbeux -- et le log s'arrete sur une iteration parfaitement
     * normale, sans rien dire de l'etat d'entree en gel. Les runs precedents
     * gelaient aux iterations 1 et 2, dans la fenetre tracee ; le point de gel
     * se deplace d'un run a l'autre.
     *
     * PLACE APRES LA FERMETURE DE LA FENETRE CHRONOMETREE, volontairement : t1
     * est deja pris, donc ni les lectures CSR ni le printf n'entrent dans la
     * mesure, et les latences de TOUTES les iterations restent valables. C'est
     * la difference avec les TRACE() ci-dessus, qui sont dans la fenetre et
     * obligent a jeter leurs iterations.
     *
     * L'etat imprime apres l'iteration k EST l'etat d'entree du lancement k+1 :
     * la derniere ligne du log nomme donc le point de gel, avec ses compteurs.
     *
     * Ce qu'il coute quand meme : une ligne a 115200 bauds retarde l'iteration
     * suivante d'environ 8 ms, ce qui change la cadence des salves. Sur un
     * defaut aussi sensible au temps que celui-ci, ca peut deplacer le gel --
     * c'est le meme compromis que OBS_CHECK au banc. On l'accepte : un gel
     * date valant mieux qu'un gel muet. */
    {
        volatile uint64_t *w = (volatile uint64_t *)
            ((accel == 'M') ? WRAP2_BASE_ADDR : WRAP1_BASE_ADDR);
        uint64_t req = w[WRAP_CNT_REQ_OFF    / 8];
        uint64_t cyc = w[WRAP_CNT_CYC_OFF    / 8];
        uint64_t bad = w[WRAP_CNT_BADID_OFF  / 8];
        uint64_t wch = w[WRAP_CNT_WCH_OFF    / 8];
        uint64_t wan = w[WRAP_CNT_WANOM_OFF  / 8];
        uint64_t wow = w[WRAP_DBG_WOWED_OFF  / 8];
        uint64_t rtr = w[WRAP_CNT_RETRACT_OFF / 8];
        uint32_t r_up = (uint32_t)req, r_dn = (uint32_t)(req >> 32);
        printf("# IT,%d,st=0x%lx,up=%lu,dn=%lu,cut=%ld,blk=%lu,hold=%lu,"
               "bad=%lu,ecart=%ld,fant=%lu,orph=%lu,owed=%lu/%lu,"
               "retr=%lu/%lu/%lu/%lu\r\n",
               g_iter, (unsigned long)st,
               (unsigned long)r_up, (unsigned long)r_dn,
               (long)((int64_t)r_up - (int64_t)r_dn),
               (unsigned long)(uint32_t)cyc,
               (unsigned long)(uint32_t)(cyc >> 32),
               (unsigned long)(uint32_t)bad,
               (long)((int64_t)(uint32_t)wch - (int64_t)(uint32_t)(wch >> 32)),
               (unsigned long)(uint32_t)wan,
               (unsigned long)(uint32_t)(wan >> 32),
               WRAP_WOWED_CUR(wow), WRAP_WOWED_MAX(wow),
               /* retr = aw/ar/w/(b,r) : VALID retires sans READY. Sur du
                * trafic legitime les quatre doivent rester a zero. */
               (unsigned long)WRAP_RETR_FIELD(rtr, 0),
               (unsigned long)WRAP_RETR_FIELD(rtr, 1),
               (unsigned long)WRAP_RETR_FIELD(rtr, 2),
               (unsigned long)WRAP_RETR_FIELD(rtr, 3));
        g_iter++;
    }
#endif

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

    /* Etat d'entree du scenario, apres le CNT_CLR : trois lignes qui disent si
     * le wrapper part propre. Un `stormflag` ou un `BANNED` encore haut ici
     * signifie que le scenario precedent a laisse ARMOR arme -- exactement le
     * piege du bannissement residuel de la sonde (cf. b4c8525), et de quoi
     * disqualifier un verdict avant de l'attribuer au scenario en cours. */
    armor_wrap_snapshot(tag, (accel == 'M') ? mha_status : lha_status);

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
    armor_wrap_perf(tag);     /* latences et cycles mesures PAR LE MATERIEL */
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
     * le nombre d'iterations du scenario (s->N) : lat_add() rejette les valeurs
     * nulles, donc diviser par s->N sous-estimerait la moyenne d'un facteur n/N.
     *
     * Le run du 2026-09-09 a montre n == N partout : aucun echantillon nul, ce
     * defaut ne se declenchait pas, et il n'explique donc PAS le rapport
     * det ~= 0,52 x tx. La vraie cause est dans fire_one() : `tx - det` valait
     * 645 a 675 ticks sur les sept scenarios, y compris sur SC03 qui dure 33 000
     * ticks -- c'est le cout FIXE d'un seul appel a read_counter(), pas une
     * propriete du materiel. Voir la note d'unites dans fire_one().
     *
     * On emet donc `n` (echantillons dans L_sum) ET `n_lat` (remplissage de
     * lat[], sature a LAT_CAP) : sans les deux, on ne peut pas savoir si une
     * moyenne et un percentile portent sur la meme population. Sur SC08,
     * n = 700 et n_lat = 512. */
#ifdef BENCH_DUMP_LAT
    /* Les n_lat echantillons DANS L'ORDRE D'ACQUISITION, avant que pctl_int()
     * ne trie lat[] en place -- apres le tri, l'ordre est perdu et on ne peut
     * plus voir si un scenario bascule en cours de route.
     *
     * A quoi ca sert. Le 2026-09-12, une campagne sur dix-sept a mesure SC06 a
     * 206 cycles au lieu de 220, alors que TOUS les compteurs du wrapper etaient
     * identiques au bit pres et que la duree du scenario n'avait pas bouge (36
     * cycles d'ecart sur 71 millions). L'ecart vaut une passe de la boucle de
     * sondage (tx - det = 38 = 26 de read_counter + 12). Reste a savoir si les
     * valeurs se rangent sur DEUX PALIERS separes de ~12 cycles -- alors c'est
     * la quantification du sondage MMIO, et l'affaire est close -- ou si elles
     * s'etalent en continu, auquel cas c'est autre chose. Les agregats
     * min/moy/p50/p99/max ne permettent pas de trancher.
     *
     * Emis en fin de campagne, avec les SUMMARY : aucune mesure n'est en cours,
     * le cout UART de ces lignes ne peut pas deplacer la phase d'un scenario. */
    for (int i = 0; i < a->n_lat; i += 16) {
        printf("# LATDUMP,%s,%s,%d", tag, s->name, i);
        for (int j = i; j < i + 16 && j < a->n_lat; j++)
            printf(",%lu", (unsigned long)a->lat[j]);
        printf("\r\n");
    }
#endif
    uint64_t avg  = a->n ? (a->L_sum / (uint64_t)a->n) : 0;
    uint64_t lmin = a->n ? a->L_min : 0;
    uint64_t p50  = pctl_int(a, 50);
    uint64_t p99  = pctl_int(a, 99);
    printf("%s,%s,%d,%d,%d,%d,%d,%d,%d,%lu,%lu,%lu,%lu,%lu\r\n",
           tag, s->name, s->N, a->n, a->n_lat, s->TP, s->FP, s->FN, s->TN,
           (unsigned long)lmin, (unsigned long)avg,
           (unsigned long)p50, (unsigned long)p99,
           (unsigned long)a->L_max);
}

static void dump(stats_t *s) {
    dump_acc("SUMMARY-DET", s, &s->det);   /* latence de détection  */
    dump_acc("SUMMARY-TX",  s, &s->tx);    /* latence de transaction */
}


/* ============================================================
 * SONDE DE WEDGE (-DBENCH_WEDGE_PROBE) — diagnostic, pas une campagne.
 *
 * Isole la cause du gel observé sur carte SANS resynthétiser, en exploitant le
 * fait qu'ID_CFG (0x00) est RW : on programme un identifiant attendu FAUX, et
 * ARMOR se met alors à bloquer du trafic parfaitement LÉGITIME (mode 0). Si le
 * gel se produit là, il ne doit rien au spoofing, à la tempête ni au MSI : il
 * suffit qu'ARMOR bloque.
 *
 * Le §6.3 du rapport de campagne de référence décrit un wedge de même famille,
 * laissé non corrigé : « si l'AW a déjà été accepté par l'IOMMU avant le
 * blocage, l'IOMMU complète l'écriture et émet un B réel que le response
 * manager ignore [...] le canal B se remplit, et le mux/IOMMU partagé se fige »,
 * et il le dit SPÉCIFIQUE AUX ÉCRITURES.
 *
 * D'où l'ordre : LECTURE d'abord, ÉCRITURE ensuite. Si la lecture passe et que
 * l'écriture gèle, la spécificité est confirmée sur notre matériel et le suspect
 * se réduit au canal B. Si la lecture gèle aussi, elle est infirmée.
 *
 * Chaque phase annonce ce qu'elle va faire AVANT de le faire : sur un gel, la
 * dernière ligne imprimée nomme la phase fautive.
 * ============================================================ */
#ifdef BENCH_WEDGE_PROBE
/* Transactions legitimes avant basculement : il en faut assez pour que le
 * pipeline d'identifiant ait rendu un verdict positif et que legit_hit soit
 * franchement etabli. Huit est large. */
#ifndef WEDGE_WARMUP
#  define WEDGE_WARMUP 8
#endif
/* Duree d'un bannissement en profil BENCH (~2 ms a 50 MHz), plus une marge. */
#ifndef WEDGE_BAN_DRAIN_CY
#  define WEDGE_BAN_DRAIN_CY 150000
#endif

static void wedge_probe(void) {
    volatile uint64_t *w2 = (volatile uint64_t *)WRAP2_BASE_ADDR;
    uint64_t det, tx, st;

    printf("\r\n# ===== SONDE DE WEDGE =====\r\n");

    /* PRECHAUFFAGE — indispensable, et c'est ce qui manquait au premier essai.
     *
     * `legit_hit` est un NIVEAU. Au reset il vaut 0 : le HOLD s'applique
     * d'emblee, rien n'est transmis en aval, aucune course n'est possible. La
     * sonde du 2026-09-09 12:55 n'a donc RIEN gele -- six transactions bloquees
     * abouties -- alors que la campagne, elle, gele.
     *
     * La difference est le trafic legitime qui precede : apres lui, legit_hit
     * reste PERIME a 1 pendant les 2 cycles du pipeline, l'AW suivant traverse,
     * et l'aval peut l'accepter avant que le verdict ne tombe. On reproduit donc
     * cette condition : quelques transactions legitimes, PUIS le basculement. */
    printf("# Prechauffage : %d transactions legitimes pour porter legit_hit a 1.\r\n",
           WEDGE_WARMUP);
    for (int i = 0; i < WEDGE_WARMUP; i++)
        (void)fire_one('M', 0, LEGIT_DST, 0, &det, &tx);
    printf("# Prechauffage OK (dernier verdict=%c).\r\n",
           classify(fire_one('M', 0, LEGIT_DST, 0, &det, &tx)));

    printf("# ID_CFG w2 <- 99 : le MHA (STREAM_ID=2) devient illegitime aux yeux d'ARMOR.\r\n");
    printf("# Le trafic reste du mode 0, legitime. Seul ARMOR change d'avis.\r\n");
    w2[WRAP_ID_CFG_OFF / 8] = 99ULL;
    fence();

    printf("# PHASE 1/2 : LECTURE bloquee (cfg=1) x3 — attendu : passe si le wedge est propre aux ecritures\r\n");
    for (int i = 0; i < 3; i++) {
        TRACE_ARM();
        st = fire_one('M', 0, LEGIT_DST, 1 /* read */, &det, &tx);
        printf("#   lecture %d : verdict=%c det=%lu tx=%lu status=0x%lx\r\n",
               i, classify(st), (unsigned long)det, (unsigned long)tx,
               (unsigned long)st);
    }
    printf("# PHASE 1/2 TERMINEE : une lecture bloquee ne gele pas.\r\n");

    /* La phase 1 laisse legit_hit a 0 : sans reprechauffer, la phase 2 partirait
     * du cas deja teste (HOLD des le depart) et ne prouverait rien. */
    w2[WRAP_ID_CFG_OFF / 8] = 2ULL;
    fence();
    printf("# Reprechauffage avant la phase 2.\r\n");
    for (int i = 0; i < WEDGE_WARMUP; i++)
        (void)fire_one('M', 0, LEGIT_DST, 0, &det, &tx);
    w2[WRAP_ID_CFG_OFF / 8] = 99ULL;
    fence();

    printf("# PHASE 2/2 : ECRITURE bloquee (cfg=0) x3 — c'est ici que le gel est attendu\r\n");
    for (int i = 0; i < 3; i++) {
        TRACE_ARM();
        st = fire_one('M', 0, LEGIT_DST, 0 /* write */, &det, &tx);
        printf("#   ecriture %d : verdict=%c det=%lu tx=%lu status=0x%lx\r\n",
               i, classify(st), (unsigned long)det, (unsigned long)tx,
               (unsigned long)st);
    }
    printf("# PHASE 2/2 TERMINEE : une ecriture bloquee ne gele pas non plus.\r\n");

    w2[WRAP_ID_CFG_OFF / 8] = 2ULL;   /* remise en etat */
    fence();

    /* Purge du BANNISSEMENT avant de rendre la main. armor_wrap_clear() efface
     * les bits collants et les compteurs, mais PAS le timer interne de
     * security_monitor (BLOCK_DURATION, ~2 ms en profil BENCH). Sans cette
     * attente, la premiere transaction de SC07 -- meme wrapper -- part alors que
     * le MHA est encore banni : c'est exactement le ERR=1 vu sur SC07 au run du
     * 2026-09-09 12:55, qui n'etait pas un faux positif d'ARMOR mais un residu
     * de la sonde. */
    wait_cycles(WEDGE_BAN_DRAIN_CY);
    armor_wrap_clear();
    printf("# ID_CFG w2 restaure a 2, bannissement purge, compteurs remis a zero.\r\n");
    printf("# ===== FIN DE SONDE =====\r\n\r\n");
}
#endif

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
    printf("# SUMMARY-DET / SUMMARY-TX,name,N,n,n_lat,TP,FP,FN,TN,Lmin,Lavg,Lp50,Lp99,Lmax\r\n");
    calib_timer();

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

#ifdef BENCH_WEDGE_PROBE
    /* APRÈS armor_wrap_init ET la mise en route de l'IOMMU : la sonde doit voir
     * exactement l'environnement de la campagne, sinon elle ne prouve rien.
     * Placée avant, elle tournait ARMOR non armé et son ID_CFG était de toute
     * façon écrasé par armor_wrap_init. */
    wedge_probe();
#endif

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
     * MISE À JOUR 2026-09-09 : SC01 est passé en TOUT DERNIER parce qu'il gèle
     * la carte et emportait SC02, SC04 et SC03 avec lui. Voir le commentaire à
     * sa nouvelle place. L'ordre ci-dessous décrit le raisonnement d'origine,
     * qui reste valable pour tous les autres.
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

#ifdef BENCH_SC03_FIRST
    /* ==================================================================
     * DIAGNOSTIC (-DBENCH_SC03_FIRST) — SC03 AVANT SC02.
     *
     * La question posée, et une seule : LE GEL EST-IL SPÉCIFIQUE AUX
     * ÉCRITURES ? SC03 est la seule attaque en LECTURE (mode 5, inondation
     * d'AR avec r_ready=0). Sous ENFORCE=1 il n'a jamais été atteint : SC02
     * gèle avant lui, à chaque run.
     *
     *   SC03 gèle aussi  -> le canal W est hors de cause, le défaut est sur le
     *                       chemin d'adresse ou de réponse ;
     *   SC03 va au bout   -> le gel est propre aux écritures, et le canal W
     *                       redevient suspect malgré `ecart = 0`.
     *
     * CE QUE CET ORDRE DÉTRUIT, à savoir avant de lire le reste du log :
     * SC03 laisse le compteur d'outstanding du wrapper SATURÉ pour toute la
     * suite de la campagne (voir le commentaire à sa place normale). Tout ce
     * qui vient après hérite donc d'un OUTS parasite : **les verdicts de SC02,
     * SC04 et SC01 ne valent rien dans ce build**. Seule la question du gel a
     * un sens ici — elle ne dépend d'aucun verdict, seulement de l'endroit où
     * le log s'arrête.
     *
     * Ne jamais publier de chiffres issus d'un build portant ce drapeau.
     * ================================================================== */
    printf("# DIAG : SC03 JOUE EN PREMIER (-DBENCH_SC03_FIRST) — "
           "les verdicts de SC02, SC04 et SC01 sont contamines par OUTS\r\n");
    run_scenario("SC03-OUTS",  'M', /*mode*/5, LEGIT_DST, /*cfg*/0, N_ATK, 1, &s[n++]);
#endif

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
     * plus aucun scénario ne s'exécute après -> aucune contamination.
     *
     * -DBENCH_SC03_FIRST le remonte avant SC02, pour un diagnostic precis et au
     * prix de la contamination -- voir le commentaire a cet endroit. */
#ifndef BENCH_SC03_FIRST
    run_scenario("SC03-OUTS",  'M', /*mode*/5, LEGIT_DST, /*cfg*/0, N_ATK, 1, &s[n++]);
#endif

    /* SC-01 : ID spoofing — attendu BANNED par ARMOR. EXÉCUTÉ EN TOUT DERNIER,
     * et c'est un contournement assumé, pas un choix de méthode.
     *
     * SC01 GÈLE LE CPU sur carte, à la première itération, avant la moindre
     * ligne CSV — le 2026-09-08 puis le 2026-09-09, au même endroit, avec et
     * sans le correctif `bad_id` du wrapper. Tant qu'il était placé avant
     * SC02/SC04/SC03, il emportait avec lui les TROIS seuls scénarios de
     * protection sous ENFORCE=1 que la campagne pouvait produire. En dernier,
     * tout le reste est mesuré et le gel ne coûte plus que SC01.
     *
     * CE QUE ÇA COÛTE, à savoir avant de lire ses chiffres : SC03 laisse le
     * compteur d'outstanding du wrapper saturé pour le reste de la campagne
     * (voir juste au-dessus), donc SC01 hérite d'un OUTS parasite. Ses verdicts
     * ne valent rien dans cet ordre. C'est acceptable uniquement parce qu'il
     * n'en produit aucun.
     *
     * À RÉTABLIR dès que le gel est corrigé : replacer ce bloc avant SC02, à sa
     * position d'origine, pour retrouver un SC01 propre. */
    run_scenario("SC01-SPOOF", 'M', /*mode*/1, LEGIT_DST, /*cfg*/0, N_ATK, 1, &s[n++]);
#ifndef BENCH_NO_LHA_BG
    lha_bg_stop();   /* arrêt du trafic de fond */
#endif

    printf("\r\n###### RESUME ######\r\n");
    for (int i = 0; i < n; i++) dump(&s[i]);
    printf("###### END ######\r\n");

    /* Fin : on rentre en wfi forever */
    while (1) asm volatile("wfi");
}
