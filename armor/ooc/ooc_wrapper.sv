// =============================================================================
//  Enveloppe de synthese HORS CONTEXTE du wrapper ARMOR
//
//  A quoi ca sert. Le papier annonce 180 LUT et 157 bascules par wrapper. La
//  seule mesure disponible jusqu'ici etait l'utilisation PAR HIERARCHIE d'une
//  synthese complete -- 2 676 LUT et 1 927 bascules au v15 -- mais Vivado y
//  optimise a travers les frontieres de hierarchie, et ce chiffre depend donc
//  de ce qui entoure le wrapper. Une synthese hors contexte du module seul est
//  la source defendable pour un article.
//
//  Pourquoi une enveloppe et pas le module directement : les types des canaux
//  AXI sont des PARAMETRES DE TYPE dont la valeur par defaut est `logic`.
//  Synthetiser `wrapper` tel quel donnerait un module d'un bit de large, et un
//  chiffre de surface qui ne voudrait rien dire. Cette enveloppe lie les memes
//  types que `ariane_peripherals_xilinx.sv`, et rien d'autre : elle n'ajoute
//  aucune logique, seulement des ports.
//
//  PROFIL : synthetiser avec +define+BENCH_PROFILE. En profil DEMO les durees
//  de blocage valent 750 000 000 cycles au lieu de 4 et 10, soit des compteurs
//  de 30 bits au lieu de 3 : ce n'est pas le meme circuit, et c'est le profil
//  BENCH qui est evalue dans le papier.
//
//  Usage : armor/ooc/run_ooc.sh
// =============================================================================
module ooc_wrapper (
    input  logic                       clk_i,
    input  logic                       rst_ni,
    input  ariane_axi_soc::req_mmu_t   req_IP_wrapper_i,
    output ariane_axi_soc::resp_slv_t  resp_IP_wrapper_o,
    input  ariane_axi_soc::resp_slv_t  resp_wrapper_iommu_i,
    output ariane_axi_soc::req_mmu_t   req_wrapper_iommu_o,
    input  ariane_axi_soc::req_slv_t   req_CPU_Wrapper__i,
    output ariane_axi_soc::resp_slv_t  resp_CPU_Wrapper_o,
    output logic [4:0]                 armor_verdict_o,
    output logic                       irq_o
);

    wrapper #(
        .IdWidth            ( ariane_soc::IdWidth - 1       ),
        .IdWidthSlv         ( ariane_soc::IdWidthSlave      ),
        .AddrWidth          ( 64                            ),
        .UserWidth          ( 1                             ),
        .DevIDWidth         ( 24                            ),
        .ProcIDWidth        ( 20                            ),
        .DataWidth          ( 64                            ),
        .StrbWidth          ( 64 / 8                        ),
        .aw_chan_extended_t ( ariane_axi_soc::aw_chan_mmu_t ),
        .aw_chan_slv_t      ( ariane_axi_soc::aw_chan_slv_t ),
        .aw_chan_t          ( ariane_axi_soc::aw_chan_t     ),
        .w_chan_t           ( ariane_axi_soc::w_chan_t      ),
        .b_chan_t           ( ariane_axi_soc::b_chan_t      ),
        .b_chan_slv_t       ( ariane_axi_soc::b_chan_slv_t  ),
        .ar_chan_extended_t ( ariane_axi_soc::ar_chan_mmu_t ),
        .ar_chan_slv_t      ( ariane_axi_soc::ar_chan_slv_t ),
        .ar_chan_t          ( ariane_axi_soc::ar_chan_t     ),
        .r_chan_t           ( ariane_axi_soc::r_chan_t      ),
        .r_chan_slv_t       ( ariane_axi_soc::r_chan_slv_t  ),
        .req_t              ( ariane_axi_soc::req_t         ),
        .req_slv_t          ( ariane_axi_soc::req_slv_t     ),
        .resp_t             ( ariane_axi_soc::resp_t        ),
        .resp_slv_t         ( ariane_axi_soc::resp_slv_t    ),
        .req_iommu_t        ( ariane_axi_soc::req_mmu_t     )
    ) i_wrap (
        .clk_i                ( clk_i                ),
        .rst_ni               ( rst_ni               ),
        .req_IP_wrapper_i     ( req_IP_wrapper_i     ),
        .resp_IP_wrapper_o    ( resp_IP_wrapper_o    ),
        .resp_wrapper_iommu_i ( resp_wrapper_iommu_i ),
        .req_wrapper_iommu_o  ( req_wrapper_iommu_o  ),
        .req_CPU_Wrapper__i   ( req_CPU_Wrapper__i   ),
        .resp_CPU_Wrapper_o   ( resp_CPU_Wrapper_o   ),
        .armor_verdict_o      ( armor_verdict_o      ),
        .irq_o                ( irq_o                )
    );

endmodule
