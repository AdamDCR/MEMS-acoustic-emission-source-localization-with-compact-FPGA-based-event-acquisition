open_project {E:/AE_project/FPGA/AE_project/AE_project.xpr}
set fir_ip {E:/AE_project/FPGA/adc_data_preprocess/adc_data_preprocess.srcs/sources_1/ip/fir_500k_lp/fir_500k_lp.xci}
if {[llength [get_files -quiet $fir_ip]] == 0} {
    add_files -norecurse $fir_ip
}
generate_target simulation [get_files $fir_ip]
add_files -fileset sim_1 -norecurse {E:/AE_project/FPGA/AE_project/AE_project.srcs/sim_1/new/tb_top_smoke.v}
set_property top tb_top_smoke [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
set_property xsim.simulate.runtime {20 us} [get_filesets sim_1]
launch_simulation -simset sim_1 -mode behavioral
close_sim
close_project
