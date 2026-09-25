# ASOS

Supervision logicielle des wrappers ARMOR. ASOS lit les alertes de chaque
wrapper, tient pour chaque slot un score de menace qui décroît dans le temps, le
classe en TLC (Trust Level Class) et écrit dans le wrapper la politique qui
correspond à la classe.

## Modules

| Module | Dossier | Rôle |
|---|---|---|
| 1. Event Processing | `event_processing/` | Lit et acquitte le registre d'alerte (STICKY), lit l'étendue d'adresses si un working set est déclaré, traduit chaque alerte en événement normalisé (slot, type, horodatage). |
| 2. Security Context Creation | `security_context/` | Crée le contexte d'un slot au déploiement (Device ID, bornes de référence, working set, score nul, TLC-10), le supprime au retrait, calcule les bornes dérivées du trafic légitime observé. |
| 3. Supervision Unit | `supervision_unit/` | Score = score × 230/256 + poids des événements ; classement en TLC ; verrou BANNED ; hystérésis ; politique voulue. |
| 4. Update Unit | `update_unit/` | Écrit la politique dans le wrapper (CFG_PARAMS, ID_CFG, CTRL) et relit pour vérifier la mise à jour. |

`asos.c` enchaîne les modules 1, 3 et 4 pour une évaluation d'un slot
(`asos_step`). Le module 2 est appelé au déploiement et au retrait d'un
accélérateur. `include/` porte l'API (`asos.h`), les types partagés et le
sous-ensemble de la carte des registres ARMOR qu'ASOS utilise.

Les sources ne dépendent que de `<stdint.h>` : ni allocation, ni affichage.
Elles compilent en freestanding pour rv64.

## Politiques

| TLC | État | Politique écrite |
|---|---|---|
| ≥ 6 | ACTIVE / LEARNING | bornes de référence |
| 5 | SUSPICIOUS | seuil de flux 6 |
| 4 | SUSPICIOUS | seuil 4, transferts comptés, bornes resserrées (échecs 2, en-vol 8, fenêtre 50) |
| 3 | QUARANTINE | idem + Device ID révoqué |
| ≤ 2 | BANNED | idem, verrouillé |

## Tests

```
make -C asos/tests
```

- `unit` : working set, calibration des bornes, vérification de mise à jour,
  verrou BANNED, suppression du contexte.
- `replay` : rejoue les trajectoires relevées sur carte (`results/*.log`, lignes
  `# TRAJ,`) et compare pas à pas score, TLC, action et registres écrits. Les
  journaux à l'ancien format sont signalés et ignorés.

## État

La logique des modules 1, 3 et 4 est celle qui a tourné sur carte dans le
banc (`bench_runner.c`, blocs `BENCH_ASOS_*`) ; le rejeu le vérifie. Pas encore
exercés sur carte : le contrôle du working set (événement `OUT_OF_SET`, poids
40) et la calibration portée par le module 2. Le banc n'appelle pas encore
cette bibliothèque.
