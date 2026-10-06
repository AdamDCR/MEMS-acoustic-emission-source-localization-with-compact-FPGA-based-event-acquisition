`timescale 1ns / 1ps

module ae_ddr_axis_event_buffer #(
    parameter integer FRAME_SAMPLES    = 8192,
    parameter integer PRE_SAMPLES      = 4096,
    parameter integer POST_SAMPLES     = 4096,
    parameter integer HEADER_WORDS     = 4,
    parameter integer EVENT_BASE_ADDR  = 30'h0000_0000,
    parameter integer DESC_COUNT       = 1024,
    parameter integer SIM_AXI_MEM      = 0
)(
    input                               sys_clk                    ,
    input                               reset_n                    ,

    input                               s_axis_tvalid              ,
    output                              s_axis_tready              ,
    input                [ 255: 0]      s_axis_tdata               ,
    input                               s_axis_tlast               ,
    input                [  63: 0]      s_axis_tuser               ,

    input                [  15: 0]      cfg_ae_threshold           ,
    input                [  15: 0]      cfg_sample_rate_div        ,
    input                [  15: 0]      cfg_trig_mask              ,
    input                [  95: 0]      time_info                  ,

    input                               rd_req                     ,
    input                [  31: 0]      rd_event_seq               ,
    output                              rd_busy                    ,
    output                              rd_found                   ,
    output                              rd_valid                   ,
    input                               rd_ready                   ,
    output                              rd_sop                     ,
    output                              rd_eop                     ,
    output               [ 255: 0]      rd_data                    ,

    output               [  14: 0]      ddr3_addr                  ,
    output               [   2: 0]      ddr3_ba                    ,
    output                              ddr3_cas_n                 ,
    output               [   0: 0]      ddr3_ck_n                  ,
    output               [   0: 0]      ddr3_ck_p                  ,
    output               [   0: 0]      ddr3_cke                   ,
    output                              ddr3_ras_n                 ,
    output                              ddr3_reset_n               ,
    output                              ddr3_we_n                  ,
    inout                [  31: 0]      ddr3_dq                    ,
    inout                [   3: 0]      ddr3_dqs_n                 ,
    inout                [   3: 0]      ddr3_dqs_p                 ,
    output               [   0: 0]      ddr3_cs_n                  ,
    output               [   3: 0]      ddr3_dm                    ,
    output               [   0: 0]      ddr3_odt                   ,

    input                               sys_clk_i                  ,
    input                               clk_ref_i                  ,
    input                               sys_rst                    ,

    output                              init_calib_complete        ,
    output                              ui_clk                     ,
    output                              ui_clk_sync_rst            ,
    output                              mmcm_locked                ,

    output               [  31: 0]      ingress_event_seq_dbg      ,
    output                              ingress_frame_len_error    ,
    output               [  31: 0]      committed_event_seq        ,
    output                              committed_event_pulse      ,
    output               [ 127: 0]      ddr_dbg_bus                ,
    output               [  31: 0]      ddr_dbg_seq                ,
    output                              ddr_dbg_desc_wr_en         ,
    output                              ddr_dbg_desc_query_done    ,
    output                              ddr_dbg_desc_query_found    
);

    wire                 [  15: 0]      axis_ch_mask               ;
    wire                 [  31: 0]      axis_trigger_sample_index  ;
    wire                 [  15: 0]      meta_trig_mask             ;
    wire                 [  15: 0]      meta_sample_rate_div       ;
    wire                 [ 255: 0]      cap_out_meta               ;

    assign                              axis_ch_mask                = s_axis_tuser[16:1]   ;
    assign                              axis_trigger_sample_index   = s_axis_tuser[48:17]  ;
    assign                              meta_trig_mask              = (cfg_trig_mask == 16'd0) ? axis_ch_mask : cfg_trig_mask;
    assign                              meta_sample_rate_div        = (cfg_sample_rate_div == 16'd0) ? 16'd1 : cfg_sample_rate_div;

    assign cap_out_meta = {
        axis_trigger_sample_index,
        32'd0,
        axis_ch_mask,
        meta_trig_mask,
        cfg_ae_threshold,
        meta_sample_rate_div,
        128'd0
    };

    ae_ddr_event_buffer #(
    .FRAME_SAMPLES                      (FRAME_SAMPLES             ),
    .PRE_SAMPLES                        (PRE_SAMPLES               ),
    .POST_SAMPLES                       (POST_SAMPLES              ),
    .HEADER_WORDS                       (HEADER_WORDS              ),
    .EVENT_BASE_ADDR                    (EVENT_BASE_ADDR           ),
    .DESC_COUNT                         (DESC_COUNT                ),
    .SIM_AXI_MEM                        (SIM_AXI_MEM               ) 
    ) u_ae_ddr_event_buffer (
    .sys_clk                            (sys_clk                   ),
    .reset_n                            (reset_n                   ),

    .cap_out_valid                      (s_axis_tvalid             ),
    .cap_out_sop                        (s_axis_tuser[0]           ),
    .cap_out_eop                        (s_axis_tlast              ),
    .cap_out_data                       (s_axis_tdata              ),
    .cap_out_ch_mask                    (axis_ch_mask              ),
    .cap_out_meta                       (cap_out_meta              ),
    .cap_out_ready                      (s_axis_tready             ),

    .time_info                          (time_info                 ),

    .rd_req                             (rd_req                    ),
    .rd_event_seq                       (rd_event_seq              ),
    .rd_busy                            (rd_busy                   ),
    .rd_found                           (rd_found                  ),
    .rd_valid                           (rd_valid                  ),
    .rd_ready                           (rd_ready                  ),
    .rd_sop                             (rd_sop                    ),
    .rd_eop                             (rd_eop                    ),
    .rd_data                            (rd_data                   ),

    .ddr3_addr                          (ddr3_addr                 ),
    .ddr3_ba                            (ddr3_ba                   ),
    .ddr3_cas_n                         (ddr3_cas_n                ),
    .ddr3_ck_n                          (ddr3_ck_n                 ),
    .ddr3_ck_p                          (ddr3_ck_p                 ),
    .ddr3_cke                           (ddr3_cke                  ),
    .ddr3_ras_n                         (ddr3_ras_n                ),
    .ddr3_reset_n                       (ddr3_reset_n              ),
    .ddr3_we_n                          (ddr3_we_n                 ),
    .ddr3_dq                            (ddr3_dq                   ),
    .ddr3_dqs_n                         (ddr3_dqs_n                ),
    .ddr3_dqs_p                         (ddr3_dqs_p                ),
    .ddr3_cs_n                          (ddr3_cs_n                 ),
    .ddr3_dm                            (ddr3_dm                   ),
    .ddr3_odt                           (ddr3_odt                  ),

    .sys_clk_i                          (sys_clk_i                 ),
    .clk_ref_i                          (clk_ref_i                 ),
    .sys_rst                            (sys_rst                   ),

    .init_calib_complete                (init_calib_complete       ),
    .ui_clk                             (ui_clk                    ),
    .ui_clk_sync_rst                    (ui_clk_sync_rst           ),
    .mmcm_locked                        (mmcm_locked               ),

    .ingress_event_seq_dbg              (ingress_event_seq_dbg     ),
    .ingress_frame_len_error            (ingress_frame_len_error   ),
    .committed_event_seq                (committed_event_seq       ),
    .committed_event_pulse              (committed_event_pulse     ),
    .ddr_dbg_bus                        (ddr_dbg_bus               ),
    .ddr_dbg_seq                        (ddr_dbg_seq               ),
    .ddr_dbg_desc_wr_en                 (ddr_dbg_desc_wr_en        ),
    .ddr_dbg_desc_query_done            (ddr_dbg_desc_query_done   ),
    .ddr_dbg_desc_query_found           (ddr_dbg_desc_query_found  ) 
    );

endmodule
