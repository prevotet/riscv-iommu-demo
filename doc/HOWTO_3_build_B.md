---                                                                                   
 Étapes 3_build_B2.sh                                                                                    
                                                                                                          
  Workflow complet (all ;défaut)                                                                          
                  
  1. dpr          → génère les bitstreams (Vivado)                                                        
  2. baremetal    → compile le firmware (baremetal-dpr/)                                                  
  3. program      → programme le FPGA via Vivado JTAG                                                     
  4. [manuel]     → lancer OpenOCD dans un terminal dédié                                                 
  5. load         → charge tout via GDB et démarre le CVA6                                                
                                                                                                          
  ---                                                                                                     
  Détail de chaque étape                                                                                  
                        
  dpr — Vivado, ~2h
  1. Génère static_routed.dcp (si absent ou FORCE_STATIC=1)                                               
  2. Génère les bitstreams pour accel_default, RM_INIT, RM_TARGET                                         
  3. Convertit les partiels .bit → .bin (strip header AA995566)                                           
  4. Vérifie la cohérence dates (partiels plus récents que le checkpoint)                                 
                                                                                                          
  baremetal — ~1 min                                                                                      
  - Compile baremetal-dpr/ → baremetal.bin + baremetal.elf                                                
                                                                                                          
  program — ~1 min
  - Programme full_<RM_INIT>.bit sur le FPGA via Vivado JTAG                                              
                                                                                                          
  openocd — terminal dédié, bloquant
  - Lance OpenOCD sur les ports telnet=4444 / gdb=3333                                                    
                                                                                                          
  load — GDB interactif
  - Vérifie qu'OpenOCD tourne                                                                             
  - Charge via GDB :         
    - partial_<RM_TARGET>_accel1.bin → 0x81000000                                                         
    - partial_<RM_TARGET>_accel2.bin → 0x81300000                                                         
    - baremetal.bin → 0x90000000                                                                          
  - Positionne $pc = 0x90000000 et continue  
 
 
 
 3_build_B2.sh — Artefacts générés                                                     
                                                                                        
  Répertoire de sortie : cva6/corev_apu/fpga/work-dpr/3_build_B_dpr/                    
                                                                                        
  1. Bitstreams FPGA (Vivado — dpr)                                                     
                                                                                        
  ┌────────────────────────────────┬───────────────┬────────────────────────────────┐   
  │            Fichier             │     Type      │          Description           │
  ├────────────────────────────────┼───────────────┼────────────────────────────────┤
  │ static_routed.dcp              │ Checkpoint    │ Design statique routé (base    │
  │                                │               │ pour tous les RMs)             │
  ├────────────────────────────────┼───────────────┼────────────────────────────────┤   
  │ static_full.bit                │ Bitstream     │ Full bitstream du design       │   
  │                                │ complet       │ statique (pblocks vides)       │   
  ├────────────────────────────────┼───────────────┼────────────────────────────────┤   
  │ full_accel_default.bit         │ Bitstream     │ Full bitstream avec RM initial │
  │                                │ complet       │  = accel_blank                 │   
  ├────────────────────────────────┼───────────────┼────────────────────────────────┤
  │ full_<RM_INIT>.bit             │ Bitstream     │ Full bitstream avec RM initial │   
  │                                │ complet       │  (défaut : accel_A)            │   
  ├────────────────────────────────┼───────────────┼────────────────────────────────┤
  │ full_<RM_TARGET>.bit           │ Bitstream     │ Full bitstream avec RM cible   │   
  │                                │ complet       │ (défaut : accel_B)             │   
  ├────────────────────────────────┼───────────────┼────────────────────────────────┤
  │ partial_<RM_TARGET>_accel1.bit │ Bitstream     │ Reconfig. zone pblock_accel1   │   
  │                                │ partiel       │ vers RM_TARGET                 │   
  ├────────────────────────────────┼───────────────┼────────────────────────────────┤
  │ partial_<RM_TARGET>_accel2.bit │ Bitstream     │ Reconfig. zone pblock_accel2   │   
  │                                │ partiel       │ vers RM_TARGET                 │   
  ├────────────────────────────────┼───────────────┼────────────────────────────────┤
  │ <RM_TARGET>_routed.dcp         │ Checkpoint    │ RM cible routé                 │   
  └────────────────────────────────┴───────────────┴────────────────────────────────┘   
   
  Pour chaque RM (accel_default, RM_INIT, RM_TARGET), les 3 bitstreams (full + 2        
  partiels) sont générés séparément.
                                                                                        
  2. Bitstreams convertis .bit → .bin (convert-bin)                                     
   
  ┌────────────────────────────────┬─────────────────────────────────────────────────┐  
  │            Fichier             │                   Description                   │
  ├────────────────────────────────┼─────────────────────────────────────────────────┤  
  │ partial_<RM_TARGET>_accel1.bin │ Header Xilinx strippé (sync word AA995566),     │
  │                                │ chargeable directement en DDR                   │
  ├────────────────────────────────┼─────────────────────────────────────────────────┤  
  │ partial_<RM_TARGET>_accel2.bin │ Idem pour pblock_accel2                         │
  └────────────────────────────────┴─────────────────────────────────────────────────┘  
                  
  Ces .bin sont chargés en DDR par GDB aux adresses 0x81000000 et 0x81300000.           
                  
  3. Firmware baremetal (baremetal)                                                     
                  
  ┌────────────────────────────────────────┬─────────────────────────────────────────┐  
  │                Fichier                 │               Description               │
  ├────────────────────────────────────────┼─────────────────────────────────────────┤
  │ baremetal-dpr/build/cva6/baremetal.bin │ Image binaire chargée par GDB à         │
  │                                        │ 0x90000000                              │
  ├────────────────────────────────────────┼─────────────────────────────────────────┤  
  │ baremetal-dpr/build/cva6/baremetal.elf │ ELF pour le débogage GDB (symboles)     │
  └────────────────────────────────────────┴─────────────────────────────────────────┘  
                  
  4. Logs de session                                                                    
                  
  ┌────────────────────────────────┬──────────────────────────────────────────┐         
  │            Fichier             │               Description                │
  ├────────────────────────────────┼──────────────────────────────────────────┤
  │ logs/<TS>_dpr_static.log       │ Log Vivado — implémentation statique     │
  ├────────────────────────────────┼──────────────────────────────────────────┤
  │ logs/<TS>_dpr_partial_<RM>.log │ Log Vivado — implémentation de chaque RM │         
  ├────────────────────────────────┼──────────────────────────────────────────┤         
  │ logs/<TS>_baremetal.log        │ Log compilation baremetal                │         
  ├────────────────────────────────┼──────────────────────────────────────────┤         
  │ logs/<TS>_program.log          │ Log programmation FPGA via JTAG          │
  ├────────────────────────────────┼──────────────────────────────────────────┤         
  │ logs/<TS>_openocd.log          │ Log OpenOCD                              │
  ├────────────────────────────────┼──────────────────────────────────────────┤         
  │ logs/summary.log               │ Résumé cumulatif de toutes les sessions  │
  └────────────────────────────────┴──────────────────────────────────────────┘         
   
  Variables d'environnement clés                                                        
                  
  ┌─────────────────┬─────────┬────────────────────────────────────────────────────┐    
  │    Variable     │ Défaut  │                       Effet                        │
  ├─────────────────┼─────────┼────────────────────────────────────────────────────┤    
  │ RM_INIT         │ accel_A │ RM chargé dans le full_*.bit programmé sur le FPGA │
  ├─────────────────┼─────────┼────────────────────────────────────────────────────┤
  │ RM_TARGET       │ accel_B │ RM des bitstreams partiels chargés en DDR          │    
  ├─────────────────┼─────────┼────────────────────────────────────────────────────┤    
  │ FORCE_STATIC    │ 0       │ 1 = refait le checkpoint même s'il existe          │    
  ├─────────────────┼─────────┼────────────────────────────────────────────────────┤    
  │ FORCE_BAREMETAL │ 0       │ 1 = recompile le firmware même s'il existe         │
  └─────────────────┴─────────┴────────────────────────────────────────────────────┘

 ACCEL1 / ACCEL2 = slots physiques (zones reconfigurables sur le FPGA)                 
  - Instance matérielle fixe dans le design statique
  - Adresse AXI fixe : 0x50000000 (ACCEL1), 0x50001000 (ACCEL2)                         
  - STREAM_ID fixe : 1 et 2                                    
  - Correspond à pblock_accel1 / pblock_accel2 dans le floorplan                        
                                                                                        
  accel_A / accel_B / accel_default = Reconfigurable Modules (RMs)                      
  - Le contenu qu'on charge dans un slot via DPR                                        
  - Un RM peut être chargé dans ACCEL1 ou ACCEL2                                        
  - La STREAM_ID est paramétrée à la synthèse du RM, pas fixée dans le RM lui-même
                                                                                        
  La relation : un slot contient un RM à un instant donné.                              
                                                                                        
  Slot        RM actuellement chargé                                                    
  ────────    ──────────────────────                                                    
  ACCEL1  →   accel_A   (ID: 0xDEAD_000001_AAAAAA)
  ACCEL2  →   accel_B   (ID: 0xDEAD_000002_BBBBBB)                                      
                                                                                        
  Après DPR sur ACCEL1 :                                                                
  ACCEL1  →   accel_B   (ID: 0xDEAD_000001_BBBBBB)                                      
  ACCEL2  →   accel_B   (ID: 0xDEAD_000002_BBBBBB)
                                                                                        
  C'est pourquoi partial_accel_B_accel1.bit et partial_accel_B_accel2.bit sont deux
  bitstreams distincts pour le même RM accel_B : même logique, mais synthétisée avec une
   STREAM_ID différente selon le slot cible.
 