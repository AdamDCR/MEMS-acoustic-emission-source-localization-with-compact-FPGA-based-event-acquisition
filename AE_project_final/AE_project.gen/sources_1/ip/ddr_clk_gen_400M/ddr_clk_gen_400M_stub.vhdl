-- Copyright 1986-2020 Xilinx, Inc. All Rights Reserved.
-- --------------------------------------------------------------------------------
-- Tool Version: Vivado v.2020.2 (win64) Build 3064766 Wed Nov 18 09:12:45 MST 2020
-- Date        : Fri May 15 15:35:53 2026
-- Host        : Adam running 64-bit major release  (build 9200)
-- Command     : write_vhdl -force -mode synth_stub
--               e:/AE_project/FPGA/AE_project/AE_project.gen/sources_1/ip/ddr_clk_gen_400M/ddr_clk_gen_400M_stub.vhdl
-- Design      : ddr_clk_gen_400M
-- Purpose     : Stub declaration of top-level module interface
-- Device      : xc7a200tfbg484-2
-- --------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity ddr_clk_gen_400M is
  Port ( 
    ae_ddr_clk : out STD_LOGIC;
    reset : in STD_LOGIC;
    locked : out STD_LOGIC;
    sys_clk_200M : in STD_LOGIC
  );

end ddr_clk_gen_400M;

architecture stub of ddr_clk_gen_400M is
attribute syn_black_box : boolean;
attribute black_box_pad_pin : string;
attribute syn_black_box of stub : architecture is true;
attribute black_box_pad_pin of stub : architecture is "ae_ddr_clk,reset,locked,sys_clk_200M";
begin
end;
