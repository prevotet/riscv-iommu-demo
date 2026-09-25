#include "event_processing.h"
#include "armor_regs.h"

static const struct { uint64_t bit; asos_event_kind_t kind; } ep_map[] = {
    { ARMOR_ALERT_BANNED,  ASOS_EV_SPOOF   },
    { ARMOR_ALERT_OUTS,    ASOS_EV_OUTS    },
    { ARMOR_ALERT_BLOCKED, ASOS_EV_BLOCKED },
    { ARMOR_ALERT_STORM,   ASOS_EV_STORM   },
    { ARMOR_ALERT_MSI,     ASOS_EV_MSI     },
};
#define EP_NMAP (sizeof(ep_map) / sizeof(ep_map[0]))

static const char *const ep_names[ASOS_EV_COUNT] = {
    "SPOOF", "OUTS", "BLOCKED", "STORM", "MSI", "OUT_OF_SET",
};

const char *asos_ep_name(asos_event_kind_t k) {
    return (unsigned)k < ASOS_EV_COUNT ? ep_names[k] : "?";
}

static void ep_push(asos_batch_t *b, unsigned slot, asos_event_kind_t k, uint64_t now) {
    b->ev[b->n].slot      = slot;
    b->ev[b->n].kind      = k;
    b->ev[b->n].timestamp = now;
    b->n++;
}

void asos_ep_decode(unsigned slot, uint64_t sticky, uint64_t now, asos_batch_t *b) {
    b->sticky    = sticky;
    b->span_read = 0;
    b->amin = b->amax = 0;
    b->n = 0;
    for (unsigned i = 0; i < EP_NMAP; i++)
        if (sticky & ep_map[i].bit) ep_push(b, slot, ep_map[i].kind, now);
}

void asos_ep_read(const asos_context_t *c, uint64_t now, asos_batch_t *b) {
    volatile uint64_t *w = c->w;

    /* Lecture puis acquittement : l'impulsion STICKY_CLR est ecrite sur le CTRL
     * courant, impulsions retirees, pour ne rien changer d'autre. */
    uint64_t st   = ARMOR_REG(w, ARMOR_STICKY_OFF);
    uint64_t ctrl = ARMOR_REG(w, ARMOR_CTRL_OFF) & ~ARMOR_CTRL_PULSES;
    ARMOR_REG(w, ARMOR_CTRL_OFF) = ctrl | ARMOR_CTRL_STICKY_CLR;
    ASOS_FENCE();

    asos_ep_decode(c->slot, st, now, b);

    /* Etendue d'adresses : lue seulement si un working set est declare, pour ne
     * rien ajouter aux acces d'un slot qui n'en a pas. amin = 0xFFFFFFFF
     * signale qu'aucune requete n'a ete vue. L'etendue n'est pas remise a zero
     * par l'acquittement : une sortie du working set est donc signalee a chaque
     * evaluation jusqu'a la remise a zero des compteurs du wrapper. */
    if (c->wset_valid) {
        uint64_t spn = ARMOR_REG(w, ARMOR_ADDR_SPAN_OFF);
        b->amin = (uint32_t)(spn & 0xFFFFFFFFULL);
        b->amax = (uint32_t)(spn >> 32);
        b->span_read = 1;
        if (b->amin != 0xFFFFFFFFu && (b->amin < c->wset.lo || b->amax > c->wset.hi))
            ep_push(b, c->slot, ASOS_EV_OUT_OF_SET, now);
    }
}
