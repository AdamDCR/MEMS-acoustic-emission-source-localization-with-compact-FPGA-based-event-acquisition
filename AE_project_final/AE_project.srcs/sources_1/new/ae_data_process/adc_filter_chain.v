`timescale 1ns / 1ps
// ============================================================================
// File        : adc_filter_chain.v
// Top module  : adc_filter_chain
//
// Position in your data path:
//   get_adc_data_inst1/2
//        -> adc_filter_chain
//        -> adc_data_sync with its internal FIR removed
//        -> top/AE or later processing
//
// Per-channel pipeline:
//   14-bit ADC sample
//        -> optional offset-binary to two's-complement conversion
//        -> sign extension to 16 bit
//        -> 4th-order IIR high-pass, Butterworth, Fc = 10 kHz, Fs = 40 MHz
//        -> fir_500k_lp FIR Compiler IP
//        -> signed 16-bit filtered output
//
// Important assumptions:
//   1. adc1_div_clk/adc2_div_clk are 40 MHz sample clocks.
//   2. fir_500k_lp has the exact AXI-Stream ports shown by you:
//        aresetn, aclk, aclken,
//        s_axis_data_tvalid, s_axis_data_tready, s_axis_data_tdata[15:0],
//        m_axis_data_tvalid, m_axis_data_tdata[31:0]
//   3. The ADC stream cannot be back-pressured. Therefore fir_backpressure is a
//      sticky diagnostic flag. In a healthy design the FIR IP tready should stay
//      high whenever sample_valid is high.
//   4. FIR_OUT_SHIFT must match the FIR Compiler output scaling. The generated
//      63-tap coefficient set sums to 65536, so the default unity-gain scaling
//      is right shift by 16.
// ============================================================================

module adc_filter_chain #(
    parameter integer INPUT_IS_OFFSET_BINARY = 0,
    parameter integer FIR_OUT_SHIFT          = 16
)(
    input                               reset_n,

    // ------------------------------------------------------------------------
    // ADC1 raw input from get_adc_data_inst1, adc1_div_clk domain
    // ------------------------------------------------------------------------
    input                               adc1_div_clk,
    input                               adc1_data_vld,
    input      [13:0]                   adc1_data0,
    input      [13:0]                   adc1_data1,
    input      [13:0]                   adc1_data2,
    input      [13:0]                   adc1_data3,
    input      [13:0]                   adc1_data4,
    input      [13:0]                   adc1_data5,
    input      [13:0]                   adc1_data6,
    input      [13:0]                   adc1_data7,

    // ------------------------------------------------------------------------
    // ADC2 raw input from get_adc_data_inst2, adc2_div_clk domain
    // ------------------------------------------------------------------------
    input                               adc2_div_clk,
    input                               adc2_data_vld,
    input      [13:0]                   adc2_data0,
    input      [13:0]                   adc2_data1,
    input      [13:0]                   adc2_data2,
    input      [13:0]                   adc2_data3,
    input      [13:0]                   adc2_data4,
    input      [13:0]                   adc2_data5,
    input      [13:0]                   adc2_data6,
    input      [13:0]                   adc2_data7,

    // ------------------------------------------------------------------------
    // ADC1 filtered output, still adc1_div_clk domain
    // ------------------------------------------------------------------------
    output                              adc1_filter_vld,
    output     signed [15:0]            adc1_filter_data0,
    output     signed [15:0]            adc1_filter_data1,
    output     signed [15:0]            adc1_filter_data2,
    output     signed [15:0]            adc1_filter_data3,
    output     signed [15:0]            adc1_filter_data4,
    output     signed [15:0]            adc1_filter_data5,
    output     signed [15:0]            adc1_filter_data6,
    output     signed [15:0]            adc1_filter_data7,

    // ------------------------------------------------------------------------
    // ADC2 filtered output, still adc2_div_clk domain
    // ------------------------------------------------------------------------
    output                              adc2_filter_vld,
    output     signed [15:0]            adc2_filter_data0,
    output     signed [15:0]            adc2_filter_data1,
    output     signed [15:0]            adc2_filter_data2,
    output     signed [15:0]            adc2_filter_data3,
    output     signed [15:0]            adc2_filter_data4,
    output     signed [15:0]            adc2_filter_data5,
    output     signed [15:0]            adc2_filter_data6,
    output     signed [15:0]            adc2_filter_data7,

    // Sticky diagnostic flags. Clear only by reset_n.
    output                              adc1_filter_backpressure,
    output                              adc2_filter_backpressure
);

    adc_filter_8ch #(
        .INPUT_IS_OFFSET_BINARY         (INPUT_IS_OFFSET_BINARY),
        .FIR_OUT_SHIFT                  (FIR_OUT_SHIFT)
    ) u_adc1_filter_8ch (
        .clk                            (adc1_div_clk),
        .reset_n                        (reset_n),
        .data_vld                       (adc1_data_vld),
        .data0                          (adc1_data0),
        .data1                          (adc1_data1),
        .data2                          (adc1_data2),
        .data3                          (adc1_data3),
        .data4                          (adc1_data4),
        .data5                          (adc1_data5),
        .data6                          (adc1_data6),
        .data7                          (adc1_data7),
        .filter_vld                     (adc1_filter_vld),
        .filter_data0                   (adc1_filter_data0),
        .filter_data1                   (adc1_filter_data1),
        .filter_data2                   (adc1_filter_data2),
        .filter_data3                   (adc1_filter_data3),
        .filter_data4                   (adc1_filter_data4),
        .filter_data5                   (adc1_filter_data5),
        .filter_data6                   (adc1_filter_data6),
        .filter_data7                   (adc1_filter_data7),
        .filter_backpressure            (adc1_filter_backpressure)
    );

    adc_filter_8ch #(
        .INPUT_IS_OFFSET_BINARY         (INPUT_IS_OFFSET_BINARY),
        .FIR_OUT_SHIFT                  (FIR_OUT_SHIFT)
    ) u_adc2_filter_8ch (
        .clk                            (adc2_div_clk),
        .reset_n                        (reset_n),
        .data_vld                       (adc2_data_vld),
        .data0                          (adc2_data0),
        .data1                          (adc2_data1),
        .data2                          (adc2_data2),
        .data3                          (adc2_data3),
        .data4                          (adc2_data4),
        .data5                          (adc2_data5),
        .data6                          (adc2_data6),
        .data7                          (adc2_data7),
        .filter_vld                     (adc2_filter_vld),
        .filter_data0                   (adc2_filter_data0),
        .filter_data1                   (adc2_filter_data1),
        .filter_data2                   (adc2_filter_data2),
        .filter_data3                   (adc2_filter_data3),
        .filter_data4                   (adc2_filter_data4),
        .filter_data5                   (adc2_filter_data5),
        .filter_data6                   (adc2_filter_data6),
        .filter_data7                   (adc2_filter_data7),
        .filter_backpressure            (adc2_filter_backpressure)
    );

endmodule
