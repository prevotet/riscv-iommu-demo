#include "update_unit.h"
#include "armor_regs.h"

void asos_uu_values(const asos_context_t *c, unsigned pol, asos_regs_t *r) {
    r->ctrl = c->ctrl_ref;
    r->cfgp = c->cfgp_ref;
    r->id   = c->id_own;
    if (pol <= ASOS_POL_THROTTLE)
        r->ctrl = (c->ctrl_ref & ~ARMOR_CTRL_THRESH(0xFF))
                | ARMOR_CTRL_THRESH(pol == ASOS_POL_THROTTLE ? 6 : 4);
    /* A partir de TLC-4, le moniteur de flux compte les TRANSFERTS : c'est ce
     * qui rend visible une tempete pipelinee, que le comptage des fronts ne
     * voit pas. */
    if (pol <= ASOS_POL_TIGHT) {
        r->ctrl |= ARMOR_CTRL_RFMCNT;
        r->cfgp  = ASOS_CFGP_TIGHT;
    }
    if (pol <= ASOS_POL_REVOKED) r->id = ASOS_ID_REVOKED;
}

void asos_uu_apply(asos_context_t *c, unsigned pol) {
    asos_regs_t r;
    asos_uu_values(c, pol, &r);
    ARMOR_REG(c->w, ARMOR_CFG_PARAMS_OFF) = r.cfgp;
    ARMOR_REG(c->w, ARMOR_ID_CFG_OFF)     = r.id;
    ARMOR_REG(c->w, ARMOR_CTRL_OFF)       = r.ctrl;
    ASOS_FENCE();
    c->pol = pol;
    c->changes++;
}

int asos_uu_verify(const asos_context_t *c) {
    asos_regs_t r;
    asos_uu_values(c, c->pol, &r);
    return ARMOR_REG(c->w, ARMOR_CFG_PARAMS_OFF) == r.cfgp
        && ARMOR_REG(c->w, ARMOR_ID_CFG_OFF)     == r.id
        && (ARMOR_REG(c->w, ARMOR_CTRL_OFF) & ~ARMOR_CTRL_PULSES) == r.ctrl;
}

const char *asos_uu_policy_name(unsigned pol) {
    switch (pol) {
    case ASOS_POL_REFERENCE: return "reference";
    case ASOS_POL_THROTTLE:  return "seuil-6";
    case ASOS_POL_TIGHT:     return "CFG-D";
    case ASOS_POL_REVOKED:   return "CFG-D+revoque";
    default:                 return "CFG-D+revoque+BAN";
    }
}
