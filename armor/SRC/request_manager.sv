`timescale 1ns/1ps

// =============================================================================
//  request_manager — filtrage combinatoire des requetes vers l'IOMMU
//
//  Cette version etait un simple registre : req_wrapper_iommu_o <= req_i. Le
//  valid arrivait donc a l'IOMMU avec un cycle de retard et le ready revenait
//  au maitre avec un cycle de retard (via response_manager, registre lui
//  aussi). Comme un IOMMU au repos maintient aw_ready haut, le maitre ne
//  voyait le ready qu'au cycle 2, ne retirait son valid qu'au cycle 3, et
//  l'IOMMU avait alors vu valid && ready pendant plusieurs cycles : chaque
//  transaction etait emise deux fois (mesure par simulation : 1 AW emis -> 2
//  vus, idem AR et W, avec ENFORCE=0 donc hors logique de blocage).
//
//  Un etage de pipeline sur un canal AXI exige un skid buffer ; a defaut, le
//  passage combinatoire preserve l'atomicite du handshake. C'est ce que fait
//  cette version : les signaux traversent dans le meme cycle.
//
//  BLOCAGE CHIRURGICAL (Bug #16 de l'implementation de reference).
//  Une version anterieure coupait aussi w_valid et r_ready pendant un blocage.
//  Les deux maitres (LHA et MHA) partagent en aval un multiplexeur AXI 2:1 et
//  l'IOMMU : couper W tuait les transactions du voisin deja acceptees en aval,
//  et l'interconnexion mourait apres chaque attaque MHA. On ne coupe donc que
//  AW et AR — aucune nouvelle requete malicieuse ne passe, la securite est
//  intacte — et W/B/R restent passants pour drainer l'aval.
//
//  DRAINAGE DU CANAL B (correctif du « wedge SC04 »).
//  Quand response_manager termine la transaction vers le maitre par un SLVERR
//  fabrique, le maitre considere son ecriture finie et n'assertera plus
//  b_ready. Si l'AW avait deja ete accepte par l'IOMMU avant le blocage,
//  l'IOMMU emet malgre tout un B reel : personne ne le consomme, le canal B se
//  remplit et le mux/IOMMU partage se fige. C'est le wedge decrit au §6.3 du
//  rapport de campagne de reference, laisse ouvert par celle-ci. On le corrige
//  ici en forcant b_ready/r_ready a 1 vers l'IOMMU pendant le blocage : les
//  reponses en vol sont avalees au lieu de s'accumuler.
//
//  Le forcage s'applique au blocage (block_req_i) ET a la terminaison pour
//  identifiant fautif (bad_id_i), pas au mode d'attente ~legit_hit.
//
//  Pourquoi bad_id_i en fait partie : `legit_hit` est un niveau qui reste a 1
//  tant que la comparaison suivante n'a pas rendu son verdict. Une requete
//  usurpee qui suit un flot legitime traverse donc bel et bien pendant les deux
//  cycles du pipeline, et l'aval a pu l'accepter. Quand le verdict tombe et
//  qu'on termine en SLVERR vers le maitre, ce B reel doit etre avale -- c'est le
//  meme raisonnement anti-wedge que pour block_req_i.
//
//  Dans le mode d'attente pur (~legit_hit sans verdict), rien n'a ete accepte en
//  aval et le maitre doit garder la main sur ses propres ready.
//
//  COUPURE DU CANAL W (correctif du « W orphelin », 2026-09-09).
//  Couper AW sans couper W laissait l'aval avaler les donnees d'une ecriture
//  dont il ne recevrait jamais l'adresse : le canal W du crossbar restait
//  decale d'un beat et le premier acces CPU par ce chemin ne revenait plus.
//  C'est le gel isole par la sonde du 2026-09-09 -- specifique aux ecritures,
//  puisqu'une lecture n'a pas de canal W.
//
//  On coupe donc W dans la meme fenetre que AW, mais SOUS GARDE : uniquement
//  quand w_cut_allowed_i dit qu'aucun AW deja admis en aval n'attend ses
//  donnees. Sans cette garde on retomberait sur le Bug #16 (couper W tue les
//  transactions deja acceptees et l'interconnexion meurt). Le wrapper calcule la
//  garde a partir des handshakes reels de l'aval.
// =============================================================================
module request_manager #(
    parameter type req_iommu_t = logic
)(
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        legit_hit,
    input  logic        block_req_i,
    input  logic        bad_id_i,        // verdict rendu, et mauvais
    input  logic        verdict_known_i, // le verdict de la requete presentee est rendu
    input  logic        w_pending_i,     // un AW admis en aval attend ses donnees

    //  INTERDICTION DE COUPER UN VALID DEJA PRESENTE (correctif 2026-09-10,
    //  derriere CTRL[3], donc inactif par defaut).
    //
    //  La coupure ci-dessous est COMBINATOIRE : si le maitre avait deja
    //  aw_valid haut en attente de son aw_ready et que block_req_i monte, ARMOR
    //  RETIRE ce VALID. AXI4 l'interdit -- un VALID asserte doit etre tenu
    //  jusqu'au READY -- et un IOMMU qui a commence une traduction sur ce VALID
    //  peut en garder un etat partiel. Mesure : c'est ce qui se produit sur
    //  SC04-MSI (cause block_req) et SC01-SPOOF (cause bad_id) en simulation.
    //
    //  Ces deux signaux valent 1 quand un VALID a ete presente au cycle
    //  precedent sans obtenir son READY : la coupure est alors differee au
    //  prochain cycle ou le canal est libre. Le cout est UNE requete deja
    //  presentee qui aboutit en aval ; response_manager la termine tout de meme
    //  vers le maitre, et request_manager avale sa reponse (b_ready/r_ready
    //  forces), donc rien ne s'accumule.
    input  logic        no_cut_aw_i,
    input  logic        no_cut_ar_i,

    //  BLOCAGE TRANSACTIONNEL (CTRL[6]). Une ecriture dont l'AW est deja admis
    //  en aval doit se terminer normalement : sa reponse B appartient au maitre
    //  et ne doit pas etre avalee par le drainage anti-wedge, sinon le maitre
    //  attend une reponse que personne ne lui rendra.
    input  logic        txblock_en_i,

    //  MAINTIEN DES REPONSES FABRIQUEES (CTRL[8] RESP_HOLD). Tant que
    //  response_manager tient un B/R FABRIQUE vers le maitre, le ready du maitre
    //  appartient a cette reponse-la : le transmettre a l'aval y ferait prendre
    //  en meme temps une reponse reelle, perdue. Sans effet pendant le drainage
    //  anti-wedge, qui avale deja les reponses de l'aval.
    input  logic        hold_b_i,
    input  logic        hold_r_i,

    input  req_iommu_t  req_IP_wrapper_i,
    output req_iommu_t  req_wrapper_iommu_o
);

    always_comb begin
        req_wrapper_iommu_o = req_IP_wrapper_i;

        // Blocage, ID refuse, ou VERDICT PAS ENCORE RENDU : seuls AW et AR sont
        // coupes. La troisieme condition est le correctif du gel -- sans elle,
        // `legit_hit` etant un niveau perime, une requete d'attaque traversait
        // pendant 2 cycles, l'aval l'acceptait, et l'absence de W qui suivait le
        // SLVERR coincait le canal d'ecriture du crossbar.
        if (block_req_i || !legit_hit || !verdict_known_i) begin
            //  no_cut_*_i differe la coupure d'un VALID deja presente, pour ne
            //  pas violer AXI4. A 0 (defaut) le comportement est inchange.
            if (!no_cut_aw_i) req_wrapper_iommu_o.aw_valid = 1'b0;
            if (!no_cut_ar_i) req_wrapper_iommu_o.ar_valid = 1'b0;
        end

        // Un beat W ne part JAMAIS avant que son AW n'ait ete admis en aval.
        // Couper W seulement pendant la fenetre de blocage ne suffit pas : aux
        // bords du blocage plus aucune condition de coupure n'est vraie, et
        // l'aval avale un W bien plus vite qu'il n'accepte un AW (celui-ci
        // traverse la traduction IOMMU). Des qu'un AW est du, les beats passent
        // librement : le Bug #16 reste couvert.
        if (!w_pending_i)
            req_wrapper_iommu_o.w_valid = 1'b0;

        // Blocage effectif : on avale les reponses en vol (anti-wedge).
        //
        // EXCEPTION sous CTRL[6] : si une ecriture est engagee en aval
        // (w_pending), son B revient au MAITRE, qui l'attend. L'avaler
        // reintroduirait le blocage du maitre que le drainage existe pour
        // eviter -- par l'autre bout.
        if ((block_req_i || bad_id_i) && !(txblock_en_i && w_pending_i)) begin
            req_wrapper_iommu_o.b_ready = 1'b1;
            req_wrapper_iommu_o.r_ready = 1'b1;
        end else begin
            //  RESP_HOLD : une reponse fabriquee est tenue vers le maitre, son
            //  ready lui appartient. Aucune reponse reelle n'est prise en aval
            //  pendant ce temps -- elle y reste presentee, et passera ensuite.
            if (hold_b_i) req_wrapper_iommu_o.b_ready = 1'b0;
            if (hold_r_i) req_wrapper_iommu_o.r_ready = 1'b0;
        end
    end

endmodule
