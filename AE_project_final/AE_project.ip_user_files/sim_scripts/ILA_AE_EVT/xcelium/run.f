-makelib xcelium_lib/xpm -sv \
  "E:/1.tools/Xilinx/Vivado/2020.2/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv" \
  "E:/1.tools/Xilinx/Vivado/2020.2/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv" \
  "E:/1.tools/Xilinx/Vivado/2020.2/data/ip/xpm/xpm_fifo/hdl/xpm_fifo.sv" \
-endlib
-makelib xcelium_lib/xpm \
  "E:/1.tools/Xilinx/Vivado/2020.2/data/ip/xpm/xpm_VCOMP.vhd" \
-endlib
-makelib xcelium_lib/xil_defaultlib \
  "../../../../AE_project.gen/sources_1/ip/ILA_AE_EVT/sim/ILA_AE_EVT.v" \
-endlib
-makelib xcelium_lib/xil_defaultlib \
  glbl.v
-endlib

