-- Copyright 1986-2020 Xilinx, Inc. All Rights Reserved.
-- --------------------------------------------------------------------------------
-- Tool Version: Vivado v.2020.2 (win64) Build 3064766 Wed Nov 18 09:12:45 MST 2020
-- Date        : Sun May 17 17:34:20 2026
-- Host        : Adam running 64-bit major release  (build 9200)
-- Command     : write_vhdl -force -mode synth_stub
--               e:/AE_project/FPGA/AE_project/AE_project.gen/sources_1/ip/ILA_DATA_DOWNSAMPLE/ILA_DATA_DOWNSAMPLE_stub.vhdl
-- Design      : ILA_DATA_DOWNSAMPLE
-- Purpose     : Stub declaration of top-level module interface
-- Device      : xc7a200tfbg484-2
-- --------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity ILA_DATA_DOWNSAMPLE is
  Port ( 
    clk : in STD_LOGIC;
    probe0 : in STD_LOGIC_VECTOR ( 0 to 0 );
    probe1 : in STD_LOGIC_VECTOR ( 0 to 0 );
    probe2 : in STD_LOGIC_VECTOR ( 15 downto 0 );
    probe3 : in STD_LOGIC_VECTOR ( 0 to 0 );
    probe4 : in STD_LOGIC_VECTOR ( 255 downto 0 );
    probe5 : in STD_LOGIC_VECTOR ( 255 downto 0 );
    probe6 : in STD_LOGIC_VECTOR ( 0 to 0 );
    probe7 : in STD_LOGIC_VECTOR ( 255 downto 0 );
    probe8 : in STD_LOGIC_VECTOR ( 255 downto 0 )
  );

end ILA_DATA_DOWNSAMPLE;

architecture stub of ILA_DATA_DOWNSAMPLE is
attribute syn_black_box : boolean;
attribute black_box_pad_pin : string;
attribute syn_black_box of stub : architecture is true;
attribute black_box_pad_pin of stub : architecture is "clk,probe0[0:0],probe1[0:0],probe2[15:0],probe3[0:0],probe4[255:0],probe5[255:0],probe6[0:0],probe7[255:0],probe8[255:0]";
attribute X_CORE_INFO : string;
attribute X_CORE_INFO of stub : architecture is "ila,Vivado 2020.2";
begin
end;
