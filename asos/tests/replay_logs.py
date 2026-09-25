#!/usr/bin/env python3
"""Rejoue les trajectoires ASOS des journaux de carte a travers la bibliotheque.

  asos/tests/replay_logs.py <replay> results/*.log

Pour chaque journal portant des lignes `# TRAJ,<pas>,...`, presente a ASOS les
mots STICKY lus sur carte et compare, pas a pas, ce qu'il en tire a ce que le
firmware a imprime : score et TLC des deux slots, action, et les trois
registres du slot supervise (CTRL, CFG_PARAMS, ID_CFG) quand ASOS agit. Sort en erreur au
premier ecart, avec le journal et le pas.
"""
import re
import subprocess
import sys

HDR_RE = re.compile(r"^# TRAJ : gamma=\d+/256,(?: hysteresis=(\d),)? pas=\d+ cycles, "
                    r"ctrl_ref=(0x[0-9a-f]+), cfgp_ref=(0x[0-9a-f]+)", re.M)
ARM_RE = re.compile(r"ASOS NIVEAU 2 \([^,]+, bras ([\w-]+),")
STEP_RE = re.compile(r"^# TRAJ,\d+,", re.M)


def parse(path):
    txt = open(path, "rb").read().replace(b"\0", b"").decode("ascii", "replace")
    h, arm = HDR_RE.search(txt), ARM_RE.search(txt)
    if not h or not arm:
        return None
    steps = []
    for line in txt.splitlines():
        if not STEP_RE.match(line):
            continue
        f = line.strip().split(",")
        if len(f) != 17:
            return None
        steps.append(f)
    if not steps:
        return None
    hyst = int(h.group(1) or 0)
    enforce = 1 if arm.group(1) == "ASOS" else 0
    return h.group(2), h.group(3), hyst, enforce, steps


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    exe, paths = sys.argv[1], sys.argv[2:]
    n_logs = n_steps = 0
    skipped = []
    for p in paths:
        r = parse(p)
        if r is None:
            if "# TRAJ," in open(p, "rb").read().decode("ascii", "replace"):
                skipped.append(p)
            continue
        ctrl, cfgp, hyst, enforce, steps = r
        cmd = f"H {ctrl[2:]} {cfgp[2:]} {hyst} {enforce}\n"
        cmd += "".join(f"S {f[5][2:]} {f[13][2:]}\n" for f in steps)
        out = subprocess.run([exe], input=cmd, capture_output=True, text=True,
                             check=True).stdout.split("\n")
        for f, o in zip(steps, out):
            got = o.split()
            want = [f[6], f[7][4:], f[9], f[10], f[11], f[12], f[14], f[15][4:]]
            if not enforce:
                # Bras fixes : les registres sont poses par le banc, pas par
                # ASOS. On ne compare que ce qu'ASOS evalue.
                got, want = got[:3] + got[6:], want[:3] + want[6:]
            if got != want:
                print(f"ECART {p} pas {f[1]}\n  carte : {want}\n  ASOS  : {got}")
                sys.exit(1)
        n_logs += 1
        n_steps += len(steps)
    print(f"{n_logs} journaux, {n_steps} pas : identiques a la carte")
    if skipped:
        print(f"{len(skipped)} journaux a l'ancien format, non rejoues")


if __name__ == "__main__":
    main()
