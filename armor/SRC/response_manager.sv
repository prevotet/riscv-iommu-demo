`timescale 1ns/1ps

// =============================================================================
//  response_manager — retour combinatoire des reponses vers l'IP
//
//  Voir request_manager pour la raison du passage en combinatoire.
//
//  Trois modes, au lieu des deux de la version precedente :
//
//  1. BLOCAGE (block_ip_i || block_req_i) — terminaison de bus gracieuse.
//     On absorbe la requete (aw/w/ar_ready a 1) et on fabrique immediatement
//     une reponse d'erreur SLVERR. La version precedente calait le maitre en
//     retirant les ready : une attaque bloquee ne se terminait jamais, le
//     logiciel devait sortir par timeout et la latence mesuree n'etait plus
//     que TIMEOUT_CYCLES. Avec la terminaison SLVERR la transaction se termine
//     proprement et la latence redevient une vraie mesure (~1450 cy sur la
//     campagne de reference, contre un timeout ici).
//
//     Le B reel eventuellement emis par l'IOMMU pour un AW deja accepte est
//     avale par request_manager (b_ready force) — sans quoi le canal B se
//     remplirait et figerait le mux partage (« wedge SC04 »).
//
//  2. ATTENTE (!legit_hit ou verdict pas encore rendu) — mode HOLD, BORNE.
//
//     La condition `!verdict_known_i` est indispensable et va de pair avec la
//     coupure d'AW/AR faite par request_manager pendant la meme fenetre : sans
//     elle, le maitre verrait passer le aw_ready de l'aval alors que sa requete
//     n'y a jamais ete presentee -- un handshake fantome, exactement ce que ce
//     mode existe pour empecher.
//     Pendant les deux cycles du pipeline ID_extractor + id_comparator, le
//     verdict n'est pas encore connu. Laisser passer aw_ready fabriquerait un
//     handshake fantome : le maitre croirait sa requete acceptee alors qu'elle
//     est encore en cours d'examen. On sort donc '0 : tous les ready et valid
//     a zero, l'accelerateur reste dans sa phase d'adresse.
//
//     BORNE PAR bad_id_i (correctif 2026-09-09). `legit_hit` est un niveau qui
//     confondait « verdict pas encore connu » et « verdict connu et mauvais » :
//     une requete a l'identifiant usurpe restait tenue jusqu'au timeout du
//     maitre (65536 cycles cote accel_wrap, 1,31 ms a 50 MHz), et il en fallait
//     TROIS pour que security_monitor bannisse -- ~3,9 ms avant la moindre
//     reaction d'ARMOR. Pire, le seul evenement qui relance une comparaison est
//     un FRONT de AxVALID (cf. ID_extractor), et une requete tenue n'en produit
//     aucun : l'escalade dependait entierement du timeout du maitre.
//
//     bad_id_i dit « la comparaison a rendu son verdict et il est mauvais ». On
//     termine alors la transaction comme un blocage, en SLVERR. Le maitre reprend
//     la main immediatement, retire son AxVALID, et sa prochaine tentative fait
//     un nouveau front -- donc une nouvelle comparaison. MAX_FAILURES = 3 est
//     inchange et redevient atteignable en trois requetes au lieu de trois
//     timeouts.
//
//  3. TRANSPARENT — l'IP est legitime, les reponses traversent telles quelles.
// =============================================================================
module response_manager #(
    parameter type         resp_slv_t = logic,
    parameter int unsigned IdWidth    = 6      // largeur de b.id vers le maitre (B_FATE)
)(
    input  logic       clk_i,
    input  logic       rst_ni,
    input  logic       block_ip_i,
    input  logic       block_req_i,
    input  logic       bad_id_i,        // verdict rendu, et mauvais
    input  logic       verdict_known_i, // le verdict de la requete presentee est rendu
    input  logic       legit_hit,
    input  logic       w_pending_i,     // un AW admis en aval attend ses donnees

    //  ETAGE W (skid buffer, derriere CTRL[4]). Quand il est actif, le ready
    //  rendu au maitre sur le canal W est « il y a de la place dans l'etage »,
    //  JAMAIS le ready de l'aval ni un 1 fabrique.
    //
    //  C'est la moitie du correctif qui manquait a la tentative sur AW : tenir
    //  le VALID sans corriger le ready avait fait passer les retraits de 1 a 33,
    //  parce que le maitre, croyant son beat absorbe, passait au suivant. ARMOR
    //  ne doit ni retirer un VALID presente, ni acquitter ce qui est encore
    //  presente en aval.
    input  logic       wskid_en_i,
    input  logic       wskid_ready_i,

    //  ABSORPTION DU W D'UN AW COUPE (CTRL[9] W_FATE, 2026-09-11). Le beat W
    //  presente par le maitre appartient a un AW qu'ARMOR a acquitte par
    //  fabrication et n'a jamais admis en aval : il faut l'acquitter (w_ready=1)
    //  sans rien envoyer -- request_manager coupe deja son w_valid --, Y COMPRIS
    //  HORS BLOCAGE. Sans cela le maitre attendait son w_ready jusqu'a son timeout
    //  (sur carte : SC02 17/50 sous W_CAPDEBT).
    input  logic       w_absorb_i,

    //  BLOCAGE TRANSACTIONNEL (CTRL[6]). Une ecriture dont l'AW est deja admis
    //  en aval ne peut PAS etre terminee en SLVERR : le maitre cesserait
    //  d'envoyer ses donnees et l'aval garderait une adresse orpheline -- le
    //  defaut corrige le 2026-09-09, reintroduit par l'autre bout. On laisse
    //  donc cette transaction s'achever, et le blocage prend effet a la
    //  SUIVANTE (l'AW suivant est coupe par request_manager).
    //
    //  NE PAS ACTIVER SANS CTRL[5]. Sans exigence de verdict frais, une adresse
    //  peut etre presentee sur le verdict de la requete precedente ; « ce qui
    //  est presente est engage » reviendrait alors a admettre une ecriture
    //  usurpee. L'ordre des deux correctifs n'est pas negociable.
    input  logic       txblock_en_i,

    //  MAINTIEN DES REPONSES PRESENTEES (CTRL[8] RESP_HOLD, 2026-09-11).
    //
    //  LE TROISIEME SITE DE RETRAIT DE VALID. Les branches ci-dessous sont des
    //  fonctions PURES de l'etat courant. Une reponse B/R presentee au maitre
    //  sans son ready retombe donc des que la branche change :
    //
    //    - SLVERR fabrique pendant un blocage, puis le blocage retombe ;
    //    - R REELLE en passe-plat, puis une nouvelle requete ouvre la fenetre
    //      d'attente de verdict (FRESH le fait a chaque front) et la branche
    //      d'attente sort '0.
    //
    //  Mesure sur carte, SC03 : b-r = 16 sans FRESH, 73 avec (cause !verdict).
    //  L'accelerateur y tient r_ready bas pendant l'emission (mode 5), d'ou la
    //  fenetre.
    //
    //  ET UN RISQUE DE PERTE, LU DANS LE RTL, JAMAIS OBSERVE. L'attente masque le
    //  r_valid de l'aval au maitre, alors que request_manager transmet le r_ready
    //  du maitre a l'aval : une reponse reelle pourrait y etre prise en aval sans
    //  que le maitre l'ait vue. Le banc compte ces pertes (REPONSES PERDUES) :
    //  ZERO sur toutes les campagnes, avec et sans RESP_HOLD. Le point 2
    //  ci-dessous est donc une precaution, pas un correctif mesure -- seul le
    //  retrait l'est (SC03 au banc : b/r 8 -> 0).
    //
    //  Sous RESP_HOLD :
    //    1. toute reponse presentee sans ready est VERROUILLEE, charge utile
    //       comprise, et representee a l'identique jusqu'a son ready ;
    //    2. dans la branche d'attente, les reponses de l'aval traversent -- elles
    //       appartiennent a des transactions deja admises ;
    //    3. tant qu'une reponse FABRIQUEE est tenue, hold_*_o demande a
    //       request_manager de ne prendre aucune reponse reelle en aval : le
    //       ready du maitre appartient a la reponse tenue.
    input  logic       resp_hold_en_i,
    input  logic       b_ready_i,       // ready du maitre sur B
    input  logic       r_ready_i,       // ready du maitre sur R
    output logic       hold_b_o,        // un B FABRIQUE est tenu vers le maitre
    output logic       hold_r_o,        // un R FABRIQUE est tenu vers le maitre

    //  SORT DE CHAQUE ECRITURE COTE B (CTRL[10] B_FATE, 2026-09-11).
    //
    //  LE DEFAUT. Le canal B vers le maitre etait, comme le reste, une fonction
    //  de la branche courante : pendant un blocage un SLVERR fabrique est
    //  presente EN CONTINU, et accel_wrap -- b_ready a 1 -- en prend un par
    //  cycle, pas un par ecriture ; hors blocage, seul le B de l'aval passe, et
    //  l'aval ne repondra jamais a un AW qu'il n'a pas vu. Au banc, configuration
    //  de reference : 2674 B sans ecriture en attente et 14 W-last jamais
    //  repondus. Les premiers masquaient les seconds dans le compte du maitre ;
    //  sans RESP_HOLD ils ne suffisaient plus : timeout en DRAIN.
    //
    //  Sous B_FATE le wrapper tient une file, dans l'ordre AXI, du sort de chaque
    //  AW acquitte au maitre. Tete COUPEE et W-last passe : bfate_fab_i, un
    //  SLVERR, un seul, avec l'ID de l'AW. Tete ADMISE : bfate_take_i, le B de
    //  l'aval, et lui seul. Sinon aucun B. Le canal B ne depend plus du blocage.
    input  logic                bfate_en_i,
    input  logic                bfate_fab_i,
    input  logic                bfate_take_i,
    input  logic [IdWidth-1:0]  bfate_id_i,

    //  FILE PLEINE (2026-09-12). Une poussee perdue desynchronise le compte pour
    //  toujours : le maitre attend alors un B que personne ne lui doit -- le gel
    //  observe sur carte dans SC04. Quand la file est pleine on ne perd rien, on
    //  fait attendre : aw_ready reste a 0, dans TOUTES les branches, y compris
    //  pendant un blocage ou l'acquittement est fabrique.
    input  logic                bfate_hold_aw_i,

    input  resp_slv_t  resp_wrapper_iommu_i,
    output resp_slv_t  resp_IP_wrapper_o
);

    resp_slv_t resp_base;      // ce que produit la branche courante
    logic      fabricating;    // la branche courante fabrique les reponses

    assign fabricating = (block_ip_i || block_req_i || bad_id_i)
                         && !(txblock_en_i && w_pending_i);

    always_comb begin
        if (fabricating) begin
            // ---- Terminaison de bus gracieuse (SLVERR) ----
            resp_base = '0;

            // Absorption des requetes encore presentees par l'accelerateur.
            resp_base.aw_ready = 1'b1;
            resp_base.ar_ready = 1'b1;

            //  W : on n'absorbe de force que s'il n'y a RIEN a acheminer. Des
            //  qu'un AW est du en aval, ses beats doivent partir pour de vrai --
            //  on rend donc le ready de l'etage, pas un 1 fabrique. Sans cette
            //  distinction, le maitre avancerait pendant qu'un beat est encore
            //  presente en aval : c'est exactement le defaut mesure.
            if (wskid_en_i && w_pending_i)
                resp_base.w_ready = wskid_ready_i;
            else
                resp_base.w_ready = 1'b1;

            // Reponse d'ecriture : SLVERR.
            resp_base.b_valid  = 1'b1;
            resp_base.b.resp   = 2'b10;

            // Reponse de lecture : SLVERR, un seul beat.
            resp_base.r_valid  = 1'b1;
            resp_base.r.resp   = 2'b10;
            resp_base.r.last   = 1'b1;

        end else if (!legit_hit || !verdict_known_i) begin
            // ---- Verdict d'ID en cours (2 cycles) : on tient le maitre ----
            resp_base = '0;

            //  Sous RESP_HOLD, les reponses de l'aval traversent : tenir la
            //  phase d'adresse du maitre n'exige pas de lui cacher les reponses
            //  de transactions deja admises -- et les cacher pouvait les faire
            //  perdre (risque lu au RTL, jamais observe au banc).
            if (resp_hold_en_i) begin
                resp_base.b_valid = resp_wrapper_iommu_i.b_valid;
                resp_base.b       = resp_wrapper_iommu_i.b;
                resp_base.r_valid = resp_wrapper_iommu_i.r_valid;
                resp_base.r       = resp_wrapper_iommu_i.r;
            end

        end else begin
            // ---- IP legitime : passe-plat ----
            resp_base = resp_wrapper_iommu_i;

            // request_manager retient w_valid tant qu'aucun AW n'est admis en
            // aval. Or l'aval maintient son w_ready en permanence : le laisser
            // traverser ferait croire au maitre que son beat est parti alors
            // qu'on vient de le retenir, et la donnee serait perdue. On masque
            // donc w_ready dans exactement la meme fenetre.
            if (wskid_en_i)
                //  Le handshake du maitre se fait contre l'etage : de la place
                //  et un AW du, sinon le maitre attend. Il ne voit plus jamais
                //  le ready de l'aval sur ce canal.
                //  W_FATE : le W d'un AW coupe est acquitte sans etre envoye --
                //  c'est ici, hors blocage, qu'il manquait. En blocage, la branche
                //  du dessus rend deja 1 quand aucune dette ne l'attend.
                resp_base.w_ready = w_absorb_i ? 1'b1 : (wskid_ready_i & w_pending_i);
            else if (!w_pending_i)
                resp_base.w_ready = 1'b0;
        end

        //  File de sort pleine : aucune nouvelle ecriture n'est acquittee, quelle
        //  que soit la branche. Le W et les reponses en cours continuent, eux.
        if (bfate_hold_aw_i)
            resp_base.aw_ready = 1'b0;
    end

    // -------------------------------------------------------------------------
    //  Verrou des reponses presentees (RESP_HOLD). *_pres_q : une reponse est
    //  presentee au maitre sans son ready ; *_fab_q : elle a ete fabriquee par
    //  ARMOR, au cycle ou elle a ete presentee pour la premiere fois.
    // -------------------------------------------------------------------------
    resp_slv_t lat_q;
    logic      b_pres_q, r_pres_q, b_fab_q, r_fab_q;

    always_comb begin
        resp_IP_wrapper_o = resp_base;
        if (bfate_en_i) begin
            //  B_FATE : le B presente ne depend que de la tete de file, stable
            //  jusqu'a son handshake -- le verrou de RESP_HOLD n'a rien a tenir.
            resp_IP_wrapper_o.b_valid = 1'b0;
            resp_IP_wrapper_o.b       = '0;
            if (bfate_fab_i) begin
                resp_IP_wrapper_o.b_valid = 1'b1;
                resp_IP_wrapper_o.b.id    = bfate_id_i;
                resp_IP_wrapper_o.b.resp  = 2'b10;   // SLVERR
            end else if (bfate_take_i) begin
                resp_IP_wrapper_o.b_valid = resp_wrapper_iommu_i.b_valid;
                resp_IP_wrapper_o.b       = resp_wrapper_iommu_i.b;
            end
        end else if (resp_hold_en_i && b_pres_q) begin
            resp_IP_wrapper_o.b_valid = 1'b1;
            resp_IP_wrapper_o.b       = lat_q.b;
        end
        if (resp_hold_en_i && r_pres_q) begin
            resp_IP_wrapper_o.r_valid = 1'b1;
            resp_IP_wrapper_o.r       = lat_q.r;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            lat_q    <= '0;
            b_pres_q <= 1'b0;
            r_pres_q <= 1'b0;
            b_fab_q  <= 1'b0;
            r_fab_q  <= 1'b0;
        end else if (!resp_hold_en_i) begin
            b_pres_q <= 1'b0;
            r_pres_q <= 1'b0;
            b_fab_q  <= 1'b0;
            r_fab_q  <= 1'b0;
        end else begin
            b_pres_q <= resp_IP_wrapper_o.b_valid & ~b_ready_i & ~bfate_en_i;
            r_pres_q <= resp_IP_wrapper_o.r_valid & ~r_ready_i;
            if (resp_IP_wrapper_o.b_valid && !b_ready_i) begin
                lat_q.b <= resp_IP_wrapper_o.b;
                if (!b_pres_q) b_fab_q <= fabricating;
            end
            if (resp_IP_wrapper_o.r_valid && !r_ready_i) begin
                lat_q.r <= resp_IP_wrapper_o.r;
                if (!r_pres_q) r_fab_q <= fabricating;
            end
        end
    end

    assign hold_b_o = resp_hold_en_i & b_pres_q & b_fab_q & ~bfate_en_i;
    assign hold_r_o = resp_hold_en_i & r_pres_q & r_fab_q;

endmodule
