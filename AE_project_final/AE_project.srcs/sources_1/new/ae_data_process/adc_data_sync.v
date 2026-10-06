// ============================================================================
// Rewritten adc_data_sync
//   - No ADC14 conversion
//   - No IIR/FIR
//   - Input is already signed 16-bit filtered data
//   - Only does ADC1/ADC2 async FIFO synchronization into adc_clk domain
// ============================================================================
module adc_data_sync #(
    parameter integer ADC_CH_PER_DEV      = 8,
    parameter integer ADC_OUT_W           = 16,
    parameter integer PACK_W              = ADC_CH_PER_DEV * ADC_OUT_W,
    parameter integer STARTUP_WAIT_CYCLES = 16,
    parameter integer PRELOAD_CYCLES      = 4
)(
    input                               adc_clk,
    input                               reset_n,
    input                               sync_en,

    input      [15:0]                   active_ch_mask_cfg,
    input      [15:0]                   trig_ch_mask_cfg,

    input                               adc1_div_clk,
    input                               adc1_data_vld,
    input      signed [15:0]            adc1_data0,
    input      signed [15:0]            adc1_data1,
    input      signed [15:0]            adc1_data2,
    input      signed [15:0]            adc1_data3,
    input      signed [15:0]            adc1_data4,
    input      signed [15:0]            adc1_data5,
    input      signed [15:0]            adc1_data6,
    input      signed [15:0]            adc1_data7,

    input                               adc2_div_clk,
    input                               adc2_data_vld,
    input      signed [15:0]            adc2_data0,
    input      signed [15:0]            adc2_data1,
    input      signed [15:0]            adc2_data2,
    input      signed [15:0]            adc2_data3,
    input      signed [15:0]            adc2_data4,
    input      signed [15:0]            adc2_data5,
    input      signed [15:0]            adc2_data6,
    input      signed [15:0]            adc2_data7,

    output wire                         cap_en_out,
    output reg                          sample_valid,
    output reg  [255:0]                 sample_data,
    output reg  [255:0]                 trigger_sample_data,
    output wire [15:0]                  active_ch_mask,
    output wire [15:0]                  trig_mask,

    output wire                         sync_ready,
    output reg                          sync_error
);

    assign active_ch_mask = active_ch_mask_cfg;
    assign trig_mask      = trig_ch_mask_cfg;

    wire [PACK_W-1:0] adc1_pack_word;
    wire [PACK_W-1:0] adc2_pack_word;

    assign adc1_pack_word = {
        adc1_data7,
        adc1_data6,
        adc1_data5,
        adc1_data4,
        adc1_data3,
        adc1_data2,
        adc1_data1,
        adc1_data0
    };

    assign adc2_pack_word = {
        adc2_data7,
        adc2_data6,
        adc2_data5,
        adc2_data4,
        adc2_data3,
        adc2_data2,
        adc2_data1,
        adc2_data0
    };

    // ------------------------------------------------------------------------
    // FIFO reset release.
    // Do not depend on adc*_data_vld here. After filtering, valid can be a
    // continuous stream pulse. The real readiness condition is both FIFOs
    // non-empty, checked later by preload/sync_run logic.
    // ------------------------------------------------------------------------
    reg [15:0]                          startup_cnt;
    reg                                 fifo_release_en;

    always @(posedge adc_clk or negedge reset_n) begin
        if (!reset_n) begin
            startup_cnt     <= 16'd0;
            fifo_release_en <= 1'b0;
        end
        else if (!sync_en) begin
            startup_cnt     <= 16'd0;
            fifo_release_en <= 1'b0;
        end
        else if (!fifo_release_en) begin
            if (startup_cnt == STARTUP_WAIT_CYCLES - 1) begin
                fifo_release_en <= 1'b1;
            end
            else begin
                startup_cnt <= startup_cnt + 1'b1;
            end
        end
    end

    wire fifo_rst;
    assign fifo_rst = (~reset_n) || (~sync_en) || (~fifo_release_en);

    // ------------------------------------------------------------------------
    // ADC1 async FIFO
    // ------------------------------------------------------------------------
    wire                                adc1_fifo_full;
    wire                                adc1_fifo_empty;
    wire                                adc1_wr_rst_busy;
    wire                                adc1_rd_rst_busy;
    wire [PACK_W-1:0]                   adc1_fifo_dout;
    wire                                adc1_fifo_rd_en;
    wire                                adc1_fifo_wr_en;

    assign adc1_fifo_wr_en = adc1_data_vld && !adc1_fifo_full && !adc1_wr_rst_busy;

    xpm_fifo_async #(
        .CDC_SYNC_STAGES                (2),
        .DOUT_RESET_VALUE               ("0"),
        .ECC_MODE                       ("no_ecc"),
        .FIFO_MEMORY_TYPE               ("block"),
        .FIFO_READ_LATENCY              (0),
        .FIFO_WRITE_DEPTH               (64),
        .FULL_RESET_VALUE               (0),
        .PROG_EMPTY_THRESH              (10),
        .PROG_FULL_THRESH               (10),
        .RD_DATA_COUNT_WIDTH            (1),
        .READ_DATA_WIDTH                (PACK_W),
        .READ_MODE                      ("fwft"),
        .RELATED_CLOCKS                 (0),
        .SIM_ASSERT_CHK                 (0),
        .USE_ADV_FEATURES               ("0000"),
        .WAKEUP_TIME                    (0),
        .WRITE_DATA_WIDTH               (PACK_W),
        .WR_DATA_COUNT_WIDTH            (1)
    ) u_adc1_fifo (
        .almost_empty                   (),
        .almost_full                    (),
        .data_valid                     (),
        .dbiterr                        (),
        .dout                           (adc1_fifo_dout),
        .empty                          (adc1_fifo_empty),
        .full                           (adc1_fifo_full),
        .overflow                       (),
        .prog_empty                     (),
        .prog_full                      (),
        .rd_data_count                  (),
        .rd_rst_busy                    (adc1_rd_rst_busy),
        .sbiterr                        (),
        .underflow                      (),
        .wr_ack                         (),
        .wr_data_count                  (),
        .wr_rst_busy                    (adc1_wr_rst_busy),

        .din                            (adc1_pack_word),
        .injectdbiterr                  (1'b0),
        .injectsbiterr                  (1'b0),
        .rd_clk                         (adc_clk),
        .rd_en                          (adc1_fifo_rd_en),
        .rst                            (fifo_rst),
        .sleep                          (1'b0),
        .wr_clk                         (adc1_div_clk),
        .wr_en                          (adc1_fifo_wr_en)
    );

    // ------------------------------------------------------------------------
    // ADC2 async FIFO
    // ------------------------------------------------------------------------
    wire                                adc2_fifo_full;
    wire                                adc2_fifo_empty;
    wire                                adc2_wr_rst_busy;
    wire                                adc2_rd_rst_busy;
    wire [PACK_W-1:0]                   adc2_fifo_dout;
    wire                                adc2_fifo_rd_en;
    wire                                adc2_fifo_wr_en;

    assign adc2_fifo_wr_en = adc2_data_vld && !adc2_fifo_full && !adc2_wr_rst_busy;

    xpm_fifo_async #(
        .CDC_SYNC_STAGES                (2),
        .DOUT_RESET_VALUE               ("0"),
        .ECC_MODE                       ("no_ecc"),
        .FIFO_MEMORY_TYPE               ("block"),
        .FIFO_READ_LATENCY              (0),
        .FIFO_WRITE_DEPTH               (64),
        .FULL_RESET_VALUE               (0),
        .PROG_EMPTY_THRESH              (10),
        .PROG_FULL_THRESH               (10),
        .RD_DATA_COUNT_WIDTH            (1),
        .READ_DATA_WIDTH                (PACK_W),
        .READ_MODE                      ("fwft"),
        .RELATED_CLOCKS                 (0),
        .SIM_ASSERT_CHK                 (0),
        .USE_ADV_FEATURES               ("0000"),
        .WAKEUP_TIME                    (0),
        .WRITE_DATA_WIDTH               (PACK_W),
        .WR_DATA_COUNT_WIDTH            (1)
    ) u_adc2_fifo (
        .almost_empty                   (),
        .almost_full                    (),
        .data_valid                     (),
        .dbiterr                        (),
        .dout                           (adc2_fifo_dout),
        .empty                          (adc2_fifo_empty),
        .full                           (adc2_fifo_full),
        .overflow                       (),
        .prog_empty                     (),
        .prog_full                      (),
        .rd_data_count                  (),
        .rd_rst_busy                    (adc2_rd_rst_busy),
        .sbiterr                        (),
        .underflow                      (),
        .wr_ack                         (),
        .wr_data_count                  (),
        .wr_rst_busy                    (adc2_wr_rst_busy),

        .din                            (adc2_pack_word),
        .injectdbiterr                  (1'b0),
        .injectsbiterr                  (1'b0),
        .rd_clk                         (adc_clk),
        .rd_en                          (adc2_fifo_rd_en),
        .rst                            (fifo_rst),
        .sleep                          (1'b0),
        .wr_clk                         (adc2_div_clk),
        .wr_en                          (adc2_fifo_wr_en)
    );

    // ------------------------------------------------------------------------
    // Joint readout in adc_clk domain.
    // Both FIFOs must be non-empty before popping one 16-channel sample group.
    // ------------------------------------------------------------------------
    reg [15:0]                          preload_cnt;
    reg                                 sync_run;

    wire                                both_fifo_ready;
    wire                                pair_pop;

    assign both_fifo_ready = !adc1_fifo_empty &&
                             !adc2_fifo_empty &&
                             !adc1_rd_rst_busy &&
                             !adc2_rd_rst_busy;

    assign pair_pop        = sync_run && both_fifo_ready;

    assign adc1_fifo_rd_en = pair_pop;
    assign adc2_fifo_rd_en = pair_pop;

    assign sync_ready      = sync_run;
    assign cap_en_out      = sync_en && sync_run;

    always @(posedge adc_clk or negedge reset_n) begin
        if (!reset_n) begin
            preload_cnt         <= 16'd0;
            sync_run            <= 1'b0;
            sample_valid        <= 1'b0;
            sample_data         <= 256'd0;
            trigger_sample_data <= 256'd0;
            sync_error          <= 1'b0;
        end
        else if (!sync_en) begin
            preload_cnt         <= 16'd0;
            sync_run            <= 1'b0;
            sample_valid        <= 1'b0;
            sample_data         <= 256'd0;
            trigger_sample_data <= 256'd0;
            sync_error          <= 1'b0;
        end
        else begin
            sample_valid <= 1'b0;

            if (!fifo_release_en) begin
                preload_cnt <= 16'd0;
                sync_run    <= 1'b0;
            end
            else if (!sync_run) begin
                if (both_fifo_ready) begin
                    if (preload_cnt == PRELOAD_CYCLES - 1) begin
                        preload_cnt <= preload_cnt;
                        sync_run    <= 1'b1;
                    end
                    else begin
                        preload_cnt <= preload_cnt + 1'b1;
                    end
                end
                else begin
                    preload_cnt <= 16'd0;
                end
            end
            else begin
                if (both_fifo_ready) begin
                    sample_valid <= 1'b1;

                    sample_data <= {
                        adc2_fifo_dout,
                        adc1_fifo_dout
                    };

                    // Trigger path uses the same filtered samples.
                    // If later you want raw-data trigger and filtered-data storage,
                    // expose raw data separately before the filter chain.
                    trigger_sample_data <= {
                        adc2_fifo_dout,
                        adc1_fifo_dout
                    };
                end
                else begin
                    sync_run    <= 1'b0;
                    preload_cnt <= 16'd0;
                    sync_error  <= 1'b1;
                end
            end
        end
    end

endmodule