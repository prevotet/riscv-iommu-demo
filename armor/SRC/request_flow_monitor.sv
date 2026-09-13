module request_flow_monitor #(
    parameter WINDOW_CYCLES = 1024,
    parameter MAX_REQ_PER_WINDOW = 64,
    parameter BLOCK_CYCLES = 20,
    parameter type req_iommu_t = logic,
    parameter type resp_slv_t = logic

)(
    input  logic        clk_i,
    input  logic        rst_ni,

    // Incoming request 
    input req_iommu_t   req_IP_wrapper_i,
    input resp_slv_t    resp_wrapper_iommu_i,

    // Garde de legitimite. Quand un device_id est banni, request_manager masque
    // aw/ar vers l'IOMMU. Mais l'IP continue d'asserter aw_valid/ar_valid et
    // l'IOMMU, au repos, maintient aw_ready/ar_ready hauts : le handshake brut
    // est alors vrai a chaque cycle alors qu'aucune requete ne circule. Le
    // compteur d'outstanding, qui reutilise req_fire, explose en 16 cycles et
    // declenche un faux OUTS sur chaque tentative de spoof. On exige donc
    // legit_hit_i pour ne compter que les requetes reellement emises.
    input  logic        legit_hit_i,

    // =========================================================================
    //  Comptage par TRANSFERT plutot que par front (CTRL[12], v14).
    //
    //  dn_aw_hs_i / dn_ar_hs_i sont les handshakes REELS en aval, apres la
    //  coupure de request_manager : `req_wrapper_iommu_o.aw_valid &
    //  resp_wrapper_iommu_i.aw_ready`. Un cycle ou les deux sont hauts EST un
    //  transfert d'adresse AXI, il n'y en a pas d'autre definition.
    //
    //  Pourquoi ne pas simplement compter `aw_handshake` par cycle : ce signal
    //  croise le VALID du maitre en AMONT avec le READY de l'aval, deux bus
    //  differents. Pendant un blocage, request_manager coupe aw_valid en aval
    //  mais le maitre tient le sien et l'IOMMU au repos tient son ready : le
    //  produit est vrai a chaque cycle alors que rien ne circule. C'est le meme
    //  piege que celui qui a impose legit_hit_i ci-dessus, et c'est ce qui avait
    //  fait compter 1 024 012 evenements MSI pour 1 000 transactions.
    //
    //  Le front montant evite ce piege mais en paie un autre : deux adresses
    //  transferees sur deux cycles consecutifs ne font qu'un front, donc une
    //  seule requete comptee. Le generateur de accel_wrap ne le fait jamais (sa
    //  FSM repasse par G_W entre deux AW, aw_valid retombe), mais tout maitre
    //  qui pipeline ses adresses -- c'est-a-dire toute tempete realiste --
    //  serait sous-compte exactement dans le regime qu'on veut detecter.
    //
    //  A 0, comportement historique (front montant) : le meme bitstream donne
    //  les deux comptages et l'A/B se fait sans resynthese.
    // =========================================================================
    input  logic        dn_aw_hs_i,
    input  logic        dn_ar_hs_i,
    input  logic        cnt_fix_i,

    // =========================================================================
    //  SEUIL REGLABLE A L'EXECUTION (CTRL[23:16], v15).
    //
    //  MAX_REQ_PER_WINDOW reste le seuil de synthese ; max_req_i le remplace
    //  quand il est non nul. ZERO SIGNIFIE « VALEUR DE SYNTHESE » : c'est ce qui
    //  rend le bit retrocompatible sans un mot de firmware a changer -- une
    //  image qui ecrit CTRL sans ce champ ecrit zero, donc garde 8.
    //
    //  Pourquoi ce reglage existe. Sur carte, le 2026-09-13 : trafic legitime
    //  pilote par logiciel et low-and-slow a UNE requete par fenetre, DMA
    //  legitime saturant a 4 au pic sur 5,4 millions de fenetres, tempete a 10
    //  au pic pour une moyenne de 4,9 -- le tout contre un seuil de 8. La
    //  question « ou placer le seuil » est donc une question a mesurer, et la
    //  mesurer demandait jusqu'ici une synthese par valeur, soit 45 minutes par
    //  point de courbe.
    // =========================================================================
    input  logic [7:0]  max_req_i,

    // Outputs
    output logic        storm_flag,
    output logic        block_req,
    output logic        req_fire,       // signal injected in proceeding modules

    // Observabilite pure : nombre de requetes comptees dans la fenetre courante
    // et position dans la fenetre. Le seuil se lit alors comme une marge et non
    // comme un booleen -- necessaire pour savoir de combien SC08 passe sous le
    // seuil, et pour objecter que MAX_REQ_PER_WINDOW est mal calibre en DEMO.
    output logic [7:0]  req_cnt_o,
    output logic [31:0] window_cnt_o
);
    // =========================================================================
    //  Comptage : UN front montant de handshake = UNE requete.
    //
    //  La version precedente comptait « handshake ET (premiere requete OU
    //  changement d'ID) », avec aw_id_prev/ar_id_prev declares sur 1 bit alors
    //  que aw.id/ar.id en font plusieurs. La sauvegarde tronquait donc l'ID au
    //  bit 0 et la comparaison etait quasi toujours vraie : req_fire montait a
    //  chaque cycle de handshake, le seuil etait franchi par une seule lecture
    //  legitime et tout le trafic sain etait marque storm.
    //
    //  Le comptage par identifiant est de toute facon inadapte a ces
    //  scenarios : l'attaque storm emet ses ecritures avec un id constant (la
    //  boucle RESP -> ADDR de l'accelerateur ne repasse pas par IDLE), donc un
    //  comptage par-ID ne verrait qu'une requete et manquerait l'attaque ; et
    //  la detection d'outstanding repose sur plusieurs requetes vues sur un
    //  ar_valid maintenu, qu'un comptage par-ID sous-compterait.
    //
    //  Le front montant du handshake compte une fois par transfert AXI reel,
    //  independamment de l'ID : le storm mono-ID reste detecte et une lecture
    //  legitime ne compte qu'une fois.
    //
    //  NUANCE (v14) : « une fois par transfert » n'est vrai que d'un maitre qui
    //  relache son VALID entre deux adresses, ce que fait le generateur de
    //  accel_wrap. Deux adresses transferees sur deux cycles consecutifs ne font
    //  qu'un front et ne comptent que pour une. cnt_fix_i compte alors les
    //  transferts reels en aval ; voir le commentaire de ses ports.
    //
    //  req_fire garde dans les deux cas sa definition historique : il alimente
    //  outs_req_monitor, qui l'apparie a resp_complete pour tenir sa profondeur
    //  d'en-vol. Changer son pas changerait le seuil d'outstanding, qui n'est
    //  pas le sujet ici -- et SC03 detecte 50/50 avec la definition actuelle.
    // =========================================================================
    logic aw_prev,      ar_prev;
    logic aw_edge,      ar_edge;
    logic aw_handshake, ar_handshake;

    assign aw_handshake = req_IP_wrapper_i.aw_valid && resp_wrapper_iommu_i.aw_ready && legit_hit_i;
    assign ar_handshake = req_IP_wrapper_i.ar_valid && resp_wrapper_iommu_i.ar_ready && legit_hit_i;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            aw_prev <= 1'b0;
            ar_prev <= 1'b0;
        end else begin
            aw_prev <= aw_handshake;
            ar_prev <= ar_handshake;
        end
    end

    assign aw_edge  = aw_handshake & ~aw_prev;
    assign ar_edge  = ar_handshake & ~ar_prev;
    assign req_fire = aw_edge | ar_edge;


    logic [$clog2(WINDOW_CYCLES):0] window_cnt;

    // =========================================================================
    //  LARGEUR DU COMPTEUR DE FENETRE : 8 BITS SATURANTS (correctif v14).
    //
    //  Il faisait `$clog2(MAX_REQ_PER_WINDOW)+1` bits, soit QUATRE bits pour un
    //  seuil de 8 : il comptait 0 a 15 puis REPASSAIT A 0 en pleine fenetre.
    //  storm_flag, qui n'est qu'une comparaison sur ce compteur, retombait alors
    //  au milieu d'une tempete et le blocage se relachait -- silencieusement,
    //  aucun compteur ne le disait.
    //
    //  Le scenario SC02 emet STORM_REQS = 16 requetes par salve : il est pile
    //  sur le point de rebouclage. Toute salve dont 16 requetes tombent dans la
    //  meme fenetre y passait, et le bras ENFORCE=0 -- ou rien n'est coupe,
    //  donc ou les 16 sont comptees a coup sur -- le traverse par construction.
    //
    //  Un compteur d'observation n'a aucune raison de reboucler : 8 bits (la
    //  largeur de req_cnt_o, donc gratuits en sortie) et une SATURATION a 255.
    //  Saturer plutot que s'arreter au seuil garde la marge lisible : c'est ce
    //  qui permet de dire de combien une salve depasse, et non seulement
    //  qu'elle depasse.
    // =========================================================================
    localparam logic [7:0] REQ_CNT_MAX = 8'hFF;

    logic [7:0] req_cnt;
    logic [1:0] req_inc;
    logic [7:0] req_cnt_next;

    // Sliding window counter
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if(!rst_ni) begin
            window_cnt <= 0;
        end else if(window_cnt == WINDOW_CYCLES-1) begin
            window_cnt <= 0;
        end else begin
            window_cnt <= window_cnt + 1;
        end
    end

    // Count requests in the window
    //
    //  cnt_fix_i = 0 : un front montant de handshake (historique), au plus une
    //                  requete comptee par cycle.
    //  cnt_fix_i = 1 : un transfert d'adresse reellement accompli en aval, AW et
    //                  AR pouvant tomber dans le MEME cycle -- d'ou un pas de 2.
    //                  Les requetes coupees par request_manager ne sont alors
    //                  plus comptees du tout, ce qui est correct : elles n'ont
    //                  pas circule. Le compteur de coupures (cnt_req_cut) les
    //                  chiffre deja separement cote wrapper.
    assign req_inc = cnt_fix_i ? ({1'b0, dn_aw_hs_i} + {1'b0, dn_ar_hs_i})
                               : {1'b0, req_fire};

    always_comb begin
        // Saturation : ne jamais reboucler, quitte a perdre la valeur exacte
        // au-dela de 255.
        if ({1'b0, req_cnt} + {7'h0, req_inc} > {1'b0, REQ_CNT_MAX})
            req_cnt_next = REQ_CNT_MAX;
        else
            req_cnt_next = req_cnt + {6'h0, req_inc};
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if(!rst_ni) begin
            req_cnt <= 8'h0;
        end else if(window_cnt == WINDOW_CYCLES-1) begin
            req_cnt <= 8'h0; // new window
        end else if(req_inc != 2'd0) begin
            req_cnt <= req_cnt_next;
        end
    end

    //  Seuil effectif : le registre s'il est arme, la valeur de synthese sinon.
    logic [7:0] max_req_eff;
    assign max_req_eff = (max_req_i == 8'h0) ? 8'(MAX_REQ_PER_WINDOW) : max_req_i;

    assign storm_flag = (req_cnt >= max_req_eff);

    // window_cnt fait 8 bits en profil BENCH et 17 en DEMO -- 32 bits couvrent
    // les deux. req_cnt fait desormais exactement la largeur de sa sortie.
    assign req_cnt_o    = req_cnt;
    assign window_cnt_o = window_cnt;
    
    
    // Blocage temporaire

    logic [$clog2(BLOCK_CYCLES):0] block_cnt;
    logic blocking;

    // =========================================================================
    //  BLOCAGE SANS HACHAGE (correctif du 2026-09-09).
    //
    //  La version precedente redemarrait le blocage sur `storm_flag && !blocking`
    //  et le relachait des que block_cnt atteignait BLOCK_CYCLES-1. Or storm_flag
    //  est un NIVEAU : req_cnt ne retombe qu'a la fin de la fenetre glissante
    //  (window_cnt == WINDOW_CYCLES-1). Une fois le seuil franchi, le signal
    //  restait donc haut pendant tout le reste de la fenetre et `blocking`
    //  oscillait : BLOCK_CYCLES cycles hauts, un cycle bas, en boucle.
    //
    //  En profil DEMO ca ne se voyait pas -- BLOCK_CYCLES vaut 750_000_000, le
    //  blocage couvre tout. En profil BENCH il vaut 4, et le banc a mesure
    //  55 fronts sur un seul scenario SC02. Ce hachage est ce qui gelait la
    //  carte : dans le creux d'un cycle, request_manager ne coupe plus rien,
    //  l'accelerateur repousse son beat W, et l'aval l'avale -- alors que l'AW,
    //  lui, doit traverser la traduction IOMMU et n'a pas le temps d'etre admis.
    //  Le canal W repart decale d'un beat, definitivement.
    //
    //  Un signal de blocage n'a aucune raison de clignoter. On le tient donc haut
    //  tant que la menace est presente, plus BLOCK_CYCLES de queue une fois
    //  qu'elle a disparu. Le comportement DEMO est inchange (storm_flag y est
    //  couvert par une temporisation bien plus longue de toute facon).
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if(!rst_ni) begin
            block_cnt <= 0;
            blocking  <= 1'b0;
        end else begin
            if(storm_flag) begin
                blocking  <= 1'b1;  // menace presente : on tient, sans relacher
                block_cnt <= 0;
            end else if(blocking) begin
                if(block_cnt == BLOCK_CYCLES-1) begin
                    blocking  <= 1'b0; // queue ecoulee, fin du blocage
                    block_cnt <= 0;
                end else begin
                    block_cnt <= block_cnt + 1;
                end
            end
        end
    end

    assign block_req = blocking;

endmodule
