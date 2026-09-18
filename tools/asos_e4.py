#!/usr/bin/env python3
"""E4 : sensibilite d'ASOS a gamma, aux seuils de la Table 2 et a la periode.

Sur l'hote, avec tools/asos_model.py -- valide sur les 113 journaux ASOS du
18/09 (108 au pas pres jusqu'au ban, 3 fuites des 6 %, 2 bans au meme pas).

Metriques, pour chaque configuration :
  falaise   E2a : plus petit delai D (pas) apres lequel l'evasion DMA passe
            entierement (script de E1 : DMA sain, deux tempetes, attente D,
            30 jobs d'evasion).
  n_ban     E2b : plus grande periode n (pas) a laquelle une tempete tous les
            n pas mene au ban en 200 pas.
  E3        2 000 traces malveillantes tirees comme sur carte : mediane de la
            1re restriction et du ban (pas apres T0), part des evasions
            bloquees, part d'attaquants bannis. Les fuites des 6 % sous TLC-4
            sont tirees au hasard, comme sur carte.
  cout      locataire SAIN, 1 000 pas (30 % DMA, 70 % ecritures) avec une
            FAUSSE ALERTE de poids tempete a chaque pas avec probabilite p.
            HYPOTHESE : le banc a mesure 0 fausse alerte ; p est un parametre,
            pas une mesure. Un DMA sain sous TLC-4 est bloque et leve 45
            (meme motif que l'evasion) : c'est par la que le cout s'emballe.
            Sorties : part des pas resserres, part de DMA sains bloques,
            probabilite d'etre banni.

  fusion    variante REJETEE (TLC-5 fusionne dans TLC-4) : probabilite qu'un
            locataire sain soit banni apres UNE SEULE fausse alerte, selon la
            part de DMA pipeline dans son trafic. C'est la justification du
            palier TLC-5 ; la variante n'existe que dans le modele.

  tools/asos_e4.py [repertoire de sortie]     (defaut : results/e4)
"""
import csv
import os
import random
import statistics as st
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asos_model import Slot, TH, held  # noqa: E402

LEAK = 20 / 331          # evasions passees sous TLC-4, sur carte


def mk(cfg):
    return Slot(hyst=cfg["hyst"], gamma=(cfg["gnum"], 8), th=cfg["th"],
                fusion5=cfg.get("fusion5", False))


def run_ev(s, ev, rng=None):
    """Un pas : alerte du job sous la politique en vigueur, puis equation 3."""
    if held(s, ev):
        s.step(0)
        return "I"
    pol = s.pol
    w = s.alert(ev)
    if rng is not None and ev == "dma" and pol == 4 and w and rng.random() < LEAK:
        w = 0
    s.step(w)
    return "B" if w or (pol <= 3 and ev != "legit") else "D"


def cliff(cfg, dmax=200):
    for d in range(dmax):
        s = mk(cfg)
        for ev in ["dma"] * 20 + (["storm"] + ["legit"] * 9) + ["storm"] + ["legit"] * d:
            run_ev(s, ev)
        blocked = sum(run_ev(s, "dma") != "D" for _ in range(30))
        if blocked == 0:
            return d
    return None


def n_ban(cfg, horizon=200):
    best = None
    for n in range(1, 60):
        s = mk(cfg)
        for k in range(horizon):
            run_ev(s, "storm" if k % n == 0 else "legit")
        if s.banned:
            best = n
    return best


def e3(cfg, ntr=2000, steps=100, seed=1):
    rng = random.Random(seed)
    restr, ban, ev_b, ev_t, nb = [], [], 0, 0, 0
    for _ in range(ntr):
        s = mk(cfg)
        t0 = 10 + rng.randrange(30)
        r = b = None
        for k in range(steps):
            if k < t0:
                ev = "dma" if rng.random() < .3 else "legit"
            elif rng.random() < .3:
                x = rng.random()
                ev = "storm" if x < .4 else ("msi" if x < .6 else "dma")
            else:
                ev = "legit"
            v = run_ev(s, ev, rng)
            if k >= t0 and ev == "dma":
                ev_t += 1
                ev_b += v != "D"
            if r is None and k >= t0 and s.pol < 6:
                r = k - t0
            if b is None and s.banned:
                b = k - t0
        if r is not None:
            restr.append(r)
        if b is not None:
            ban.append(b)
            nb += 1
    return (st.median(restr) if restr else None, st.median(ban) if ban else None,
            ev_b / ev_t, nb / ntr)


def cost(cfg, p, ntr=500, steps=1000, seed=2):
    rng = random.Random(seed)
    tight = dma_b = dma_t = banned = 0
    for _ in range(ntr):
        s = mk(cfg)
        for _k in range(steps):
            ev = "dma" if rng.random() < .3 else "legit"
            fa = rng.random() < p
            if held(s, ev):
                s.step(0)
            else:
                pol = s.pol
                w = s.alert(ev)
                if ev == "dma":
                    dma_t += 1
                    dma_b += bool(w) or pol <= 3
                s.step(w + (45 if fa else 0))
            tight += s.pol < 6
        banned += s.banned
    return tight / (ntr * steps), (dma_b / dma_t if dma_t else 0), banned / ntr


def one_false_alarm(cfg, dma_share, ntr=4000, steps=200, at=10, seed=3):
    rng = random.Random(seed)
    banned = 0
    for _ in range(ntr):
        s = mk(cfg)
        for k in range(steps):
            ev = "dma" if rng.random() < dma_share else "legit"
            if held(s, ev):
                s.step(0)
                continue
            pol = s.pol
            w = s.alert(ev)
            if ev == "dma" and pol == 4 and w and rng.random() < LEAK:
                w = 0
            s.step(w + (45 if k == at else 0))
        banned += s.banned
    return banned / ntr


def evaluate(cfg, ps=(0.001, 0.005, 0.02)):
    c = cliff(cfg)
    n = n_ban(cfg)
    r, b, evb, nb = e3(cfg)
    row = dict(falaise_pas=c, n_ban=n, e3_restr_med=r, e3_ban_med=b,
               e3_evasion_bloquee=round(evb, 3), e3_bannis=round(nb, 3))
    for p in ps:
        t, db, bn = cost(cfg, p)
        row[f"p{p}_resserre"] = round(t, 4)
        row[f"p{p}_dma_bloque"] = round(db, 4)
        row[f"p{p}_banni"] = round(bn, 3)
    return row


def write(path, rows):
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    print(f"-> {path}")
    for r in rows:
        print("  " + " ".join(f"{k}={v}" for k, v in r.items()))


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "results/e4"
    os.makedirs(out, exist_ok=True)

    rows = []
    for g in (0.80, 0.85, 0.898, 0.95, 0.98):
        for hyst in (False, True):
            cfg = dict(gnum=round(g * 256), hyst=hyst, th=TH)
            rows.append(dict(gamma=g, gnum=cfg["gnum"], hyst=int(hyst), **evaluate(cfg)))
    write(os.path.join(out, "e4_gamma.csv"), rows)

    rows = []
    for k in (0.5, 0.75, 1.0, 1.5, 2.0):
        th = [max(1, round(x * k)) for x in TH]
        cfg = dict(gnum=230, hyst=True, th=th)
        rows.append(dict(echelle=k, seuils="/".join(map(str, th)), **evaluate(cfg)))
    write(os.path.join(out, "e4_seuils.csv"), rows)

    # Periode : un pas = T ms. (a) gamma fixe PAR PAS (le firmware) ;
    # (b) gamma fixe PAR SECONDE, gamma_pas = 0,898^(T/20).
    rows = []
    for T in (5, 10, 20, 50, 100):
        for mode in ("par-pas", "par-seconde"):
            g = 0.898 if mode == "par-pas" else 0.898 ** (T / 20)
            cfg = dict(gnum=max(1, round(g * 256)), hyst=True, th=TH)
            c = cliff(cfg)
            rows.append(dict(periode_ms=T, gamma_fixe=mode, gamma_pas=round(g, 4),
                             gnum=cfg["gnum"], falaise_pas=c,
                             falaise_ms=None if c is None else c * T))
    write(os.path.join(out, "e4_periode.csv"), rows)

    rows = []
    for share in (0.0, 0.05, 0.1, 0.3):
        a = one_false_alarm(dict(gnum=230, hyst=True, th=TH), share)
        b = one_false_alarm(dict(gnum=230, hyst=True, th=TH, fusion5=True), share)
        rows.append(dict(part_dma=share, banni_hysteresis=round(a, 3),
                         banni_fusion5_rejetee=round(b, 3)))
    write(os.path.join(out, "e4_fusion5.csv"), rows)


if __name__ == "__main__":
    main()
