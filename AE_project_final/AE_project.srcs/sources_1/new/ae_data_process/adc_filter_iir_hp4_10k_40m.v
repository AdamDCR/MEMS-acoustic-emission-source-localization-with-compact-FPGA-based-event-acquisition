    `timescale 1ns / 1ps
    
    (* use_dsp = "no" *)
    module adc_filter_iir_hp4_10k_40m #(
    parameter integer SAMPLE_W   = 16,
    parameter integer STATE_W    = 40,
    parameter integer STATE_FRAC = 16,
    
    // 40 MHz 采样下的移位高通近似。
    // K 越小，高通截止越高、恢复越快；
    // K 越大，高通截止越低、恢复越慢。
    parameter integer K0         = 10,
    parameter integer K1         = 10,
    parameter integer K2         = 12,
    parameter integer K3         = 12
    )(
    input                               clk                        ,
    input                               reset_n                    ,
    input                               sample_valid               ,
    input        signed  [  15: 0]      sample_in                  ,
    
    output                              sample_out_valid           ,
    output       signed  [  15: 0]      sample_out                  
    );
    
    hp_iir_shift_4th_1ch #(
    .SAMPLE_W                           (SAMPLE_W                  ),
    .STATE_W                            (STATE_W                   ),
    .STATE_FRAC                         (STATE_FRAC                ),
    .K0                                 (K0                        ),
    .K1                                 (K1                        ),
    .K2                                 (K2                        ),
    .K3                                 (K3                        ) 
    ) u_hp_iir_shift_4th_1ch (
    .clk                                (clk                       ),
    .reset_n                            (reset_n                   ),
    .in_valid                           (sample_valid              ),
    .x_in                               (sample_in                 ),
    .out_valid                          (sample_out_valid          ),
    .y_out                              (sample_out                ) 
    );
    
    endmodule