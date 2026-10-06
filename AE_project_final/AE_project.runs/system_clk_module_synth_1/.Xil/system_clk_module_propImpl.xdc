set_property SRC_FILE_INFO {cfile:e:/AE_project/FPGA/AE_project/AE_project.gen/sources_1/ip/system_clk_module/system_clk_module.xdc rfile:../../../AE_project.gen/sources_1/ip/system_clk_module/system_clk_module.xdc id:1 order:EARLY scoped_inst:inst} [current_design]
current_instance inst
set_property src_info {type:SCOPED_XDC file:1 line:57 export:INPUT save:INPUT read:READ} [current_design]
set_input_jitter [get_clocks -of_objects [get_ports clk_in1_p]] 0.05
