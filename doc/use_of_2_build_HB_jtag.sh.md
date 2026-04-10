2_build_HB_jtag.sh — Entrées / Sorties par cible                              
                                                                                
  Chemins de base :                                                             
  ROOT_DIR/                                                                     
  ├── build/                                                                    
  │   ├── hw/          (BUILD_CVA6_DIR)                                         
  │   ├── guests/      (BUILD_GUESTS_DIR)                                    
  │   ├── bao/         (BUILD_BAO_DIR)                                          
  │   └── firmware/    (BUILD_FIRMWARE_DIR)
  ├── cva6/corev_apu/fpga/work-dpr/2_build_HB/   (WORK_DPR — bitstreams)        
  └── opensbi/build/platform/fpga/ariane/firmware/ (FW_PAYLOAD)                 
                                                                                
  ---                                                                           
  Cibles FPGA                                                                   
                                                                                
  ┌───────────────┬──────────────────┬─────────────────────────────────────┐ 
  │     Cible     │     Entrées      │               Sorties               │    
  ├───────────────┼──────────────────┼─────────────────────────────────────┤ 
  │               │                  │ Patch ariane_soc_pkg.sv,            │ 
  │ hwicap-setup  │ Sources RTL CVA6 │ ariane_xilinx.sv,                   │ 
  │               │                  │ ariane_peripherals_xilinx.sv +      │    
  │               │                  │ xilinx/xlnx_axi_hwicap/ créé        │ 
  ├───────────────┼──────────────────┼─────────────────────────────────────┤    
  │ fpga          │ Sources RTL CVA6 │ build/hw/ariane_xilinx.bit          │    
  │               │  + armor/        │                                     │ 
  ├───────────────┼──────────────────┼─────────────────────────────────────┤    
  │ fpga-dpr      │ Sources RTL +    │ work-dpr/2_build_HB/static_routed.d │ 
  │ (static)      │ dpr/             │ cp + full_accel_default.bit         │    
  ├───────────────┼──────────────────┼─────────────────────────────────────┤ 
  │               │                  │ work-dpr/2_build_HB/full_accel_A.bi │    
  │ fpga-dpr (RM= │ static_routed.dc │ t, partial_accel_A_accel1.bit,      │ 
  │ accel_A/B)    │ p + RM sources   │ partial_accel_A_accel2.bit (idem    │    
  │               │                  │ pour B)                             │
  └───────────────┴──────────────────┴─────────────────────────────────────┘    
                                                                             
  ---
  Cibles firmware (scénario DPR baremetal — all-dpr-bm)
                                                                                
  do_dpr_full       → do_bao_dpr_bm       → do_opensbi_dpr_bm
                                                                                
  ┌─────────┬───────────────┬───────────────────────┬──────────────────────┐ 
  │  Cible  │    Source     │        Entrées        │        Sortie        │    
  ├─────────┼───────────────┼───────────────────────┼──────────────────────┤ 
  │ dpr-ful │ bao-baremetal │ dpr_test_full.c +     │ build/guests/dpr_man │
  │ l       │ -guest/ VARIA │ dpr_manager.c         │ ager.bin             │
  │         │ NT=dpr_full   │                       │                      │    
  ├─────────┼───────────────┼───────────────────────┼──────────────────────┤
  │         │ bao-hyperviso │ dpr_manager.bin +     │                      │    
  │ bao-dpr │ r/            │ vm-configs/cva6-dpr-b │ build/bao/bao-dpr-bm │    
  │ -bm     │ CONFIG=cva6-d │ aremetal/config.c     │ .bin                 │
  │         │ pr-baremetal  │                       │                      │    
  ├─────────┼───────────────┼───────────────────────┼──────────────────────┤ 
  │         │               │                       │ opensbi/build/.../fw │    
  │ opensbi │ opensbi/      │ bao-dpr-bm.bin        │ _payload.bin copié → │
  │ -dpr-bm │               │ (payload)             │  build/firmware/fw_p │    
  │         │               │                       │ ayload_dpr_bm.bin    │ 
  └─────────┴───────────────┴───────────────────────┴──────────────────────┘

  ---
  Cibles firmware (scénario DPR + Linux — all-dpr)
                                                                                
  do_dpr_manager    → do_bao_dpr_linux    → do_opensbi_dpr
                                                                                
  ┌─────────┬───────────────┬───────────────────────┬──────────────────────┐    
  │  Cible  │    Source     │        Entrées        │        Sortie        │
  ├─────────┼───────────────┼───────────────────────┼──────────────────────┤    
  │         │ bao-baremetal │                       │                      │ 
  │ dpr-man │ -guest/       │ dpr_manager.c seul    │ build/guests/dpr_man │
  │ ager    │ VARIANT=dpr_m │                       │ ager.bin             │    
  │         │ anager        │                       │                      │
  ├─────────┼───────────────┼───────────────────────┼──────────────────────┤    
  │         │ bao-hyperviso │ dpr_manager.bin +     │                      │    
  │ bao-dpr │ r/ CONFIG=cva │ image Linux +         │ build/bao/bao-dpr.bi │
  │         │ 6-dpr-linux   │ vm-configs/cva6-dpr-l │ n                    │    
  │         │               │ inux/config.c         │                      │ 
  ├─────────┼───────────────┼───────────────────────┼──────────────────────┤
  │         │               │                       │ opensbi/build/.../fw │    
  │ opensbi │ opensbi/      │ bao-dpr.bin (payload) │ _payload.bin (non    │
  │ -dpr    │               │                       │ copié, écrase le     │    
  │         │               │                       │ précédent)           │ 
  └─────────┴───────────────┴───────────────────────┴──────────────────────┘

  ---
  Cibles déploiement JTAG
                         
  Cible: program                                                             
  Entrées requises: build/hw/dpr/static_full.bit (priorité) ou ariane_xilinx.bit
  Ce qui est chargé en DDR: Programmation FPGA via Vivado JTAG               
  ────────────────────────────────────────                                      
  Cible: jtag-load                                                           
  Entrées requises: fw_payload.bin + OpenOCD actif                              
  Ce qui est chargé en DDR: 0x80000000 ← fw_payload.bin                      
  ────────────────────────────────────────                                      
  Cible: jtag-load-dpr                                                          
  Entrées requises: fw_payload.bin + 4 .bin dans WORK_DPR/ + OpenOCD actif   
  Ce qui est chargé en DDR: 0x80000000 fw + 0x81000000 A1 + 0x81300000 B1 +     
    0x81600000 A2 + 0x81B00000 B2                                               
  ────────────────────────────────────────
  Cible: jtag-load-dpr-bm                                                       
  Entrées requises: fw_payload_dpr_bm.bin + 4 .bin + OpenOCD actif           
  Ce qui est chargé en DDR: Même layout DDR que ci-dessus mais avec             
    fw_payload_dpr_bm.bin                                                    
  ────────────────────────────────────────
  Cible: jtag-dpr-bm                                                            
  Entrées requises: Idem jtag-load-dpr-bm
  Ce qui est chargé en DDR: OpenOCD lancé en bg + jtag-load-dpr-bm + OpenOCD    
    arrêté                                                                   

  ---
  Point critique : WORK_DPR dans ce script
                                                                                
  WORK_DPR="$ROOT_DIR/cva6/corev_apu/fpga/work-dpr/2_build_HB"
                                                                                
  Les cibles jtag-load-dpr et jtag-load-dpr-bm lisent les 4 .bin depuis ce      
  répertoire — c'est différent de 3_build_B2.sh qui pointe vers
  work-dpr/3_build_B_dpr/. Les deux scripts ont leurs propres dossiers de sortie
   séparés.    