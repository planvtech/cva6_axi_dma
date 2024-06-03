# cva6_axi_dma

**Table of content:**
 - [Introduction](#item-one)
 - [Key Features](#item-two)
 - [IO Ports](#item-three)
 - [Registers](#item-four)
 - [Getting Started](#item-five)
 - [Contribution](#item-six)
 - [License](#item-seven)

 <a id="item-one"></a>
## Introduction
The CVA6 AXI DMA IP, generated from [iDMA from pulp](https://github.com/pulp-platform/iDMA), is an implementation of a DMA that can be integrated with [CVA6 from OpenHWGroup](https://github.com/openhwgroup/cva6). The DMA can be used by an external microcontroller to move data between peripherals connected through an AXI bus.

 <a id="item-two"></a>
 ## Key Features

The iDMA from PULP provides different blocks to build a DMA with different features and interfaces. For more information about all the options refer to the iDMA documentation.

The CVA6 AXI DMA IP uses the following configuration:

- Frontend: descriptor-based frontend with 64 bits bus (idma_desc64_top)
- Backend: AXI read/write backend (idma_backend_rw_axi)

The frontend is responsible for providing a configuration interface for the DMA to the rest of the system. In this case the configuration interface is descriptor-based, allowing to integrate the DMA with CVA6 ready to run Linux. There is a Reg bus interface used to write the address of the first descriptor in memory and to provide feedback about the status of the DMA. The frontend also has an AXI master interface used to fetch the descriptor(s) information from the system. The frontend subsequently generates 1D requests to the backend base don the information gathered in the descriptors.

The backend is responsible for generating valid AXI transfers from the 1D requests coming from frontend, at the request interface.

 <a id="item-three"></a>
 ## IO Ports
 
| Port                      | Type                 | Direction | Description                           |
|---------------------------|----------------------|-----------|---------------------------------------|
|clk_i                      |logic                 |in         | input clock                           |
|rst_ni                     |logic                 |in         | input reset (active low)              |
|testmode_i                 |logic                 |in         | Test mode indicator                   |
|master_fe_req_o            |axi_req_t             |out        | Frontend master request used for fetching descriptors |
|master_fe_resp_i           |axi_rsp_t             |in         | Frontend master response              |
|axi_ar_id_i                |logic [AxiIdWidth-1:0]|in         | ID to be used by the read channel     |
|axi_aw_id_i                |logic [AxiIdWidth-1:0]|in         | ID to be used by the write channel    |
|slave_req_i                |reg_req_t             |in         | Reg bus interface input request       |
|slave_rsp_o                |reg_rsp_t             |out        | Reg bus interface output response     |
|master_be_req_o            |axi_req_t             |out        | Backend master request                |
|master_be_rsp_i            |axi_rsp_t             |in         | Backend master response               |
|irq_o                      |logic                 |out        | Interrupt                             |

 <a id="item-four"></a>

 ## Registers
 | Name                                  | Offset   | Length   | Description | 
|--------------------------------------|---------|---------|--------------------------------------------------------------------| 
idma_desc64.[`desc_addr`](#desc_addr)   | 0x0      | 8        | This register specifies the bus address at which the first transfer | 
idma_desc64.[`status`](#status)         | 0x8      | 8        | This register contains status information for the DMA. | 

## desc_addr 
This register specifies the bus address at which the first transfer descriptor can be found. A write to this register starts the transfer. 
- Offset: `0x0` - Reset default: `0xffffffffffffffff` - Reset mask: `0xffffffffffffffff` 

### Fields 

| Bits | Type | Reset | Name | Description | 
|------|------|------------------|----------|--------------| 
| 63:0   | wo     | 0xffffffffffffffff | desc_addr | | 

## status 
This register contains status information for the DMA. 
- Offset: `0x8` - Reset default: `0x0` - Reset mask: `0x3` 
### Fields 

| Bits | Type | Reset | Name      | Description | 
|----|----|-----|----------------|------------------------------------------------------------------------------------------------------------------------------------------------------| 
| 63:2 |      |       |           | Reserved | 
| 1    | ro   | 0x0   | fifo_full | If this bit is set, the buffers of the DMA are full. Any further submissions via the desc_addr register may overwrite previously submitted jobs or get lost. | 
| 0    | ro   | 0x0   | busy      | The DMA is busy | 

 <a id="item-five"></a>

 ## Getting Started
 To initiate a transaction, first the descriptor information needs to be written in the memory. Afterwards, the DMA is started when the address of the first descriptor is written to the desc_addr register. 
 
 The format of descriptors when using a 64 AXI bus is as follows:

| Destination Address (63:0)|
| Source Address      (63:0)|
| Next Descriptor     (63:0)|
| Length (31:0) and Flags (31:0)|

A value of 0xFFFF_FFFF_FFFF_FFFF in the Next Descriptor indicates it is the last descriptor in chain

The Length is the amount of bytes to be copied in the transaction.

Description of currently defined flags is available in the idma_desc64_top.sv file.

 <a id="item-six"></a> 

## Contributing
Contributions to this project are enthusiastically encouraged. If you encounter issues or have enhancements to propose, please initiate an issue or submit a pull request. Ensure compliance with the project's coding standards and guidelines.

<a id="item-seven"></a> 

## License
This project is licensed under the ---- License. You are free to use, modify, and distribute the code in accordance with the terms stipulated in the license.
