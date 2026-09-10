`timescale 1ns/1ps

// =============================================================================
//  w_skid_buffer — etage d'un emplacement sur le canal W
//
//  POURQUOI IL EXISTE. Mesure du 2026-09-10, campagne
//  results/bench_2026-09-10_160512.log : sur 901 iterations, une seule porte un
//  retrait de VALID, et c'est celle ou ARMOR coupe (`cut=4` -> `retr=0/0/4/0`,
//  troisieme champ = canal W). Correlation sans exception : 900 iterations a
//  cut=0 donnent zero retrait.
//
//  La regle en cause, dans request_manager :
//
//      if (!w_pending_i) req_wrapper_iommu_o.w_valid = 1'b0;
//
//  Elle est COMBINATOIRE. Quand `w_owed` retombe a zero alors que le maitre a
//  encore un beat presente en aval non acquitte, ARMOR retire ce w_valid. AXI4
//  l'interdit, et retirer un VALID de DONNEE desynchronise le canal d'ecriture --
//  la panne qui coince le W du crossbar partage.
//
//  Cette regle est elle-meme le correctif du « W orphelin » du 2026-09-09 : il a
//  echange une violation AXI4 contre une autre.
//
//  CE QUE CET ETAGE CHANGE. La decision de couper est prise A LA CAPTURE et non
//  a la presentation. Un beat n'entre dans l'etage que si l'on a le droit de
//  l'emettre ; une fois entre, il est presente en aval et TENU jusqu'a son
//  w_ready, quoi que devienne `w_pending` entre-temps. Un beat qu'on n'a pas le
//  droit d'emettre n'est simplement pas capture, et le maitre le garde -- ce qui
//  est licite, un maitre peut attendre.
//
//  LES DEUX COTES BOUGENT ENSEMBLE, et c'est le point. Une premiere tentative de
//  correctif sur le canal AW s'etait contentee de tenir le VALID : les retraits
//  etaient passes de 1 a 33, parce que response_manager fabrique `w_ready = 1`
//  vers le maitre pendant un blocage. Le maitre croyait son beat absorbe et
//  passait au suivant. D'ou la regle : ARMOR ne doit NI retirer un VALID
//  presente, NI acquitter vers le maitre ce qui est encore presente en aval. Le
//  ready rendu au maitre est donc « il y a de la place dans l'etage », jamais le
//  ready de l'aval.
//
//  DERIVATION. `en_i` a 0 rend l'etage totalement transparent, au fil pres : le
//  MEME bitstream sert donc a mesurer la violation et a verifier sa disparition,
//  comme cela a permis de refuter la tentative precedente sans y perdre une
//  synthese.
//
//  COUT. Un cycle de latence sur le canal W quand l'etage est actif, et un
//  emplacement de registre de la largeur du canal. Le canal W n'est pas sur le
//  chemin de la latence de detection : `det` se mesure de la presentation de
//  l'adresse au premier verdict, l'etage n'y entre pas.
// =============================================================================
module w_skid_buffer #(
    parameter type w_chan_t = logic
)(
    input  logic    clk_i,
    input  logic    rst_ni,

    //  Derivation : a 0, transparent.
    input  logic    en_i,

    //  Cote maitre (sortie de request_manager, deja filtree).
    input  w_chan_t w_i,
    input  logic    w_valid_i,
    output logic    w_ready_o,     // « il y a de la place », jamais le ready aval

    //  Cote aval.
    output w_chan_t w_o,
    output logic    w_valid_o,
    input  logic    w_ready_i
);

    w_chan_t w_q;
    logic    full_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            full_q <= 1'b0;
            w_q    <= '0;
        end else if (!en_i) begin
            //  En derivation, on garde l'etage vide : basculer en_i a 1 part
            //  alors d'un etat propre.
            full_q <= 1'b0;
        end else begin
            //  Vidange et remplissage peuvent avoir lieu dans le meme cycle :
            //  le beat sortant laisse la place au suivant sans bulle.
            if (full_q && w_ready_i) full_q <= 1'b0;

            if (w_valid_i && (!full_q || w_ready_i)) begin
                full_q <= 1'b1;
                w_q    <= w_i;
            end
        end
    end

    always_comb begin
        if (!en_i) begin
            //  Transparent : les trois signaux traversent, l'atomicite du
            //  handshake est preservee comme dans la version d'origine.
            w_o       = w_i;
            w_valid_o = w_valid_i;
            w_ready_o = w_ready_i;
        end else begin
            w_o       = w_q;
            w_valid_o = full_q;
            //  De la place s'il est vide, ou s'il se vide dans ce cycle.
            w_ready_o = ~full_q | w_ready_i;
        end
    end

endmodule
