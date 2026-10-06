-makelib ies_lib/xpm -sv \
  "E:/1.tools/Xilinx/Vivado/2020.2/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv" \
  "E:/1.tools/Xilinx/Vivado/2020.2/data/ip/xpm/xpm_fifo/hdl/xpm_fifo.sv" \
  "E:/1.tools/Xilinx/Vivado/2020.2/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv" \
-endlib
-makelib ies_lib/xpm \
  "E:/1.tools/Xilinx/Vivado/2020.2/data/ip/xpm/xpm_VCOMP.vhd" \
-endlib
-makelib ies_lib/xil_defaultlib \
  "../../../../AE_project.gen/sources_1/ip/adc_dclk_in/adc_dclk_in_clk_wiz.v" \
  "../../../../AE_project.gen/sources_1/ip/adc_dclk_in/adc_dclk_in.v" \
-endlib
-makelib ies_lib/xil_defaultlib \
  glbl.v
-endlib

