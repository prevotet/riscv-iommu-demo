`timescale 1ns/1ps






module wrapper #(

    parameter IdWidth      = 4,
    parameter IdWidthSlv   = 6, // pour les interactions processeur-périphériques
    parameter AddrWidth    = 64,
    parameter UserWidth    = 1,
    parameter DevIDWidth   = 24, //taille du device ID
    parameter ProcIDWidth  = 20, // taille du process ID 
    //parameter SubIDWidth   = 24, // taille de l'identifiant dynamique du wrapper
    parameter DataWidth    = 64,
    parameter StrbWidth    = DataWidth / 8,


    parameter type aw_chan_extended_t  = logic,
    parameter type aw_chan_slv_t       = logic,
    parameter type aw_chan_t           = logic,
    parameter type w_chan_t            = logic,
    parameter type b_chan_t            = logic,
    parameter type b_chan_slv_t        = logic,
    parameter type ar_chan_extended_t  = logic,
    parameter type ar_chan_slv_t       = logic,
    parameter type ar_chan_t           = logic,
    parameter type r_chan_t            = logic,
    parameter type r_chan_slv_t        = logic,
    parameter type req_t               = logic,
    parameter type req_slv_t           = logic,
    parameter type resp_t              = logic,
    parameter type resp_slv_t          = logic,
    parameter type req_iommu_t           = logic


)(

    input  logic    clk_i,
    input  logic    rst_ni,




    // IP-Wrapper Interface (Slave)
    input   req_iommu_t   req_IP_wrapper_i,
    output  resp_slv_t    resp_IP_wrapper_o,  //change it to resp_t when integration of the iommu 
    
    

    // Wrapper-IOMMU Interface (Master)


    input   resp_slv_t    resp_wrapper_iommu_i, //change it to resp_t when integration of the iommu 
    output  req_iommu_t   req_wrapper_iommu_o,
    
    
    //CPU_Wrapper Interface   (Slave)

    input   req_slv_t       req_CPU_Wrapper__i,
    output  resp_slv_t      resp_CPU_Wrapper_o,

    // Verdicts remontes a l'IP surveillee, pour son registre STATUS :
    // {MSI, OUTS, STORM, BANNED, BLOCKED} = armor_status[7:3].
    // Signaux instantanes : c'est a l'IP de les memoriser si elle veut les
    // observer apres coup (accel_wrap le fait par transaction).
    output  logic [4:0]     armor_verdict_o,

    // Interruption de niveau vers le PLIC (v13). Haute tant qu'une alerte
    // collante non acquittee subsiste et que CTRL[11] est arme.
    //
    // POURQUOI DU NIVEAU, ET PAS UNE IMPULSION. Les verdicts de flux ne durent
    // que BLOCK_CYCLES -- 4 et 10 cycles en profil BENCH. Une impulsion de cette
    // largeur serait manquee par un PLIC echantillonne, et le logiciel entrant
    // dans son gestionnaire ne trouverait rien a lire dans STATUS : c'est
    // exactement le piege qui a fait mesurer k = 0 partout au niveau 0. Le
    // registre collant, lui, retient l'evenement jusqu'a son acquittement.
    //
    // ACQUITTEMENT : le STICKY_CLR qui existe deja (CTRL[1]). Le gestionnaire
    // lit STICKY, evalue, ecrit sa politique avec STICKY_CLR, et l'interruption
    // retombe dans la meme ecriture. Aucun registre nouveau, aucun chemin
    // d'acquittement separe a desynchroniser.
    output  logic           irq_o




    
);

// =============================================================================
// Profil de bitstream : DEMO (defaut) vs BENCH (`+define+BENCH_PROFILE`)
//
//   DEMO  : blocages longs (~15 s @50 MHz), fenetre de flux large, seuil MSI bas
//           -> penalite visible a l'oeil pour la demo interactive (main.c)
//   BENCH : blocages courts (~2 ms), fenetre courte, seuil MSI haut
//           -> permet d'enchainer les iterations de bench_runner.c
//
// Les seuils de *detection* (MAX_FAILURES, MAX_REQ_PER_WINDOW, MAX_OUTSTANDING,
// MAX_RATIO_MSI_DMA) sont volontairement identiques dans les deux profils :
// seules les durees de reaction et le seuil MSI changent.
//
// Activation cote Vivado :
//   set_property verilog_define {BENCH_PROFILE} [current_fileset]
// =============================================================================
`ifdef BENCH_PROFILE
    localparam logic [31:0] BLOCK_DURATION_C     = 32'd100_000;  // ~2 ms @50 MHz
    localparam int unsigned FLOW_WINDOW_C        = 100;
    localparam int unsigned FLOW_BLOCK_CYCLES_C  = 4;
    localparam int unsigned OUTS_BLOCK_CYCLES_C  = 10;
    localparam int unsigned MAX_MSI_C            = 32;
`else // profil DEMO
    localparam logic [31:0] BLOCK_DURATION_C     = 32'd750_000_000;  // ~15 s @50 MHz
    localparam int unsigned FLOW_WINDOW_C        = 50_000;
    localparam int unsigned FLOW_BLOCK_CYCLES_C  = 750_000_000;
    localparam int unsigned OUTS_BLOCK_CYCLES_C  = 750_000_000;
    localparam int unsigned MAX_MSI_C            = 4;
`endif

resp_slv_t resp_delayed;

logic [DevIDWidth-1:0] Device_ID_o;                         //Extracted_ID
logic                  Device_ID_write_enable_o;
logic                  legit_hit;
logic                  block_ip_o; 
logic [DevIDWidth-1:0] fixed_ID_reg;                        // Fixed ID register
logic                  comparison_valid;
logic [7:0]            failure_count;
logic                  threat_detected;
logic                  storm_flag;
logic                  block_req_flow;
logic                  block_req_i;  // signal final pour le request_manager
logic                  req_fire_signal;
logic                  overflow_flag_outs;
logic                  block_req_outs;
logic [AddrWidth-1:0]  extracted_address;
logic                  address_valid;
logic                  is_write_req;
logic                  is_read_req;
logic [AddrWidth-1:0]  msi_address_config;    // Configuré par le CPU
logic                  is_msi_interrupt;
logic                  is_dma;
logic                  msi_comparison_valid;
logic                  msi_storm;
logic                  block_msi;


// Registres de configuration/statut ARMOR — declares ici car referencés
// des la gate ci-dessous ; leur logique est en fin de module.
//  6 bits depuis le v17 : les 32 emplacements de 8 octets etaient tous pris et
//  l'observation d'adresses en demandait deux de plus. La fenetre MMIO de
//  chaque wrapper fait 4 Kio (0x5000_2000 et 0x5000_3000), donc 64 registres
//  n'empietent sur rien. Les litteraux 5'dN des case existants s'etendent
//  d'eux-memes a 6 bits : aucun n'est a reecrire.
localparam int unsigned CSR_IDX_W = 6;   // 64 registres de 8 octets
// bits [11:3] + [14] bad_id. Les bits [12] legit_hit et [13] ENFORCE restent
// exclus : ce sont des echos d'etat, les rendre collants n'apprendrait rien.
localparam logic [63:0] ARMOR_STICKY_MASK = 64'h0000_0000_0000_4FF8;

logic [63:0]            csr_id_cfg_q;
logic [63:0]            csr_msi_addr_q;
logic                   csr_enforce_q;
logic                   csr_awfix_q;      // CTRL[3] : ne pas retirer un VALID
logic                   csr_wskid_q;      // CTRL[4] : etage W (skid buffer)
logic                   csr_fresh_q;      // CTRL[5] : verdict FRAIS exige
logic                   csr_txblk_q;      // CTRL[6] : blocage transactionnel
logic                   csr_wcap_q;       // CTRL[7] : dette W comptee a la capture
logic                   csr_rhold_q;      // CTRL[8] : reponses B/R tenues jusqu'au ready
logic                   csr_wfate_q;      // CTRL[9] : sort de chaque AW, W des AW coupes absorbe
logic                   csr_bfate_q;      // CTRL[10] : sort de chaque ecriture cote B, un B par AW
logic                   csr_irqen_q;      // CTRL[11] : interruption armee (v13)
logic                   csr_rfmcnt_q;     // CTRL[12] : moniteur de flux compte les transferts (v14)
logic [7:0]             csr_thresh_q;     // CTRL[23:16] : seuil de flux, 0 = valeur de synthese (v15)
logic [63:0]            csr_sticky_q;
logic [31:0]            cnt_banned_q, cnt_storm_q, cnt_outs_q, cnt_msi_q;
logic [DevIDWidth-1:0]  dev_id_last_q;
logic                   csr_sticky_clr, csr_cnt_clr;

// Remontees d'observabilite des moniteurs (aucun effet fonctionnel).
logic [7:0]             outs_depth;      // profondeur outstanding courante
logic [7:0]             flow_req_cnt;    // requetes comptees dans la fenetre
logic [31:0]            flow_window_cnt; // position dans la fenetre

// =============================================================================
//  OCCUPATION DE LA FENETRE DE FLUX (v14).
//
//  Le seul chiffre qui manquait pour interpreter un faux negatif de SC02. Le
//  log dit combien de salves ont leve STORM, jamais de combien les autres sont
//  passees sous le seuil -- or une salve de 16 requetes etalee sur trois
//  fenetres de 100 cycles n'en met que cinq ou six dans chacune, et aucun
//  moniteur a fenetre ne peut la voir. Sans ces deux compteurs, cette
//  explication reste une hypothese deduite des latences logicielles.
//
//    cnt_reqmax_q : la plus forte occupation atteinte, toutes fenetres
//                   confondues -- a comparer a MAX_REQ_PER_WINDOW = 8. C'est la
//                   marge, en clair.
//    cnt_winact_q : nombre de fenetres FERMEES en ayant compte au moins une
//                   requete. Avec cnt_req_up_q, il donne l'occupation MOYENNE
//                   d'une fenetre active, donc le debit reel de l'attaque tel
//                   que le moniteur le voit -- et non tel que la Table 5
//                   l'annonce.
// =============================================================================
logic [7:0]             cnt_reqmax_q;
logic [23:0]            cnt_winact_q;

// =============================================================================
//  FILIGRANE DE LA PROFONDEUR D'EN-VOL (v16).
//
//  Le moniteur d'outstanding expose sa profondeur INSTANTANEE (outs_depth,
//  echo dans DBG_STATE[31:24]), et rien d'autre. Le 2026-09-13 sur carte, ses
//  verdicts passent de 32,3 par campagne a 0,3 des que du trafic legitime
//  partage le bus -- plages disjointes sur six campagnes par bras. L'explication
//  proposee est que l'attaquant, ralenti, n'accumule plus assez de lectures en
//  vol pour franchir le seuil de 16 ; mais elle reste une DEDUCTION a partir des
//  compteurs de requetes et de blocage, parce qu'aucun registre ne garde le
//  maximum atteint.
//
//  Ce filigrane le dit directement : si la campagne sous fond lit 9 la ou celle
//  sans fond lit 24, le mecanisme est etabli ; si elle lit 16 ou plus, c'est
//  autre chose et l'hypothese tombe. Remis a zero par CNT_CLR comme les autres.
// =============================================================================
logic [7:0]             cnt_outsmax_q;
logic                   flow_win_close;  // dernier cycle de la fenetre courante

assign flow_win_close = (flow_window_cnt == FLOW_WINDOW_C - 1);

// Signaux effectifs, apres la gate ENFORCE (CTRL[0], cf. bloc CSR en fin de
// module). ENFORCE = 0 -> le wrapper laisse tout passer et se contente
// d'observer ; ENFORCE = 1 -> comportement ARMOR complet.
logic legit_hit_eff;
logic block_ip_eff;

assign block_req_i   = csr_enforce_q &
                       (block_ip_o | block_req_flow | block_req_outs | block_msi);

// request_manager bloque toute requete dont legit_hit est nul. Forcer
// legit_hit_eff a 1 quand ENFORCE = 0 est ce qui rend le wrapper reellement
// transparent — sans cela, un ID_CFG non configure fermerait le chemin.
assign legit_hit_eff = legit_hit | ~csr_enforce_q;
assign block_ip_eff  = block_ip_o &  csr_enforce_q;

// -----------------------------------------------------------------------------
//  Verdict d'identifiant rendu, et mauvais  (correctif du 2026-09-09)
//
//  `legit_hit` seul ne distingue pas « pas encore compare » de « compare et
//  refuse » : les deux valent 0. response_manager traitait donc les deux en mode
//  HOLD et tenait le maitre jusqu'a SON timeout (65536 cycles cote accel_wrap,
//  1,31 ms a 50 MHz). Comme ID_extractor ne relance une comparaison que sur un
//  FRONT de AxVALID et qu'une requete tenue n'en produit aucun, les
//  MAX_FAILURES = 3 fautes necessaires au bannissement ne pouvaient s'accumuler
//  qu'au rythme des timeouts du maitre : ~3,9 ms avant qu'ARMOR ne reagisse.
//
//  verdict_known_q porte la distinction manquante. Il se leve quand
//  comparison_valid rend le verdict de la requete presentee, et retombe des que
//  plus rien n'est presente, pour que la requete suivante reparte proprement de
//  son etat « pas encore compare ».
//
//  Note pour la mesure : ceci ne coute rien au trafic legitime. bad_id ne peut
//  se lever que si legit_hit vaut 0, et sur un flot au meme identifiant
//  legit_hit reste a 1 -- le chemin reste le passe-plat combinatoire.
logic verdict_known_q;
logic bad_id;

//  La validite suit le PIPELINE, pas les canaux AXI. Premiere version de ce
//  correctif : verdict_known_q etait efface des que ni aw_valid ni ar_valid
//  n'etaient presentes. Le banc a montre l'erreur -- une fois l'AW absorbe, le
//  maitre passe en phase W, plus rien n'est "presente", le verdict s'effaçait au
//  milieu de la transaction et response_manager repassait en HOLD : w_ready
//  disparaissait et l'accelerateur calait jusqu'a son timeout, exactement le
//  comportement qu'on voulait supprimer.
//
//  On se cale donc sur les deux evenements du pipeline d'identifiant :
//    - Device_ID_write_enable_o : une nouvelle comparaison DEMARRE -> inconnu ;
//    - comparison_valid         : elle REND son verdict            -> connu.
//  Le verdict reste alors valable pour toute la duree de la transaction, et
//  jusqu'a la requete suivante.
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        verdict_known_q <= 1'b0;
    end else if (Device_ID_write_enable_o) begin
        verdict_known_q <= 1'b0;
    end else if (comparison_valid) begin
        verdict_known_q <= 1'b1;
    end
end

// comparison_valid est inclus pour ne pas perdre un cycle : au cycle ou il
// pulse, ids_match_reg porte deja le verdict frais (meme always_ff dans
// id_comparator).
assign bad_id = csr_enforce_q & (comparison_valid | verdict_known_q) & ~legit_hit;

// -----------------------------------------------------------------------------
//  Verdict CONNU — condition d'admission en aval (correctif du gel, 2026-09-09)
//
//  `legit_hit` est un NIVEAU : il reste à la valeur de la comparaison précédente
//  pendant les 2 cycles où la comparaison en cours n'a pas encore rendu. Une
//  requête d'attaque qui suit un flot légitime traversait donc, et l'IOMMU
//  l'acceptait. Quand le verdict tombait, response_manager terminait la
//  transaction côté maître par un SLVERR et l'accélérateur n'envoyait JAMAIS ses
//  beats W : il restait en aval une écriture acceptée attendant ses données pour
//  toujours. L'IOMMU rentrant dans le XBAR pour atteindre la DRAM, le canal W du
//  crossbar se coinçait et le premier accès CPU empruntant ce chemin ne revenait
//  pas -- le gel observé sur SC01 puis, une fois SC01 déplacé, sur SC02.
//
//  On n'admet donc plus rien en aval tant que le verdict de la requête PRÉSENTÉE
//  n'est pas rendu. Cela ferme aussi la fenêtre de contournement : jusqu'ici, une
//  requête usurpée arrivant juste après un flot légitime passait.
//
//  ENFORCE = 0 -> toujours « connu », le wrapper reste un passe-plat intégral.
logic verdict_known_eff;
// -----------------------------------------------------------------------------
//  VERDICT FRAIS EXIGE  (CTRL[5], 2026-09-10)
//
//  LA FENETRE QUE CECI FERME. `Device_ID_write_enable_o` est REGISTRE dans
//  ID_extractor : front de aw_valid a T, signal a T+1, et `verdict_known_q` ne
//  retombe donc qu'a T+2. Pendant T et T+1, l'adresse presentee est jugee sur le
//  verdict de la requete PRECEDENTE.
//
//  Aujourd'hui rien ne passe par cette fenetre -- mesure sur SC01 :
//  `req up=8 dn=0`, les huit requetes usurpees sont coupees. Mais c'est la
//  LENTEUR de l'aval qui la referme (l'AW attend sa traduction IOMMU plus de
//  deux cycles), pas la logique d'ARMOR. Une garantie de securite qui repose sur
//  un accident de timing n'est pas une garantie.
//
//  ET C'EST CE QUI BLOQUE LE BLOCAGE TRANSACTIONNEL. Le principe « une adresse
//  presentee est engagee » transformerait ce rate de justesse en ADMISSION d'une
//  ecriture usurpee. Il faut donc fermer cette fenetre AVANT, jamais apres.
//
//  `verdict_stale` vaut 1 des le cycle ou une requete se presente et jusqu'a ce
//  que SA comparaison rende. Le front est pris de facon COMBINATOIRE -- c'est
//  tout l'objet du correctif, l'etat registre arrivant deux cycles trop tard.
//
//  CE QUE CA COUTE, mesure au banc et non estime : +2 CYCLES par transaction
//  legitime (lecture 20 -> 22, ecriture 21 -> 23). J'avais d'abord ecrit ici
//  « aucune latence ajoutee », en raisonnant que l'admission reprenait a T+2
//  comme aujourd'hui. C'est faux : aujourd'hui l'adresse est presentee des T et
//  souvent ACCEPTEE la, deux cycles plus tot -- precisement parce qu'ARMOR la
//  laisse sortir avant de savoir si elle est legitime.
//
//  Ces 2 cycles sont donc le PRIX du controle d'identite reellement effectue
//  avant emission. Sans eux, la garantie ne tient que parce que l'IOMMU est plus
//  lent que la fenetre de fuite. C'est le chiffre a publier comme surcout
//  d'ARMOR sur paquet valide, et il est honnete.
// -----------------------------------------------------------------------------
logic aw_v_in_q, ar_v_in_q;
logic aw_edge_raw, ar_edge_raw;
logic verdict_pending_q, verdict_stale, verdict_fresh;

assign aw_edge_raw = req_IP_wrapper_i.aw_valid & ~aw_v_in_q;
assign ar_edge_raw = req_IP_wrapper_i.ar_valid & ~ar_v_in_q;

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        aw_v_in_q         <= 1'b0;
        ar_v_in_q         <= 1'b0;
        verdict_pending_q <= 1'b0;
    end else begin
        aw_v_in_q <= req_IP_wrapper_i.aw_valid;
        ar_v_in_q <= req_IP_wrapper_i.ar_valid;

        if (comparison_valid)                     verdict_pending_q <= 1'b0;
        else if (aw_edge_raw | ar_edge_raw)       verdict_pending_q <= 1'b1;
    end
end

//  `& ~comparison_valid` : au cycle ou la comparaison rend, le verdict est frais
//  et l'attente cesse dans le meme cycle. Sans ce terme on ajouterait un cycle
//  de coupure a chaque requete legitime.
assign verdict_stale = (aw_edge_raw | ar_edge_raw | verdict_pending_q)
                     & ~comparison_valid;

assign verdict_fresh = (comparison_valid | verdict_known_q) & ~verdict_stale;

assign verdict_known_eff = ~csr_enforce_q
                         | (csr_fresh_q ? verdict_fresh
                                        : (comparison_valid | verdict_known_q));

// -----------------------------------------------------------------------------
//  W DU EN AVAL — garde du correctif « W orphelin » (2026-09-09)
//
//  request_manager coupe aw_valid/ar_valid tant que le verdict n'est pas rendu,
//  mais laissait passer w_valid. Un aval qui tient w_ready haut -- c'est le cas
//  d'un crossbar qui bufferise, et de l'IOMMU en amont de lui -- avalait donc
//  les donnees d'une ecriture dont il ne recevrait jamais l'adresse. Le canal W
//  se retrouvait decale d'un beat DEFINITIVEMENT : le premier acces CPU
//  empruntant ce chemin ne revenait plus. C'est le gel de SC01 sur carte, et la
//  sonde du 2026-09-09 13:02 l'a isole -- une ecriture bloquee gele, une lecture
//  bloquee non, parce qu'une lecture n'a pas de canal W.
//
//  On ne peut pas couper w_valid inconditionnellement : c'est le Bug #16 de
//  l'implementation de reference, ou couper W tuait les transactions deja
//  acceptees en aval et l'interconnexion mourait apres chaque attaque. La
//  distinction est celle-ci :
//
//    - un AW deja admis en aval attend ses beats W : ils DOIVENT passer ;
//    - aucun AW en attente de donnees : tout W presente est un orphelin en
//      devenir, et c'est LUI qu'il faut couper.
//
//  w_owed_q compte les AW admis en aval dont le dernier beat W n'est pas encore
//  passe. La coupure de W n'est autorisee que lorsqu'il vaut zero, ce qui
//  preserve integralement le correctif du Bug #16.
//
//  LARGEUR : 4 -> 8 bits (2026-09-13). Quatre bits saturaient a 15, et la
//  saturation n'est sure que dans un sens. Avec seize AW a la volee (mode 7 de
//  l'accelerateur), le compteur perd une incrementation puis encaisse seize
//  decrementations : il atteint zero alors qu'une ecriture est encore due en
//  aval, et la coupure de W redevient autorisee au pire moment -- exactement le
//  Bug #16 que ce compteur existe pour eviter. Huit bits couvrent les 48
//  ecritures de SC04-MSI et les 64 entrees de la file de sort.
logic [7:0] w_owed_q;
logic       dn_aw_hs, dn_w_last_hs;

assign dn_aw_hs     = req_wrapper_iommu_o.aw_valid & resp_wrapper_iommu_i.aw_ready;
assign dn_w_last_hs = req_wrapper_iommu_o.w_valid  & resp_wrapper_iommu_i.w_ready
                                                   & req_wrapper_iommu_o.w.last;

// dn_ar_hs vit ici et non avec ses jumeaux du bloc d'observabilite : il est
// consomme par request_flow_monitor, instancie plus haut dans le fichier.
logic       dn_ar_hs;
assign dn_ar_hs     = req_wrapper_iommu_o.ar_valid & resp_wrapper_iommu_i.ar_ready;

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        w_owed_q <= '0;
    end else begin
        // Saturation a 255 : au-dela le compteur cesse de decrire l'aval, mais
        // il vaut mieux ne plus couper que couper a tort.
        case ({dn_aw_hs, dn_w_last_hs})
            2'b10:   if (w_owed_q != 8'hFF) w_owed_q <= w_owed_q + 8'd1;
            2'b01:   if (w_owed_q != 8'h0)  w_owed_q <= w_owed_q - 8'd1;
            default: w_owed_q <= w_owed_q;   // 00 et 11 : inchange
        endcase
    end
end

// -----------------------------------------------------------------------------
//  VALID PRESENTE ET NON ACQUITTE  (correctif derriere CTRL[3])
//
//  Echantillon REGISTRE du valid reellement sorti en aval. Pas de boucle
//  combinatoire : ces bascules sont lues au cycle SUIVANT pour interdire la
//  coupure, et le cas « presente et coupe dans le meme cycle » est impossible
//  par construction -- si la coupure est active, aucun valid n'est sorti.
//
//  A 0 (reset) CTRL[3] laisse le comportement historique, pour que le MEME
//  bitstream serve a mesurer la violation AXI4 et a verifier qu'elle disparait.
// -----------------------------------------------------------------------------
logic aw_pres_q, ar_pres_q;
logic no_cut_aw, no_cut_ar;
logic dn_ar_hs_pres;

assign dn_ar_hs_pres = req_wrapper_iommu_o.ar_valid & resp_wrapper_iommu_i.ar_ready;

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        aw_pres_q <= 1'b0;
        ar_pres_q <= 1'b0;
    end else begin
        if (dn_aw_hs)                          aw_pres_q <= 1'b0;
        else if (req_wrapper_iommu_o.aw_valid) aw_pres_q <= 1'b1;

        if (dn_ar_hs_pres)                     ar_pres_q <= 1'b0;
        else if (req_wrapper_iommu_o.ar_valid) ar_pres_q <= 1'b1;
    end
end

//  CTRL[3] EST DESORMAIS INERTE, et c'est deliberé.
//
//  Deux raisons de couper son effet plutot que de le laisser derriere un bit a
//  0 :
//
//  1. Il est NUISIBLE, mesure : les retraits d'AW passaient de 1 a 33 en
//     simulation (cf. 2ea871d). Un bouton dont on sait qu'il aggrave le defaut
//     n'a pas a rester cablé, meme a 0 -- c'est un piege pour la prochaine
//     personne qui lira la carte des registres, moi compris.
//
//  2. Il vise LE MAUVAIS CANAL. La mesure du 2026-09-10 place le retrait sur
//     W (`retr=0/0/4/0`), pas sur AW. Sa valeur d'observation, qui etait le
//     seul argument pour le garder, a disparu avec cette mesure.
//
//  Le bit reste lisible dans CTRL et STATUS[15] pour ne pas decaler la carte
//  des registres, mais il ne pilote plus rien. aw_pres_q / ar_pres_q restent
//  calcules : la synthese les elaguera, et ils documentent la tentative.
assign no_cut_aw = 1'b0;
assign no_cut_ar = 1'b0;

//  w_pending : un AW est admis en aval et attend encore ses donnees. C'est la
//  seule condition dans laquelle un beat W a le droit de partir. Voir
//  request_manager pour le raisonnement complet.
logic w_pending;
assign w_pending = (w_owed_q != 4'h0);

//  w_pending_sel : la dette W effectivement presentee a request_manager et a
//  response_manager. Sous CTRL[4] W_SKID + CTRL[7] W_CAPDEBT, c'est la dette
//  comptee a la CAPTURE dans l'etage (calculee apres son instanciation) ;
//  sinon w_pending, inchange.
logic w_pending_sel;

//  RESP_HOLD (CTRL[8]) : response_manager tient un B / un R FABRIQUE vers le
//  maitre ; request_manager ne prend alors aucune reponse reelle en aval.
logic resp_hold_b, resp_hold_r;

//  B_FATE (CTRL[10]) : nets de la file du sort cote B, calcules plus bas (apres
//  W_FATE, dont ils reprennent les handshakes) et lus par les deux managers.
logic                  bfate_on, bq_fab, bq_take, bq_hold_aw;
logic [IdWidthSlv-1:0] bq_head_id;



ID_extractor#(

    .DevIDWidth(DevIDWidth),
    .req_iommu_t(req_iommu_t)


)Dev_ID_extractor(
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .req_i(req_IP_wrapper_i),
    .Device_ID_o(Device_ID_o),
    .Device_ID_write_enable_o(Device_ID_write_enable_o)
);
address_extractor #(
        .AddrWidth(AddrWidth),
        .req_iommu_t(req_iommu_t)
    ) addr_extractor_inst (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .req_i(req_IP_wrapper_i),
        .Address_o(extracted_address),
        .Address_write_enable_o(address_valid),
        .is_write_o(is_write_req),
        .is_read_o(is_read_req)
    );
    msi_detector #(
        .AddrWidth(AddrWidth)
    ) msi_detect_inst (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .msi_address_config(msi_address_config),
        .extracted_address(extracted_address),
        .compare_enable(address_valid),
        .is_write_req(is_write_req),
        .is_msi_interrupt(is_msi_interrupt),
        .is_dma(is_dma),
        .comparison_valid(msi_comparison_valid)
    );
id_comparator #(
    .DevIDWidth(DevIDWidth)  // même largeur que Device_ID_o et fixed_ID_reg
) comparator_inst (
    .clk_i(clk_i),                               // horloge du wrapper
    .rst_ni(rst_ni),                             // reset du wrapper
    .fixed_id(fixed_ID_reg),                     // ID fixe stocké par le processeur
    .dynamic_id(Device_ID_o),                    // ID capturé par l'ID_extractor
    .compare_enable(Device_ID_write_enable_o),  // déclenche la comparaison
    .legit_hit(legit_hit),                       // résultat de la comparaison
    .comparison_valid(comparison_valid)         // signal de validité
);



//  Nets de l'etage W. `req_rm` est la sortie brute de request_manager ; le port
//  aval `req_wrapper_iommu_o` en est l'assemblage avec le canal W de l'etage.
req_iommu_t req_rm;
w_chan_t    wskid_w;
logic       wskid_valid, wskid_ready;

request_manager #(
    .req_iommu_t(req_iommu_t)
)request_manager_module(
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .legit_hit(legit_hit_eff),
    .req_IP_wrapper_i(req_IP_wrapper_i),
    .block_req_i(block_req_i),      // signal combiné
    .bad_id_i(bad_id),
    .verdict_known_i(verdict_known_eff),
    .w_pending_i(w_pending_sel),    // dette W : voir W_CAPDEBT apres l'etage
    .no_cut_aw_i(no_cut_aw),
    .no_cut_ar_i(no_cut_ar),
    .txblock_en_i(csr_txblk_q),
    .hold_b_i(resp_hold_b),         // RESP_HOLD : un B fabrique est tenu
    .hold_r_i(resp_hold_r),         // RESP_HOLD : un R fabrique est tenu
    .bfate_en_i(bfate_on),          // B_FATE : ready B aval pilote par la file
    .bfate_take_i(bq_take),
    .req_wrapper_iommu_o(req_rm)

);

// -----------------------------------------------------------------------------
//  ETAGE W  (skid buffer, derriere CTRL[4])
//
//  Insere entre la sortie de request_manager et le port aval. La decision de
//  couper un beat W est desormais prise A LA CAPTURE : un beat qu'on n'a pas le
//  droit d'emettre n'entre pas dans l'etage et reste chez le maitre -- ce qui
//  est licite, un maitre peut attendre -- et un beat entre est presente en aval
//  puis TENU jusqu'a son w_ready, quoi que devienne `w_pending`. Le retrait de
//  VALID mesure le 2026-09-10 devient impossible par construction.
//
//  A CTRL[4] = 0 (reset) l'etage est transparent au fil pres : le meme bitstream
//  sert a mesurer la violation et a verifier sa disparition.
// -----------------------------------------------------------------------------
w_skid_buffer #(
    .w_chan_t(w_chan_t)
) i_w_skid (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .en_i      (csr_wskid_q),
    .w_i       (req_rm.w),
    .w_valid_i (req_rm.w_valid),
    .w_ready_o (wskid_ready),
    .w_o       (wskid_w),
    .w_valid_o (wskid_valid),
    .w_ready_i (resp_wrapper_iommu_i.w_ready)
);

// -----------------------------------------------------------------------------
//  DETTE W COMPTEE A LA CAPTURE  (CTRL[7] W_CAPDEBT, 2026-09-11)
//
//  CE COMMENTAIRE REMPLACE UN « RISQUE LATENT, NON ATTEIGNABLE » QUI ETAIT FAUX.
//  Il raisonnait sur le seul cycle de vidange de l'etage, et concluait que la
//  FSM de l'accelerateur (G_NEXT puis G_AW) ne presentait jamais de W a temps.
//  Il oubliait deux choses mesurees :
//
//    - l'aval met 40 a 45 cycles a prendre un beat W (ARMORSTALL sur carte) :
//      le dernier beat d'une ecriture reste dans l'etage bien plus d'un cycle ;
//    - pendant un blocage, response_manager FABRIQUE aw_ready vers le maitre :
//      l'ecriture suivante, pourtant coupee, est acquittee, et son W arrive
//      pendant que le beat precedent attend encore dans l'etage.
//
//  `w_pending`, compte en AVAL, vaut encore 1 a ce moment : le W de l'ecriture
//  coupee est capture, reste presente en aval avec w_owed = 0, puis part avec
//  l'adresse legitime suivante. Le vrai beat de celle-ci se fait coincer a son
//  tour : tout le canal W est decale d'un cran, et le solde AW / W-last reste
//  JUSTE. Ni `cnt_w_orphan_q` ni `w_excess_tot` ne le voient -- ils attendaient
//  un beat sans adresse, pas un beat qui attend la prochaine.
//
//  Preuve : banc a aval realiste (DN_WGATE=1 DN_WLAT=40), controle d'appariement
//  adresse/donnee -- 147 beats partis avec la donnee d'une AUTRE ecriture, le
//  premier 63 beats plus vieux que prevu. Sur carte, dans les trois runs
//  W_SKID=1 : un beat `W V- last` bloque en aval avec w_owed = 0, des SC02.
//
//  LE CORRECTIF. La dette qui autorise la capture doit etre comptee la ou la
//  decision est prise : AW admis en aval MOINS W-last ENTRES dans l'etage. Un
//  beat de plus ne peut alors plus etre capture pour une adresse dont le dernier
//  beat est deja dans l'etage. Le meme signal pilote response_manager, pour que
//  le ready rendu au maitre reste coherent avec ce que request_manager laisse
//  passer.
//
//  VIVACITE, inchangee par ce correctif : si ARMOR a fabrique l'acquittement
//  d'une adresse et que le blocage retombe avant que son W ne soit presente, le
//  maitre attend son w_ready jusqu'a son propre timeout -- c'est deja le cas
//  aujourd'hui quand l'etage est vide.
//
//  A CTRL[7] = 0 (reset) : comportement historique, pour mesurer le decalage
//  puis sa disparition sur le meme bitstream.
// -----------------------------------------------------------------------------
logic [3:0] w_cap_owed_q;
logic       cap_w_last;

//  Un dernier beat ENTRE dans l'etage : le handshake cote maitre de l'etage.
assign cap_w_last = req_rm.w_valid & wskid_ready & req_rm.w.last;

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        w_cap_owed_q <= '0;
    end else if (!csr_wskid_q) begin
        //  Etage en derivation, donc vide : dette a la capture = dette en aval.
        //  Basculer W_SKID a 1 part ainsi d'un etat coherent.
        w_cap_owed_q <= w_owed_q;
    end else begin
        case ({dn_aw_hs, cap_w_last})
            2'b10:   if (w_cap_owed_q != 4'hF) w_cap_owed_q <= w_cap_owed_q + 4'd1;
            2'b01:   if (w_cap_owed_q != 4'h0) w_cap_owed_q <= w_cap_owed_q - 4'd1;
            default: w_cap_owed_q <= w_cap_owed_q;   // 00 et 11 : inchange
        endcase
    end
end

// -----------------------------------------------------------------------------
//  SORT DE CHAQUE AW  (CTRL[9] W_FATE, 2026-09-11)
//
//  CE QUE W_CAPDEBT NE SAVAIT PAS FAIRE. Pendant un blocage, response_manager
//  fabrique aw_ready : le maitre croit son ecriture acceptee et presente son W.
//  Si le blocage retombe avant ce W, plus rien ne l'absorbe -- aucune dette W ne
//  l'attend, et la branche passe-plat rend w_ready = 0. Le maitre attend jusqu'a
//  son timeout. Mesure sur carte sous W_CAPDEBT : SC02 finit 17 fois sur 50 au
//  timeout de l'accelerateur (SUMMARY-TX Lp50 = 65 676). Au banc, 24 photos au
//  cycle du timeout, toutes : etat W, beat 0, blocage retombe, dettes a zero --
//  et la MEME cause sans W_CAPDEBT, masquee par la capture a tort du beat.
//
//  Une dette est un COMPTE ; il faut un SORT PAR TRANSACTION. Pour chaque AW
//  acquitte au maitre, on empile 1 s'il a ete admis en aval DANS LE MEME CYCLE,
//  0 sinon (acquittement fabrique). Le meme cycle suffit : en passe-plat le ready
//  amont EST le ready aval ; en blocage aw_valid est coupe en aval ; en attente de
//  verdict aw_ready vaut 0 en amont. On depile au W-last accepte COTE MAITRE.
//
//  La tete decide du beat W presente : 1 -> capture dans l'etage ; 0 -> ABSORBE
//  (w_valid coupe en aval, w_ready = 1 au maitre), QUEL QUE SOIT L'ETAT DU
//  BLOCAGE ; FIFO vide -> le maitre attend.
//
//  Limites connues : pas de contournement -- un maitre qui presenterait son W
//  dans le cycle meme de son AW attendrait un cycle (accel_wrap ne le fait pas).
//  Une poussee sur FIFO pleine est perdue et leve fate_ovf_q (echo STATUS[22]) :
//  ce bit doit rester a 0.
//
//  PROFONDEUR : 4 -> 64 (2026-09-13). Le 4 reposait sur une phrase qui vient de
//  cesser d'etre vraie : « accel_wrap n'a jamais plus d'un AW sans W en
//  attente ». Le mode 7 de l'accelerateur emet ses adresses A LA VOLEE, seize
//  avant le premier beat de donnees -- c'est ce que fait n'importe quel DMA
//  reel, et c'est ce que la Table 5 du papier decrit deja. Avec 4 entrees, la
//  cinquieme poussee est PERDUE : le sort d'une ecriture est inconnu, son beat
//  W part sur la foi de la tete d'une autre, et fate_ovf_q se leve. On dimensionne
//  donc comme la file B (64), au-dessus des 48 ecritures de SC04-MSI.
//
//  La profondeur ne change rien tant que le maitre n'a qu'un AW en vol : une
//  file qui n'utilise jamais plus de 4 entrees se comporte a l'identique. Le
//  banc le verifie -- campagne inchangee, ligne pour ligne.
//
//  Actif seulement avec CTRL[4] W_SKID ; supplante CTRL[7] W_CAPDEBT. A 0 au
//  reset : comportement precedent, pour mesurer sur le meme bitstream.
// -----------------------------------------------------------------------------
localparam int unsigned FateDepth = 64;

logic [FateDepth-1:0] fate_q;    // fate_q[0] = tete
logic [6:0]           fate_n_q;  // 0..64 entrees
logic                 fate_ovf_q;  // poussee perdue sur FIFO pleine (collant)
//  fate_aw_hs est le MEME signal que up_aw_hs du bloc d'observabilite, declare
//  plus bas (vers la ligne 1280) : on ne peut pas s'en servir avant sa
//  declaration, d'ou ce nom propre.
logic       fate_aw_hs, fate_w_last_hs, fate_empty, fate_head;

assign fate_aw_hs     = req_IP_wrapper_i.aw_valid & resp_IP_wrapper_o.aw_ready;
assign fate_w_last_hs = req_IP_wrapper_i.w_valid  & resp_IP_wrapper_o.w_ready
                                                  & req_IP_wrapper_i.w.last;
assign fate_empty   = (fate_n_q == 7'd0);
assign fate_head    = fate_q[0];

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        fate_q     <= '0;
        fate_n_q   <= '0;
        fate_ovf_q <= 1'b0;
    end else if (!csr_wskid_q) begin
        //  Etage en derivation : rien a suivre, et W_SKID repart d'un etat vide.
        fate_q   <= '0;
        fate_n_q <= '0;
    end else begin
        automatic logic [FateDepth-1:0] q = fate_q;
        automatic logic [6:0]           n = fate_n_q;
        //  Depiler d'abord : un W-last et un nouvel AW peuvent tomber le meme cycle.
        if (fate_w_last_hs && n != 7'd0) begin
            q = {1'b0, q[FateDepth-1:1]};
            n = n - 7'd1;
        end
        if (fate_aw_hs) begin
            if (n != 7'(FateDepth)) begin
                q[n] = dn_aw_hs;
                n    = n + 7'd1;
            end else begin
                fate_ovf_q <= 1'b1;
            end
        end
        fate_q   <= q;
        fate_n_q <= n;
    end
end

logic w_absorb;
assign w_absorb = csr_wskid_q & csr_wfate_q & ~fate_empty & ~fate_head;

// -----------------------------------------------------------------------------
//  SORT DE CHAQUE ECRITURE COTE B  (CTRL[10] B_FATE, 2026-09-11)
//
//  LE DEFAUT, MESURE AU BANC. W_FATE rend au maitre le W de chaque AW coupe ;
//  personne ne lui rendait son B. Le canal B vers le maitre etait une fonction de
//  la branche de response_manager : pendant un blocage, un SLVERR fabrique
//  presente EN CONTINU -- accel_wrap tient b_ready a 1 et en prend un PAR CYCLE ;
//  hors blocage, seul le B de l'aval passe, et l'aval ne repond pas a un AW qu'il
//  n'a jamais vu. Controle du banc « un B par W-last cote maitre », configuration
//  de reference : aval historique 1958 B apparies, 2674 B sans ecriture en
//  attente, 14 W-last jamais repondus ; aval realiste 782 et 1. Le maitre compte
//  ses B sans les apparier : les B en trop masquaient les B manquants. Sans
//  RESP_HOLD ils ne suffisaient plus -- d'ou le timeout en DRAIN (14 B recus sur
//  16) laisse ouvert par W_FATE.
//
//  LE CORRECTIF. Un B par ecriture, dans l'ordre AXI. File du sort de chaque AW
//  acquitte au maitre -- meme poussee que W_FATE, plus l'ID de l'AW, qu'accel_wrap
//  fait varier en modes 4 et 5 --, depilee au B acquitte par le maitre :
//    - tete COUPEE : un SLVERR fabrique, avec son ID, presente seulement une fois
//      son W-last passe cote maitre (AXI : pas de B avant les donnees).
//      bq_wdone_q compte les W-last passes dont le B n'est pas rendu ; l'ordre
//      des W est celui des AW, donc celui de la file ;
//    - tete ADMISE : le B de l'aval, et lui seul -- c'est aussi le seul cas ou
//      l'aval recoit b_ready. Plus de drainage B : sous B_FATE tout B de l'aval
//      appartient a une ecriture que le maitre attend ;
//    - file vide : aucun B.
//
//  Limites connues : une ecriture abandonnee par le maitre avant son W-last
//  (timeout en etat W) laisse son entree en tete et decale la file d'un cran --
//  c'est precisement le cas que W_FATE supprime. Profondeur 16 = STORM_REQS ;
//  une poussee sur file pleine est perdue et leve bq_ovf_q (echo dans STATUS,
//  voir la carte des registres), qui doit rester a 0. A activer avant le trafic,
//  comme W_FATE : une ecriture en vol a l'activation n'a pas d'entree.
//
//  N'agit qu'avec CTRL[4] W_SKID et CTRL[9] W_FATE : il reprend leurs handshakes
//  et a besoin de W_FATE pour que le W d'un AW coupe soit absorbe. Suppose
//  CTRL[5] FRESH : une ecriture admise en aval recoit son B reel, meme si son
//  verdict tombe ensuite. A 0 au reset : comportement precedent.
// -----------------------------------------------------------------------------
//  PROFONDEUR. 16 ne suffit pas : SC04-MSI emet MSI_REQS = 48 ecritures d'affilee
//  sans attendre leurs B, et il suffit que la tete soit une ecriture admise dont
//  le B reel tarde pour que rien ne se depile. Sur carte le 2026-09-12, la file a
//  deborde et la campagne a gele dans SC04 ; reproduit au banc avec DN_AWOUT=48
//  DN_BLAT=200 (remplissage 16/16, 294 B manquants, 6 timeouts). 64 couvre la plus
//  grosse rafale de bench_runner.c ; au-dela, le freinage ci-dessous protege.
localparam int unsigned BqDepth = 64;

logic [BqDepth-1:0]                 bq_fate_q;    // [0] = tete ; 1 admise, 0 coupee
logic [BqDepth-1:0][IdWidthSlv-1:0] bq_id_q;
logic [6:0]                         bq_n_q;       // 0..64 entrees
logic [6:0]                         bq_wdone_q;   // W-last passes, B pas encore rendu
logic                               bq_ovf_q;     // poussee perdue : ne doit plus arriver
logic                               bq_empty, bq_full, bq_b_hs;

assign bfate_on   = csr_bfate_q & csr_wskid_q & csr_wfate_q;

// Interruption de niveau. csr_sticky_q est deja masque a l'ecriture par
// ARMOR_STICKY_MASK, donc un OU reduit suffit : tout ce qui y est entre est un
// evenement de securite.
assign irq_o      = csr_irqen_q & (|csr_sticky_q);
assign bq_empty   = (bq_n_q == 7'd0);
assign bq_full    = (bq_n_q == 7'(BqDepth));

//  FILE PLEINE : ON REFUSE L'AW, ON NE PERD PAS LA POUSSEE (2026-09-12).
//
//  La version precedente laissait tomber la poussee et levait bq_ovf_q : le
//  compte etait alors faux pour toujours, et le maitre attendait un B que
//  personne ne devait plus -- c'est le gel observe sur carte dans SC04. Un
//  esclave a le droit de faire attendre : on retire donc aw_ready au maitre et
//  aw_valid en aval tant que la file est pleine.
//
//  Aucun VALID deja presente n'est retire : la file ne se remplit qu'au cycle
//  d'un handshake AW AMONT, et ce handshake implique que l'AW correspondant a
//  ete soit admis en aval dans le meme cycle, soit jamais presente (coupe).
assign bq_hold_aw = bfate_on & bq_full;
assign bq_fab     = bfate_on & ~bq_empty & ~bq_fate_q[0] & (bq_wdone_q != 5'd0);
assign bq_take    = bfate_on & ~bq_empty &  bq_fate_q[0];
assign bq_head_id = bq_id_q[0];
assign bq_b_hs    = resp_IP_wrapper_o.b_valid & req_IP_wrapper_i.b_ready;

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        bq_fate_q  <= '0;
        bq_id_q    <= '0;
        bq_n_q     <= '0;
        bq_wdone_q <= '0;
        bq_ovf_q   <= 1'b0;
    end else if (!bfate_on) begin
        //  File inactive : rien a suivre, et B_FATE repart d'un etat vide.
        bq_fate_q  <= '0;
        bq_n_q     <= '0;
        bq_wdone_q <= '0;
    end else begin
        automatic logic [BqDepth-1:0]                 f  = bq_fate_q;
        automatic logic [BqDepth-1:0][IdWidthSlv-1:0] d  = bq_id_q;
        automatic logic [6:0]                         n  = bq_n_q;
        automatic logic [6:0]                         wd = bq_wdone_q;
        //  Depiler d'abord, puis le W-last, puis l'AW : les trois peuvent tomber
        //  dans le meme cycle.
        if (bq_b_hs && n != 7'd0) begin
            f = f >> 1;
            d = d >> IdWidthSlv;
            n = n - 7'd1;
            if (wd != 7'd0) wd = wd - 7'd1;
        end
        //  Borne par n : un W-last sans entree n'ouvre aucun B.
        if (fate_w_last_hs && wd < n)
            wd = wd + 7'd1;
        if (fate_aw_hs) begin
            if (n < BqDepth) begin
                f[n] = dn_aw_hs;
                d[n] = IdWidthSlv'(req_IP_wrapper_i.aw.id);
                n    = n + 7'd1;
            end else begin
                //  Inatteignable depuis le freinage : un AW ne peut plus etre
                //  acquitte quand la file est pleine. Le drapeau reste comme
                //  filet -- s'il se leve, c'est que le freinage a ete contourne.
                bq_ovf_q <= 1'b1;
            end
        end
        bq_fate_q  <= f;
        bq_id_q    <= d;
        bq_n_q     <= n;
        bq_wdone_q <= wd;
    end
end

assign w_pending_sel = (csr_wskid_q & csr_wfate_q) ? (~fate_empty & fate_head)
                     : (csr_wskid_q & csr_wcap_q)  ? (w_cap_owed_q != 4'h0)
                     :                               w_pending;
always_comb begin
    req_wrapper_iommu_o = req_rm;
    if (csr_wskid_q) begin
        req_wrapper_iommu_o.w       = wskid_w;
        req_wrapper_iommu_o.w_valid = wskid_valid;
    end
    //  B_FATE, file pleine : l'AW n'est pas presente en aval, et response_manager
    //  ne rend pas son ready au maitre. L'ecriture attend son tour.
    if (bq_hold_aw) req_wrapper_iommu_o.aw_valid = 1'b0;
end

response_manager #(
    .resp_slv_t(resp_slv_t),
    .IdWidth(IdWidthSlv)
) response_manager_module (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .block_req_i(block_req_i),
    .block_ip_i(block_ip_eff),
    .bad_id_i(bad_id),
    .verdict_known_i(verdict_known_eff),
    .legit_hit(legit_hit_eff),
    .w_pending_i(w_pending_sel),    // meme dette que request_manager (W_CAPDEBT)
    .wskid_en_i(csr_wskid_q),
    .wskid_ready_i(wskid_ready),
    .w_absorb_i(w_absorb),          // W_FATE : W d'un AW coupe, acquitte sans envoi
    .txblock_en_i(csr_txblk_q),
    .resp_hold_en_i(csr_rhold_q),
    .b_ready_i(req_IP_wrapper_i.b_ready),
    .r_ready_i(req_IP_wrapper_i.r_ready),
    .hold_b_o(resp_hold_b),
    .hold_r_o(resp_hold_r),
    .bfate_en_i(bfate_on),          // B_FATE : un B par ecriture, dans l'ordre
    .bfate_fab_i(bq_fab),
    .bfate_take_i(bq_take),
    .bfate_id_i(bq_head_id),
    .bfate_hold_aw_i(bq_hold_aw),   // file pleine : le maitre attend
    .resp_wrapper_iommu_i(resp_wrapper_iommu_i),
    .resp_IP_wrapper_o(resp_IP_wrapper_o)
);
security_monitor #(
    .MAX_FAILURES(3),
    .BLOCK_DURATION(BLOCK_DURATION_C)
) sec_mon (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .legit_hit(legit_hit),               // connecté au comparator
    .comparison_valid(comparison_valid), // signal du comparator
    .block_ip_o(block_ip_o),             // utilisé par response_manager
    .failure_count(failure_count),
    .threat_detected(threat_detected)
);

request_flow_monitor #(
    .WINDOW_CYCLES(FLOW_WINDOW_C),
    .MAX_REQ_PER_WINDOW(8),
    .BLOCK_CYCLES(FLOW_BLOCK_CYCLES_C),
    .req_iommu_t(req_iommu_t),
    .resp_slv_t(resp_slv_t)

) req_flow_mon_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .req_IP_wrapper_i(req_IP_wrapper_i),
    .resp_wrapper_iommu_i(resp_wrapper_iommu_i),
    .legit_hit_i(legit_hit_eff),
    .dn_aw_hs_i(dn_aw_hs),
    .dn_ar_hs_i(dn_ar_hs),
    .cnt_fix_i(csr_rfmcnt_q),
    .max_req_i(csr_thresh_q),
    .storm_flag(storm_flag),
    .block_req(block_req_flow),
    .req_fire(req_fire_signal),
    .req_cnt_o(flow_req_cnt),
    .window_cnt_o(flow_window_cnt)

);

outs_req_monitor #(
    .MAX_OUTSTANDING(16),
    .BLOCK_CYCLES(OUTS_BLOCK_CYCLES_C),
    .resp_slv_t(resp_slv_t),
    .req_iommu_t(req_iommu_t)
) outs_monitor_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .req_fire(req_fire_signal),              // Réutilisation
    .resp_wrapper_iommu_i(resp_wrapper_iommu_i),
    .req_IP_wrapper_i(req_IP_wrapper_i),
    .overflow_flag(overflow_flag_outs),
    .block_req(block_req_outs),
    .outstanding_o(outs_depth)
);
interrupt_monitor #(
    .WINDOW_CYCLES(1024),
    .MAX_MSI_PER_WINDOW(MAX_MSI_C),
    .MAX_RATIO_MSI_DMA(2)
) int_monitor_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .comparison_valid(msi_comparison_valid),
    .is_msi_interrupt(is_msi_interrupt),
    .is_dma(is_dma),
    .msi_storm(msi_storm),
    .block_msi(block_msi)
);

response_delayer #(
    .MAX_DELAY(16),
    .resp_slv_t(resp_slv_t)
) resp_delay_inst (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .resp_in_i(resp_wrapper_iommu_i),    // Réponses de l'IOMMU
    .resp_out_o(resp_delayed)             // Réponses retardées
);



// =============================================================================
// Interface CSR CPU   (sec_wrapper #1 -> 0x5000_2000, #2 -> 0x5000_3000)
//
// Avant cette version, req_CPU_Wrapper__i / resp_CPU_Wrapper_o etaient declares
// dans la liste de ports mais jamais references dans le corps du module. Vivado
// signalait 30 nets sans driver ; les deux consequences fonctionnelles etaient :
//
//   - fixed_ID_reg et msi_address_config restaient constants a 0. Comme
//     id_comparator applique la garde `(fixed_id == dynamic_id) && (fixed_id != '0)`,
//     legit_hit valait 0 en permanence, et request_manager bloque toute requete
//     dont legit_hit est nul : le chemin accel -> IOMMU etait ferme en toutes
//     circonstances, independamment des moniteurs.
//
//   - aucun verdict (block_ip_o, storm_flag, block_req_outs, block_msi, ...) ne
//     sortait du module : aucune observabilite logicielle.
//
// Carte des registres — 64 bits, index decode sur addr[7:3] (32 registres,
// alias tous les 256 octets dans la fenetre de 4 KiB) :
//
//   0x00  ID_CFG       RW  identifiant legitime attendu = STREAM_ID de l'accel
//                          (1 pour sec_wrapper #1, 2 pour #2, cf. accel_wrap.sv)
//   0x08  MSI_ADDR     RW  adresse MSI surveillee par msi_detector
//   0x10  CTRL         RW  b0 ENFORCE, b1 STICKY_CLR, b2 CNT_CLR,
//                          (la file de sort de b9 W_FATE fait 64 entrees depuis
//                          v14, contre 4 : un maitre qui emet ses adresses a la
//                          volee en presente seize avant le premier beat, et la
//                          cinquieme poussee etait perdue)
//                          b[23:16] FLOW_THRESH -- seuil du moniteur de flux,
//                          ZERO = valeur de synthese (8). Regler le seuil sans
//                          resynthetiser est ce qui permet de tracer la courbe
//                          detection / faux positifs en fonction du seuil : sur
//                          carte le 2026-09-13, legitime et low-and-slow tiennent
//                          a 1 requete par fenetre, un DMA legitime saturant
//                          culmine a 4 sur 5,4 millions de fenetres, la tempete a
//                          10 pour une moyenne de 4,9 -- et le seuil vaut 8. (v15)
//                          b12 RFM_CNT -- request_flow_monitor compte les
//                          TRANSFERTS d'adresse accomplis en aval au lieu des
//                          FRONTS de handshake. A 0, comportement historique :
//                          deux adresses transferees sur deux cycles consecutifs
//                          ne comptent que pour une. Le generateur de accel_wrap
//                          ne pipeline pas ses AW, le bit est donc sans effet
//                          mesurable sur les scenarios actuels -- il ferme un
//                          angle mort pour tout maitre qui le ferait. Echo dans
//                          la relecture de CTRL. (v14)
//                          b5 FRESH_VERDICT -- n'admet une adresse en aval que
//                          si SA comparaison d'identite a rendu. Ferme une
//                          fenetre de DEUX cycles ou l'adresse etait jugee sur
//                          le verdict de la requete precedente
//                          (Device_ID_write_enable_o est registre). Aujourd'hui
//                          seule la lenteur de l'IOMMU la referme. Echo
//                          STATUS[17]. PREREQUIS de b6.
//                          b6 TX_BLOCK -- blocage transactionnel : une ecriture
//                          dont l'AW est deja admis en aval se termine au lieu
//                          d'etre terminee en SLVERR, ce qui evite de laisser un
//                          AW orphelin. NE PAS ACTIVER SANS b5 : sans verdict
//                          frais, « ce qui est presente est engage » revient a
//                          admettre une ecriture usurpee. Echo STATUS[18].
//                          b7 W_CAPDEBT -- la dette W qui autorise la capture
//                          dans l'etage W est comptee A LA CAPTURE (AW admis -
//                          W-last entres dans l'etage) et non en aval. Sans lui,
//                          le W d'une ecriture coupee pouvait etre capture, rester
//                          presente en aval et partir avec l'adresse legitime
//                          suivante (demontre au banc le 2026-09-11). N'agit
//                          qu'avec b4. Echo STATUS[19].
//                          b8 RESP_HOLD -- une reponse B/R presentee au maitre
//                          est tenue a l'identique jusqu'a son ready, et l'attente
//                          de verdict laisse passer les reponses de l'aval.
//                          Correctif du troisieme site de retrait de VALID (SC03 :
//                          b-r = 16 sans FRESH, 73 avec, sur carte ; 8 -> 0 au
//                          banc). Laisse aussi passer les reponses de l'aval
//                          pendant l'attente : risque de perte lu au RTL, jamais
//                          observe. Echo STATUS[20].
//                          b9 W_FATE -- sort de chaque AW acquitte au maitre
//                          (admis en aval ou coupe), dans une FIFO de 4 bits ; le
//                          W d'un AW coupe est absorbe meme hors blocage. Correctif
//                          des timeouts de l'accelerateur (SC02 17/50 sur carte
//                          sous b7). N'agit qu'avec b4 ; supplante b7. Echo
//                          STATUS[21] ; STATUS[22] = poussee perdue sur FIFO pleine,
//                          doit rester a 0.
//                          b10 B_FATE -- un B par ecriture, dans l'ordre AXI : file
//                          du sort de chaque AW acquitte au maitre (16 entrees, avec
//                          l'ID). AW coupe : un SLVERR fabrique, apres son W-last ;
//                          AW admis : le B de l'aval, seul cas ou l'aval recoit
//                          b_ready (plus de drainage B). Correctif des B fabriques
//                          en continu pendant un blocage (un par cycle au banc) et
//                          des W-last jamais repondus (timeout en DRAIN). N'agit
//                          qu'avec b4 et b9 ; suppose b5. Echo STATUS[23] ;
//                          STATUS[24] = poussee perdue sur file pleine, doit rester
//                          a 0.
//                          b4 W_SKID -- etage d'un emplacement sur le canal W.
//                          Correctif du retrait de VALID mesure le 2026-09-10 :
//                          la coupure est decidee A LA CAPTURE, un beat entre
//                          est tenu jusqu'a son ready, et le ready rendu au
//                          maitre est celui de l'etage. A 0 (reset) l'etage est
//                          transparent. Echo dans STATUS[16].
//
//                          b3 AW_HOLD_FIX -- TENTATIVE REFUTEE, gardee pour
//                          etre mesurable sur carte. A 0 (reset), donc sans
//                          effet par defaut. Echo dans STATUS[15].
//
//                          L'idee etait : interdire de retirer un VALID deja
//                          presente en aval, en differant la coupure. La
//                          simulation la refute -- les retraits d'AW passent de
//                          1 a 33 sur SC04-MSI et de 1 a 8 sur SC01-SPOOF, et
//                          un nouveau apparait sur du trafic legitime.
//
//                          POURQUOI. Pendant un blocage, response_manager
//                          fabrique aw_ready = 1 vers le maitre pour absorber sa
//                          requete. Maintenir en meme temps le aw_valid en aval
//                          sans qu'il y soit acquitte fait que le maitre
//                          considere son AW termine et RETIRE lui-meme son
//                          valid : le retrait revient, et plus souvent.
//
//                          Le vrai defaut n'est donc pas la coupure seule, c'est
//                          qu'ARMOR ABSORBE la requete cote maitre alors qu'elle
//                          est encore presentee en aval. Un correctif doit
//                          traiter les deux cotes ensemble : soit laisser l'AW
//                          deja presente s'accomplir en aval AVANT de fabriquer
//                          le ready, soit ne jamais presenter en aval un AW
//                          qu'on pourrait avoir a absorber -- ce qui demande un
//                          skid buffer, pas une inhibition.
//                          (b1/b2 sont des commandes a impulsion, auto-effacees)
//   0x18  STATUS       RO  verdicts instantanes
//   0x20  STICKY       RO  OU cumulatif de STATUS depuis le dernier STICKY_CLR
//   0x28  FAIL_CNT     RO  security_monitor.failure_count (8 bits)
//   0x30  CNT_BANNED   RO  nombre de bannissements (fronts montants)
//   0x38  CNT_STORM    RO  [31:0]  nombre d'episodes de storm de requetes
//                          [39:32] REQ_MAX -- plus forte occupation atteinte par
//                          une fenetre de flux depuis CNT_CLR, a comparer au
//                          seuil MAX_REQ_PER_WINDOW = 8. Dit de COMBIEN une
//                          salve non detectee est passee sous le seuil, la
//                          seule chose que le log ne savait pas dire.
//                          [63:40] WIN_ACT -- fenetres fermees en ayant compte
//                          au moins une requete. Avec CNT_REQ (0x90), donne
//                          l'occupation moyenne d'une fenetre active, c'est-a-
//                          dire le debit de l'attaque TEL QUE LE MONITEUR LE
//                          VOIT -- a ne pas confondre avec le nombre de requetes
//                          par salve, qui n'en est le double que si la salve
//                          tient dans une seule fenetre.
//                          Les deux sont remis a zero par CNT_CLR (v14).
//   0x40  CNT_OUTS     RO  [31:0]  nombre d'episodes de saturation outstanding
//                          [39:32] OUTS_MAX -- plus forte profondeur d'en-vol
//                          atteinte depuis CNT_CLR, a comparer au seuil de 16.
//                          Dit si une campagne non detectee est passee SOUS le
//                          seuil ou si le moniteur l'a manquee pour une autre
//                          raison ; c'est la question ouverte du 2026-09-13,
//                          quand ses verdicts tombent de 32,3 a 0,3 sous
//                          contention. (v16)
//   0x48  CNT_MSI      RO  nombre d'episodes de storm MSI
//   0x50  DEV_ID_LAST  RO  dernier stream_id observe — sert a calibrer ID_CFG
//   0x58  MAGIC        RO  0x41524D4F52000011 ("ARMOR" + version)
//                          v11 portait deja b10, mais avec une file de 16 : elle
//                          deborde et GELE la campagne dans SC04. Le MAGIC monte
//                          donc a v12, seul moyen pour le logiciel de distinguer
//                          les deux -- le .bit v11 reste archive et reinstallable.
//                          Le bitstream v13 (irq_o, b11) avait OUBLIE d'y
//                          toucher : le MAGIC passe de 0x0C a 0x0E d'un coup,
//                          pour que numero de bitstream et version de MAGIC se
//                          recollent. Un firmware qui exige v13 ou v14 est donc
//                          protege ; aucun ne pouvait exiger 0x0D, il n'a jamais
//                          existe.
//
// Bloc d'observabilite, ajoute le 2026-09-10 (d'ou MAGIC ...0002 : le logiciel
// distingue ainsi un bitstream qui porte ces registres d'un qui n'en a pas).
// Tout est en lecture seule et sans effet fonctionnel ; les accumulateurs sont
// remis a zero par CNT_CLR, comme les compteurs d'evenements.
//
//   0x60  DBG_UP       RO  poignees de main VIVANTES cote maitre surveille
//   0x68  DBG_DN       RO  poignees de main VIVANTES cote aval
//                          [0] aw_valid [1] aw_ready [2] w_valid [3] w_ready
//                          [4] w_last   [5] b_valid  [6] b_ready [7] ar_valid
//                          [8] ar_ready [9] r_valid [10] r_ready [11] r_last
//   0x70  DBG_STATE    RO  [3:0] w_owed [4] w_pending [5] verdict_known
//                          [6] comparison_valid [7] bad_id [8] legit_hit
//                          [9] legit_hit_eff [10] verdict_known_eff
//                          [12:11] FSM ecriture CSR [13] FSM lecture CSR
//                          [23:16] failure_count [31:24] outstanding
//                          [39:32] req_cnt fenetre [63:40] position fenetre
//   0x78  DBG_STALL_UP RO  plus longue attente d'un ready, cote maitre, par
//   0x80  DBG_STALL_DN RO  canal AW/W/B/AR/R : 5 champs de 12 bits, satures a
//                          4095. Saturé = coince ; moyen = contention.
//   0x88  CNT_CYC      RO  [31:0] cycles de blocage effectif
//                          [63:32] cycles passes en attente de verdict (HOLD)
//   0x90  CNT_REQ      RO  [31:0] transferts AW+AR presentes par le maitre
//                          [63:32] transferts AW+AR admis en aval
//                          leur difference = requetes reellement coupees
//   0x98  LAT_LAST     RO  [31:0] latence de detection de la derniere
//                          transaction, [63:32] latence de transaction
//   0xA0  LAT_DET_SUM  RO  somme des latences de detection
//   0xA8  LAT_TX_SUM   RO  somme des latences de transaction
//   0xB0  LAT_N        RO  [31:0] transactions mesurees
//                          [63:32] dont un verdict a ete observe
//   0xB8  LAT_MINMAX   RO  [15:0] det_min [31:16] det_max
//                          [47:32] tx_min [63:48] tx_max (satures a 65535)
//   0xC0  LAT_CUR      RO  [31:0] compteur de la transaction EN VOL,
//                          [32] mesure en cours, [33] verdict deja vu
//   0xC8  CYC_TOTAL    RO  cycles ecoules depuis le dernier CNT_CLR
//
// Version 3 (2026-09-10) : trois angles morts fermes, apres une campagne qui a
// gele avec sticky = 0, cyc_block = 0, cyc_hold = 0 et w_owed = 0 -- c'est-a-dire
// sans qu'aucun compteur existant ne voie quoi que ce soit.
//
//   0xD0  CNT_BADID    RO  [31:0] fronts de bad_id, [63:32] cycles a 1
//                          bad_id est le SEUL mecanisme gate par ENFORCE ; il
//                          n'avait ni bit de statut, ni bit collant, ni
//                          compteur. Il est aussi remonte dans STATUS[14] et
//                          rendu collant.
//   0xD8  CNT_WCH      RO  [31:0] AW admis en aval, [63:32] W-last admis
//                          comptes SEPAREMENT : `w_owed` est un solde dont le
//                          decrement garde absorbe un W-last excedentaire en
//                          silence. L'ecart se lit ici dans les deux sens.
//   0xE0  CNT_WANOM    RO  [31:0] beats FANTOMES, [63:32] W-last orphelins
//                          fantome = l'aval prend le beat alors que le maitre
//                          n'en est pas informe, donc le maitre le represente
//                          et l'aval en recoit deux. Trou reel de la branche
//                          HOLD de response_manager ; le banc le dit
//                          inatteignable par cet accelerateur, ce compteur
//                          verifie la meme chose sur la carte.
//   0xE8  DBG_WOWED    RO  [7:0] w_owed courant, [15:8] filigrane de maximum
//                          DEUX CHAMPS DE 8 BITS depuis v14 ; ils en faisaient 4
//                          et saturaient a 15, ce qui ne tient plus face a un
//                          maitre qui emet ses adresses a la volee. DBG_STATE
//                          (0x70) continue de n'en porter que les quatre bits
//                          bas : c'est ici qu'on lit la valeur entiere.
//
// Version 4 (2026-09-10, apres le run SC03-first qui montre le gel specifique
// aux ECRITURES et non proportionnel a l'action d'ARMOR) :
//
//   0xF0  CNT_RETRACT  RO  VALID retire sans READY, 16 bits par canal :
//                          [15:0] AW aval, [31:16] AR aval, [47:32] W aval,
//                          [63:48] B ou R vers le maitre
//                          AXI4 interdit de retirer un VALID asserte. Ces
//                          compteurs sont les seuls a pouvoir le voir : aucun
//                          handshake ne s'accomplit, donc aucun autre ne bouge.
//   0xF8  DBG_RETRACT  RO  [31:0] cycle du PREMIER retrait (base CYC_TOTAL)
//   0x100 ADDR_SPAN   RO  [31:0] plus petite adresse vue, [63:32] plus grande
//   0x108 ADDR_WALK   RO  [31:0] changements de page, [51:32] derniere page
//
//  ADDR_SPAN / ADDR_WALK : ce que les moniteurs de DEBIT ne peuvent pas voir.
//  Un accelerateur compromis qui emet au rythme NOMINAL mais parcourt l'espace
//  d'adresses ne fait franchir aucun seuil -- ni le flux, ni l'outstanding, ni
//  l'IOMMU tant qu'il reste dans les pages qu'on lui a donnees. Ce qui le
//  distingue du trafic legitime est l'ETENDUE qu'il touche et la FREQUENCE a
//  laquelle il en change, deux grandeurs qu'aucun compteur par fenetre ne
//  porte. Elles ne decident de rien ici : le wrapper les EXPOSE, et c'est un
//  superviseur echantillonnant sur un horizon long qui en tire une conclusion.
//
//  Les adresses sont observees sur 32 bits : la DRAM de la carte occupe
//  0x8000_0000 + 1 Gio, donc rien d'interessant ne vit au-dessus de 4 Gio, et
//  deux comparateurs 64 bits par wrapper coutaient le double pour rien.
//                          [35:32] cause : b0 block_req, b1 !legit_hit,
//                                  b2 !verdict_known, b3 bad_id
//                          [39:36] canal : 1 AW, 2 AR, 3 W, 4 B/R
//                          [40] un retrait a ete vu
//                          La cause distingue « retrait pendant un blocage » de
//                          « retrait pendant l'attente de verdict » : deux
//                          correctifs differents.
//                          (w_owed_q fait 4 bits et sature a 15 ; le premier
//                          commentaire annoncait 8 bits par champ et le
//                          firmware l'a cru, d'ou un « w_owed=16 max=0 »
//                          impossible dans le log du 2026-09-10 12:36 :
//                          c'etait 0x10, soit max=1 et owed=0)
//
// Corrige aussi CNT_CYC[63:32] (cyc_hold), qui etait conditionne a la
// presentation d'une adresse et manquait donc tout HOLD entre pendant une phase
// W -- exactement le cas d'une rafale d'ecritures.
//
// Ces compteurs chronometrent au cycle, dans le wrapper : ils remplacent la
// mesure logicielle prise autour de `*ctrl = 1`, dont jusqu'a 48 % du chiffre
// etait le cout de la sonde elle-meme.
//
// STATUS et STICKY reprennent volontairement les positions de bits deja
// utilisees cote logiciel (bench_runner.c / main.c), pour que classify() et
// armor_blocked() fonctionnent sans modification :
//
//   [3] BLOCKED  blocage effectif (apres gate ENFORCE)
//   [4] BANNED   block_ip_o          — brut, moniteur, non gate
//   [5] STORM    block_req_flow      — brut
//   [6] OUTS     block_req_outs      — brut
//   [7] MSI      block_msi           — brut
//   [8] threat_detected   [9] storm_flag   [10] outs_overflow   [11] msi_storm
//   [12] legit_hit        [13] ENFORCE (echo de CTRL[0])
//
// ENFORCE (CTRL[0], valeur de reset 0) ne conditionne QUE le blocage. Les
// moniteurs tournent en permanence, donc STATUS, STICKY et les compteurs
// restent valides meme a 0. A 0 le wrapper est transparent : c'est la baseline
// "sans ARMOR" obtenue dans le MEME bitstream, sans resynthese.
// =============================================================================

// Les deux nets jusqu'ici sans driver sont desormais pilotes par les CSR.
assign fixed_ID_reg       = csr_id_cfg_q[DevIDWidth-1:0];
assign msi_address_config = csr_msi_addr_q[AddrWidth-1:0];

// -----------------------------------------------------------------------------
// Vecteur de statut
// -----------------------------------------------------------------------------
logic [63:0] armor_status;

always_comb begin
    armor_status      = 64'h0;
    armor_status[3]   = block_req_i;          // blocage effectif (gate incluse)
    armor_status[4]   = block_ip_o;           // verdicts bruts des moniteurs :
    armor_status[5]   = block_req_flow;       //   visibles meme si ENFORCE = 0,
    armor_status[6]   = block_req_outs;       //   ce qui permet de mesurer la
    armor_status[7]   = block_msi;            //   detection sans subir le blocage
    armor_status[8]   = threat_detected;
    armor_status[9]   = storm_flag;
    armor_status[10]  = overflow_flag_outs;
    armor_status[11]  = msi_storm;
    armor_status[12]  = legit_hit;
    armor_status[13]  = csr_enforce_q;
    // bad_id (2026-09-10). Il n'apparaissait NI ici, NI dans STICKY, NI dans
    // aucun compteur -- et c'est le seul mecanisme gate par ENFORCE : il
    // fabrique une terminaison SLVERR vers le maitre en forcant b_ready et
    // r_ready en aval. Un gel avec sticky=0 et cyc_block=0 etait donc
    // indiscernable d'un gel ou rien ne s'est passe. Il est desormais visible,
    // instantanement et de facon collante.
    armor_status[14]  = bad_id;
    armor_status[15]  = csr_awfix_q;   // echo du correctif AXI4
    armor_status[16]  = csr_wskid_q;   // echo de l'etage W
    armor_status[17]  = csr_fresh_q;   // echo du verdict frais exige
    armor_status[18]  = csr_txblk_q;   // echo du blocage transactionnel
    armor_status[19]  = csr_wcap_q;    // echo de la dette W a la capture
    armor_status[20]  = csr_rhold_q;   // echo du maintien des reponses
    armor_status[21]  = csr_wfate_q;   // echo du sort de chaque AW
    armor_status[22]  = fate_ovf_q;    // FIFO W_FATE debordee : doit rester a 0
    armor_status[23]  = csr_bfate_q;   // echo du sort de chaque ecriture cote B
    armor_status[24]  = bq_ovf_q;      // file B_FATE debordee : doit rester a 0
end

// -----------------------------------------------------------------------------
// Sticky, compteurs d'evenements, dernier device ID observe
// -----------------------------------------------------------------------------
logic ban_d, storm_d, outs_d, msi_d;

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        ban_d         <= 1'b0;
        storm_d       <= 1'b0;
        outs_d        <= 1'b0;
        msi_d         <= 1'b0;
        csr_sticky_q  <= 64'h0;
        cnt_banned_q  <= 32'h0;
        cnt_storm_q   <= 32'h0;
        cnt_outs_q    <= 32'h0;
        cnt_msi_q     <= 32'h0;
        cnt_reqmax_q  <= 8'h0;
        cnt_winact_q  <= 24'h0;
        cnt_outsmax_q <= 8'h0;
        dev_id_last_q <= '0;
    end else begin
        ban_d   <= block_ip_o;
        storm_d <= block_req_flow;
        outs_d  <= block_req_outs;
        msi_d   <= block_msi;

        if (Device_ID_write_enable_o) dev_id_last_q <= Device_ID_o;

        // Les verdicts de flux ne durent que quelques cycles (BLOCK_CYCLES = 4
        // et 10 en profil BENCH) : une lecture logicielle de STATUS les rate
        // presque toujours. STICKY et les compteurs sont la seule mesure fiable.
        // Seuls les bits d'evenement sont cumules. Les bits [12] legit_hit et
        // [13] ENFORCE sont des echos d'etat : les rendre collants n'aurait
        // aucun sens (ils resteraient a 1 des la premiere requete legitime).
        if (csr_sticky_clr) csr_sticky_q <= 64'h0;
        else                csr_sticky_q <= csr_sticky_q | (armor_status & ARMOR_STICKY_MASK);

        if (csr_cnt_clr) begin
            cnt_banned_q <= 32'h0;
            cnt_storm_q  <= 32'h0;
            cnt_outs_q   <= 32'h0;
            cnt_msi_q    <= 32'h0;
            cnt_reqmax_q  <= 8'h0;
            cnt_winact_q  <= 24'h0;
            cnt_outsmax_q <= 8'h0;
        end else begin
            if (block_ip_o     && !ban_d)   cnt_banned_q <= cnt_banned_q + 1;
            if (block_req_flow && !storm_d) cnt_storm_q  <= cnt_storm_q  + 1;
            if (block_req_outs && !outs_d)  cnt_outs_q   <= cnt_outs_q   + 1;
            if (block_msi      && !msi_d)   cnt_msi_q    <= cnt_msi_q    + 1;

            // Occupation de la fenetre de flux. Le maximum se prend en continu
            // -- flow_req_cnt ne retombe qu'a la fermeture de la fenetre, le
            // suivre cycle a cycle revient au meme et evite de dependre d'un
            // instant d'echantillonnage. Les fenetres actives se comptent au
            // DERNIER cycle de la fenetre, le seul ou le compte est complet.
            if (flow_req_cnt > cnt_reqmax_q) cnt_reqmax_q <= flow_req_cnt;
            if (outs_depth   > cnt_outsmax_q) cnt_outsmax_q <= outs_depth;
            if (flow_win_close && flow_req_cnt != 8'h0 &&
                cnt_winact_q != 24'hFF_FFFF)
                cnt_winact_q <= cnt_winact_q + 24'd1;
        end
    end
end

// -----------------------------------------------------------------------------
// Esclave AXI4 de configuration
//
// Portee volontairement minimale : un seul acces en vol par sens, rafales INCR
// gerees en incrementant l'index de registre a chaque beat. Le port n'accepte
// pas de W avant son AW — c'est licite en AXI4, le maitre maintient simplement
// w_valid jusqu'a ce que l'AW soit passe.
// -----------------------------------------------------------------------------
typedef enum logic [1:0] { ARMOR_W_IDLE, ARMOR_W_DATA, ARMOR_W_RESP } armor_w_state_e;
typedef enum logic       { ARMOR_R_IDLE, ARMOR_R_DATA }               armor_r_state_e;

armor_w_state_e         w_state_q;
armor_r_state_e         r_state_q;
// On ne latche que les champs reellement utilises (id pour la reponse, len
// pour le dernier beat) : latcher le canal entier laisserait des bascules
// mortes que la synthese retire en emettant du bruit dans le log.
logic [IdWidthSlv-1:0]  aw_id_q, ar_id_q;
logic [7:0]             ar_len_q;
logic [CSR_IDX_W-1:0]   w_idx_q, r_idx_q;
logic [7:0]             r_beat_q;
logic [63:0]            csr_rdata;

// Canal ecriture
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        w_state_q      <= ARMOR_W_IDLE;
        aw_id_q        <= '0;
        w_idx_q        <= '0;
        csr_id_cfg_q   <= 64'h0;
        csr_msi_addr_q <= 64'h0;
        csr_enforce_q  <= 1'b0;   // reset : wrapper transparent
        csr_awfix_q    <= 1'b0;   // reset : comportement historique conserve
        csr_wskid_q    <= 1'b0;   // reset : etage W en derivation
        csr_fresh_q    <= 1'b0;   // reset : comportement historique
        csr_txblk_q    <= 1'b0;   // reset : comportement historique
        csr_wcap_q     <= 1'b0;   // reset : comportement historique
        csr_rhold_q    <= 1'b0;   // reset : comportement historique
        csr_wfate_q    <= 1'b0;   // reset : comportement historique
        csr_bfate_q    <= 1'b0;   // reset : comportement historique
        csr_irqen_q    <= 1'b0;   // reset : aucune interruption tant qu'on ne l'arme pas
        csr_rfmcnt_q   <= 1'b0;   // reset : comptage historique par fronts
        csr_thresh_q   <= 8'h0;   // reset : seuil de synthese (8)
        csr_sticky_clr <= 1'b0;
        csr_cnt_clr    <= 1'b0;
    end else begin
        csr_sticky_clr <= 1'b0;   // commandes a impulsion d'un cycle
        csr_cnt_clr    <= 1'b0;

        case (w_state_q)
            ARMOR_W_IDLE: begin
                if (req_CPU_Wrapper__i.aw_valid) begin
                    aw_id_q   <= req_CPU_Wrapper__i.aw.id;
                    w_idx_q   <= req_CPU_Wrapper__i.aw.addr[8:3];
                    w_state_q <= ARMOR_W_DATA;
                end
            end

            ARMOR_W_DATA: begin
                if (req_CPU_Wrapper__i.w_valid) begin
                    case (w_idx_q)
                        5'd0: csr_id_cfg_q   <= req_CPU_Wrapper__i.w.data;
                        5'd1: csr_msi_addr_q <= req_CPU_Wrapper__i.w.data;
                        5'd2: begin
                            csr_enforce_q  <= req_CPU_Wrapper__i.w.data[0];
                            csr_sticky_clr <= req_CPU_Wrapper__i.w.data[1];
                            csr_cnt_clr    <= req_CPU_Wrapper__i.w.data[2];
                            csr_awfix_q    <= req_CPU_Wrapper__i.w.data[3];
                            csr_wskid_q    <= req_CPU_Wrapper__i.w.data[4];
                            csr_fresh_q    <= req_CPU_Wrapper__i.w.data[5];
                            csr_txblk_q    <= req_CPU_Wrapper__i.w.data[6];
                            csr_wcap_q     <= req_CPU_Wrapper__i.w.data[7];
                            csr_rhold_q    <= req_CPU_Wrapper__i.w.data[8];
                            csr_wfate_q    <= req_CPU_Wrapper__i.w.data[9];
                            csr_bfate_q    <= req_CPU_Wrapper__i.w.data[10];
                            csr_irqen_q    <= req_CPU_Wrapper__i.w.data[11];
                            csr_rfmcnt_q   <= req_CPU_Wrapper__i.w.data[12];
                            csr_thresh_q   <= req_CPU_Wrapper__i.w.data[23:16];
                        end
                        default: ; // registres en lecture seule
                    endcase
                    w_idx_q <= w_idx_q + 1'b1;
                    if (req_CPU_Wrapper__i.w.last) w_state_q <= ARMOR_W_RESP;
                end
            end

            ARMOR_W_RESP: begin
                if (req_CPU_Wrapper__i.b_ready) w_state_q <= ARMOR_W_IDLE;
            end

            default: w_state_q <= ARMOR_W_IDLE;
        endcase
    end
end

// Canal lecture
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        r_state_q <= ARMOR_R_IDLE;
        ar_id_q   <= '0;
        ar_len_q  <= 8'h0;
        r_idx_q   <= '0;
        r_beat_q  <= 8'h0;
    end else begin
        case (r_state_q)
            ARMOR_R_IDLE: begin
                if (req_CPU_Wrapper__i.ar_valid) begin
                    ar_id_q   <= req_CPU_Wrapper__i.ar.id;
                    ar_len_q  <= req_CPU_Wrapper__i.ar.len;
                    r_idx_q   <= req_CPU_Wrapper__i.ar.addr[8:3];
                    r_beat_q  <= 8'h0;
                    r_state_q <= ARMOR_R_DATA;
                end
            end

            ARMOR_R_DATA: begin
                if (req_CPU_Wrapper__i.r_ready) begin
                    if (r_beat_q == ar_len_q) begin
                        r_state_q <= ARMOR_R_IDLE;
                    end else begin
                        r_idx_q  <= r_idx_q  + 1'b1;
                        r_beat_q <= r_beat_q + 8'h1;
                    end
                end
            end

            default: r_state_q <= ARMOR_R_IDLE;
        endcase
    end
end

// =============================================================================
//  OBSERVABILITE MATERIELLE  (2026-09-10)
//
//  Deux besoins, un seul bloc.
//
//  1. MESURER. Toutes les latences publiees jusqu'ici sont prises par le
//     logiciel, autour de `*ctrl = 1`, avec une lecture de compteur de part et
//     d'autre. Le cout de la sonde elle-meme (~650 ticks par lecture de `time`
//     sous Bao, ~1300 cycles coeur) representait jusqu'a 48 % du chiffre
//     publie : la mesure etait bornee par l'instrument, pas par le materiel.
//     Les compteurs ci-dessous chronometrent DANS le wrapper, au cycle, sans
//     instrument dans la boucle. C'est la mesure qu'on peut opposer a une autre
//     implementation.
//
//  2. DEBOGUER LE GEL. Le gel de SC02-STORM se produit sur un store CPU qui
//     n'emprunte meme pas ARMOR : pour qu'il reste en l'air, il faut que le
//     canal d'ecriture du crossbar partage soit coince par le chemin DMA. Le
//     banc de simulation ne modelise pas ce crossbar et a valide du vide quatre
//     fois de suite. Il faut donc lire l'etat sur la carte. Les registres
//     DBG_UP / DBG_DN donnent les poignees de main VIVANTES des deux cotes de
//     la coupure, DBG_STALL_* dit quel canal ne recoit pas son ready et depuis
//     combien de cycles, LAT_CUR dit depuis combien de temps une transaction
//     est en vol. Un blocage se lit alors, au lieu de se deviner.
//
//  Tout ce bloc est en LECTURE SEULE et ne pilote aucun signal fonctionnel :
//  aucun risque de changer un verdict en instrumentant. Les accumulateurs
//  suivent CNT_CLR, comme les compteurs d'evenements existants.
// =============================================================================

// -----------------------------------------------------------------------------
//  Poignees de main vivantes, de part et d'autre de la coupure
//
//  Meme disposition de bits des deux cotes, pour un seul decodeur logiciel :
//    [0] aw_valid [1] aw_ready [2] w_valid [3] w_ready [4] w_last
//    [5] b_valid  [6] b_ready  [7] ar_valid [8] ar_ready
//    [9] r_valid [10] r_ready [11] r_last
//
//  « up » = cote maitre surveille (l'accelerateur), « dn » = cote aval (IOMMU
//  puis crossbar). Comparer les deux revele exactement ce que la detection
//  actuelle confond : `request_flow_monitor` apparie le valid du maitre avec le
//  ready de l'aval, si bien qu'un handshake « brut » reste vrai alors qu'ARMOR
//  coupe et que rien ne circule.
// -----------------------------------------------------------------------------
logic [11:0] dbg_up, dbg_dn;

always_comb begin
    dbg_up      = 12'h0;
    dbg_up[0]   = req_IP_wrapper_i.aw_valid;
    dbg_up[1]   = resp_IP_wrapper_o.aw_ready;
    dbg_up[2]   = req_IP_wrapper_i.w_valid;
    dbg_up[3]   = resp_IP_wrapper_o.w_ready;
    dbg_up[4]   = req_IP_wrapper_i.w.last;
    dbg_up[5]   = resp_IP_wrapper_o.b_valid;
    dbg_up[6]   = req_IP_wrapper_i.b_ready;
    dbg_up[7]   = req_IP_wrapper_i.ar_valid;
    dbg_up[8]   = resp_IP_wrapper_o.ar_ready;
    dbg_up[9]   = resp_IP_wrapper_o.r_valid;
    dbg_up[10]  = req_IP_wrapper_i.r_ready;
    dbg_up[11]  = resp_IP_wrapper_o.r.last;

    dbg_dn      = 12'h0;
    dbg_dn[0]   = req_wrapper_iommu_o.aw_valid;
    dbg_dn[1]   = resp_wrapper_iommu_i.aw_ready;
    dbg_dn[2]   = req_wrapper_iommu_o.w_valid;
    dbg_dn[3]   = resp_wrapper_iommu_i.w_ready;
    dbg_dn[4]   = req_wrapper_iommu_o.w.last;
    dbg_dn[5]   = resp_wrapper_iommu_i.b_valid;
    dbg_dn[6]   = req_wrapper_iommu_o.b_ready;
    dbg_dn[7]   = req_wrapper_iommu_o.ar_valid;
    dbg_dn[8]   = resp_wrapper_iommu_i.ar_ready;
    dbg_dn[9]   = resp_wrapper_iommu_i.r_valid;
    dbg_dn[10]  = req_wrapper_iommu_o.r_ready;
    dbg_dn[11]  = resp_wrapper_iommu_i.r.last;
end

// -----------------------------------------------------------------------------
//  Transferts reels, et non fronts de handshake
//
//  A distinguer de `req_fire` du request_flow_monitor, qui compte des FRONTS :
//  en AXI, valid et ready tenus hauts, c'est un transfert PAR CYCLE, et les 24
//  lectures du mode outstanding ne comptaient que pour une. Ces deux compteurs
//  comptent les transferts, chacun de SON cote de la coupure. Leur difference
//  est le nombre de requetes qu'ARMOR a effectivement coupees -- la seule
//  mesure directe de son action, jusqu'ici deduite des verdicts.
// -----------------------------------------------------------------------------
logic up_aw_hs, up_ar_hs, up_b_hs, up_r_last_hs;

assign up_aw_hs     = req_IP_wrapper_i.aw_valid & resp_IP_wrapper_o.aw_ready;
assign up_ar_hs     = req_IP_wrapper_i.ar_valid & resp_IP_wrapper_o.ar_ready;
assign up_b_hs      = resp_IP_wrapper_o.b_valid & req_IP_wrapper_i.b_ready;
assign up_r_last_hs = resp_IP_wrapper_o.r_valid & req_IP_wrapper_i.r_ready
                                                & resp_IP_wrapper_o.r.last;
// dn_ar_hs est declare avec dn_aw_hs, plus haut : request_flow_monitor le
// consomme avant ce point du fichier.

// -----------------------------------------------------------------------------
//  Chronometre materiel d'une transaction
//
//  Definitions calquees sur celles de bench_runner.c, pour que les deux mesures
//  soient comparables -- et pour que l'ecart entre elles chiffre le cout de la
//  sonde logicielle :
//
//    depart   : front de presentation d'une requete par le maitre
//               (aw_valid | ar_valid), si aucune mesure n'est en cours ;
//    detection: premier cycle ou un verdict quelconque apparait ;
//    fin      : terminaison de la transaction VERS LE MAITRE (B, ou R avec
//               last) -- ce qui couvre aussi bien une transaction qui aboutit
//               qu'une que response_manager termine en SLVERR.
//
//  Trois approximations assumees, a garder en tete avant de publier :
//    - `tx` est lu au cycle de la fin, donc peut etre court d'un cycle ;
//    - un verdict qui apparait dans le meme cycle que le depart n'est pas vu
//      comme detection (la mesure n'est pas encore armee) : `det` vaut alors
//      `tx`, exactement comme le fait le logiciel quand il ne voit aucun bit ;
//    - une fin et un depart dans le meme cycle perdent le depart. Le bench
//      espace ses transactions, ca ne se produit pas sur ces scenarios.
//
//  LAT_CUR expose le compteur EN VOL : une transaction coincee s'y lit comme un
//  chiffre qui monte, la ou tout le reste reste muet.
// -----------------------------------------------------------------------------
logic        lat_verdict, lat_end, lat_start;
logic        req_presented, req_presented_q;

assign lat_verdict   = block_req_i | bad_id | block_ip_o
                     | block_req_flow | block_req_outs | block_msi;
assign lat_end       = up_b_hs | up_r_last_hs;
assign req_presented = req_IP_wrapper_i.aw_valid | req_IP_wrapper_i.ar_valid;

logic [31:0] lat_cnt_q;
logic        lat_busy_q, lat_evt_q;
logic [31:0] lat_det_q;
logic [31:0] lat_det_last_q, lat_tx_last_q;
logic [63:0] lat_det_sum_q,  lat_tx_sum_q;
logic [31:0] lat_n_q,        lat_n_blk_q;
logic [15:0] lat_det_min_q,  lat_det_max_q, lat_tx_min_q, lat_tx_max_q;

logic [31:0] lat_det_val;
logic [15:0] lat_det_sat, lat_tx_sat;

//  Le depart doit se rearmer sur une rafale. `req_presented` seul ne suffit
//  pas : pendant une tempete, le maitre tient aw_valid haut en permanence, il
//  n'y a donc plus AUCUN front et on n'aurait mesure que la premiere
//  transaction du scenario -- exactement les scenarios ou la mesure importe.
//  On part donc au premier des deux evenements : la presentation d'une requete
//  (front, qui inclut l'attente de verdict, pendant laquelle aucun handshake
//  n'a lieu) ou un transfert d'adresse reellement accepte cote maitre.
assign lat_start   = ~lat_busy_q & ( (req_presented & ~req_presented_q)
                                   | up_aw_hs | up_ar_hs );
assign lat_det_val = lat_evt_q ? lat_det_q : lat_cnt_q;
assign lat_det_sat = (lat_det_val > 32'd65535) ? 16'hFFFF : lat_det_val[15:0];
assign lat_tx_sat  = (lat_cnt_q   > 32'd65535) ? 16'hFFFF : lat_cnt_q[15:0];

// -----------------------------------------------------------------------------
//  Compteurs de temps et de trafic
// -----------------------------------------------------------------------------
logic [31:0] cnt_cyc_block_q, cnt_cyc_hold_q;
logic [31:0] cnt_req_up_q,    cnt_req_dn_q;

//  Etendue d'adresses touchee par le maitre surveille (v17). Voir la carte des
//  registres, 0x100 / 0x108. Observees sur les MEMES poignees de main que
//  cnt_req_up_q, donc une adresse par requete PRESENTEE et acceptee.
logic [31:0] addr_min_q, addr_max_q;
logic [31:0] cnt_pgchg_q;      // changements de page d'une requete a la suivante
logic [19:0] last_pg_q;        // page de la derniere requete, addr[31:12]
logic        pg_seen_q;        // une premiere page a-t-elle ete vue
logic [31:0] addr_obs;
logic        addr_fire;
//  AW prioritaire sur AR : si les deux tirent le meme cycle, on en perd une.
//  C'est sans effet sur l'etendue, qui est un min/max cumulatif, et sur le
//  compte de pages cela sous-estime -- jamais l'inverse.
assign addr_fire = up_aw_hs | up_ar_hs;
assign addr_obs  = up_aw_hs ? req_IP_wrapper_i.aw.addr[31:0]
                            : req_IP_wrapper_i.ar.addr[31:0];
logic [63:0] cyc_total_q;

//  HOLD : la fenetre pendant laquelle response_manager tient le maitre sans
//  encore rien decider.
//
//  CORRECTIF DU 2026-09-10. La version precedente conditionnait le comptage a
//  `req_presented` (aw_valid | ar_valid). Or le commentaire du correctif de
//  verdict_known_q dit exactement pourquoi c'est faux : « une fois l'AW absorbe,
//  le maitre passe en phase W, plus rien n'est presente ». Un HOLD entre pendant
//  une phase W -- le cas qui compte pour une rafale d'ecritures -- etait donc
//  invisible, et c'est ce qui a fait lire `cyc_hold = 0` sur la campagne SC02
//  qui gele. Le compteur avait le meme angle mort que le defaut qu'il devait
//  eclairer.
//
//  On garde une garde d'activite, sinon on compterait le repos : apres reset et
//  sous ENFORCE = 1, verdict_known_q vaut 0 et le compteur saturerait sans qu'un
//  seul maitre attende. Mais cette garde couvre maintenant les trois facons
//  d'attendre : presenter une adresse, pousser des donnees, ou attendre une
//  reponse.
logic master_active, hold_mode;

assign master_active = req_presented
                     | req_IP_wrapper_i.w_valid
                     | lat_busy_q;

assign hold_mode = master_active & ~block_req_i & ~block_ip_eff & ~bad_id
                 & (~legit_hit_eff | ~verdict_known_eff);

logic [1:0] req_up_inc, req_dn_inc;
assign req_up_inc = {1'b0, up_aw_hs} + {1'b0, up_ar_hs};
assign req_dn_inc = {1'b0, dn_aw_hs} + {1'b0, dn_ar_hs};

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        req_presented_q <= 1'b0;
        lat_cnt_q       <= 32'h0;
        lat_busy_q      <= 1'b0;
        lat_evt_q       <= 1'b0;
        lat_det_q       <= 32'h0;
        lat_det_last_q  <= 32'h0;
        lat_tx_last_q   <= 32'h0;
        lat_det_sum_q   <= 64'h0;
        lat_tx_sum_q    <= 64'h0;
        lat_n_q         <= 32'h0;
        lat_n_blk_q     <= 32'h0;
        lat_det_min_q   <= 16'hFFFF;
        lat_tx_min_q    <= 16'hFFFF;
        lat_det_max_q   <= 16'h0;
        lat_tx_max_q    <= 16'h0;
        cnt_cyc_block_q <= 32'h0;
        cnt_cyc_hold_q  <= 32'h0;
        cnt_req_up_q    <= 32'h0;
        cnt_req_dn_q    <= 32'h0;
        cyc_total_q     <= 64'h0;
    end else begin
        req_presented_q <= req_presented;

        if (csr_cnt_clr) begin
            // Remise a zero solidaire des compteurs d'evenements : un scenario
            // de bench appelle CNT_CLR au demarrage, ses chiffres sont donc a
            // lui seul.
            lat_cnt_q       <= 32'h0;
            lat_busy_q      <= 1'b0;
            lat_evt_q       <= 1'b0;
            lat_det_q       <= 32'h0;
            lat_det_last_q  <= 32'h0;
            lat_tx_last_q   <= 32'h0;
            lat_det_sum_q   <= 64'h0;
            lat_tx_sum_q    <= 64'h0;
            lat_n_q         <= 32'h0;
            lat_n_blk_q     <= 32'h0;
            lat_det_min_q   <= 16'hFFFF;
            lat_tx_min_q    <= 16'hFFFF;
            lat_det_max_q   <= 16'h0;
            lat_tx_max_q    <= 16'h0;
            cnt_cyc_block_q <= 32'h0;
            cnt_cyc_hold_q  <= 32'h0;
            cnt_req_up_q    <= 32'h0;
            cnt_req_dn_q    <= 32'h0;
            cyc_total_q     <= 64'h0;
            addr_min_q      <= 32'hFFFF_FFFF;
            addr_max_q      <= 32'h0;
            cnt_pgchg_q     <= 32'h0;
            last_pg_q       <= 20'h0;
            pg_seen_q       <= 1'b0;
        end else begin
            cyc_total_q <= cyc_total_q + 64'd1;

            if (block_req_i && cnt_cyc_block_q != 32'hFFFF_FFFF)
                cnt_cyc_block_q <= cnt_cyc_block_q + 32'd1;
            if (hold_mode   && cnt_cyc_hold_q  != 32'hFFFF_FFFF)
                cnt_cyc_hold_q  <= cnt_cyc_hold_q + 32'd1;

            cnt_req_up_q <= cnt_req_up_q + {30'h0, req_up_inc};
            cnt_req_dn_q <= cnt_req_dn_q + {30'h0, req_dn_inc};

            if (addr_fire) begin
                if (addr_obs < addr_min_q) addr_min_q <= addr_obs;
                if (addr_obs > addr_max_q) addr_max_q <= addr_obs;
                //  La premiere requete n'est pas un changement : sans ce garde,
                //  tout scenario compterait un deplacement qui n'a pas eu lieu.
                if (pg_seen_q && (addr_obs[31:12] != last_pg_q) &&
                    cnt_pgchg_q != 32'hFFFF_FFFF)
                    cnt_pgchg_q <= cnt_pgchg_q + 32'd1;
                last_pg_q <= addr_obs[31:12];
                pg_seen_q <= 1'b1;
            end

            if (lat_busy_q) begin
                if (lat_cnt_q != 32'hFFFF_FFFF) lat_cnt_q <= lat_cnt_q + 32'd1;

                if (!lat_evt_q && lat_verdict) begin
                    lat_evt_q <= 1'b1;
                    lat_det_q <= lat_cnt_q;
                end

                if (lat_end) begin
                    lat_busy_q     <= 1'b0;
                    lat_det_last_q <= lat_det_val;
                    lat_tx_last_q  <= lat_cnt_q;
                    lat_det_sum_q  <= lat_det_sum_q + {32'h0, lat_det_val};
                    lat_tx_sum_q   <= lat_tx_sum_q  + {32'h0, lat_cnt_q};
                    lat_n_q        <= lat_n_q + 32'd1;
                    if (lat_evt_q) lat_n_blk_q <= lat_n_blk_q + 32'd1;
                    if (lat_det_sat < lat_det_min_q) lat_det_min_q <= lat_det_sat;
                    if (lat_det_sat > lat_det_max_q) lat_det_max_q <= lat_det_sat;
                    if (lat_tx_sat  < lat_tx_min_q)  lat_tx_min_q  <= lat_tx_sat;
                    if (lat_tx_sat  > lat_tx_max_q)  lat_tx_max_q  <= lat_tx_sat;
                end
            end else if (lat_start) begin
                lat_busy_q <= 1'b1;
                lat_cnt_q  <= 32'h0;
                lat_det_q  <= 32'h0;
                //  Le verdict est echantillonne DES le cycle de depart.
                //  Sans cela il ne l'etait qu'a partir du cycle suivant, et le
                //  cas le plus interessant y echappait entierement : quand la
                //  fenetre de blocage est deja ouverte, response_manager
                //  termine la requete en SLVERR dans le cycle meme, si bien que
                //  la transaction etait finie avant d'avoir ete regardee. La
                //  simulation le montrait sans ambiguite -- n_verdict = 0 sur
                //  SC02-STORM et SC01-SPOOF, alors que 67 et 8 requetes
                //  respectivement avaient ete coupees.
                //
                //  Une detection a 0 cycle n'est pas une absence de mesure :
                //  c'est le cas ou ARMOR n'a rien eu a decider, son verdict
                //  etait deja rendu. C'est cette valeur-la qui soutient
                //  l'argument « une transaction bloquee coute moins cher
                //  qu'une qui aboutit ».
                lat_evt_q  <= lat_verdict;
            end
        end
    end
end

// -----------------------------------------------------------------------------
//  LE CANAL W, ET CE QUI LUI ARRIVE VRAIMENT  (2026-09-10)
//
//  Trois compteurs qui ferment trois angles morts nommes par la campagne du
//  2026-09-10, tous a l'endroit ou vit la signature du gel (sticky = 0,
//  cyc_block = 0, cyc_hold = 0, w_owed = 0).
//
//  1. bad_id. Compte en fronts ET en cycles. C'est le seul mecanisme gate par
//     ENFORCE, et il ne laissait aucune trace : ni bit de statut, ni bit
//     collant, ni compteur. `block_req_i` l'exclut, et `hold_mode` l'excluait
//     aussi. Un evenement bad_id etait litteralement indiscernable de rien.
//
//  2. Les deux cotes du canal W en aval, comptes SEPAREMENT. `w_owed_q` est un
//     solde, et son decrement est garde a zero : un W-last excedentaire y est
//     absorbe en silence. Compter les AW et les W-last separement rend le
//     desalignement lisible DANS LES DEUX SENS -- un AW sans donnees comme un
//     beat de trop. `cnt_w_orphan_q` isole directement le second cas.
//
//  3. Le BEAT FANTOME : l'aval prend le beat (w_valid & w_ready en aval) alors
//     que le maitre n'en est pas informe (w_ready retire cote maitre). Le maitre
//     croit son beat refuse et le represente ; l'aval en recoit deux, et le
//     canal W est decale pour toujours.
//
//     C'est un trou reel de la branche HOLD de response_manager, qui sort '0
//     sur tout -- donc w_ready = 0 -- alors que request_manager ne coupe
//     w_valid que si `!w_pending`. La branche passe-plat traite ce piege
//     explicitement ; la branche HOLD ne le traite pas.
//
//     Le banc dit ce trou INATTEIGNABLE par cet accelerateur : sa FSM est
//     sequentielle (G_AW -> G_W -> G_NEXT), donc `aw_owed max = 1` et jamais
//     deux ecritures ne se chevauchent. Mais le banc ne modelise ni la latence
//     de l'IOMMU, ni le crossbar, et il a deja valide du vide quatre fois. Ce
//     compteur est la version SUR CARTE du meme test : s'il bouge, le trou est
//     atteignable en vrai et on a la cause racine.
// -----------------------------------------------------------------------------
logic [31:0] cnt_badid_rise_q, cnt_badid_cy_q;
logic [31:0] cnt_aw_dn_q,      cnt_wlast_dn_q;
logic [31:0] cnt_w_ghost_q,    cnt_w_orphan_q;
logic [7:0]  w_owed_max_q;
logic        bad_id_d_q;

logic dn_w_ghost, dn_w_orphan;

//  Le beat part en aval et y est pris, mais le maitre ne recoit pas son ready.
//
//  SANS OBJET QUAND L'ETAGE W EST ACTIF (correctif 2026-09-11). Avec CTRL[4],
//  le handshake aval et celui du maitre sont DECOUPLES par construction : un
//  beat pris en aval sort de l'etage, ou il n'est entre que par un handshake
//  cote maitre. Le ready du maitre y est celui de l'etage, et W_CAPDEBT le
//  baisse A JUSTE TITRE pendant que l'aval vide le dernier beat d'une ecriture.
//  Compter ce cas faisait accuser l'etage d'un defaut qu'il n'a pas : 25 puis
//  187 « fantomes » au banc sous WSKID=1 WCAP=1, pour ZERO anomalie
//  d'appariement -- or un vrai fantome ferait recevoir deux fois la meme
//  donnee a l'aval, et l'appariement le verrait.
assign dn_w_ghost  = req_wrapper_iommu_o.w_valid
                   & resp_wrapper_iommu_i.w_ready
                   & ~resp_IP_wrapper_o.w_ready
                   & ~csr_wskid_q;

//  Un W-last accepte en aval alors qu'aucun AW n'y attend de donnees, et
//  qu'aucun n'arrive dans le meme cycle : le solde ne peut pas le montrer.
assign dn_w_orphan = dn_w_last_hs & (w_owed_q == 4'h0) & ~dn_aw_hs;

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        cnt_badid_rise_q <= 32'h0;
        cnt_badid_cy_q   <= 32'h0;
        cnt_aw_dn_q      <= 32'h0;
        cnt_wlast_dn_q   <= 32'h0;
        cnt_w_ghost_q    <= 32'h0;
        cnt_w_orphan_q   <= 32'h0;
        w_owed_max_q     <= 8'h0;
        bad_id_d_q       <= 1'b0;
    end else if (csr_cnt_clr) begin
        cnt_badid_rise_q <= 32'h0;
        cnt_badid_cy_q   <= 32'h0;
        cnt_aw_dn_q      <= 32'h0;
        cnt_wlast_dn_q   <= 32'h0;
        cnt_w_ghost_q    <= 32'h0;
        cnt_w_orphan_q   <= 32'h0;
        w_owed_max_q     <= 8'h0;
        bad_id_d_q       <= bad_id;
    end else begin
        bad_id_d_q <= bad_id;

        if (bad_id) begin
            if (cnt_badid_cy_q != 32'hFFFF_FFFF)
                cnt_badid_cy_q <= cnt_badid_cy_q + 32'd1;
            if (!bad_id_d_q)
                cnt_badid_rise_q <= cnt_badid_rise_q + 32'd1;
        end

        if (dn_aw_hs)     cnt_aw_dn_q    <= cnt_aw_dn_q    + 32'd1;
        if (dn_w_last_hs) cnt_wlast_dn_q <= cnt_wlast_dn_q + 32'd1;
        if (dn_w_ghost)   cnt_w_ghost_q  <= cnt_w_ghost_q  + 32'd1;
        if (dn_w_orphan)  cnt_w_orphan_q <= cnt_w_orphan_q + 32'd1;

        if (w_owed_q > w_owed_max_q) w_owed_max_q <= w_owed_q;
    end
end

// -----------------------------------------------------------------------------
//  VALID RETIRE SANS READY  (2026-09-10, apres le run SC03-first)
//
//  Le seul mecanisme qui reste compatible avec tout ce qui a ete mesure, et le
//  seul qu'aucun compteur existant ne puisse voir.
//
//  Ce que le run du 2026-09-10 13:07 etablit : SC03 (lectures) coupe 612
//  requetes et bloque 3251 cycles sans geler, SC02 (ecritures) gele apres 16
//  coupures et 78 cycles, et SC07 (100 ecritures legitimes, zero coupure) passe.
//  Le declencheur n'est donc ni l'ecriture seule, ni la quantite de blocage :
//  c'est UNE COUPURE SUR LE CHEMIN D'ECRITURE. Et a la frontiere d'ARMOR le
//  canal W est equilibre a chaque iteration, gel inclus.
//
//  L'explication : request_manager coupe `aw_valid` de facon COMBINATOIRE des
//  que block_req_i, !legit_hit ou !verdict_known monte. Si le maitre avait deja
//  aw_valid haut en attente de son aw_ready, ARMOR le RETIRE. AXI4 l'interdit --
//  un VALID asserte doit etre tenu jusqu'au READY -- et un IOMMU qui a commence
//  une traduction sur ce VALID peut en garder un etat partiel. Aucun de mes
//  compteurs ne bouge, puisqu'aucun handshake ne s'accomplit.
//
//  response_manager fait la meme chose dans l'autre sens : son mode HOLD sort
//  '0 sur tout, ce qui retire b_valid et r_valid vers le maitre. Meme famille de
//  violation, comptee aussi.
//
//  Definition : au cycle precedent VALID etait haut sans handshake, et VALID est
//  retombe. Comptage sature a 65535, un champ de 16 bits par canal.
//
//  Le premier retrait est HORODATE et sa CAUSE est capturee : c'est ce qui
//  distinguera « ARMOR retire un VALID pendant un blocage » de « pendant
//  l'attente de verdict », deux correctifs differents.
// -----------------------------------------------------------------------------
logic dn_aw_v_q, dn_ar_v_q, dn_w_v_q, up_b_v_q, up_r_v_q;
logic dn_aw_r_q, dn_ar_r_q, dn_w_r_q, up_b_r_q, up_r_r_q;

logic retract_aw, retract_ar, retract_w, retract_br;

//  « VALID etait haut, READY ne l'etait pas, et VALID est retombe. »
assign retract_aw = dn_aw_v_q & ~dn_aw_r_q & ~req_wrapper_iommu_o.aw_valid;
assign retract_ar = dn_ar_v_q & ~dn_ar_r_q & ~req_wrapper_iommu_o.ar_valid;
assign retract_w  = dn_w_v_q  & ~dn_w_r_q  & ~req_wrapper_iommu_o.w_valid;
assign retract_br = (up_b_v_q & ~up_b_r_q & ~resp_IP_wrapper_o.b_valid)
                  | (up_r_v_q & ~up_r_r_q & ~resp_IP_wrapper_o.r_valid);

logic [15:0] cnt_retr_aw_q, cnt_retr_ar_q, cnt_retr_w_q, cnt_retr_br_q;
logic [31:0] retr_first_cyc_q;
logic [3:0]  retr_first_cause_q;   // {bad_id, ~vk, ~legit, block_req}
logic [3:0]  retr_first_chan_q;    // 1 AW, 2 AR, 3 W, 4 B/R
logic        retr_seen_q;

always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        dn_aw_v_q <= 1'b0; dn_ar_v_q <= 1'b0; dn_w_v_q <= 1'b0;
        up_b_v_q  <= 1'b0; up_r_v_q  <= 1'b0;
        dn_aw_r_q <= 1'b0; dn_ar_r_q <= 1'b0; dn_w_r_q <= 1'b0;
        up_b_r_q  <= 1'b0; up_r_r_q  <= 1'b0;
        cnt_retr_aw_q      <= 16'h0;
        cnt_retr_ar_q      <= 16'h0;
        cnt_retr_w_q       <= 16'h0;
        cnt_retr_br_q      <= 16'h0;
        retr_first_cyc_q   <= 32'h0;
        retr_first_cause_q <= 4'h0;
        retr_first_chan_q  <= 4'h0;
        retr_seen_q        <= 1'b0;
    end else begin
        //  Memoire d'un cycle des deux cotes de chaque handshake surveille.
        dn_aw_v_q <= req_wrapper_iommu_o.aw_valid;
        dn_ar_v_q <= req_wrapper_iommu_o.ar_valid;
        dn_w_v_q  <= req_wrapper_iommu_o.w_valid;
        up_b_v_q  <= resp_IP_wrapper_o.b_valid;
        up_r_v_q  <= resp_IP_wrapper_o.r_valid;
        dn_aw_r_q <= resp_wrapper_iommu_i.aw_ready;
        dn_ar_r_q <= resp_wrapper_iommu_i.ar_ready;
        dn_w_r_q  <= resp_wrapper_iommu_i.w_ready;
        up_b_r_q  <= req_IP_wrapper_i.b_ready;
        up_r_r_q  <= req_IP_wrapper_i.r_ready;

        if (csr_cnt_clr) begin
            cnt_retr_aw_q      <= 16'h0;
            cnt_retr_ar_q      <= 16'h0;
            cnt_retr_w_q       <= 16'h0;
            cnt_retr_br_q      <= 16'h0;
            retr_first_cyc_q   <= 32'h0;
            retr_first_cause_q <= 4'h0;
            retr_first_chan_q  <= 4'h0;
            retr_seen_q        <= 1'b0;
        end else begin
            if (retract_aw && cnt_retr_aw_q != 16'hFFFF)
                cnt_retr_aw_q <= cnt_retr_aw_q + 16'd1;
            if (retract_ar && cnt_retr_ar_q != 16'hFFFF)
                cnt_retr_ar_q <= cnt_retr_ar_q + 16'd1;
            if (retract_w  && cnt_retr_w_q  != 16'hFFFF)
                cnt_retr_w_q  <= cnt_retr_w_q  + 16'd1;
            if (retract_br && cnt_retr_br_q != 16'hFFFF)
                cnt_retr_br_q <= cnt_retr_br_q + 16'd1;

            //  Premier retrait : on garde l'instant, la cause et le canal.
            //  L'ordre de priorite ne sert qu'a nommer UN canal quand plusieurs
            //  retombent ensemble ; les compteurs, eux, les comptent tous.
            if (!retr_seen_q && (retract_aw | retract_ar | retract_w | retract_br)) begin
                retr_seen_q        <= 1'b1;
                retr_first_cyc_q   <= cyc_total_q[31:0];
                retr_first_cause_q <= {bad_id, ~verdict_known_eff,
                                       ~legit_hit_eff, block_req_i};
                retr_first_chan_q  <= retract_aw ? 4'd1 :
                                      retract_ar ? 4'd2 :
                                      retract_w  ? 4'd3 : 4'd4;
            end
        end
    end
end

// -----------------------------------------------------------------------------
//  Canal qui n'obtient pas son ready, et depuis combien de cycles
//
//  Cinq canaux par cote, dans l'ordre AW, W, B, AR, R. On garde la plus longue
//  attente observee, saturee a 4095 cycles : une valeur saturee dit « coince »,
//  une valeur moyenne dit « contention ». C'est ce qui manquait pour nommer le
//  canal responsable d'un gel sans sonde externe, et ce qui chiffre le cout
//  d'attente que subit l'accelerateur legitime pendant qu'ARMOR delibere.
// -----------------------------------------------------------------------------
localparam int unsigned N_STALL = 5;

logic [N_STALL-1:0] stall_up, stall_dn;

assign stall_up = { resp_IP_wrapper_o.r_valid    & ~req_IP_wrapper_i.r_ready,
                    req_IP_wrapper_i.ar_valid    & ~resp_IP_wrapper_o.ar_ready,
                    resp_IP_wrapper_o.b_valid    & ~req_IP_wrapper_i.b_ready,
                    req_IP_wrapper_i.w_valid     & ~resp_IP_wrapper_o.w_ready,
                    req_IP_wrapper_i.aw_valid    & ~resp_IP_wrapper_o.aw_ready };

assign stall_dn = { resp_wrapper_iommu_i.r_valid & ~req_wrapper_iommu_o.r_ready,
                    req_wrapper_iommu_o.ar_valid & ~resp_wrapper_iommu_i.ar_ready,
                    resp_wrapper_iommu_i.b_valid & ~req_wrapper_iommu_o.b_ready,
                    req_wrapper_iommu_o.w_valid  & ~resp_wrapper_iommu_i.w_ready,
                    req_wrapper_iommu_o.aw_valid & ~resp_wrapper_iommu_i.aw_ready };

logic [11:0] stall_up_cur_q [N_STALL];
logic [11:0] stall_up_max_q [N_STALL];
logic [11:0] stall_dn_cur_q [N_STALL];
logic [11:0] stall_dn_max_q [N_STALL];

//  On compare la valeur INCREMENTEE au maximum, pas la valeur courante. Avec la
//  valeur courante, une attente d'un seul cycle laissait le maximum a zero --
//  c'est-a-dire invisible, alors que c'est le cas le plus frequent. La longueur
//  d'une attente est le nombre de cycles pendant lesquels `valid & ~ready` est
//  vrai, donc le compteur doit refleter le cycle en cours.
logic [11:0] stall_up_nxt [N_STALL];
logic [11:0] stall_dn_nxt [N_STALL];

always_comb begin
    for (int unsigned i = 0; i < N_STALL; i++) begin
        stall_up_nxt[i] = (stall_up_cur_q[i] == 12'hFFF) ? 12'hFFF
                                                         : stall_up_cur_q[i] + 12'd1;
        stall_dn_nxt[i] = (stall_dn_cur_q[i] == 12'hFFF) ? 12'hFFF
                                                         : stall_dn_cur_q[i] + 12'd1;
    end
end

//  La remise a zero par CNT_CLR est SYNCHRONE et doit donc etre une branche
//  distincte du reset asynchrone : `if (!rst_ni || csr_cnt_clr)` melange les
//  deux dans la meme condition, ce qui n'est pas une forme reconnue d'inference
//  de bascule et laisse la synthese libre de traiter CNT_CLR comme un signal de
//  reset asynchrone.
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
        for (int unsigned i = 0; i < N_STALL; i++) begin
            stall_up_cur_q[i] <= 12'h0;
            stall_up_max_q[i] <= 12'h0;
            stall_dn_cur_q[i] <= 12'h0;
            stall_dn_max_q[i] <= 12'h0;
        end
    end else if (csr_cnt_clr) begin
        for (int unsigned i = 0; i < N_STALL; i++) begin
            stall_up_cur_q[i] <= 12'h0;
            stall_up_max_q[i] <= 12'h0;
            stall_dn_cur_q[i] <= 12'h0;
            stall_dn_max_q[i] <= 12'h0;
        end
    end else begin
        for (int unsigned i = 0; i < N_STALL; i++) begin
            if (stall_up[i]) begin
                stall_up_cur_q[i] <= stall_up_nxt[i];
                if (stall_up_nxt[i] > stall_up_max_q[i])
                    stall_up_max_q[i] <= stall_up_nxt[i];
            end else begin
                stall_up_cur_q[i] <= 12'h0;
            end

            if (stall_dn[i]) begin
                stall_dn_cur_q[i] <= stall_dn_nxt[i];
                if (stall_dn_nxt[i] > stall_dn_max_q[i])
                    stall_dn_max_q[i] <= stall_dn_nxt[i];
            end else begin
                stall_dn_cur_q[i] <= 12'h0;
            end
        end
    end
end

// -----------------------------------------------------------------------------
//  Mots de lecture assembles
// -----------------------------------------------------------------------------
logic [63:0] armor_dbg_state, armor_dbg_stall_up, armor_dbg_stall_dn;

//  Les etats de FSM passent par une variable de bits explicite : une assignation
//  directe d'un enum vers une tranche est legale mais son elargissement depend
//  de l'outil, et cette carte de registres est un contrat avec le logiciel.
logic [1:0]  w_state_bits;
logic        r_state_bits;
assign w_state_bits = w_state_q;   // extension implicite depuis l'enum
assign r_state_bits = r_state_q;

always_comb begin
    armor_dbg_state        = 64'h0;
    armor_dbg_state[3:0]   = w_owed_q[3:0];   // tronque : 0xE8 porte les 8 bits
    armor_dbg_state[4]     = w_pending;
    armor_dbg_state[5]     = verdict_known_q;
    armor_dbg_state[6]     = comparison_valid;
    armor_dbg_state[7]     = bad_id;
    armor_dbg_state[8]     = legit_hit;
    armor_dbg_state[9]     = legit_hit_eff;
    armor_dbg_state[10]    = verdict_known_eff;
    armor_dbg_state[12:11] = w_state_bits;   // FSM du port de config CPU
    armor_dbg_state[13]    = r_state_bits;
    armor_dbg_state[23:16] = failure_count;
    armor_dbg_state[31:24] = outs_depth;
    armor_dbg_state[39:32] = flow_req_cnt;
    armor_dbg_state[63:40] = flow_window_cnt[23:0];

    armor_dbg_stall_up        = 64'h0;
    armor_dbg_stall_up[11:0]  = stall_up_max_q[0];   // AW
    armor_dbg_stall_up[23:12] = stall_up_max_q[1];   // W
    armor_dbg_stall_up[35:24] = stall_up_max_q[2];   // B
    armor_dbg_stall_up[47:36] = stall_up_max_q[3];   // AR
    armor_dbg_stall_up[59:48] = stall_up_max_q[4];   // R

    armor_dbg_stall_dn        = 64'h0;
    armor_dbg_stall_dn[11:0]  = stall_dn_max_q[0];
    armor_dbg_stall_dn[23:12] = stall_dn_max_q[1];
    armor_dbg_stall_dn[35:24] = stall_dn_max_q[2];
    armor_dbg_stall_dn[47:36] = stall_dn_max_q[3];
    armor_dbg_stall_dn[59:48] = stall_dn_max_q[4];
end

// Multiplexeur de lecture
always_comb begin
    case (r_idx_q)
//  ARMOR_NO_OBSERVE : mesure seulement, JAMAIS un bitstream de campagne.
//
//  Les compteurs d'enquete (latences, cycles, attentes par canal, retractations,
//  episodes) n'ont qu'une destination : csr_rdata. Renvoyer zero a leur index
//  les prive de toute charge, et la synthese les elague d'elle-meme -- aucun
//  compteur n'est a toucher, et l'elagage ne peut pas emporter ce qui sert
//  encore a decider. On mesure ainsi le COUT DU MECANISME, a comparer au
//  wrapper complet pour chiffrer ce que l'instrumentation d'evaluation ajoute.
//
//  CONSERVES : la configuration et les verdicts (0x00-0x20), MAGIC, et
//  l'etendue d'adresses (0x100/0x108), qui est un mecanisme propose et non
//  une sonde.
`ifdef ARMOR_NO_OBSERVE
  `define OBS(x) 64'h0
`else
  `define OBS(x) x
`endif

        5'd0:    csr_rdata = csr_id_cfg_q;
        5'd1:    csr_rdata = csr_msi_addr_q;
        5'd2:    csr_rdata = {40'h0, csr_thresh_q,
                              3'b000, csr_rfmcnt_q, csr_irqen_q, csr_bfate_q, csr_wfate_q, csr_rhold_q, csr_wcap_q, csr_txblk_q, csr_fresh_q, csr_wskid_q,
                              csr_awfix_q, 2'b00, csr_enforce_q};
        5'd3:    csr_rdata = armor_status;
        5'd4:    csr_rdata = csr_sticky_q;
        5'd5:    csr_rdata = `OBS({56'h0, failure_count});
        5'd6:    csr_rdata = `OBS({32'h0, cnt_banned_q});
        // [31:0] verdicts STORM ; [39:32] occupation max d'une fenetre de flux ;
        // [63:40] fenetres fermees avec au moins une requete. Loge dans les bits
        // libres du compteur STORM plutot que dans un index neuf : les 32 index
        // du wrapper sont tous pris, et ces trois chiffres se lisent ensemble.
        5'd7:    csr_rdata = `OBS({cnt_winact_q, cnt_reqmax_q, cnt_storm_q});
        // [31:0] episodes de saturation ; [39:32] OUTS_MAX, plus forte profondeur
        // d'en-vol atteinte depuis CNT_CLR (seuil MAX_OUTSTANDING = 16). Meme
        // logement que REQ_MAX dans 0x38, et pour la meme raison.
        5'd8:    csr_rdata = `OBS({24'h0, cnt_outsmax_q, cnt_outs_q});
        5'd9:    csr_rdata = `OBS({32'h0, cnt_msi_q});
        5'd10:   csr_rdata = `OBS({{(64-DevIDWidth){1'b0}}, dev_id_last_q});
        5'd11:   csr_rdata = 64'h41524D4F52000011;
        // Observabilite (version 2 du MAGIC). Voir la carte des registres.
        5'd12:   csr_rdata = `OBS({52'h0, dbg_up});
        5'd13:   csr_rdata = `OBS({52'h0, dbg_dn});
        5'd14:   csr_rdata = `OBS(armor_dbg_state);
        5'd15:   csr_rdata = `OBS(armor_dbg_stall_up);
        5'd16:   csr_rdata = `OBS(armor_dbg_stall_dn);
        5'd17:   csr_rdata = `OBS({cnt_cyc_hold_q, cnt_cyc_block_q});
        5'd18:   csr_rdata = `OBS({cnt_req_dn_q,   cnt_req_up_q});
        5'd19:   csr_rdata = `OBS({lat_tx_last_q,  lat_det_last_q});
        5'd20:   csr_rdata = `OBS(lat_det_sum_q);
        5'd21:   csr_rdata = `OBS(lat_tx_sum_q);
        5'd22:   csr_rdata = `OBS({lat_n_blk_q,    lat_n_q});
        5'd23:   csr_rdata = `OBS({lat_tx_max_q, lat_tx_min_q,
                              lat_det_max_q, lat_det_min_q});
        5'd24:   csr_rdata = `OBS({30'h0, lat_evt_q, lat_busy_q, lat_cnt_q});
        5'd25:   csr_rdata = `OBS(cyc_total_q);
        // Fermeture des trois angles morts du 2026-09-10 (MAGIC ...0003).
        5'd26:   csr_rdata = `OBS({cnt_badid_cy_q,  cnt_badid_rise_q});
        5'd27:   csr_rdata = `OBS({cnt_wlast_dn_q,  cnt_aw_dn_q});
        5'd28:   csr_rdata = `OBS({cnt_w_orphan_q,  cnt_w_ghost_q});
        //  DEUX champs de 8 bits depuis v14 (ils faisaient 4 bits, et le
        //  firmware masquait en consequence : les deux ont bouge ensemble).
        5'd29:   csr_rdata = `OBS({48'h0, w_owed_max_q, w_owed_q});
        // VALID retire sans READY : violation AXI4, invisible aux compteurs de
        // handshake puisqu'aucun handshake ne s'accomplit.
        5'd30:   csr_rdata = `OBS({cnt_retr_br_q, cnt_retr_w_q,
                              cnt_retr_ar_q, cnt_retr_aw_q});
        5'd31:   csr_rdata = `OBS({23'h0, retr_seen_q, retr_first_chan_q,
                              retr_first_cause_q, retr_first_cyc_q});
        //  Etendue d'adresses (v17). ADDR_SPAN donne les bornes brutes : c'est
        //  au lecteur de faire la difference, parce qu'un min egal a 0xFFFFFFFF
        //  signale « aucune requete vue » et ne doit pas etre confondu avec une
        //  etendue nulle.
        6'd32:   csr_rdata = {addr_max_q, addr_min_q};
        6'd33:   csr_rdata = {12'h0, last_pg_q, cnt_pgchg_q};
        default: csr_rdata = 64'h0;
    endcase
end

assign armor_verdict_o = armor_status[7:3];

// Reponse AXI
always_comb begin
    resp_CPU_Wrapper_o          = '0;

    resp_CPU_Wrapper_o.aw_ready = (w_state_q == ARMOR_W_IDLE);
    resp_CPU_Wrapper_o.w_ready  = (w_state_q == ARMOR_W_DATA);
    resp_CPU_Wrapper_o.b_valid  = (w_state_q == ARMOR_W_RESP);
    resp_CPU_Wrapper_o.b.id     = aw_id_q;
    resp_CPU_Wrapper_o.b.resp   = 2'b00;   // OKAY
    resp_CPU_Wrapper_o.b.user   = '0;

    resp_CPU_Wrapper_o.ar_ready = (r_state_q == ARMOR_R_IDLE);
    resp_CPU_Wrapper_o.r_valid  = (r_state_q == ARMOR_R_DATA);
    resp_CPU_Wrapper_o.r.id     = ar_id_q;
    resp_CPU_Wrapper_o.r.data   = csr_rdata;
    resp_CPU_Wrapper_o.r.resp   = 2'b00;   // OKAY
    resp_CPU_Wrapper_o.r.last   = (r_beat_q == ar_len_q);
    resp_CPU_Wrapper_o.r.user   = '0;
end


endmodule