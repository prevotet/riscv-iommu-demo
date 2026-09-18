#!/usr/bin/env python3
"""Figure de la trajectoire ASOS (article, §6.4) : donnees tirees d'un journal.

  tools/fig_asos_traj.py <journal TRAJ> <repertoire de sortie>

Ecrit asos_traj.dat (pas, score, politique en vigueur, evenement) et
asos_traj.tex (pgfplots, classe standalone), puis compile asos_traj.pdf.
Journal publie : results/bench_2026-09-18_175403.log (hysteresis, v18 ;
identique octet pour octet a 175416 et 175429).

Politique en vigueur APRES l'evaluation du pas, lue dans les registres
relus du wrapper : 0 reference, 1 TLC-5 (borne 6), 2 TLC-4 (CFG-D +
comptage par transfert), 3 ID revoque (QUARANTINE), 4 ID revoque et BANNED.
"""
import os
import re
import subprocess
import sys

STEP = re.compile(r"^# TRAJ,(\d+),[^,]*,(\w+),(.),0x[0-9a-f]+,(\d+),TLC-(\d+),(\w+),"
                  r"[^,]*,(0x[0-9a-f]+),(0x[0-9a-f]+),(0x[0-9a-f]+),", re.M)


def policy(ctrl, idv, etat):
    ctrl = int(ctrl, 16)
    if idv == "0xffffffff":
        return 4 if etat == "BANNED" else 3
    if ctrl & 0x1000:
        return 2
    if (ctrl >> 16) & 0xFF == 6:
        return 1
    return 0


TEX = r"""\documentclass[border=2pt]{standalone}
\usepackage{pgfplots}
\pgfplotsset{compat=1.17}
\usepgfplotslibrary{groupplots}
% Etats : rampe sequentielle grise, du clair (ACTIVE) au fonce (BANNED).
\definecolor{sActive}{HTML}{F7F7F5}
\definecolor{sLearn}{HTML}{ECECE8}
\definecolor{sSusp}{HTML}{DCDCD6}
\definecolor{sQuar}{HTML}{C6C6BE}
\definecolor{sBan}{HTML}{ADADA3}
% Evenements : palette categorielle validee (3 teintes, toutes paires).
\definecolor{evStorm}{HTML}{2A78D6}
\definecolor{evMsi}{HTML}{EB6834}
\definecolor{evSpoof}{HTML}{1BAF7A}
\definecolor{ink}{HTML}{0B0B0B}
\definecolor{inkSoft}{HTML}{52514E}
\begin{document}
\begin{tikzpicture}
\begin{groupplot}[
  group style={group size=1 by 2, vertical sep=6pt, xlabels at=edge bottom,
               xticklabels at=edge bottom},
  width=15cm, xmin=0, xmax=@XMAX@, axis on top,
  tick label style={font=\footnotesize, text=inkSoft},
  label style={font=\footnotesize, text=ink},
  axis line style={inkSoft}, tick style={inkSoft},
  xtick distance=10, minor x tick num=1,
]
\nextgroupplot[height=4.4cm, ymin=0, ymax=@YMAX@, ylabel={Threat score},
  ytick={0,16,36,71,86,100}, clip=false, restrict y to domain=0:@YMAX@]
  \fill[sActive] (axis cs:0,0)   rectangle (axis cs:@XMAX@,16);
  \fill[sLearn]  (axis cs:0,16)  rectangle (axis cs:@XMAX@,36);
  \fill[sSusp]   (axis cs:0,36)  rectangle (axis cs:@XMAX@,71);
  \fill[sQuar]   (axis cs:0,71)  rectangle (axis cs:@XMAX@,86);
  \fill[sBan]    (axis cs:0,86)  rectangle (axis cs:@XMAX@,@YMAX@);
  \node[anchor=west, font=\scriptsize, text=inkSoft] at (axis cs:@XMAX@,8) {\,ACTIVE};
  \node[anchor=west, font=\scriptsize, text=inkSoft] at (axis cs:@XMAX@,26) {\,LEARNING};
  \node[anchor=west, font=\scriptsize, text=inkSoft] at (axis cs:@XMAX@,53.5) {\,SUSPICIOUS};
  \node[anchor=west, font=\scriptsize, text=inkSoft] at (axis cs:@XMAX@,78.5) {\,QUARANTINE};
  \node[anchor=west, font=\scriptsize, text=inkSoft] at (axis cs:@XMAX@,108) {\,BANNED};
  \begin{scope}
    \clip (axis cs:0,0) rectangle (axis cs:@XMAX@,@YMAX@);
    \addplot[const plot mark left, ink, line width=1pt] table[x=step, y=score] {asos_traj.dat};
  \end{scope}
  \draw[inkSoft, -{latex}] (axis cs:@PEAKX@,@YMAX@) ++(0,8pt) node[above, font=\scriptsize, text=ink] {peak @PEAK@} -- ++(0,-6pt);
  \addplot[only marks, mark=triangle*, mark size=3pt, evStorm, draw=white,
           line width=0.6pt] table[x=step, y=score, restrict expr to domain={\thisrow{ev}}{1:1}] {asos_traj.dat};
  \addplot[only marks, mark=diamond*, mark size=3.4pt, evMsi, draw=white,
           line width=0.6pt] table[x=step, y=score, restrict expr to domain={\thisrow{ev}}{2:2}] {asos_traj.dat};
  \addplot[only marks, mark=square*, mark size=2.4pt, evSpoof, draw=white,
           line width=0.6pt] table[x=step, y=score, restrict expr to domain={\thisrow{ev}}{3:3}] {asos_traj.dat};
@LABELS@
\nextgroupplot[height=2.6cm, ymin=-0.5, ymax=4.5, xlabel={Step (20\,ms each)},
  ytick={0,1,2,3,4},
  yticklabels={Reference, TLC-5, TLC-4, ID revoked, Banned},
  ylabel={Policy}, axis on top=false, ymajorgrids, grid style={inkSoft!20}]
  \addplot[const plot mark left, ink, line width=1pt] table[x=step, y=pol] {asos_traj.dat};
\end{groupplot}
\end{tikzpicture}
\end{document}
"""


def main():
    log, out = sys.argv[1], sys.argv[2]
    txt = open(log, "rb").read().replace(b"\0", b"").decode("ascii", "replace")
    rows = STEP.findall(txt)
    code = {"legit": 0, "storm": 1, "msi": 2, "spoof": 3}
    lines = ["step score pol ev"]
    first = {}
    for st, ev, v, score, tlc, etat, ctrl, cfg, idv in rows:
        lines.append(f"{st} {score} {policy(ctrl, idv, etat)} {code[ev]}")
        if ev != "legit":
            first.setdefault(ev, (int(st), int(score)))
    os.makedirs(out, exist_ok=True)
    open(os.path.join(out, "asos_traj.dat"), "w").write("\n".join(lines) + "\n")
    xmax = int(rows[-1][0]) + 1
    names = {"storm": "storms", "msi": "MSI flood", "spoof": "spoofing"}
    colors = {"storm": "evStorm", "msi": "evMsi", "spoof": "evSpoof"}
    labels = []
    for ev, (st, sc) in first.items():
        anchor = "south"
        if ev == "spoof":             # les deux premiers echecs ne levent rien
            st, sc = next((int(r[0]), int(r[3])) for r in rows
                          if r[1] == "spoof" and int(r[3]) > 0)
            anchor = "east"
        labels.append(rf"  \node[anchor={anchor}, font=\scriptsize, text=ink, "
                      rf"inner sep=4pt] at (axis cs:{st},{sc}) {{{names[ev]}}};")
    peak = max((int(r[3]), int(r[0])) for r in rows)
    tex = (TEX.replace("@XMAX@", str(xmax)).replace("@YMAX@", "130")
              .replace("@PEAKX@", str(peak[1])).replace("@PEAK@", str(peak[0]))
              .replace("@LABELS@", "\n".join(labels)))
    open(os.path.join(out, "asos_traj.tex"), "w").write(tex)
    subprocess.run(["pdflatex", "-interaction=nonstopmode", "asos_traj.tex"],
                   cwd=out, check=True, stdout=subprocess.DEVNULL)
    print(f"{len(rows)} pas -> {out}/asos_traj.pdf ; premiers evenements : {first}")


if __name__ == "__main__":
    main()
