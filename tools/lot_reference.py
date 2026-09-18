#!/usr/bin/env python3
"""Toutes les valeurs de l'article tirees d'UN lot de campagnes de reference.

  tools/lot_reference.py results/bench_A.log results/bench_B.log ...
  tools/lot_reference.py --csv results/mesures_2026-09-15_v18.csv REF REF2

Ecrit en clair, pour chaque valeur, le tableau de l'article qui la porte :
Table 7 (detection), Table 8 (latence mesuree par le wrapper), Table 11
(ligne 16, borne de synthese), Table 12 (occupation, fenetres, etendue),
§6.2/6.3.3 (aller-retour), et la borne de la regle de trois.

Correspondance des noms (firmware -> article) :
  SC01-SPOOF  -> SC-01   usurpation              SC06-LHAOK -> SC-06 benin
  SC02-STORM  -> SC-02   tempete                 SC07-MHAOK -> SC-07 benin
  SC03-OUTS   -> SC-03   epuisement d'en-vol     SC08-LAS   -> SC-05 benin soutenu
  SC04-MSI    -> SC-04   inondation MSI          SC10-SCAN  -> SC-08 balayage

Une campagne n'entre dans le lot que si ses garde-fous sont bons : MAGIC du
v18 sur les deux wrappers, marqueur de fin, CTRL relu 0x331 sur les deux,
aucun registre 0x110 ecrit, aucun octet parasite hors du « é » connu.
"""
import re
import statistics as st
import sys

MAGIC = "0x41524d4f52000012"
CTRL_REF = "0x331"


def load(path):
    raw = open(path, "rb").read()
    txt = raw.replace(b"\0", b"").decode("utf-8", "replace").replace("\r", "")
    return raw, txt


def guards(raw, txt):
    """Rend la liste des garde-fous en defaut (vide = campagne valide)."""
    bad = []
    m = re.search(r"wrap1=(0x[0-9a-f]+) wrap2=(0x[0-9a-f]+)", txt)
    if not m or m.group(1) != MAGIC or m.group(2) != MAGIC:
        bad.append("MAGIC")
    if "###### END ######" not in txt:
        bad.append("fin")
    m = re.search(r"CTRL relu : w1=(0x[0-9a-f]+) w2=(0x[0-9a-f]+)", txt)
    if not m or m.group(1) != CTRL_REF or m.group(2) != CTRL_REF:
        bad.append("CTRL")
    if re.search(r"Table 4.*0x[0-9a-f]{8}", txt):
        bad.append("0x110 ecrit")
    if b"\0" in raw:
        bad.append("octets nuls")
    return bad


def summ(txt, kind, name):
    """SUMMARY-DET/TX : name,N,n,n_lat,TP,FP,FN,TN,Lmin,Lavg,Lp50,Lp99,Lmax"""
    m = re.search(rf"^SUMMARY-{kind},{name},([^\n]*)", txt, re.M)
    if not m:
        return None
    v = m.group(1).split(",")
    keys = "N n n_lat TP FP FN TN Lmin Lavg Lp50 Lp99 Lmax".split()
    return {k: float(x) for k, x in zip(keys, v)}


def kv(line):
    return {k: v for k, v in re.findall(r"(\w+)=(0x[0-9a-f]+|\d+)", line)}


def cnt(txt, name, w):
    m = re.search(rf"^# ARMORCNT,{name},{w},([^\n]*)", txt, re.M)
    return kv(m.group(1)) if m else None


def lat(txt, name, w):
    m = re.search(rf"^# ARMORLAT,{name},{w},([^\n]*)", txt, re.M)
    return kv(m.group(1)) if m else None


def status_final(txt, name):
    m = re.search(rf"^# {name} STATUS_final=\S+ \| ([^\n]*)", txt, re.M)
    return {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", m.group(1))} if m else None


def per_campaign(txt):
    r = {}
    for name, key in (("SC01-SPOOF", "spoof"), ("SC02-STORM", "storm"), ("SC04-MSI", "msi")):
        r[key] = summ(txt, "DET", name)["TP"]
    sf = status_final(txt, "SC03-OUTS")
    r["outs_contained"] = 50 - sf["DONE"] - sf["ERR"] - sf["UNK"]
    r["outs_inflight"] = sf["OUTS"]
    r["outs_timeout"] = sf["ERR"]
    r["outs_lp50"] = summ(txt, "DET", "SC03-OUTS")["Lp50"]
    ben = [summ(txt, "DET", n) for n in ("SC06-LHAOK", "SC07-MHAOK", "SC08-LAS")]
    r["fp"] = sum(b["FP"] for b in ben)
    r["benign_n"] = sum(b["N"] for b in ben)
    m = re.search(r"^# SC10 : passed=(\d+) blocked=(\d+)", txt, re.M)
    r["scan_n"], r["scan_blocked"] = int(m.group(1)) + int(m.group(2)), int(m.group(2))
    for name, key in (("SC01-SPOOF", "spoof"), ("SC02-STORM", "storm"), ("SC04-MSI", "msi")):
        l = lat(txt, name, "w2")
        r[f"lat_{key}_nv"], r[f"lat_{key}_max"] = int(l["n_verdict"]), int(l["det_max"])
    # fond LHA : toutes les lignes ARMORCNT w1 de la campagne
    w1 = [kv(m) for m in re.findall(r"^# ARMORCNT,[^,]+,w1,([^\n]*)", txt, re.M)]
    r["bg_peak"] = max(int(x["reqmax"]) for x in w1)
    r["bg_winact"] = sum(int(x["winact"]) for x in w1)
    rows = {"sc06": ("SC06-LHAOK", "w1"), "sc05": ("SC08-LAS", "w2"),
            "scan": ("SC10-SCAN", "w2"), "storm": ("SC02-STORM", "w2")}
    for key, (name, w) in rows.items():
        c = cnt(txt, name, w)
        r[f"t12_{key}"] = (int(c["reqmax"]), int(c["winact"]), int(c["apages"]), int(c["pgchg"]),
                           summ(txt, "TX", name)["Lp50"])
    l = lat(txt, "SC06-LHAOK", "w1")
    r["rtt_read"] = int(l["tx_avg"])
    return r


def fmt(v):
    """Moyenne ± demi-intervalle de confiance a 95 % (1,96 sigma / racine n) :
    c'est la convention des ± de l'article, verifiee sur la Table 7 (26,0 ± 2,4)
    et la Table 10 (44,8 ± 2,2). L'ecart-type par campagne suit entre crochets."""
    if len(v) < 2 or st.stdev(v) == 0:
        return f"{st.mean(v):g} (identique)"
    sd = st.stdev(v)
    return f"{st.mean(v):.2f} ± {1.96 * sd / len(v) ** 0.5:.2f} [sigma {sd:.2f}]"


def main():
    args = sys.argv[1:]
    if args and args[0] == "--csv":
        labels = set(args[2:])
        paths = ["results/" + l.split(",")[2] for l in open(args[1]) if l.split(",")[0] in labels]
    else:
        paths = args
    runs, rejected = [], []
    for p in paths:
        raw, txt = load(p)
        bad = guards(raw, txt)
        if bad:
            rejected.append((p, bad))
            continue
        runs.append(per_campaign(txt))
    n = len(runs)
    print(f"LOT : {n} campagnes retenues, {len(rejected)} rejetees")
    for p, b in rejected:
        print(f"  rejetee {p} : {', '.join(b)}")
    col = lambda k: [r[k] for r in runs]

    inj = 50 * n
    print("\n== Table 7 (sur 50 par campagne)")
    for k, lab in (("spoof", "usurpation"), ("storm", "tempete"), ("msi", "MSI")):
        print(f"  {lab:12s} {int(sum(col(k)))} / {inj}   par campagne {fmt(col(k))}")
    pc = [100 * x / 50 for x in col("outs_contained")]
    pi = [100 * x / 50 for x in col("outs_inflight")]
    pt = [100 * x / 50 for x in col("outs_timeout")]
    print(f"  epuisement   contenu {fmt(pc)} %   en-vol seul {fmt(pi)} %   timeout {fmt(pt)} %")
    print(f"  balayage     {sum(col('scan_blocked'))} verdicts / {sum(col('scan_n'))} injections")
    print(f"  faux positifs {int(sum(col('fp')))} / {int(sum(col('benign_n')))} transactions benignes")
    print(f"  regle de trois : 0 sur {inj} -> taux < {300 / inj:.2f} % (95 %)")

    print("\n== Table 8 (latence du wrapper, w2)")
    for k, lab in (("spoof", "usurpation"), ("storm", "tempete"), ("msi", "MSI")):
        mx = col(f"lat_{k}_max")
        print(f"  {lab:12s} verdicts {sum(col(f'lat_{k}_nv'))}   attente max {max(mx)}   "
              f"(par campagne de {min(mx)} a {max(mx)})")

    print("\n== Table 11, ligne 16 (synth.)")
    print(f"  verdicts d'en-vol sur 50 : {fmt(col('outs_inflight'))}   Lp50 : {fmt(col('outs_lp50'))}")

    print("\n== Table 12 (pic, fenetres actives, cycles/transfert, pages, changements)")
    print(f"  fond LHA     pic {max(col('bg_peak'))}   fenetres {min(col('bg_winact'))}–{max(col('bg_winact'))}")
    for key, lab in (("sc06", "SC-06"), ("sc05", "SC-05"), ("scan", "SC-08 balayage"), ("storm", "SC-02 tempete")):
        t = col(f"t12_{key}")
        print(f"  {lab:14s} pic {max(x[0] for x in t)}   fenetres {min(x[1] for x in t)}–{max(x[1] for x in t)}   "
              f"Lp50 {fmt([x[4] for x in t])}   pages {max(x[2] for x in t)}   changements {min(x[3] for x in t)}–{max(x[3] for x in t)}")

    print("\n== §6.3.3 aller-retour lu par le wrapper (SC-06, w1)")
    print(f"  {fmt(col('rtt_read'))} cycles")


if __name__ == "__main__":
    main()
