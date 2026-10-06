vlib work
vlib riviera

vlib riviera/xpm
vlib riviera/xil_defaultlib

vmap xpm riviera/xpm
vmap xil_defaultlib riviera/xil_defaultlib

vlog -work xpm  -sv2k12 "+incdir+../../../../AE_project.gen/sources_1/ip/ILA_DATA_DOWNSAMPLE/hdl/verilog" \
"E:/1.tools/Xilinx/Vivado/2020.2/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv" \
"E:/1.tools/Xilinx/Vivado/2020.2/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv" \
"E:/1.tools/Xilinx/Vivado/2020.2/data/ip/xpm/xpm_fifo/hdl/xpm_fifo.sv" \

vcom -work xpm -93 \
"E:/1.tools/Xilinx/Vivado/2020.2/data/ip/xpm/xpm_VCOMP.vhd" \

vlog -work xil_defaultlib  -v2k5 "+incdir+../../../../AE_project.gen/sources_1/ip/ILA_DATA_DOWNSAMPLE/hdl/verilog" \
"../../../../AE_project.gen/sources_1/ip/ILA_DATA_DOWNSAMPLE/sim/ILA_DATA_DOWNSAMPLE.v" \

vlog -work xil_defaultlib \
"glbl.v"

