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
    parameter type resp_slv_t = logic
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

    input  resp_slv_t  resp_wrapper_iommu_i,
    output resp_slv_t  resp_IP_wrapper_o
);

    always_comb begin
        if ((block_ip_i || block_req_i || bad_id_i)
            && !(txblock_en_i && w_pending_i)) begin
            // ---- Terminaison de bus gracieuse (SLVERR) ----
            resp_IP_wrapper_o = '0;

            // Absorption des requetes encore presentees par l'accelerateur.
            resp_IP_wrapper_o.aw_ready = 1'b1;
            resp_IP_wrapper_o.ar_ready = 1'b1;

            //  W : on n'absorbe de force que s'il n'y a RIEN a acheminer. Des
            //  qu'un AW est du en aval, ses beats doivent partir pour de vrai --
            //  on rend donc le ready de l'etage, pas un 1 fabrique. Sans cette
            //  distinction, le maitre avancerait pendant qu'un beat est encore
            //  presente en aval : c'est exactement le defaut mesure.
            if (wskid_en_i && w_pending_i)
                resp_IP_wrapper_o.w_ready = wskid_ready_i;
            else
                resp_IP_wrapper_o.w_ready = 1'b1;

            // Reponse d'ecriture : SLVERR.
            resp_IP_wrapper_o.b_valid  = 1'b1;
            resp_IP_wrapper_o.b.resp   = 2'b10;

            // Reponse de lecture : SLVERR, un seul beat.
            resp_IP_wrapper_o.r_valid  = 1'b1;
            resp_IP_wrapper_o.r.resp   = 2'b10;
            resp_IP_wrapper_o.r.last   = 1'b1;

        end else if (!legit_hit || !verdict_known_i) begin
            // ---- Verdict d'ID en cours (2 cycles) : on tient le maitre ----
            resp_IP_wrapper_o = '0;

        end else begin
            // ---- IP legitime : passe-plat ----
            resp_IP_wrapper_o = resp_wrapper_iommu_i;

            // request_manager retient w_valid tant qu'aucun AW n'est admis en
            // aval. Or l'aval maintient son w_ready en permanence : le laisser
            // traverser ferait croire au maitre que son beat est parti alors
            // qu'on vient de le retenir, et la donnee serait perdue. On masque
            // donc w_ready dans exactement la meme fenetre.
            if (wskid_en_i)
                //  Le handshake du maitre se fait contre l'etage : de la place
                //  et un AW du, sinon le maitre attend. Il ne voit plus jamais
                //  le ready de l'aval sur ce canal.
                resp_IP_wrapper_o.w_ready = wskid_ready_i & w_pending_i;
            else if (!w_pending_i)
                resp_IP_wrapper_o.w_ready = 1'b0;
        end
    end

endmodule
