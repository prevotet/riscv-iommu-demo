#include "security_context.h"
#include "armor_regs.h"

void asos_sc_create(asos_context_t *c, unsigned slot, volatile uint64_t *w,
                    uint64_t id_own, const asos_sc_opts_t *o) {
    c->in_use     = 1;
    c->slot       = slot;
    c->w          = w;
    c->id_own     = id_own;
    c->ctrl_ref   = ARMOR_REG(w, ARMOR_CTRL_OFF) & ~ARMOR_CTRL_PULSES;
    c->cfgp_ref   = ARMOR_REG(w, ARMOR_CFG_PARAMS_OFF);
    c->wset_valid = o ? o->wset_valid : 0;
    c->wset.lo    = o ? o->wset.lo : 0;
    c->wset.hi    = o ? o->wset.hi : 0;
    c->hyst       = o ? o->hyst : 0;
    c->enforce    = o ? o->enforce : 1;
    c->score      = 0;
    c->score_max  = 0;
    c->tlc        = 10;
    c->banned     = 0;
    c->pol        = ASOS_POL_REFERENCE;
    c->changes    = 0;
}

void asos_sc_delete(asos_context_t *c) {
    c->in_use     = 0;
    c->w          = 0;
    c->id_own     = 0;
    c->wset_valid = 0;
    c->score      = 0;
    c->score_max  = 0;
    c->tlc        = 10;
    c->banned     = 0;
    c->pol        = ASOS_POL_REFERENCE;
    c->changes    = 0;
}

unsigned asos_sc_bound(unsigned peak, unsigned margin, unsigned floor, unsigned ref) {
    unsigned b = peak + margin;
    if (b < floor) b = floor;
    if (b > ref)   b = ref;
    return b;
}

int asos_sc_calibrate(asos_context_t *c, unsigned peak_req, unsigned peak_outs,
                      unsigned margin, uint64_t sticky) {
    if (sticky != 0) return 0;

    /* ZERO = valeur de synthese : sans cette conversion, la regle « ne jamais
     * relacher » comparerait a 0 et toute borne passerait pour un relachement. */
    unsigned thr_ref  = ARMOR_CTRL_THRESH_GET(c->ctrl_ref);
    unsigned outs_ref = ARMOR_CFGP_OUTS_GET(c->cfgp_ref);
    if (thr_ref  == 0) thr_ref  = ARMOR_SYNTH_THRESH;
    if (outs_ref == 0) outs_ref = ARMOR_SYNTH_OUTS;

    unsigned thr  = asos_sc_bound(peak_req,  margin, ASOS_SC_CAL_FLOOR, thr_ref);
    unsigned outs = asos_sc_bound(peak_outs, margin, ASOS_SC_CAL_FLOOR, outs_ref);

    c->ctrl_ref = (c->ctrl_ref & ~ARMOR_CTRL_THRESH(0xFF)) | ARMOR_CTRL_THRESH(thr);
    c->cfgp_ref = (c->cfgp_ref & ~ARMOR_CFGP_OUTS_MASK) | ((uint64_t)outs << 16);
    return 1;
}
