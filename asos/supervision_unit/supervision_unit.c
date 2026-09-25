#include "supervision_unit.h"

/* Poids de severite. Un blocage effectif (BLOCKED) accompagne tout verdict
 * applique : une tempete contenue pese donc 20 + 25 = 45, une usurpation
 * tranchee 40 + 25 = 65. Une sortie du working set pese comme une usurpation. */
static const unsigned su_weight[ASOS_EV_COUNT] = {
    [ASOS_EV_SPOOF]      = 40,
    [ASOS_EV_OUTS]       = 30,
    [ASOS_EV_BLOCKED]    = 25,
    [ASOS_EV_STORM]      = 20,
    [ASOS_EV_MSI]        = 15,
    [ASOS_EV_OUT_OF_SET] = 40,
};

/* Neuf seuils, dix classes : TLC-10 sous 1, TLC-1 a partir de 100. */
static const uint64_t su_th[9] = { 1, 6, 16, 26, 36, 51, 71, 86, 100 };

unsigned asos_su_weight(asos_event_kind_t k) {
    return (unsigned)k < ASOS_EV_COUNT ? su_weight[k] : 0;
}

unsigned asos_su_batch_weight(const asos_batch_t *b) {
    unsigned wsum = 0;
    for (unsigned i = 0; i < b->n; i++) wsum += asos_su_weight(b->ev[i].kind);
    return wsum;
}

unsigned asos_tlc(uint64_t score) {
    unsigned tlc = 10;
    for (unsigned i = 0; i < 9; i++) if (score >= su_th[i]) tlc = 9 - i;
    return tlc;
}

const char *asos_state(unsigned tlc) {
    if (tlc >= 8) return "ACTIVE";
    if (tlc >= 6) return "LEARNING";
    if (tlc >= 4) return "SUSPICIOUS";
    if (tlc == 3) return "QUARANTINE";
    return "BANNED";
}

unsigned asos_su_assess(asos_context_t *c, unsigned weight) {
    uint64_t sc = ((c->score * ASOS_GAMMA_NUM) >> ASOS_GAMMA_SH) + weight;
    c->score = sc;
    if (sc > c->score_max) c->score_max = sc;

    unsigned tlc = asos_tlc(sc);
    if (c->banned && tlc > c->tlc) tlc = c->tlc;   /* BANNED ne se leve pas */
    if (tlc <= 2) c->banned = 1;
    c->tlc = tlc;

    unsigned pol = c->banned ? ASOS_POL_BANNED
                             : (tlc >= 6 ? ASOS_POL_REFERENCE : tlc);
    /* Hysteresis : resserrer des l'entree dans une classe, ne relacher qu'au
     * retour a ACTIVE. La memoire est proportionnelle a la gravite, sans
     * parametre de plus que les seuils de classe. */
    if (c->hyst && pol > c->pol && tlc < 8) pol = c->pol;
    return pol;
}
