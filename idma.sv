// Copyright 2023 ETH Zurich and University of Bologna.
// Copyright 2024 PlanV Technology
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Angela Gonzalez, PlanV Technology

`include "../register_interface/include/register_interface/typedef.svh"
`include "../axi/include/axi/typedef.svh"
`include "idma/typedef.svh"


module idma #(
    /// Width of the addresses
    parameter int unsigned AddrWidth              = 64   ,
    /// Width of a data item on the AXI bus
    parameter int unsigned DataWidth              = 64   ,
    /// Width an AXI ID
    parameter int unsigned AxiIdWidth             = 3    ,
    /// AXI user width
    parameter int unsigned UserWidth        = 32'd1,

    /// Specifies the depth of the fifo behind the descriptor address register
    parameter int unsigned InputFifoDepth         =     8,
    /// Specifies the buffer size of the fifo that tracks requests submitted to the backend
    parameter int unsigned PendingFifoDepth       =     8,
    /// How many requests the backend might have at the same time in its buffers.
    /// Usually, `NumAxInFlight + BufferDepth`
    parameter int unsigned BackendDepth           =     0,
    /// Specifies how many descriptors may be fetched speculatively
    parameter int unsigned NSpeculation           =     4,
     /// Number of transaction that can be in-flight concurrently
    parameter int unsigned NumAxInFlight    = 32'd3,
    /// The depth of the internal reorder buffer:
    /// - '2': minimal possible configuration
    /// - '3': efficiently handle misaligned transfers (recommended)
    parameter int unsigned BufferDepth      = 32'd2,
    /// With of a transfer: max transfer size is `2**TFLenWidth` bytes
    parameter int unsigned TFLenWidth       = 32'd24,
    /// The depth of the memory system the backend is attached to
    parameter int unsigned MemSysDepth      = 32'd0,
    /// Should both data shifts be done before the dataflow element?
    /// If this is enabled, then the data inserted into the dataflow element
    /// will no longer be word aligned, but only a single shifter is needed
    parameter bit          CombinedShifter  = 1'b0,
    /// Should the `R`-`AW` coupling hardware be present? (recommended)
    parameter bit          RAWCouplingAvail = 1'b1,
    /// Mask invalid data on the manager interface
    parameter bit MaskInvalidData            = 1'b1,
    /// Should hardware legalization be present? (recommended)
    /// If not, software legalization is required to ensure the transfers are
    /// AXI4-conformal
    parameter bit HardwareLegalizer          = 1'b1,
    /// Reject zero-length transfers
    parameter bit RejectZeroTransfers        = 1'b1,
    /// Should the error handler be present?
    parameter idma_pkg::error_cap_e ErrorCap = idma_pkg::NO_ERROR_HANDLING,
    /// Print the info of the FIFO configuration
    parameter bit PrintFifoInfo              = 1'b0,
    /// Strobe Width (do not override!)
    parameter int unsigned StrbWidth    = DataWidth / 8,
    /// Offset Width (do not override!)
    parameter int unsigned OffsetWidth  = $clog2(StrbWidth),
    /// AXI4+ATOP Request and Response channel type
    parameter type axi_req_t = logic,
    parameter type axi_rsp_t = logic,
    parameter type axi_r_chan_t = logic,
    parameter type axi_w_chan_t = logic,
    parameter type axi_ar_chan_t = logic,
    parameter type axi_aw_chan_t = logic,
    /// regbus interface types. Use the REG_BUS_TYPEDEF macros to define the types
    /// or see the idma backend documentation for more details
    parameter type         reg_rsp_t              = logic,
    parameter type         reg_req_t              = logic
)(
    /// clock
    input  logic                  clk_i             ,
    /// reset
    input  logic                  rst_ni            ,
    /// Testmode in
    input  logic testmode_i,

    /// axi interface used for fetching descriptors from memory (frontend)
    /// master pair
    /// master request
    output axi_req_t              master_fe_req_o      ,
    /// master response
    input  axi_rsp_t              master_fe_rsp_i      ,
    /// ID to be used by the read channel
    input  logic [AxiIdWidth-1:0] axi_ar_id_i        ,
    /// ID to be used by the write channel
    input  logic [AxiIdWidth-1:0] axi_aw_id_i        ,
    /// regbus interface
    /// slave pair
    /// The slave interface exposes two registers: One address register to
    /// write a descriptor address to process and a status register that
    /// exposes whether the DMA is busy on bit 0 and whether FIFOs are full
    /// on bit 1.
    /// master request
    input  reg_req_t              slave_req_i       ,
    /// master response
    output reg_rsp_t              slave_rsp_o       ,

    // axi interface used for backend connection
    /// master pair
    /// master request
    output axi_req_t              master_be_req_o,
    input  axi_rsp_t              master_be_rsp_i,

    /// Event: irq
    output logic                  irq_o
);

//-----------------------//
//  TYPE DEFINITIONS     //
//-----------------------//
localparam int unsigned OneDLength       = 32;
typedef logic [AddrWidth-1:0]  addr_t;
typedef logic [DataWidth-1:0]  data_t;
typedef logic [StrbWidth-1:0]  strb_t;
typedef logic [OneDLength-1:0] length_t;
typedef logic [AxiIdWidth-1:0] id_t;
typedef logic [UserWidth-1:0]  user_t;
typedef logic [TFLenWidth-1:0] tf_len_t;


typedef struct packed {
    axi_ar_chan_t ar_chan;
} axi_read_meta_channel_t;

typedef struct packed {
    axi_read_meta_channel_t axi;
} read_meta_channel_t;

typedef struct packed {
    axi_aw_chan_t aw_chan;
} axi_write_meta_channel_t;

typedef struct packed {
    axi_write_meta_channel_t axi;
} write_meta_channel_t;

//--------------------------------------
// Connections between frontend and backend
//--------------------------------------
`IDMA_TYPEDEF_FULL_REQ_T(idma_req_t, id_t, addr_t, tf_len_t)
`IDMA_TYPEDEF_FULL_RSP_T(idma_rsp_t, addr_t)
// dma request
idma_req_t idma_req;
logic req_valid;
logic req_ready;

// dma response
idma_rsp_t idma_rsp;
logic rsp_valid;
logic rsp_ready;

// error handler
idma_pkg::idma_eh_req_t idma_eh_req;
logic eh_req_valid;
logic eh_req_ready;

// busy signal
idma_pkg::idma_busy_t busy;

 // AXI4+ATOP request and response
axi_req_t axi_read_req, axi_write_req, axi_req, axi_req_mem;
axi_rsp_t axi_read_rsp, axi_write_rsp, axi_rsp, axi_rsp_mem;


///FRONT END AXI///
idma_desc64_top #(
    .AddrWidth        ( AddrWidth        ),
    .DataWidth        ( DataWidth        ),
    .AxiIdWidth       ( AxiIdWidth       ),
    .idma_req_t       ( idma_req_t       ),
    .idma_rsp_t       ( idma_rsp_t       ),
    .axi_req_t        ( axi_req_t        ),
    .axi_rsp_t        ( axi_rsp_t        ),
    .axi_ar_chan_t    ( axi_ar_chan_t    ),
    .axi_r_chan_t     ( axi_r_chan_t     ),
    .reg_req_t        ( reg_req_t        ),
    .reg_rsp_t        ( reg_rsp_t        ),
    .InputFifoDepth   ( InputFifoDepth   ),
    .PendingFifoDepth ( PendingFifoDepth ),
    .BackendDepth     ( BackendDepth ),
    .NSpeculation     ( NSpeculation )
) i_idma_frontend (
    .clk_i            ( clk_i           ),
    .rst_ni           ( rst_ni          ),
    .master_req_o     (master_fe_req_o ),
    .master_rsp_i     (master_fe_rsp_i ),
    .axi_ar_id_i      (axi_ar_id_i      ),
    .axi_aw_id_i      (axi_aw_id_i      ),
    .slave_req_i      (slave_req_i      ),
    .slave_rsp_o      (slave_rsp_o      ),
    .idma_req_o       (idma_req         ),
    .idma_req_valid_o (req_valid        ),
    .idma_req_ready_i (req_ready        ),
    .idma_rsp_i       (idma_rsp         ),
    .idma_rsp_valid_i (rsp_valid        ),
    .idma_rsp_ready_o (rsp_ready        ),
    .idma_busy_i      (|busy            ),
    .irq_o            (irq_o            )
  );

///BACKEND AXI///

idma_backend_rw_axi #(
        .CombinedShifter      ( CombinedShifter      ),
        .DataWidth            ( DataWidth            ),
        .AddrWidth            ( AddrWidth            ),
        .AxiIdWidth           ( AxiIdWidth           ),
        .UserWidth            ( UserWidth            ),
        .TFLenWidth           ( TFLenWidth           ),
        .MaskInvalidData      ( MaskInvalidData      ),
        .BufferDepth          ( BufferDepth          ),
        .RAWCouplingAvail     ( RAWCouplingAvail     ),
        .HardwareLegalizer    ( HardwareLegalizer    ),
        .RejectZeroTransfers  ( RejectZeroTransfers  ),
        .ErrorCap             ( ErrorCap             ),
        .PrintFifoInfo        ( PrintFifoInfo        ),
        .NumAxInFlight        ( NumAxInFlight        ),
        .MemSysDepth          ( MemSysDepth          ),
        .idma_req_t           ( idma_req_t           ),
        .idma_rsp_t           ( idma_rsp_t           ),
        .idma_eh_req_t        ( idma_pkg::idma_eh_req_t),
        .idma_busy_t          ( idma_pkg::idma_busy_t),
        .axi_req_t ( axi_req_t ),
        .axi_rsp_t ( axi_rsp_t ),
        .write_meta_channel_t ( write_meta_channel_t ),
        .read_meta_channel_t  ( read_meta_channel_t  )
    ) i_idma_backend  (
        .clk_i                ( clk_i           ),
        .rst_ni               ( rst_ni          ),
        .testmode_i           ( testmode_i      ),
        .idma_req_i           ( idma_req        ),
        .req_valid_i          ( req_valid       ),
        .req_ready_o          ( req_ready       ),
        .idma_rsp_o           ( idma_rsp        ),
        .rsp_valid_o          ( rsp_valid       ),
        .rsp_ready_i          ( rsp_ready       ),
        .idma_eh_req_i        ( idma_eh_req     ),
        .eh_req_valid_i       ( eh_req_valid    ),
        .eh_req_ready_o       ( eh_req_ready    ),
        .axi_read_req_o       ( axi_read_req    ),
        .axi_read_rsp_i       ( axi_read_rsp    ),
        .axi_write_req_o      ( axi_write_req   ),
        .axi_write_rsp_i      ( axi_write_rsp   ),
        .busy_o               ( busy            )
    );

        // Read Write Join
    axi_rw_join #(
        .axi_req_t        ( axi_req_t ),
        .axi_resp_t       ( axi_rsp_t )
    ) i_axi_rw_join (
        .clk_i            ( clk_i         ),
        .rst_ni           ( rst_ni        ),
        .slv_read_req_i   ( axi_read_req  ),
        .slv_read_resp_o  ( axi_read_rsp  ),
        .slv_write_req_i  ( axi_write_req ),
        .slv_write_resp_o ( axi_write_rsp ),
        .mst_req_o        ( master_be_req_o),
        .mst_resp_i       ( master_be_rsp_i)
    );
    

endmodule