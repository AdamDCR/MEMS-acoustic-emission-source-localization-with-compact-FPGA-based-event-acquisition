`timescale 1ns / 1ps
// ============================================================================
// File       : ae_event_capture_axi.v
// Top module : ae_event_capture
//
// AE single-shot event capture with internal UDP config synchronization and
// DDR/write-clock-domain AXI-Stream output.
//
// Requirements implemented:
//   1. UDP config enters this module in sys_clk domain and is latched/synced
//      internally to adc_clk domain.
//   2. ADC-side inputs match adc_data_preprocess outputs. Channel masks from
//      adc_data_preprocess are ANDed with channel_en from udp_rec_decode.
//   3. Single-shot capture: after one event is captured, the ADC-side FSM waits
//      for the frame to be accepted by the DDR AXIS stream and then waits for
//      upload_done_pulse before arming again.
//   4. Fixed event length is 8192 downsampled points; trigger point is centered:
//        frame index 4096 is the trigger sample.
//   5. adc_data_downsampler is inside this module. sample_rate controls
//      AE capture/downsampling rate.
//   6. 
//   7. Output stream uses AXI4-Stream style:
//        m_axis_tvalid / m_axis_tready / m_axis_tdata / m_axis_tlast
//        m_axis_tkeep  = all valid bytes
//        m_axis_tuser[0]     = SOF, high only on first beat
//        m_axis_tuser[16:1]  = channel mask
//        m_axis_tuser[48:17] = trigger sample index
//        m_axis_tuser[51:49] = frame code, fixed 0 for 8192
//
// BRAM latency assumptions:
//   ae_live_ring_bram  B-port read latency = 4 rd_clk cycles in xsim for
//   the generated IP configuration used by this project
//   ae_frame_bank_bram B-port read latency = 3 rd_clk cycles
//   A-port latency does not affect write timing; writes are still synchronous.
// ============================================================================

module ae_event_capture #(
    parameter integer MAX_CH              = 16,
    parameter integer SAMPLE_W            = 16,
    parameter integer DATA_W              = 256,
    parameter integer FRAME_SAMPLES        = 8192,
    parameter integer PRE_SAMPLES          = 4096,
    parameter integer RING_AW              = 14,
    parameter integer FRAME_AW             = 13,
    parameter integer DESC_W               = 72,
    parameter integer AXIS_USER_W          = 64,
    parameter integer LIVE_RING_RD_LATENCY = 4,
    parameter integer FRAME_BANK_RD_LATENCY= 3
)(
    // ------------------------------------------------------------------------
    // Clocks and reset
    // ------------------------------------------------------------------------
    input                               adc_clk                    ,
    input                               sys_clk                    ,
    input                               rd_clk                     ,
    input                               reset_n                    ,

    // ------------------------------------------------------------------------
    // ADC-domain sample stream from adc_data_preprocess
    // ------------------------------------------------------------------------
    input                               cap_en_out                 ,
    input                               sample_valid               ,
    input                [DATA_W-1: 0]  sample_data                ,
    input                [DATA_W-1: 0]  trigger_sample_data        ,
    input                [MAX_CH-1: 0]  active_ch_mask             ,
    input                [MAX_CH-1: 0]  trig_mask                  ,
    input                               sync_ready                 ,
    input                               sync_error                 ,

    // ------------------------------------------------------------------------
    // UDP config from udp_rec_decode, sys_clk domain.
    // Put udp_rec_decode outputs directly here to keep top concise.
    //
    // sample_rate:
    //   1=40MHz, 2=20MHz, 4=10MHz, 8=5MHz, 16=2.5MHz,
    //   20=2MHz, 40=1MHz, 80=500kHz.
    //
    // channel_en:
    //   Top-level channel enable from UDP. It gates both active_ch_mask and
    //   trig_mask from adc_data_preprocess inside this module.
    // ------------------------------------------------------------------------
    input                               ctrl_cfg_valid_pulse       ,
    input                [  15: 0]      sample_rate                ,
    input                [MAX_CH-1: 0]  channel_en                 ,
    input                [SAMPLE_W-1: 0]ctrl_ae_threshold          ,

    // ------------------------------------------------------------------------
    // Release pulse from top / UDP upload path, sys_clk domain.
    // Assert after udp_data_upload has completed for the stored event and a
    // new acquisition is allowed.
    // ------------------------------------------------------------------------
    input                               upload_done_pulse          ,
// ------------------------------------------------------------------------
// True DDR commit pulse, sys_clk domain.
// This must come from ae_ddr_axis_event_buffer.committed_event_pulse.
// It means the event payload has been written and descriptor committed.
// ------------------------------------------------------------------------
    input                               ddr_commit_done_pulse      ,
    // ------------------------------------------------------------------------
    // AXI4-Stream output, rd_clk domain
    // ------------------------------------------------------------------------
    output wire                         m_axis_tvalid              ,
    input                               m_axis_tready              ,
    output wire          [DATA_W-1: 0]  m_axis_tdata               ,
    output wire          [DATA_W/8-1: 0]m_axis_tkeep               ,
    output wire                         m_axis_tlast               ,
    output wire       [AXIS_USER_W-1: 0]m_axis_tuser               ,

    // ------------------------------------------------------------------------
    // Status / debug
    // ------------------------------------------------------------------------
    output wire                         trig_pulse                 ,// adc_clk domain
    output wire                         capture_busy               ,// adc_clk domain
    output wire                         event_wait_ddr             ,// adc_clk domain
    output wire                         event_wait_upload          ,// adc_clk domain
    output wire                         stream_busy                ,// rd_clk domain
    output wire                         event_overflow             ,// adc_clk domain sticky
    output wire                         event_ddr_done_pulse       ,// sys_clk debug: true DDR commit pulse
    output wire          [   1: 0]      bank_free_dbg              ,// rd_clk domain
    output wire          [  31: 0]      trigger_sample_index       ,// adc_clk domain
    output wire                         ds_sample_valid_dbg        ,// adc_clk domain
    output wire          [  15: 0]      active_ch_mask_dbg         ,// adc_clk domain
    output wire          [  15: 0]      sample_rate_div_dbg        ,// adc_clk domain
    output wire          [SAMPLE_W-1: 0]trig_threshold_dbg          // adc_clk domain
);

//调试用计数器
reg [13:0] axis_valid_beat_idx;

always @(posedge rd_clk or negedge reset_n) begin
    if (!reset_n) begin
        axis_valid_beat_idx <= 14'd0;
    end else if (m_axis_tvalid && m_axis_tready) begin
        if (m_axis_tuser[0])
            axis_valid_beat_idx <= 14'd0;
        else
            axis_valid_beat_idx <= axis_valid_beat_idx + 1'b1;
    end
end
`ifdef DEBUG_ILA_AE_AXIS
    ILA_AE_AXIS ILA_AE_AXIS_inst1 (
    .clk                                (rd_clk                    ),// input wire clk
    
    
    .probe0                             (m_axis_tvalid             ),// input wire [0:0]  probe0
    .probe1                             (m_axis_tready             ),// input wire [0:0]  probe1
    .probe2                             (m_axis_tdata[63:0]        ),// input wire [63:0]  probe2
    .probe3                             (axis_valid_beat_idx       ),// input wire [13:0]  probe3
    .probe4                             (m_axis_tlast              ),// input wire [0:0]  probe4
    .probe5                             (m_axis_tuser              ),// input wire [63:0]  probe5
    .probe6                             (stream_busy               ),// input wire [0:0]  probe6
    .probe7                             (probank_free_dbgbe7       ) // input wire [1:0]  probe7
    );
`endif
`ifdef DEBUG_ILA_AE_EVENT
    ILA_AE_EVENT ILA_AE_EVENT_inst1 (
    .clk                                (adc_clk                   ),// input wire clk
    
    
    .probe0                             (trig_pulse                ),// input wire [0:0]  probe0
    .probe1                             (capture_busy              ),// input wire [0:0]  probe1
    .probe2                             (event_wait_ddr            ),// input wire [0:0]  probe2
    .probe3                             (event_wait_upload         ),// input wire [0:0]  probe3
    .probe4                             (event_overflow            ),// input wire [0:0]  probe4
    .probe5                             (trigger_sample_index      ),// input wire [31:0]  probe5
    .probe6                             (ds_sample_valid_dbg       ),// input wire [0:0]  probe6
    .probe7                             (active_ch_mask_dbg        ),// input wire [15:0]  probe7
    .probe8                             (sample_rate_div_dbg       ),// input wire [15:0]  probe8
    .probe9                             (trig_threshold_dbg        ) // input wire [15:0]  probe9
    );
`endif
    // ------------------------------------------------------------------------
    // Compile-time checks by construction:
    // DATA_W must be MAX_CH*SAMPLE_W for ae_trigger_detect packing.
    // ------------------------------------------------------------------------
    localparam integer AXIS_KEEP_W = DATA_W / 8;
    localparam [2:0] FRAME_CODE_8192 = 3'd0;

    assign m_axis_tkeep = {AXIS_KEEP_W{1'b1}};

    // ------------------------------------------------------------------------
    // Internal UDP configuration synchronization
    // sys_clk ctrl_cfg_valid_pulse -> latch config -> adc_clk update pulse
    // ------------------------------------------------------------------------
    wire [15:0]          sample_rate_adc;
    wire [MAX_CH-1:0]    channel_en_adc;
    wire [SAMPLE_W-1:0]  ae_threshold_adc;
    wire                 cfg_update_adc_pulse;
    wire                 cap_en_adc;
    wire [MAX_CH-1:0]    active_ch_mask_eff;
    wire [MAX_CH-1:0]    trig_mask_eff;

    assign                              cap_en_adc                  = cap_en_out     && sync_ready && !sync_error;
    assign                              active_ch_mask_eff          = active_ch_mask & channel_en_adc;
    assign                              trig_mask_eff               = trig_mask      & channel_en_adc;

    ae_udp_cfg_sync #(
    .MAX_CH                             (MAX_CH                    ),
    .SAMPLE_W                           (SAMPLE_W                  ) 
    ) ae_udp_cfg_sync_inst (
    .sys_clk                            (sys_clk                   ),
    .adc_clk                            (adc_clk                   ),
    .reset_n                            (reset_n                   ),

    .ctrl_cfg_valid_pulse               (ctrl_cfg_valid_pulse      ),
    .sample_rate                        (sample_rate               ),
    .channel_en                         (channel_en                ),
    .ctrl_ae_threshold                  (ctrl_ae_threshold         ),

    .sample_rate_adc                    (sample_rate_adc           ),
    .channel_en_adc                     (channel_en_adc            ),
    .ae_threshold_adc                   (ae_threshold_adc          ),
    .cfg_update_adc_pulse               (cfg_update_adc_pulse      ) 
    );

    assign                              active_ch_mask_dbg          = active_ch_mask_eff   ;
    assign                              sample_rate_div_dbg         = sample_rate_adc      ;
    assign                              trig_threshold_dbg          = ae_threshold_adc     ;

// ------------------------------------------------------------------------
// upload_done_pulse sys_clk -> adc_clk
// ddr_commit_done_pulse sys_clk -> adc_clk
//
// 注意：ddr_commit_done_pulse 必须来自 ae_ddr_axis_event_buffer 的
// committed_event_pulse，而不是 stream_bank_release_pulse。
// stream_bank_release_pulse 只代表 AXI-stream bank 已经释放，不代表 DDR 写完。
// ------------------------------------------------------------------------
    wire                                upload_done_adc_pulse      ;
    wire                                ddr_write_done_adc_pulse   ;
    wire                                stream_bank_release_pulse  ;

// 调试输出：现在它代表真正 DDR commit，而不是 stream bank release。
    assign                              event_ddr_done_pulse        = ddr_commit_done_pulse;

ae_pulse_sync_toggle ae_upload_done_sync (
    .src_clk                            (sys_clk                   ),
    .dst_clk                            (adc_clk                   ),
    .reset_n                            (reset_n                   ),
    .src_pulse                          (upload_done_pulse         ),
    .dst_pulse                          (upload_done_adc_pulse     ) 
);

ae_pulse_sync_toggle ae_ddr_write_done_sync (
    .src_clk                            (sys_clk                   ),
    .dst_clk                            (adc_clk                   ),
    .reset_n                            (reset_n                   ),
    .src_pulse                          (ddr_commit_done_pulse     ),
    .dst_pulse                          (ddr_write_done_adc_pulse  ) 
);

    // ------------------------------------------------------------------------
    // Downsampler inside AE capture
    // ------------------------------------------------------------------------
    wire                  ds_sample_valid;
    wire [DATA_W-1:0]     ds_sample_data;
    wire [DATA_W-1:0]     ds_trigger_sample_data;

    ae_adc_data_downsampler #(
        .DATA_W           (DATA_W)
    ) ae_adc_data_downsampler_inst (
        .clk              (adc_clk),
        .reset_n          (reset_n),
        .enable           (cap_en_adc),
        .cfg_update_pulse (cfg_update_adc_pulse),
        .sample_rate_div  (sample_rate_adc),

        .sample_valid_in  (sample_valid),
        .sample_data_in   (sample_data),
        .trigger_data_in  (trigger_sample_data),

        .sample_valid_out (ds_sample_valid),
        .sample_data_out  (ds_sample_data),
        .trigger_data_out (ds_trigger_sample_data)
    );

    assign ds_sample_valid_dbg = ds_sample_valid;

    wire [DATA_W-1:0] ds_sample_data_masked;
    wire [DATA_W-1:0] ds_trigger_sample_data_masked;

    genvar ch_i;
    generate
        for (ch_i = 0; ch_i < MAX_CH; ch_i = ch_i + 1) begin : gen_channel_mask
            assign ds_sample_data_masked[ch_i*SAMPLE_W +: SAMPLE_W] =
                active_ch_mask_eff[ch_i] ?
                ds_sample_data[ch_i*SAMPLE_W +: SAMPLE_W] :
                {SAMPLE_W{1'b0}};

            assign ds_trigger_sample_data_masked[ch_i*SAMPLE_W +: SAMPLE_W] =
                active_ch_mask_eff[ch_i] ?
                ds_trigger_sample_data[ch_i*SAMPLE_W +: SAMPLE_W] :
                {SAMPLE_W{1'b0}};
        end
    endgenerate

    // ------------------------------------------------------------------------
    // Trigger detect using synced UDP config
    // ------------------------------------------------------------------------
    wire trigger_hit;

    ae_trigger_detect #(
        .MAX_CH           (MAX_CH),
        .SAMPLE_W         (SAMPLE_W)
    ) ae_trigger_detect_inst (
        .sample_data      (ds_trigger_sample_data_masked),
        .active_ch_mask   (active_ch_mask_eff),
        .trig_mask        (trig_mask_eff),
        .trig_threshold   (ae_threshold_adc),
        .trigger_hit      (trigger_hit)
    );

    // ------------------------------------------------------------------------
    // ADC-domain live ring / descriptor generation
    // ------------------------------------------------------------------------
    wire                         cap_ring_wr_en;
    wire [RING_AW-1:0]           cap_ring_wr_addr;
    wire                         cap_desc_wr_en;
    wire [DESC_W-1:0]            cap_desc_din;

    wire                         desc_fifo_full;
    wire                         desc_fifo_almost_full;
    wire                         desc_fifo_empty;
    wire                         desc_fifo_almost_empty;
    wire                         desc_fifo_wr_rst_busy;
    wire                         desc_fifo_rd_rst_busy;
    wire [DESC_W-1:0]            desc_fifo_dout;

    wire                         ring_rsta_busy;
    wire                         ring_rstb_busy;
    wire [DATA_W-1:0]            ring_doutb_sys;

    wire                         adc_path_ready;
    wire                         sys_path_ready;

    assign adc_path_ready = !ring_rsta_busy && !desc_fifo_wr_rst_busy;
    assign sys_path_ready = !ring_rstb_busy && !desc_fifo_rd_rst_busy;

    ae_cap_ctrl #(
        .MAX_CH           (MAX_CH),
        .FRAME_SAMPLES    (FRAME_SAMPLES),
        .PRE_SAMPLES      (PRE_SAMPLES),
        .RING_AW          (RING_AW),
        .DESC_W           (DESC_W)
    ) ae_cap_ctrl_inst (
        .adc_clk          (adc_clk),
        .reset_n          (reset_n),
        .adc_path_ready   (adc_path_ready),
        .cap_en           (cap_en_adc),
        .sample_valid     (ds_sample_valid),
        .trigger_hit      (trigger_hit),
        .active_ch_mask   (active_ch_mask_eff),
        .ddr_write_done_pulse_adc(ddr_write_done_adc_pulse),
        .upload_done_pulse_adc(upload_done_adc_pulse),
        .desc_fifo_full   (desc_fifo_full),

        .ring_wr_en       (cap_ring_wr_en),
        .ring_wr_addr     (cap_ring_wr_addr),
        .desc_wr_en       (cap_desc_wr_en),
        .desc_din         (cap_desc_din),
        .trig_pulse       (trig_pulse),
        .capture_busy     (capture_busy),
        .event_wait_ddr   (event_wait_ddr),
        .event_wait_upload(event_wait_upload),
        .event_overflow   (event_overflow),
        .trigger_sample_index(trigger_sample_index)
    );

    // ------------------------------------------------------------------------
    // Descriptor FIFO: adc_clk write -> rd_clk read
    // ------------------------------------------------------------------------
    wire copy_desc_rd_en;

    ae_desc_fifo_ip u_ae_desc_fifo_ip (
        .rst             (~reset_n),
        .wr_clk          (adc_clk),
        .rd_clk          (rd_clk),
        .din             (cap_desc_din),
        .wr_en           (cap_desc_wr_en),
        .rd_en           (copy_desc_rd_en),
        .dout            (desc_fifo_dout),
        .full            (desc_fifo_full),
        .almost_full     (desc_fifo_almost_full),
        .empty           (desc_fifo_empty),
        .almost_empty    (desc_fifo_almost_empty),
        .wr_rst_busy     (desc_fifo_wr_rst_busy),
        .rd_rst_busy     (desc_fifo_rd_rst_busy)
    );

    // ------------------------------------------------------------------------
    // Live ring BRAM:
    //   A port adc_clk write latency configured by IP, not used for douta.
    //   B port rd_clk read latency = LIVE_RING_RD_LATENCY, handled in copy ctrl.
    // ------------------------------------------------------------------------
    wire                         copy_ring_rd_en;
    wire [RING_AW-1:0]           copy_ring_rd_addr;

    ae_live_ring_bram ae_live_ring_bram_inst (
        .clka            (adc_clk),
        .rsta            (~reset_n),
        .ena             (1'b1),
        .wea             (cap_ring_wr_en),
        .addra           (cap_ring_wr_addr),
        .dina            (ds_sample_data_masked),
        .douta           (),

        .clkb            (rd_clk),
        .rstb            (~reset_n),
        .enb             (copy_ring_rd_en),
        .web             (1'b0),
        .addrb           (copy_ring_rd_addr),
        .dinb            ({DATA_W{1'b0}}),
        .doutb           (ring_doutb_sys),

        .rsta_busy       (ring_rsta_busy),
        .rstb_busy       (ring_rstb_busy)
    );

    // ------------------------------------------------------------------------
    // SYS-domain copy / bank / AXI stream
    // ------------------------------------------------------------------------
    wire                         copy_busy;
    wire                         copy_bank_sel;
    wire                         copy_bank_wr_en;
    wire                         copy_bank_wr_sel;
    wire [FRAME_AW-1:0]          copy_bank_wr_addr;
    wire [DATA_W-1:0]            copy_bank_wr_data;
    wire                         copy_bank_load_pulse;
    wire                         copy_bank_load_sel;
    wire [31:0]                  copy_bank_load_trig_idx;
    wire [MAX_CH-1:0]            copy_bank_load_ch_mask;

    wire                         stream_bank_rd_en;
    wire                         stream_bank_rd_sel;
    wire [FRAME_AW-1:0]          stream_bank_rd_addr;
    wire                         stream_bank_release_sel;

    wire [DATA_W-1:0]            bank0_doutb;
    wire [DATA_W-1:0]            bank1_doutb;

    reg                          bank0_ready;
    reg                          bank1_ready;
    reg [31:0]                   bank0_trig_idx;
    reg [31:0]                   bank1_trig_idx;
    reg [MAX_CH-1:0]             bank0_ch_mask;
    reg [MAX_CH-1:0]             bank1_ch_mask;

    wire                         bank0_free;
    wire                         bank1_free;

    assign bank0_free = !bank0_ready &&
                        !(copy_busy   && !copy_bank_sel) &&
                        !(stream_busy && !stream_bank_rd_sel);

    assign bank1_free = !bank1_ready &&
                        !(copy_busy   &&  copy_bank_sel) &&
                        !(stream_busy &&  stream_bank_rd_sel);

    assign bank_free_dbg = {bank1_free, bank0_free};

    ae_copy_ctrl #(
        .MAX_CH           (MAX_CH),
        .FRAME_SAMPLES    (FRAME_SAMPLES),
        .RING_AW          (RING_AW),
        .FRAME_AW         (FRAME_AW),
        .DESC_W           (DESC_W),
        .RING_RD_LATENCY  (LIVE_RING_RD_LATENCY)
    ) ae_copy_ctrl_inst (
        .sys_clk          (rd_clk),
        .reset_n          (reset_n),
        .sys_path_ready   (sys_path_ready),
        .desc_fifo_empty  (desc_fifo_empty),
        .desc_fifo_dout   (desc_fifo_dout),
        .ring_rd_data     (ring_doutb_sys),
        .bank0_free       (bank0_free),
        .bank1_free       (bank1_free),

        .desc_rd_en       (copy_desc_rd_en),
        .ring_rd_en       (copy_ring_rd_en),
        .ring_rd_addr     (copy_ring_rd_addr),
        .copy_busy        (copy_busy),
        .copy_bank_sel    (copy_bank_sel),
        .bank_wr_en       (copy_bank_wr_en),
        .bank_wr_sel      (copy_bank_wr_sel),
        .bank_wr_addr     (copy_bank_wr_addr),
        .bank_wr_data     (copy_bank_wr_data),
        .bank_load_pulse  (copy_bank_load_pulse),
        .bank_load_sel    (copy_bank_load_sel),
        .bank_load_trig_idx(copy_bank_load_trig_idx),
        .bank_load_ch_mask(copy_bank_load_ch_mask)
    );

    // Frame bank 0. B-port read latency = FRAME_BANK_RD_LATENCY.
    ae_frame_bank_bram ae_frame_bank_inst0 (
        .clka            (rd_clk),
        .rsta            (~reset_n),
        .ena             (copy_bank_wr_en && !copy_bank_wr_sel),
        .wea             (copy_bank_wr_en && !copy_bank_wr_sel),
        .addra           (copy_bank_wr_addr),
        .dina            (copy_bank_wr_data),
        .douta           (),

        .clkb            (rd_clk),
        .rstb            (~reset_n),
        .enb             (stream_bank_rd_en && !stream_bank_rd_sel),
        .web             (1'b0),
        .addrb           (stream_bank_rd_addr),
        .dinb            ({DATA_W{1'b0}}),
        .doutb           (bank0_doutb)
    );

    // Frame bank 1. B-port read latency = FRAME_BANK_RD_LATENCY.
    ae_frame_bank_bram ae_frame_bank_inst1 (
        .clka            (rd_clk),
        .rsta            (~reset_n),
        .ena             (copy_bank_wr_en && copy_bank_wr_sel),
        .wea             (copy_bank_wr_en && copy_bank_wr_sel),
        .addra           (copy_bank_wr_addr),
        .dina            (copy_bank_wr_data),
        .douta           (),

        .clkb            (rd_clk),
        .rstb            (~reset_n),
        .enb             (stream_bank_rd_en && stream_bank_rd_sel),
        .web             (1'b0),
        .addrb           (stream_bank_rd_addr),
        .dinb            ({DATA_W{1'b0}}),
        .doutb           (bank1_doutb)
    );

    ae_axis_stream_ctrl #(
        .MAX_CH           (MAX_CH),
        .DATA_W           (DATA_W),
        .FRAME_SAMPLES    (FRAME_SAMPLES),
        .FRAME_AW         (FRAME_AW),
        .AXIS_USER_W      (AXIS_USER_W),
        .FRAME_RD_LATENCY (FRAME_BANK_RD_LATENCY)
    ) ae_axis_stream_ctrl_inst (
        .sys_clk          (rd_clk),
        .reset_n          (reset_n),
        .sys_path_ready   (sys_path_ready),

        .m_axis_tvalid    (m_axis_tvalid),
        .m_axis_tready    (m_axis_tready),
        .m_axis_tdata     (m_axis_tdata),
        .m_axis_tlast     (m_axis_tlast),
        .m_axis_tuser     (m_axis_tuser),

        .bank0_ready      (bank0_ready),
        .bank1_ready      (bank1_ready),
        .bank0_ch_mask    (bank0_ch_mask),
        .bank1_ch_mask    (bank1_ch_mask),
        .bank0_trig_idx   (bank0_trig_idx),
        .bank1_trig_idx   (bank1_trig_idx),
        .bank0_rd_data    (bank0_doutb),
        .bank1_rd_data    (bank1_doutb),

        .bank_rd_en       (stream_bank_rd_en),
        .bank_rd_sel      (stream_bank_rd_sel),
        .bank_rd_addr     (stream_bank_rd_addr),
        .bank_release_pulse(stream_bank_release_pulse),
        .bank_release_sel (stream_bank_release_sel),
        .stream_busy      (stream_busy)
    );

    // Bank ready/free maintenance
    always @(posedge rd_clk or negedge reset_n) begin
        if (!reset_n) begin
            bank0_ready    <= 1'b0;
            bank1_ready    <= 1'b0;
            bank0_trig_idx <= 32'd0;
            bank1_trig_idx <= 32'd0;
            bank0_ch_mask  <= {MAX_CH{1'b0}};
            bank1_ch_mask  <= {MAX_CH{1'b0}};
        end
        else begin
            if (copy_bank_load_pulse && !copy_bank_load_sel) begin
                bank0_ready    <= 1'b1;
                bank0_trig_idx <= copy_bank_load_trig_idx;
                bank0_ch_mask  <= copy_bank_load_ch_mask;
            end
            else if (stream_bank_release_pulse && !stream_bank_release_sel) begin
                bank0_ready    <= 1'b0;
                bank0_trig_idx <= 32'd0;
                bank0_ch_mask  <= {MAX_CH{1'b0}};
            end

            if (copy_bank_load_pulse && copy_bank_load_sel) begin
                bank1_ready    <= 1'b1;
                bank1_trig_idx <= copy_bank_load_trig_idx;
                bank1_ch_mask  <= copy_bank_load_ch_mask;
            end
            else if (stream_bank_release_pulse && stream_bank_release_sel) begin
                bank1_ready    <= 1'b0;
                bank1_trig_idx <= 32'd0;
                bank1_ch_mask  <= {MAX_CH{1'b0}};
            end
        end
    end

    wire _unused_desc_afull  = desc_fifo_almost_full;
    wire _unused_desc_aempty = desc_fifo_almost_empty;

endmodule
