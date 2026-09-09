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
            req_wrapper_iommu_o.aw_valid = 1'b0;
            req_wrapper_iommu_o.ar_valid = 1'b0;
        end

        // Blocage effectif : on avale les reponses en vol (anti-wedge).
        if (block_req_i || bad_id_i) begin
            req_wrapper_iommu_o.b_ready = 1'b1;
            req_wrapper_iommu_o.r_ready = 1'b1;
        end
    end

endmodule
