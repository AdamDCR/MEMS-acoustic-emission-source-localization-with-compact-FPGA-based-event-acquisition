`timescale 1ns / 1ps
// ============================================================================
// File       : adc_data_preprocess.v
// Top module : adc_data_preprocess
//
// New ADC preprocessing path:
//
//   get_adc_data_inst1/2
//          |
//          v
//   adc_filter_chain
//      - 16 parallel channels
//      - each channel: ADC14 -> signed16 -> 4th-order 10 kHz IIR high-pass
//        -> fir_500k_lp FIR IP -> signed16
//          |
//          v
//   adc_data_sync
//      - no FIR inside
//      - only synchronizes ADC1/ADC2 filtered data into adc_clk domain
//      - outputs 256-bit sample_data for downstream AE / processing
//
// Compile note:
//   This file contains adc_data_preprocess, the rewritten no-filter adc_data_sync,
//   and adc_filter_chain plus its helper modules.
//   Do NOT compile the older standalone adc_filter_chain.v together with this file,
//   otherwise adc_filter_chain will be defined twice.
// ============================================================================

module adc_data_preprocess #(
    parameter integer ADC1_DEBUG_ILA           = 0,
    parameter integer ADC2_DEBUG_ILA           = 0,
    parameter integer ILA_ADC1_FILTERED_DATA_EN= 0,
    parameter integer ILA_ADC2_FILTERED_DATA_EN= 0,
    parameter integer INPUT_IS_OFFSET_BINARY   = 0,
    parameter integer FIR_OUT_SHIFT            = 16,
    parameter integer STARTUP_WAIT_CYCLES      = 16,
    parameter integer PRELOAD_CYCLES           = 4
)(
    // ------------------------------------------------------------------------
    // System clocks and control
    // ------------------------------------------------------------------------
    input                               sys_clk,
    input                               reset_n,
    input                               adc_clk,
    input                               adc_en,

    input      [15:0]                   active_ch_mask_cfg,
    input      [15:0]                   trig_ch_mask_cfg,

    // ------------------------------------------------------------------------
    // ADC1 board pins
    // ------------------------------------------------------------------------
    output                              adc1_pdwn,
    output                              adc1_spi_sck,
    output                              adc1_spi_csn,
    inout                               adc1_spi_dio,

    output                              adc1_sync,
    output                              adc1_clk_out_p,
    output                              adc1_clk_out_n,

    input                               adc1_fclk_p,
    input                               adc1_fclk_n,
    input                               adc1_dclk_p,
    input                               adc1_dclk_n,
    input      [7:0]                    adc1_data_in_p,
    input      [7:0]                    adc1_data_in_n,

    // ------------------------------------------------------------------------
    // ADC2 board pins
    // ------------------------------------------------------------------------
    output                              adc2_pdwn,
    output                              adc2_spi_sck,
    output                              adc2_spi_csn,
    inout                               adc2_spi_dio,

    output                              adc2_sync,
    output                              adc2_clk_out_p,
    output                              adc2_clk_out_n,

    input                               adc2_fclk_p,
    input                               adc2_fclk_n,
    input                               adc2_dclk_p,
    input                               adc2_dclk_n,
    input      [7:0]                    adc2_data_in_p,
    input      [7:0]                    adc2_data_in_n,

    // ------------------------------------------------------------------------
    // Preprocessed output to downstream AE / processing
    // adc_clk domain
    // ------------------------------------------------------------------------
    output                              cap_en_out,
    output                              sample_valid,
    output     [255:0]                  sample_data,
    output     [255:0]                  trigger_sample_data,
    output     [15:0]                   active_ch_mask,
    output     [15:0]                   trig_mask,

    output                              sync_ready,
    output                              sync_error,

    // ------------------------------------------------------------------------
    // Minimal status outputs for top LED / ILA
    // ------------------------------------------------------------------------
    output                              adc_raw_ready,
    output                              filter_valid,
    output                              filter_backpressure
);

    // Your current top ties adc*_sync low. Keep the same behavior here.
    assign adc1_sync = 1'b0;
    assign adc2_sync = 1'b0;

    // ------------------------------------------------------------------------
    // Raw ADC outputs from get_adc_data
    // ------------------------------------------------------------------------
    wire                                adc1_div_clk;
    wire                                adc1_data_vld;
    wire [13:0]                         adc1_data0;
    wire [13:0]                         adc1_data1;
    wire [13:0]                         adc1_data2;
    wire [13:0]                         adc1_data3;
    wire [13:0]                         adc1_data4;
    wire [13:0]                         adc1_data5;
    wire [13:0]                         adc1_data6;
    wire [13:0]                         adc1_data7;
    wire [13:0]                         adc1_out_frame;

    wire                                adc2_div_clk;
    wire                                adc2_data_vld;
    wire [13:0]                         adc2_data0;
    wire [13:0]                         adc2_data1;
    wire [13:0]                         adc2_data2;
    wire [13:0]                         adc2_data3;
    wire [13:0]                         adc2_data4;
    wire [13:0]                         adc2_data5;
    wire [13:0]                         adc2_data6;
    wire [13:0]                         adc2_data7;
    wire [13:0]                         adc2_out_frame;

    assign adc_raw_ready = adc1_data_vld & adc2_data_vld;

    get_adc_data #(
        .DEBUG_ILA                      (ADC1_DEBUG_ILA)
    ) get_adc_data_inst1 (
    .sys_clk                            (sys_clk                   ),
    .reset_n                            (reset_n                   ),

    .adc_en                             (adc_en                    ),

    .adc_clk                            (adc_clk                   ),

    .adc_pdwn                           (adc1_pdwn                 ),
    .adc_spi_sck                        (adc1_spi_sck              ),
    .adc_spi_csn                        (adc1_spi_csn              ),
    .adc_spi_dio                        (adc1_spi_dio              ),

    .adc_clk_out_p                      (adc1_clk_out_p            ),
    .adc_clk_out_n                      (adc1_clk_out_n            ),

    .adc_fclk_p                         (adc1_fclk_p               ),
    .adc_fclk_n                         (adc1_fclk_n               ),
    .adc_dclk_p                         (adc1_dclk_p               ),
    .adc_dclk_n                         (adc1_dclk_n               ),
    .adc_data_in_p                      (adc1_data_in_p            ),
    .adc_data_in_n                      (adc1_data_in_n            ),

    .adc_div_clk                        (adc1_div_clk              ),
    .adc_data0                          (adc1_data0                ),
    .adc_data1                          (adc1_data1                ),
    .adc_data2                          (adc1_data2                ),
    .adc_data3                          (adc1_data3                ),
    .adc_data4                          (adc1_data4                ),
    .adc_data5                          (adc1_data5                ),
    .adc_data6                          (adc1_data6                ),
    .adc_data7                          (adc1_data7                ),
    .adc_out_frame                      (adc1_out_frame            ),
    .adc_data_vld                       (adc1_data_vld             ) 
    );

    get_adc_data #(
        .DEBUG_ILA                      (ADC2_DEBUG_ILA)
    ) get_adc_data_inst2 (
    .sys_clk                            (sys_clk                   ),
    .reset_n                            (reset_n                   ),

    .adc_en                             (adc_en                    ),

    .adc_clk                            (adc_clk                   ),

    .adc_pdwn                           (adc2_pdwn                 ),
    .adc_spi_sck                        (adc2_spi_sck              ),
    .adc_spi_csn                        (adc2_spi_csn              ),
    .adc_spi_dio                        (adc2_spi_dio              ),

    .adc_clk_out_p                      (adc2_clk_out_p            ),
    .adc_clk_out_n                      (adc2_clk_out_n            ),

    .adc_fclk_p                         (adc2_fclk_p               ),
    .adc_fclk_n                         (adc2_fclk_n               ),
    .adc_dclk_p                         (adc2_dclk_p               ),
    .adc_dclk_n                         (adc2_dclk_n               ),
    .adc_data_in_p                      (adc2_data_in_p            ),
    .adc_data_in_n                      (adc2_data_in_n            ),

    .adc_div_clk                        (adc2_div_clk              ),
    .adc_data0                          (adc2_data0                ),
    .adc_data1                          (adc2_data1                ),
    .adc_data2                          (adc2_data2                ),
    .adc_data3                          (adc2_data3                ),
    .adc_data4                          (adc2_data4                ),
    .adc_data5                          (adc2_data5                ),
    .adc_data6                          (adc2_data6                ),
    .adc_data7                          (adc2_data7                ),
    .adc_out_frame                      (adc2_out_frame            ),
    .adc_data_vld                       (adc2_data_vld             ) 
    );

    // ------------------------------------------------------------------------
    // Filtered ADC outputs
    // ------------------------------------------------------------------------
    wire                                adc1_filter_vld;
    wire signed [15:0]                  adc1_filter_data0;
    wire signed [15:0]                  adc1_filter_data1;
    wire signed [15:0]                  adc1_filter_data2;
    wire signed [15:0]                  adc1_filter_data3;
    wire signed [15:0]                  adc1_filter_data4;
    wire signed [15:0]                  adc1_filter_data5;
    wire signed [15:0]                  adc1_filter_data6;
    wire signed [15:0]                  adc1_filter_data7;

    wire                                adc2_filter_vld;
    wire signed [15:0]                  adc2_filter_data0;
    wire signed [15:0]                  adc2_filter_data1;
    wire signed [15:0]                  adc2_filter_data2;
    wire signed [15:0]                  adc2_filter_data3;
    wire signed [15:0]                  adc2_filter_data4;
    wire signed [15:0]                  adc2_filter_data5;
    wire signed [15:0]                  adc2_filter_data6;
    wire signed [15:0]                  adc2_filter_data7;

    wire                                adc1_filter_backpressure;
    wire                                adc2_filter_backpressure;

    assign filter_valid        = adc1_filter_vld & adc2_filter_vld;
    assign filter_backpressure = adc1_filter_backpressure | adc2_filter_backpressure;

    adc_filter_chain #(
        .INPUT_IS_OFFSET_BINARY         (INPUT_IS_OFFSET_BINARY),
        .FIR_OUT_SHIFT                  (FIR_OUT_SHIFT)
    ) adc_filter_chain_inst (
        .reset_n                        (reset_n),

        .adc1_div_clk                   (adc1_div_clk),
        .adc1_data_vld                  (adc1_data_vld),
        .adc1_data0                     (adc1_data0),
        .adc1_data1                     (adc1_data1),
        .adc1_data2                     (adc1_data2),
        .adc1_data3                     (adc1_data3),
        .adc1_data4                     (adc1_data4),
        .adc1_data5                     (adc1_data5),
        .adc1_data6                     (adc1_data6),
        .adc1_data7                     (adc1_data7),

        .adc2_div_clk                   (adc2_div_clk),
        .adc2_data_vld                  (adc2_data_vld),
        .adc2_data0                     (adc2_data0),
        .adc2_data1                     (adc2_data1),
        .adc2_data2                     (adc2_data2),
        .adc2_data3                     (adc2_data3),
        .adc2_data4                     (adc2_data4),
        .adc2_data5                     (adc2_data5),
        .adc2_data6                     (adc2_data6),
        .adc2_data7                     (adc2_data7),

        .adc1_filter_vld                (adc1_filter_vld),
        .adc1_filter_data0              (adc1_filter_data0),
        .adc1_filter_data1              (adc1_filter_data1),
        .adc1_filter_data2              (adc1_filter_data2),
        .adc1_filter_data3              (adc1_filter_data3),
        .adc1_filter_data4              (adc1_filter_data4),
        .adc1_filter_data5              (adc1_filter_data5),
        .adc1_filter_data6              (adc1_filter_data6),
        .adc1_filter_data7              (adc1_filter_data7),

        .adc2_filter_vld                (adc2_filter_vld),
        .adc2_filter_data0              (adc2_filter_data0),
        .adc2_filter_data1              (adc2_filter_data1),
        .adc2_filter_data2              (adc2_filter_data2),
        .adc2_filter_data3              (adc2_filter_data3),
        .adc2_filter_data4              (adc2_filter_data4),
        .adc2_filter_data5              (adc2_filter_data5),
        .adc2_filter_data6              (adc2_filter_data6),
        .adc2_filter_data7              (adc2_filter_data7),

        .adc1_filter_backpressure       (adc1_filter_backpressure),
        .adc2_filter_backpressure       (adc2_filter_backpressure)
    );

    // ------------------------------------------------------------------------
    // adc_en is sys_clk-domain control. Synchronize it before using it as
    // adc_clk-domain sync_en for the FIFO synchronizer.
    // ------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg         adc_en_adc_m;
    (* ASYNC_REG = "TRUE" *) reg         adc_en_adc_s;

    always @(posedge adc_clk or negedge reset_n) begin
        if (!reset_n) begin
            adc_en_adc_m <= 1'b0;
            adc_en_adc_s <= 1'b0;
        end
        else begin
            adc_en_adc_m <= adc_en;
            adc_en_adc_s <= adc_en_adc_m;
        end
    end

    // ------------------------------------------------------------------------
    // ADC1/ADC2 filtered data synchronization.
    // This adc_data_sync has no FIR and expects signed 16-bit filtered samples.
    // ------------------------------------------------------------------------
    adc_data_sync #(
        .STARTUP_WAIT_CYCLES            (STARTUP_WAIT_CYCLES),
        .PRELOAD_CYCLES                 (PRELOAD_CYCLES)
    ) adc_data_sync_inst (
        .adc_clk                        (adc_clk),
        .reset_n                        (reset_n),
        .sync_en                        (adc_en_adc_s),

        .active_ch_mask_cfg             (active_ch_mask_cfg),
        .trig_ch_mask_cfg               (trig_ch_mask_cfg),

        .adc1_div_clk                   (adc1_div_clk),
        .adc1_data_vld                  (adc1_filter_vld),
        .adc1_data0                     (adc1_filter_data0),
        .adc1_data1                     (adc1_filter_data1),
        .adc1_data2                     (adc1_filter_data2),
        .adc1_data3                     (adc1_filter_data3),
        .adc1_data4                     (adc1_filter_data4),
        .adc1_data5                     (adc1_filter_data5),
        .adc1_data6                     (adc1_filter_data6),
        .adc1_data7                     (adc1_filter_data7),

        .adc2_div_clk                   (adc2_div_clk),
        .adc2_data_vld                  (adc2_filter_vld),
        .adc2_data0                     (adc2_filter_data0),
        .adc2_data1                     (adc2_filter_data1),
        .adc2_data2                     (adc2_filter_data2),
        .adc2_data3                     (adc2_filter_data3),
        .adc2_data4                     (adc2_filter_data4),
        .adc2_data5                     (adc2_filter_data5),
        .adc2_data6                     (adc2_filter_data6),
        .adc2_data7                     (adc2_filter_data7),

        .cap_en_out                     (cap_en_out),
        .sample_valid                   (sample_valid),
        .sample_data                    (sample_data),
        .trigger_sample_data            (trigger_sample_data),
        .active_ch_mask                 (active_ch_mask),
        .trig_mask                      (trig_mask),
        .sync_ready                     (sync_ready),
        .sync_error                     (sync_error)
    );
    
generate
    if(ADC1_DEBUG_ILA) 
    begin : GEN_DEBUG_ILA_GET_ADC1_DATA
    ILA_ADC_DATA ILA_ADC_DATA_INST1 (
    .clk                                (adc_clk                   ),// input wire clk


    .probe0                             (adc1_data_vld             ),// input wire [0:0]  probe0  
    .probe1                             (adc1_filter_vld           ),// input wire [0:0]  probe1 
    .probe2                             (adc1_out_frame            ),// input wire [13:0]  probe2 
    .probe3                             (adc1_data1                ),// input wire [13:0]  probe3 
    .probe4                             (adc1_data2                ),// input wire [13:0]  probe4 
    .probe5                             (adc1_data3                ),// input wire [13:0]  probe5 
    .probe6                             (adc1_data4                ),// input wire [13:0]  probe6 
    .probe7                             (adc1_data5                ) // input wire [13:0]  probe7
    );
    end

    if(ADC2_DEBUG_ILA) 
    begin : GEN_DEBUG_ILA_GET_ADC2_DATA
    ILA_ADC_DATA ILA_ADC_DATA_INST2 (
    .clk                                (adc_clk                   ),// input wire clk


    .probe0                             (adc2_data_vld             ),// input wire [0:0]  probe0  
    .probe1                             (adc2_filter_vld           ),// input wire [0:0]  probe1 
    .probe2                             (adc2_out_frame            ),// input wire [13:0]  probe2 
    .probe3                             (adc2_data1                ),// input wire [13:0]  probe3 
    .probe4                             (adc2_data2                ),// input wire [13:0]  probe4 
    .probe5                             (adc2_data3                ),// input wire [13:0]  probe5 
    .probe6                             (adc2_data4                ),// input wire [13:0]  probe6 
    .probe7                             (adc2_data5                ) // input wire [13:0]  probe7
    );
    end
endgenerate

generate
    if(ILA_ADC1_FILTERED_DATA_EN) 
    begin:GEN_DEBUG_ILA_ADC1_FILTERED_DATA
    ILA_FILTERED_DATA ILA_FILTERED_DATA_INST1 (
    .clk                                (adc_clk                   ),// input wire clk
    .probe0                             (sample_valid              ),// input wire [0:0]  probe0  
    .probe1                             (adc1_filter_vld           ),// input wire [0:0]  probe1 
    .probe2                             (adc1_filter_data0         ),// input wire [15:0]  probe2 
    .probe3                             (adc1_filter_data1         ),// input wire [15:0]  probe3 
    .probe4                             (adc1_filter_data2         ),// input wire [15:0]  probe4 
    .probe5                             (adc1_filter_data3         ),// input wire [15:0]  probe5 
    .probe6                             (adc1_filter_data4         ),// input wire [15:0]  probe6 
    .probe7                             (adc1_filter_data5         ) // input wire [15:0]  probe7
    );
    end

    if(ILA_ADC2_FILTERED_DATA_EN) 
    begin:GEN_DEBUG_ILA_ADC2_FILTERED_DATA
    ILA_FILTERED_DATA ILA_FILTERED_DATA_INST2 (
    .clk                                (adc_clk                   ),// input wire clk
    .probe0                             (cap_en_out                ),// input wire [0:0]  probe0  
    .probe1                             (adc2_filter_vld           ),// input wire [0:0]  probe1 
    .probe2                             (adc2_filter_data0         ),// input wire [15:0]  probe2 
    .probe3                             (adc2_filter_data1         ),// input wire [15:0]  probe3 
    .probe4                             (adc2_filter_data2         ),// input wire [15:0]  probe4 
    .probe5                             (adc2_filter_data3         ),// input wire [15:0]  probe5 
    .probe6                             (adc2_filter_data4         ),// input wire [15:0]  probe6 
    .probe7                             (adc2_filter_data5         ) // input wire [15:0]  probe7
    );
    end
endgenerate

endmodule
