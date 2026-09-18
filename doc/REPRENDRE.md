# Reprendre le travail ARMOR sur une autre machine

État au **2026-09-18**, branche `testbench`. Ce document existe parce que le README amont
ne dit rien de la chaîne de bench, et que tout le reste vivait dans les messages de commit.

## 0. Où reprendre, exactement

> ### 2026-09-18 (nuit, E3) — **E3 MESURÉ : 30 traces aléatoires, zéro resserrement à tort, 20 bannis sur 20**
>
> **REPRENDRE ICI.** E1, E2, hystérésis et E3 faits. Reste **E4 sur l'hôte** (le modèle hôte est validé
> par E2b), puis le `.tex`.
>
> **E3** (`-DBENCH_ASOS_E3 -DASOS_HYST=1 -DE3_KIND=0|1 -DE3_SEED=n`, un build par graine, 100 pas,
> slot MHA ; 30 journaux de `bench_2026-09-18_175803.log` à `bench_2026-09-18_180534.log`, lire `# E3-FIN`) :
> - **Saines** (graines 101–110 ; 30 % de DMA pipeliné légitime, 70 % d'écritures simples) :
>   **0/339 DMA bloqués, 0/661 écritures bloquées, 0 pas resserré sur 1 000.**
> - **Malveillantes** (graines 1–20 ; saines jusqu'à T0 ∈ [10, 40[, puis 30 % d'attaques :
>   tempête 40 %, MSI 20 %, évasion DMA 40 %) :
>
> | mesure | valeur |
> |---|---|
> | tempêtes bloquées | 176/176 |
> | MSI bloquées | 94/94 |
> | **évasions DMA bloquées** | **160/182 (87,9 %)** |
> | DMA sain avant T0 bloqué | 0/171 |
> | 1ʳᵉ restriction, pas après T0 | médiane **2**, de 0 à 15 |
> | ban, pas après T0 | médiane **9**, de 1 à 33 ; **20/20 bannis** |
>
> **Où passent les 22 évasions** (classées d'après la politique en vigueur au job) : **17 sous la
> référence**, avant que l'attaquant se soit révélé par une tempête ou une MSI, et **5 sous
> TLC-5** (seuil 6 **sans** `RFMCNT`). **Sous TLC-4 ou plus bas : 160/160 bloquées.** Deux lectures
> pour l'article : (i) la limite de E1, désormais chiffrée (ASOS ne voit pas un attaquant qui ne
> s'est pas révélé) ; (ii) les 5 passées sous TLC-5 — voir la mesure ci-dessous.
>
> **LA PISTE « `RFMCNT` DÈS TLC-5 » EST FERMÉE** (mesuré le 18/09 au soir, 6 campagnes par seuil,
> SC-09 à profondeur 4, bornes `0x110` de référence, fond LHA actif) :
>
> | seuil, avec `RFMCNT` | 4 (CFG-D, E0) | **5** | **6** | 8 (15/09) |
> |---|---|---|---|---|
> | SC-09 d4 bloqués / 50 | 44,7 | **0** | **0** | 0 |
> | fond LHA `storm=` | 0 | 0 | 0 | 0 |
>
> Journaux : seuil 6 `bench_2026-09-18_1817*` à `_181821`, seuil 5 `_181854` à `_181951`.
> **Frontière nette entre 4 et 5** : ce DMA se tient à une unité de la borne, et le fond LHA
> (densité 4) aussi. C'est une marge fragile, à dire. **Conséquence** : fermer les 5 évasions de
> TLC-5 imposerait le seuil 4 dès TLC-5, c'est-à-dire **fusionner TLC-5 dans la politique TLC-4**
> et perdre le palier intermédiaire. Aucun coût mesuré sur le trafic légitime (0 FP partout),
> mais une réponse moins graduée. **Décision de conception laissée à JC, rien n'est modifié.**
> La ligne « parasites=1 » de ces journaux est un « é » du firmware (SC08), pas l'UART.

> ### 2026-09-18 (nuit, fin) — **HYSTÉRÉSIS AJOUTÉE À ASOS (décision JC) : la mémoire passe de 40 à 220 ms**
>
> **(point de reprise précédent.)** La conception publiée est désormais **ASOS avec hystérésis**
> (`-DASOS_HYST=1`, toute campagne ASOS à venir). Restent E3, E4 (hôte), puis le `.tex`.
>
> **LA RÈGLE** (`traj_eval`) : **resserrer dès l'entrée dans une classe, ne relâcher qu'au retour à
> ACTIVE** (TLC ≥ 8, score < 16). Aucun paramètre nouveau : ce sont les bandes de la Table 2. La
> mémoire devient proportionnelle à la gravité, puisqu'un score haut met plus longtemps à redescendre.
>
> **E2a rejoué avec hystérésis** (3 campagnes par D, `results/bench_2026-09-18_1748*` à `_1752*`) :
>
> | D (pas de 20 ms) | 0 | 1 | 2 | 5 | 10 | 11 | 15 |
> |---|---|---|---|---|---|---|---|
> | sans hystérésis : évasions bloquées / 30 | 30 | 30 | **0** | 0 | 0 | — | — |
> | **avec** : évasions bloquées / 30 | 30 | 29,7 | **30** | 30 | 29,7 | **0** | 0 |
>
> La falaise passe **de D = 2 à D = 11, exactement où l'hôte la prédisait** (57 redescend sous 16
> en 11 pas). **Le prix, à dire avec** : c'est le même chiffre lu à l'envers. Un slot légitime
> soupçonné à tort reste resserré 11 pas au lieu de 2, et un DMA légitime lancé dans cette
> fenêtre est bloqué, puis banni. **Toute mémoire finie peut être attendue** : l'hystérésis
> déplace la falaise, elle ne la supprime pas.
>
> **E1, bras ASOS, rejoué avec hystérésis** (`175256` à `175349`, 6 campagnes) : DMA sain
> **120/120**, évasion bloquée **180/180**. Les bras fixes ne dépendent pas d'ASOS : inchangés.
>
> **Trajectoire rejouée avec hystérésis** (`175403`, `175416`, `175429`, identiques octet pour
> octet ; **ce sont eux à publier**, plus ceux de la série 2) : scores et classes identiques,
> **9 changements de politique au lieu de 16**. **QUARANTINE tient désormais 14 pas** (du pas 87
> au pas 101, ID révoqué et trafic légitime tenu à l'arrêt), puis l'ID est rendu directement à
> la référence. Cela lève la réserve « QUARANTINE ne dure qu'un pas » du bloc de la trajectoire.
> E2b ne dépend que du score : inchangé par construction.

> ### 2026-09-18 (nuit, suite) — **E2 MESURÉ : la mémoire d'ASOS tient deux pas contre l'évasion**
>
> **(point de reprise précédent.)** E1 et E2 faits. Restent **une décision de conception** (ci-dessous), E3, E4,
> puis le `.tex`.
>
> **E2a — l'attaquant patient** (`-DBENCH_ASOS_E1 -DE1_ARM=2 -DE1_DELAY=D`, 3 campagnes par D,
> `results/bench_2026-09-18_1735*` à `_1738*`) : D pas de trafic sain entre la seconde tempête et
> l'évasion pipelinée.
>
> | D (pas de 20 ms) | 0 | 1 | 2 | 3 | 5 | 10 |
> |---|---|---|---|---|---|---|
> | évasions bloquées / 30 | 30 | 30 | **0** | 0 | 0 | 0 |
> | état final | BANNED | BANNED | ACTIVE | ACTIVE | ACTIVE | ACTIVE |
>
> **Une falaise, et elle est exactement prévisible** : TLC-4 (CFG-D + `RFMCNT`) tient deux pas
> (57, 51) ; à 45, TLC-5 (seuil 6 **sans** `RFMCNT`) rend le DMA pipeliné invisible. **Un
> attaquant qui attend 40 ms s'évade entièrement, sans jamais être banni.** Trois campagnes
> identiques par case. `173537` a deux lignes parasitées dont celle du MAGIC (illisible) : les
> deux autres campagnes du même build lisent `0x12`.
>
> **E2b — l'attaquant intermittent** (`-DBENCH_ASOS_E2B -DE2_PERIOD=n`, tempête classique tous
> les n pas pendant 60 pas, 3 campagnes par n, `_1738*` à `_1741*`) :
>
> | n | 3 | 6 | 7 | 10 |
> |---|---|---|---|---|
> | banni | oui, pas 16 (score 99) | oui, pas 34 (score 87) | **non**, max 80 | **non**, max 63 |
>
> **La carte reproduit la prédiction de l'hôte au pas et à l'unité près** (même arithmétique :
> frontière n ≤ 6 ⇔ 45/(1−γⁿ) ≥ 86). Une tempête pèse 45 même sous politique resserrée. **Le
> modèle hôte est donc validé : E4 (sensibilité à γ, aux seuils, à la période) se fait sur l'hôte**,
> et c'est à dire ainsi dans l'article. Après le ban, les tempêtes suivantes portent en plus les
> bits d'usurpation (ID révoqué), d'où les maxima 443 / 249 : sans importance pour le verdict.
>
> **LA DÉCISION DE CONCEPTION QUE E2a IMPOSE** (à trancher par JC) : publier ASOS tel quel, avec la
> falaise à 40 ms comme limite mesurée, ou **ajouter une hystérésis** (politique tenue un temps
> minimal, ou relâchée seulement sous un seuil plus bas) et **mesurer le gain** avec le même E2a.
> La seconde voie touche le firmware seul, pas le RTL.

> ### 2026-09-18 (nuit) — **E1 MESURÉ : ASOS FACE AUX DEUX POLITIQUES STATIQUES**
>
> **(point de reprise précédent.)** **Option (b) retenue par JC** : les contributions ASOS se réduisent à « une
> réponse graduée à états », évaluée par E1–E4 ; corrélation entre slots, DPR et VM de service
> passent en conception non évaluée, dans les limites. E1 est fait ; restent E2 (attaquant
> intermittent / patient), E3 (traces aléatoires), E4 (sensibilité, sur l'hôte), puis le `.tex`.
>
> **POURQUOI E1 A CETTE FORME.** Mesure préalable E0 (12 campagnes, `results/bench_2026-09-18_1710*`
> à `_1712*`) : politique stricte (CFG-D + `RFMCNT`) sur SC-09, profondeur 2 / 4 / 8 / 16 →
> **0 / 44,7 / 50 / 50** sur 50, fond LHA `storm=0` partout. **Sur le trafic légitime du banc, la
> stricte ne coûte rien** : seul un DMA pipeliné légitime la met en défaut. **HYPOTHÈSE DE
> CADRAGE validée par JC, à écrire dans l'article** : seize écritures pipelinées à profondeur 4
> sont un DMA de streaming légitime. Physiquement, c'est le même trafic que la tempête pipelinée.
>
> **E1** (`-DBENCH_ASOS_E1 -DE1_ARM=0|1|2`, `-DARMOR_BFATE=1` dans les trois bras, slot MHA,
> 61 pas) : **P1** 20 jobs de DMA sain → **P2** deux tempêtes classiques (score 57, TLC-4) → **P3**
> 30 jobs du même DMA, désormais malveillant. **Six campagnes par bras**, toutes propres :
>
> | bras | P1 : DMA sain mené au bout | P3 : évasion bloquée |
> |---|---|---|
> | référence fixe | **120/120** (100 %) | **0/180** (0 %) |
> | stricte fixe | **4/120** (3,3 %) | **167/180** (92,8 %) |
> | ASOS | **120/120** (100 %) | **179/180** (99,4 %) |
>
> Journaux : référence `172606`, `172617`, `172627`, `173019`, `173029`, `173040` ; stricte
> `172825`, `172836`, `172846`, `173055`, `173105`, `173116` ; ASOS `172716`, `172727`, `172737`,
> `173130`, `173141`, `173152` (tous `results/bench_2026-09-18_*`). Lire les lignes `# PHASE`.
>
> **À DIRE EXACTEMENT, sans enjoliver** :
> - **Dans le bras ASOS, les bornes ne tranchent que le premier job d'évasion** (5 fois sur 6 ; la
>   6ᵉ fois, le 1ᵉʳ passe et le 2ᵉ est pris, `173141`). Le verdict pousse le score à 96 (BANNED),
>   et **tous les jobs suivants sont refusés par la révocation de l'ID**, pas par les bornes.
> - **La fenêtre TLC-4 ne dure que deux pas** (57 → 51 → 45, TLC-5 sans `RFMCNT`). **Un attaquant
>   qui attend 40 ms après sa tempête s'évade.** C'est l'objet de E2, et une vraie limite.
> - **Un attaquant qui passe directement au mode pipeliné** sans se trahir avant n'éveille jamais
>   ASOS : ASOS ne protège que contre un attaquant **qui s'est déjà révélé**.
> - Bras strict : le fond LHA déclenche **une fois, au pas 0**, dans 2 campagnes sur 6
>   (`score1_max=45`). C'est un **artefact de bascule** (E0, qui démarre strict, donne 0).
>   Ne pas le compter comme un coût de la stricte.
>
> **LA POLITIQUE TLC-4 COMPREND MAINTENANT `RFMCNT`** (`traj_apply`). La trajectoire a été
> **rejouée** avec cette politique et `BFATE` (`172924`, `172937`, `172950`) : **score, classe,
> état et action identiques à la série 2 au pas près**, seul le CTRL relu porte le bit 12.
> Publier ces trois journaux-là.
>
> **Bug corrigé en route** : la première passe du bras strict (3 journaux supprimés) ne portait
> que `0x110` ; la purge du collant réécrivait CTRL après la bascule. Vérifier `ctrl2 = 0x41731`
> à chaque fois.

> ### 2026-09-18 (soir) — **TRAJECTOIRE ASOS JOUÉE SUR CARTE : six campagnes, QUARANTINE atteinte**
>
> **(point de reprise précédent.)** Le chantier (1) du bloc ci-dessous est fait. Reste le (2) : la
> sous-section §6.4 « trajectoire » et ses raccords.
>
> **Série 1, scénario d'origine** (`results/bench_2026-09-18_164943`, `_164955`, `_165008`) : les
> trois campagnes ont la même trajectoire au pas près. Le journal 2 a perdu les pas 40–54 sur
> l'UART ; ses 132 lignes lisibles sont identiques. **Mais la MSI du pas 81 mène directement à
> BANNED (score 100)** : la rafale MSI pèse **60 et non 40**, parce qu'elle lève AUSSI le moniteur
> de flux (collant `0xaa8` ; même chose sur SC-04 seul, `storm=75`). La table simulée du bloc
> ci-dessous se trompe sur ce point. QUARANTINE n'était jamais atteinte.
>
> **Série 2, scénario corrigé — celle à publier** (`results/bench_2026-09-18_170318`, `_170331`,
> `_170343`, aucun octet parasite, **trois trajectoires identiques octet pour octet**, 153 pas) :
> tempête au pas 80, six pas légitimes, puis MSI. Le firmware seul a changé, pas l'équation.
>
> | pas | événement | score | classe | politique |
> |---|---|---|---|---|
> | 10 / 20 / 30 | tempête | 45 / 57 / 61 | TLC-5 / 4 / 4 | seuil 6 / CFG-D / CFG-D |
> | 41 → 53 | légitime | 15 → 0 | ACTIVE | référence |
> | 80 | tempête | 45 | TLC-5 | seuil 6 |
> | 87 | MSI | 21 → **78** | **TLC-3 QUARANTINE** | CFG-D + ID révoqué (`0xffffffff`) |
> | 88 | légitime (tenu, `I`) | 70 | TLC-4 | **ID rendu** (`0x2`), CFG-D |
> | 91 / 94 / 101 | légitime | 49 / 35 / 14 | TLC-5 / 6 / 8 | seuil 6 / référence |
> | 128 / 129 | usurpation | 0 / 0 | ACTIVE | aucune alerte (ban au 3ᵉ échec, attendu) |
> | 130 / 131 | usurpation | 65 / **123** | TLC-4 / **BANNED** | CFG-D / verrouillé |
> | 133 → 152 | légitime (tenu, `I`) | 222 → 24 | BANNED | reste BANNED |
>
> `TRAJ-FIN` : `banni2=1`, `score2_max=222`, `politiques2=16`, `sonde2=E` (**refusée** : réponse
> d'erreur ; la série 1 donnait `B`, les deux lettres alternent pendant l'usurpation),
> `score1_max=0`, `politiques1=0` (**le fond LHA ne bouge jamais**), `depassements=0`.
> Mesure à −O0 (`CALIB` 26), sans conséquence : la trajectoire ne chronomètre rien.
>
> **Pour l'article** : QUARANTINE ne tient **qu'un pas** (78 → 70). Cela s'ajoute au point (i)
> du bloc ci-dessous : la durée d'une restriction est fixée par la période d'évaluation.

> ### 2026-09-18 — **RELECTURE FINIE JUSQU'À §6.6 ; ASOS RETROUVE UNE ÉVALUATION (option B), À JOUER SUR CARTE**
>
> **(point de reprise précédent.)** Deux chantiers ouverts, dans cet ordre : (1) la session carte de
> l'option B, (2) la sous-section d'article qui en sort.
>
> **OÙ SONT LES PIÈCES DE L'ARTICLE (changé le 18/09)**
> - **Le `.tex` est versionné** : `git clone https://gitlab.insa-rennes.fr/trust_gw/article_jsa.git`,
>   fichier `cas-sc-template.tex`. Compiler : `pdflatex` ×2 + `bibtex` (renvois : 0 `??`, 30 pages).
>   Utiliser les VRAIES étiquettes (`grep -n '\\label{'`), ne plus en supposer.
> - `CONTRAINTES_RELECTURE.md` (règles R1–R9, contrôles 1–8) **n'est PAS versionné**, par choix :
>   il voyage par téléchargement. Sans lui, la relecture perd ses règles.
> - Le dossier-artefact (https://claude.ai/artifact/84VmBeb5agszoVD2KTif7m) **n'a PAS reçu la passe
>   du 18/09 après-midi** : ce bloc-ci est le seul relevé de ce qui a été fait.
>
> **1. CE QUI A ÉTÉ FAIT DANS LE `.tex` LE 18/09** (tout en `\add{}`) :
> - §6.5 réécrite et **simplifiée en trois paragraphes** (ARMOR aux bornes évaluées ; une borne est
>   un choix contre une charge, le scan échappe à toutes ; partage du travail par échelle de temps).
>   Trois contradictions supprimées : ASOS « négligeable » devant la détection (§6.4.3 dit « du même
>   ordre »), l'épuisement « défait par la contention plutôt que par l'enforcement » (la Table 11 dit :
>   moniteur de flux puis timeout), et le blocage « dans le même cycle » (la Table 8 dit ≤ 49 cycles).
> - §6.6 réécrite : ASOS n'est plus évalué que pour son coût, dit comme une limite ; **la Table 13
>   vient du bitstream v12** (MAGIC `0x…0c`, `results/asos_O2.log`, `asos_irq_00{1,2}.log`), dit en
>   clair — paragraphe À SUPPRIMER si on la rejoue sur le v18.
> - Raccords des coupes : abstract, dernière puce de §1.2, préambule §6 (Q4/Q5 supprimées, nouvelle Q4
>   « containment vs bounds / what a bound-based monitor cannot detect »), §6.1 fusionnée et **§6.1.2
>   supprimée** (étiquette `sec:virtplat` disparue), intro §6.4, Conclusion. Partout, l'épuisement
>   « finit sur le timeout du maître », plus « bus contention ».
> - Huit renvois réparés, dont les trois `??` historiques (`eq:score`, `eq:det`, `eq:detect`).
>
> **2. DÉCISIONS ENCORE OUVERTES**
> - **Le lot : 45 ou 56 campagnes** (point 1 du dossier). L'abstract affiche maintenant **0,13 %**
>   avec 2 250 injections (option A, cohérente) — **à confirmer par JC**.
> - Bloc en commentaire `%The two campaigns deliberately use different experimental environments…`
>   dans le préambule §6 : obsolète, à supprimer.
> - §6.4.1 : « that path is exercised functionally » — vestige de la plateforme virtualisée.
> - Table 14 : toujours des `\tbd{}`. Son journal (`bench_2026-09-16_120430.log`) **est dans `results/` depuis la fusion du 18/09** :
  il était resté dans un commit non poussé (`b73504f`, bloc du 16/09 après-midi ci-dessous). C'est une
  campagne `-DBENCH_ASOS -DBENCH_ASOS_IRQ` à −O2 **sur le v18** (MAGIC `0x12`) : elle rend la seconde
  commande du point 4 probablement inutile, et le paragraphe « bitstream v12 » de §6.6 supprimable.
>
> **3. DIAGNOSTIC DU PAPIER ET DÉCISION.** La moitié ARMOR est solide. Mais §2.4 et trois des cinq
> contributions reposent sur ASOS (corrélation, confiance persistante, cycle DPR) alors que §6 ne fait
> plus que le chronométrer. **Option B retenue** : redonner à ASOS une évaluation fonctionnelle sur
> carte, sans resynthèse. Elle couvre accumulation, transitions de TLC, mitigation appliquée au
> matériel, décroissance, bannissement terminal. **Elle NE couvre PAS** la corrélation entre slots
> (le LHA n'a pas de registre de mode : il faudrait toucher au RTL, marge WNS +0,061 ns), ni le DPR,
> ni la VM de service.
>
> **4. LE FIRMWARE EST PRÊT : `-DBENCH_ASOS_TRAJ`** (commit `a8365cb`, `bench_runner.c`). Campagne
> autonome, wrappers vierges, fond LHA actif. Un pas = une évaluation de l'équation 3, 20 ms.
> Actuation réelle et relue : TLC-5 seuil 6, TLC-4 bornes CFG-D via `0x110`, QUARANTINE révoque
> l'ID (rendu en sortie), BANNED **verrouillé**. Sonde finale : l'accélérateur banni doit être refusé.
>
> ```sh
> # bitstream v18 flashé (DEUX passes, voir § 0 ter), puis :
> tools/campagne.sh TRAJ 3 "-DBENCH_ASOS_TRAJ"
> OPT_LEVEL=2 tools/campagne.sh ASOS 3 "-DBENCH_ASOS -DBENCH_ASOS_IRQ"   # Tables 13 et 14 sur le v18
> ```
> `campagne.sh` transmet `OPT_LEVEL` depuis le 18/09 (sinon mesure à −O0, ×5). Ses colonnes SC01–SC04
> restent **vides pour TRAJ, c'est normal** : lire les lignes `# TRAJ` et `# TRAJ-FIN` du journal.
>
> **Trajectoire attendue** (simulée sur l'hôte, même arithmétique entière ; le bit BLOCKED, poids 25,
> accompagne tout verdict appliqué : tempête 45, MSI 40, usurpation 65) :
>
> | pas | événement | score | classe | politique |
> |---|---|---|---|---|
> | 10 / 20 / 30 | tempête | 45 / **57** / **61** | TLC-5 / 4 / 4 | seuil 6 / CFG-D / CFG-D |
> | 35 → 79 | légitime | décroît | → ACTIVE | référence |
> | 80 / 81 | tempête puis MSI | 45 → 80 | QUARANTINE | ID révoqué |
> | 83 → 88 | arrêt puis reprise | 63 → 35 | → ACTIVE | ID rendu à 83 |
> | 124 / 125 | usurpation | 65 → 123 | **BANNED** | verrouillé jusqu'au bout |
>
> **À vérifier sur les trois journaux** : trajectoire identique au pas près (sinon, R7 : intervalle) ;
> `TRAJ-FIN` avec `banni2=1`, `sonde2` bloquée (pas `D`), `score1_max=0`, `politiques1=0`,
> `depassements=0`. Les deux premiers pas d'usurpation devraient ne lever aucune alerte (ban au 3ᵉ
> échec) : si la carte diffère de la table, c'est la table qu'on corrige, pas le firmware.
>
> **Deux résultats de conception à assumer dans l'article** : (i) avec γ = 0,9 **par pas**, une
> tempête isolée ne tient SUSPICIOUS que deux pas — la durée d'une restriction dépend de la période
> d'évaluation, que le papier ne fixe nulle part ; (ii) une tempête soutenue mène au bannissement
> (équilibre 45/(1−γ) ≈ 440).
>
> **5. APRÈS LA CARTE, DANS LE `.tex`** : une sous-section §6.4 « trajectoire » (~250 mots + figure
> score/pas avec bandes de TLC), une Q sur le comportement à états d'ASOS, et reprendre en conséquence
> §1.2, l'intro §6.4, §6.4.1 (**dire que la trajectoire est une évaluation périodique**, l'interruption
> étant chronométrée à part), §6.6 et la Conclusion. Remplir la Table 14, et supprimer le paragraphe
> « bitstream antérieur » de §6.6 si la Table 13 a été rejouée.

> ### 2026-09-16 (soir) — **LE MANUSCRIT EST À JOUR ; le dossier de révision est clos**
>
> **(point de reprise précédent.)** Plus rien en attente : ni mesure, ni ajout, ni correction. Le PDF du
> 16/09 à 14 h 07 (32 p.) passe les huit contrôles ci-dessous. L'artefact v35
> (https://claude.ai/artifact/84VmBeb5agszoVD2KTif7m) ne contient plus de liste de tâches,
> seulement l'annexe : la provenance de chaque chiffre.
>
> **CE QUI A ÉTÉ PORTÉ DANS L'ARTICLE** (six ajouts, treize tables) : §4.5 conformité AXI4,
> §6.2.4 méthodologie des campagnes, §6.3.5 sensibilité aux seuils, §6.3.6 les quatre
> configurations mesurées, §6.3.7 angle mort du balayage mémoire, §6.3.8 tempête pipelinée.
> Légendes toutes ramenées à une ou deux lignes, texte ajouté en rouge par `\add{}`.
>
> **LES HUIT CONTRÔLES, à rejouer si le manuscrit rebouge** :
> 1. aucun `??` ; 2. les treize légendes sur la bonne table ; 3. les 41 renvois de table
> pointent la table annoncée ; 4. aucun passage dupliqué mot pour mot ; 5. aucune légende de
> plus de deux lignes ; 6. aucun « no false negatives » ni « 100 % » là où une borne est voulue ;
> 7. les chiffres de l'abstract se recalculent depuis les tables ; 8. aucun chiffre de la
> section 6 venant d'un autre bitstream.
>
> **LE CONTRÔLE 3 EST CELUI QUI SERT.** Il a trouvé deux phrases qui désignaient une table
> **existante mais pas la bonne** — invisibles à la compilation, parce que l'insertion d'une
> table en section 4 avait décalé toute la série d'un rang. Tous les renvois passent désormais
> par une étiquette ; garder cette discipline : `grep -n 'Table [0-9]' *.tex` doit ne rien
> rendre hors légendes.
>
> **DEUX PIÈGES DE RELECTURE rencontrés, qui se reproduiront** : (i) une légende recopiée vers
> le bas au lieu d'être substituée a contaminé quatre tables, et celle qui a **résisté** à la
> correction était celle dont la légende erronée était **en double** — un remplacement qui
> s'arrête à la première occurrence ; (ii) corriger un renvoi en dur vers `\ref` **crée** un
> `??` si l'étiquette n'a jamais été posée. Recompiler deux fois après chaque tour.
>
> **UNE ERREUR DE MA PART, corrigée des deux côtés** : §6.3.2 annonçait un écart-type nul au
> seuil 9 ; la Table 8 donne 0,41. La table a raison — au seuil 9, cinq campagnes sur six
> contiennent 50 rafales, une en contient 49 (vérifié dans `results/mesures_2026-09-15_v18.csv`).
> La phrase venait du dossier et s'était propagée dans son annexe III.2.
>
> **LE SEUL CHIFFRE DÉRIVÉ DE L'ARTICLE** : la borne de **0,11 %** (abstract et §6.3.1) est la
> règle de trois sur 2 750 injections, soit **55 campagnes de 50**. Si le pool change, elle
> change — à 21 campagnes elle vaudrait 0,29 %. C'est le seul chiffre qu'une re-mesure
> partielle peut rendre faux en silence.

> ### 2026-09-16 (après-midi) — **CAMPAGNE ASOS REJOUÉE SUR LE v18 ; plus aucun chiffre venu d'ailleurs**
>
> **(point de reprise précédent.)** La dernière dette de mesure est soldée. Il ne reste **que le report dans
> le LaTeX** : six ajouts et dix réparations, tous dans l'artefact v30
> (https://claude.ai/artifact/84VmBeb5agszoVD2KTif7m).
>
> **1. LA TABLE ASOS EST MESURÉE SUR LE BITSTREAM ÉVALUÉ.** Seize réactions, **aucune sans
> remontée**, journal `results/bench_2026-09-16_120430.log`. Garde-fous : MAGIC `0x12`,
> `CTRL` relu `0x331`, marqueur de fin présent.
>
> | phase | symbole | cycles | part |
> |---|---|---|---|
> | délivrance d'interruption | `L_notify` | 45 816 | 74,1 % |
> | évaluation + classification TLC | `L_processing` | 196 / 221 | 0,3 % |
> | actuation | `L_mmio` | 56 / 67 | 0,1 % |
> | retour de gestionnaire | `L_exit` | 15 776 | 25,5 % |
> | **réaction bout en bout** | `L_total` | **61 872** | 100 % |
>
> Écart avec les chiffres publiés (pris sur un bitstream antérieur) : **moins de 0,3 % sur
> chaque phase**. C'était le pronostic ; c'est maintenant une mesure. **Conséquence article** :
> la réserve de R5 tombe, et §6.6 ne concède plus que **deux** limites au lieu de trois.
>
> **Les deux colonnes du milieu portent un slash et pas une fourchette, et c'est le résultat** :
> à zéro bit d'alerte et une écriture de politique, 196 et 56 cycles, **identiques au cycle dans
> neuf réactions sur dix** ; à deux bits et deux écritures, 221 et 67, quatre fois sur cinq. La
> première réaction est un rodage (388 cycles), même signature que le trafic légitime en III.4.
>
> **2. PIÈGE CONFIRMÉ — `OPT_LEVEL = 0` par défaut** (`bao-baremetal-guest/Makefile:19`), alors
> que les chiffres logiciels publiés sont des **−O2**. `tools/campagne.sh` ne passe PAS
> `OPT_LEVEL` : pour toute mesure logicielle il faut construire à la main avec `OPT_LEVEL=2`,
> sinon `L_processing` est ~5× trop grand et on conclut à une régression qui n'existe pas.
> Contrôle : la ligne `# CALIB` du journal doit annoncer **une lecture de `cycle` à 2 cycles**
> (26 à −O0). Commande exacte utilisée :
>
> ```sh
> cd bao-baremetal-guest && make clean
> make PLATFORM=cva6 CROSS_COMPILE="$RISCV_BARE" BENCH=1 OPT_LEVEL=2 -j$(nproc) \
>      ARCH_CPPFLAGS="-DBENCH_QUICK -DARMOR_WSKID=1 -DARMOR_FRESH=1 -DARMOR_RHOLD=1 \
>                     -DARMOR_WFATE=1 -DBENCH_ASOS -DBENCH_ASOS_IRQ"
> cd .. && cp bao-baremetal-guest/build/cva6/baremetal.bin build/guests/baremetal.bin
> ./2_build_HB.sh bao && ./2_build_HB.sh opensbi
> tools/capture_uart.sh -j opensbi/build/platform/fpga/ariane/firmware/fw_payload.elf
> ```
>
> **3. NON-RÉGRESSION, dans la même passe** : SC-01 à SC-04 **50/50**, **FP = 0**, le balayage
> d'adresses reproduit **256 pages / 699 changements** à l'unité, le fond LHA ne déclenche pas
> (`storm=0` sur w1), et SC-03 donne **0 verdict** à la borne de synthèse — cohérent avec les
> 0,8 ± 0,6 publiés. **202ᵉ campagne sur le v18.**
>
> **ATTENTION, les latences LOGICIELLES de cette campagne ne se comparent pas aux 201 autres** :
> elles sont à −O2, les précédentes à −O0. `L3p50` lit 65 582 ici contre 65 685 ailleurs — c'est
> le même timeout maître vu par une boucle de scrutation différente. **Les comptages matériels,
> eux, sont comparables** : ce sont des verdicts, pas des cycles logiciels.
>
> **4. DÉCOMPOSITION relue le 16/09** (annexe III.5 de l'artefact) : lecture CSR wrapper **17**,
> écriture + relecture **43**, évaluation O(NEV) **155**, O(k) **132** (publié 122), TLC seule
> **106**, lecture vPLIC émulé **815** (publié 813), boucle à vide **5**. Plancher
> évaluation + actuation seules : **215–262** cycles (publié 213–264).

> ### 2026-09-16 — **LES 25 ÉTAPES SONT PORTÉES ; artefact v29, six ajouts et onze réparations**
>
> **(point de reprise précédent.)** L'article a été repris sur l'autre PC (`/media/sf_Partage/Papier_JSA_JC.pdf`,
> recompilé le 16/09, 28 p.) : **les vingt-cinq passages « change » sont appliqués**. Ce qui reste
> n'est plus du report, c'est de la **rédaction d'ajouts** — le texte n'existait pas — plus les
> incohérences qu'une révision partielle laisse derrière elle. **Aucune mesure n'est en attente**,
> sauf une facultative (campagne ASOS sur le v18, ci-dessous).
>
> **Artefact v29** — https://claude.ai/artifact/84VmBeb5agszoVD2KTif7m — réécrit pour cet état :
> LaTeX prêt à coller, points d'insertion cités par la phrase qui précède et celle qui suit,
> texte ajouté en rouge (`\newcommand{\add}[1]{\textcolor{red}{#1}}`), chiffres sortis du corps
> du texte et mis en tables avec `\label`/`\ref`, commentaires en italique hors des blocs à coller.
>
> **1. SIX SOUS-SECTIONS À AJOUTER** (A1–A6 dans l'artefact) :
>
> | | Où | Apporte |
> |---|---|---|
> | A1 | nouvelle §4.5, avant `\subsection{Discussion}` | conformité AXI4 + table des 5 mécanismes |
> | A2 | nouvelle §6.2.4, avant §6.3 | méthodologie des campagnes, standard statistique |
> | A3 | nouvelle §6.3.5 | sensibilité aux seuils + 2 tables de balayage |
> | A4 | nouvelle §6.3.6 | Table 4 enfin mesurée + table de résultats |
> | A5 | nouvelle §6.3.7 | angle mort du balayage mémoire + table d'étendue |
> | A6 | nouvelle §6.3.8 | tempête pipelinée (SC-09) — **facultatif** |
>
> A3–A6 s'insèrent **d'un seul tenant** entre §6.3.4 et §6.4. **L'ORDRE COMPTE** : §6.5 renvoie
> déjà en dur à « §6.3.7 » pour le balayage mémoire, numéro qu'A5 prend seulement si les trois
> autres sont placées comme indiqué.
>
> **2. UNE RÉPARATION BLOQUANTE : la table ASOS (p. 24) n'a pas été remplacée.** §6.4.6 affirme
> maintenant que les chiffres sont mesurés sur CVA6 à 50 MHz, et la table juste au-dessus est
> restée l'ancienne — six lignes **par événement**, en **cycles émulés sous QEMU**, légende
> « in the virtualized RISC-V platform » comprise. Les deux jeux diffèrent d'un **facteur mille**.
> Le texte renvoie deux fois à une « Table 8 » **qui n'existe pas** : renvoi en dur, donc LaTeX ne
> signale rien. C'est la seule incohérence qu'un relecteur voit sans chercher.
>
> **3. DIX AUTRES RÉPARATIONS**, par ordre de gravité :
> - **L'équation (4) a été supprimée et reste citée trois fois** (deux fois §6.3.3, une fois
>   §6.4.6). L'équation ASOS a pris le numéro (4) alors que le texte l'appelle « Equation 5 »,
>   d'où le `(5)  (4)` visible p. 24. L'artefact donne le bloc qui la rétablit.
> - **La Table 5 porte encore trois lignes d'avant correctif** — SC-02 « 4,9 par fenêtre, pic 10 »
>   et « verdict sur 79,5 % », SC-03 « block once 16 are in flight », SC-04 « 93,9 % ». Elles
>   annoncent en page 21 le contraire de ce que la page 22 mesure.
> - **« 21 campagnes » subsiste** dans la légende de la Table 6 et dans §6.3.3, alors que la borne
>   de 0,11 % annoncée dans l'abstract suppose les **55**. À 21, la règle de trois donne 0,29 %.
> - **§6.5, collision de collage** : le paragraphe de la conclusion a été collé à l'intérieur du
>   mot « exhaustively ».
> - **§6.6 et §7 annoncent toujours une sensibilité aux faux positifs** du moniteur de débit, que
>   §6.3.2 vient de chiffrer à **zéro** sur 55 campagnes.
> - **Trois `??` dans le PDF** (§6.2.3, ligne SC-08 de la Table 5, légende Table 6) et six
>   `\label` à poser sur l'existant : `tbl:rtl`, `tbl:configs`, `tbl:scenarios`, `tbl:detection`,
>   `sec:accuracy`, `sec:cost`.
> - Abstract : une phrase à ajouter sur l'angle mort, si A5 est retenue.
> - §3.3 : un item de classe d'attaque à ajouter, sinon SC-08 figure en Table 5 sans être déclarée.
>
> **4. CORRECTION DE CHIFFRE — le pic du générateur de fond est 4, pas 3.** Vérifié sur les 704
> relevés `ARMORCNT,*,w1` des campagnes du 15/09 : 376 fenêtres à 3, **164 à 4**, jamais plus.
> C'est cohérent avec le balayage (seuil 4 → 0 déclenchement, seuil 3 → ~59 000), le moniteur
> déclenchant sur **dépassement** strict. L'annexe III.3 de l'artefact disait 3 ; corrigé.
>
> **CE QUI RESTE FACULTATIF** : (i) **A6 n'est pas recommandée sans réserve** — résultat
> conditionnel, absent de la configuration évaluée, et rien d'autre n'en dépend si elle est coupée ;
> (ii) **rejouer la campagne ASOS sur le v18** — une heure de carte — ce qui supprimerait la
> troisième limite que §6.6 doit sinon concéder : les chiffres de la table ASOS ont été pris sur un
> bitstream antérieur, sur un chemin (délivrance d'interruption par l'hyperviseur) que le correctif
> d'écriture ne touche pas, mais sans re-mesure.

> ### 2026-09-15 (nuit) — **QUATRE POINTS D'AMÉLIORATION TRAITÉS ; artefact v28**
>
> *(Dépassé par le bloc du 18/09 ci-dessus.)* Il ne reste **que le report des 25 étapes dans le LaTeX**. Aucune mesure
> n'est en attente. 201 campagnes au total sur le v18, toutes vérifiées.
>
> **1. Surface resynthétisée sur le RTL PUBLIÉ.** L'ancienne mesure datait d'avant le v18 :
> elle décrivait un wrapper sans seuils configurables. Mécanisme seul **1 637 LUT / 1 151 FF**
> (0,80 % / 0,28 % du device), instrumenté **3 443 / 2 514**, marge **+14,542 ns** sans
> instrumentation et +14,279 avec, zéro endpoint en faute. **PIÈGE** : la synthèse hors contexte
> optimise un module isolé, elle ne retrouve donc PAS les +131 LUT mesurés dans le design
> complet. Les deux chiffres valent dans leur contexte et **ne se soustraient pas**.
>
> **2. Référence portée à 55 campagnes** (2 750 injections/classe) → borne de la règle de trois
> **0,11 %**, celle que l'article annonçait, mais sur la plateforme qu'il publie. 34 campagnes
> ajoutées, toutes 50/50. **ATTENTION à l'ambiguïté** : le pré-correctif comptait AUSSI 55
> campagnes. Toujours nommer la plateforme, jamais le nombre de campagnes seul.
>
> **3. Latences regroupées sur les 55** : usurpation **≤ 1 cycle** (2 695 verdicts), tempête
> **≤ 30**, MSI **≤ 49**. L'artefact annonçait 31 pour le MSI — c'était du pré-correctif.
>
> **4. SC-09 : un A/B à UN BIT PRÈS, et c'est le meilleur résultat de la journée.**
>
> | profondeur | fronts (`RFMCNT=0`, config de référence) | transferts (`RFMCNT=1`) |
> |---|---|---|
> | 2 | 0,0 | 0,0 |
> | 4 | 0,0 | 0,0 |
> | **8** | **0,0** | **43,5 ± 1,9** |
> | **16** | **0,0** | **50,0 ± 0,0** |
>
> Six campagnes par case, 48 au total, même bitstream, même attaquant, fond actif, aucun gel.
> **Un attaquant qui pipeline ses adresses est invisible à un moniteur qui compte des FRONTS** :
> la rafale arrive comme une seule assertion continue, pas comme des événements séparés. C'est
> un argument de CONCEPTION de moniteur, et il démontre enfin le bit `RFMCNT` que le RTL porte
> depuis le 11/09 sans justification.
>
> **DEUX RÉSERVES à porter avec :** (i) SC-09 n'est détectable qu'**en dehors** de la config de
> référence (`CTRL=0x331` ⇒ `RFMCNT=0`) — il ne peut PAS rejoindre la Table 6 comme cinquième
> classe contenue, il se présente comme un résultat **conditionnel** ; (ii) la campagne unique
> citée jusqu'ici donnait 49/50 à profondeur 8, six campagnes donnent **43,5**. Comme pour
> CFG-C, **le run isolé flattait** — c'est la deuxième fois aujourd'hui.
>
> **Pour lancer SC-09** : `-DBENCH_SC09 -DBENCH_SC09_DEPTH=n`, et **impérativement**
> `-DARMOR_RFMCNT=1 -DARMOR_BFATE=1` pour le bras détectant (le firmware avertit lui-même :
> sans BFATE, seize AW en vol font décrocher le canal B).
>
> **CE QUI RESTE, ET QU'AUCUNE MESURE NE RÉSOUT** (porté dans la checklist de l'artefact) :
> tout repose sur **un seul couple d'accélérateurs et un seul profil de trafic** — la
> recommandation « borne 8 » vaut pour CETTE charge ; il n'y a **aucune comparaison quantitative
> avec l'état de l'art**, alors que le § 4.5 revendique les cinq mécanismes AXI4 comme
> contribution citable ; et la **Table 8 (ASOS) a été mesurée sur un bitstream antérieur**
> (chemin d'interruption, a priori insensible au correctif, mais non revérifié).

> ### 2026-09-15 (soir) — **L'ARTICLE PASSE SUR LA PLATEFORME RÉPARÉE (option B)**
>
> *(Dépassé par le bloc du 18/09 ci-dessus.)* 119 campagnes sur le v18, toutes vérifiées (MAGIC, fin de campagne,
> relecture du registre). Journaux dans `results/`, colonne de contrôle dans
> `results/mesures_2026-09-15_v18.csv`. Artefact **version 27**, réécrit pour l'option B.
> **Il reste à reporter les 25 étapes dans le LaTeX** — c'est le seul travail en attente.
>
> **1. DÉCISION : Section 6 est évaluée sur la plateforme RÉPARÉE.** Les trois motifs du 14/09
> en faveur du pré-correctif sont tombés : (i) il existe maintenant **21 campagnes post-correctif
> FOND ACTIF**, donc comparables ; (ii) le mécanisme est établi (§ 3 ci-dessous) ; (iii) l'argument
> « non exhaustif » est mieux servi par le balayage de seuil, délibéré et reproductible, que par
> un défaut de datapath. Motif décisif : **les chiffres pré-correctif ne sont plus reproductibles
> depuis le dépôt** (correctif commité, v18 archivé).
>
> **2. BALAYAGE DU SEUIL DE FLUX — pas de falaise, une décroissance régulière** (6 campagnes/point) :
>
> | seuil | 3 | 4 | 5 | 6 | 8 | 9 | 10 | 12 | 16 |
> |---|---|---|---|---|---|---|---|---|---|
> | SC-02 | 50,0 | 50,0 | 50,0 | 50,0 | **50,0** | 49,8 | 44,8 | 25,0 | 16,8 |
> | écart-type | 0,00 | 0,00 | 0,00 | 0,00 | 0,00 | 0,41 | **2,79** | 1,90 | 2,14 |
>
> SC-04 vaut 50,0 ± 0,0 **partout** (borne propre, c'est le témoin). **La dispersion est la
> signature de la frontière** : nulle loin du seuil, 2–3 points dessus. Les 8,6 points du
> pré-correctif étaient le symptôme d'un moniteur qui travaillait sur sa frontière.
>
> **3. LE MÉCANISME DU CORRECTIF, ÉTABLI — et ce n'est PAS le pacer.** ARMOR est en AMONT du
> pacer, qui ne peut rien changer à ce qu'il voit. **C'est le mux 4 → 16** : l'accélérateur
> présente ses 16 adresses coup sur coup au lieu d'être étranglé à 4, et le pic d'occupation
> passe de 10 à **16 — la rafale entière dans une fenêtre**. La réserve (ii) de l'appendice III.7
> est levée.
>
> **4. DEUX PIÈGES DE COMPTEUR, tous deux coûteux, tous deux à retenir :**
> - **`reqmax` est ÉCRÊTÉ par le seuil.** Le verdict remet le compteur à zéro, donc il lit 3 au
>   seuil 3, 8 au seuil 8, 16 au seuil 16. **On lit le seuil, pas le trafic.** Le vrai pic exige
>   `-DARMOR_ENFORCE=0` : six campagnes donnent 16 sans un écart.
> - **La colonne FP du résumé ne voit pas le fond LHA** (il n'est pas un scénario noté). Au
>   seuil 3 elle affiche 0 alors que le wrapper w1 se déclenche **58 919 à 59 090 fois**. Lire le
>   compteur `storm` de w1. Plancher sans faux positif : **seuil 4**.
> - Accessoirement : la bannière « LHA background CONTINU armé » est imprimée
>   **inconditionnellement**. Elle ne prouve rien ; seule l'absence de « fond LHA DESACTIVE » le fait.
>
> **5. SC-03 N'EST PAS CONTENU PAR ARMOR à la borne de synthèse.** Les 50 injections échouent,
> mais le moniteur ne tranche que **0,8 fois sur 50 (1,6 %)** : le reste expire sur le **timeout
> du maître à 65 685 cycles**. Balayage de la borne d'en-vol, 6 campagnes/point :
>
> | borne | 4 | 8 | 12 | 16 (synth) | 24 |
> |---|---|---|---|---|---|
> | verdicts | 50,0 | **43,3** | 1,3 | **0,8** | 1,0 |
> | latence Lp50 | 159 | **226** | 65 685 | 65 685 | 65 685 |
>
> **Ne JAMAIS publier 65 685 comme une latence de détection** : c'est le timeout du maître. La
> latence du moniteur vaut 226 cycles. Et la Table 6 doit afficher **1,6 %**, pas 100 %.
> Contention rejouée : fond coupé borne 16 → 20,2 verdicts ; fond actif borne 8 → **43,3**. Le
> moniteur n'est pas aveugle, **sa borne est calibrée sur l'attaquant isolé**.
>
> **6. TABLE 4 : les quatre configurations à six campagnes.** CFG-A 50,0 ± 0,0 ; CFG-B 50,0 ± 0,0 ;
> **CFG-C 36,2 ± 0,9** ; CFG-D 50,0 ± 0,0 avec SC-03 à 158 cycles. Décomposition de CFG-C : le
> seuil 16 SEUL donne 16,8, et la fenêtre 200 en récupère les deux tiers (36,2). **Les deux
> paramètres ne sont pas interchangeables** — citer le couple, jamais l'un seul.
>
> **7. Groupé de référence : 21 campagnes**, 1 050 injections par classe, borne de la règle de
> trois **0,29 %**. Usurpation, tempête et MSI exhaustives, écart-type nul. Zéro faux positif
> dans les 119 campagnes, seuil 3 excepté.

> ### 2026-09-15 (matin) — **v18 VALIDÉ SUR CARTE : les quatre configurations de la Table 4 sont mesurées**
>
> *(Bloc du matin, conservé : c'est la validation du v18 elle-même. Le bitstream est archivé
> depuis, et les chiffres de la Table 4 sont repris à six campagnes dans le bloc du soir.)*
>
> **Le v18 est validé.** Non-régression CFG-A d'abord, puis les quatre lignes de la Table 4,
> toutes sur le même bitstream, sans resynthèse entre elles — ce que le v18 devait précisément
> rendre possible. MAGIC `…012` vérifié au début de CHACUNE des quatre campagnes.
>
> | | `0x110` relu | CTRL | SC01 | SC02 | SC03 | SC04 | faux positifs |
> |---|---|---|---|---|---|---|---|
> | **CFG-A** (référence) | non écrit | `0x331` | 50/50 | 50/50 | 50/50 | 50/50 | **0** |
> | **CFG-B** (`XFER_SIZE=512`) | non écrit | `0x331` | 50/50 | 50/50 | 50/50 | 50/50 | **0** |
> | **CFG-C** (seuils relâchés) | `0x002000c8` | `0x100331` | 50/50 | **36,2 ± 0,9** | 50/50 | 50/50 | **0** |
> | **CFG-D** (seuils resserrés) | `0x02080032` | `0x40331` | 50/50 | 50/50 | 50/50 | 50/50 | **0** |
>
> Journaux : `results/bench_2026-09-15_103551.log` (A), `103829` (B), `103909` (C), `103948` (D).
> Bras répétés : `1048{55}`/`1049{04,13,21,31,40}` (CFG-C ×6) et `1050{05,13,21,30,38,46}` (CFG-A ×6).
>
> **1. `0x110` N'EST PAS INERTE — c'est prouvé deux fois, et par le comportement, pas par une
> relecture.** La relecture concorde (`0x002000c8`, `0x02080032`, aucune ligne `ATTENTION`),
> mais c'est l'effet mesuré qui compte :
> - **CFG-C fait TOMBER SC02 de 50,0 ± 0,0 à 36,2 ± 0,9**, sur **six campagnes par bras** jouées
>   d'affilée sur le même bitstream : référence 50/50 six fois, CFG-C **35, 36, 37, 36, 38, 35**.
>   **Les fourchettes ne se chevauchent pas** et l'écart de 13,8 points s'appuie sur une
>   dispersion inférieure au point. Seuil de flux 8 → 16 sur une fenêtre de 200.
>   **PIÈGE** : la campagne unique du matin donnait **38, le HAUT de la fourchette** — publier 36,2.
> - **CFG-D fait s'effondrer la latence de détection de SC03 : `Lp50` 65685 → 158 cycles**,
>   soit **416×**. À `MAX_OUTS` 8 au lieu de la valeur de synthèse, le moniteur d'en-vol tranche
>   presque immédiatement au lieu de laisser la transaction saturer le timeout du maître. C'est
>   le résultat le plus fort de la journée et il n'était pas prévu : jusqu'ici SC03 saturait
>   TOUJOURS, et le § 4 du 14/09 le notait comme une limite (« SC03 sature au timeout »). Cette
>   limite est un ARTEFACT DU SEUIL, pas une propriété du moniteur.
>
> **2. Zéro faux positif dans les seize campagnes**, y compris CFG-D qui resserre les trois
> seuils à la fois (fenêtre 50, en-vol 8, échecs 2). SC06/SC07 (bénins lecture), SC08 (bénin
> écriture) et SC10 (balayage) restent tous à FP=0. SC01/SC03/SC04 sont à 50/50 dans les douze
> campagnes des deux bras répétés, et la latence SC03 y vaut 65 685 au cycle près.
>
> **3. Non-régression CFG-A contre le v17** (campagne `bench_2026-09-14_134259.log`) :
> les huit scénarios donnent des verdicts **identiques** (TP/FP/FN/TN au chiffre près), et
> l'étendue du balayage SC10 est reproduite au bit près — `amin=0x92000000`, `amax=0x920ff000`,
> `apages=256`, `pgchg=699`. Seul `winact` bouge de quelques unités (13483 vs 13497) : jitter du
> trafic de fond. L'élargissement des deux compteurs et le déplacement de la comparaison
> d'échecs n'ont rien cassé.
>
> **4. CFG-B coûte ~70 cycles partout** (SC06 `Lp50` 225 → 297, SC07 225 → 291) sans changer un
> seul verdict : c'est le profil P-BURST, transfert 8× plus gros, et il ne déplace pas les
> frontières de détection.
>
> **LE BITSTREAM PEUT MAINTENANT ÊTRE ARCHIVÉ** (`tools/bitstream.sh save bench`) : la réserve
> du 14/09 est levée, le v18 a quatre campagnes valides. `bitstreams/` contient encore le v17.
>
> ---
>
> **PIÈGE DE LA CHAÎNE JTAG, ET IL A COÛTÉ UNE MATINÉE ENTIÈRE.**
>
> **`2_build_HB.sh program` / `tools/program_fpga.sh` échouent À LA PREMIÈRE PASSE et
> réussissent À LA SECONDE. Il faut les lancer DEUX FOIS.** Le mécanisme est visible dans les
> logs Vivado : la passe qui échoue ouvre la cible
> `…/Digilent/`**`200300BB8B2C`**, celle qui réussit ouvre `…/Digilent/`**`200300BB8B2CB`** —
> le numéro de série est **tronqué d'un caractère** tant que `hw_server` vient d'être lancé.
> La seconde passe, sur un `hw_server` déjà chaud, retrouve le nom complet et programme
> (`End of startup status: HIGH`).
>
> **Corollaire, et c'est là qu'on se perd : NE PAS TUER `hw_server` ENTRE LES DEUX PASSES.**
> Un `pkill` entre chaque essai condamne à ne jamais jouer que la première, donc à échouer
> indéfiniment. Le 15/09 la matinée est passée là-dessus, avec un diagnostic qui s'enfonçait :
> alimentation, câble, rails du FPGA, jusqu'à conclure à tort à une panne matérielle. **Aucune
> de ces pistes n'était la bonne, la carte n'a jamais eu le moindre défaut.**
>
> Ce qui a été mesuré pendant cette errance reste vrai et vaut d'être gardé :
> - `all ones` sur la chaîne signifie « personne ne pilote TDO » — PAS « carte éteinte ». Un
>   FPGA alimenté mais vierge répond quand même à l'IDCODE.
> - **Le FT2232H est alimenté PAR LA CARTE** (`bMaxPower = 0mA`, il ne tire rien du bus) : il
>   disparaît de `lsusb` sur OFF, revient sur ON. `lsusb | grep 0403:6010` est donc un témoin
>   FIABLE de l'alimentation. Le FT232R de la console (`0403:6001` → `ttyUSB0`) est sur son
>   propre câble et reste visible en permanence : lui ne prouve rien.
> - OpenOCD lancé sur la chaîne AVANT programmation lit forcément `all ones` : le TAP déclaré
>   dans `openocd_genesys2.cfg` est celui du CVA6, qui n'existe qu'une fois le bitstream chargé.
>   **Ce n'est pas un test d'alimentation** — c'était l'erreur de lecture de départ.

> ### 2026-09-14 (soir) — v18 SYNTHÉTISÉ MAIS **NON VALIDÉ SUR CARTE**
>
> **Le détail de ce qui reste à faire est ici.** Le v18 rend configurables les **trois
> derniers seuils de détection**, ceux que la Table 4 de l'article fait varier et qui
> étaient figés à la synthèse :
> registre **`0x110 CFG_PARAMS`** — `[15:0]` largeur de fenêtre, `[23:16]` seuil d'en-vol,
> `[31:24]` échecs consécutifs. Convention du seuil de flux : **zéro = valeur de synthèse**,
> donc un firmware qui ignore le registre ne change rien. MAGIC **v18** (`0x…012`).
>
> **Synthèse faite** : WNS **+0,061 ns**, 0 endpoint en faute, 109 518 LUT / 74 493 bascules,
> soit **+131 LUT et +84 bascules** sur le v17 pour les trois seuils. **ATTENTION : la marge
> a fondu** (+0,154 → +0,061 ns). Encore positive, mais c'est la plus serrée du projet. Pour
> en regagner : ramener la fenêtre à 12 bits (4095 couvre les 200 de CFG-C) ou registrer les
> comparaisons de seuil.
>
> **CE QUI N'EST PAS FAIT : aucune campagne sur le v18.** Le bitstream est dans `build/hw/`
> mais **PAS archivé** — `bitstreams/` garde le **v17**, qui lui est validé (7 campagnes).
> Ne pas faire `tools/bitstream.sh save bench` avant d'avoir validé le v18 sur carte, sinon
> on perd la seule archive éprouvée. Secours : `build/hw/ariane_xilinx_v17_scan.bit`.
>
> **Les quatre campagnes de la Table 4**, prêtes à jouer (le firmware sait écrire `0x110`) :
>
> ```
> CFG-A   (référence, aucun flag)
> CFG-B   -DXFER_SIZE=512
> CFG-C   -DARMOR_THRESH=16 -DARMOR_WINDOW=200 -DARMOR_MAXOUTS=32
> CFG-D   -DARMOR_THRESH=4  -DARMOR_WINDOW=50  -DARMOR_MAXOUTS=8 -DARMOR_MAXFAIL=2
> ```
>
> **Commencer par CFG-A en non-régression** : le RTL des trois moniteurs a changé (compteurs
> de fenêtre et d'en-vol élargis, comparaison d'échecs déplacée). Vérifier **MAGIC `…012`**
> — une campagne du 14/09 15:02 a tourné sur le v17 sans que rien ne le signale, parce que le
> flash avait échoué et que le `| tail` du script masquait son code de retour.
>
> **PIÈGES DE LA CHAÎNE JTAG, rencontrés ce jour :**
> - `2_build_HB.sh program` (Vivado) exige que **`ftdi_sio` soit détaché** : `sudo modprobe -r
>   ftdi_sio`, flasher, puis `sudo modprobe ftdi_sio` pour retrouver `/dev/ttyUSB0`. Sans ça,
>   « No devices detected on target …/Digilent/… » alors que le câble EST vu.
> - « No matching hw_devices were found » (sans nom de câble) = Vivado ne voit pas le câble :
>   débrancher/rebrancher le PROG a suffi.
> - **`JTAG scan chain interrogation failed: all ones`** = **rien ne pilote TDO**. La cause la
>   plus courante est un FPGA non alimenté, mais **ce n'est pas la seule** — voir la mesure du
>   15/09 ci-dessous, où la carte était sous tension et la chaîne restait vide. C'est là-dessus
>   que la session du 14 s'est arrêtée.
> - **CORRECTION DU 2026-09-15 : le FT2232H est alimenté PAR LA CARTE, pas par l'USB.** La note
>   d'origine disait l'inverse et a coûté plusieurs rallumages à l'aveugle. Vérifié en basculant
>   l'interrupteur : sur OFF le `0403:6010` **disparaît** de `lsusb` (et `ttyUSB1`/`ttyUSB2`
>   avec lui), sur ON il revient. **`lsusb | grep 0403:6010` est donc un témoin FIABLE de
>   l'alimentation de la carte** — c'est le test à faire en premier, il ne coûte rien. Le
>   FT232R de la console (`0403:6001` → `ttyUSB0`), lui, est sur son propre câble USB et reste
>   visible en permanence : c'est celui-là qui ne prouve rien.
> - OpenOCD (`capture_uart.sh -j`) et Vivado ne se partagent pas le câble : un seul à la fois.
>
> **Artefact « article » : version 24**, restructuré en **parcours linéaire de 25 étapes**
> dans l'ordre du manuscrit, chacune marquée *Change* (le passage à remplacer, cité en entier)
> ou *Add* (la sous-section à créer, avec son point d'insertion). Tables 5 et 6 fournies **en
> LaTeX** aux étapes 7 et 9. Le balayage mémoire y est **SC-08** (pas SC-09).


> ### 2026-09-14 — LE BALAYAGE MÉMOIRE : LA PREMIÈRE ATTAQUE QU'ARMOR NE PEUT PAS VOIR
>
> **Bitstream v17 archivé** (`tools/bitstream.sh use bench`, MAGIC `0x…011`), WNS **+0,154 ns,
> 0 endpoint en faute**, 109 387 LUT / 74 409 bascules.
>
> **1. SC-08 (« low-and-slow », SC-05 du papier) N'EST PAS UNE ATTAQUE.** Son firmware émet
> `fire_one('M', 0 /* mode normal */, LEGIT_DST, 0 /* write */)` × 700 : c'est le trafic
> légitime joué sept fois plus longtemps. SC07 et SC08 donnent **264 ticks au tick près** et
> une requête par fenêtre chacun. Son « 0 % de détection » mesurait donc l'ABSENCE DE FAUX
> POSITIF. **Il est reclassé comme profil bénin en ÉCRITURE** — le seul de l'évaluation, et
> celui qui manquait pour étayer le « +1 cycle par écriture légitime » du § 6.3.3. Corollaire :
> la réserve « la latence d'écriture légitime n'est pas mesurée » TOMBE (264 ticks, inchangés
> de part et d'autre du correctif du gel).
>
> **2. NOUVEAU : mode 8 de `accel_wrap` (BALAYAGE) + registres d'étendue dans le wrapper.**
> Le mode 8 émet **une requête par lancement — la cadence du mode 0** — mais avance d'une page
> à chaque transfert, DANS la région guest autorisée. Deux registres neufs :
> `0x100 ADDR_SPAN` (min/max d'adresse) et `0x108 ADDR_WALK` (changements de page). L'index CSR
> passe à **6 bits** (les 32 emplacements étaient pleins ; fenêtre MMIO de 4 Kio, rien n'est
> empiété). Scénario firmware `SC10-SCAN`, 700 requêtes sur 256 pages depuis `0x92000000`.
>
> **RÉSULTAT, 6 campagnes du 2026-09-14 (`results/bench_2026-09-14_13*.log`)** :
>
> | | req/fenêtre | pages | chgts page |
> |---|---|---|---|
> | fond LHA légitime continu | 3 | 1 | 0 |
> | SC07 bénin lecture | 1 | 1 | 0 |
> | SC08 bénin écriture | 1 | 1 | 0 |
> | **SC10 balayage** | **1** | **256** | **699** |
> | SC02 / SC04 / SC03 | 8 / 8 / 20 | 1 | 0 |
>
> **700 requêtes émises, 700 acheminées, 0 bloquée.** Aucun seuil franchi, l'IOMMU n'a rien à
> dire (l'attaque reste dans ses droits). **256 pages et 699 changements DANS CHACUNE des six
> campagnes, sans une unité d'écart** — c'est structurel, pas statistique : à publier comme une
> ÉTENDUE, jamais comme un taux de détection. Témoin exact : SC08 et SC10, même volume, même
> cadence (266 ticks), même région ; seule l'étendue diffère. **Non-régression v17 dans les
> mêmes runs** : SC01/SC02/SC03/SC04 tous 50/50, zéro faux positif.
>
> **3. SURFACE : le chiffre publié ne mesurait pas le mécanisme.** Macro `` `OBS() `` dans
> `wrapper.sv` + `ARMOR_NO_OBSERVE` : les 26 registres d'enquête renvoient zéro et la synthèse
> les élague. `armor/ooc/run_ooc.sh noobs` donne **1 680 LUT / 1 110 FF = le MÉCANISME**
> (0,82 % du device, WNS +14,1 ns) contre **3 359 / 2 467 pour le wrapper mesuré** :
> **l'instrumentation pèse la moitié des LUT et 55 % des bascules.** C'est 1 680 qu'il faut
> publier, en mentionnant que toutes les mesures viennent du wrapper instrumenté.
>
> **4. LATENCE DE DÉTECTION : mesurée, plus dérivée.** Les lignes `ARMORLAT` des campagnes la
> donnent depuis toujours. Sur 19 campagnes de référence : usurpation bloquée **en 1 cycle au
> plus** (931 verdicts), tempête ≤ 37, MSI ≤ 31 ; minimum 0 partout. L'équation (4) du papier
> (≈116 cy) borne autre chose — l'accumulation de `N_failures` avant l'IRQ. **PIÈGE** : sans
> verdict, le compteur enregistre la durée TOTALE de la transaction, donc la MOYENNE mélange
> détectées et non détectées — ne publier que le MAX. Et SC03 sature au timeout du maître.
>
> **5. Correctif d'inférence du pacer** : `aw_mem`/`w_mem` sorties du bloc à reset asynchrone
> → RAM distribuée (`RAM32M`/`RAM32X1D`) au lieu de bascules. Rend **4 663 bascules**, WNS
> −0,007 → **+0,177 ns**, warning `Synth 8-7137` disparu, banc identique au cycle. Registrer un
> étage du pacer s'est avéré INUTILE.
>
> **Artefact « article » à jour** : version 19, restructuré en **trois parties** — I ce qu'il
> faut MODIFIER (21 éditions), II ce qu'il faut AJOUTER (6, avec point d'insertion exact),
> III les mesures. L'autre artefact est périmé et pointe vers celui-ci.


> ### 2026-09-14 — DÉCISION PLATEFORME POUR L'ARTICLE : **A, plateforme PRÉ-FIX**
>
> **Le problème posé.** Le correctif du gel mode 7 (mux 4→16 + `axi_wr_pacer`, ci-dessous)
> ne fait pas que dégeler la carte : **il déplace les verdicts rate-based**. À bitstream et
> `CTRL` identiques (v16, `0x1731`), fond LHA désactivé dans les deux bras :
>
> | sur 50 | avant le correctif (2 campagnes) | après (5 campagnes) |
> |---|---|---|
> | SC02 storm | 39, 45 | **50, 50, 50, 50, 50** |
> | SC04 MSI | 44, 47 | **50, 50, 50, 50, 50** |
> | SC03 outstanding | 50, 50 | 50 ×5 |
> | faux positifs | 0 | 0 |
> | latence légitime (médiane) | 266 | 266 |
>
> Logs : `results/bench_2026-09-13_1533{53,427}.log` (avant) et `204335`, `2229{04,36}`,
> `2230{12,36}` (après). **SC09 (tempête pipelinée) devient détectable** : 0/50 à d=2 et d=4,
> **49/50 à d=8, 50/50 à d=16** — avant, d≥8 gelait la carte.
>
> **DÉCISION (14/09) : l'article reste évalué sur la plateforme PRÉ-FIX.** Les chiffres
> publiés (55 campagnes, fond actif, moniteurs NON exhaustifs 79,5 % / 93,9 %) restent
> valides ; le gel et son correctif sont rapportés comme *finding*, avec **une phrase ajoutée
> au § 6.5** disant ce que le correctif fait aux verdicts et pourquoi ce n'est pas comparable.
> Aucune campagne à refaire pour cette soumission.
>
> **Trois réserves attachées à ce résultat, à lever si on veut un jour publier la plateforme
> corrigée** : (i) le fond LHA était **désactivé dans les deux bras** → non comparable au
> pooled de la Table 6 ; (ii) **le mécanisme n'est pas établi** — le pacer est en AVAL
> d'ARMOR, pourquoi la détection MONTE n'est expliqué par aucune mesure (le registre
> d'occupation de fenêtre `0x38` trancherait en une campagne) ; (iii) **la latence d'une
> écriture légitime n'a jamais été mesurée** — les deux profils bénins sont des LECTURES,
> donc l'effet de `MAX_WR_TXN=1` sur le trafic légitime en écriture est inconnu.
>
> **Artefact « article » à jour** : `ARMOR–ASOS Revision Dossier`, version 10 du 14/09
> (https://claude.ai/code/artifact/392ced50-8c6a-4781-849c-921e9b2e6e68) — sections 1, 6, 11
> et 12 revues. L'autre artefact, `ARMOR–ASOS Revision Notes` (12/09), est **périmé** : il a
> été remplacé par le Dossier, ne pas y revenir. **Report des corrections dans le papier :
> À LA MAIN** (les sources LaTeX ne sont pas sur ce PC ; le PDF seul ne s'édite pas).
> Le manuscrit `~/Téléchargements/Papier_JSA.pdf` recompilé le 14/09 n'a encore **aucune**
> révision appliquée : « 326K LUTs », « Vivado 2022.1 », Table 7 et Table 8 sont intacts.


> ### 2026-09-13 (soir) — GEL MODE 7 (SC09) DIAGNOSTIQUÉ ET CORRIGÉ, VALIDÉ SUR CARTE
>
> **Le problème.** Le mode 7 de `accel_wrap` (tempête PIPELINÉE : N adresses d'écriture EN VOL
> AVANT la moindre donnée, profondeur réglable via le registre `0x40`) GÈLE le SoC à
> profondeur ≥ 8 (d2/d4 passent, d8/d16 gèlent — gel non déterministe : parfois la 1ʳᵉ
> itération de SC09, parfois le `*ctrl=1` du scénario suivant). Cause : le décalage
> AW-avant-W du mode 7 face à une **capacité d'outstanding-write FINIE** en aval. **Ni ARMOR**
> (au gel : `sticky=0`, `STATUS[22]/[24]=0`, file B_FATE 8/64, zéro orphelin — falsifie
> l'ancienne hypothèse « débordement B_FATE »), **ni SC04, ni l'IOMMU en soi.**
>
> **Certitude (triple).** (a) `armor/tb` (VRAI accel + VRAI ARMOR) : `PIPE=1 PIPEDEPTH=8
> RFMCNT=1 … DN_AWOUT=4 DN_WGATE=1` → gel (« AW SANS W EN AVAL : 4 — condition du gel
> carte »), `DN_AWOUT=8` → passe. (b) Carte : frontière d4/d8. (c) Banc `riscv_iommu`
> (`armor/tb/run_iommu_sim.sh`, mode Bare) : reproduit l'interblocage.
>
> **LE CORRECTIF (validé carte le 2026-09-13, d2/d4/d8/d16 tous COMPLETS ; avant d8/d16
> gelaient). Il est HYBRIDE — les deux morceaux sont nécessaires :**
> 1. `ariane_peripherals_xilinx.sv`, `axi_mux_intf` du chemin DMA : **`MAX_W_TRANS` 4 → 16**
>    (le mux à 4 = 1er goulot = frontière carte ; le relever seul échoue → le goulot passe
>    en aval à <8).
> 2. **`axi_wr_pacer` inséré APRÈS le mux** (`dma_muxed`→IOMMU, bloc `gen_accel2`),
>    `MAX_WR_TXN=1` : le mux à 16 laisse l'accel vider ses 16 AW dans le FIFO du pacer, qui
>    débite ≤1 AW-sans-W vers l'aval partagé (IOMMU/XBAR/DRAM). Module :
>    `cva6-overlay/corev_apu/fpga/src/axi_wr_pacer.sv` (commit `ebc77b5`), validé isolément
>    par `armor/tb/tb_pacer.sv` (`run_pacer.sh` : sans pacer N≥8 gèle à MAXOPEN=4, avec pacer
>    N=16 passe).
>
> **RÉSERVES à traiter avant de figer.** (i) **Timing WNS = −0.008 ns** (8 ps ; négligeable à
> 50 MHz, carte OK, mais techniquement en faute) → registrer un étage du pacer + corriger le
> warning `Synth 8-7137` (FIFO `aw_mem` non resettée), puis resynthèse pour WNS positif.
> (ii) **`MAX_WR_TXN=1` sérialise TOUTES les écritures DMA** → il CHANGE le régime d'écriture
> vu par ARMOR : latences ET verdicts *rate-based* bougent (mesuré : storm ~78 %→~100 %, plus
> MSI, occupation de fenêtre, balayage de seuil). **INCHANGÉS** : ID spoofing, outstanding
> (ce sont des lectures), réaction ASOS. **Conséquence pour l'article** : si le bitstream
> corrigé devient la plateforme publiée, il faut REMESURER la Section 6 (chemin d'écriture) ;
> sinon garder la plateforme pré-fix (chiffres valides) et rapporter le fix comme *finding*.
> Relevable (la correction du gel vient du pacing AW-après-W, pas du crédit).
>
> **Bitstream corrigé** : dans `build/hw/` et `cva6/corev_apu/fpga/work-fpga/` (BENCH_PROFILE,
> genesys2). Reconstructible : le RTL est commité, `BENCH_PROFILE=1 RISCV=/usr make -C cva6 fpga`.
>
> **Drapeaux de diagnostic firmware ajoutés** (`bao-baremetal-guest/src/bench_runner.c`,
> commits `42cf5a6`, `2412293`, inertes par défaut) : `BENCH_SC09_QUIESCE_CY`,
> `BENCH_SC04_FIRST`, `BENCH_SC09_N`.
>
> **Prochaines étapes** : (1) nettoyer le timing + resynthèse ; (2) commiter le bitstream
> corrigé (`tools/bitstream.sh`) ; (3) éventuellement relever `MAX_WR_TXN` et remesurer les
> latences pour l'article ; (4) mettre l'artefact « article » à jour. **Mémoire détaillée** :
> `~/.claude/.../memory/sc09_wedge_mode7.md` (locale — non versionnée, cf. § multi-PC).


> **Bitstream v14 synthétisé et archivé le 2026-09-13 à 01h30** (§ 5 quater) : compteur de
> fenêtre saturant, `CTRL[12]`, occupation de fenêtre en `0x38`, file de sort à 64,
> `w_owed` à 8 bits, et le mode 7 de `accel_wrap` (tempête pipelinée). `check bench` dit
> À JOUR. **Aucune campagne carte n'a encore été jouée dessus** : tout ce qui suit sur le
> v14 vient du banc. Pour rejouer une campagne v13, revenir au RTL de `a80e162`.

**Configuration de référence, VALIDÉE SUR CARTE : `W_SKID + FRESH + RESP_HOLD + W_FATE`**
(`CTRL` relu `0x331`). **Bitstream archivé : v13** (`d4836ae`) — `tools/bitstream.sh use
bench`, puis `check bench` doit dire À JOUR. `B_FATE` (`CTRL[10]`, `0x731`) y est **sûr mais
sans gain mesurable** : à activer ou non, la détection est la même (voir plus bas). Le v13
ajoute `CTRL[11] IRQ_EN` et la sortie `irq_o` (§ 5 ter) ; à son reset le bit vaut 0, `irq_o`
est constamment bas et **le v13 se comporte exactement comme le v12**, donc toutes les
campagnes archivées restent comparables.

**Validation de `W_FATE` sur carte, 2026-09-11 17:00**, même bitstream v10, chargement par
`capture_uart.sh -j` :

| | `wfate0` (`results/bench_2026-09-11_170057.log`) | `wfate1` (`170253`) |
|---|---|---|
| `CTRL` relu | `0x131` | `0x331` |
| `W V- last` en aval du wrapper 2 | 9 / 21 | **0 / 21** |
| SC04 `SUMMARY-TX` p99 / max | 65 671 / 65 687 (timeout) | **1230 / 1230** |
| SC02 p99 / max | 565 / 565 | 560 / 565 |
| SC03 `b-r` | 0 | 0 |
| ERR SC02 / SC04 | 0 / 0 | 0 / 0 |
| `tx_sum` SC06 / SC07 | 3712 / 3711 | 3712 / 3753 |
| FIFO débordée (`STATUS[22]`) | — | 0 sur 21 instantanés |

Détection SC02 18 → 34, SC04 41 → 45, SC03 et SC01 50/50, zéro faux positif — sans
aucune ERR, donc sans l'artefact de timeout de `W_CAPDEBT`.

**Runs répétés, A/B, 2026-09-11 22:45–22:54** — même bitstream v10, même chargement
`capture_uart.sh -j`, sur une seconde machine : 7 campagnes `wfate1` (`170253`, `224519`,
`224645`, `224731`, `224757`, `224823`, `224849`) et 6 `wfate0` (`170057`, `225208`, `225234`,
`225301`, `225328`, `225354`). Toutes vont jusqu'à `END` avec le `CTRL` attendu, sans
`ATTENTION` ; partout zéro faux positif, SC03 et SC01 50/50, SC03 `b-r=0`, zéro ERR sur
SC02 et SC04.

| | `wfate0` ×6 | `wfate1` ×7 |
|---|---|---|
| SC02 TP / 50 | 18 à 30, moy. 23,3 | **34 à 48, moy. 39,3** |
| SC04 TP / 50 | 38 à 43, moy. 41,0 | **44 à 48, moy. 46,4** |
| `SUMMARY-TX` max SC02 / SC04 | timeout (65 6xx) sur 5 runs / sur 6 | ≤ 565 / ≤ 1241 |
| `W V- last` en aval de w2 | 9 à 11 / 21, dans chaque run | 0, dans chaque run |
| latence moyenne exacte SC06 / SC07 | 37,12–37,22 / 37,11–37,65 | 37,12–37,16 / 37,10–37,65 |

**Les plages sont disjointes** (SC02 30 < 34, SC04 43 < 44) : le gain de détection est
attribuable à `W_FATE`, pas au bruit d'un run. Coût en latence légitime : nul, sous le bruit.
Le lien avec les timeouts de `wfate0` est plausible mais **non vérifié itération par
itération**. `224849` a perdu sur l'UART des lignes de trace de SC01 (blocs `pre-ctrl`
incomplets, d'où `W V- last` 0/19) ; ses lignes `SUMMARY` et `STATUS_final` sont intactes.
`224519` a été lancé depuis un autre terminal que la série : ne jamais lancer deux captures
ou deux chargements JTAG à la fois, ils se partagent le câble et `/dev/ttyUSB0`.

Images (`payloads/` n'est pas versionné) : § 2, étape 2, avec
`-DARMOR_WSKID=1 -DARMOR_FRESH=1 -DARMOR_RHOLD=1 -DARMOR_WFATE=1`, en copiant
**`fw_payload.elf` et `fw_payload.bin`** dans `payloads/`. Campagne :

```sh
./2_build_HB.sh program
pkill -x hw_server
tools/capture_uart.sh -j payloads/fw_payload_v10_fresh1_wskid1_rhold1_wfate1.elf
```

**Bitstream v11 synthétisé et archivé le 2026-09-12** (`a402202`) : `CTRL[10] B_FATE`, un B
par écriture (§ 5, « Encore ouvert », et `armor/tb/README.md`, « Canal B »). WNS +0,177 ns
inchangé, 107 567 LUT et 73 385 bascules, soit +179 et +110 sur le v10. `check bench` dit
À JOUR. Images : `payloads/fw_payload_v11_fresh1_wskid1_rhold1_wfate1_bfate0.elf` et
`_bfate1.elf`.

**A/B sur carte du v11, 2026-09-12 08:54 — `B_FATE` GELAIT LA CARTE.** Corrigé depuis :
le v12 passe des deux côtés, voir « A/B du v12 » ci-dessous.

| | `bfate0` (`results/bench_2026-09-12_085414.log`) | `bfate1` (`085533`) |
|---|---|---|
| `CTRL` relu | `0x331` | `0x731` |
| Campagne | jusqu'à `END` | **gelée dans SC04, vers l'itération 18** |
| `STATUS[24]`, file pleine | 0 | **1 (collant)** |
| SC02 / SC04 détectées | 34/50, 48/50 | 38/50 puis plus rien |

Le témoin `bfate0` reproduit exactement le v10 (SC02 34, SC04 48, SC03 et SC01 50/50, zéro
faux positif, latence 37,08 / 37,10) : **le v11 ne change rien tant que le bit est à 0.**

**Cause.** La file de sort ne fait que **16 entrées**, alors que SC04-MSI émet **48 écritures**
d'affilée (`MSI_REQS`) et SC02 seize (`STORM_REQS`), sans attendre leurs B. Il suffit que la
tête soit une écriture admise dont le B réel tarde : rien ne se dépile, les AW acquittés
s'empilent, et la poussée en trop est **perdue** — `bq_ovf_q` — au lieu d'être refusée. Le
compte est alors désynchronisé pour toujours ; au gel, le maître tient `b_ready` sans qu'aucun
B ne lui soit présenté (`B -R` en amont) et ARMOR n'en prend aucun en aval (`B --`), la tête
étant une écriture coupée dont le W-last ne viendra jamais.

**Le banc ne pouvait pas le voir** : son aval n'acceptait **qu'une écriture à la fois**
(sixième angle mort). Avec `DN_AWOUT` et `DN_BLAT`, ajoutés le 2026-09-12
(`armor/tb/README.md`), seize écritures en vol et 8 cycles de latence de B ne suffisent
toujours pas — la file monte à 2 sur 16. C'est la **lenteur du B**, pas le nombre
d'écritures, qui bloque la tête.

**Correctif écrit et validé au banc le 2026-09-12** : la file passe à **64** — au-dessus des
48 écritures de SC04-MSI — et, pleine, elle **refuse l'AW** (`aw_ready` à 0 au maître,
`aw_valid` coupé en aval) au lieu de perdre la poussée. Aval historique et aval réaliste :
0 B en trop, 0 manquant, 0 débordement, remplissage 1 et 14 sur 64, verdicts inchangés.
Le point qui débordait (48 écritures en vol, B à 200 cycles) ne déborde plus. Détail et
tableaux : `armor/tb/README.md`, « La file de 16 déborde sur carte ».

**Bitstream v12 synthétisé et archivé le 2026-09-12** (`9e23f97`) : file de sort à 64
entrées, qui refuse l'AW quand elle est pleine. MAGIC v12 (`0x…0c`). Images :
`payloads/fw_payload_v12_fresh1_wskid1_rhold1_wfate1_bfate0.elf` et `_bfate1.elf`.

**A/B du v12 sur carte, 2026-09-12 11:00–11:14 — LE GEL EST CORRIGÉ, SANS GAIN DE
DÉTECTION.** 17 campagnes : 9 `bfate0` et 8 `bfate1`, toutes jusqu'à `END`, `STATUS[24]`
jamais armé sur aucun des 81 instantanés de chacune. La série répétée est
`results/serie_bfate{0,1}_11*.log` (7 + 7, alternées, une seule capture à la fois), plus
l'A/B initial `bench_2026-09-12_1100{10,40}.log` et `serie_bfate0_110730_essai.log`.

| TP sur 50 | `bfate0` ×9 | `bfate1` ×8 |
|---|---|---|
| SC02-STORM | 32 à 44, moy. 37,4 | 32 à 42, moy. 37,0 |
| SC04-MSI | 43 à 49, moy. 46,4 | 45 à 49, moy. 47,0 |

**Les plages se recouvrent entièrement** et les moyennes tiennent en moins d'un point : à
l'inverse de `W_FATE`, dont les plages étaient disjointes, `B_FATE` n'apporte **aucun gain
de détection**. L'A/B d'un seul run de 11:00 semblait montrer SC02 32 → 42 ; la série le
dément — la même variante `bfate1` donne 32 comme 40 selon le run. **Ne pas conclure d'un
A/B à un run sur SC02 : sa dispersion propre est de 12 points.**

Partout ailleurs, les 17 campagnes sont identiques : zéro faux positif, SC03 et SC01 50/50,
SC03 `b-r=0`, aucune `ERR` sur SC02 ni SC04, `W V-` absent en aval du wrapper 2, latence
légitime 258 cycles (`SUMMARY-TX` SC06/SC07). Une anomalie isolée, sans conséquence et non
expliquée : `serie_bfate1_110806.log` donne SC06-LHAOK à 240–245 cycles au lieu de 258 —
**plus rapide**, sur le seul chemin LHA, SC07 restant à 258 et les faux positifs à 0.
**Creusée le 2026-09-12, voir ci-dessous : artefact de mesure, sans effet sur la
détection.**

**L'anomalie SC06 du 110806 est un artefact de mesure, et elle ne se reproduit pas.**
Trois faits l'établissent. Toutes les lignes SC06 des deux journaux sont identiques au bit
près — compteurs du wrapper (`det_sum=3712`, `req_up=req_dn=100`, `cyc_hold=200`) et
instantanés des itérations tracées. La durée du scénario est la même à 36 cycles près sur
71 millions (`cyc_total`), alors qu'un gain réel de 14 cycles sur 100 itérations en aurait
retiré 1400 : **le travail a pris le même temps, seule la fenêtre chronométrée a bougé**.
Et l'écart vaut une passe de la boucle de sondage : `tx − det = 38` partout, dont 26 pour
la lecture de compteur que `CALIB` chiffre, donc 12 pour une passe.

**21 campagnes de plus le 2026-09-12 (`results/latdump_0*.log`, `-DBENCH_DUMP_LAT`) ne l'ont
pas reproduite** : SC06 y vaut `231` puis `220 × 96`, les 21 fois. Soit environ **1 cas sur
38**. Vu que le régime normal est déterministe au cycle près (§ 3), c'était un événement
ponctuel, pas un second mode de fonctionnement.

Ce qui reste ouvert, et qu'on ne saura qu'en attrapant une occurrence avec le dump : la
forme de la perturbation. Des agrégats du 110806 on déduit que `p50` et `p99` (échantillons
triés 48 et 95 sur `n_lat=97`) valaient tous deux 207, donc **au moins 48 échantillons à
207** — mais la moyenne de 206 interdit que les 48 autres y soient aussi, ils s'étalaient
entre 202 et 206. Ce **n'était donc pas** un basculement propre entre deux paliers de
quantification. Si le cas revient, les 97 valeurs de `LATDUMP` diront immédiatement s'il
bascule en cours de scénario ou part décalé dès l'itération de chauffe.

**Réplication de l'A/B, 2026-09-12 11:50** (`results/serie_bfate{0,1}_115*.log`) : même
protocole 7 + 7 alterné, mêmes images, après une reprogrammation de la carte.

| TP sur 50 | série 11:07 | série 11:50 |
|---|---|---|
| `bfate0` SC02 | 32–44, moy. 38,6 | 31–43, moy. 38,4 |
| `bfate1` SC02 | 32–40, moy. 36,3 | 31–41, moy. 35,9 |
| `bfate0` SC04 | 43–49, moy. 46,1 | 45–48, moy. 46,6 |
| `bfate1` SC04 | 45–49, moy. 47,0 | 47–49, moy. 47,6 |

Les quatre moyennes tiennent en moins d'un demi-point d'une série à l'autre, **à travers une
reprogrammation de la carte**. Cela règle aussi un soupçon qu'avait laissé la série `latdump`
(SC02 à 40,2) : ce n'était pas un effet de la reprogrammation, puisque cette série-ci, qui
lui est postérieure, retombe à 38,4. C'était le bruit de SC02, rien d'autre.

**Un signe reproductible, mais pas un effet.** Dans les deux séries indépendamment,
`bfate1` est plus bas sur SC02 (−2,3 puis −2,5) et plus haut sur SC04 (+0,9 puis +1,0).
Sur les 31 campagnes v12 poolées :

| | `bfate0` | `bfate1` | Mann-Whitney |
|---|---|---|---|
| SC02-STORM | n=16, moy. 37,9 | n=15, moy. 36,5 | z=+0,93, p=0,35 |
| SC04-MSI | n=16, moy. 46,5 | n=15, moy. 47,3 | z=−0,99, p=0,32 |

**Non significatif des deux côtés** : la conclusion tient. Le signe répété est ce qu'on
attend de deux tirages dans des populations qui se recouvrent — à ces effectifs, deux fois
le même signe arrive une fois sur quatre. Trancher demanderait une trentaine de campagnes
par bras, soit une heure de carte.

**Ce que `B_FATE` vaut donc** : une correction de robustesse — il supprime le gel du v11 —
et rien de plus. Le témoin `bfate0` du v12 reproduit le v10, donc **le v12 ne change rien
tant que le bit est à 0** et la configuration de référence `0x331` reste justifiée.

**Prochaine action** : **synthétiser le v14** (§ 5 quater). Le RTL a changé le 2026-09-13 —
`tools/bitstream.sh check bench` dira donc PÉRIMÉ, c'est normal et il ne faut lancer aucune
campagne avant la resynthèse. Restent ouverts par ailleurs : le point (2) de
§ 5, « Encore ouvert » — SC04 à 1396 cycles en moyenne sous `DN_WLAT=40` sans timeout —
et la notification **inter-VM** vers une VM de service distincte, avec sa copie de 8 Kio,
que § 5 ter ne mesure pas (la configuration y est à VM unique).

## 0 ter. Reprise sur un autre PC — checklist pérenne

**Principe : `doc/REPRENDRE.md` (ce fichier, versionné) est l'UNIQUE source de vérité pour
« où on en est ». La mémoire de l'assistant vit dans `~/.claude/…/memory/` et est LOCALE à
chaque machine : elle ne suit PAS le dépôt.** Donc, en fin de session, on met à jour le § 0
ici ; à la reprise, on lit le § 0 ici. Rien d'autre n'est nécessaire côté état.

Sur une machine neuve :

```sh
git clone --recurse-submodules git@github.com:prevotet/riscv-iommu-demo.git
cd riscv-iommu-demo && git checkout testbench
git submodule update --init --recursive          # si le clone n'a pas tout pris
tools/bitstream.sh use bench                      # installe le .bit archivé dans build/hw/
# payloads/ est ignoré (reconstruit en 3 min, § 2). Le RTL vit dans cva6-overlay/ et
# bao-overlay/ (versionnés) ; le build les recopie dans les sous-modules (cp -a).
```

**Config PROPRE À CHAQUE MACHINE (à surcharger par variables d'env, jamais commitées) :**
- `RISCV_BARE` — toolchain bare-metal (ici `/home/jc/Work/Software/riscv-imac/bin/riscv64-unknown-elf-`) ;
- `VIVADO_DIR` / `VIVADO_VERSION` — installation Vivado ;
- `RISCV=/usr` pour `make -C cva6 fpga`.
  Les scripts (`1_build_HLB.sh`, `2_build_HB.sh`) acceptent tous ces overrides.

**Licence Vivado.** La synthèse n'est possible que sur la machine licenciée (`~/Xilinx.lic`
nodelocked, via `XILINXD_LICENSE_FILE`). Sur un PC sans licence : **pas de synthèse**, mais
tout le reste marche (le `.bit` archivé se flashe, le banc `armor/tb` tourne, le firmware se
construit). Choisir la machine en conséquence.

**Ce qui transite par git** : RTL (overlays), `.bit` bench archivé + provenance, `results/`,
docs, pointeurs de sous-modules. **Ce qui ne transite pas** : `payloads/` (reconstruit),
`build/` (reconstruit), la mémoire de l'assistant (résumée ici au § 0), les sorties Vivado.

**Vérifié le 2026-09-15 — les sous-modules sont sales et c'est NORMAL.** `git status` montre
`bao-hypervisor` et `cva6` modifiés ; ne rien y committer, tout est régénéré :
- **cva6** (13 fichiers) : déversé depuis `armor/SRC/` et `cva6-overlay/` par le build.
- **bao-hypervisor** (4 entrées) : trois fichiers depuis `bao-overlay/`, et le répertoire
  **non suivi** `src/platform/cva6/` que `2_build_HB.sh` recopie depuis **`plat-configs/cva6/`**,
  lequel EST versionné (5 fichiers, vérifiés identiques). Rien n'est perdu au clone.

**Enchaîner des campagnes : `tools/campagne.sh <étiquette> <N> [flags]`** (versionné depuis le
15/09). Il construit le firmware, joue N campagnes, et sort **une ligne CSV par campagne avec
les garde-fous en clair** — MAGIC, marqueur de fin, `CTRL` et `0x110` relus. Une ligne dont le
MAGIC ou `end=` n'est pas le bon est une campagne **à jeter, pas à interpréter**. Surcharger
`RISCV_BARE` et `BASE_FLAGS` par l'environnement. Le bitstream n'est PAS rechargé entre les
campagnes : le flasher une fois avant (deux passes !), le JTAG ne change que le firmware.

**Ordre de démarrage sur la carte, dans cet ordre :**
1. `lsusb | grep 0403:6010` → **témoin fiable** de l'alimentation (le FT2232H est alimenté par
   la carte). Le FT232R `0403:6001` → `ttyUSB0` est la console, sur son propre câble.
2. `tools/program_fpga.sh build/hw/ariane_xilinx.bit` — **DEUX FOIS**, et **sans tuer
   `hw_server` entre les deux** (la 1ʳᵉ passe ouvre la cible sous un numéro de série tronqué).
3. `pkill -x hw_server` **après** la programmation, avant tout OpenOCD.
4. `tools/campagne.sh` ou `tools/capture_uart.sh -j <elf>`.

## 1. Mise en route

```sh
git clone --recurse-submodules git@github.com:prevotet/riscv-iommu-demo.git
cd riscv-iommu-demo
tools/bitstream.sh use bench     # réinstalle le .bit versionné dans build/hw/
tools/bitstream.sh check bench   # doit dire « À JOUR »
```

`check` compare une empreinte du RTL (`armor/SRC`, `armor/Include`,
`cva6-overlay`, plus le commit du sous-module `cva6`) à celle enregistrée dans
`bitstreams/*.provenance`. **S'il dit PÉRIMÉ, ne pas lancer de campagne** : un
`.bit` qui ne correspond pas au RTL produit des logs qu'on peut passer des
heures à réinterpréter. C'est arrivé le 2026-09-08.

Outils attendus sur la machine :

- **Vivado 2022.2** (synthèse, programmation, et `xsim` pour le banc). La **synthèse exige
  une licence** couvrant le `xc7k325t`, absent de l'édition gratuite : sans elle,
  `2_build_HB.sh fpga` échoue après les premières IP sur `ERROR: [Common 17-345] A valid
  license was not found for feature 'Synthesis'`. La licence est **nodelocked sur
  l'adresse MAC** : son `HOSTID` doit être celle de la machine, sans les deux-points
  (`cat /sys/class/net/<iface>/address`). Sur une VM, une licence émise pour une autre
  VM échoue — rencontré le 2026-09-11, le fichier portait le HOSTID de la machine
  d'origine ; il a fallu le régénérer sur le portail AMD pour cette MAC. Fichier hors
  des chemins par défaut : `XILINXD_LICENSE_FILE=<chemin>/Xilinx.lic`, sinon Vivado ne
  le voit pas ;
- la toolchain **`/home/jc/Work/Software/riscv-imac/bin/riscv64-unknown-elf-`** — à
  adapter dans les commandes si le chemin diffère ; `tools/load_jtag.sh` accepte
  `READELF=<chemin>` ;
- **OpenOCD ≥ 0.12** pour le chargement JTAG : `load_jtag.sh` appelle `/usr/bin/openocd`,
  `OPENOCD=<chemin>` sinon. Celui de Quartus (0.11) ne comprend pas la config ;
- **`dtc`** (paquet `device-tree-compiler`), pour le DTB chargé par JTAG ;
- les **fichiers de carte Digilent**, pour la synthèse seulement
  (`digilentinc.com:genesys2:part0:1.1`). Sans eux, `2_build_HB.sh fpga` s'arrête en
  6 s sur `ERROR: [Board 49-71]`, dès la première IP. Sans droits sur l'installation
  Vivado : `git clone https://github.com/Digilent/vivado-boards`, puis dans
  `~/.Xilinx/Vivado/Vivado_init.tcl` :
  `set_param board.repoPaths [list <clone>/new/board_files]`. Rencontré le 2026-09-11
  sur la seconde machine.

Même carte, même câblage : la **console** passe par l'adaptateur **FT232R séparé**
(`0403:6001`, en général `/dev/ttyUSB0`), le **JTAG** par l'USB de la Genesys2
(`0403:6010`). `capture_uart.sh` trouve le premier tout seul.

## 2. Chaîne complète

Utiliser **`2_build_HB.sh`** (hyperviseur + baremetal), jamais `1_build_HLB.sh`
qui construit la variante Linux : sa VM ajouterait du trafic parasite sur le bus
et sur l'UART pendant les mesures, et son `do_all` appelle `init_submodules`, ce
qui détruit les IP Vivado générées.

```sh
# 1. bitstream (~45 min) — seulement si le RTL a changé
BENCH_PROFILE=1 ./2_build_HB.sh fpga --force
tools/bitstream.sh save bench          # puis committer bitstreams/

# 2. guest de bench — À LA MAIN, les scripts ne propagent pas BENCH=1
cd bao-baremetal-guest
make clean                              # obligatoire : sources.mk change de fichier
make PLATFORM=cva6 \
     CROSS_COMPILE=/home/jc/Work/Software/riscv-imac/bin/riscv64-unknown-elf- \
     BENCH=1 ARCH_CPPFLAGS="-DBENCH_QUICK -DBENCH_TRACE_MMIO -DBENCH_NO_LHA_BG \
                            -DARMOR_WSKID=1 -DARMOR_FRESH=1 -DARMOR_RHOLD=1 \
                            -DARMOR_WFATE=1" \
     -j$(nproc)
# Drapeaux optionnels : -DBENCH_DUMP_LAT (échantillons bruts, § 3),
# -DBENCH_ASOS (coût logiciel de la boucle de décision) et -DBENCH_ASOS_IRQ
# (la même, interruption comprise — exige le v13). Voir § 5 ter.
# OPT_LEVEL=2 : à annoncer avec tout chiffre. Par défaut le banc est en -O0, où
# une lecture de compteur coûte 26 cycles contre 2, et le calcul cinq fois plus.
# Les quatre ARMOR_* donnent la configuration de référence, validée sur carte le
# 2026-09-11 sur le bitstream v10 (CTRL relu 0x331). -DARMOR_WFATE=0 donne le témoin
# de W_FATE (0x131). Ne PAS mettre -DARMOR_WCAP=1 : il fait caler le maître jusqu'au
# timeout. Retirer tous les ARMOR_* donne le témoin historique, sur le même bitstream.
cd .. && cp bao-baremetal-guest/build/cva6/baremetal.bin build/guests/baremetal.bin

# 3. hyperviseur et firmware
./2_build_HB.sh bao && ./2_build_HB.sh opensbi

# 4. carte SD, puis FPGA, puis capture — DANS CET ORDRE
sudo dd if=opensbi/build/platform/fpga/ariane/firmware/fw_payload.bin \
        of=/dev/sdX1 oflag=sync bs=1M status=progress
./2_build_HB.sh program
tools/capture_uart.sh

# 4 bis. SANS carte SD, par le JTAG de débogage de CVA6 — VALIDÉ SUR CARTE le
#        2026-09-11 14:19 (recette KERONEv2) : du lancement de la capture au
#        « ###### END » en moins d'une minute, contre le dd + la carte à déplacer
./2_build_HB.sh program
pkill -x hw_server                              # program en laisse un, qui tient le câble
tools/capture_uart.sh -j payloads/<image>.elf   # ouvre le port, PUIS charge ; pas de reset
```

**Pas de reset de carte en JTAG** : `load_jtag.sh` fait `reset halt`, charge, puis
`resume`. Avec `-j`, c'est la capture qui lance le chargement une fois la lecture
démarrée : l'en-tête ne peut plus être perdu. Avec deux terminaux il l'a été
(`results/bench_2026-09-11_143200.log`, capture ouverte trop tard). La sortie
d'OpenOCD va dans `<journal>.openocd`. `tools/load_jtag.sh` seul reste utilisable.

`load_jtag.sh` appelle `/usr/bin/openocd` (0.12) : celui de Quartus, souvent
premier dans le `PATH`, est en 0.11 et ne comprend pas la config. Le rebind de
`ftdi_sio` de `capture_uart.sh` n'a lieu que si **aucun** FT232R n'expose de tty :
avec l'adaptateur console branché, il ne gêne pas OpenOCD. Pour avoir un ELF,
copier `opensbi/build/platform/fpga/ariane/firmware/fw_payload.elf` à côté du `.bin`.

**Pièges de cette chaîne, tous rencontrés :**

- Après l'étape 2, n'appeler **que** `bao`, `opensbi`, `sdcard`, `program`.
  `all` ou `baremetal` recompilent `main.c` et écrasent `build/guests/baremetal.bin`
  **sans le signaler** : la campagne mesure alors le guest de démo.
- Vérifier que le bench est bien embarqué : `ls bao-baremetal-guest/build/cva6/*.o`
  ne doit montrer que `bench_runner.o` à la racine, pas `main.o`.
- **Programmer le FPGA AVANT d'ouvrir la capture.** Vivado prend le câble par
  libusb et détache `ftdi_sio` des deux canaux du FT2232 ; les `ttyUSB` ne
  reviennent pas seuls.
- La table GPT de la carte SD est déjà bonne : écrire directement sur la
  partition 1 évite de repartitionner 118 Go pour rien.
- Les logs de capture contiennent parfois des octets non ASCII. `grep` les
  déclare alors binaires et **renvoie silencieusement zéro résultat** : utiliser
  `grep -a`.

## 3. Lire un log de campagne

Dans l'ordre, avant toute interprétation :

1. `# ARMOR CSR magic` doit valoir la version attendue et **aucune ligne
   `ATTENTION`** ne doit suivre. Sinon le firmware et le bitstream sont
   désappariés et le reste ne vaut rien.
2. `# ARMOR arme : ENFORCE=…, W_SKID=…` — vérifier que c'est bien la
   configuration voulue. Deux images qui ne diffèrent que par un bit se
   confondent vite.
3. `# IT,<k>,…` — un digest par itération, imprimé **après** la fin de
   l'itération. La dernière ligne date donc le gel : c'est l'état d'entrée du
   lancement qui n'est jamais revenu.

Lignes ASOS, quand `-DBENCH_ASOS` / `-DBENCH_ASOS_IRQ` sont compilés (§ 5 ter) :
`ASOS` (coût par réaction, sans interruption), `ASOS-K` (coût en fonction du nombre
d'alertes simultanées), `ASOS-DECOMP` (décomposition par terme, dont le vPLIC),
`ASOS-IRQ` (réaction complète, interruption comprise) et `ASOS-IRQ-CFG` / `ASOS-IRQ-ARM`
(ce que le vPLIC a retenu de la configuration, à lire d'abord si rien ne remonte).

Lignes produites : `ARMORLAT` (latences matérielles), `ARMORHW` (cycles,
transferts), `ARMORSTALL` (attentes par canal), `ARMORW` / `ARMORRETR`
(canal W, `bad_id`, retraits de VALID), et `ARMORSNAP` / `ARMORHS` / `ARMORDBG`
avant chaque lancement tracé.

**`Lmax` sur un scénario légitime, c'est l'itération de chauffe, pas du bruit.**
Mesuré sur 21 campagnes le 2026-09-12 : la **première** itération de chaque
scénario est plus lente, puis la valeur est **rigoureusement constante** sur
toutes les suivantes, et les 21 runs donnent la même chose à l'échantillon près.

| | 1re itération | régime établi |
|---|---|---|
| SC06-LHAOK | 231 | 220 × 96 |
| SC07-MHAOK | 226 | 220 × 96 |
| SC08-LAS | 229 puis 223 | 218 × 510 |
| SC01-SPOOF | 149 | 143 × 46 |

Deux conséquences pratiques. Ne pas chercher à expliquer un `Lmax` légitime
supérieur de 6 à 11 cycles au `Lp99` : c'est la chauffe, et elle est elle-même
reproductible à la valeur exacte. Et surtout, **sur le trafic légitime le
système est déterministe au cycle près** : le moindre écart y est donc un signal,
alors que sur SC02 il faudrait 12 points pour sortir du bruit.

**Sortir les échantillons bruts** — `-DBENCH_DUMP_LAT` ajoute, à la fin de la
campagne et à côté des `SUMMARY`, une ligne par tranche de 16 échantillons :

```
# LATDUMP,SUMMARY-DET,SC06-LHAOK,0,231,220,220,…
```

Les valeurs sont émises **dans l'ordre d'acquisition**, avant que le calcul des
percentiles ne trie `lat[]` en place — après le tri on ne peut plus voir si un
scénario bascule en cours de route. L'émission a lieu une fois toutes les mesures
finies : son coût UART ne peut pas déplacer la phase d'un scénario, ce qui
importe quand on enquête précisément sur un artefact de phase.

## 4. Banc de simulation

```sh
./armor/tb/run_sim.sh 0            # aval sain
./armor/tb/run_sim.sh 1            # aval qui accepte mais ne répond jamais
./armor/tb/run_sim.sh 2            # aval qui n'accepte rien
DN_LAT=4 ./armor/tb/run_sim.sh 3   # campagne complète
OBS_CHECK=1 DN_LAT=4 ./armor/tb/run_sim.sh 3   # + contrôle croisé des compteurs
WSKID=1 DN_LAT=4 ./armor/tb/run_sim.sh 3       # + étage W actif
WSKID=1 FRESH=1 RHOLD=1 WFATE=1 BFATE=1 DN_LAT=4 ./armor/tb/run_sim.sh 3   # configuration v11
```

`DN_LAT` doit valoir **au moins 2** : à 0 le banc validait précisément ce sur
quoi la carte gelait.

`OBS_CHECK` est **désactivé par défaut**, et ce n'est pas de la prudence
excessive : ses quatre lectures CSR par pas suffisent à changer l'issue de SC03
et SC04. Une campagne de **vérification** et une campagne de **mesure** ne
peuvent pas être le même run.

Le banc ne modélise **ni l'IOMMU, ni le crossbar partagé, ni la contention
LHA/MHA**, et un seul accélérateur y est instancié. Il a validé du vide quatre
fois : vérifier ce qu'il ne modélise pas avant d'accuser le RTL.

## 5. Où en est l'enquête

**Mesuré et solide** — surcoût d'ARMOR sur trafic légitime : **2 cycles
d'attente de verdict pour 100 transactions**, zéro coupure, zéro blocage, zéro
retrait de VALID sur 900 itérations. Latence AXI matérielle **37 cycles**
(min 26). L'attente AW de 2 cycles n'existe qu'en amont (0 en aval) : c'est bien
ARMOR ; l'attente W de 38–46 cycles est identique des deux côtés, c'est l'aval.

Ne **pas** opposer ces 37 cycles aux ~275 des campagnes logicielles : le
matériel mesure une transaction AXI, le logiciel une itération d'accélérateur,
MMIO de sondage comprises. Deux colonnes, jamais une.

**Cause racine du gel de SC02-STORM** — `request_manager` retirait un `w_valid`
déjà présenté en aval (violation AXI4). Corrélation mesurée sans exception sur
901 itérations : 900 à `cut=0` sans aucun retrait, 1 à `cut=4` avec quatre
retraits sur le canal W. La règle en cause était le correctif du « W orphelin »
du 2026-09-09 : il avait échangé une violation contre une autre.

**Correctif, VALIDÉ SUR CARTE** — `armor/SRC/w_skid_buffer.sv`, derrière `CTRL[4]`.
La coupure est décidée **à la capture** ; un beat entré est tenu jusqu'à son
`ready` ; et le `ready` rendu au maître est celui de l'étage, jamais celui de
l'aval ni un 1 fabriqué. **Les deux côtés doivent bouger ensemble** — une première
tentative qui tenait le `VALID` sans corriger le `ready` avait fait passer les
retraits de 1 à 33.

Deux runs indépendants : SC02, SC04 et SC03 font **50/50 itérations chacun**,
coupure active sur 49 à 50 d'entre elles, **zéro retrait W, aucun gel**. SC04 et
SC03 n'avaient jamais été atteints sous `ENFORCE=1`. Coût : +1 cycle sur une
écriture légitime, +75 LUT, +134 bascules, marge de timing inchangée.
`w_owed_max` passe de 1 à 2 — preuve que l'étage est bien dans le chemin.

## 5 bis. `FRESH_VERDICT` adopté, VALIDÉ SUR CARTE

**2026-09-11, `results/bench_2026-09-11_105615.log`** — bitstream v7, `CTRL` relu
`0x31` (ENFORCE + W_SKID + FRESH). **La campagne va jusqu'à `###### END`**, pour la
première fois sous `ENFORCE=1`.

| scénario | TP / N | FP | retraits de VALID |
|---|---|---|---|
| SC06, SC07 (légitime) | — | 0 | aucun |
| SC02-STORM | 21 / 50 | 0 | aucun |
| SC04-MSI | 41 / 50 | 0 | aucun |
| SC03-OUTS | 50 / 50 | 0 | `ar=11`, `b-r=73` (voir « Encore ouvert ») |
| **SC01-SPOOF** | **50 / 50** | 0 | **aucun** |

**SC01 ne gèle plus** : 50 itérations, `req_up=50 req_dn=0`, aucune requête usurpée
n'atteint l'aval. Il gelait à la première itération les 08 et 09/09. SC02, SC04 et
SC03 restent dans la plage des deux runs v6 `wskid1`.

**Témoin `fresh0_wskid1`** (`results/bench_2026-09-11_124113.log`, `CTRL` relu
`0x11`) : même bitstream, même firmware, **seul FRESH diffère**.

| mesure | sans FRESH | avec FRESH |
|---|---|---|
| SC01 | **gèle à la 1re itération** | 50/50, aucun gel |
| SC06, latence moyenne exacte | 37,03 | 37,12 (+0,09) |
| SC07, latence moyenne exacte | 37,54 | 37,53 (−0,01) |
| latence minimale | 26 | 28 (+2) |
| SC03, retraits B/R (cause du 1er) | 16 (vide) | 73 (`!verdict`) |

Trois conclusions, par A/B et non par raisonnement :

- **C'est FRESH qui corrige le gel de SC01.**
- **Son coût moyen est sous le bruit d'un run (~0,1 cycle) ; +2 cycles au pire**, sur
  les transactions les plus rapides. Ailleurs, le retard d'AW se superpose à
  l'attente du canal W en aval (~40 cycles).
- **Il multiplie par ~4 les retraits B/R de SC03**, un défaut qui préexistait (voir
  « Encore ouvert »).

SC01 tourne encore **en dernier**, derrière l'OUTS parasite de SC03 : le replacer
avant SC02 pour des verdicts propres.

`CTRL[5] FRESH_VERDICT` supprime le retrait d'AW de **SC01**. Le défaut : `Device_ID_write_enable_o` est registré, donc
`verdict_known_q` ne retombe qu'à T+2 — pendant T et T+1 l'adresse est jugée sur
le verdict de la requête **précédente**. Aujourd'hui rien ne passe (`req up=8
dn=0` sur SC01), mais c'est la **lenteur de l'IOMMU** qui referme la fenêtre, pas
la logique.

Matrice mesurée au banc, `DN_LAT=4`, campagne 10 OK / 1 ÉCHEC partout :

| config | retrait AW SC01 | retrait AW SC04 | surcoût légitime |
|---|---|---|---|
| défaut | 1 | 1 | 0 cy |
| `FRESH` | **0** | 1 | **+2 cy** |
| `FRESH`+`WSKID` | 0 | 1 | +2 cy |
| `FRESH`+`WSKID`+`TXBLOCK` | 0 | **4** | +2 cy |

**Décision prise le 2026-09-11 : `FRESH` est adopté**, sans condition de seuil. On
accepte le surcoût sur chaque transaction légitime en échange d'une garantie
d'identité qui ne dépend plus d'un accident de timing. C'est aussi le seul
correctif prêt pour le gel de SC01. Le « 0 cycle » d'avant venait de ce qu'ARMOR
laissait l'adresse sortir avant de savoir si elle était légitime.

**Deux chiffres à ne pas confondre.** Le « 2 cycles d'attente pour 100
transactions » de la section 5 a été mesuré **sans** `FRESH`. Avec, l'attente de
verdict passe à **2 cycles par transaction** (`cyc_hold` 2 → 200 sur 100, mesuré sur
carte). Mais la **latence moyenne** ne prend qu'**au plus 0,12 à 0,53 cycle** : sur
carte, le retard d'AW se superpose en grande partie à l'attente du canal W en aval.
Le banc, dont l'aval est rapide, donnait +2 cycles partout. L'article publie les
valeurs de la carte, mesurées par A/B contre le témoin `FRESH=0` (tableau
ci-dessus) : ~0,1 cycle en moyenne, +2 au pire.

`CTRL[6] TX_BLOCK` est **câblé mais nuisible seul** (retraits AW de SC04 : 1 → 4).
Il ne redevient nécessaire qu'avec un futur étage sur AW. **Ne pas l'activer.**

Configuration de référence : **`W_SKID` + `FRESH_VERDICT`, sans `TX_BLOCK`**, soit
`-DARMOR_WSKID=1 -DARMOR_FRESH=1` à la compilation du guest. Les deux valent 0 par
défaut, exprès : un témoin se construit sans eux. Au boot, la ligne
`# ARMOR CTRL relu` donne la configuration réellement retenue par le matériel.

**Bitstream v7 synthétisé et archivé le 2026-09-11** : WNS +0,177 ns (inchangé),
107 287 LUT et 73 231 bascules, soit +4 et +2 par rapport au v6. `check bench` dit
À JOUR. Images de boot : `payloads/fw_payload_v7_fresh1_wskid0.bin` (FRESH seul,
à passer en premier pour isoler son coût) puis `_wskid1.bin` (configuration de
référence).

**Encore ouvert :**

- **l'étage W décale le canal W — DÉMONTRÉ au banc, `CTRL[7] W_CAPDEBT` (MAGIC v8,
  `d172928`) le corrige mais INTRODUIT DES BLOCAGES JUSQU'AU TIMEOUT.** Sur carte, même
  bitstream, chargement JTAG :

  | | `wcap0` (`141906`) | `wcap1` (`143242`) |
  |---|---|---|
  | `W V- last` bloqué en aval w2 | **11 / 21** instantanés | **0 / 21** |
  | SC06 / SC07 `tx_sum` | 3710 / 3754 | 3712 / 3766 |
  | écart / fantômes / orphelins W | 0 / 0 / 0 | 0 / 0 / 0 |
  | SC02 : DONE / ERR, `SUMMARY-TX` Lp50 | 30 / 0, 514 | **0 / 17, 65 676** |
  | SC04 : DONE / ERR | 8 / 0 | 0 / 2 |

  **Le « SC02 détecté 50/50 » sous `wcap1` est un ARTEFACT, à ne pas publier** : la moitié
  des transactions finissent sur le timeout de l'accélérateur (`TIMEOUT_CYCLES` = 65 536),
  et le firmware compte `ST_ERROR` comme une attaque observée. Mécanisme : pendant un
  blocage, ARMOR fabrique `aw_ready` ; si le blocage retombe avant que le maître présente
  le W de cette adresse coupée, `W_CAPDEBT` refuse — à raison — de le capturer, mais rien
  ne l'absorbe, et le maître attend jusqu'à son timeout. Sans le correctif ce W était
  capturé et partait avec l'adresse suivante : pas de blocage, mais une donnée mal
  adressée. **Correctif complet à concevoir** : suivre CHAQUE transaction — pour chaque
  AW acquitté au maître, retenir s'il a été admis en aval ou coupé (petite FIFO de bits,
  dans l'ordre AXI) — et absorber les W des AW coupés même après la fin du blocage.

  **Reproduit au banc** (`DN_WGATE=1`, `DN_WLAT` 4 et 8 — à 40 SC02 n'y est jamais détecté —,
  après correction de SC08 qui tournait sans aucune option). Photographie au cycle de chaque
  timeout, identique sur les 24 relevées : accélérateur en état **W, beat 0**, `w_valid=1
  w_ready=0`, blocage retombé, `w_owed=0 cap_owed=0`. **La cause est la même avec et sans
  `W_CAPDEBT`** (timeouts à `DN_WLAT=8` : SC02 3 et 4, SC04 4 et 4) ; sans lui, l'étage est
  plein d'un beat d'une autre écriture coupée et 757 beats partent mal adressés, avec lui
  l'étage est vide et aucun. `W_CAPDEBT` répare donc l'intégrité, et ni l'un ni l'autre ne
  sait absorber le W d'un AW coupé hors blocage.

  **`CTRL[9] W_FATE` (MAGIC v10), validé au banc, VALIDÉ SUR CARTE le 2026-09-11 (§ 0).** Une FIFO de 4
  bits garde le sort de chaque AW acquitté au maître — admis en aval dans le même cycle,
  ou coupé — et le W d'un AW coupé est absorbé (`w_valid` coupé en aval, `w_ready = 1`
  au maître) quel que soit l'état du blocage. Supplante `W_CAPDEBT`.

  | aval banc | timeouts en état W, avant → `W_FATE` | itération SC02 / SC04 | beats d'une autre écriture |
  |---|---|---|---|
  | `DN_WLAT=4` | SC08-m4 31 → **0**, SC02 4 → **0**, SC04 2 → **0** | 109 / 246 cy | **0** / 1778 |
  | `DN_WLAT=8` | SC08-m4 31 → **0**, SC02 4 → **0**, SC04 4 → **0** | 110 / 241 cy | **0** / 1772 |
  | `DN_WLAT=40` | — | 672 / 1396 cy | **0** / 2538 |
  | historique | — | 353 / 244 cy | **0** / 1773 |

  `OBS_CHECK` 0 défaut, verdicts inchangés. **Deux points ouverts** : (1) avec l'aval
  historique, SC02 finit UNE fois en timeout en état **DRAIN** (14 B reçus sur 16) —
  **cause établie au banc le 2026-09-11, corrigée par `CTRL[10] B_FATE` — MAGIC v11, puis
  v12 après le débordement de file constaté sur carte (§ 0)** : le canal B n'était pas compté par écriture. Pendant un blocage un SLVERR
  est présenté en continu et l'accélérateur en prend un par cycle (2674 B en trop en
  configuration de référence) ; après le blocage, le B d'un AW coupé ne vient jamais (14
  manquants). Les premiers masquaient les seconds, sauf sans `RHOLD`, où s'ajoutaient
  815 B perdus. Sous `B_FATE` : 0 en trop, 0 manquant, 0 perdu, verdicts inchangés, sur
  les avals historique, réaliste et `DN_WLAT=8`, et sous `OBS_CHECK` — voir
  `armor/tb/README.md`, « Canal B » ; (2) à `DN_WLAT=40`, SC04 dure en
  moyenne 1396 cycles sans aucun timeout (775 à 837 avant) — à comprendre ; Sur carte,
  dans les quatre runs `W_SKID=1` (v6 ×2, v7 ×2), un beat W reste présenté en aval
  dès SC02 et jusqu'à la fin, avec `w_owed=0` et `w_pending=0`
  (`ARMORHS,pre-ctrl,w2,dn` : `W V- last`) ; il n'est pas la cause du gel de SC01.
  Mécanisme : pendant un blocage, `response_manager` fabrique `aw_ready`, l'écriture
  suivante coupée envoie son W pendant que le dernier beat de la précédente attend
  encore dans l'étage (40 à 45 cycles en aval), et la dette W, comptée **en aval**,
  autorise sa capture. Ce beat part ensuite avec l'adresse légitime suivante.
  **Aucun compteur matériel ne le voit.** Il a fallu deux ajouts au banc : un aval
  réaliste pour W (`DN_WGATE=1 DN_WLAT=40`, cinquième angle mort) et un contrôle
  d'appariement adresse/donnée — voir `armor/tb/README.md`.

  | aval banc | `WCAP` | beats d'une autre écriture | fantômes | `OBS_CHECK` |
  |---|---|---|---|---|
  | réaliste | 0 | **147** (1er : 63 beats plus vieux) | 0 | — |
  | réaliste | 1 | **0** / 2408 | 0 | 0 défaut |
  | historique | 1 | **0** / 1586 | 0 | — |

  Verdicts de campagne inchangés (8/3 aval réaliste, 10/1 historique). Au passage,
  le détecteur de fantômes — banc ET `cnt_w_ghost_q` — donnait 187 fausses alarmes
  sous `WCAP=1` : handshakes aval et maître sont découplés par l'étage. Il est
  désormais inhibé quand `W_SKID=1`. **À valider sur carte après synthèse** ;
- retrait de VALID résiduel sur **AW** (cause `block_req` : verdict frais et bon,
  puis verdict volumétrique qui arrive après). Demanderait un étage sur AW de la
  même forme que celui de W — **pas** `TX_BLOCK` ;
- **retrait de `b_valid`/`r_valid` par `response_manager` — troisième site, corrigé
  par `CTRL[8] RESP_HOLD` (MAGIC v9), VALIDÉ SUR CARTE le 2026-09-11.** Même bitstream v9,
  chargement JTAG par `capture_uart.sh -j` : `rhold0` (`results/bench_2026-09-11_151005.log`)
  SC03 `b-r=54`, `rhold1` (`151516`, `CTRL 0x131`) **`b-r=0`** ; latence légitime inchangée
  (`tx_sum` SC06/SC07 3710/3766 → 3712/3759), détection inchangée (SC02 25→24, SC04 43→41,
  SC03 et SC01 50/50), zéro faux positif. Seul écart : ERR de SC03 3 → 7 (retraits AR sans
  cause, timeouts de l'accélérateur), dans la plage habituelle de 3 à 11 — non attribuable
  sur un run. Sur
  carte, SC03 : `b-r` = 16 et 11 en v6 `wskid1`, **73** en v7 avec `FRESH` (cause du
  premier retrait : vide → `!verdict`). Les branches de `response_manager` sont des
  fonctions pures de l'état courant : une réponse présentée sans `ready` retombe dès
  que la branche change — SLVERR fabriqué à la fin d'un blocage, ou R **réelle** à
  l'ouverture d'une attente de verdict (d'où l'effet de `FRESH`, qui en ouvre une à
  chaque front). Sous `RESP_HOLD`, toute réponse présentée est verrouillée, charge
  utile comprise, jusqu'à son `ready` ; tant qu'une réponse *fabriquée* est tenue,
  aucune réponse réelle n'est prise en aval. Banc, aval réaliste : SC03 `b/r` **8 →
  0**, appariement W, `OBS_CHECK` et verdicts inchangés ; aval historique 10/1.
  L'attente laisse aussi passer les réponses de l'aval au maître : **précaution** contre
  une perte lue dans le RTL, **jamais observée** (détecteur « réponses perdues » à 0 sur
  toutes les campagnes). Les `ar=8` qui restent sur SC03 au banc sont le timeout de
  l'accélérateur lui-même (cause vide, 2031 cycles), pas ARMOR ;
- `MAX_REQ_PER_WINDOW = 8` sur une fenêtre de 100 cycles est hors d'atteinte à
  la latence réelle de l'aval (37 cycles par transaction) : SC02 n'est détecté
  que par intermittence ;
- profil DEMO cassé : `FLOW_WINDOW_C` vaut 100 en BENCH et 50 000 en DEMO pour
  le même seuil, donc le trafic légitime y est bloqué comme une tempête ;
- SC03-OUTS échoue en simulation dès `DN_LAT = 2` : `req_fire` compte des
  **fronts** de handshake et non des transferts, et apparie le `valid` du maître
  au `ready` de l'aval.

## 5 ter. Interruption ARMOR → logiciel, et coût réel d'ASOS

**Bitstream v13, 2026-09-12.** `wrapper.sv` expose `irq_o`, de **niveau**, haut tant
qu'une alerte collante non acquittée subsiste et que `CTRL[11] IRQ_EN` est armé.
L'acquittement réutilise le `STICKY_CLR` existant (`CTRL[1]`) : le gestionnaire lit le
collant, évalue, écrit sa politique avec `STICKY_CLR`, et la ligne retombe dans la même
écriture. Aucun registre nouveau, aucun chemin d'acquittement séparé à désynchroniser.

**De niveau et pas une impulsion** : les verdicts de flux ne durent que `BLOCK_CYCLES`,
4 à 10 cycles en profil BENCH. Une impulsion aussi étroite serait ratée par un PLIC
échantillonné, et le gestionnaire ne trouverait rien à lire — c'est le piège qui a fait
mesurer `k = 0` partout au niveau 0.

Câblage : `irq_sources[12]` et `[13]`, routage vers la VM par `vm-configs`. Coût **+142 LUT
et +8 bascules** sur le design complet pour deux wrappers, WNS **+0,177 ns inchangé**.

### Ce que ça mesure

| Phase | cycles | contenu |
|---|---:|---|
| `L_notify` | ≈ 45 760 | montée de `irq_o` → entrée dans le gestionnaire : PLIC physique, injection par Bao, `claim` sur le vPLIC émulé |
| `L_processing` | 177 (k=0) / 224 (k=2) | évaluation de la menace + classification TLC |
| `L_mmio` | 56 (1 écriture) / 67 (2) | écriture de la politique |
| `L_exit` | ≈ 15 710 | retour du gestionnaire, `complete` sur le vPLIC compris |
| **`L_total`** | **≈ 61 700** | dispersion ±0,7 % sur 16 essais |

**Le résultat : la décision logicielle pèse 0,4 % de sa propre réaction** — 233 cycles sur
61 700. Tout le reste est la livraison et le retour d'interruption à travers l'hyperviseur.

La décomposition qui l'explique, mesurée séparément (100 opérations chacune, `-O2`) :

| Terme | cycles / opération |
|---|---:|
| Lecture CSR du wrapper, **passthrough** | **17** |
| Écriture CSR + relecture | 43 |
| Classification TLC seule (9 seuils) | 106 |
| Évaluation complète, forme O(NEV) | 155 |
| Évaluation complète, forme O(k), k=2 | 122 |
| Lecture d'un registre du **vPLIC émulé** | **813** |

**Bao passe les devices en direct mais émule le PLIC** (`src/arch/riscv/vplic.c`,
`vm_emul_add_mem`) : un accès CSR au wrapper coûte 17 cycles, un accès vPLIC 813, soit un
facteur 48. C'est là qu'est tout le surcoût de virtualisation, pas dans l'accès aux
registres d'ARMOR.

Journaux : `results/asos_O0.log`, `results/asos_O2.log` (sans interruption),
`results/asos_irq_002.log` (avec). Code derrière `-DBENCH_ASOS` et `-DBENCH_ASOS_IRQ`.

### Quatre pièges, tous rencontrés

1. **L'identifiant PLIC vaut l'index matériel PLUS UN**, l'ID 0 étant réservé par la
   spécification RISC-V. La table de `vm-configs` le faisait déjà : UART câblé sur
   `irq_sources[0]` et déclaré `{1}`, timer sur `[6:3]` et déclaré `{4,5,6,7}`. Les
   wrappers, câblés sur `[12]` et `[13]`, portent donc **13 et 14**. Les déclarer 12 et 13
   arme le voisin — l'ID 13 désigne le wrapper 1, dont le collant reste vide, et rien ne
   remonte jamais. **Trois campagnes perdues dessus.**
2. **`plic_handle()` contenait deux `printf` de débogage** sur le chemin du `claim`. Dans
   un gestionnaire d'interruption ils rendent toute mesure de latence absurde, et sous une
   source de niveau non acquittée ils ont produit 560 000 lignes et 11 Mo d'UART en une
   campagne. Retirés.
3. **Une source de niveau se re-lève tant que l'attaque dure.** C'est correct, et c'est ce
   qui justifie le traitement groupé des notifications — mais pour chronométrer UNE
   réaction il faut la borner : le gestionnaire désarme `IRQ_EN`, l'appelant le ré-arme.
4. **Le bit 14 du collant, `BAD_ID`, est un écho d'état et non un événement.** Après SC01
   il est ré-armé en permanence : armer `IRQ_EN` sur un collant plein fait monter `irq_o`
   immédiatement, le gestionnaire s'exécute avant la boucle et désarme. La mesure déclenche
   donc **par l'armement** et non par l'attaque — ce qui isole proprement la livraison, la
   latence de détection d'ARMOR étant déjà mesurée par ailleurs (37 cycles, `ARMORLAT`).

### Sondes Bao

`bao-overlay/src/core/interrupts.c` et `bao-overlay/src/arch/riscv/vplic.c` impriment
l'assignation et la voie d'activation. **Dans l'overlay et pas dans le sous-module** :
`init_submodules` y fait `git reset --hard`. Ce sont elles qui ont prouvé que Bao prend la
voie matérielle et programme bien le PLIC physique — donc que le défaut était ailleurs.

## 5 quater. v14 — pourquoi SC02 n'est détecté qu'à ~78 %, et ce qui est corrigé

Écrit le 2026-09-13, **validé au banc uniquement** : aucun bitstream v14 n'existe encore,
`check bench` dit PÉRIMÉ tant qu'il n'est pas synthétisé. Rien de ce qui suit n'est vérifié
sur carte.

### Le point de départ

Le 80,4 % de détection de SC02 publié dans le dossier de révision est un taux **par salve**
— la proportion d'itérations où un bit de verdict est apparu — et non par transaction. Les
compteurs matériels du même run disent l'autre chiffre : `req_up=800 req_dn=649
req_cut=151`, soit **18,9 % de transactions coupées** (`results/serie_bfate0_115531.log`).
Les deux sont vrais, ils ne répondent pas à la même question, et c'est le second qu'un
relecteur peut recalculer.

### Le mécanisme, mesuré

Le débit de SC02 **au niveau du wrapper** n'est pas fixé par `STORM_REQS = 16` mais par la
vitesse de l'aval. Le générateur de `accel_wrap` est séquentiel (`G_AW → G_W → G_NEXT`),
`aw_valid` retombe entre deux adresses : la salve s'étale, et une salve étalée sur trois
fenêtres de 100 cycles n'en met que cinq ou six dans chacune — sous le seuil de 8.

Le banc le démontre en ne changeant QUE l'aval, scénario identique (détail et tableaux dans
`armor/tb/README.md`, « L'occupation de la fenêtre de flux ») :

| aval | occupation max | fenêtres au seuil | verdict SC02 |
|---|---|---|---|
| `DN_LAT=2` | 8 | 6 / 7 | `STORM`, 68/128 coupées |
| `DN_LAT=4` | 8 | 9 / 10 | `STORM`, 55/128 coupées |
| `DN_LAT=4 DN_WGATE=1 DN_WLAT=40` | **3** | **0 / 54** | **aucun**, 0 coupée |

À `DN_WLAT=40` — la valeur que `ARMORSTALL` mesure sur carte — **SC02 passe
intégralement**. La carte se situe entre les deux régimes : c'est là l'explication des
~78 % et de leur dispersion de 12 points. Le seuil n'est pas mal calibré, **le scénario est
sur la frontière de décision**.

### Ce que le v14 change

Deux correctifs et deux compteurs, tous dans `armor/SRC` :

1. **`req_cnt` ne reboucle plus.** Il faisait quatre bits pour un seuil de 8 : il comptait
   0 à 15 puis repassait à 0 en pleine fenêtre, `storm_flag` retombant au milieu d'une
   tempête sans qu'aucun compteur ne le dise. Il fait désormais 8 bits **saturants**.
   `STORM_REQS = 16` place SC02 pile sur ce point. Sous `ENFORCE=1` le blocage écrête le
   compte à 8 et le défaut est invisible ; sous `ENFORCE=0` — le bras du baseline publié —
   il coûtait 6 fenêtres sur 7 et 12 verdicts sur 128.
2. **`CTRL[12] RFM_CNT`** : le moniteur compte les **transferts** d'adresse accomplis en
   aval au lieu des **fronts** de handshake. Douze adresses transférées sur douze cycles
   consécutifs comptaient pour **une**. L'accélérateur ne pipeline pas ses AW, donc l'A/B
   sur la campagne est rigoureusement identique — le bit ferme un trou que la campagne
   actuelle ne sait pas creuser, et `./run_sim.sh 4` le démontre sur un stimulus dédié.
   **Au reset le bit vaut 0 : le v14 se comporte alors exactement comme le v13.**
3. **`0x38[39:32] REQ_MAX` et `0x38[63:40] WIN_ACT`** : occupation maximale atteinte par une
   fenêtre, et nombre de fenêtres fermées non vides, remises à zéro par `CNT_CLR`. C'est ce
   qui manquait pour lire un faux négatif : `reqmax=6` sur un scénario non détecté dit en
   un chiffre de combien la salve est passée sous le seuil. Le firmware les imprime
   (`ARMORCNT,...,reqmax=,winact=`).
4. **MAGIC passe à `0x…0E`** (v14). Le bitstream v13 avait oublié d'incrémenter le sien,
   resté à `0x…0C` : on saute `0x0D` pour que numéro de bitstream et version de MAGIC se
   recollent. Le contrôle du firmware est par seuil, un firmware ancien n'y verra rien.

### Non-régression

RTL v14 + banc de HEAD, aval réaliste : sortie **identique ligne pour ligne** à HEAD. Sur
l'aval rapide, la seule différence de toute la campagne est le bras `ENFORCE=0`, qui passe
de 65 à 77 transactions avec verdict sur 128 — le rebouclage en moins. Le contrôle croisé
`OBS_CHECK=1` confirme que `REQ_MAX`/`WIN_ACT` disent la même chose que les compteurs
indépendants du banc : 0 défaut.

### Le mode 7 : la tempête que le mode 4 n'est pas

Ajouté le même jour, pour la même raison. Puisque le débit de SC02 est fixé par la vitesse
de l'aval et non par `STORM_REQS`, la seule façon de relever la détection sans toucher au
seuil est d'émettre une vraie tempête. Le **mode 7** de `accel_wrap` présente ses seize
adresses à la volée puis leurs seize beats — ce que fait tout DMA réel, et ce que la Table 5
du papier annonce déjà (« 16 requêtes par salve, 2 × MAX_REQ »). Le mode 4 est conservé tel
quel : mêmes seize écritures, une à la fois. **Seule leur forme diffère**, et c'est toute la
comparaison.

Au banc, 8 itérations × 16 écritures = 128 transactions :

| aval rapide (`DN_LAT=4`) | `req_fire` vu | occ. max | verdict | coupées |
|---|---|---|---|---|
| SC02 séquentiel | 75 | 8 | `STORM` | 53 / 128 |
| SC09 pipeliné, `RFMCNT=0` | **8** | **3** | **aucun** | **0 / 128** |
| SC09 pipeliné, `RFMCNT=1` | — | 9 | `STORM` | **92 / 128** |

| aval réaliste (`DN_WLAT=40`) | occ. max | fenêtres au seuil | verdict | coupées |
|---|---|---|---|---|
| SC02 séquentiel | 3 | 0 / 54 | aucun | 0 / 128 |
| SC09 pipeliné, `RFMCNT=1` | 9 | 8 / 10 | `STORM` | 50 / 128 |

Deux lectures. **Huit fronts pour 128 adresses transférées** : sans `CTRL[12]`, la tempête
la plus dense que cette plateforme sache produire est invisible, et elle le reste quelle que
soit la vitesse de l'aval — c'est la forme du trafic qui la cache, pas son débit. Et avec
`CTRL[12]`, **le débit du mode 7 ne dépend plus de l'aval** : il est détecté là même où SC02
passe intégralement.

**Ce que le mode 7 a coûté au wrapper.** Seize AW en vol sans leurs données, c'est
l'hypothèse exacte sur laquelle trois mécanismes reposaient :

- la file de sort de `W_FATE` faisait **quatre** entrées (« accel_wrap n'a jamais plus d'un
  AW sans W en attente ») : la cinquième poussée était perdue, `fate_ovf_q` levé, le sort
  d'une écriture inconnu. Portée à **64**, comme la file B ;
- `w_owed_q` faisait **quatre bits** et saturait à 15 : avec seize AW il perdait une
  incrémentation puis encaissait seize décrémentations, atteignait zéro alors qu'une écriture
  était encore due, et rouvrait la coupure de W au pire moment — le Bug #16. Porté à
  **8 bits** ; `0xE8` porte désormais deux champs de 8 bits au lieu de deux de 4, et le
  firmware a été ajusté ;
- **`B_FATE` cesse d'être facultatif.** Sans lui, le mode 7 sous aval réaliste donne 488 B
  en trop, 50 manquants et un AW resté dû en aval — la condition du gel carte. Avec lui :
  128 B appariés, aucun en trop ni manquant, `aw_owed = 0`. Après 31 campagnes qui ne lui
  trouvaient aucun gain mesurable, **c'est le premier scénario qui en a besoin**, et la
  configuration de référence d'une campagne SC09 est donc `0x1731`, pas `0x331`.

Aucune de ces trois modifications ne change rien tant que le maître n'a qu'un AW en vol :
campagne par défaut identique ligne pour ligne, aval rapide comme aval réaliste.

### Ce que la synthèse a donné

Synthèse du 2026-09-13, 45 min, Vivado 2022.2, `xc7k325tffg900-2`, profil BENCH :

| | v13 | **v14** |
|---|---|---|
| WNS | +0,177 ns | **+0,110 ns**, 0 endpoint en faute |
| LUT | 107 993 | **108 462** (53,2 % de 203 800) |
| bascules | 73 495 | **73 721** (18,1 % de 407 600) |

Les +469 LUT et +226 bascules sont le prix des deux files de sort à 64 entrées, de
`w_owed` à 8 bits et des compteurs d'occupation — l'ordre de grandeur attendu. La marge
temporelle perd 67 ps et reste positive ; c'est le chiffre à surveiller à la prochaine
synthèse, pas encore un problème.

**Surface d'un wrapper ARMOR, en contexte** (`reports/ariane.utilization.rpt`, utilisation
par hiérarchie, sous-modules compris) :

| instance | LUT | bascules |
|---|---|---|
| `i_sec_wrap2` (MHA) | **2 663** | **1 919** |
| `i_sec_wrap1` (LHA) | 2 622 | 1 917 |
| `i_accel1` / `i_accel2` | 557 / 561 | 535 / 535 |

**Le papier annonce 180 LUT et 157 bascules par wrapper : c'est un ordre de grandeur en
dessous.** Ces chiffres-ci sont en contexte (optimisation à travers les frontières de
hiérarchie), donc ils ne remplacent pas la synthèse hors contexte que réclame le § 6.3.4
du dossier de révision — mais ils en donnent la borne réaliste, et elle est à ~2 600 LUT,
pas à « quelques centaines ».

**Les rapports Vivado sont écrasés à chaque run.** C'est ce qui a empêché la comparaison
v13/v14 de se faire proprement : le `*_utilization_placed.rpt` du v13 n'existait plus.
`tools/bitstream.sh save` recopie désormais timing, surface et surface par wrapper dans le
`.provenance`, qui lui suit le `.bit` dans git.

### CE QUE LA CARTE A DIT, 2026-09-13

**Campagne de référence : le v14 ne change rien à la détection, et les nouveaux compteurs
marchent.** Deux campagnes (`results/bench_2026-09-13_085622.log` et `091154`), `CTRL` relu
`0x331`, MAGIC `…0E`, aucune `ATTENTION`, et **aucun débordement des files de sort** — c'était
la première campagne carte avec 64 entrées, aucun `sticky` ne porte le bit 22 ni le bit 24.

| | v12 (`serie_bfate0_115531`) | v14 (`085622`) | v14 (`091154`) |
|---|---|---|---|
| SC02-STORM | 35/50 | 40/50 | 36/50 |
| SC04-MSI | 47/50 | 47/50 | 47/50 |
| SC03 / SC01 | 50/50 | 50/50 | 50/50 |
| faux positifs SC06/SC07 | 0 | 0 | 0 |
| SC08 | 700 passent | 700 passent | 700 passent |

Tout est dans les plages archivées : **la correction de largeur n'agit pas sous `ENFORCE=1`**,
comme le banc l'annonçait. La latence matérielle est identique au cycle près (`det_avg=37`,
`det_min=28`) ; les ±5 cycles des latences logicielles viennent du binaire firmware, qui a
changé.

**Les nouveaux compteurs, eux, donnent enfin le chiffre qui manquait :**

| scénario | `req_up` | `winact` | occupation moyenne | `reqmax` |
|---|---|---|---|---|
| SC06 / SC07 (légitime) | 100 | 100 | **1,00** | **1** |
| SC02-STORM | 800 | 113 | **7,08** | 8 |
| SC04-MSI | 2400 | 362 | 6,63 | 8 |
| SC03-OUTS | 1098 | 87 | 12,6 | **24** |

La tempête vit à **7,08 requêtes par fenêtre de 100 cycles pour un seuil de 8** — 88 % du
seuil, mesuré et non plus déduit. Le trafic légitime est à **1,00**, soit une marge d'un
facteur 8. Confinement au niveau transaction : `req_cut=216` sur 800, **27 %**, à mettre en
face des 80 % de salves marquées.

Et `reqmax=24` sur SC03 prouve que **le compteur de 4 bits rebouclait bel et bien sur carte**
(24 > 15), pas seulement au banc : les épisodes `STORM` de SC03 passent de 63 (v12) à 50
(v14), dans le sens attendu. Un seul run, donc un signe ; le mécanisme, lui, est établi.

### L'occupation sans écrêtage : le low-and-slow est indiscernable du trafic légitime

Deux campagnes de plus le 2026-09-13, avec `run_sc08()` enfin instrumenté :
`bench_2026-09-13_092952` (référence, `0x331`) et `093043` (**`ARMOR_ENFORCE=0`**, `0x330`,
où rien n'est coupé — `req_cut=0` partout — donc où l'occupation se lit sans écrêtage).

| scénario | `req_up` | `winact` | occupation moyenne | **`reqmax`** |
|---|---|---|---|---|
| SC07-MHAOK (légitime) | 100 | 99 | 1,01 | **1** |
| **SC08 low-and-slow** | 700 | 687 | **1,02** | **1** |
| SC02-STORM | 800 | 162 | 4,94 | **10** |
| SC04-MSI | 2400 | 516 | 4,65 | 10 |
| SC03-OUTS | 600 | 95 | 6,3 | 12 |

**SC08 met une requête par fenêtre. Exactement comme le trafic légitime.** Son énoncé —
« salves de 7, sous le seuil de 8, espacées de 200 cycles, au-delà de la fenêtre de 100 » —
ne décrit pas ce qui arrive au moniteur : les 220 cycles de la boucle logicielle espacent
déjà chaque requête au-delà d'une fenêtre, si bien que la salve de 7 s'étale sur une
quinzaine de fenêtres à une requête chacune. Le gap de 200 cycles ne joue aucun rôle.

C'est une correction à porter dans le papier, et elle **renforce** l'argument au lieu de
l'affaiblir. L'évasion n'est pas « il reste sous le seuil » mais **« il est identique au
trafic légitime à l'entrée du moniteur »** : aucun seuil de débit, quel qu'il soit, ne peut
séparer les deux. C'est la forme forte de la limite qu'ARMOR doit admettre et qu'ASOS
existe pour couvrir.

Et la tempête, mesurée sans blocage, culmine à **10 requêtes par fenêtre pour une moyenne
de 4,94** — le seuil de 8 n'est franchi que par ses pics, d'où les ~80 % de salves détectées.
Un seuil à 2 ou 3 attraperait presque toutes ses fenêtres **sans toucher ni au légitime ni
au low-and-slow, tous deux à 1**. C'est le balayage de seuil à mesurer, et la marge est
beaucoup plus large qu'on ne le croyait.

**Limite de ces chiffres, à énoncer avec eux** : le générateur de fond LHA est DÉSACTIVÉ
(`-DBENCH_NO_LHA_BG`) dans toutes ces campagnes, alors que le § 6.2.1 du papier décrit
l'inverse. Avec le fond actif, la densité du trafic légitime monte et la marge se réduit
d'autant. **Mesurer `reqmax` sur SC06/SC07 avec le fond actif est le prochain chiffre à
prendre** — une image, pas de resynthèse.

### Avec le fond LHA actif : la marge de seuil, mesurée pour de bon

`bench_2026-09-13_095601` (`0x331`) et `095709` (`0x330`, sans blocage). **Aucun gel**, les
deux vont jusqu'à `END` — y compris SC01, que le commentaire de `bench_runner.c` annonçait
comme gelant précisément sous contention. Ce diagnostic est donc **périmé** : `W_SKID`,
`FRESH`, `RESP_HOLD` et `W_FATE` ont fermé ce gel-là, et plus rien ne le reproduit.

`lha_bg_start()` est appelé **après** SC06 et SC07 : ces deux baselines tournent toujours
sans fond et restent à `reqmax=1`. Ce que le fond donne, c'est l'occupation du **wrapper 1**
pendant tout le reste de la campagne — un DMA légitime en mode continu, saturant :

| trafic (tout mesuré sur carte, seuil = 8) | occupation moyenne | **pic `reqmax`** | fenêtres observées |
|---|---|---|---|
| légitime piloté par le logiciel (SC06/SC07) | 1,0 | **1** | ~100 |
| low-and-slow SC08 | 1,0 | **1** | ~690 |
| **fond LHA saturant (w1)** | **2,4** | **4** | **~5,4 millions** |
| tempête SC02, sans blocage (w2) | 4,9 | **10** | ~160 |

**Zéro faux positif sur le wrapper 1** dans les deux bras : `storm=0` sur 5,4 millions de
fenêtres actives de trafic légitime à plein débit.

C'est le tableau qui manquait pour discuter du seuil, et il est sans ambiguïté :

- un seuil à **6** passerait au-dessus du pic d'un DMA légitime saturant (4, sur 5,4 millions
  de fenêtres) avec deux de marge, et sous la moyenne de la tempête (4,9) comme sous son pic
  (10) : le confinement monterait nettement, sans un faux positif de plus ;
- **aucun seuil ne séparera jamais le low-and-slow du trafic légitime**, puisque les deux
  valent 1. Ce n'est pas une question de calibrage, c'est une identité à l'entrée du moniteur.

Le papier peut donc dire les deux choses, mesurées : le seuil actuel est **trop haut** — le
baisser à 6 gagnerait du confinement gratuitement — et **même bien choisi il ne fermera pas
le trou**, parce que l'attaquant patient est indiscernable du trafic sain. La seconde moitié
est l'argument d'ASOS, et elle est bien plus forte que « il reste sous le seuil ».

**Le moniteur d'outstanding, lui, devient aveugle sous contention.** SC03 passe de **33
épisodes `outs` sans fond à 0 avec fond**, et son `reqmax` de 24 à 16 : le fond sérialise les
24 lectures de l'attaque, la profondeur en vol n'atteint plus le seuil de 16, et le moniteur
ne voit rien — l'attaque échoue d'elle-même (42 `ERR` sur 50) sans être détectée. À
rapprocher du « outstanding exhaustion : 100 % » du papier, qui est mesuré **sans** fond.

### Surface d'un wrapper, hors contexte (2026-09-13)

`armor/ooc/run_ooc.sh` — deux minutes, licence requise. Synthèse du wrapper **seul**, profil
BENCH, `xc7k325tffg900-2`, horloge de 20 ns :

| | mesuré | papier | part du composant |
|---|---|---|---|
| LUT (toutes en logique) | **3 173** | 180 | 1,56 % |
| bascules | **2 342** | 157 | 0,57 % |
| WNS à 50 MHz | **+14,279 ns** | — | 0 endpoint en faute |

**17,6 fois la surface annoncée en LUT**, 14,9 fois en bascules. Le « below 0.09% of the
target FPGA » du papier devient **1,6 % par wrapper**, 3,1 % pour les deux instanciés.

Le chiffre hors contexte est **plus grand** que celui de l'utilisation par hiérarchie
(2 676 LUT) : c'est le sens attendu, Vivado élague à travers la frontière quand le wrapper
est entouré de logique. Citer le hors contexte comme coût de l'IP, l'hiérarchique comme coût
dans ce SoC, et dire lequel est lequel.

Deux pièges rencontrés en écrivant le harnais, tous deux dans `armor/ooc/` :

- les types des canaux AXI sont des **paramètres de type** dont le défaut est `logic`.
  Synthétiser `wrapper` directement donne un module d'un bit de large et un chiffre qui ne
  veut rien dire — d'où l'enveloppe `ooc_wrapper.sv`, qui lie les mêmes types que
  `ariane_peripherals_xilinx.sv` et n'ajoute aucune logique ;
- **un seul `read_verilog`** pour tous les fichiers : Vivado traite chaque appel comme une
  unité de compilation séparée, et un package déclaré dans l'une n'est pas visible depuis
  l'autre (« `ariane_axi_soc` is not declared »).

Et le profil compte : en DEMO les durées de blocage valent 750 000 000 cycles au lieu de 4
et 10, soit des compteurs de 30 bits au lieu de 3. Ce n'est pas le même circuit.

### Après toute synthèse : lire les CRITICAL WARNING, pas seulement les ERROR

Le 2026-09-13, un registre neuf de `accel_wrap` (0x40 PIPE_DEPTH) relisait **zéro** sur
carte. Cause : son reset était dans le `always_ff` de la FSM du générateur alors que son
écriture est dans celui de la FSM de configuration — **deux pilotes**. Vivado l'avait
signalé, en `CRITICAL WARNING [Synth 8-6859] multi-driven net`, pas en `ERROR` ; mes
contrôles ne grepaient que `^ERROR: \[`, et la campagne qui a suivi a tourné à la valeur de
synthèse en croyant balayer une profondeur.

**La simulation ne peut pas attraper ça** : avec deux pilotes, le dernier écrivain gagne et
le bloc de reset ne parle qu'au reset — au banc, le registre marchait parfaitement.

Deux réflexes :

```sh
grep -c "CRITICAL WARNING" vivado.log                     # zero attendu
grep "Synth 8-6859" vivado.log | head                      # multi-driven : jamais acceptable
```

Et côté firmware : **tout registre neuf se relit après écriture**, avec une `ATTENTION` si la
relecture diffère. C'est ce qui manquait ici, et c'est deux lignes.

### Décision : le seuil évalué reste 8

Prise le 2026-09-13 après le balayage. **Toutes les campagnes de référence restent au seuil de
synthèse**, `CTRL[23:16]` à zéro — c'est l'état par défaut du v15, rien à faire pour l'obtenir.
Le balayage est une **étude de paramètre publiée à côté**, pas un changement de base : passer le
papier à 5 obligerait à re-mesurer toute la Section 6 là-bas.

Balayage mesuré, 6 campagnes par point pour les quatre seuils qui comptent
(`results/bench_2026-09-13_11*.log`, fond LHA actif) :

| seuil | SC02 /50 | SC04 /50 | écritures coupées | faux positifs | SC08 |
|---|---|---|---|---|---|
| 8 (synthèse) | 41,3 ± 2,3 | 47,3 ± 0,8 | 25,3 % | 0 | s'échappe |
| 8 (registre) | 40,2 ± 3,3 | 48,0 ± 1,0 | 24,5 % | 0 | s'échappe |
| 6 | 49,3 ± 0,7 | 50,0 | 47,9 % | 0 | s'échappe |
| 5 | **50,0 ± 0,0** | 50,0 | 59,5 % | 0 | s'échappe |
| 4 (k=1) | 50 | 50 | 68 % | 0 | s'échappe |
| 3 (k=1) | 50 | 50 | 75 % | **500 575** | s'échappe |

Le contrôle qui autorise à lire la courbe : champ à zéro 41,3 ± 2,3 contre champ écrit à 8
40,2 ± 3,3. Le registre reproduit la valeur de synthèse ; l'écart de 8 détections vu sur un
run unique était du bruit.

**Ce que ça vaut pour le papier** : le seuil évalué est conservateur d'un facteur deux en
confinement, 5 est le point de fonctionnement recommandé sur cette charge, et **aucun seuil ne
ferme le trou du low-and-slow** — il s'échappe même à 3, là où le trafic légitime est marqué un
demi-million de fois.

### SC09 (mode 7) GÈLE LA CARTE — les deux bras

`bench_2026-09-13_090157` (`0x1731`) et `090714` (`0x731`) s'arrêtent au **même endroit** : le
`*ctrl = 1` de la **première** itération de SC09, après un SC02 parfaitement normal. État
d'entrée propre dans les deux cas (`w_owed=0`, `req_cnt=0`, `sticky=0`, `status=0xb33000`).

**Le gel ne dépend pas de `CTRL[12]`.** Le bras témoin ne compte qu'un front par salve, ne
franchit jamais le seuil, ne coupe rien — et gèle pareil. Ce n'est donc pas le chemin de
coupure d'ARMOR : c'est la forme du trafic. Le banc, qui ne modélise ni l'IOMMU ni le
crossbar partagé, déclarait ce mode propre — cinquième fois qu'il valide du vide.

**Hypothèse à vérifier** : le port de configuration ne traverse pas ARMOR mais **traverse le
crossbar**. Seize AW en vol saturent l'interconnexion partagée et l'écriture MMIO du CPU
reste bloquée derrière. Si elle se confirme, c'est un résultat pour le papier et pas
seulement un bug : **un maître qui pipeline ses adresses verrouille le CPU hors de ses
propres périphériques**, et aucun moniteur ne peut plus être reprogrammé une fois que c'est
parti.

**Reprise après gel, à connaître avant de rejouer SC09 :**

```sh
pkill -x hw_server                 # sinon `program` échoue sur current_hw_device
./2_build_HB.sh program            # le chargement JTAG SEUL ne suffit pas (capture vide)
pkill -x hw_server
```

**Prochaine mesure, à ne pas faire à l'aveugle** : rendre la profondeur du pipeline réglable
à l'exécution (par exemple via le registre `SIZE` de l'accélérateur, inutilisé en mode 7)
pour balayer 2, 4, 8, 16 AW en vol sur **un seul** bitstream et trouver le seuil de survie.
En l'état, `PIPE_REQS` est un paramètre de module : chaque valeur coûte 45 minutes de
synthèse, et un gel par essai.

### À faire sur carte

Le bitstream est déjà synthétisé et archivé (`tools/bitstream.sh use bench` pour le
réinstaller dans `build/hw/`). Puis, dans cet ordre :

**1. Campagne de référence (`0x331`, § 2), sans rien de neuf.** La détection de SC02 doit
être **inchangée** — la correction de largeur n'agit pas sous `ENFORCE=1` — et les lignes
`ARMORCNT` doivent porter un `reqmax` proche de 8 sur les salves détectées, nettement plus
bas sur les autres. C'est ce chiffre-là qui permettra de dire dans le papier de combien un
faux négatif passe sous le seuil. Un A/B `-DARMOR_RFMCNT=1` ne devrait rien changer ; une
différence voudrait dire qu'un maître pipeline ses adresses sur la carte, ce que le banc ne
modélise pas.

**2. Campagne SC09**, à compiler à part et à ne pas mélanger aux archives :

```sh
make ... BENCH=1 ARCH_CPPFLAGS="-DBENCH_QUICK -DBENCH_NO_LHA_BG -DBENCH_SC09 \
    -DARMOR_WSKID=1 -DARMOR_FRESH=1 -DARMOR_RHOLD=1 -DARMOR_WFATE=1 \
    -DARMOR_BFATE=1 -DARMOR_RFMCNT=1"      # CTRL relu attendu : 0x1731
```

Et son témoin, le même sans `-DARMOR_RFMCNT=1` (`0x731`), qui doit donner **zéro détection
sur SC09** : c'est le bras qui démontre l'angle mort, il vaut autant que l'autre. Attention,
`-DBENCH_SC09` ajoute 50 × 16 transactions avant SC04 : une campagne avec SC09 ne se compare
pas aux campagnes archivées, seulement à son propre témoin.

**3. Ce qu'il faudra surveiller dans le log**, et qui n'est pas vérifié sur carte : `STATUS`
final avec `[22]` (file `W_FATE`) et `[24]` (file `B_FATE`) à zéro, `w_owed` revenu à zéro
en fin de scénario, et aucun timeout (`SUMMARY-TX` à 65 6xx). Le banc dit que tout est propre
avec `B_FATE`, mais le banc ne modélise ni l'IOMMU ni le crossbar partagé — et c'est
exactement le genre de régime où il a déjà validé du vide quatre fois.

## 6. Ce qui n'est pas dans le dépôt

- **`payloads/`** est ignoré : les images de boot se reconstruisent en trois
  minutes avec la section 2.
- Les **notes de travail** (27 fichiers) ne sont pas versionnées : elles vivent
  dans un répertoire local à la machine d'origine et ne suivent pas le clone. Ce
  document en reprend l'essentiel opérationnel, mais pas le détail des impasses.
- Les sorties Vivado (`cva6/corev_apu/fpga/work-fpga/`) ne sont pas versionnées ;
  seul le `.bit` l'est, via `tools/bitstream.sh`.
