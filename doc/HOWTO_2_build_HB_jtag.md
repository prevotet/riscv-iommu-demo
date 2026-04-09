2_build_HB_jtag.sh — Artefacts générés                                                
                                                                                        
  Scénario : VM baremetal unique sous BAO — DPR Manager + test ping-pong accel_A ↔      
  accel_B fusionnés en une seule VM (VARIANT=dpr_full).                                 
                                                                                        
  ---                                                                                   
  1. Firmware (all-dpr-bm)
                                                                                        
  Chaîne de build : dpr_manager.bin → bao-dpr-bm.bin → fw_payload_dpr_bm.bin
                                                                                        
  ┌──────────────────────────────────────┬───────────────────────────────────────────┐
  │               Fichier                │                Description                │  
  ├──────────────────────────────────────┼───────────────────────────────────────────┤
  │                                      │ Guest baremetal compilé                   │
  │ build/guests/dpr_manager.bin         │ (VARIANT=dpr_full) — DPR Manager + test   │
  │                                      │ ping-pong fusionnés                       │  
  ├──────────────────────────────────────┼───────────────────────────────────────────┤
  │ build/bao/bao-dpr-bm.bin             │ Image BAO avec config cva6-dpr-baremetal  │  
  │                                      │ (VM baremetal unique)                     │
  ├──────────────────────────────────────┼───────────────────────────────────────────┤  
  │ build/firmware/fw_payload_dpr_bm.bin │ Image finale — OpenSBI + BAO + VM DPR,    │  
  │                                      │ chargée à 0x80000000                      │
  └──────────────────────────────────────┴───────────────────────────────────────────┘  
                  
  ---
  2. Bitstreams FPGA (fpga-dpr)
                                                                                        
  Répertoire de travail : cva6/corev_apu/fpga/work-dpr/2_build_HB/
                                                                                        
  ┌─────────────────┬────────────────────────────────────────────────────────────────┐  
  │  DPR_MODE / RM  │                        Fichiers générés                        │  
  ├─────────────────┼────────────────────────────────────────────────────────────────┤  
  │ DPR_MODE=static │ static_routed.dcp, static_full.bit                             │
  ├─────────────────┼────────────────────────────────────────────────────────────────┤
  │ RM=accel_A      │ full_accel_A.bit, partial_accel_A_accel1.bit/.bin,             │  
  │                 │ partial_accel_A_accel2.bit/.bin                                │  
  ├─────────────────┼────────────────────────────────────────────────────────────────┤  
  │ RM=accel_B      │ full_accel_B.bit, partial_accel_B_accel1.bit/.bin,             │  
  │                 │ partial_accel_B_accel2.bin                                     │  
  └─────────────────┴────────────────────────────────────────────────────────────────┘
                                                                                        
  Tous les .bit sont aussi copiés dans build/hw/dpr/.                                   
  
  ---                                                                                   
  3. Layout DDR après jtag-load-dpr-bm / jtag-dpr-bm
                                                                                        
  ┌─────────────┬────────────────────────────┬────────────────────────────────┐
  │ Adresse DDR │       Fichier chargé       │           Taille max           │         
  ├─────────────┼────────────────────────────┼────────────────────────────────┤
  │ 0x80000000  │ fw_payload_dpr_bm.bin      │ —                              │         
  ├─────────────┼────────────────────────────┼────────────────────────────────┤
  │ 0x81000000  │ partial_accel_A_accel1.bin │ 3 Mo (slot jusqu'à 0x81300000) │
  ├─────────────┼────────────────────────────┼────────────────────────────────┤         
  │ 0x81300000  │ partial_accel_B_accel1.bin │ 3 Mo (slot jusqu'à 0x81600000) │
  ├─────────────┼────────────────────────────┼────────────────────────────────┤         
  │ 0x81600000  │ partial_accel_A_accel2.bin │ 5 Mo (slot jusqu'à 0x81B00000) │
  ├─────────────┼────────────────────────────┼────────────────────────────────┤         
  │ 0x81B00000  │ partial_accel_B_accel2.bin │ 5 Mo                           │
  └─────────────┴────────────────────────────┴────────────────────────────────┘         
  
  Les 4 bitstreams sont pré-chargés en DDR pour que le firmware puisse faire le         
  ping-pong accel_A ↔ accel_B sur les deux slots sans passer par JTAG.
                                                                                        
  ---             
  4. Logs temporaires (déploiement)
                                                                                        
  ┌──────────────────────────────┬───────────────────────────────────────────────────┐
  │           Fichier            │                    Description                    │  
  ├──────────────────────────────┼───────────────────────────────────────────────────┤
  │ /tmp/openocd_bg.log          │ Log OpenOCD en mode background (jtag-dpr-bm)      │
  ├──────────────────────────────┼───────────────────────────────────────────────────┤
  │ /tmp/jtag_dpr_bm_XXXXXX.gdb  │ Script GDB généré à la volée (supprimé après      │  
  │                              │ exécution)                                        │  
  ├──────────────────────────────┼───────────────────────────────────────────────────┤  
  │ /tmp/program_fpga_XXXXXX.tcl │ Script Vivado JTAG généré à la volée (supprimé    │  
  │                              │ après exécution)                                  │  
  ├──────────────────────────────┼───────────────────────────────────────────────────┤
  │ dpr/dpr_build.log            │ Log de la synthèse Vivado (fpga-dpr)              │  
  └──────────────────────────────┴───────────────────────────────────────────────────┘  
  
  ---                                                                                   
  Différences clés vs 3_build_B2.sh
                                                                                        
  ┌─────────────┬────────────────────────────────────┬──────────────────────────────┐
  │             │         2_build_HB_jtag.sh         │        3_build_B2.sh         │   
  ├─────────────┼────────────────────────────────────┼──────────────────────────────┤
  │             │ VARIANT=dpr_full (DPR Manager +    │ Baremetal standalone sans    │
  │ Guest       │ test fusionné) sous BAO            │ BAO (baremetal-dpr/)         │
  │             │ (cva6-dpr-baremetal)               │                              │   
  ├─────────────┼────────────────────────────────────┼──────────────────────────────┤
  │ Bitstreams  │ 4 bitstreams (A+B × accel1+accel2) │ 2 bitstreams (RM_TARGET ×    │   
  │ DDR         │  — ping-pong complet               │ accel1+accel2) —             │
  │             │                                    │ reconfiguration simple       │   
  ├─────────────┼────────────────────────────────────┼──────────────────────────────┤
  │ Démarrage   │ GDB non-interactif (-batch), CVA6  │ GDB interactif, pc mis       │
  │             │ démarre automatiquement            │ manuellement                 │   
  ├─────────────┼────────────────────────────────────┼──────────────────────────────┤
  │ OpenOCD     │ Lancé en background                │ Terminal dédié obligatoire   │   
  │             │ automatiquement (jtag-dpr-bm)      │                              │   
  ├─────────────┼────────────────────────────────────┼──────────────────────────────┤
  │ Config BAO  │ cva6-dpr-baremetal (1 VM)          │ Sans BAO                     │   
  └─────────────┴────────────────────────────────────┴──────────────────────────────┘

  Variables d'environnement clés

  ┌──────────────┬─────────────────────┬───────────────────────────────────────────┐
  │   Variable   │       Défaut        │                   Effet                   │
  ├──────────────┼─────────────────────┼───────────────────────────────────────────┤
  │ DPR_MODE     │ —                   │ static / all / clean / (absent = partial) │
  ├──────────────┼─────────────────────┼───────────────────────────────────────────┤
  │ RM           │ accel_default       │ RM à implémenter en mode partial          │    
  ├──────────────┼─────────────────────┼───────────────────────────────────────────┤    
  │ FORCE_FPGA   │ 0                   │ 1 = force rebuild checkpoint statique     │    
  ├──────────────┼─────────────────────┼───────────────────────────────────────────┤    
  │ OPENOCD_PORT │ 3333                │ Port GDB/JTAG                             │
  ├──────────────┼─────────────────────┼───────────────────────────────────────────┤    
  │ GDB          │ ${CROSS_COMPILE}gdb │ Chemin vers GDB RISC-V                    │
  └──────────────┴─────────────────────┴───────────────────────────────────────────┘  