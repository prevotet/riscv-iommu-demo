`timescale 1ns/1ps

// =============================================================================
//  response_manager — retour combinatoire des reponses vers l'IP
//
//  Voir request_manager pour la raison du passage en combinatoire.
//
//  Point essentiel : quand la requete est bloquee, il ne suffit pas de couper
//  les valid en aval. Le ready de l'IOMMU traverse jusqu'au maitre ; s'il
//  restait visible, le maitre verrait valid && ready et considererait sa
//  requete acceptee alors qu'elle n'a jamais quitte le wrapper. On masque donc
//  aussi les ready pendant un blocage, ce qui fait simplement caler le maitre.
// =============================================================================
module response_manager #(
    parameter type resp_slv_t = logic
)(
    input  logic       clk_i,
    input  logic       rst_ni,
    input  logic       block_ip_i,
    input  logic       block_req_i,
    input  resp_slv_t  resp_wrapper_iommu_i,
    output resp_slv_t  resp_IP_wrapper_o
);

    always_comb begin
        resp_IP_wrapper_o = resp_wrapper_iommu_i;

        if (block_ip_i) begin
            // IP bannie : plus rien ne remonte.
            resp_IP_wrapper_o = '0;
        end else if (block_req_i) begin
            // Blocage transitoire : on cale le maitre en retirant les ready,
            // les reponses deja en vol restent valides.
            resp_IP_wrapper_o.aw_ready = 1'b0;
            resp_IP_wrapper_o.w_ready  = 1'b0;
            resp_IP_wrapper_o.ar_ready = 1'b0;
        end
    end

endmodule
