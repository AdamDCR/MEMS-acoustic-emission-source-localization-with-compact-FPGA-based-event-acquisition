-- Copyright 1986-2020 Xilinx, Inc. All Rights Reserved.
-- --------------------------------------------------------------------------------
-- Tool Version: Vivado v.2020.2 (win64) Build 3064766 Wed Nov 18 09:12:45 MST 2020
-- Date        : Wed May 13 20:15:38 2026
-- Host        : Adam running 64-bit major release  (build 9200)
-- Command     : write_vhdl -force -mode synth_stub
--               e:/AE_project/FPGA/AE_project/AE_project.gen/sources_1/ip/system_clk_module/system_clk_module_stub.vhdl
-- Design      : system_clk_module
-- Purpose     : Stub declaration of top-level module interface
-- Device      : xc7a200tfbg484-2
-- --------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity system_clk_module is
  Port ( 
    sys_clk : out STD_LOGIC;
    adc_clk : out STD_LOGIC;
    eth_clk : out STD_LOGIC;
    clk_125M : out STD_LOGIC;
    resetn : in STD_LOGIC;
    locked : out STD_LOGIC;
    clk_in1_p : in STD_LOGIC;
    clk_in1_n : in STD_LOGIC
  );

end system_clk_module;

architecture stub of system_clk_module is
attribute syn_black_box : boolean;
attribute black_box_pad_pin : string;
attribute syn_black_box of stub : architecture is true;
attribute black_box_pad_pin of stub : architecture is "sys_clk,adc_clk,eth_clk,clk_125M,resetn,locked,clk_in1_p,clk_in1_n";
begin
end;
