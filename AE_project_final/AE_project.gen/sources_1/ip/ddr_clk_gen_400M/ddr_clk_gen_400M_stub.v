// Copyright 1986-2020 Xilinx, Inc. All Rights Reserved.
// --------------------------------------------------------------------------------
// Tool Version: Vivado v.2020.2 (win64) Build 3064766 Wed Nov 18 09:12:45 MST 2020
// Date        : Fri May 15 15:35:53 2026
// Host        : Adam running 64-bit major release  (build 9200)
// Command     : write_verilog -force -mode synth_stub
//               e:/AE_project/FPGA/AE_project/AE_project.gen/sources_1/ip/ddr_clk_gen_400M/ddr_clk_gen_400M_stub.v
// Design      : ddr_clk_gen_400M
// Purpose     : Stub declaration of top-level module interface
// Device      : xc7a200tfbg484-2
// --------------------------------------------------------------------------------

// This empty module with port declaration file causes synthesis tools to infer a black box for IP.
// The synthesis directives are for Synopsys Synplify support to prevent IO buffer insertion.
// Please paste the declaration into a Verilog source file or add the file as an additional source.
module ddr_clk_gen_400M(ae_ddr_clk, reset, locked, sys_clk_200M)
/* synthesis syn_black_box black_box_pad_pin="ae_ddr_clk,reset,locked,sys_clk_200M" */;
  output ae_ddr_clk;
  input reset;
  output locked;
  input sys_clk_200M;
endmodule
