#!/usr/bin/env python3
"""Modele hote d'ASOS, transcription de bench_runner.c (traj_eval / traj_apply).

Meme arithmetique entiere (gamma = 230/256 par pas), meme Table 2, meme
hysteresis (ASOS_HYST), meme verrou BANNED. Ce que le materiel apporte est
ramene a des poids MESURES sur carte le 18/09 :

  tempete contenue          STORM + BLOCKED            45
  rafale MSI                MSI + STORM + BLOCKED      60   (collant 0xaa8)
      sous TLC-4 (8 en vol)   + OUTS                     90   (3 fois sur 5 ;
                                                       75 et 60 une fois)
  echec d'identite tranche  BANNED + BLOCKED           65
  evasion DMA (profondeur 4) : 45 si la politique en vigueur compte les
      transferts au seuil 4 (TLC <= 4), 0 sinon -- seuils 5, 6, 8 : 0/50.
      Sous TLC-4, 6 % des jobs passent quand meme (20/331 sur carte) : le
      modele les tient pour bloques.

Usurpation : le compteur d'echecs tranche au 3e echec sous la reference,
au 2e sous CFG-D, et ne redescend jamais.

ID REVOQUE (QUARANTINE, BANNED) -- releve sur 114 journaux, bits du collant :
tempete 65 (BANNED + BLOCKED, le bit STORM disparait), MSI 80 (+ MSI),
usurpation 65 ; un job DMA vaut 0 au premier pas revoque, 65 ensuite. Le
trafic legitime est tenu a l'arret. Residu NON modele : un job bloque laisse
parfois ses bits au pas suivant (244 pas tenus sur 1 457 portent 0x18).
Sans effet sur la decision : il ne survient qu'apres revocation, et le
modele est valide jusqu'au ban inclus (voir `valide`).

Usage :
  tools/asos_model.py valide results/*.log   # rejoue chaque journal, compare
"""
import re
import sys

GAMMA_NUM, GAMMA_SH = 230, 8
TH = [1, 6, 16, 26, 36, 51, 71, 86, 100]          # Table 2
W_STORM, W_MSI, W_FAIL, W_EVASION = 45, 60, 65, 45


def tlc_of(score, th=TH):
    t = 10
    for i, x in enumerate(th):
        if score >= x:
            t = 9 - i
    return t


def state_of(t):
    if t >= 8:
        return "ACTIVE"
    if t >= 6:
        return "LEARNING"
    if t >= 4:
        return "SUSPICIOUS"
    return "QUARANTINE" if t == 3 else "BANNED"


class Slot:
    """Un slot ASOS. `pol` : 6 reference, 5 seuil 6, 4 CFG-D + RFMCNT,
    3 + ID revoque, 2 + BAN (verrouille)."""

    def __init__(self, hyst=True, gamma=(GAMMA_NUM, GAMMA_SH), th=TH,
                 adaptive=True, fusion5=False):
        self.hyst, self.gamma, self.th, self.adaptive = hyst, gamma, th, adaptive
        self.fusion5 = fusion5
        self.score, self.tlc, self.pol, self.banned = 0, 10, 6, False
        self.fails = 0
        self.rev_jobs = 0

    # --- ce que le wrapper leve pour un job, sous la politique en vigueur ---
    def alert(self, ev):
        if ev == "legit":
            return 0
        if self.pol <= 3:                          # ID revoque
            self.rev_jobs += 1
            if ev == "msi":
                return 80
            if ev == "dma" and self.rev_jobs == 1:
                return 0
            return W_FAIL
        if ev == "spoof":
            self.fails += 1
            return W_FAIL if self.fails >= (2 if self.pol <= 4 else 3) else 0
        if ev == "storm":
            return W_STORM
        if ev == "msi":        # sous CFG-D (8 en vol), la rafale leve aussi OUTS
            return 90 if self.pol <= 4 else W_MSI
        if ev == "dma":        # evasion : visible au seuil 4 + RFMCNT seulement
            return W_EVASION if self.pol <= 4 else 0
        raise ValueError(ev)

    # --- un pas de l'equation 3 ---
    def step(self, w):
        num, sh = self.gamma
        sc = (self.score * num) >> sh
        sc += w
        self.score = sc
        t = tlc_of(sc, self.th)
        if self.banned and t > self.tlc:
            t = self.tlc
        if t <= 2:
            self.banned = True
        self.tlc = t
        pol = 2 if self.banned else (6 if t >= 6 else t)
        if self.fusion5 and pol == 5:     # variante REJETEE le 18/09, analyse seule
            pol = 4
        if self.hyst and pol > self.pol and t < 8:
            pol = self.pol
        acted = self.adaptive and pol != self.pol
        if acted:
            self.pol = pol
        return acted


def held(slot, ev):
    """Le trafic LEGITIME d'un slot revoque n'est pas emis (verdict I)."""
    return ev == "legit" and slot.pol <= 3


# ----------------------------------------------------------------------------
# Validation contre les journaux de carte
# ----------------------------------------------------------------------------
STEP_RE = re.compile(r"^# TRAJ,(\d+),[^,]*,(\w+),(.),0x[0-9a-f]+,(\d+),TLC-(\d+),(\w+),", re.M)


def replay(path):
    txt = open(path, "rb").read().replace(b"\0", b"").decode("ascii", "replace")
    m = re.search(r"hysteresis=(\d)", txt)
    hyst = bool(int(m.group(1))) if m else False
    f5 = re.search(r"fusion5=(\d)", txt)
    fusion5 = bool(int(f5.group(1))) if f5 else False
    arm = re.search(r"bras ([\w-]+)", txt)
    adaptive = not arm or arm.group(1) == "ASOS"
    s = Slot(hyst=hyst, adaptive=adaptive, fusion5=fusion5)
    if arm and arm.group(1) == "stricte-fixe":
        s.pol = 4
    steps = STEP_RE.findall(txt)
    if not steps:
        return None
    diffs = []
    banned_card = False
    for st, ev, v, score, tlc, etat in steps:
        pol_before = s.pol
        w = 0 if held(s, ev) else s.alert(ev)
        s.step(w)
        carte = (int(score), int(tlc), etat)
        hote = (s.score, s.tlc, state_of(s.tlc))
        if banned_card:                      # apres le ban : l'etat seul
            if etat != "BANNED" or not s.banned:
                diffs.append((int(st), ev, carte, hote, "etat"))
        elif carte != hote:
            # evasion passee sous TLC-4 : le hasard des 6 %, pas le modele
            if ev == "dma" and pol_before == 4 and v == "D":
                kind = "fuite"
            elif etat == state_of(s.tlc) == "BANNED" and not banned_card:
                kind = "meme-decision"        # poids MSI disperse, ban au meme pas
            else:
                kind = "ecart"
            diffs.append((int(st), ev, carte, hote, kind))
            break                            # la suite en decoule
        banned_card = banned_card or etat == "BANNED"
    return len(steps), diffs, hyst, adaptive


def main():
    if len(sys.argv) < 3 or sys.argv[1] != "valide":
        print(__doc__)
        return 1
    ok = bad = fuite = same = 0
    for p in sys.argv[2:]:
        r = replay(p)
        if r is None:
            continue
        n, diffs, hyst, adaptive = r
        tag = f"hyst={int(hyst)} {'ASOS' if adaptive else 'fixe'}"
        if diffs and diffs[0][4] == "fuite":
            fuite += 1
            st = diffs[0][0]
            print(f"FUITE {p} ({tag}) : evasion passee sous TLC-4 au pas {st}, "
                  f"trajectoire exacte jusque-la")
        elif diffs and diffs[0][4] == "meme-decision":
            same += 1
            st, ev, carte, hote, kind = diffs[0]
            print(f"MEME DECISION {p} ({tag}) : ban au meme pas {st}, score "
                  f"carte={carte[0]} hote={hote[0]} ({ev})")
        elif diffs:
            bad += 1
            st, ev, carte, hote, kind = diffs[0]
            print(f"ECART {p} ({tag}) : {kind} au pas {st} ({ev}) "
                  f"carte={carte} hote={hote}")
        else:
            ok += 1
    print(f"{ok} journaux reproduits jusqu'au ban inclus (puis BANNED tenu), "
          f"{fuite} fuites des 6 %, {same} ban au meme pas (score MSI disperse), "
          f"{bad} en ecart")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
