// Copyright 1986-2020 Xilinx, Inc. All Rights Reserved.
// --------------------------------------------------------------------------------
// Tool Version: Vivado v.2020.2 (win64) Build 3064766 Wed Nov 18 09:12:45 MST 2020
// Date        : Sun May 17 17:34:20 2026
// Host        : Adam running 64-bit major release  (build 9200)
// Command     : write_verilog -force -mode synth_stub
//               e:/AE_project/FPGA/AE_project/AE_project.gen/sources_1/ip/ILA_DATA_DOWNSAMPLE/ILA_DATA_DOWNSAMPLE_stub.v
// Design      : ILA_DATA_DOWNSAMPLE
// Purpose     : Stub declaration of top-level module interface
// Device      : xc7a200tfbg484-2
// --------------------------------------------------------------------------------

// This empty module with port declaration file causes synthesis tools to infer a black box for IP.
// The synthesis directives are for Synopsys Synplify support to prevent IO buffer insertion.
// Please paste the declaration into a Verilog source file or add the file as an additional source.
(* X_CORE_INFO = "ila,Vivado 2020.2" *)
module ILA_DATA_DOWNSAMPLE(clk, probe0, probe1, probe2, probe3, probe4, probe5, 
  probe6, probe7, probe8)
/* synthesis syn_black_box black_box_pad_pin="clk,probe0[0:0],probe1[0:0],probe2[15:0],probe3[0:0],probe4[255:0],probe5[255:0],probe6[0:0],probe7[255:0],probe8[255:0]" */;
  input clk;
  input [0:0]probe0;
  input [0:0]probe1;
  input [15:0]probe2;
  input [0:0]probe3;
  input [255:0]probe4;
  input [255:0]probe5;
  input [0:0]probe6;
  input [255:0]probe7;
  input [255:0]probe8;
endmodule
