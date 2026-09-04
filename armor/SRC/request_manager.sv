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
//  cette version : les signaux traversent dans le meme cycle, et le blocage se
//  contente de masquer les valid. Le masquage des ready correspondants est
//  fait par response_manager, sans quoi le maitre croirait son handshake
//  accepte alors que la requete n'est jamais partie.
// =============================================================================
module request_manager #(
    parameter type req_iommu_t = logic
)(
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        legit_hit,
    input  logic        block_req_i,
    input  req_iommu_t  req_IP_wrapper_i,
    output req_iommu_t  req_wrapper_iommu_o
);

    logic block;
    assign block = block_req_i | ~legit_hit;

    always_comb begin
        req_wrapper_iommu_o = req_IP_wrapper_i;
        if (block) begin
            req_wrapper_iommu_o.aw_valid = 1'b0;
            req_wrapper_iommu_o.w_valid  = 1'b0;
            req_wrapper_iommu_o.ar_valid = 1'b0;
            req_wrapper_iommu_o.r_ready  = 1'b0;
        end
    end

endmodule
