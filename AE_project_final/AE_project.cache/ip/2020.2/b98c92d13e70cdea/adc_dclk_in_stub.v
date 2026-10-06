// Copyright 1986-2020 Xilinx, Inc. All Rights Reserved.
// --------------------------------------------------------------------------------
// Tool Version: Vivado v.2020.2 (win64) Build 3064766 Wed Nov 18 09:12:45 MST 2020
// Date        : Wed May 13 13:42:29 2026
// Host        : Adam running 64-bit major release  (build 9200)
// Command     : write_verilog -force -mode synth_stub -rename_top decalper_eb_ot_sdeen_pot_pi_dehcac_xnilix -prefix
//               decalper_eb_ot_sdeen_pot_pi_dehcac_xnilix_ adc_dclk_in_stub.v
// Design      : adc_dclk_in
// Purpose     : Stub declaration of top-level module interface
// Device      : xc7a200tfbg484-2
// --------------------------------------------------------------------------------

// This empty module with port declaration file causes synthesis tools to infer a black box for IP.
// The synthesis directives are for Synopsys Synplify support to prevent IO buffer insertion.
// Please paste the declaration into a Verilog source file or add the file as an additional source.
module decalper_eb_ot_sdeen_pot_pi_dehcac_xnilix(adc_dclk_in, adc_divclk, clk_in1_p, clk_in1_n)
/* synthesis syn_black_box black_box_pad_pin="adc_dclk_in,adc_divclk,clk_in1_p,clk_in1_n" */;
  output adc_dclk_in;
  output adc_divclk;
  input clk_in1_p;
  input clk_in1_n;
endmodule
