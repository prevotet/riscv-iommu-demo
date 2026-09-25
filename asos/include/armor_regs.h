/* Registres d'un wrapper ARMOR utilises par ASOS : sous-ensemble de la carte du
 * v18 (armor/SRC/wrapper.sv). Chaque wrapper expose ses registres en mots de
 * 64 bits a partir de sa base. */
#ifndef ARMOR_REGS_H
#define ARMOR_REGS_H

#include <stdint.h>

#define ARMOR_ID_CFG_OFF        (0x00ULL)   /* Device ID autorise du slot       */
#define ARMOR_CTRL_OFF          (0x10ULL)
#define ARMOR_STATUS_OFF        (0x18ULL)
#define ARMOR_STICKY_OFF        (0x20ULL)   /* alertes cumulees depuis l'acquit */
#define ARMOR_MAGIC_OFF         (0x58ULL)
#define ARMOR_ADDR_SPAN_OFF     (0x100ULL)  /* v17 : [31:0] min, [63:32] max    */
#define ARMOR_CFG_PARAMS_OFF    (0x110ULL)  /* v18 : fenetre / en-vol / echecs  */

#define ARMOR_REG(w, off)       ((w)[(off) / 8])

/* CTRL */
#define ARMOR_CTRL_ENFORCE      (1ULL << 0)
#define ARMOR_CTRL_STICKY_CLR   (1ULL << 1)   /* impulsion : vide STICKY        */
#define ARMOR_CTRL_CNT_CLR      (1ULL << 2)   /* impulsion : vide les compteurs */
#define ARMOR_CTRL_RFMCNT       (1ULL << 12)  /* moniteur de flux : transferts  */
#define ARMOR_CTRL_THRESH(n)    (((uint64_t)(n) & 0xFFULL) << 16)
#define ARMOR_CTRL_THRESH_GET(v) ((unsigned)(((v) >> 16) & 0xFFULL))
#define ARMOR_CTRL_PULSES       (ARMOR_CTRL_STICKY_CLR | ARMOR_CTRL_CNT_CLR)

/* CFG_PARAMS : [15:0] fenetre de flux, [23:16] borne d'en-vol, [31:24] echecs
 * consecutifs avant blocage. ZERO par champ = valeur de synthese. */
#define ARMOR_CFGP(win, outs, fails) \
    ((((uint64_t)(fails) & 0xFFULL) << 24) | (((uint64_t)(outs) & 0xFFULL) << 16) | \
     ((uint64_t)(win) & 0xFFFFULL))
#define ARMOR_CFGP_OUTS_GET(v)  ((unsigned)(((v) >> 16) & 0xFFULL))
#define ARMOR_CFGP_OUTS_MASK    (0xFFULL << 16)

/* Valeurs de synthese, que designe un champ a zero */
#define ARMOR_SYNTH_THRESH      8u
#define ARMOR_SYNTH_OUTS        16u

/* Bits d'alerte de STICKY (memes positions dans STATUS) */
#define ARMOR_ALERT_BLOCKED     (1ULL << 3)   /* blocage effectif, tout verdict */
#define ARMOR_ALERT_BANNED      (1ULL << 4)   /* usurpation d'identite tranchee */
#define ARMOR_ALERT_STORM       (1ULL << 5)
#define ARMOR_ALERT_OUTS        (1ULL << 6)
#define ARMOR_ALERT_MSI         (1ULL << 7)

#define ARMOR_MAGIC_VERSION(m)  ((unsigned)((m) & 0xFFULL))

#endif
