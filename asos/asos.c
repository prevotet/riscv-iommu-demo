#include "asos.h"

uint64_t asos_step(asos_context_t *c, uint64_t now, asos_batch_t *b, int *acted) {
    asos_batch_t local;
    if (!b) b = &local;

    asos_ep_read(c, now, b);                                  /* 1 */
    unsigned pol = asos_su_assess(c, asos_su_batch_weight(b)); /* 3 */
    int act = c->enforce && pol != c->pol;
    if (act) asos_uu_apply(c, pol);                           /* 4 */
    if (acted) *acted = act;
    return b->sticky;
}
