#!/usr/bin/env python3
"""Calibration automatique des bornes : agrege les campagnes -DBENCH_ASOS_CALIB.

  tools/calib_bornes.py results/bench_*.log
  tools/calib_bornes.py --tex results/bench_*.log

Un bras = (arm, mix, depth). `arm=0` garde les bornes de synthese, `arm=1`
applique celles que la phase d'apprentissage a derivees. Les campagnes d'un
meme bras sont sommees ; une valeur qui varie d'une campagne a l'autre est
donnee en intervalle, pas en moyenne.

CE QUE CHAQUE COLONNE VEUT DIRE
-------------------------------
  pic          plus forte occupation de fenetre / profondeur d'en-vol vues
               pendant l'apprentissage, lues dans le wrapper (CNT_STORM[39:32],
               CNT_OUTS[39:32]). Elles ne valent que si AUCUN verdict n'est
               tombe : une fois le seuil franchi, request_manager coupe et le
               compteur cesse de monter. D'ou `refus=` : apprentissage avec
               collant non vide = calibration refusee.
  borne        ce qui est ECRIT et RELU dans CTRL[23:16] et CFG_PARAMS[23:16].
  legit        jobs legitimes termines sans erreur, par forme. C'est la mesure
               des faux positifs de la calibration.
  abouties     attaques terminees sans erreur. Zero dans les deux bras : ce
               n'est PAS la ou se voit l'apport de la calibration.
  verdicts     storm= et outs= du wrapper. C'est LA colonne : elle dit quel
               moniteur a tranche, et c'est le seul endroit ou les deux bras
               different.
"""
import re
import sys

CHAMPS = ("arm", "mix", "refus", "applique", "thr", "outs", "pic_req", "pic_outs")


def load(path):
    txt = open(path, "rb").read().replace(b"\0", b"").decode("utf-8", "replace")
    return txt.replace("\r", "")


def fin(txt):
    m = re.search(r"^# CALIB-FIN,([^\n]*)", txt, re.M)
    if not m:
        return None
    d = dict(re.findall(r"(\w+)=([\w/]+)", m.group(1)))
    return d


def entete(txt):
    m = re.search(r"^# CALIB : learn=(\d+) mix=(\d+) marge=(\d+) check=(\d+) "
                  r"attack=(\d+) depth=(\d+)", txt, re.M)
    return m.groups() if m else None


def attaques(txt):
    out = {}
    for m in re.finditer(r"^# CALIB-C,attaque,(\w+),(\d+),(\d+),collant=\S+,"
                         r"storm=(\d+),outs=(\d+)", txt, re.M):
        nom, n, ok, stm, ou = m.groups()
        out[nom] = (int(n), int(ok), int(stm), int(ou))
    return out


def legits(txt):
    out = {}
    for m in re.finditer(r"^# CALIB-C,legit,(\w+),(\d+),(\d+),", txt, re.M):
        nom, n, ok = m.groups()
        out[nom] = (int(n), int(ok))
    return out


def plage(vals):
    return f"{vals[0]}" if len(set(vals)) == 1 else f"{min(vals)}-{max(vals)}"


def main(argv):
    tex = "--tex" in argv
    paths = [a for a in argv if not a.startswith("--")]
    if not paths:
        print(__doc__)
        return 1

    bras = {}
    for p in paths:
        txt = load(p)
        f = fin(txt)
        if f is None:
            continue
        e = entete(txt)
        depth = e[5] if e else "?"
        cle = (f["arm"], f["mix"], depth)
        bras.setdefault(cle, []).append((f, legits(txt), attaques(txt)))

    if not bras:
        print("# Aucune campagne CALIB dans ces journaux.")
        return 2

    print(f"# Calibration des bornes — {len(bras)} bras, "
          f"{sum(len(v) for v in bras.values())} campagnes")
    print("#")
    print(f"{'bras':<22} {'n':>2} {'pic req/vol':>12} {'bornes':>9} "
          f"{'legit copie':>12} {'legit dma':>10} "
          f"{'tempete st/ou':>14} {'en-vol st/ou':>14}")

    lignes = []
    for cle in sorted(bras):
        arm, mix, depth = cle
        camps = bras[cle]
        f0 = camps[0][0]
        if any(c[0]["refus"] != "0" for c in camps):
            print(f"#   bras arm={arm} mix={mix} : au moins une campagne REFUSEE "
                  f"(verdict pendant l'apprentissage)")
        nom = f"arm={arm} mix={mix} d={depth}"
        pic = f"{plage([int(c[0]['pic_req']) for c in camps])}/" \
              f"{plage([int(c[0]['pic_outs']) for c in camps])}"
        bor = f"{plage([int(c[0]['thr']) for c in camps])}/" \
              f"{plage([int(c[0]['outs']) for c in camps])}"
        lc = sum(c[1].get("copie", (0, 0))[1] for c in camps)
        lcn = sum(c[1].get("copie", (0, 0))[0] for c in camps)
        ld = sum(c[1].get("dma_pipeline", (0, 0))[1] for c in camps)
        ldn = sum(c[1].get("dma_pipeline", (0, 0))[0] for c in camps)
        tm = [c[2].get("tempete", (0, 0, 0, 0)) for c in camps]
        ev = [c[2].get("en_vol", (0, 0, 0, 0)) for c in camps]
        tmt = f"{plage([t[2] for t in tm])}/{plage([t[3] for t in tm])}"
        evt = f"{plage([t[2] for t in ev])}/{plage([t[3] for t in ev])}"
        abouti = sum(t[1] for t in tm) + sum(t[1] for t in ev)
        print(f"{nom:<22} {len(camps):>2} {pic:>12} {bor:>9} "
              f"{str(lc)+'/'+str(lcn):>12} {str(ld)+'/'+str(ldn):>10} "
              f"{tmt:>14} {evt:>14}")
        lignes.append((arm, mix, depth, bor, lc, lcn, ld, ldn, tmt, evt, abouti))

    tot_abouti = sum(l[10] for l in lignes)
    print("#")
    print(f"# Attaques abouties, tous bras confondus : {tot_abouti}. "
          f"La calibration ne change pas CELA.")
    print("# Ce qu'elle change est le moniteur qui tranche : lire la colonne")
    print("# « en-vol st/ou », ou le second chiffre passe de 0 a 50 sur 50.")

    if tex:
        print("\n" + "=" * 72)
        print(r"""\begin{table}[t]
\caption{\add{Bounds derived by the supervisor from 40 legitimate jobs, against
the bounds fixed at synthesis. The peak occupancy and in-flight depth are read
from the wrapper during the learning phase; each bound is set to that peak plus
two. \emph{Verdicts} counts, per 50 attacks, the decisions of the request-rate
monitor and of the in-flight monitor.}}
\label{tbl:VRAI_LABEL}
\begin{tabular*}{\tblwidth}{@{}LRRRRR@{}}
\toprule
 & \multicolumn{2}{c}{Bounds} & \multicolumn{2}{c}{Legitimate} & In-flight \\
Configuration & rate & in flight & copy & pipelined & verdicts \\
\midrule""")
        for (arm, mix, depth, bor, lc, lcn, ld, ldn, tmt, evt, _) in lignes:
            thr, outs = bor.split("/")
            nom = "Synthesis" if arm == "0" else "Calibrated"
            ouv = evt.split("/")[1]
            print(f"{nom} & {thr} & {outs} & {lc}/{lcn} & {ld}/{ldn} & {ouv}/50 \\\\")
        print(r"""\bottomrule
\end{tabular*}
\end{table}""")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
