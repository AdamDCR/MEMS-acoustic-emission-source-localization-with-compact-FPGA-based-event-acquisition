`timescale 1ns / 1ps

module ae_ddr_event_buffer #(
    parameter   integer                 FRAME_SAMPLES = 8192        ,
    parameter   integer                 PRE_SAMPLES   = 4096        ,
    parameter   integer                 POST_SAMPLES  = 4096        ,
    parameter   integer                 HEADER_WORDS  = 4           ,
    parameter   integer                 EVENT_BASE_ADDR = 30'h0000_0000 ,
    parameter   integer                 DESC_COUNT    = 1024        ,
    parameter   integer                 SIM_AXI_MEM   = 0
)(
    input                               sys_clk                    ,
    input                               reset_n                    ,

    // ------------------------------------------------------------------------
    // 来自 ae_event_capture 的一帧事件流
    // ------------------------------------------------------------------------
    input                               cap_out_valid              ,
    input                               cap_out_sop                ,
    input                               cap_out_eop                ,
    input                [ 255: 0]      cap_out_data               ,
    input                [  15: 0]      cap_out_ch_mask            ,
    input                [ 255: 0]      cap_out_meta               ,

    output                              cap_out_ready              ,

    // ------------------------------------------------------------------------
    // 打包后的时间信息
    // [95:80] year
    // [79:72] month
    // [71:64] day
    // [63:56] hour
    // [55:48] minute
    // [47:40] second
    // [39:8]  subsec_us
    // [7]     time_valid
    // [6:0]   reserved
    // ------------------------------------------------------------------------
    input                [  95: 0]      time_info                  ,

    // ------------------------------------------------------------------------
    // 读回请求与输出流
    // ------------------------------------------------------------------------
    input                               rd_req                     ,
    input                [  31: 0]      rd_event_seq               ,
    output                              rd_busy                    ,
    output                              rd_found                   ,
    output                              rd_valid                   ,
    input                               rd_ready                   ,
    output                              rd_sop                     ,
    output                              rd_eop                     ,
    output               [ 255: 0]      rd_data                    ,

    // ------------------------------------------------------------------------
    // DDR3 物理接口
    // ------------------------------------------------------------------------
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

    // ------------------------------------------------------------------------
    // MIG 时钟与复位
    // ------------------------------------------------------------------------
    input                               sys_clk_i                  ,
    input                               clk_ref_i                  ,
    input                               sys_rst                    ,

    output                              init_calib_complete        ,
    output                              ui_clk                     ,
    output                              ui_clk_sync_rst            ,
    output                              mmcm_locked                ,

    // ------------------------------------------------------------------------
    // 调试输出
    // ------------------------------------------------------------------------
    output               [  31: 0]      ingress_event_seq_dbg      ,
    output                              ingress_frame_len_error     ,
    output reg           [  31: 0]      committed_event_seq        ,
    output reg                          committed_event_pulse      ,
    output               [ 127: 0]      ddr_dbg_bus                ,
    output               [  31: 0]      ddr_dbg_seq                ,
    output                              ddr_dbg_desc_wr_en         ,
    output                              ddr_dbg_desc_query_done    ,
    output                              ddr_dbg_desc_query_found    
);

    localparam integer AXI_DATA_W        = 256;
    localparam integer AXI_ADDR_W        = 30;
    localparam integer FRAME_WORDS       = FRAME_SAMPLES + HEADER_WORDS;
    localparam integer FRAME_BYTES       = FRAME_WORDS * (AXI_DATA_W / 8);
    localparam integer EVENT_SLOT_BYTES  = ((FRAME_BYTES + 4095) / 4096) * 4096;

    wire                                ui_rst_n                   ;
    wire                 [  11: 0]      ddr3_device_temp           ;

    // ------------------------------------------------------------------------
    // sys_clk -> ui_clk 数据 FIFO
    // ------------------------------------------------------------------------
    wire                                data_fifo_wr_en            ;
    wire                 [ 255: 0]      data_fifo_din              ;
    wire                                data_fifo_full             ;
    wire                                data_fifo_prog_full        ;
    wire                                data_fifo_wr_rst_busy      ;
    wire                                data_fifo_rd_rst_busy      ;

    wire                                data_fifo_rd_en            ;
    wire                 [ 255: 0]      data_fifo_dout             ;
    wire                                data_fifo_empty            ;
    wire                                data_fifo_empty_safe       ;

    // ------------------------------------------------------------------------
    // sys_clk -> ui_clk 元信息 FIFO
    // ------------------------------------------------------------------------
    wire                                meta_fifo_wr_en            ;
    wire                 [ 255: 0]      meta_fifo_din              ;
    wire                                meta_fifo_full             ;
    wire                                meta_fifo_prog_full        ;
    wire                                meta_fifo_wr_rst_busy      ;
    wire                                meta_fifo_rd_rst_busy      ;

    wire                                meta_fifo_rd_en            ;
    wire                 [ 255: 0]      meta_fifo_dout             ;
    wire                                meta_fifo_empty            ;
    wire                                meta_fifo_empty_safe       ;
    wire                                data_fifo_ingress_pause    ;
    wire                                meta_fifo_ingress_pause    ;

    // ------------------------------------------------------------------------
    // 描述符表接口
    // ------------------------------------------------------------------------
    wire                                desc_wr_en                 ;
    wire                 [$clog2(DESC_COUNT)-1: 0]desc_wr_idx                ;
    wire                 [ 255: 0]      desc_wr_data               ;

    wire                                desc_query_en              ;
    wire                 [  31: 0]      desc_query_event_seq       ;
    wire                                desc_query_done            ;
    wire                                desc_query_found           ;
    wire                 [ 255: 0]      desc_query_desc            ;

    // ------------------------------------------------------------------------
    // AXI 写接口
    // ------------------------------------------------------------------------
    wire                 [   3: 0]      s_axi_awid_w               ;
    wire                 [  29: 0]      s_axi_awaddr_w             ;
    wire                 [   7: 0]      s_axi_awlen_w              ;
    wire                 [   2: 0]      s_axi_awsize_w             ;
    wire                 [   1: 0]      s_axi_awburst_w            ;
    wire                 [   0: 0]      s_axi_awlock_w             ;
    wire                 [   3: 0]      s_axi_awcache_w            ;
    wire                 [   2: 0]      s_axi_awprot_w             ;
    wire                 [   3: 0]      s_axi_awqos_w              ;
    wire                                s_axi_awvalid_w            ;
    wire                                s_axi_awready_w            ;

    wire                 [ 255: 0]      s_axi_wdata_w              ;
    wire                 [  31: 0]      s_axi_wstrb_w              ;
    wire                                s_axi_wlast_w              ;
    wire                                s_axi_wvalid_w             ;
    wire                                s_axi_wready_w             ;

    wire                 [   3: 0]      s_axi_bid_w                ;
    wire                 [   1: 0]      s_axi_bresp_w              ;
    wire                                s_axi_bvalid_w             ;
    wire                                s_axi_bready_w             ;

    // ------------------------------------------------------------------------
    // AXI 读接口
    // ------------------------------------------------------------------------
    wire                 [   3: 0]      s_axi_arid_r               ;
    wire                 [  29: 0]      s_axi_araddr_r             ;
    wire                 [   7: 0]      s_axi_arlen_r              ;
    wire                 [   2: 0]      s_axi_arsize_r             ;
    wire                 [   1: 0]      s_axi_arburst_r            ;
    wire                 [   0: 0]      s_axi_arlock_r             ;
    wire                 [   3: 0]      s_axi_arcache_r            ;
    wire                 [   2: 0]      s_axi_arprot_r             ;
    wire                 [   3: 0]      s_axi_arqos_r              ;
    wire                                s_axi_arvalid_r            ;
    wire                                s_axi_arready_r            ;

    wire                 [   3: 0]      s_axi_rid_r                ;
    wire                 [ 255: 0]      s_axi_rdata_r              ;
    wire                 [   1: 0]      s_axi_rresp_r              ;
    wire                                s_axi_rlast_r              ;
    wire                                s_axi_rvalid_r             ;
    wire                                s_axi_rready_r             ;

    // ------------------------------------------------------------------------
    // MIG 应用层保留接口，当前固定为 0
    // ------------------------------------------------------------------------
    wire                                app_sr_req                 ;
    wire                                app_ref_req                ;
    wire                                app_zq_req                 ;
    wire                                app_sr_active              ;
    wire                                app_ref_ack                ;
    wire                                app_zq_ack                 ;
    wire                                aresetn                    ;

    assign                              app_sr_req                  = 1'b0                 ;
    assign                              app_ref_req                 = 1'b0                 ;
    assign                              app_zq_req                  = 1'b0                 ;
    reg                  [   1: 0]      ui_reset_sync              ;
    assign                              aresetn                     = ui_reset_sync[1]     ;
    assign                              ui_rst_n                    = ui_reset_sync[1]     ;

    wire                 [  31: 0]      ddr_dbg_status             ;
    assign                              ddr_dbg_desc_wr_en          = desc_wr_en            ;
    assign                              ddr_dbg_desc_query_done     = desc_query_done       ;
    assign                              ddr_dbg_desc_query_found    = desc_query_found      ;
    assign                              data_fifo_empty_safe         =
        data_fifo_empty | data_fifo_rd_rst_busy;
    assign                              meta_fifo_empty_safe         =
        meta_fifo_empty | meta_fifo_rd_rst_busy;
    assign                              data_fifo_ingress_pause      =
        data_fifo_prog_full | data_fifo_wr_rst_busy;
    assign                              meta_fifo_ingress_pause      =
        meta_fifo_prog_full | meta_fifo_wr_rst_busy;
    assign                              ddr_dbg_seq                 =
        desc_wr_en ? desc_wr_data[254:223] : desc_query_event_seq;
    assign                              ddr_dbg_status              = {
        init_calib_complete,
        ui_clk_sync_rst,
        rd_req,
        rd_busy,
        rd_found,
        rd_valid,
        rd_ready,
        rd_sop,
        rd_eop,
        desc_wr_en,
        desc_query_en,
        desc_query_done,
        desc_query_found,
        s_axi_awvalid_w,
        s_axi_awready_w,
        s_axi_wvalid_w,
        s_axi_wready_w,
        s_axi_wlast_w,
        s_axi_bvalid_w,
        s_axi_bready_w,
        s_axi_arvalid_r,
        s_axi_arready_r,
        s_axi_rvalid_r,
        s_axi_rready_r,
        s_axi_rlast_r,
        s_axi_bresp_w,
        s_axi_rresp_r,
        3'd0
    };
    assign                              ddr_dbg_bus                 = {
        ddr_dbg_status,
        rd_event_seq,
        desc_query_event_seq,
        desc_wr_data[254:223]
    };

    reg                  [  31: 0]      committed_event_seq_ui     ;
    reg                                 committed_event_toggle_ui  ;
    reg                                 committed_event_toggle_meta1;
    reg                                 committed_event_toggle_meta2;
    reg                                 committed_event_toggle_meta2_d;
    reg                  [  31: 0]      committed_event_seq_meta1  ;
    reg                  [  31: 0]      committed_event_seq_meta2  ;
    wire                                committed_event_toggle_edge;

    assign committed_event_toggle_edge =
        committed_event_toggle_meta2 ^ committed_event_toggle_meta2_d;
        
    always @(posedge ui_clk or posedge ui_clk_sync_rst) begin
        if (ui_clk_sync_rst)
            ui_reset_sync <= 2'b00;
        else
            ui_reset_sync <= {ui_reset_sync[0], 1'b1};
    end

    always @(posedge ui_clk) begin
        if (!ui_rst_n) begin
            committed_event_seq_ui    <= 32'd0;
            committed_event_toggle_ui <= 1'b0;
        end else if (desc_wr_en) begin
            committed_event_seq_ui    <= desc_wr_data[254:223];
            committed_event_toggle_ui <= ~committed_event_toggle_ui;
        end
    end

    always @(posedge sys_clk or negedge reset_n) begin
        if (!reset_n) begin
            committed_event_toggle_meta1   <= 1'b0;
            committed_event_toggle_meta2   <= 1'b0;
            committed_event_toggle_meta2_d <= 1'b0;
            committed_event_seq_meta1      <= 32'd0;
            committed_event_seq_meta2      <= 32'd0;
            committed_event_seq            <= 32'd0;
            committed_event_pulse          <= 1'b0;
        end else begin
            committed_event_toggle_meta1   <= committed_event_toggle_ui;
            committed_event_toggle_meta2   <= committed_event_toggle_meta1;
            committed_event_toggle_meta2_d <= committed_event_toggle_meta2;
            committed_event_seq_meta1      <= committed_event_seq_ui;
            committed_event_seq_meta2      <= committed_event_seq_meta1;
            committed_event_pulse          <= committed_event_toggle_edge;

            if (committed_event_toggle_edge) begin
                committed_event_seq <= committed_event_seq_meta2;
            end
        end
    end

    // ------------------------------------------------------------------------
    // 1) sys_clk 域：事件流入口
    // ------------------------------------------------------------------------
    ae_event_ingress #(
    .FRAME_SAMPLES                      (FRAME_SAMPLES             ) 
    ) u_ae_event_ingress (
    .sys_clk                            (sys_clk                   ),
    .reset_n                            (reset_n                   ),
    .cap_out_valid                      (cap_out_valid             ),
    .cap_out_sop                        (cap_out_sop               ),
    .cap_out_eop                        (cap_out_eop               ),
    .cap_out_data                       (cap_out_data              ),
    .cap_out_ch_mask                    (cap_out_ch_mask           ),
    .cap_out_ready                      (cap_out_ready             ),

    .cap_out_meta                       (cap_out_meta              ),
    .time_info                          (time_info                 ),
    .data_fifo_prog_full                (data_fifo_ingress_pause   ),
    .meta_fifo_prog_full                (meta_fifo_ingress_pause   ),
    .data_fifo_wr_en                    (data_fifo_wr_en           ),
    .data_fifo_din                      (data_fifo_din             ),
    .meta_fifo_wr_en                    (meta_fifo_wr_en           ),
    .meta_fifo_din                      (meta_fifo_din             ),
    .event_seq_dbg                      (ingress_event_seq_dbg     ),
    .frame_len_error                    (ingress_frame_len_error   ) 
    );

    // ------------------------------------------------------------------------
    // 2) payload FIFO：仅缓存 256bit 数据
    // ------------------------------------------------------------------------
    xpm_fifo_async #(
    .FIFO_MEMORY_TYPE                   ("block"                   ),
    .FIFO_WRITE_DEPTH                   (512                       ),
    .WRITE_DATA_WIDTH                   (256                       ),
    .READ_DATA_WIDTH                    (256                       ),
    .READ_MODE                          ("fwft"                    ),
    .FIFO_READ_LATENCY                  (0                         ),
    .FULL_RESET_VALUE                   (0                         ),
    .PROG_FULL_THRESH                   (384                       ),
    .PROG_EMPTY_THRESH                  (16                        ),
    .USE_ADV_FEATURES                   ("0707"                    ),
    .CDC_SYNC_STAGES                    (2                         ),
    .DOUT_RESET_VALUE                   ("0"                       ),
    .ECC_MODE                           ("no_ecc"                  ),
    .SIM_ASSERT_CHK                     (0                         ),
    .WAKEUP_TIME                        (0                         ),
    .WR_DATA_COUNT_WIDTH                (9                         ),
    .RD_DATA_COUNT_WIDTH                (9                         ) 
    ) u_data_fifo (
    .rst                                (~reset_n                  ),
    .wr_clk                             (sys_clk                   ),
    .wr_en                              (data_fifo_wr_en           ),
    .din                                (data_fifo_din             ),
    .full                               (data_fifo_full            ),
    .prog_full                          (data_fifo_prog_full       ),
    .wr_data_count                      (                          ),
    .overflow                           (                          ),
    .wr_rst_busy                        (data_fifo_wr_rst_busy     ),
    .almost_full                        (                          ),
    .wr_ack                             (                          ),

    .rd_clk                             (ui_clk                    ),
    .rd_en                              (data_fifo_rd_en           ),
    .dout                               (data_fifo_dout            ),
    .empty                              (data_fifo_empty           ),
    .prog_empty                         (                          ),
    .rd_data_count                      (                          ),
    .underflow                          (                          ),
    .rd_rst_busy                        (data_fifo_rd_rst_busy     ),
    .almost_empty                       (                          ),
    .data_valid                         (                          ),

    .dbiterr                            (                          ),
    .injectdbiterr                      (1'b0                      ),
    .injectsbiterr                      (1'b0                      ),
    .sbiterr                            (                          ),
    .sleep                              (1'b0                      ) 
    );

    // ------------------------------------------------------------------------
    // 3) meta FIFO：每帧 1 条 256bit 元信息
    // ------------------------------------------------------------------------
    xpm_fifo_async #(
    .FIFO_MEMORY_TYPE                   ("block"                   ),
    .FIFO_WRITE_DEPTH                   (16                        ),
    .WRITE_DATA_WIDTH                   (256                       ),
    .READ_DATA_WIDTH                    (256                       ),
    .READ_MODE                          ("fwft"                    ),
    .FIFO_READ_LATENCY                  (0                         ),
    .FULL_RESET_VALUE                   (0                         ),
    .PROG_FULL_THRESH                   (10                        ),
    .PROG_EMPTY_THRESH                  (5                         ),
    .USE_ADV_FEATURES                   ("0707"                    ),
    .CDC_SYNC_STAGES                    (2                         ),
    .DOUT_RESET_VALUE                   ("0"                       ),
    .ECC_MODE                           ("no_ecc"                  ),
    .SIM_ASSERT_CHK                     (0                         ),
    .WAKEUP_TIME                        (0                         ),
    .WR_DATA_COUNT_WIDTH                (4                         ),
    .RD_DATA_COUNT_WIDTH                (4                         ) 
    ) u_meta_fifo (
    .rst                                (~reset_n                  ),
    .wr_clk                             (sys_clk                   ),
    .wr_en                              (meta_fifo_wr_en           ),
    .din                                (meta_fifo_din             ),
    .full                               (meta_fifo_full            ),
    .prog_full                          (meta_fifo_prog_full       ),
    .wr_data_count                      (                          ),
    .overflow                           (                          ),
    .wr_rst_busy                        (meta_fifo_wr_rst_busy     ),
    .almost_full                        (                          ),
    .wr_ack                             (                          ),

    .rd_clk                             (ui_clk                    ),
    .rd_en                              (meta_fifo_rd_en           ),
    .dout                               (meta_fifo_dout            ),
    .empty                              (meta_fifo_empty           ),
    .prog_empty                         (                          ),
    .rd_data_count                      (                          ),
    .underflow                          (                          ),
    .rd_rst_busy                        (meta_fifo_rd_rst_busy     ),
    .almost_empty                       (                          ),
    .data_valid                         (                          ),

    .dbiterr                            (                          ),
    .injectdbiterr                      (1'b0                      ),
    .injectsbiterr                      (1'b0                      ),
    .sbiterr                            (                          ),
    .sleep                              (1'b0                      ) 
    );

    // ------------------------------------------------------------------------
    // 4) DDR 写控制器
    // ------------------------------------------------------------------------
    ae_ddr_axi_writer #(
    .FRAME_SAMPLES                      (FRAME_SAMPLES             ),
    .PRE_SAMPLES                        (PRE_SAMPLES               ),
    .POST_SAMPLES                       (POST_SAMPLES              ),
    .HEADER_WORDS                       (HEADER_WORDS              ),
    .AXI_ADDR_W                         (AXI_ADDR_W                ),
    .AXI_DATA_W                         (AXI_DATA_W                ),
    .DESC_COUNT                         (DESC_COUNT                ),
    .EVENT_BASE_ADDR                    (EVENT_BASE_ADDR           ),
    .EVENT_SLOT_BYTES                   (EVENT_SLOT_BYTES          ) 
    ) u_ae_ddr_axi_writer (
    .ui_clk                             (ui_clk                    ),
    .ui_rst_n                           (ui_rst_n                  ),
    .init_calib_complete                (init_calib_complete       ),
    .meta_fifo_empty                    (meta_fifo_empty_safe      ),
    .meta_fifo_rd_en                    (meta_fifo_rd_en           ),
    .meta_fifo_dout                     (meta_fifo_dout            ),
    .data_fifo_empty                    (data_fifo_empty_safe      ),
    .data_fifo_rd_en                    (data_fifo_rd_en           ),
    .data_fifo_dout                     (data_fifo_dout            ),
    .desc_wr_en                         (desc_wr_en                ),
    .desc_wr_idx                        (desc_wr_idx               ),
    .desc_wr_data                       (desc_wr_data              ),
    .s_axi_awid                         (s_axi_awid_w              ),
    .s_axi_awaddr                       (s_axi_awaddr_w            ),
    .s_axi_awlen                        (s_axi_awlen_w             ),
    .s_axi_awsize                       (s_axi_awsize_w            ),
    .s_axi_awburst                      (s_axi_awburst_w           ),
    .s_axi_awlock                       (s_axi_awlock_w            ),
    .s_axi_awcache                      (s_axi_awcache_w           ),
    .s_axi_awprot                       (s_axi_awprot_w            ),
    .s_axi_awqos                        (s_axi_awqos_w             ),
    .s_axi_awvalid                      (s_axi_awvalid_w           ),
    .s_axi_awready                      (s_axi_awready_w           ),
    .s_axi_wdata                        (s_axi_wdata_w             ),
    .s_axi_wstrb                        (s_axi_wstrb_w             ),
    .s_axi_wlast                        (s_axi_wlast_w             ),
    .s_axi_wvalid                       (s_axi_wvalid_w            ),
    .s_axi_wready                       (s_axi_wready_w            ),
    .s_axi_bid                          (s_axi_bid_w               ),
    .s_axi_bresp                        (s_axi_bresp_w             ),
    .s_axi_bvalid                       (s_axi_bvalid_w            ),
    .s_axi_bready                       (s_axi_bready_w            ) 
    );

    // ------------------------------------------------------------------------
    // 5) 描述符表
    // ------------------------------------------------------------------------
    ae_event_desc_table #(
    .DESC_COUNT                         (DESC_COUNT                ) 
    ) u_ae_event_desc_table (
    .clk                                (ui_clk                    ),
    .reset_n                            (ui_rst_n                  ),
    .wr_en                              (desc_wr_en                ),
    .wr_idx                             (desc_wr_idx               ),
    .wr_data                            (desc_wr_data              ),
    .query_en                           (desc_query_en             ),
    .query_event_seq                    (desc_query_event_seq      ),
    .query_done                         (desc_query_done           ),
    .query_found                        (desc_query_found          ),
    .query_desc                         (desc_query_desc           ) 
    );

    // ------------------------------------------------------------------------
    // 6) DDR 读控制器
    // ------------------------------------------------------------------------
    ae_ddr_axi_reader #(
    .AXI_ADDR_W                         (AXI_ADDR_W                ) 
    ) u_ae_ddr_axi_reader (
    .ui_clk                             (ui_clk                    ),
    .ui_rst_n                           (ui_rst_n                  ),
    .rd_req                             (rd_req                    ),
    .rd_event_seq                       (rd_event_seq              ),
    .rd_busy                            (rd_busy                   ),
    .rd_found                           (rd_found                  ),
    .query_en                           (desc_query_en             ),
    .query_event_seq                    (desc_query_event_seq      ),
    .query_done                         (desc_query_done           ),
    .query_found                        (desc_query_found          ),
    .query_desc                         (desc_query_desc           ),
    .rd_valid                           (rd_valid                  ),
    .rd_ready                           (rd_ready                  ),
    .rd_sop                             (rd_sop                    ),
    .rd_eop                             (rd_eop                    ),
    .rd_data                            (rd_data                   ),
    .s_axi_arid                         (s_axi_arid_r              ),
    .s_axi_araddr                       (s_axi_araddr_r            ),
    .s_axi_arlen                        (s_axi_arlen_r             ),
    .s_axi_arsize                       (s_axi_arsize_r            ),
    .s_axi_arburst                      (s_axi_arburst_r           ),
    .s_axi_arlock                       (s_axi_arlock_r            ),
    .s_axi_arcache                      (s_axi_arcache_r           ),
    .s_axi_arprot                       (s_axi_arprot_r            ),
    .s_axi_arqos                        (s_axi_arqos_r             ),
    .s_axi_arvalid                      (s_axi_arvalid_r           ),
    .s_axi_arready                      (s_axi_arready_r           ),
    .s_axi_rid                          (s_axi_rid_r               ),
    .s_axi_rdata                        (s_axi_rdata_r             ),
    .s_axi_rresp                        (s_axi_rresp_r             ),
    .s_axi_rlast                        (s_axi_rlast_r             ),
    .s_axi_rvalid                       (s_axi_rvalid_r            ),
    .s_axi_rready                       (s_axi_rready_r            ) 
    );

    // ------------------------------------------------------------------------
    // 7) DDR 后端
    // ------------------------------------------------------------------------
    generate
        if (SIM_AXI_MEM != 0) begin : gen_sim_axi_mem
            reg                  [   7: 0]      sim_calib_cnt;
            reg                                  sim_init_calib_complete;
            wire                                 sim_reset_n;

            assign sim_reset_n           = reset_n & sys_rst;
            assign ui_clk                = sys_clk_i;
            assign ui_clk_sync_rst       = ~sim_init_calib_complete;
            assign mmcm_locked           = sim_reset_n;
            assign init_calib_complete   = sim_init_calib_complete;

            assign ddr3_addr             = 15'd0;
            assign ddr3_ba               = 3'd0;
            assign ddr3_cas_n            = 1'b1;
            assign ddr3_ck_n             = 1'b0;
            assign ddr3_ck_p             = 1'b0;
            assign ddr3_cke              = 1'b0;
            assign ddr3_ras_n            = 1'b1;
            assign ddr3_reset_n          = sim_reset_n;
            assign ddr3_we_n             = 1'b1;
            assign ddr3_cs_n             = 1'b1;
            assign ddr3_dm               = 4'hF;
            assign ddr3_odt              = 1'b0;
            assign ddr3_dq               = 32'hZZZZ_ZZZZ;
            assign ddr3_dqs_n            = 4'hZ;
            assign ddr3_dqs_p            = 4'hZ;

            always @(posedge sys_clk_i or negedge sim_reset_n) begin
                if (!sim_reset_n) begin
                    sim_calib_cnt           <= 8'd0;
                    sim_init_calib_complete <= 1'b0;
                end else if (!sim_init_calib_complete) begin
                    sim_calib_cnt <= sim_calib_cnt + 1'b1;
                    if (sim_calib_cnt == 8'd20) begin
                        sim_init_calib_complete <= 1'b1;
                    end
                end
            end

            ae_ddr_axi_mem_model #(
            .AXI_ADDR_W                        (AXI_ADDR_W                ),
            .AXI_DATA_W                        (AXI_DATA_W                ),
            .MEM_WORDS                         (65536                     )
            ) u_ae_ddr_axi_mem_model (
            .ui_clk                            (ui_clk                    ),
            .ui_rst_n                          (ui_rst_n                  ),

            .s_axi_awid                        (s_axi_awid_w              ),
            .s_axi_awaddr                      (s_axi_awaddr_w            ),
            .s_axi_awlen                       (s_axi_awlen_w             ),
            .s_axi_awsize                      (s_axi_awsize_w            ),
            .s_axi_awburst                     (s_axi_awburst_w           ),
            .s_axi_awvalid                     (s_axi_awvalid_w           ),
            .s_axi_awready                     (s_axi_awready_w           ),

            .s_axi_wdata                       (s_axi_wdata_w             ),
            .s_axi_wstrb                       (s_axi_wstrb_w             ),
            .s_axi_wlast                       (s_axi_wlast_w             ),
            .s_axi_wvalid                      (s_axi_wvalid_w            ),
            .s_axi_wready                      (s_axi_wready_w            ),

            .s_axi_bid                         (s_axi_bid_w               ),
            .s_axi_bresp                       (s_axi_bresp_w             ),
            .s_axi_bvalid                      (s_axi_bvalid_w            ),
            .s_axi_bready                      (s_axi_bready_w            ),

            .s_axi_arid                        (s_axi_arid_r              ),
            .s_axi_araddr                      (s_axi_araddr_r            ),
            .s_axi_arlen                       (s_axi_arlen_r             ),
            .s_axi_arsize                      (s_axi_arsize_r            ),
            .s_axi_arburst                     (s_axi_arburst_r           ),
            .s_axi_arvalid                     (s_axi_arvalid_r           ),
            .s_axi_arready                     (s_axi_arready_r           ),

            .s_axi_rid                         (s_axi_rid_r               ),
            .s_axi_rdata                       (s_axi_rdata_r             ),
            .s_axi_rresp                       (s_axi_rresp_r             ),
            .s_axi_rlast                       (s_axi_rlast_r             ),
            .s_axi_rvalid                      (s_axi_rvalid_r            ),
            .s_axi_rready                      (s_axi_rready_r            )
            );
        end else begin : gen_mig_ddr3
            ddr3 u_ddr3 (
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
            .init_calib_complete                (init_calib_complete       ),
            .device_temp                        (ddr3_device_temp          ),
            .ddr3_cs_n                          (ddr3_cs_n                 ),
            .ddr3_dm                            (ddr3_dm                   ),
            .ddr3_odt                           (ddr3_odt                  ),

            .ui_clk                             (ui_clk                    ),
            .ui_clk_sync_rst                    (ui_clk_sync_rst           ),
            .mmcm_locked                        (mmcm_locked               ),
            .aresetn                            (aresetn                   ),
            .app_sr_req                         (app_sr_req                ),
            .app_ref_req                        (app_ref_req               ),
            .app_zq_req                         (app_zq_req                ),
            .app_sr_active                      (app_sr_active             ),
            .app_ref_ack                        (app_ref_ack               ),
            .app_zq_ack                         (app_zq_ack                ),

            .s_axi_awid                         (s_axi_awid_w              ),
            .s_axi_awaddr                       (s_axi_awaddr_w            ),
            .s_axi_awlen                        (s_axi_awlen_w             ),
            .s_axi_awsize                       (s_axi_awsize_w            ),
            .s_axi_awburst                      (s_axi_awburst_w           ),
            .s_axi_awlock                       (s_axi_awlock_w            ),
            .s_axi_awcache                      (s_axi_awcache_w           ),
            .s_axi_awprot                       (s_axi_awprot_w            ),
            .s_axi_awqos                        (s_axi_awqos_w             ),
            .s_axi_awvalid                      (s_axi_awvalid_w           ),
            .s_axi_awready                      (s_axi_awready_w           ),

            .s_axi_wdata                        (s_axi_wdata_w             ),
            .s_axi_wstrb                        (s_axi_wstrb_w             ),
            .s_axi_wlast                        (s_axi_wlast_w             ),
            .s_axi_wvalid                       (s_axi_wvalid_w            ),
            .s_axi_wready                       (s_axi_wready_w            ),

            .s_axi_bid                          (s_axi_bid_w               ),
            .s_axi_bresp                        (s_axi_bresp_w             ),
            .s_axi_bvalid                       (s_axi_bvalid_w            ),
            .s_axi_bready                       (s_axi_bready_w            ),

            .s_axi_arid                         (s_axi_arid_r              ),
            .s_axi_araddr                       (s_axi_araddr_r            ),
            .s_axi_arlen                        (s_axi_arlen_r             ),
            .s_axi_arsize                       (s_axi_arsize_r            ),
            .s_axi_arburst                      (s_axi_arburst_r           ),
            .s_axi_arlock                       (s_axi_arlock_r            ),
            .s_axi_arcache                      (s_axi_arcache_r           ),
            .s_axi_arprot                       (s_axi_arprot_r            ),
            .s_axi_arqos                        (s_axi_arqos_r             ),
            .s_axi_arvalid                      (s_axi_arvalid_r           ),
            .s_axi_arready                      (s_axi_arready_r           ),

            .s_axi_rid                          (s_axi_rid_r               ),
            .s_axi_rdata                        (s_axi_rdata_r             ),
            .s_axi_rresp                        (s_axi_rresp_r             ),
            .s_axi_rlast                        (s_axi_rlast_r             ),
            .s_axi_rvalid                       (s_axi_rvalid_r            ),
            .s_axi_rready                       (s_axi_rready_r            ),

            .sys_clk_i                          (sys_clk_i                 ),
            .clk_ref_i                          (clk_ref_i                 ),
            .sys_rst                            (sys_rst                   )
            );
        end
    endgenerate

endmodule
