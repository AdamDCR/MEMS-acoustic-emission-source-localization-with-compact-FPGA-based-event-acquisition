-- Copyright 1986-2020 Xilinx, Inc. All Rights Reserved.
-- --------------------------------------------------------------------------------
-- Tool Version: Vivado v.2020.2 (win64) Build 3064766 Wed Nov 18 09:12:45 MST 2020
-- Date        : Wed May 13 13:42:29 2026
-- Host        : Adam running 64-bit major release  (build 9200)
-- Command     : write_vhdl -force -mode synth_stub
--               e:/AE_project/FPGA/AE_project/AE_project.gen/sources_1/ip/adc_dclk_in/adc_dclk_in_stub.vhdl
-- Design      : adc_dclk_in
-- Purpose     : Stub declaration of top-level module interface
-- Device      : xc7a200tfbg484-2
-- --------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity adc_dclk_in is
  Port ( 
    adc_dclk_in : out STD_LOGIC;
    adc_divclk : out STD_LOGIC;
    clk_in1_p : in STD_LOGIC;
    clk_in1_n : in STD_LOGIC
  );

end adc_dclk_in;

architecture stub of adc_dclk_in is
attribute syn_black_box : boolean;
attribute black_box_pad_pin : string;
attribute syn_black_box of stub : architecture is true;
attribute black_box_pad_pin of stub : architecture is "adc_dclk_in,adc_divclk,clk_in1_p,clk_in1_n";
begin
end;
