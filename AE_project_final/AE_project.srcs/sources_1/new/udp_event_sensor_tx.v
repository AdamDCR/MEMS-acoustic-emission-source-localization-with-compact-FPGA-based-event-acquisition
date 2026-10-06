`timescale 1ns / 1ps

`include "debug_cfg.vh"

module udp_event_sensor_tx #(
    parameter integer UDP_PKT_MAX_BYTES       = 1024,
    parameter integer SENSOR_PKT_BYTES        = 64,
    parameter integer EVENT_HDR_BYTES         = 128,
    parameter integer TRANSPORT_HDR_BYTES     = 32,
    // UDP 包间隔，单位 gmii_tx_clk 周期。
    // gmii_tx_clk = 125 MHz 时：
    // 12500 = 100 us
    // 25000 = 200 us
    // 6250  = 50 us
    parameter integer TX_INTER_PKT_GAP_CYCLES = 12500
)(
    input                               reset_n                    ,
    input                               sys_clk                    ,
    input                               gmii_tx_clk                ,
    input                               ae_ddr_ui_clk              ,

    input                               upload_req_pulse           ,
    input                               event_available            ,
    input                [  31: 0]      latest_event_seq           ,
    input                [  63: 0]      current_time_tag           ,
    input                [  15: 0]      sample_rate                ,
    input                [  15: 0]      channel_en                 ,
    input                [  15: 0]      ae_threshold               ,

    input                               ds18b20_valid              ,
    input                               ds18b20_present            ,
    input        signed  [  15: 0]      ds18b20_temp_raw_x16       ,
    input        signed  [  15: 0]      ds18b20_temp_centi         ,
    input                               aht20_valid                ,
    input                [  15: 0]      aht20_humi_centi           ,
    input        signed  [  15: 0]      aht20_temp_centi           ,
    input                               lsm6_valid                 ,
    input                               lsm6_ok                    ,
    input        signed  [  15: 0]      lsm6_gx_raw                ,
    input        signed  [  15: 0]      lsm6_gy_raw                ,
    input        signed  [  15: 0]      lsm6_gz_raw                ,

    output                              ae_rd_req                  ,
    output               [  31: 0]      ae_rd_event_seq            ,
    input                               ae_rd_busy                 ,
    input                               ae_rd_found                ,
    input                               ae_rd_valid                ,
    output                              ae_rd_ready                ,
    input                               ae_rd_sop                  ,
    input                               ae_rd_eop                  ,
    input                [ 255: 0]      ae_rd_data                 ,

    input                               tx_req                     ,
    input                               tx_done                    ,

    // 宽泛完成脉冲：表示本次回传事务的数据已经全部进入 TX FIFO。
    // 不建议再用它释放 AE 捕获状态。
    output reg                          upload_done_pulse          ,

    // 严格事件完成脉冲：真实 AE 事件事务结束后拉高。
    // upload_done_event_ok=1：DDR 读回成功，最后一个 AE 数据包 tx_done。
    // upload_done_event_ok=0：DDR read fail/timeout 错误回包 tx_done。
    // sensor-only 包不会拉高该事件完成脉冲。
    output reg                          upload_done_event_pulse    ,
    output reg           [  31: 0]      upload_done_event_seq      ,
    output reg                          upload_done_event_ok       ,

    output                              tx_start_en                ,
    output               [   7: 0]      tx_data                    ,
    output               [  15: 0]      tx_byte_num                ,
    output               [  31: 0]      tx_dbg_status
);

    localparam integer UNIFIED_HDR_BYTES        = TRANSPORT_HDR_BYTES + SENSOR_PKT_BYTES + EVENT_HDR_BYTES;
    localparam integer AE_PAYLOAD_BYTES_MAX     = UDP_PKT_MAX_BYTES - UNIFIED_HDR_BYTES;
    localparam                          [  15: 0]      UNIFIED_HDR_BYTES_U16       = UNIFIED_HDR_BYTES    ;
    localparam                          [  15: 0]      AE_PAYLOAD_BYTES_MAX_U16    = AE_PAYLOAD_BYTES_MAX ;
    localparam                          [  31: 0]      EVENT_HDR_BYTES_U32         = EVENT_HDR_BYTES      ;

    localparam                          [   3: 0]      SYS_IDLE                    = 4'd0                 ;
    localparam                          [   3: 0]      SYS_COLLECT_HDR             = 4'd1                 ;
    localparam                          [   3: 0]      SYS_PREP_PKT                = 4'd2                 ;
    localparam                          [   3: 0]      SYS_PKT_META                = 4'd3                 ;
    localparam                          [   3: 0]      SYS_PKT_SENSOR              = 4'd4                 ;
    localparam                          [   3: 0]      SYS_PKT_EVT_HDR             = 4'd5                 ;
    localparam                          [   3: 0]      SYS_PKT_PAYLOAD             = 4'd6                 ;
    localparam                          [   3: 0]      SYS_PKT_COMMIT              = 4'd7                 ;
    localparam                          [  31: 0]      SYS_READ_TIMEOUT_CYCLES     = 32'd200_000_000      ;

    // ------------------------------------------------------------------
    // sys_clk -> ae_ddr_ui_clk request FIFO
    // ------------------------------------------------------------------
    reg                                 req_fifo_wr_en_sys         ;
    reg                  [  31: 0]      req_fifo_din_sys           ;
    wire                                req_fifo_full_sys          ;

    wire                 [  31: 0]      req_fifo_dout_ui           ;
    wire                                req_fifo_empty_ui          ;
    reg                                 req_fifo_rd_en_ui          ;

    reg                                 ae_rd_req_ui               ;
    reg                  [  31: 0]      ae_rd_event_seq_ui         ;
    reg                                 req_issue_pending_ui       ;
    reg                  [   2: 0]      ui_hdr_word_count          ;
    reg                  [ 255: 0]      ui_hdr_word0               ;
    reg                  [ 255: 0]      ui_hdr_word1               ;
    reg                  [ 255: 0]      ui_hdr_word2               ;
    reg                  [ 255: 0]      ui_hdr_word3               ;
    reg                                 ui_hdr_toggle              ;
    reg                                 ui_rd_active               ;
    reg                                 ui_rd_busy_seen            ;
    reg                                 ui_rd_found_seen           ;
    reg                                 ui_rd_fail_toggle          ;

    assign                              ae_rd_req                   = ae_rd_req_ui         ;
    assign                              ae_rd_event_seq             = ae_rd_event_seq_ui   ;

    // ------------------------------------------------------------------
    // ae_ddr_ui_clk -> sys_clk event payload FIFO
    // din[257] = sop, din[256] = eop, din[255:0] = data
    // ------------------------------------------------------------------
    wire                                evt_in_fifo_full_ui        ;
    wire                                evt_in_fifo_prog_full_ui   ;
    reg                                 evt_in_fifo_wr_en_ui       ;
    reg                  [ 257: 0]      evt_in_fifo_din_ui         ;

    assign                              ae_rd_ready                 = !evt_in_fifo_full_ui && !evt_in_fifo_prog_full_ui;

    wire                 [ 257: 0]      evt_in_fifo_dout_sys       ;
    wire                                evt_in_fifo_empty_sys      ;
    reg                                 evt_in_fifo_rd_en_sys      ;

    // ------------------------------------------------------------------
    // sys_clk -> gmii_tx_clk output packet FIFO group
    // byte FIFO stores payload bytes.
    // len FIFO stores each UDP payload length.
    // meta FIFO stores packet attributes aligned with len FIFO.
    // meta[34] = is real AE event transaction
    //            1 for normal AE upload, and also 1 for DDR-read-fail/timeout
    //            response of a requested AE event.
    // meta[33] = is last packet of this AE event transaction
    // meta[32] = event_ok. 1 = event DDR read/upload succeeded;
    //            0 = DDR read fail/timeout response.
    // meta[31:0] = event sequence
    // ------------------------------------------------------------------
    reg                                 out_byte_fifo_wr_en_sys    ;
    reg                  [   7: 0]      out_byte_fifo_din_sys      ;
    reg                                 pkt_byte_valid_sys         ;
    reg                  [   7: 0]      pkt_byte_data_sys          ;
    wire                                out_byte_fifo_full_sys     ;
    wire                                out_byte_fifo_prog_full_sys ;

    wire                 [   7: 0]      out_byte_fifo_dout_tx      ;
    wire                                out_byte_fifo_empty_tx     ;
    wire                                out_byte_fifo_data_valid_tx ;
    wire                                out_byte_fifo_rd_en_tx     ;
    wire                 [  13: 0]      out_byte_fifo_rd_count_tx  ;
    wire                 [  15: 0]      out_byte_fifo_rd_count_tx_ext;
    wire                                out_byte_fifo_write_ready_sys;
    wire                                out_packet_ready_tx        ;

    reg                                 out_len_fifo_wr_en_sys     ;
    reg                  [  15: 0]      out_len_fifo_din_sys       ;
    wire                                out_len_fifo_full_sys      ;

    wire                 [  15: 0]      out_len_fifo_dout_tx       ;
    wire                                out_len_fifo_empty_tx      ;
    reg                                 out_len_fifo_rd_en_tx      ;

    reg                                 out_meta_fifo_wr_en_sys    ;
    reg                  [  34: 0]      out_meta_fifo_din_sys      ;
    wire                                out_meta_fifo_full_sys     ;

    wire                 [  34: 0]      out_meta_fifo_dout_tx      ;
    wire                                out_meta_fifo_empty_tx     ;
    reg                                 out_meta_fifo_rd_en_tx     ;

    // ------------------------------------------------------------------
    // sys_clk state machine registers
    // ------------------------------------------------------------------
    reg                  [   3: 0]      sys_state                  ;
    reg                  [   3: 0]      sys_state_nxt              ;
    reg                                 pending_event              ;
    reg                                 pending_event_has_data     ;
    // Set when the current output packet is the failure response of a real AE upload.
    // This lets the TX side generate upload_done_event_pulse with ok=0 after
    // the error/empty-event packet has actually been transmitted.
    reg                                 pending_event_fail_response;
    reg                                 evt_packet_is_event_txn    ;
    reg                                 evt_packet_event_ok        ;

    reg                                 ui_hdr_toggle_meta1        ;
    reg                                 ui_hdr_toggle_meta2        ;
    reg                                 ui_hdr_toggle_meta2_d      ;
    reg                                 ui_rd_fail_toggle_meta1    ;
    reg                                 ui_rd_fail_toggle_meta2    ;
    reg                                 ui_rd_fail_toggle_meta2_d  ;
    reg                  [  31: 0]      sys_read_wait_cnt          ;
    wire                                sys_read_fail_or_timeout    ;

    reg                  [ 255: 0]      ui_hdr_word0_meta1         ;
    reg                  [ 255: 0]      ui_hdr_word1_meta1         ;
    reg                  [ 255: 0]      ui_hdr_word2_meta1         ;
    reg                  [ 255: 0]      ui_hdr_word3_meta1         ;
    reg                  [ 255: 0]      ui_hdr_word0_meta2         ;
    reg                  [ 255: 0]      ui_hdr_word1_meta2         ;
    reg                  [ 255: 0]      ui_hdr_word2_meta2         ;
    reg                  [ 255: 0]      ui_hdr_word3_meta2         ;

    reg                                 sensor_ds18b20_valid       ;
    reg                                 sensor_ds18b20_present     ;
    reg     signed       [  15: 0]      sensor_ds18b20_temp_raw_x16;
    reg     signed       [  15: 0]      sensor_ds18b20_temp_centi  ;
    reg                                 sensor_aht20_valid         ;
    reg                  [  15: 0]      sensor_aht20_humi_centi    ;
    reg     signed       [  15: 0]      sensor_aht20_temp_centi    ;
    reg                                 sensor_lsm6_valid          ;
    reg                                 sensor_lsm6_ok             ;
    reg     signed       [  15: 0]      sensor_lsm6_gx_raw         ;
    reg     signed       [  15: 0]      sensor_lsm6_gy_raw         ;
    reg     signed       [  15: 0]      sensor_lsm6_gz_raw         ;
    reg                  [  63: 0]      sensor_time_tag            ;
    reg                  [  15: 0]      sensor_sample_rate         ;
    reg                  [  15: 0]      sensor_channel_en          ;
    reg                  [  15: 0]      sensor_ae_threshold        ;
    reg                  [  31: 0]      sensor_latest_event_seq    ;
    reg                  [   6: 0]      sensor_byte_idx            ;

    reg                  [   2: 0]      evt_header_words_collected ;
    reg                  [   7: 0]      evt_header_bytes[0:EVENT_HDR_BYTES-1];
    reg                  [   7: 0]      evt_stream_bytes[0:31]     ;
    reg                                 evt_stream_word_valid      ;
    reg                  [   5: 0]      evt_stream_word_byte_idx   ;
    reg                  [  31: 0]      evt_event_seq              ;
    reg                  [  31: 0]      evt_total_bytes            ;
    reg                  [  31: 0]      evt_payload_total_bytes    ;
    reg                  [  31: 0]      evt_payload_remaining      ;
    reg                  [  31: 0]      evt_payload_offset         ;
    reg                  [  31: 0]      evt_packet_count_calc_remaining;
    reg                  [  15: 0]      evt_packet_count           ;
    reg                  [  15: 0]      evt_packet_index           ;
    reg                  [  15: 0]      evt_packet_payload_bytes   ;
    reg                  [  15: 0]      evt_packet_payload_written ;
    reg                  [   5: 0]      evt_meta_byte_idx          ;
    reg                  [   7: 0]      evt_header_byte_idx        ;
    reg                  [  15: 0]      evt_commit_len             ;
    reg                                 evt_first_flag             ;
    reg                                 evt_last_flag              ;

    // ------------------------------------------------------------------
    // gmii_tx_clk registers
    // ------------------------------------------------------------------
    reg                                 tx_busy                    ;
    reg                                 tx_start_en_reg            ;
    reg                  [  15: 0]      tx_len_reg                 ;
    reg                  [  15: 0]      tx_pop_count               ;
    reg                  [   7: 0]      tx_data_reg                ;
    reg                                 tx_req_seen                ;
    reg                                 tx_underflow_seen          ;
    reg                                 tx_pkt_is_event            ;
    reg                                 tx_pkt_is_last             ;
    reg                                 tx_pkt_event_ok            ;
    reg                  [  31: 0]      tx_pkt_event_seq           ;
    reg                                 event_done_toggle_tx       ;
    reg                  [  31: 0]      event_done_seq_tx          ;
    reg                                 event_done_ok_tx           ;
    reg                  [  31: 0]      tx_gap_cnt                 ;

    wire                                tx_gap_done                ;
    assign                              tx_gap_done                 = (tx_gap_cnt == 32'd0);
    // tx_done event sync back to sys_clk
    (* ASYNC_REG = "TRUE" *) reg        event_done_toggle_sys_m    ;
    (* ASYNC_REG = "TRUE" *) reg        event_done_toggle_sys_s    ;
    reg                                 event_done_toggle_sys_d    ;
    reg                  [  31: 0]      event_done_seq_sys_m       ;
    reg                  [  31: 0]      event_done_seq_sys_s       ;
    reg                                 event_done_ok_sys_m        ;
    reg                                 event_done_ok_sys_s        ;

    integer                             i                          ;
    reg                  [  31: 0]      tmp32                      ;

    assign                              tx_start_en                 = tx_start_en_reg      ;
    assign                              tx_byte_num                 = tx_len_reg           ;
    assign                              tx_data                     = out_byte_fifo_dout_tx;

    assign                              out_byte_fifo_rd_en_tx      = tx_busy && tx_req &&
                                                                      !out_byte_fifo_empty_tx &&
                                                                      (tx_pop_count < tx_len_reg);
    assign                              out_byte_fifo_rd_count_tx_ext = {2'b00, out_byte_fifo_rd_count_tx};
    assign                              out_byte_fifo_write_ready_sys = !out_byte_fifo_full_sys && !out_byte_fifo_prog_full_sys;

    assign                              out_packet_ready_tx          = !out_len_fifo_empty_tx  &&
                                                                      !out_meta_fifo_empty_tx &&
                                                                      (out_byte_fifo_rd_count_tx_ext >= out_len_fifo_dout_tx);

    assign tx_dbg_status = {
        tx_busy,
        tx_start_en_reg,
        tx_req,
        tx_done,
        out_len_fifo_empty_tx,
        out_len_fifo_rd_en_tx,
        tx_underflow_seen,
        out_byte_fifo_rd_en_tx,
        out_byte_fifo_data_valid_tx,
        tx_req_seen,
        tx_len_reg,
        tx_pop_count[5:0]
    };

    assign sys_read_fail_or_timeout =
        (ui_rd_fail_toggle_meta2 != ui_rd_fail_toggle_meta2_d) ||
        (sys_read_wait_cnt >= SYS_READ_TIMEOUT_CYCLES);

    function [31:0] sensor_word;
        input [3:0] idx;
        reg [31:0] flags_word;
        begin
            flags_word = 32'd0;
            flags_word[0] = sensor_ds18b20_valid;
            flags_word[1] = sensor_ds18b20_present;
            flags_word[2] = sensor_aht20_valid;
            flags_word[3] = sensor_lsm6_valid;
            flags_word[4] = sensor_lsm6_ok;
            case (idx)
                4'd0 : sensor_word = 32'h534E_5352;                 // SNSR
                4'd1 : sensor_word = {16'h0001, 16'd64};
                4'd2 : sensor_word = sensor_latest_event_seq;
                4'd3 : sensor_word = flags_word;
                4'd4 : sensor_word = {sensor_ds18b20_temp_raw_x16, sensor_ds18b20_temp_centi};
                4'd5 : sensor_word = {sensor_aht20_humi_centi, sensor_aht20_temp_centi};
                4'd6 : sensor_word = {sensor_lsm6_gx_raw, sensor_lsm6_gy_raw};
                4'd7 : sensor_word = {sensor_lsm6_gz_raw, 16'd0};
                4'd8 : sensor_word = {sensor_time_tag[63:48], 4'd0, sensor_time_tag[47:44], 3'd0, sensor_time_tag[43:39]};
                4'd9 : sensor_word = {3'd0, sensor_time_tag[38:34], 2'd0, sensor_time_tag[33:28], 2'd0, sensor_time_tag[27:22], 8'd0};
                4'd10: sensor_word = sensor_time_tag[63:32];
                4'd11: sensor_word = sensor_time_tag[31:0];
                4'd12: sensor_word = {sensor_sample_rate, sensor_channel_en};
                4'd13: sensor_word = {16'd0, sensor_ae_threshold};
                4'd14: sensor_word = 32'd0;
                4'd15: sensor_word = 32'h454E_4421;                 // END!
                default: sensor_word = 32'd0;
            endcase
        end
    endfunction

    function [31:0] unified_hdr_word;
        input [2:0] idx;
        reg [15:0] flags_word;
        begin
            flags_word = 16'd0;
            flags_word[0] = evt_first_flag;
            flags_word[1] = evt_last_flag;
            case (idx)
                3'd0: unified_hdr_word = 32'h4145_5550;             // AEUP
                3'd1: unified_hdr_word = {16'h0001, UNIFIED_HDR_BYTES_U16};
                3'd2: unified_hdr_word = evt_event_seq;
                3'd3: unified_hdr_word = {evt_packet_index, evt_packet_count};
                3'd4: unified_hdr_word = evt_payload_offset;
                3'd5: unified_hdr_word = {evt_packet_payload_bytes, flags_word};
                3'd6: unified_hdr_word = evt_total_bytes;
                3'd7: unified_hdr_word = evt_payload_total_bytes;
                default: unified_hdr_word = 32'd0;
            endcase
        end
    endfunction

    function [7:0] be_word_byte;
        input [31:0] word_in;
        input [1:0]  byte_idx;
        begin
            case (byte_idx)
                2'd0: be_word_byte = word_in[31:24];
                2'd1: be_word_byte = word_in[23:16];
                2'd2: be_word_byte = word_in[15:8];
                default: be_word_byte = word_in[7:0];
            endcase
        end
    endfunction

    function [15:0] min16;
        input [31:0] value_in;
        input [15:0] max_in;
        begin
            if (value_in[31:16] != 16'd0) begin
                min16 = max_in;
            end else if (value_in[15:0] > max_in) begin
                min16 = max_in;
            end else begin
                min16 = value_in[15:0];
            end
        end
    endfunction

    // ------------------------------------------------------------------
    // FIFO instances
    // ------------------------------------------------------------------
    xpm_fifo_async #(
        .CDC_SYNC_STAGES                    (2                         ),
        .DOUT_RESET_VALUE                   ("0"                       ),
        .ECC_MODE                           ("no_ecc"                  ),
        .FIFO_MEMORY_TYPE                   ("auto"                    ),
        .FIFO_READ_LATENCY                  (0                         ),
        .FIFO_WRITE_DEPTH                   (16                        ),
        .FULL_RESET_VALUE                   (0                         ),
        .PROG_EMPTY_THRESH                  (2                         ),
        .PROG_FULL_THRESH                   (12                        ),
        .RD_DATA_COUNT_WIDTH                (1                         ),
        .READ_DATA_WIDTH                    (32                        ),
        .READ_MODE                          ("fwft"                    ),
        .RELATED_CLOCKS                     (0                         ),
        .SIM_ASSERT_CHK                     (0                         ),
        .USE_ADV_FEATURES                   ("0000"                    ),
        .WAKEUP_TIME                        (0                         ),
        .WRITE_DATA_WIDTH                   (32                        ),
        .WR_DATA_COUNT_WIDTH                (1                         )
    ) u_req_fifo (
        .almost_empty                       (                          ),
        .almost_full                        (                          ),
        .data_valid                         (                          ),
        .dbiterr                            (                          ),
        .dout                               (req_fifo_dout_ui          ),
        .empty                              (req_fifo_empty_ui         ),
        .full                               (req_fifo_full_sys         ),
        .overflow                           (                          ),
        .prog_empty                         (                          ),
        .prog_full                          (                          ),
        .rd_data_count                      (                          ),
        .rd_rst_busy                        (                          ),
        .sbiterr                            (                          ),
        .underflow                          (                          ),
        .wr_ack                             (                          ),
        .wr_data_count                      (                          ),
        .wr_rst_busy                        (                          ),
        .din                                (req_fifo_din_sys          ),
        .injectdbiterr                      (1'b0                      ),
        .injectsbiterr                      (1'b0                      ),
        .rd_clk                             (ae_ddr_ui_clk             ),
        .rd_en                              (req_fifo_rd_en_ui         ),
        .rst                                (~reset_n                  ),
        .sleep                              (1'b0                      ),
        .wr_clk                             (sys_clk                   ),
        .wr_en                              (req_fifo_wr_en_sys        )
    );

    xpm_fifo_async #(
        .CDC_SYNC_STAGES                    (2                         ),
        .DOUT_RESET_VALUE                   ("0"                       ),
        .ECC_MODE                           ("no_ecc"                  ),
        .FIFO_MEMORY_TYPE                   ("block"                   ),
        .FIFO_READ_LATENCY                  (0                         ),
        .FIFO_WRITE_DEPTH                   (256                       ),
        .FULL_RESET_VALUE                   (0                         ),
        .PROG_EMPTY_THRESH                  (8                         ),
        .PROG_FULL_THRESH                   (220                       ),
        .RD_DATA_COUNT_WIDTH                (1                         ),
        .READ_DATA_WIDTH                    (258                       ),
        .READ_MODE                          ("fwft"                    ),
        .RELATED_CLOCKS                     (0                         ),
        .SIM_ASSERT_CHK                     (0                         ),
        .USE_ADV_FEATURES                   ("0002"                    ),
        .WAKEUP_TIME                        (0                         ),
        .WRITE_DATA_WIDTH                   (258                       ),
        .WR_DATA_COUNT_WIDTH                (1                         )
    ) u_evt_word_fifo (
        .almost_empty                       (                          ),
        .almost_full                        (                          ),
        .data_valid                         (                          ),
        .dbiterr                            (                          ),
        .dout                               (evt_in_fifo_dout_sys      ),
        .empty                              (evt_in_fifo_empty_sys     ),
        .full                               (evt_in_fifo_full_ui       ),
        .overflow                           (                          ),
        .prog_empty                         (                          ),
        .prog_full                          (evt_in_fifo_prog_full_ui  ),
        .rd_data_count                      (                          ),
        .rd_rst_busy                        (                          ),
        .sbiterr                            (                          ),
        .underflow                          (                          ),
        .wr_ack                             (                          ),
        .wr_data_count                      (                          ),
        .wr_rst_busy                        (                          ),
        .din                                (evt_in_fifo_din_ui        ),
        .injectdbiterr                      (1'b0                      ),
        .injectsbiterr                      (1'b0                      ),
        .rd_clk                             (sys_clk                   ),
        .rd_en                              (evt_in_fifo_rd_en_sys     ),
        .rst                                (~reset_n                  ),
        .sleep                              (1'b0                      ),
        .wr_clk                             (ae_ddr_ui_clk             ),
        .wr_en                              (evt_in_fifo_wr_en_ui      )
    );

    xpm_fifo_async #(
        .CDC_SYNC_STAGES                    (2                         ),
        .DOUT_RESET_VALUE                   ("0"                       ),
        .ECC_MODE                           ("no_ecc"                  ),
        .FIFO_MEMORY_TYPE                   ("block"                   ),
        .FIFO_READ_LATENCY                  (0                         ),
        .FIFO_WRITE_DEPTH                   (8192                      ),
        .FULL_RESET_VALUE                   (0                         ),
        .PROG_EMPTY_THRESH                  (32                        ),
        .PROG_FULL_THRESH                   (7800                      ),
        .RD_DATA_COUNT_WIDTH                (14                        ),
        .READ_DATA_WIDTH                    (8                         ),
        .READ_MODE                          ("fwft"                    ),
        .RELATED_CLOCKS                     (0                         ),
        .SIM_ASSERT_CHK                     (0                         ),
        .USE_ADV_FEATURES                   ("1402"                    ),
        .WAKEUP_TIME                        (0                         ),
        .WRITE_DATA_WIDTH                   (8                         ),
        .WR_DATA_COUNT_WIDTH                (1                         )
    ) u_out_byte_fifo (
        .almost_empty                       (                          ),
        .almost_full                        (                          ),
        .data_valid                         (out_byte_fifo_data_valid_tx),
        .dbiterr                            (                          ),
        .dout                               (out_byte_fifo_dout_tx     ),
        .empty                              (out_byte_fifo_empty_tx    ),
        .full                               (out_byte_fifo_full_sys    ),
        .overflow                           (                          ),
        .prog_empty                         (                          ),
        .prog_full                          (out_byte_fifo_prog_full_sys),
        .rd_data_count                      (out_byte_fifo_rd_count_tx ),
        .rd_rst_busy                        (                          ),
        .sbiterr                            (                          ),
        .underflow                          (                          ),
        .wr_ack                             (                          ),
        .wr_data_count                      (                          ),
        .wr_rst_busy                        (                          ),
        .din                                (out_byte_fifo_din_sys     ),
        .injectdbiterr                      (1'b0                      ),
        .injectsbiterr                      (1'b0                      ),
        .rd_clk                             (gmii_tx_clk               ),
        .rd_en                              (out_byte_fifo_rd_en_tx    ),
        .rst                                (~reset_n                  ),
        .sleep                              (1'b0                      ),
        .wr_clk                             (sys_clk                   ),
        .wr_en                              (out_byte_fifo_wr_en_sys   )
    );

    xpm_fifo_async #(
        .CDC_SYNC_STAGES                    (2                         ),
        .DOUT_RESET_VALUE                   ("0"                       ),
        .ECC_MODE                           ("no_ecc"                  ),
        .FIFO_MEMORY_TYPE                   ("auto"                    ),
        .FIFO_READ_LATENCY                  (0                         ),
        .FIFO_WRITE_DEPTH                   (64                        ),
        .FULL_RESET_VALUE                   (0                         ),
        .PROG_EMPTY_THRESH                  (2                         ),
        .PROG_FULL_THRESH                   (60                        ),
        .RD_DATA_COUNT_WIDTH                (1                         ),
        .READ_DATA_WIDTH                    (16                        ),
        .READ_MODE                          ("fwft"                    ),
        .RELATED_CLOCKS                     (0                         ),
        .SIM_ASSERT_CHK                     (0                         ),
        .USE_ADV_FEATURES                   ("0000"                    ),
        .WAKEUP_TIME                        (0                         ),
        .WRITE_DATA_WIDTH                   (16                        ),
        .WR_DATA_COUNT_WIDTH                (1                         )
    ) u_out_len_fifo (
        .almost_empty                       (                          ),
        .almost_full                        (                          ),
        .data_valid                         (                          ),
        .dbiterr                            (                          ),
        .dout                               (out_len_fifo_dout_tx      ),
        .empty                              (out_len_fifo_empty_tx     ),
        .full                               (out_len_fifo_full_sys     ),
        .overflow                           (                          ),
        .prog_empty                         (                          ),
        .prog_full                          (                          ),
        .rd_data_count                      (                          ),
        .rd_rst_busy                        (                          ),
        .sbiterr                            (                          ),
        .underflow                          (                          ),
        .wr_ack                             (                          ),
        .wr_data_count                      (                          ),
        .wr_rst_busy                        (                          ),
        .din                                (out_len_fifo_din_sys      ),
        .injectdbiterr                      (1'b0                      ),
        .injectsbiterr                      (1'b0                      ),
        .rd_clk                             (gmii_tx_clk               ),
        .rd_en                              (out_len_fifo_rd_en_tx     ),
        .rst                                (~reset_n                  ),
        .sleep                              (1'b0                      ),
        .wr_clk                             (sys_clk                   ),
        .wr_en                              (out_len_fifo_wr_en_sys    )
    );

    xpm_fifo_async #(
        .CDC_SYNC_STAGES                    (2                         ),
        .DOUT_RESET_VALUE                   ("0"                       ),
        .ECC_MODE                           ("no_ecc"                  ),
        .FIFO_MEMORY_TYPE                   ("auto"                    ),
        .FIFO_READ_LATENCY                  (0                         ),
        .FIFO_WRITE_DEPTH                   (64                        ),
        .FULL_RESET_VALUE                   (0                         ),
        .PROG_EMPTY_THRESH                  (2                         ),
        .PROG_FULL_THRESH                   (60                        ),
        .RD_DATA_COUNT_WIDTH                (1                         ),
        .READ_DATA_WIDTH                    (35                        ),
        .READ_MODE                          ("fwft"                    ),
        .RELATED_CLOCKS                     (0                         ),
        .SIM_ASSERT_CHK                     (0                         ),
        .USE_ADV_FEATURES                   ("0000"                    ),
        .WAKEUP_TIME                        (0                         ),
        .WRITE_DATA_WIDTH                   (35                        ),
        .WR_DATA_COUNT_WIDTH                (1                         )
    ) u_out_meta_fifo (
        .almost_empty                       (                          ),
        .almost_full                        (                          ),
        .data_valid                         (                          ),
        .dbiterr                            (                          ),
        .dout                               (out_meta_fifo_dout_tx     ),
        .empty                              (out_meta_fifo_empty_tx    ),
        .full                               (out_meta_fifo_full_sys    ),
        .overflow                           (                          ),
        .prog_empty                         (                          ),
        .prog_full                          (                          ),
        .rd_data_count                      (                          ),
        .rd_rst_busy                        (                          ),
        .sbiterr                            (                          ),
        .underflow                          (                          ),
        .wr_ack                             (                          ),
        .wr_data_count                      (                          ),
        .wr_rst_busy                        (                          ),
        .din                                (out_meta_fifo_din_sys     ),
        .injectdbiterr                      (1'b0                      ),
        .injectsbiterr                      (1'b0                      ),
        .rd_clk                             (gmii_tx_clk               ),
        .rd_en                              (out_meta_fifo_rd_en_tx    ),
        .rst                                (~reset_n                  ),
        .sleep                              (1'b0                      ),
        .wr_clk                             (sys_clk                   ),
        .wr_en                              (out_meta_fifo_wr_en_sys   )
    );

    // ------------------------------------------------------------------
    // DDR UI clock domain: issue read requests and push read payload into FIFO
    // ------------------------------------------------------------------
    always @(posedge ae_ddr_ui_clk) begin
        if (!reset_n) begin
            req_fifo_rd_en_ui    <= 1'b0;
            ae_rd_req_ui         <= 1'b0;
            ae_rd_event_seq_ui   <= 32'd0;
            req_issue_pending_ui <= 1'b0;
            ui_hdr_word_count    <= 3'd0;
            ui_hdr_word0         <= 256'd0;
            ui_hdr_word1         <= 256'd0;
            ui_hdr_word2         <= 256'd0;
            ui_hdr_word3         <= 256'd0;
            ui_hdr_toggle        <= 1'b0;
            ui_rd_active         <= 1'b0;
            ui_rd_busy_seen      <= 1'b0;
            ui_rd_found_seen     <= 1'b0;
            ui_rd_fail_toggle    <= 1'b0;
            evt_in_fifo_wr_en_ui <= 1'b0;
            evt_in_fifo_din_ui   <= 258'd0;
        end else begin
            req_fifo_rd_en_ui     <= 1'b0;
            ae_rd_req_ui          <= 1'b0;
            evt_in_fifo_wr_en_ui  <= 1'b0;

            if (req_issue_pending_ui) begin
                ae_rd_req_ui         <= 1'b1;
                req_fifo_rd_en_ui    <= 1'b1;
                req_issue_pending_ui <= 1'b0;
                ui_rd_active         <= 1'b1;
                ui_rd_busy_seen      <= 1'b0;
                ui_rd_found_seen     <= 1'b0;
            end else if (!req_fifo_empty_ui && !ae_rd_busy) begin
                ae_rd_event_seq_ui   <= req_fifo_dout_ui;
                req_issue_pending_ui <= 1'b1;
                ui_hdr_word_count    <= 3'd0;
            end

            if (ui_rd_active) begin
                if (ae_rd_found) begin
                    ui_rd_found_seen <= 1'b1;
                end

                if (ae_rd_busy) begin
                    ui_rd_busy_seen <= 1'b1;
                end else if (ui_rd_busy_seen) begin
                    ui_rd_active    <= 1'b0;
                    ui_rd_busy_seen <= 1'b0;
                    if (!(ui_rd_found_seen || ae_rd_found) || (ui_hdr_word_count < 3'd4)) begin
                        ui_rd_fail_toggle <= ~ui_rd_fail_toggle;
                    end
                end
            end

            if (ae_rd_valid && ae_rd_ready) begin
                if (ui_hdr_word_count < 3'd4) begin
                    case (ui_hdr_word_count)
                        3'd0: ui_hdr_word0 <= ae_rd_data;
                        3'd1: ui_hdr_word1 <= ae_rd_data;
                        3'd2: ui_hdr_word2 <= ae_rd_data;
                        3'd3: begin
                            ui_hdr_word3  <= ae_rd_data;
                            ui_hdr_toggle <= ~ui_hdr_toggle;
                        end
                        default: begin
                        end
                    endcase
                    ui_hdr_word_count <= ui_hdr_word_count + 1'b1;
                end else if (!evt_in_fifo_full_ui) begin
                    evt_in_fifo_wr_en_ui <= 1'b1;
                    evt_in_fifo_din_ui   <= {ae_rd_sop, ae_rd_eop, ae_rd_data};
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // sys_clk packet builder FSM, three-block style
    // ------------------------------------------------------------------
    // Block 1: next-state combinational logic.
    // Only state transitions are described here. All datapath and pulse
    // generation are kept in Block 3, so the packet flow is easier to read.
    always @(*) begin
        sys_state_nxt = sys_state;

        // DDR read failure or read timeout is a global recovery path. It
        // builds a sensor + empty event packet. If the failed transaction was
        // a real AE event upload, the packet meta marks event_ok=0 so top can
        // release or retry according to policy.
        if (sys_read_fail_or_timeout) begin
            sys_state_nxt = SYS_PKT_META;
        end else begin
            case (sys_state)
                SYS_IDLE: begin
                    if (pending_event) begin
                        if (pending_event_has_data) begin
                            sys_state_nxt = SYS_COLLECT_HDR;
                        end else begin
                            sys_state_nxt = SYS_PKT_META;
                        end
                    end
                end

                SYS_COLLECT_HDR: begin
                    if (evt_header_words_collected >= 3'd4) begin
                        sys_state_nxt = SYS_PREP_PKT;
                    end
                end

                SYS_PREP_PKT: begin
                    if (evt_packet_count_calc_remaining == 32'd0) begin
                        sys_state_nxt = SYS_PKT_META;
                    end else if (evt_packet_count_calc_remaining > AE_PAYLOAD_BYTES_MAX_U16) begin
                        sys_state_nxt = SYS_PREP_PKT;
                    end else begin
                        sys_state_nxt = SYS_PKT_META;
                    end
                end

                SYS_PKT_META: begin
                    if (!pkt_byte_valid_sys && (evt_meta_byte_idx == TRANSPORT_HDR_BYTES - 1)) begin
                        sys_state_nxt = SYS_PKT_SENSOR;
                    end
                end

                SYS_PKT_SENSOR: begin
                    if (!pkt_byte_valid_sys && (sensor_byte_idx == SENSOR_PKT_BYTES - 1)) begin
                        sys_state_nxt = SYS_PKT_EVT_HDR;
                    end
                end

                SYS_PKT_EVT_HDR: begin
                    if (!pkt_byte_valid_sys && (evt_header_byte_idx == EVENT_HDR_BYTES - 1)) begin
                        if (evt_packet_payload_bytes == 16'd0) begin
                            sys_state_nxt = SYS_PKT_COMMIT;
                        end else begin
                            sys_state_nxt = SYS_PKT_PAYLOAD;
                        end
                    end
                end

                SYS_PKT_PAYLOAD: begin
                    if (!pkt_byte_valid_sys && evt_stream_word_valid &&
                        ((evt_packet_payload_written + 16'd1) >= evt_packet_payload_bytes)) begin
                        sys_state_nxt = SYS_PKT_COMMIT;
                    end
                end

                SYS_PKT_COMMIT: begin
                    if (!pkt_byte_valid_sys && !out_len_fifo_full_sys && !out_meta_fifo_full_sys) begin
                        if (evt_payload_remaining <= evt_packet_payload_bytes) begin
                            sys_state_nxt = SYS_IDLE;
                        end else begin
                            sys_state_nxt = SYS_PKT_META;
                        end
                    end
                end

                default: begin
                    sys_state_nxt = SYS_IDLE;
                end
            endcase
        end
    end

    // Block 2: state register.
    always @(posedge sys_clk) begin
        if (!reset_n) begin
            sys_state <= SYS_IDLE;
        end else begin
            sys_state <= sys_state_nxt;
        end
    end

    // Block 3: datapath and registered outputs for the sys_clk FSM.
    // This block does not assign sys_state. It only performs the work that
    // belongs to each current state.
    always @(posedge sys_clk) begin
        if (!reset_n) begin
            req_fifo_wr_en_sys              <= 1'b0;
            req_fifo_din_sys                <= 32'd0;
            pending_event                   <= 1'b0;
            pending_event_has_data          <= 1'b0;
            pending_event_fail_response    <= 1'b0;
            evt_packet_is_event_txn        <= 1'b0;
            evt_packet_event_ok            <= 1'b0;
            ui_hdr_toggle_meta1             <= 1'b0;
            ui_hdr_toggle_meta2             <= 1'b0;
            ui_hdr_toggle_meta2_d           <= 1'b0;
            ui_rd_fail_toggle_meta1         <= 1'b0;
            ui_rd_fail_toggle_meta2         <= 1'b0;
            ui_rd_fail_toggle_meta2_d       <= 1'b0;
            sys_read_wait_cnt               <= 32'd0;
            ui_hdr_word0_meta1              <= 256'd0;
            ui_hdr_word1_meta1              <= 256'd0;
            ui_hdr_word2_meta1              <= 256'd0;
            ui_hdr_word3_meta1              <= 256'd0;
            ui_hdr_word0_meta2              <= 256'd0;
            ui_hdr_word1_meta2              <= 256'd0;
            ui_hdr_word2_meta2              <= 256'd0;
            ui_hdr_word3_meta2              <= 256'd0;
            sensor_byte_idx                 <= 7'd0;
            out_byte_fifo_wr_en_sys         <= 1'b0;
            out_byte_fifo_din_sys           <= 8'd0;
            pkt_byte_valid_sys              <= 1'b0;
            pkt_byte_data_sys               <= 8'd0;
            out_len_fifo_wr_en_sys          <= 1'b0;
            out_len_fifo_din_sys            <= 16'd0;
            out_meta_fifo_wr_en_sys         <= 1'b0;
            out_meta_fifo_din_sys           <= 35'd0;
            upload_done_pulse               <= 1'b0;
            upload_done_event_pulse         <= 1'b0;
            upload_done_event_seq           <= 32'd0;
            upload_done_event_ok            <= 1'b0;
            event_done_toggle_sys_m         <= 1'b0;
            event_done_toggle_sys_s         <= 1'b0;
            event_done_toggle_sys_d         <= 1'b0;
            event_done_seq_sys_m            <= 32'd0;
            event_done_seq_sys_s            <= 32'd0;
            event_done_ok_sys_m             <= 1'b0;
            event_done_ok_sys_s             <= 1'b0;
            evt_in_fifo_rd_en_sys           <= 1'b0;
            evt_header_words_collected      <= 3'd0;
            evt_stream_word_valid           <= 1'b0;
            evt_stream_word_byte_idx        <= 6'd0;
            evt_event_seq                   <= 32'd0;
            evt_total_bytes                 <= 32'd0;
            evt_payload_total_bytes         <= 32'd0;
            evt_payload_remaining           <= 32'd0;
            evt_payload_offset              <= 32'd0;
            evt_packet_count_calc_remaining <= 32'd0;
            evt_packet_count                <= 16'd0;
            evt_packet_index                <= 16'd0;
            evt_packet_payload_bytes        <= 16'd0;
            evt_packet_payload_written      <= 16'd0;
            evt_meta_byte_idx               <= 6'd0;
            evt_header_byte_idx             <= 8'd0;
            evt_commit_len                  <= 16'd0;
            evt_first_flag                  <= 1'b0;
            evt_last_flag                   <= 1'b0;
            sensor_ds18b20_valid            <= 1'b0;
            sensor_ds18b20_present          <= 1'b0;
            sensor_ds18b20_temp_raw_x16     <= 16'sd0;
            sensor_ds18b20_temp_centi       <= 16'sd0;
            sensor_aht20_valid              <= 1'b0;
            sensor_aht20_humi_centi         <= 16'd0;
            sensor_aht20_temp_centi         <= 16'sd0;
            sensor_lsm6_valid               <= 1'b0;
            sensor_lsm6_ok                  <= 1'b0;
            sensor_lsm6_gx_raw              <= 16'sd0;
            sensor_lsm6_gy_raw              <= 16'sd0;
            sensor_lsm6_gz_raw              <= 16'sd0;
            sensor_time_tag                 <= 64'd0;
            sensor_sample_rate              <= 16'd0;
            sensor_channel_en               <= 16'd0;
            sensor_ae_threshold             <= 16'd0;
            sensor_latest_event_seq         <= 32'd0;
            for (i = 0; i < EVENT_HDR_BYTES; i = i + 1) begin
                evt_header_bytes[i] <= 8'd0;
            end
            for (i = 0; i < 32; i = i + 1) begin
                evt_stream_bytes[i] <= 8'd0;
            end
        end else begin
            // Default one-cycle pulse clears.
            req_fifo_wr_en_sys        <= 1'b0;
            out_byte_fifo_wr_en_sys   <= 1'b0;
            out_len_fifo_wr_en_sys    <= 1'b0;
            out_meta_fifo_wr_en_sys   <= 1'b0;
            evt_in_fifo_rd_en_sys     <= 1'b0;
            upload_done_pulse         <= 1'b0;
            upload_done_event_pulse   <= 1'b0;
            upload_done_event_ok      <= 1'b0;

            // Strict event-complete notification from gmii_tx_clk to sys_clk.
            event_done_toggle_sys_m <= event_done_toggle_tx;
            event_done_toggle_sys_s <= event_done_toggle_sys_m;
            event_done_toggle_sys_d <= event_done_toggle_sys_s;
            event_done_seq_sys_m    <= event_done_seq_tx;
            event_done_seq_sys_s    <= event_done_seq_sys_m;
            event_done_ok_sys_m     <= event_done_ok_tx;
            event_done_ok_sys_s     <= event_done_ok_sys_m;

            if (event_done_toggle_sys_s != event_done_toggle_sys_d) begin
                upload_done_event_pulse <= 1'b1;
                upload_done_event_seq   <= event_done_seq_sys_s;
                upload_done_event_ok    <= event_done_ok_sys_s;
            end

            // Drain one pending byte into the sys->tx byte FIFO.
            if (pkt_byte_valid_sys && out_byte_fifo_write_ready_sys) begin
                out_byte_fifo_wr_en_sys <= 1'b1;
                out_byte_fifo_din_sys   <= pkt_byte_data_sys;
                pkt_byte_valid_sys      <= 1'b0;
            end

            // Capture UI-domain read-header and read-fail toggles into sys_clk.
            ui_hdr_toggle_meta1       <= ui_hdr_toggle;
            ui_hdr_toggle_meta2       <= ui_hdr_toggle_meta1;
            ui_hdr_toggle_meta2_d     <= ui_hdr_toggle_meta2;
            ui_rd_fail_toggle_meta1   <= ui_rd_fail_toggle;
            ui_rd_fail_toggle_meta2   <= ui_rd_fail_toggle_meta1;
            ui_rd_fail_toggle_meta2_d <= ui_rd_fail_toggle_meta2;
            ui_hdr_word0_meta1        <= ui_hdr_word0;
            ui_hdr_word1_meta1        <= ui_hdr_word1;
            ui_hdr_word2_meta1        <= ui_hdr_word2;
            ui_hdr_word3_meta1        <= ui_hdr_word3;
            ui_hdr_word0_meta2        <= ui_hdr_word0_meta1;
            ui_hdr_word1_meta2        <= ui_hdr_word1_meta1;
            ui_hdr_word2_meta2        <= ui_hdr_word2_meta1;
            ui_hdr_word3_meta2        <= ui_hdr_word3_meta1;

            // Accept a new upload request only when packet builder is idle.
            if (upload_req_pulse && !pending_event && (sys_state == SYS_IDLE) &&
                !out_len_fifo_full_sys && !out_meta_fifo_full_sys && out_byte_fifo_write_ready_sys &&
                (!event_available || !req_fifo_full_sys)) begin
                sensor_ds18b20_valid        <= ds18b20_valid;
                sensor_ds18b20_present      <= ds18b20_present;
                sensor_ds18b20_temp_raw_x16 <= ds18b20_temp_raw_x16;
                sensor_ds18b20_temp_centi   <= ds18b20_temp_centi;
                sensor_aht20_valid          <= aht20_valid;
                sensor_aht20_humi_centi     <= aht20_humi_centi;
                sensor_aht20_temp_centi     <= aht20_temp_centi;
                sensor_lsm6_valid           <= lsm6_valid;
                sensor_lsm6_ok              <= lsm6_ok;
                sensor_lsm6_gx_raw          <= lsm6_gx_raw;
                sensor_lsm6_gy_raw          <= lsm6_gy_raw;
                sensor_lsm6_gz_raw          <= lsm6_gz_raw;
                sensor_time_tag             <= current_time_tag;
                sensor_sample_rate          <= sample_rate;
                sensor_channel_en           <= channel_en;
                sensor_ae_threshold         <= ae_threshold;
                sensor_latest_event_seq     <= latest_event_seq;
                pending_event               <= 1'b1;
                pending_event_has_data      <= event_available;
                pending_event_fail_response <= 1'b0;
                evt_packet_is_event_txn     <= event_available;
                evt_packet_event_ok         <= event_available;
                if (event_available) begin
                    req_fifo_wr_en_sys      <= 1'b1;
                    req_fifo_din_sys        <= latest_event_seq;
                end
            end

            // Read timeout counter. It only runs while waiting for DDR header
            // or payload words.
            if (sys_state == SYS_IDLE) begin
                sys_read_wait_cnt <= 32'd0;
            end else if ((sys_state == SYS_COLLECT_HDR) || (sys_state == SYS_PKT_PAYLOAD)) begin
                if (sys_read_wait_cnt < SYS_READ_TIMEOUT_CYCLES) begin
                    sys_read_wait_cnt <= sys_read_wait_cnt + 1'b1;
                end
            end else begin
                sys_read_wait_cnt <= 32'd0;
            end

            if (sys_read_fail_or_timeout) begin
                // Recovery packet: sensor block + zero event header, no AE payload.
                // If the request was for a real AE event, mark this packet as
                // an event transaction with event_ok=0. The gmii_tx_clk domain
                // will generate upload_done_event_pulse after this packet tx_done.
                pending_event                        <= 1'b1;
                pending_event_has_data               <= 1'b0;
                pending_event_fail_response          <= 1'b1;
                evt_packet_is_event_txn              <= 1'b1;
                evt_packet_event_ok                  <= 1'b0;
                sys_read_wait_cnt                    <= 32'd0;
                for (i = 0; i < EVENT_HDR_BYTES; i = i + 1) begin
                    evt_header_bytes[i] <= 8'd0;
                end
                evt_header_words_collected           <= 3'd0;
                evt_event_seq                        <= sensor_latest_event_seq;
                evt_total_bytes                      <= EVENT_HDR_BYTES_U32;
                evt_payload_total_bytes              <= 32'd0;
                evt_payload_remaining                <= 32'd0;
                evt_payload_offset                   <= 32'd0;
                evt_packet_count_calc_remaining      <= 32'd0;
                evt_packet_count                     <= 16'd1;
                evt_packet_index                     <= 16'd0;
                evt_packet_payload_bytes             <= 16'd0;
                evt_packet_payload_written           <= 16'd0;
                evt_header_byte_idx                  <= 8'd0;
                evt_meta_byte_idx                    <= 6'd0;
                sensor_byte_idx                      <= 7'd0;
                evt_first_flag                       <= 1'b1;
                evt_last_flag                        <= 1'b1;
                evt_commit_len                       <= UNIFIED_HDR_BYTES_U16;
                evt_stream_word_valid                <= 1'b0;
                evt_stream_word_byte_idx             <= 6'd0;
            end else begin
                case (sys_state)
                    SYS_IDLE: begin
                        if (pending_event) begin
                            evt_header_words_collected      <= 3'd0;
                            evt_stream_word_valid           <= 1'b0;
                            evt_stream_word_byte_idx        <= 6'd0;
                            evt_event_seq                   <= 32'd0;
                            evt_total_bytes                 <= 32'd0;
                            evt_payload_total_bytes         <= 32'd0;
                            evt_payload_remaining           <= 32'd0;
                            evt_payload_offset              <= 32'd0;
                            evt_packet_count_calc_remaining <= 32'd0;
                            evt_packet_count                <= 16'd0;
                            evt_packet_index                <= 16'd0;
                            evt_packet_payload_bytes        <= 16'd0;
                            evt_packet_payload_written      <= 16'd0;
                            evt_header_byte_idx             <= 8'd0;
                            evt_meta_byte_idx               <= 6'd0;
                            evt_commit_len                  <= 16'd0;
                            evt_first_flag                  <= 1'b0;
                            evt_last_flag                   <= 1'b0;
                            evt_packet_is_event_txn         <= pending_event_has_data;
                            evt_packet_event_ok             <= pending_event_has_data;

                            if (!pending_event_has_data) begin
                                for (i = 0; i < EVENT_HDR_BYTES; i = i + 1) begin
                                    evt_header_bytes[i] <= 8'd0;
                                end
                                evt_header_words_collected      <= 3'd4;
                                evt_event_seq                   <= pending_event_fail_response ? sensor_latest_event_seq : 32'd0;
                                evt_packet_is_event_txn         <= pending_event_fail_response;
                                evt_packet_event_ok             <= 1'b0;
                                evt_total_bytes                 <= EVENT_HDR_BYTES_U32;
                                evt_payload_total_bytes         <= 32'd0;
                                evt_payload_remaining           <= 32'd0;
                                evt_payload_offset              <= 32'd0;
                                evt_packet_count_calc_remaining <= 32'd0;
                                evt_packet_count                <= 16'd1;
                                evt_packet_index                <= 16'd0;
                                evt_packet_payload_bytes        <= 16'd0;
                                evt_packet_payload_written      <= 16'd0;
                                evt_header_byte_idx             <= 8'd0;
                                evt_meta_byte_idx               <= 6'd0;
                                sensor_byte_idx                 <= 7'd0;
                                evt_first_flag                  <= 1'b1;
                                evt_last_flag                   <= 1'b1;
                                evt_commit_len                  <= UNIFIED_HDR_BYTES_U16;
                            end
                        end
                    end

                    SYS_COLLECT_HDR: begin
                        if (evt_header_words_collected < 3'd4) begin
                            if (ui_hdr_toggle_meta2 != ui_hdr_toggle_meta2_d) begin
                                for (i = 0; i < 32; i = i + 1) begin
                                    evt_header_bytes[i]       <= ui_hdr_word0_meta2[255 - i*8 -: 8];
                                    evt_header_bytes[32 + i]  <= ui_hdr_word1_meta2[255 - i*8 -: 8];
                                    evt_header_bytes[64 + i]  <= ui_hdr_word2_meta2[255 - i*8 -: 8];
                                    evt_header_bytes[96 + i]  <= ui_hdr_word3_meta2[255 - i*8 -: 8];
                                end
                                evt_event_seq              <= ui_hdr_word0_meta2[191:160];
                                // hdr2 layout:
                                // [255:254] reserved
                                // [253:224] ddr_base_addr
                                // [223:192] slot_index
                                // [191:160] slot_bytes
                                // [159:128] total_bytes
                                evt_total_bytes            <= ui_hdr_word2_meta2[159:128];
                                evt_header_words_collected <= 3'd4;
                            end
                        end else begin
                            tmp32 = evt_total_bytes - EVENT_HDR_BYTES_U32;
                            evt_payload_total_bytes         <= tmp32;
                            evt_payload_remaining           <= 32'd0;
                            evt_payload_offset              <= 32'd0;
                            evt_packet_count_calc_remaining <= tmp32;
                            evt_packet_count                <= 16'd0;
                            evt_packet_index                <= 16'd0;
                            evt_packet_payload_bytes        <= 16'd0;
                            evt_packet_payload_written      <= 16'd0;
                            evt_header_byte_idx             <= 8'd0;
                            evt_meta_byte_idx               <= 6'd0;
                            sensor_byte_idx                 <= 7'd0;
                            evt_first_flag                  <= 1'b1;
                            evt_last_flag                   <= 1'b0;
                            evt_commit_len                  <= UNIFIED_HDR_BYTES_U16;
                        end
                    end

                    SYS_PREP_PKT: begin
                        if (evt_packet_count_calc_remaining == 32'd0) begin
                            evt_packet_count           <= 16'd1;
                            evt_payload_remaining      <= 32'd0;
                            evt_payload_offset         <= 32'd0;
                            evt_packet_index           <= 16'd0;
                            evt_packet_payload_bytes   <= 16'd0;
                            evt_packet_payload_written <= 16'd0;
                            evt_header_byte_idx        <= 8'd0;
                            evt_meta_byte_idx          <= 6'd0;
                            sensor_byte_idx            <= 7'd0;
                            evt_first_flag             <= 1'b1;
                            evt_last_flag              <= 1'b1;
                            evt_commit_len             <= UNIFIED_HDR_BYTES_U16;
                        end else if (evt_packet_count_calc_remaining > AE_PAYLOAD_BYTES_MAX_U16) begin
                            evt_packet_count_calc_remaining <= evt_packet_count_calc_remaining - AE_PAYLOAD_BYTES_MAX_U16;
                            evt_packet_count                <= evt_packet_count + 1'b1;
                        end else begin
                            evt_packet_count           <= evt_packet_count + 1'b1;
                            evt_payload_remaining      <= evt_payload_total_bytes;
                            evt_payload_offset         <= 32'd0;
                            evt_packet_index           <= 16'd0;
                            evt_packet_payload_bytes   <= min16(evt_payload_total_bytes, AE_PAYLOAD_BYTES_MAX_U16);
                            evt_packet_payload_written <= 16'd0;
                            evt_header_byte_idx        <= 8'd0;
                            evt_meta_byte_idx          <= 6'd0;
                            sensor_byte_idx            <= 7'd0;
                            evt_first_flag             <= 1'b1;
                            evt_last_flag              <= (evt_payload_total_bytes <= AE_PAYLOAD_BYTES_MAX_U16);
                            evt_commit_len             <= UNIFIED_HDR_BYTES_U16;
                        end
                    end

                    SYS_PKT_META: begin
                        if (!pkt_byte_valid_sys) begin
                            tmp32 = unified_hdr_word(evt_meta_byte_idx[4:2]);
                            pkt_byte_valid_sys <= 1'b1;
                            pkt_byte_data_sys  <= be_word_byte(tmp32, evt_meta_byte_idx[1:0]);
                            if (evt_meta_byte_idx == TRANSPORT_HDR_BYTES - 1) begin
                                sensor_byte_idx <= 7'd0;
                            end else begin
                                evt_meta_byte_idx <= evt_meta_byte_idx + 1'b1;
                            end
                        end
                    end

                    SYS_PKT_SENSOR: begin
                        if (!pkt_byte_valid_sys) begin
                            tmp32 = sensor_word(sensor_byte_idx[6:2]);
                            pkt_byte_valid_sys <= 1'b1;
                            pkt_byte_data_sys  <= be_word_byte(tmp32, sensor_byte_idx[1:0]);
                            if (sensor_byte_idx == SENSOR_PKT_BYTES - 1) begin
                                evt_header_byte_idx <= 8'd0;
                            end else begin
                                sensor_byte_idx <= sensor_byte_idx + 1'b1;
                            end
                        end
                    end

                    SYS_PKT_EVT_HDR: begin
                        if (!pkt_byte_valid_sys) begin
                            pkt_byte_valid_sys <= 1'b1;
                            pkt_byte_data_sys  <= evt_header_bytes[evt_header_byte_idx];
                            if (evt_header_byte_idx == EVENT_HDR_BYTES - 1) begin
                                evt_packet_payload_written <= 16'd0;
                                if (evt_packet_payload_bytes == 16'd0) begin
                                    evt_commit_len <= UNIFIED_HDR_BYTES_U16;
                                end
                            end else begin
                                evt_header_byte_idx <= evt_header_byte_idx + 1'b1;
                            end
                        end
                    end

                    SYS_PKT_PAYLOAD: begin
                        if (!pkt_byte_valid_sys) begin
                            if (evt_stream_word_valid) begin
                                pkt_byte_valid_sys <= 1'b1;
                                pkt_byte_data_sys  <= evt_stream_bytes[evt_stream_word_byte_idx];
                                evt_packet_payload_written <= evt_packet_payload_written + 1'b1;

                                if (evt_stream_word_byte_idx == 6'd31) begin
                                    evt_stream_word_valid    <= 1'b0;
                                    evt_stream_word_byte_idx <= 6'd0;
                                end else begin
                                    evt_stream_word_byte_idx <= evt_stream_word_byte_idx + 1'b1;
                                end

                                if ((evt_packet_payload_written + 16'd1) >= evt_packet_payload_bytes) begin
                                    evt_commit_len <= UNIFIED_HDR_BYTES_U16 + evt_packet_payload_bytes;
                                end
                            end else if (!evt_in_fifo_empty_sys) begin
                                evt_in_fifo_rd_en_sys <= 1'b1;
                                for (i = 0; i < 32; i = i + 1) begin
                                    evt_stream_bytes[i] <= evt_in_fifo_dout_sys[255 - i*8 -: 8];
                                end
                                evt_stream_word_valid    <= 1'b1;
                                evt_stream_word_byte_idx <= 6'd0;
                            end
                        end
                    end

                    SYS_PKT_COMMIT: begin
                        if (!pkt_byte_valid_sys && !out_len_fifo_full_sys && !out_meta_fifo_full_sys) begin
                            out_len_fifo_wr_en_sys  <= 1'b1;
                            out_len_fifo_din_sys    <= evt_commit_len;

                            out_meta_fifo_wr_en_sys <= 1'b1;
                            out_meta_fifo_din_sys   <= {
                                evt_packet_is_event_txn,
                                (evt_payload_remaining <= evt_packet_payload_bytes),
                                evt_packet_event_ok,
                                evt_event_seq
                            };

                            tmp32 = evt_payload_remaining - evt_packet_payload_bytes;

                            if (evt_payload_remaining <= evt_packet_payload_bytes) begin
                                pending_event               <= 1'b0;
                                pending_event_has_data      <= 1'b0;
                                pending_event_fail_response <= 1'b0;
                                evt_packet_is_event_txn     <= 1'b0;
                                evt_packet_event_ok         <= 1'b0;

                                // Broad completion: all UDP payloads for this transaction have
                                // entered the TX FIFO. Do not use it to release AE capture.
                                upload_done_pulse      <= 1'b1;
                            end else begin
                                evt_payload_remaining      <= tmp32;
                                evt_payload_offset         <= evt_payload_offset + evt_packet_payload_bytes;
                                evt_packet_index           <= evt_packet_index + 1'b1;
                                evt_packet_payload_bytes   <= min16(tmp32, AE_PAYLOAD_BYTES_MAX_U16);
                                evt_packet_payload_written <= 16'd0;
                                evt_meta_byte_idx          <= 6'd0;
                                sensor_byte_idx            <= 7'd0;
                                evt_header_byte_idx        <= 8'd0;
                                evt_first_flag             <= 1'b0;
                                evt_last_flag              <= (tmp32 <= AE_PAYLOAD_BYTES_MAX_U16);
                                evt_commit_len             <= UNIFIED_HDR_BYTES_U16;
                            end
                        end
                    end

                    default: begin
                    end
                endcase
            end
        end
    end

    // ------------------------------------------------------------------
    // gmii_tx_clk domain: drive udp_tx byte stream and generate strict tx_done event completion
    // ------------------------------------------------------------------
    always @(posedge gmii_tx_clk) begin
        if (!reset_n) begin
            tx_busy                <= 1'b0;
            tx_start_en_reg        <= 1'b0;
            tx_len_reg             <= 16'd0;
            tx_pop_count           <= 16'd0;
            tx_data_reg            <= 8'd0;
            tx_req_seen            <= 1'b0;
            tx_underflow_seen      <= 1'b0;
            out_len_fifo_rd_en_tx  <= 1'b0;
            out_meta_fifo_rd_en_tx <= 1'b0;
            tx_pkt_is_event        <= 1'b0;
            tx_pkt_is_last         <= 1'b0;
            tx_pkt_event_ok          <= 1'b0;
            tx_pkt_event_seq       <= 32'd0;
            event_done_toggle_tx   <= 1'b0;
            event_done_seq_tx      <= 32'd0;
            event_done_ok_tx       <= 1'b0;
            tx_gap_cnt             <= 32'd0;
        end else begin
            tx_start_en_reg        <= 1'b0;
            out_len_fifo_rd_en_tx  <= 1'b0;
            out_meta_fifo_rd_en_tx <= 1'b0;
            if (tx_gap_cnt != 32'd0) begin
                tx_gap_cnt <= tx_gap_cnt - 1'b1;
            end
            if (!tx_busy && tx_gap_done && out_packet_ready_tx) begin
                tx_busy                <= 1'b1;
                tx_start_en_reg        <= 1'b1;
                tx_len_reg             <= out_len_fifo_dout_tx;
                tx_pop_count           <= 16'd0;

                out_len_fifo_rd_en_tx  <= 1'b1;
                out_meta_fifo_rd_en_tx <= 1'b1;

                tx_pkt_is_event        <= out_meta_fifo_dout_tx[34];
                tx_pkt_is_last         <= out_meta_fifo_dout_tx[33];
                tx_pkt_event_ok          <= out_meta_fifo_dout_tx[32];
                tx_pkt_event_seq       <= out_meta_fifo_dout_tx[31:0];

                tx_req_seen            <= 1'b0;
                tx_underflow_seen      <= 1'b0;
            end

            if (tx_busy) begin
                if (out_byte_fifo_rd_en_tx) begin
                    tx_req_seen  <= 1'b1;
                    tx_pop_count <= tx_pop_count + 1'b1;
                end

                if (tx_req && out_byte_fifo_empty_tx && (tx_pop_count < tx_len_reg)) begin
                    tx_underflow_seen <= 1'b1;
                end

                if (!out_byte_fifo_empty_tx) begin
                    tx_data_reg <= out_byte_fifo_dout_tx;
                end

                if (tx_done) begin
                    if (tx_pkt_is_event && tx_pkt_is_last && !tx_underflow_seen) begin
                        event_done_seq_tx    <= tx_pkt_event_seq;
                        event_done_ok_tx     <= tx_pkt_event_ok;
                        event_done_toggle_tx <= ~event_done_toggle_tx;
                    end
                
                    tx_busy      <= 1'b0;
                    tx_pop_count <= 16'd0;
                    tx_req_seen  <= 1'b0;
                
                    // 本包发送完成后，等待 TX_INTER_PKT_GAP_CYCLES 个 gmii_tx_clk 周期
                    // 再允许启动下一包。
                    tx_gap_cnt   <= TX_INTER_PKT_GAP_CYCLES[31:0];
                end
            end
        end
    end

    `ifdef DEBUG_ILA_AE_EVT
    ILA_AE_EVT ILA_AE_EVT_inst1 (
    .clk                                (sys_clk                   ),// input wire clk


    .probe0                             (evt_total_bytes           ),// input wire [31:0]  probe0
    .probe1                             (evt_payload_total_bytes   ),// input wire [31:0]  probe1
    .probe2                             (evt_packet_count          ),// input wire [15:0]  probe2
    .probe3                             (evt_packet_index          ),// input wire [15:0]  probe3
    .probe4                             (ae_rd_eop                 ),// input wire [0:0]  probe4
    .probe5                             (ae_rd_busy                ),// input wire [0:0]  probe5
    .probe6                             (upload_done_event_pulse   ),// input wire [0:0]  probe6
    .probe7                             (upload_done_event_ok      ) // input wire [0:0]  probe7
    );

`endif

endmodule
