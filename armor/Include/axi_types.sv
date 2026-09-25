
package axi_types;

  localparam int IdWidth      = 4;
  localparam int IdWidthSlv   = 6;
  localparam int AddrWidth    = 64;
  localparam int UserWidth    = 1;
  localparam int DevIDWidth   = 24;
  localparam int ProcIDWidth  = 20;
  localparam int DataWidth    = 64;
  localparam int StrbWidth    = DataWidth / 8;

  typedef struct packed {
    logic [IdWidth-1:0]             id;
    logic [AddrWidth-1:0]           addr;
    logic [7:0]                     len;
    logic [2:0]                     size;
    logic [1:0]                     burst;
    logic                           lock;
    logic [3:0]                     cache;
    logic [2:0]                     prot;
    logic [3:0]                     qos;
    logic [3:0]                     region;
    logic [5:0]                     atop;
    logic [UserWidth-1:0]           user;

}aw_chan_t;

typedef struct packed {
    logic [IdWidthSlv-1:0]             id;
    logic [AddrWidth-1:0]           addr;
    logic [7:0]                     len;
    logic [2:0]                     size;
    logic [1:0]                     burst;
    logic                           lock;
    logic [3:0]                     cache;
    logic [2:0]                     prot;
    logic [3:0]                     qos;
    logic [3:0]                     region;
    logic [5:0]                     atop;
    logic [UserWidth-1:0]           user;

}aw_chan_slv_t;


typedef struct packed {
    logic [IdWidth-1:0]             id;
    logic [AddrWidth-1:0]           addr;
    logic [7:0]                     len;
    logic [2:0]                     size;
    logic [1:0]                     burst;
    logic                           lock;
    logic [3:0]                     cache;
    logic [2:0]                     prot;
    logic [3:0]                     qos;
    logic [3:0]                     region;
    logic [5:0]                     atop;
    logic [UserWidth-1:0]           user;
    logic [DevIDWidth-1:0]          aw_stream_id_o;
    logic [ProcIDWidth-1:0]         aw_substream_id_o;
    logic                           aw_ss_id_valid_o;


}aw_chan_extended_t;


typedef struct packed {
    logic [IdWidth-1:0]             ar_id;
    logic [AddrWidth-1:0]           ar_addr;
    logic [7:0]                     ar_len;
    logic [2:0]                     ar_size;
    logic [1:0]                     ar_burst;
    logic                           ar_lock;
    logic [3:0]                     ar_cache;
    logic [2:0]                     ar_prot;
    logic [3:0]                     ar_qos;
    logic [3:0]                     ar_region;
    logic [5:0]                     ar_atop;
    logic [UserWidth-1:0]           ar_user;



}ar_chan_t ;


typedef struct packed {
    logic [IdWidthSlv-1:0]             ar_id;
    logic [AddrWidth-1:0]           ar_addr;
    logic [7:0]                     ar_len;
    logic [2:0]                     ar_size;
    logic [1:0]                     ar_burst;
    logic                           ar_lock;
    logic [3:0]                     ar_cache;
    logic [2:0]                     ar_prot;
    logic [3:0]                     ar_qos;
    logic [3:0]                     ar_region;
    logic [5:0]                     ar_atop;
    logic [UserWidth-1:0]           ar_user;



}ar_chan_slv_t ;

typedef struct packed {
    logic [IdWidth-1:0]             ar_id;
    logic [AddrWidth-1:0]           ar_addr;
    logic [7:0]                     ar_len;
    logic [2:0]                     ar_size;
    logic [1:0]                     ar_burst;
    logic                           ar_lock;
    logic [3:0]                     ar_cache;
    logic [2:0]                     ar_prot;
    logic [3:0]                     ar_qos;
    logic [3:0]                     ar_region;
    logic [5:0]                     ar_atop;
    logic [UserWidth-1:0]           ar_user;
    logic [DevIDWidth-1:0]          ar_stream_id;
    logic [ProcIDWidth-1:0]         ar_substream_id;
    logic                           ar_ss_id_valid;


}ar_chan_extended_t ;

typedef struct packed {
    logic [DataWidth-1:0]     w_data;
    logic [StrbWidth-1:0]     w_strb;
    logic                     w_last;
    logic [UserWidth-1:0]     w_user;
    
}w_chan_t;

typedef struct packed {

    logic [IdWidth-1:0]       b_id;
    logic [1:0]               b_resp;
    logic [UserWidth-1:0]     b_user;

}b_chan_t;


typedef struct packed {

    logic [IdWidthSlv-1:0]       b_id;
    logic [1:0]               b_resp;
    logic [UserWidth-1:0]     b_user;

}b_chan_slv_t;


typedef struct packed {
    logic [IdWidth-1:0]             r_id;
    logic [1:0]                     r_resp;
    logic [DataWidth-1:0]           r_data;
    logic                           r_last;
    logic [UserWidth-1:0]           r_user;

}r_chan_t;

typedef struct packed {
    logic [IdWidthSlv-1:0]             r_id;
    logic [1:0]                     r_resp;
    logic [DataWidth-1:0]           r_data;
    logic                           r_last;
    logic [UserWidth-1:0]           r_user;

}r_chan_slv_t;



typedef struct packed{


    aw_chan_t              aw;
    logic                           aw_valid;
    w_chan_t                        w;
    logic                           w_valid;
    logic                           b_ready;
    ar_chan_t              ar;
    logic                           ar_valid;
    logic                           r_ready;


}req_t;

typedef struct packed {
    aw_chan_slv_t              aw;
    logic                           aw_valid;
    w_chan_t                        w;
    logic                           w_valid;
    logic                           b_ready;
    ar_chan_slv_t              ar;
    logic                           ar_valid;
    logic                           r_ready;


}req_slv_t;

typedef struct packed {

    logic                           aw_ready;
    logic                           ar_ready;
    logic                           w_ready;
    logic                           b_valid;
    b_chan_t                        b;
    logic                           r_valid;
    r_chan_t                        r;


}resp_t;

typedef struct packed {

    logic                           aw_ready;
    logic                           ar_ready;
    logic                           w_ready;
    logic                           b_valid;
    b_chan_slv_t                        b;
    logic                           r_valid;
    r_chan_slv_t                        r;


}resp_slv_t;



typedef struct packed {

    aw_chan_extended_t              aw;
    logic                           aw_valid;
    w_chan_t                        w;
    logic                           w_valid;
    logic                           b_ready;
    ar_chan_extended_t              ar;
    logic                           ar_valid;
    logic                           r_ready;


}req_iommu_t;

endpackage