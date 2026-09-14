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
#ifdef BENCH_ASOS_IRQ
#include <irq.h>
#include <plic.h>
#endif
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
/* 0x40 PIPE_DEPTH : adresses en vol du mode 7. 0 = valeur de synthese (16),
 * celle qui a gele la carte le 2026-09-13. (v16) */
#define MHA_PIPE_DEPTH_OFF      (0x40ULL)

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
#define WRAP_ADDR_SPAN_OFF      (0x100ULL)  /* v17 : [31:0] min, [63:32] max */
#define WRAP_ADDR_WALK_OFF      (0x108ULL)  /* v17 : [31:0] chgts de page    */

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
#define WRAP_CTRL_RFMCNT        (1ULL << 12)  /* moniteur de flux : transferts et non fronts (v14) */
/* CTRL[23:16] : seuil du moniteur de flux, 0 = valeur de synthese (8). (v15) */
#define WRAP_CTRL_THRESH(n)     (((uint64_t)(n) & 0xFFULL) << 16)
#define WRAP_CTRL_THRESH_GET(v) ((unsigned)(((v) >> 16) & 0xFFULL))
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

/* Compiler avec -DARMOR_RFMCNT=1 pour que request_flow_monitor compte les
 * TRANSFERTS d'adresse accomplis en aval au lieu des FRONTS de handshake
 * (CTRL[12], MAGIC v14).
 *
 * A 0 (defaut, comportement historique), deux adresses transferees sur deux
 * cycles consecutifs ne comptent que pour UNE : le seuil de 8 par fenetre est
 * alors hors d'atteinte d'un maitre qui pipeline ses adresses. L'accelerateur
 * de ce banc ne le fait jamais -- sa FSM repasse par G_W entre deux AW, donc
 * aw_valid retombe -- et l'A/B au banc est en consequence RIGOUREUSEMENT
 * IDENTIQUE sur les six scenarios. Ce bit ne ferme donc pas un trou que la
 * campagne actuelle traverse : il ferme un trou qu'elle ne sait pas creuser.
 *
 * La preuve du sous-comptage est au banc, scenario 4 (`./run_sim.sh 4`) : douze
 * adresses transferees sur douze cycles consecutifs comptent 1 en mode front et
 * 12 en mode transfert.
 *
 * Attendu sur carte : aucune difference de detection. Une difference serait une
 * information -- elle voudrait dire qu'un maitre y pipeline ses adresses. */
#ifndef ARMOR_RFMCNT
#define ARMOR_RFMCNT 0
#endif

/* Compiler avec -DARMOR_THRESH=<n> pour regler le seuil du moniteur de flux
 * (CTRL[23:16], MAGIC v15). 0 = valeur de synthese, soit 8.
 *
 * A QUOI CA SERT. Une campagne par valeur produit la courbe detection / faux
 * positifs en fonction du seuil -- la figure qui remplacerait le « 80 % » isole
 * du papier. Sans ce champ il fallait une SYNTHESE par point de courbe.
 *
 * CE QUE LA CARTE A DEJA MESURE, le 2026-09-13, et qui dit ou chercher :
 *   trafic legitime pilote par le logiciel  : 1 requete par fenetre (pic 1)
 *   low-and-slow SC08                       : 1 par fenetre (pic 1)
 *   DMA legitime SATURANT (fond LHA)        : 2,4 de moyenne, PIC 4
 *                                             sur 5,4 millions de fenetres
 *   tempete SC02 sans blocage               : 4,9 de moyenne, PIC 10
 *   seuil actuel                            : 8
 *
 * Un seuil de 6 passe donc au-dessus du pic legitime avec deux de marge. En
 * dessous de 5, attendre des faux positifs sous fond LHA : au banc, seuil 4
 * suffit a marquer du trafic legitime (dont la densite y vaut 4, comme le fond
 * de la carte) et a bloquer 9 des 84 transactions de SC08.
 *
 * NE PAS confondre avec un reglage de confort : toute campagne qui change ce
 * seuil n'est comparable qu'aux campagnes du MEME seuil. */
#ifndef ARMOR_THRESH
#define ARMOR_THRESH 0
#endif

/* Profondeur d'adresses en vol de SC09 (registre 0x40 de l'accelerateur), a
 * n'utiliser qu'avec -DBENCH_SC09. 0 = valeur de synthese, soit 16.
 *
 * POURQUOI CE REGLAGE EXISTE. Le mode 7 a GELE la carte a 16 adresses en vol,
 * dans les deux bras -- donc independamment d'ARMOR. Chercher la profondeur a
 * laquelle le SoC lache demandait jusqu'ici une synthese par point, soit
 * 45 minutes et un gel par essai. COMMENCER PAR 2, monter progressivement, et
 * ne pas sauter a 16 : chaque gel coute un `pkill -x hw_server` suivi d'un
 * `2_build_HB.sh program`, le chargement JTAG seul ne suffisant pas.
 *
 * Au banc, de 2 a 16, le wrapper tient a toutes les profondeurs : appariement
 * W et B propre, aucune file de sort debordee. Le banc ne modelise pas le
 * crossbar, c'est-a-dire precisement le suspect. */
#ifndef BENCH_SC09_DEPTH
#define BENCH_SC09_DEPTH 0
#endif

/* Quiescence entre SC09 et SC04 (-DBENCH_SC09_QUIESCE_CY=N, defaut 0 = rien).
 *
 * DIAGNOSTIC du gel SC09(profondeur >= 8) -> SC04-MSI mesure le 2026-09-13.
 * Insere wait_cycles(N) APRES SC09 et AVANT le *ctrl=1 de SC04, pour laisser
 * l'interconnexion partagee (crossbar + IOMMU) se drainer. La salve mode 7
 * profonde congestionne l'aval que le banc ne modelise pas ; la question, et
 * une seule : cette congestion est-elle TRANSITOIRE (elle se vide avec du
 * temps) ou un ETAT COINCE (AW orphelin, B jamais rendu, qu'aucun delai ne
 * libere) ?
 *   d8 ET d16 vont au bout -> congestion transitoire : le wedge est un temps
 *                             de drain, une mitigation firmware est jouable,
 *                             ARMOR est hors de cause ;
 *   gele encore            -> etat coince en aval : correction RTL obligatoire,
 *                             aucun delai ne suffit.
 * N en cycles coeur (50 MHz). 1000000 ~ 20 ms, tres au-dela de tout drain
 * plausible d'une salve de 50 x profondeur ecritures de 64 B. */
#ifndef BENCH_SC09_QUIESCE_CY
#define BENCH_SC09_QUIESCE_CY 0
#endif

/* Nombre d'iterations de SC09 (-DBENCH_SC09_N=n, defaut 0 = N_ATK).
 *
 * COMPAGNON de BENCH_SC09_QUIESCE_CY. Le gel mode 7 profond etant tire a
 * CHAQUE *ctrl=1 de SC09, les 50 iterations par defaut ne laissent presque
 * jamais SC09 survivre jusqu'a la quiescence : reduire n abaisse l'exposition
 * pour que SC09 aille au bout et que le gap AVANT SC04 soit enfin teste.
 * Compromis : trop bas, SC09 ne stresse plus assez l'aval pour que SC04
 * bascule, et le test de quiescence devient vide. n=3 tient les deux. */
#ifndef BENCH_SC09_N
#define BENCH_SC09_N 0
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

/* DBG_WOWED : deux champs de 8 bits DEPUIS v14, de 4 bits avant.
 *
 * Les deux ont bouge ensemble le 2026-09-13 : w_owed_q est passe a 8 bits parce
 * qu'un maitre qui emet seize adresses a la volee (mode 7) saturait les quatre.
 * Ce decodeur a deja mordu une fois dans l'autre sens -- il lisait 8 bits sur un
 * RTL qui en portait 4, parce que le commentaire du RTL l'annoncait ainsi, et
 * sortait « w_owed=16 max=0 » dans le log du 2026-09-10 12:36 : un compteur de
 * 4 bits a 16 et un maximum sous la valeur courante, deux impossibilites a la
 * fois. C'etait 0x10, soit max=1 owed=0.
 *
 * Sur un bitstream anterieur a v14 les bits [7:4] portent le maximum et non le
 * haut de la valeur courante : `w_owed` y sera donc lu trop grand des que le
 * maximum depasse zero. Ne pas melanger les logs des deux versions -- le MAGIC
 * en tete de campagne tranche. */
#define WRAP_WOWED_CUR(v)       ((unsigned long)((v)       & 0xFF))
#define WRAP_WOWED_MAX(v)       ((unsigned long)(((v) >> 8) & 0xFF))

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
static volatile uint64_t *mha_pipe_depth = (volatile uint64_t *)(MHA_BASE_ADDR + MHA_PIPE_DEPTH_OFF);
#define MHA_SCAN_SPAN_OFF       (0x48ULL)   /* mode 8 : pages balayees */
static volatile uint64_t *mha_scan_span  = (volatile uint64_t *)(MHA_BASE_ADDR + MHA_SCAN_SPAN_OFF);

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
#ifdef BENCH_SC09
        printf("# ATTENTION : SC09 (mode 7) A GELE LA CARTE le 2026-09-13, "
               "sur son PREMIER lancement, dans LES DEUX bras (0x1731 et 0x731). "
               "Reprise : pkill -x hw_server puis 2_build_HB.sh program -- le "
               "chargement JTAG seul ne suffit pas. Voir doc/REPRENDRE.md\r\n");
        if (v < 14)
            printf("# ATTENTION : BENCH_SC09=1 mais bitstream v%u -- le mode 7 "
                   "n'existe pas dans cet accelerateur, SC09 emettra du TRAFIC "
                   "NORMAL et sera lu comme une non-detection\r\n", v);
        if (!ARMOR_RFMCNT)
            printf("# NOTE : SC09 sans ARMOR_RFMCNT -- aucune detection attendue, "
                   "c'est le bras qui montre l'angle mort du comptage par fronts\r\n");
        if (!ARMOR_BFATE)
            printf("# ATTENTION : SC09 sans ARMOR_BFATE -- seize AW en vol sans "
                   "leurs donnees font decrocher le canal B (au banc : 488 B en "
                   "trop, 50 manquants, un AW reste du). Armer CTRL[10].\r\n");
#endif
        if (v < 16)
            printf("# ARMOR v%u : 0x40[39:32] lira zero -- pas de filigrane de "
                   "profondeur d'en-vol\r\n", v);
#ifdef BENCH_SC09
        if (BENCH_SC09_DEPTH && v < 16)
            printf("# ATTENTION : BENCH_SC09_DEPTH=%d mais bitstream v%u -- le "
                   "registre 0x40 de l'accelerateur n'existe pas, la profondeur "
                   "restera a 16 et la carte GELERA\r\n", BENCH_SC09_DEPTH, v);
#endif
        if (ARMOR_THRESH && v < 15)
            printf("# ATTENTION : ARMOR_THRESH=%d mais bitstream v%u -- CTRL[23:16] "
                   "SANS EFFET, le seuil reste celui de la synthese\r\n",
                   ARMOR_THRESH, v);
        if (ARMOR_RFMCNT && v < 14)
            printf("# ATTENTION : ARMOR_RFMCNT=1 mais bitstream v%u -- CTRL[12] "
                   "SANS EFFET, le moniteur de flux compte les fronts\r\n", v);
        /* Pas une ATTENTION : rien n'est casse, une mesure manque. Zero n'est
         * pas « aucune requete », c'est « aucune mesure » -- la meme confusion
         * que pour 0xF0/0xF8, et elle a deja coute une journee. */
        if (v < 14)
            printf("# ARMOR v%u : 0x38[63:32] lira zero -- ni occupation max ni "
                   "fenetres actives, un faux negatif de SC02 restera sans marge "
                   "mesuree\r\n", v);
        /* Meme raison : zero n'est pas « rien touche », c'est « rien mesure ».
         * Sans le v17, SC10 tourne mais ne prouve rien -- le mode 8 de l'accel
         * n'existe pas avant ce bitstream et degenere en trafic normal. */
        if (v < 17)
            printf("# ARMOR v%u : 0x100/0x108 liront zero -- ni etendue "
                   "d'adresses ni changements de page, et le mode 8 de l'accel "
                   "n'existe pas : SC10 mesurera du trafic ordinaire\r\n", v);
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
                  | (ARMOR_RFMCNT ? WRAP_CTRL_RFMCNT : 0ULL)
                  | WRAP_CTRL_THRESH(ARMOR_THRESH)
                  | WRAP_CTRL_STICKY_CLR | WRAP_CTRL_CNT_CLR;
    w1[WRAP_CTRL_OFF / 8] = ctrl;
    w2[WRAP_CTRL_OFF / 8] = ctrl;
    fence();

    printf("# ARMOR arme : ENFORCE=%d, W_SKID=%d, FRESH=%d, WCAP=%d, RHOLD=%d, WFATE=%d, "
           "BFATE=%d, RFMCNT=%d, SEUIL=%s, ID_CFG w1=1 w2=2, MSI_ADDR=0x%08x\r\n",
           enforce, ARMOR_WSKID, ARMOR_FRESH, ARMOR_WCAP, ARMOR_RHOLD, ARMOR_WFATE,
           ARMOR_BFATE, ARMOR_RFMCNT,
           ARMOR_THRESH ? "regle" : "synthese (8)",
           (unsigned)MSI_TARGET_DST);
    if (ARMOR_THRESH)
        printf("# ARMOR seuil de flux : %d requetes par fenetre (CTRL[23:16]) -- "
               "cette campagne n'est comparable qu'aux campagnes du MEME seuil\r\n",
               ARMOR_THRESH);

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
    /* 0x38 porte trois grandeurs depuis v14 : les episodes de storm dans les
     * 32 bits bas, l'occupation maximale d'une fenetre de flux dans l'octet
     * suivant, et le nombre de fenetres fermees non vides au-dessus.
     *
     * reqmax/winact sont ce qui manquait pour lire un faux negatif de SC02. Une
     * salve de 16 ecritures n'est au-dessus du seuil de 8 que si elle tient
     * dans UNE fenetre de 100 cycles : etalee par la traduction IOMMU, elle en
     * met 5 ou 6 dans chacune et aucun moniteur a fenetre ne peut la voir.
     * `reqmax=6` sur un scenario non detecte dit cela en un chiffre ; sans lui
     * on ne pouvait que le supposer. Et `storm/(req_up/winact)` donne le debit
     * de l'attaque TEL QUE LE MONITEUR LE VOIT, a comparer aux 16 par salve
     * qu'annonce la Table 5.
     *
     * Sur un bitstream anterieur a v14 les deux champs lisent zero, et le
     * controle de version l'a deja dit en tete de campagne. */
    uint64_t stm = w[WRAP_CNT_STORM_OFF / 8];
    uint64_t out = w[WRAP_CNT_OUTS_OFF  / 8];
    /* v17 : l'etendue d'adresses, que les moniteurs de debit ne portent pas.
     * amin=0xFFFFFFFF signale « aucune requete vue », pas une etendue nulle --
     * ne pas soustraire dans ce cas. Sur un bitstream anterieur au v17 les deux
     * registres lisent zero, et le controle de version l'a deja dit. */
    uint64_t spn = w[WRAP_ADDR_SPAN_OFF / 8];
    uint64_t wlk = w[WRAP_ADDR_WALK_OFF / 8];
    unsigned long amin = (unsigned long)(spn & 0xFFFFFFFFULL);
    unsigned long amax = (unsigned long)(spn >> 32);
    unsigned long apg  = (amin == 0xFFFFFFFFUL) ? 0UL
                                                : (unsigned long)(((amax - amin) >> 12) + 1);
    printf("# ARMORCNT,%s,%s,sticky=0x%08x,fail=%lu,ban=%lu,storm=%lu,outs=%lu,msi=%lu,"
           "reqmax=%lu,winact=%lu,outsmax=%lu,amin=0x%08lx,amax=0x%08lx,"
           "apages=%lu,pgchg=%lu\r\n",
           tag, who,
           (unsigned)w[WRAP_STICKY_OFF      / 8],
           (unsigned long)w[WRAP_FAILCNT_OFF    / 8],
           (unsigned long)w[WRAP_CNT_BANNED_OFF / 8],
           (unsigned long)(stm & 0xFFFFFFFFULL),
           (unsigned long)(out & 0xFFFFFFFFULL),
           (unsigned long)w[WRAP_CNT_MSI_OFF    / 8],
           (unsigned long)((stm >> 32) & 0xFFULL),
           (unsigned long)(stm >> 40),
           /* OUTS_MAX : plus forte profondeur d'en-vol atteinte, seuil 16.
            * C'est ce chiffre qui dira si une campagne non detectee est passee
            * SOUS le seuil -- la question laissee ouverte le 2026-09-13. */
           (unsigned long)((out >> 32) & 0xFFULL),
           amin, amax, apg,
           (unsigned long)(wlk & 0xFFFFFFFFULL));
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

/* ------------------------------------------------------------------------
 * SC10 — BALAYAGE MEMOIRE (mode 8, MAGIC v17)
 *
 * POURQUOI CE SCENARIO EXISTE. SC08, dit « low-and-slow », emet mode 0 vers
 * LEGIT_DST : c'est le trafic legitime joue sept fois plus longtemps, et son
 * « 0 % de detection » mesure l'ABSENCE DE FAUX POSITIF, pas un faux negatif.
 * Constate le 2026-09-14 : SC07 et SC08 donnent 264 ticks par transaction au
 * tick pres et une requete par fenetre chacun. Il n'y avait donc, jusqu'ici,
 * aucun scenario ou un moniteur de debit soit structurellement aveugle.
 *
 * CE QUE FAIT SC10. Le MHA emet au rythme NOMINAL -- une requete par
 * lancement, exactement comme le mode 0 -- mais deplace son adresse d'une page
 * a chaque transfert. Aucun seuil n'est franchi : ni le flux (une requete par
 * fenetre), ni l'outstanding (une transaction en vol), ni l'IOMMU, puisque
 * SCAN_BASE et les SCAN_PAGES qui suivent sont DANS la region guest
 * (0x9000_0000 + 512 Mio, mappee en identite). L'attaque reste dans ses droits.
 *
 * CE QU'ON ATTEND. Zero verdict : expected_block = 0 pour chaque iteration, et
 * un blocage serait un FAUX POSITIF. La preuve ne se lit pas dans les verdicts
 * mais dans ADDR_SPAN et ADDR_WALK du wrapper 2, a comparer aux memes registres
 * sur SC07 : meme cadence, meme volume, etendue incomparable.
 *
 * BORNES. SCAN_BASE est a 32 Mio du debut de la region guest, donc au-dessus
 * de l'image du guest, et le balayage s'arrete bien avant MSI_TARGET_DST
 * (0x9100_8000) : une ecriture a cette adresse serait classee MSI et
 * polluerait la mesure.
 * ------------------------------------------------------------------------ */
#define SCAN_BASE   (0x92000000ULL) /* region guest, hors image et hors MSI */
#define SCAN_PAGES  256             /* 1 Mio balaye, 4 Kio par pas */
#define SCAN_N      700             /* meme volume que SC08 : comparaison a volume egal */

static void run_sc08(stats_t *st) {
    stat_init(st, "SC08-LAS");
    TRACE_ARM();
    /* CNT_CLR ici et ARMORCNT a la fin, comme run_scenario le fait pour tous les
     * autres scenarios (2026-09-13). SC08 en etait le seul depourvu, et c'est
     * precisement celui dont l'occupation de fenetre decide de tout l'argument :
     * la campagne du 2026-09-13 08:56 a mesure le trafic legitime a 1,00 requete
     * par fenetre et la tempete a 7,08 pour un seuil de 8, sans pouvoir dire ou
     * se situe le low-and-slow entre les deux. `winact` et `reqmax` le diront.
     *
     * Le cout est deux lectures CSR et deux printf entre SC08 et SC02, au repos
     * -- SC02 repart de son propre CNT_CLR. C'est la meme instrumentation que
     * les autres pas, pas une sonde supplementaire. */
    armor_wrap_clear();
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
    armor_wrap_report("SC08-LAS");
}

/* SC10 — balayage memoire. Voir le bloc de commentaires de SCAN_BASE. */
static void run_sc10(stats_t *st) {
    stat_init(st, "SC10-SCAN");
    TRACE_ARM();
    armor_wrap_clear();
    *mha_scan_span = (uint64_t)SCAN_PAGES;
    uint64_t span_rb = *mha_scan_span;
    printf("# === SC10 balayage : %d requetes, %d pages depuis 0x%08x "
           "(SCAN_SPAN relu %lu)\r\n",
           SCAN_N, SCAN_PAGES, (unsigned)SCAN_BASE, (unsigned long)span_rb);
    if (span_rb != (uint64_t)SCAN_PAGES)
        printf("# ATTENTION : SCAN_SPAN relit %lu -- bitstream anterieur au v17, "
               "le mode 8 tournera a sa valeur de synthese\r\n",
               (unsigned long)span_rb);
    int passed = 0, blocked = 0;
    for (int i = 0; i < SCAN_N; i++) {
        uint64_t lat_det = 0, lat_tx = 0;
        uint64_t status = fire_one('M', 8 /* balayage */, SCAN_BASE,
                                   0 /* write */, &lat_det, &lat_tx);
        if (armor_blocked(status)) { blocked++; } else { passed++; }
        /* expected_block = 0 : on ATTEND le silence des moniteurs. Un blocage
         * ici est un faux positif, pas une detection. */
        stat_add(st, /*expected*/0, armor_blocked(status), lat_det, lat_tx);
    }
    printf("# SC10 : passed=%d blocked=%d (FP=%d attendu 0 -- la preuve est "
           "dans ADDR_SPAN/ADDR_WALK)\r\n", passed, blocked, blocked);
    armor_wrap_report("SC10-SCAN");
}

/* ============================================================
 * ASOS, NIVEAU 0 : cout logiciel de la boucle de decision, MESURE SUR CARTE
 *
 * La Table 8 du papier mesure L_processing, L_mmio et L_total dans une
 * co-simulation QEMU + Verilator, et doit excuser la dispersion de ses chiffres
 * par l'ordonnancement non deterministe du coeur emule. Or deux de ses trois
 * colonnes n'ont pas besoin d'interruption pour etre mesurees : dans
 * l'equation (5), seul le point t0 en depend. L'evaluation de la menace est du
 * calcul pur, l'actuation une sequence d'ecritures MMIO -- les deux sont
 * mesurables ici, sur silicium, avec le compteur deja calibre par `# CALIB`.
 *
 * CE QUI EST MESURE
 *   L_processing : lecture de STATUS, decroissance gamma, somme ponderee des
 *                  bits d'alerte actifs, classification TLC (9 seuils,
 *                  Table 2), selection de l'etat.
 *   L_mmio       : ecritures de politique dans ARMOR, RELECTURE COMPRISE. Sans
 *                  la relecture on chronometrerait une ecriture postee, c'est
 *                  a dire rien.
 *
 * CE QUI NE L'EST PAS, et qu'il ne faut pas presenter comme tel : le chemin
 * d'interruption, absent du RTL synthetise (`wrapper.sv` n'a pas de `irq_o`),
 * et la notification inter-VM avec sa copie de 8 Kio -- que le papier designe
 * lui-meme comme le terme dominant de la variabilite de L_mmio. Ce bloc mesure
 * la configuration a VM unique, pas l'architecture a VM de service.
 *
 * LIMITE D'ACTUATION. Le design n'expose aucun registre de debit : les etats
 * SUSPICIOUS de la Table 2 (« resource throttling ») n'ont pas d'equivalent
 * materiel ici et sont actues par le seul moyen disponible, re-armement de
 * ENFORCE et purge du collant. QUARANTINE et BANNED, eux, le sont exactement
 * comme le papier les decrit : la revocation du Device ID autorise s'ecrit dans
 * ID_CFG. C'est pour ca que L_mmio depend du TLC atteint, et c'est le resultat.
 * ============================================================ */
#ifdef BENCH_ASOS

#define ASOS_GAMMA_NUM   230u   /* 230/256 = 0,898 : gamma = 0,9 en MAC entier, */
#define ASOS_GAMMA_SH    8u     /* sans division -- le papier dit « multiply-accumulate » */
#define ASOS_REPEAT      20     /* repetitions, pour donner une dispersion */

/* Poids de severite par type d'evenement, sur les bits d'alerte de STATUS. */
static const struct { uint64_t bit; unsigned w; const char *name; } asos_ev[] = {
    { 1ULL << 4, 40, "BANNED"  },   /* usurpation d'identite confirmee */
    { 1ULL << 6, 30, "OUTS"    },
    { 1ULL << 3, 25, "BLOCKED" },
    { 1ULL << 5, 20, "STORM"   },
    { 1ULL << 7, 15, "MSI"     },
};
#define ASOS_NEV  (sizeof(asos_ev) / sizeof(asos_ev[0]))
#define ARMOR_ALERT_MASK  ((1ULL<<3)|(1ULL<<4)|(1ULL<<5)|(1ULL<<6)|(1ULL<<7))

/* Table 2 : neuf seuils, dix classes. */
static unsigned asos_tlc(uint64_t sc) {
    static const uint64_t th[9] = { 1, 6, 16, 26, 36, 51, 71, 86, 100 };
    unsigned tlc = 10;
    for (unsigned i = 0; i < 9; i++) if (sc >= th[i]) tlc = 9 - i;
    return tlc;
}

static const char *asos_state(unsigned tlc) {
    if (tlc >= 8) return "ACTIVE";
    if (tlc >= 6) return "LEARNING";
    if (tlc >= 4) return "SUSPICIOUS";
    if (tlc == 3) return "QUARANTINE";
    return "BANNED";
}

/* Actuation : ce que la politique ecrit REELLEMENT dans ARMOR. La relecture
 * finale fait partie de la mesure, voir l'en-tete. */
static unsigned asos_actuate(volatile uint64_t *w, unsigned tlc, uint64_t ctrl) {
    unsigned nw;
    if (tlc >= 6) {                 /* ACTIVE / LEARNING : observation seule */
        w[WRAP_CTRL_OFF / 8] = ctrl;
        nw = 1;
    } else if (tlc >= 4) {          /* SUSPICIOUS : restriction */
        w[WRAP_CTRL_OFF / 8] = ctrl | WRAP_CTRL_STICKY_CLR;
        w[WRAP_CTRL_OFF / 8] = ctrl;
        nw = 2;
    } else {                        /* QUARANTINE / BANNED : revocation du Device ID */
        w[WRAP_ID_CFG_OFF / 8] = 0xFFFFFFFFULL;
        w[WRAP_CTRL_OFF   / 8] = ctrl | WRAP_CTRL_STICKY_CLR;
        w[WRAP_CTRL_OFF   / 8] = ctrl;
        nw = 3;
    }
    (void)w[WRAP_CTRL_OFF / 8];     /* force la fin des ecritures postees */
    return nw;
}

/* Puits volatile. SANS LUI, -O2 elimine toute l'evaluation : ni le score, ni le
 * TLC, ni l'etat ne sont relus, donc le compilateur a le droit de tout jeter.
 * Mesure avant correction : 16 cycles constants de k=0 a k=5, soit la lecture
 * MMIO seule. Un banc qui chronometre du code mort ne mesure rien. */
static volatile uint64_t asos_sink;

typedef struct { uint64_t min, max, sum; unsigned n; } asos_acc_t;

static void asos_acc(asos_acc_t *a, uint64_t v) {
    if (a->n == 0 || v < a->min) a->min = v;
    if (a->n == 0 || v > a->max) a->max = v;
    a->sum += v; a->n++;
}

/* Une reaction complete : evaluation puis actuation, chronometrees separement. */
static void asos_step(volatile uint64_t *w, uint64_t ctrl, uint64_t snap,
                      uint64_t *score,
                      unsigned *o_tlc, unsigned *o_k, unsigned *o_nw,
                      uint64_t *o_proc, uint64_t *o_mmio) {
    uint64_t t0 = read_counter();
    /* Le COLLANT, pas STATUS. Les verdicts de flux ne durent que BLOCK_CYCLES
     * (4 a 10 cycles en profil BENCH) : une lecture de STATUS apres coup ne voit
     * jamais rien, ce qu'une premiere version de ce bloc a montre en donnant
     * k = 0 partout. `snap` est l'etat collant releve AVANT la serie : la
     * lecture MMIO reste reelle et son cout est dans la mesure, mais l'ensemble
     * d'alertes evalue ne change pas d'une repetition a l'autre -- sans quoi le
     * STICKY_CLR de l'actuation viderait le registre des la premiere. */
    uint64_t st = w[WRAP_STICKY_OFF / 8] | snap;
    uint64_t sc = (*score * ASOS_GAMMA_NUM) >> ASOS_GAMMA_SH;
    unsigned k  = 0;
    for (unsigned i = 0; i < ASOS_NEV; i++)
        if (st & asos_ev[i].bit) { sc += asos_ev[i].w; k++; }
    unsigned tlc = asos_tlc(sc);
    const char *stname = asos_state(tlc);
    asos_sink = sc + tlc + (uint64_t)(uintptr_t)stname;
    uint64_t t1 = read_counter();
    unsigned nw = asos_actuate(w, tlc, ctrl);
    uint64_t t2 = read_counter();

    *score = sc; *o_tlc = tlc; *o_k = k; *o_nw = nw;
    *o_proc = t1 - t0; *o_mmio = t2 - t1;
}

static void run_asos(void) {
    volatile uint64_t *w1 = (volatile uint64_t *)WRAP1_BASE_ADDR;
    volatile uint64_t *w2 = (volatile uint64_t *)WRAP2_BASE_ADDR;
    /* CTRL tel que le MATERIEL le porte, pas tel qu'on croit l'avoir ecrit :
     * une politique doit preserver la configuration en place, et les deux
     * impulsions s'auto-effacent donc relisent zero. */
    uint64_t ctrl = w2[WRAP_CTRL_OFF / 8]
                  & ~(WRAP_CTRL_STICKY_CLR | WRAP_CTRL_CNT_CLR);

    printf("\r\n###### ASOS (niveau 0 : VM unique, sans IRQ) ######\r\n");
    printf("# ASOS : gamma=%u/256, poids BANNED=40 OUTS=30 BLOCKED=25 "
           "STORM=20 MSI=15, %d repetitions\r\n",
           ASOS_GAMMA_NUM, ASOS_REPEAT);
    printf("# ASOS,slot,evt,k,tlc,etat,ecritures,"
           "proc_min,proc_moy,proc_max,mmio_min,mmio_moy,mmio_max\r\n");

    /* Sequence calquee sur la Table 8, ramenee aux deux slots de la plateforme.
     * Les bits d'alerte lus sont ceux que la campagne vient reellement de
     * produire dans chaque wrapper : rien n'est simule. */
    static const struct { int slot; const char *evt; } seq[] = {
        { 1, "premier"  }, { 2, "premier"  },
        { 2, "repete"   }, { 1, "repete"   },
        { 2, "repete2"  }, { 2, "repete3"  },
    };

    /* Etat collant tel que la campagne vient de le laisser, releve une fois
     * pour toutes avant que la moindre actuation ne le purge. */
    uint64_t snap1 = w1[WRAP_STICKY_OFF / 8];
    uint64_t snap2 = w2[WRAP_STICKY_OFF / 8];
    printf("# ASOS : collant releve w1=0x%lx w2=0x%lx\r\n",
           (unsigned long)snap1, (unsigned long)snap2);

    for (unsigned r = 0; r < sizeof(seq) / sizeof(seq[0]); r++) {
        volatile uint64_t *w    = (seq[r].slot == 1) ? w1 : w2;
        uint64_t           snap = (seq[r].slot == 1) ? snap1 : snap2;
        asos_acc_t ap = {0,0,0,0}, am = {0,0,0,0};
        unsigned tlc = 10, k = 0, nw = 0;

        for (unsigned i = 0; i < ASOS_REPEAT; i++) {
            /* Le score repart de l'etat de la ligne precedente a chaque
             * repetition, sinon la decroissance le ferait deriver et les
             * repetitions ne mesureraient pas la meme chose. */
            uint64_t score = (uint64_t)r * 20ULL;
            uint64_t pr = 0, mm = 0;
            asos_step(w, ctrl, snap, &score, &tlc, &k, &nw, &pr, &mm);
            asos_acc(&ap, pr); asos_acc(&am, mm);
        }

        printf("# ASOS,%d,%s,%u,TLC-%u,%s,%u,%lu,%lu,%lu,%lu,%lu,%lu\r\n",
               seq[r].slot, seq[r].evt, k, tlc, asos_state(tlc), nw,
               (unsigned long)ap.min, (unsigned long)(ap.sum / ap.n),
               (unsigned long)ap.max,
               (unsigned long)am.min, (unsigned long)(am.sum / am.n),
               (unsigned long)am.max);
    }

    /* Cout en fonction du nombre de bits d'alerte simultanes. Le papier annonce
     * un cout O(k) « well under 100 integer cycles » sans jamais le mesurer ;
     * ici le masque est force, de 0 a 5 bits, la lecture de STATUS restant
     * reelle. C'est la seule partie de ce bloc qui n'est pas in situ. */
    printf("# ASOS-K,k,proc_min,proc_moy,proc_max\r\n");
    for (unsigned kk = 0; kk <= ASOS_NEV; kk++) {
        uint64_t mask = 0;
        for (unsigned i = 0; i < kk; i++) mask |= asos_ev[i].bit;
        asos_acc_t ap = {0,0,0,0};
        for (unsigned i = 0; i < ASOS_REPEAT; i++) {
            uint64_t t0 = read_counter();
            uint64_t st = w2[WRAP_STICKY_OFF / 8] | mask;
            uint64_t sc = (42ULL * ASOS_GAMMA_NUM) >> ASOS_GAMMA_SH;
            unsigned k = 0;
            for (unsigned j = 0; j < ASOS_NEV; j++)
                if (st & asos_ev[j].bit) { sc += asos_ev[j].w; k++; }
            unsigned tlc = asos_tlc(sc);
            const char *nm = asos_state(tlc);
            asos_sink = sc + tlc + k + (uint64_t)(uintptr_t)nm;
            uint64_t t1 = read_counter();
            asos_acc(&ap, t1 - t0);
        }
        printf("# ASOS-K,%u,%lu,%lu,%lu\r\n", kk,
               (unsigned long)ap.min, (unsigned long)(ap.sum / ap.n),
               (unsigned long)ap.max);
    }

    /* ------------------------------------------------------------------
     * DECOMPOSITION. Sans elle on attribue L_processing a ce qu'on croit.
     * Premiere lecture de ces chiffres, 2026-09-12 : j'avais mis les ~190
     * cycles sur le dos de la lecture MMIO, alors que L_mmio -- une ecriture
     * PLUS une relecture -- n'en valait que 44. Les deux ne pouvaient pas etre
     * vrais en meme temps. On mesure donc chaque terme separement.
     * ------------------------------------------------------------------ */
    printf("# ASOS-DECOMP,terme,cycles_pour_100,par_operation\r\n");
    {
        uint64_t t0, t1;

        /* a. lecture CSR du wrapper, nue */
        t0 = read_counter();
        for (unsigned i = 0; i < 100; i++) asos_sink = w2[WRAP_STICKY_OFF / 8];
        t1 = read_counter();
        printf("# ASOS-DECOMP,lecture_CSR_wrapper,%lu,%lu\r\n",
               (unsigned long)(t1 - t0), (unsigned long)((t1 - t0) / 100));

        /* b. ecriture CSR suivie de sa relecture, comme dans l'actuation */
        t0 = read_counter();
        for (unsigned i = 0; i < 100; i++) {
            w2[WRAP_CTRL_OFF / 8] = ctrl;
            asos_sink = w2[WRAP_CTRL_OFF / 8];
        }
        t1 = read_counter();
        printf("# ASOS-DECOMP,ecriture+relecture_CSR,%lu,%lu\r\n",
               (unsigned long)(t1 - t0), (unsigned long)((t1 - t0) / 100));

        /* c. l'evaluation SEULE, sans aucun MMIO : masque deja en main */
        uint64_t msk = snap2;
        t0 = read_counter();
        for (unsigned i = 0; i < 100; i++) {
            uint64_t sc = (42ULL * ASOS_GAMMA_NUM) >> ASOS_GAMMA_SH;
            unsigned k = 0;
            for (unsigned j = 0; j < ASOS_NEV; j++)
                if (msk & asos_ev[j].bit) { sc += asos_ev[j].w; k++; }
            asos_sink = sc + asos_tlc(sc) + k;
        }
        t1 = read_counter();
        printf("# ASOS-DECOMP,evaluation_seule_O(NEV),%lu,%lu\r\n",
               (unsigned long)(t1 - t0), (unsigned long)((t1 - t0) / 100));

        /* d. la MEME evaluation, mais reellement en O(k) : on n'itere que sur
         *    les bits ACTIFS, par extraction du bit de poids faible. C'est ce
         *    que le papier decrit ; la version (c) parcourt les 5 types a
         *    chaque fois et est donc O(NEV), d'ou sa platitude en k. */
        t0 = read_counter();
        for (unsigned i = 0; i < 100; i++) {
            uint64_t sc = (42ULL * ASOS_GAMMA_NUM) >> ASOS_GAMMA_SH;
            unsigned k = 0;
            uint64_t rem = msk & ARMOR_ALERT_MASK;
            while (rem) {
                uint64_t lsb = rem & (~rem + 1ULL);
                for (unsigned j = 0; j < ASOS_NEV; j++)
                    if (asos_ev[j].bit == lsb) { sc += asos_ev[j].w; break; }
                k++; rem ^= lsb;
            }
            asos_sink = sc + asos_tlc(sc) + k;
        }
        t1 = read_counter();
        printf("# ASOS-DECOMP,evaluation_seule_O(k),%lu,%lu\r\n",
               (unsigned long)(t1 - t0), (unsigned long)((t1 - t0) / 100));

        /* e. la classification TLC seule, 9 seuils */
        t0 = read_counter();
        for (unsigned i = 0; i < 100; i++) asos_sink = asos_tlc(40 + i % 70);
        t1 = read_counter();
        printf("# ASOS-DECOMP,classification_TLC,%lu,%lu\r\n",
               (unsigned long)(t1 - t0), (unsigned long)((t1 - t0) / 100));

        /* f. ACCES AU vPLIC : le prix d'une sortie de VM.
         *
         * C'est LE terme que le niveau 0 ne voit pas, et la reponse a « ASOS
         * tourne dans une VM, ca doit couter plus cher ». Les CSR du wrapper
         * sont en passthrough dans la config Bao (vm-configs/cva6-baremetal),
         * donc non trappes -- d'ou les 17 cycles du point (a). Le PLIC, lui,
         * est EMULE : bao-hypervisor/src/arch/riscv/vplic.c enregistre ses
         * handlers par vm_emul_add_mem, et le `claim` comme le `complete`
         * passent par vplic_hart_emul_handler. Chaque acces est donc un trap
         * vers l'hyperviseur et retour.
         *
         * On lit le registre de seuil, pas `claim` : la lecture de claim
         * acquitte une interruption et aurait un effet de bord. Le chemin de
         * trap est le meme. */
        {
            volatile uint32_t *vplic_threshold =
                (volatile uint32_t *)(0x0c000000UL + 0x200000UL);
            t0 = read_counter();
            for (unsigned i = 0; i < 100; i++) asos_sink = *vplic_threshold;
            t1 = read_counter();
            printf("# ASOS-DECOMP,lecture_vPLIC_emule,%lu,%lu\r\n",
                   (unsigned long)(t1 - t0), (unsigned long)((t1 - t0) / 100));
        }

        /* g. la boucle de mesure a vide : deux lectures de compteur */
        t0 = read_counter();
        for (unsigned i = 0; i < 100; i++) asos_sink = i;
        t1 = read_counter();
        printf("# ASOS-DECOMP,boucle_a_vide,%lu,%lu\r\n",
               (unsigned long)(t1 - t0), (unsigned long)((t1 - t0) / 100));
    }

    /* Remise en etat : l'actuation a pu revoquer les Device ID. Hors mesure. */
    w1[WRAP_ID_CFG_OFF / 8] = 1ULL;
    w2[WRAP_ID_CFG_OFF / 8] = 2ULL;
    w1[WRAP_CTRL_OFF / 8]   = ctrl;
    w2[WRAP_CTRL_OFF / 8]   = ctrl;
    fence();
    printf("# ASOS : ID_CFG et CTRL restaures (w1=%lu w2=%lu)\r\n",
           (unsigned long)w1[WRAP_ID_CFG_OFF / 8],
           (unsigned long)w2[WRAP_ID_CFG_OFF / 8]);
    printf("# ASOS : rappel -- retrancher le cout d'une lecture de compteur "
           "(voir `# CALIB`) pour comparer a un chiffre publie.\r\n");
}
#endif /* BENCH_ASOS */

/* ============================================================
 * ASOS, NIVEAU 1 : la boucle complete, INTERRUPTION COMPRISE
 *
 * Le niveau 0 mesurait le calcul et l'actuation, pas la notification. Or ASOS
 * tourne dans une VM sous Bao, et c'est la que se trouve le cout : les CSR du
 * wrapper sont en passthrough (17 cycles, non trappes), mais le PLIC du guest
 * est EMULE -- `bao-hypervisor/src/arch/riscv/vplic.c` enregistre ses handlers
 * par `vm_emul_add_mem`. Mesure du 2026-09-12 : une lecture du vPLIC coute
 * 813 cycles contre 17 pour un CSR passthrough, soit un facteur 48. Le `claim`
 * et le `complete` d'une interruption sont deux de ces acces.
 *
 * Ce bloc decoupe donc la reaction en quatre, la ou la Table 8 n'en voit que
 * deux :
 *
 *   L_notify  declenchement -> entree dans le gestionnaire. Contient la
 *             detection ARMOR, la livraison de l'interruption physique, son
 *             injection par Bao, et le `claim` sur le vPLIC.
 *   L_proc    evaluation de la menace et classification TLC.
 *   L_mmio    ecriture de la politique. Le STICKY_CLR y fait retomber irq_o.
 *   L_exit    sortie du gestionnaire -> reprise du fil principal, `complete`
 *             sur le vPLIC compris.
 *
 * Exige le bitstream v13 (CTRL[11] = IRQ_EN, irq_o cable sur les sources PLIC
 * 12 et 13) et les entrees `.interrupts` de vm-configs/cva6-baremetal.
 * ============================================================ */
#ifdef BENCH_ASOS_IRQ

#define WRAP_CTRL_IRQEN   (1ULL << 11)
/* Identifiants PLIC = index materiel + 1 (ID 0 reserve). Les wrappers sont
 * cables sur irq_sources[12] et [13], ils portent donc 13 et 14. */
#define ASOS_IRQ_W1       13
#define ASOS_IRQ_W2       14
#define ASOS_IRQ_TRIALS   16

static volatile uint64_t asos_t_entry, asos_t_assessed, asos_t_actuated;
static volatile unsigned asos_irq_seen, asos_irq_k, asos_irq_tlc, asos_irq_nw;
static volatile uint64_t asos_irq_score;
static uint64_t          asos_ctrl_saved;

static void asos_irq_handler(unsigned id) {
    asos_t_entry = read_counter();

    volatile uint64_t *w = (id == ASOS_IRQ_W1)
                         ? (volatile uint64_t *)WRAP1_BASE_ADDR
                         : (volatile uint64_t *)WRAP2_BASE_ADDR;

    uint64_t st = w[WRAP_STICKY_OFF / 8];
    uint64_t sc = (asos_irq_score * ASOS_GAMMA_NUM) >> ASOS_GAMMA_SH;
    unsigned k  = 0;
    for (unsigned i = 0; i < ASOS_NEV; i++)
        if (st & asos_ev[i].bit) { sc += asos_ev[i].w; k++; }
    unsigned tlc = asos_tlc(sc);
    asos_sink = sc + tlc + (uint64_t)(uintptr_t)asos_state(tlc);

    asos_t_assessed = read_counter();

    /* Ecrit STICKY_CLR : c'est l'acquittement, irq_o retombe dans la foulee.
     * On DESARME aussi IRQ_EN au passage. Sans ca, l'attaque qui dure re-leve
     * le collant aussitot et la source de niveau repart : 560 000 entrees dans
     * le gestionnaire mesurees le 2026-09-12. C'est le comportement correct
     * d'un niveau, et c'est precisement ce qui justifie le traitement groupe
     * des notifications decrit au paragraphe 5 du papier -- mais pour
     * chronometrer UNE reaction il faut la borner. Re-arme par l'appelant. */
    unsigned nw = asos_actuate(w, tlc, asos_ctrl_saved & ~WRAP_CTRL_IRQEN);

    asos_t_actuated = read_counter();

    asos_irq_score = sc; asos_irq_k = k; asos_irq_tlc = tlc; asos_irq_nw = nw;
    asos_irq_seen++;
}

static void run_asos_irq(void) {
    volatile uint64_t *w1 = (volatile uint64_t *)WRAP1_BASE_ADDR;
    volatile uint64_t *w2 = (volatile uint64_t *)WRAP2_BASE_ADDR;

    asos_ctrl_saved = w2[WRAP_CTRL_OFF / 8]
                    & ~(WRAP_CTRL_STICKY_CLR | WRAP_CTRL_CNT_CLR);

    printf("\r\n###### ASOS NIVEAU 1 (interruption, VM sous Bao) ######\r\n");

    /* VIDER LE COLLANT AVANT D'ARMER. La campagne vient de laisser
     * sticky = 0x4118 sur le wrapper 2 : armer IRQ_EN sur un collant plein fait
     * monter irq_o immediatement, le gestionnaire s'execute AVANT la boucle et
     * desarme, et les 16 essais suivants tirent a blanc sur un IRQ_EN eteint.
     * Symptome exact observe le 2026-09-12 : ctrl relu 0x331 au diagnostic. */
    w1[WRAP_CTRL_OFF / 8] = asos_ctrl_saved | WRAP_CTRL_STICKY_CLR;
    w2[WRAP_CTRL_OFF / 8] = asos_ctrl_saved | WRAP_CTRL_STICKY_CLR;
    fence();

    /* Arme l'interruption cote materiel, puis verifie que le bitstream la
     * porte : un bit absent du RTL relit zero, et on mesurerait un timeout. */
    w1[WRAP_CTRL_OFF / 8] = asos_ctrl_saved | WRAP_CTRL_IRQEN;
    w2[WRAP_CTRL_OFF / 8] = asos_ctrl_saved | WRAP_CTRL_IRQEN;
    fence();
    if (!(w2[WRAP_CTRL_OFF / 8] & WRAP_CTRL_IRQEN)) {
        printf("# ASOS-IRQ : ATTENTION -- CTRL[11] relit zero, ce bitstream "
               "n'a pas irq_o. Mesure impossible, bloc ignore.\r\n");
        w1[WRAP_CTRL_OFF / 8] = asos_ctrl_saved;
        w2[WRAP_CTRL_OFF / 8] = asos_ctrl_saved;
        return;
    }
    asos_ctrl_saved |= WRAP_CTRL_IRQEN;   /* l'actuation doit la garder armee */

    irq_set_handler(ASOS_IRQ_W1, asos_irq_handler);
    irq_set_handler(ASOS_IRQ_W2, asos_irq_handler);
    irq_set_prio(ASOS_IRQ_W1, 1);
    irq_set_prio(ASOS_IRQ_W2, 1);
    irq_enable(ASOS_IRQ_W1);
    irq_enable(ASOS_IRQ_W2);

    /* Ce que le vPLIC a REELLEMENT retenu de notre configuration. Le guest de
     * ce banc n'avait jamais utilise d'interruption : rien ne garantit que le
     * chemin complet fonctionne, et il faut savoir ou il casse avant d'accuser
     * le RTL. Bao emule ces registres, ces lectures passent donc par lui. */
    {
        extern volatile plic_global_t *plic_global;
        extern volatile plic_hart_t   *plic_hart;
        printf("# ASOS-IRQ-CFG,prio12=%lu,prio13=%lu,enbl0=0x%lx,thresh=%lu\r\n",
               (unsigned long)plic_global->prio[ASOS_IRQ_W1],
               (unsigned long)plic_global->prio[ASOS_IRQ_W2],
               (unsigned long)plic_global->enbl[1][0],
               (unsigned long)plic_hart[1].threshold);
    }

    printf("# ASOS-IRQ-ARM,seen=%u,ctrl_w2=0x%lx,sticky_w2=0x%lx\r\n",
           asos_irq_seen, (unsigned long)w2[WRAP_CTRL_OFF / 8],
           (unsigned long)w2[WRAP_STICKY_OFF / 8]);

    printf("# ASOS-IRQ,essai,k,tlc,ecritures,L_notify,L_proc,L_mmio,L_exit,L_total\r\n");

    unsigned done = 0, timeouts = 0;
    for (unsigned i = 0; i < ASOS_IRQ_TRIALS; i++) {
        /* Part d'un collant vide : sinon irq_o est deja haut et le
         * declenchement ne mesurerait pas une notification. */
        uint64_t ctrl_off = asos_ctrl_saved & ~WRAP_CTRL_IRQEN;
        w2[WRAP_CTRL_OFF / 8] = ctrl_off | WRAP_CTRL_STICKY_CLR;
        w2[WRAP_CTRL_OFF / 8] = ctrl_off;
        fence();

        /* DECLENCHEMENT PAR L'ARMEMENT, ET NON PAR L'ATTAQUE.
         *
         * Premiere version : vider le collant, lancer l'attaque, attendre. Elle
         * ne marche pas, et le journal dit pourquoi -- `sticky = 0x4000` releve
         * juste apres l'effacement. Le bit 14, BAD_ID, est un ECHO D'ETAT et
         * non un evenement : apres SC01 il est re-arme en permanence, le
         * collant se remplit seul, irq_o repart et le gestionnaire se desarme
         * avant meme que la boucle ne commence (`seen=1` avant le premier
         * essai). Aucune sequence logicielle ne produit un evenement propre
         * tant que ce bit compte dans la condition d'interruption.
         *
         * On tire donc parti de cet etat plutot que de le combattre : le
         * collant est deja non nul, il suffit d'ARMER pour faire monter irq_o.
         * `L_notify` mesure alors exactement ce qu'on cherche -- propagation
         * materielle, injection par Bao, et `claim` sur le vPLIC emule -- sans
         * y meler la latence de detection d'ARMOR, qui est deja mesuree par
         * ailleurs (37 cycles, `ARMORLAT`). C'est un meilleur decoupage que
         * celui de la Table 8, pas un repli. */
        uint64_t det = 0, tx = 0;
        (void)fire_one('M', 1 /* usurpation : garnit le collant */, LEGIT_DST,
                       0, &det, &tx);

        unsigned before = asos_irq_seen;
        asos_irq_score  = 0;

        uint64_t t_trigger = read_counter();
        w2[WRAP_CTRL_OFF / 8] = asos_ctrl_saved;   /* arme -> irq_o monte */

        /* Attente bornee de la remontee. */
        uint32_t guard = 2000000;
        while (asos_irq_seen == before && --guard) { }
        uint64_t t_return = read_counter();

        if (!guard) {
            /* Diagnostic : distinguer « aucun evenement » de « evenement mais
             * pas d'interruption ». Sans ca on ne sait pas quoi corriger. */
            if (timeouts == 0) {
                volatile uint32_t *vplic_pending =
                    (volatile uint32_t *)(0x0c000000UL + 0x1000UL);
                printf("# ASOS-IRQ-DIAG,sticky_w2=0x%lx,status_w2=0x%lx,"
                       "ctrl_w2=0x%lx,vplic_pending0=0x%lx,det=%lu\r\n",
                       (unsigned long)w2[WRAP_STICKY_OFF / 8],
                       (unsigned long)w2[WRAP_STATUS_OFF / 8],
                       (unsigned long)w2[WRAP_CTRL_OFF / 8],
                       (unsigned long)vplic_pending[0],
                       (unsigned long)det);
            }
            timeouts++; continue;
        }

        printf("# ASOS-IRQ,%u,%u,TLC-%u,%u,%lu,%lu,%lu,%lu,%lu\r\n",
               i, asos_irq_k, asos_irq_tlc, asos_irq_nw,
               (unsigned long)(asos_t_entry    - t_trigger),
               (unsigned long)(asos_t_assessed - asos_t_entry),
               (unsigned long)(asos_t_actuated - asos_t_assessed),
               (unsigned long)(t_return        - asos_t_actuated),
               (unsigned long)(t_return        - t_trigger));
        done++;
    }

    printf("# ASOS-IRQ : %u reactions mesurees, %u sans remontee\r\n",
           done, timeouts);

    /* Desarme et remet en etat. */
    asos_ctrl_saved &= ~WRAP_CTRL_IRQEN;
    w1[WRAP_ID_CFG_OFF / 8] = 1ULL;
    w2[WRAP_ID_CFG_OFF / 8] = 2ULL;
    w1[WRAP_CTRL_OFF / 8]   = asos_ctrl_saved;
    w2[WRAP_CTRL_OFF / 8]   = asos_ctrl_saved;
    fence();
}
#endif /* BENCH_ASOS_IRQ */

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
    /* 10 scenarios depuis SC10 (balayage memoire), 11 avec SC09 (-DBENCH_SC09).
     * Le tableau est dimensionne au maximum : un depassement ici ecrirait dans
     * la pile de 16 KiB. Toute addition de scenario doit passer par ici. */
#ifdef BENCH_SC09
    static stats_t s[11];
#else
    static stats_t s[10];
#endif
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

    /* SC-10 : balayage memoire, au meme endroit que SC08 et pour la meme
     * raison -- avant tout spoof, sinon il est mesure sur un device banni. */
    run_sc10(&s[n++]);

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

    /* SC-09 : tempête PIPELINÉE — mode 7, HORS CAMPAGNE PAR DÉFAUT.
     *
     * Compiler avec -DBENCH_SC09 pour l'inclure. Il est optionnel pour la même
     * raison que tout le reste ici : il ajoute 50 x 16 transactions avant SC04,
     * et au banc ce décalage suffit à faire basculer SC04-MSI sous aval lent.
     * Une campagne archivée et une campagne avec SC09 ne se comparent pas.
     *
     * CE QU'IL MESURE. Le mode 4 émet ses seize écritures UNE A LA FOIS : son
     * débit au niveau du wrapper est fixé par la vitesse de l'aval, pas par
     * STORM_REQS, et sous latence d'écriture réaliste il tombe sous le seuil —
     * au banc, 2,3 requêtes par fenêtre de 100 cycles pour un seuil de 8, zéro
     * détection. Le mode 7 présente ses seize adresses à la volée avant le
     * premier beat de données, comme le fait tout DMA réel et comme l'annonce
     * la Table 5 du papier. Son débit ne dépend plus de l'aval.
     *
     * L'ATTENDU DÉPEND DE L'ARME, et c'est tout le résultat :
     *   ARMOR_RFMCNT=0 : AUCUN verdict. Seize adresses transférées sur seize
     *                    cycles consécutifs ne font qu'un front de handshake,
     *                    donc UNE requête comptée. La tempête la plus dense que
     *                    cette plateforme sache produire est invisible au
     *                    moniteur historique.
     *   ARMOR_RFMCNT=1 : STORM, y compris sous l'aval lent qui fait passer SC02
     *                    intégralement.
     *
     * EXIGE ARMOR_BFATE=1 (CTRL[10]). Seize AW en vol sans leurs données, c'est
     * la configuration exacte où le canal B décroche : sans B_FATE le banc
     * mesure 488 B en trop, 50 manquants et un AW resté dû en aval — la
     * condition du gel carte. Avec, 128 B appariés et aw_owed = 0. B_FATE était
     * jusqu'ici une correction de robustesse sans gain mesurable ; ce mode est
     * le premier à en avoir besoin.
     *
     * ==========================================================================
     * IL GÈLE LA CARTE. MESURÉ LE 2026-09-13, LES DEUX BRAS.
     *
     * `bench_2026-09-13_090157` (0x1731) et `090714` (0x731) s'arrêtent au MÊME
     * endroit : le `*ctrl = 1` de la PREMIÈRE itération de SC09, après un SC02
     * parfaitement normal (38 et 36 détections sur 50). L'état d'entrée est
     * propre dans les deux cas — `w_owed=0`, `req_cnt=0`, `sticky=0`.
     *
     * Le gel ne dépend donc PAS de CTRL[12] : le bras témoin ne compte qu'un
     * front par salve, ne franchit jamais le seuil, ne coupe rien — et gèle
     * pareil. Ce n'est pas le chemin de coupure d'ARMOR qui est en cause, c'est
     * la forme du trafic elle-même.
     *
     * Hypothèse, NON VÉRIFIÉE : le port de configuration ne traverse pas ARMOR
     * mais il traverse le CROSSBAR. Seize AW en vol saturent l'interconnexion
     * partagée et l'écriture MMIO du CPU reste bloquée derrière. Le banc ne
     * modélise ni l'IOMMU ni le crossbar : il déclarait ce mode propre.
     *
     * Reprise après gel : `pkill -x hw_server` puis `2_build_HB.sh program`.
     * Le chargement JTAG seul NE SUFFIT PAS (capture vide, 0 ligne).
     * ========================================================================== */
#ifdef BENCH_SC04_FIRST
    /* DIAGNOSTIC (-DBENCH_SC04_FIRST) — SC04-MSI JOUE AVANT SC09.
     *
     * La question, et une seule : SC04-MSI gele-t-il SEUL a XFER=64, ou
     * seulement lorsque la tempete pipelinee profonde SC09 l'a precede et a
     * congestionne le crossbar/IOMMU ? Ici SC04 tourne sur un aval NON stresse
     * par mode 7 (SC09 est deplace apres lui) :
     *   SC04 va au bout -> le wedge exige la contention laissee par SC09
     *                      profond : c'est l'interaction ordre/congestion, pas
     *                      SC04 intrinseque ;
     *   SC04 gele        -> le wedge SC04 (block_req MSI -> AW orphelin -> B
     *                      IOMMU non draine) suffit seul a XFER=64, la
     *                      profondeur SC09 n'y est pour rien.
     *
     * CE QUE CET ORDRE DETRUIT : SC04 s'execute avant SC09 au lieu d'apres ;
     * les latences comparatives SC09/SC04 et tout classement dependant de
     * l'ordre ne valent plus. Seule la question du gel a un sens ici — elle ne
     * depend que de l'endroit ou le log s'arrete. Ne rien publier de chiffre
     * issu d'un build portant ce drapeau. */
    printf("# DIAG : SC04 JOUE AVANT SC09 (-DBENCH_SC04_FIRST) — "
           "ordre de campagne modifie, latences comparatives invalides\r\n");
    run_scenario("SC04-MSI",   'M', /*mode*/6, LEGIT_DST, /*cfg*/0, N_ATK, 1, &s[n++]);
#endif
#ifdef BENCH_SC09
    if (BENCH_SC09_DEPTH) {
        *mha_pipe_depth = (uint64_t)BENCH_SC09_DEPTH;
        fence();
        uint64_t relu = *mha_pipe_depth;
        printf("# SC09 : profondeur d'adresses en vol = %d (relu %lu)\r\n",
               BENCH_SC09_DEPTH, (unsigned long)relu);
        /* LE 2026-09-13, CE GARDE-FOU N'EXISTAIT PAS ET IL A COUTE UNE
         * CAMPAGNE. 0x40 relisait 0 parce que reg_pipe_q avait deux pilotes
         * dans le RTL -- Vivado l'avait dit en CRITICAL WARNING, pas en ERROR,
         * et la simulation n'y voyait rien. Le mode 7 tournait donc a sa valeur
         * de synthese, 16, et le gel obtenu ne mesurait rien de neuf.
         *
         * Un registre qui ne relit pas ce qu'on y a ecrit invalide la campagne
         * ENTIERE : on croit balayer une profondeur et on rejoue toujours la
         * meme. */
        if (relu != (uint64_t)BENCH_SC09_DEPTH)
            printf("# ATTENTION : 0x40 relit %lu au lieu de %d -- LA PROFONDEUR "
                   "N'EST PAS CELLE DEMANDEE, cette campagne ne mesure pas ce "
                   "qu'elle annonce\r\n",
                   (unsigned long)relu, BENCH_SC09_DEPTH);
    }
    run_scenario("SC09-PIPE",  'M', /*mode*/7, LEGIT_DST, /*cfg*/0,
                 BENCH_SC09_N ? BENCH_SC09_N : N_ATK,
                 ARMOR_RFMCNT ? 1 : 0, &s[n++]);
#if BENCH_SC09_QUIESCE_CY
    printf("# DIAG : quiescence de %d cycles avant SC04 "
           "(-DBENCH_SC09_QUIESCE_CY)\r\n", BENCH_SC09_QUIESCE_CY);
    wait_cycles((uint64_t)BENCH_SC09_QUIESCE_CY);
#endif
#endif

    /* SC-04 : MSI storm — attendu MSI
     *   Le MSI-monitor voit l'AW avant l'IOMMU, donc la dest configurée
     *   sur le MHA importe peu (le mode 6 redirige vers la zone MSI). On
     *   reste néanmoins sur LEGIT_DST pour homogénéité.
     *   Saute si -DBENCH_SC04_FIRST (SC04 a deja joue avant SC09). */
#ifndef BENCH_SC04_FIRST
    run_scenario("SC04-MSI",   'M', /*mode*/6, LEGIT_DST, /*cfg*/0, N_ATK, 1, &s[n++]);
#endif

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

#ifdef BENCH_ASOS
    run_asos();
#endif
#ifdef BENCH_ASOS_IRQ
    run_asos_irq();
#endif

    printf("\r\n###### RESUME ######\r\n");
    for (int i = 0; i < n; i++) dump(&s[i]);
    printf("###### END ######\r\n");

    /* Fin : on rentre en wfi forever */
    while (1) asm volatile("wfi");
}
