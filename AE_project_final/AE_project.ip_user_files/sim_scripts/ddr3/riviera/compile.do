vlib work
vlib riviera

vlib riviera/xpm
vlib riviera/xil_defaultlib

vmap xpm riviera/xpm
vmap xil_defaultlib riviera/xil_defaultlib

vlog -work xpm  -sv2k12 \
"E:/1.tools/Xilinx/Vivado/2020.2/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv" \
"E:/1.tools/Xilinx/Vivado/2020.2/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv" \
"E:/1.tools/Xilinx/Vivado/2020.2/data/ip/xpm/xpm_fifo/hdl/xpm_fifo.sv" \

vcom -work xpm -93 \
"E:/1.tools/Xilinx/Vivado/2020.2/data/ip/xpm/xpm_VCOMP.vhd" \

vlog -work xil_defaultlib  -v2k5 \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_axi_ctrl_addr_decode.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_axi_ctrl_read.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_axi_ctrl_reg.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_axi_ctrl_reg_bank.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_axi_ctrl_top.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_axi_ctrl_write.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_axi_mc.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_axi_mc_ar_channel.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_axi_mc_aw_channel.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_axi_mc_b_channel.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_axi_mc_cmd_arbiter.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_axi_mc_cmd_fsm.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_axi_mc_cmd_translator.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_axi_mc_fifo.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_axi_mc_incr_cmd.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_axi_mc_r_channel.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_axi_mc_simple_fifo.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_axi_mc_wrap_cmd.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_axi_mc_wr_cmd_fsm.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_axi_mc_w_channel.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_ddr_axic_register_slice.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_ddr_axi_register_slice.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_ddr_axi_upsizer.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_ddr_a_upsizer.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_ddr_carry_and.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_ddr_carry_latch_and.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_ddr_carry_latch_or.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_ddr_carry_or.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_ddr_command_fifo.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_ddr_comparator.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_ddr_comparator_sel.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_ddr_comparator_sel_static.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_ddr_r_upsizer.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/axi/mig_7series_v4_2_ddr_w_upsizer.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/clocking/mig_7series_v4_2_clk_ibuf.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/clocking/mig_7series_v4_2_infrastructure.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/clocking/mig_7series_v4_2_iodelay_ctrl.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/clocking/mig_7series_v4_2_tempmon.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/controller/mig_7series_v4_2_arb_mux.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/controller/mig_7series_v4_2_arb_row_col.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/controller/mig_7series_v4_2_arb_select.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/controller/mig_7series_v4_2_bank_cntrl.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/controller/mig_7series_v4_2_bank_common.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/controller/mig_7series_v4_2_bank_compare.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/controller/mig_7series_v4_2_bank_mach.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/controller/mig_7series_v4_2_bank_queue.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/controller/mig_7series_v4_2_bank_state.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/controller/mig_7series_v4_2_col_mach.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/controller/mig_7series_v4_2_mc.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/controller/mig_7series_v4_2_rank_cntrl.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/controller/mig_7series_v4_2_rank_common.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/controller/mig_7series_v4_2_rank_mach.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/controller/mig_7series_v4_2_round_robin_arb.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/ecc/mig_7series_v4_2_ecc_buf.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/ecc/mig_7series_v4_2_ecc_dec_fix.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/ecc/mig_7series_v4_2_ecc_gen.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/ecc/mig_7series_v4_2_ecc_merge_enc.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/ecc/mig_7series_v4_2_fi_xor.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/ip_top/mig_7series_v4_2_memc_ui_top_axi.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/ip_top/mig_7series_v4_2_mem_intfc.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_byte_group_io.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_byte_lane.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_calib_top.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_if_post_fifo.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_mc_phy.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_mc_phy_wrapper.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_of_pre_fifo.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_phy_4lanes.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_phy_ck_addr_cmd_delay.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_phy_dqs_found_cal.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_phy_dqs_found_cal_hr.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_phy_init.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_phy_ocd_cntlr.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_phy_ocd_data.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_phy_ocd_edge.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_phy_ocd_lim.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_phy_ocd_mux.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_phy_ocd_po_cntlr.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_phy_ocd_samp.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_phy_oclkdelay_cal.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_phy_prbs_rdlvl.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_phy_rdlvl.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_phy_tempmon.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_phy_top.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_phy_wrcal.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_phy_wrlvl.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_phy_wrlvl_off_delay.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_prbs_gen.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_ddr_skip_calib_tap.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_poc_cc.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_poc_edge_store.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_poc_meta.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_poc_pd.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_poc_tap_base.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/phy/mig_7series_v4_2_poc_top.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/ui/mig_7series_v4_2_ui_cmd.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/ui/mig_7series_v4_2_ui_rd_data.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/ui/mig_7series_v4_2_ui_top.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/ui/mig_7series_v4_2_ui_wr_data.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/ddr3_mig_sim.v" \
"../../../../AE_project.gen/sources_1/ip/ddr3/ddr3/user_design/rtl/ddr3.v" \

vlog -work xil_defaultlib \
"glbl.v"

