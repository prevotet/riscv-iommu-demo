J'ai la réponse définitive.                                                           
  
  Ce n'est pas un problème hardware physique — c'est un bug RTL dans apb_to_axilite.sv  
  qui nécessite un rebuild du bitstream FPGA.
                                                                                        
  ---             
  Bug identifié : Dans apb_to_axilite.sv, quand rvalid_i=1 (HWICAP présente la donnée)
  et pready_o=1, le code retourne prdata_o = rdata_q — la valeur enregistrée au CYCLE   
  PRÉCÉDENT. La donnée actuelle rdata_i n'est stockée dans rdata_q qu'à la prochaine 
  clock. axi2apb_64_32 échantillonne PRDATA au même cycle que PREADY=1 → il obtient     
  toujours la donnée du read précédent.                                            
                                       
  J'ai déjà appliqué le fix (ligne changée dans apb_to_axilite.sv). Effet :
  - WFV lu correctement → le write loop remplit le FIFO correctement (63 mots, pas plus)
  - CR lu correctement → le poll while(CR & CR_WRITE) attend vraiment que la state      
  machine ICAP finisse                                                                  
  - Sans le fix : rdata_q=0 (vieux WFV=0 quand FIFO plein) → CR poll sort immédiatement 
  → chunk suivant écrit avant que l'ICAP ait fini → données corrompues → DPR           
  silencieusement ignoré                                                                
                        
  Pas besoin de bswap — confirmé en tracant le chemin complet SWAP_BITS → ICAP2 : le CPU
   little-endian lit le .bin en LE, SWAP_BITS + connexion (0 to 31)→(31 downto 0)       
  compensent exactement pour donner le bon ordre d'octets à l'ICAP2 qui traite I[7:0] en
   premier.                                                                             
                  
  A  
  

  La cible dpr fait exactement ça — elle génère dans l'ordre :                  
                                                                              
  1. Le checkpoint statique (static_routed.dcp)                                 
  2. Les bitstreams full pour accel_default, accel_A, accel_B
  3. Les partiels .bit → .bin pour accel_B (RM_TARGET)                          
                                                                                
  # Premier build (tout forcer) :
  ./3_build_B2.sh dpr --force-static                                            
                                                                                
  # Si checkpoint statique déjà présent, juste régénérer les RMs :              
  ./3_build_B2.sh dpr                                                           
                                                                                
  Les variables d'environnement par défaut sont RM_INIT=accel_A et              
  RM_TARGET=accel_B, donc les fichiers produits sont