`timescale 1ns / 1ps

(* use_dsp = "no" *)
module hp_iir_shift_4th_1ch #(
    parameter integer SAMPLE_W   = 16,
    parameter integer STATE_W    = 40,
    parameter integer STATE_FRAC = 16,
    parameter integer K0         = 10,
    parameter integer K1         = 10,
    parameter integer K2         = 12,
    parameter integer K3         = 12
)(
    input  wire                         clk,
    input  wire                         reset_n,
    input  wire                         in_valid,
    input  wire signed [SAMPLE_W-1:0]   x_in,
    output wire                         out_valid,
    output wire signed [SAMPLE_W-1:0]   y_out
);

    wire v0;
    wire v1;
    wire v2;
    wire v3;

    wire signed [SAMPLE_W-1:0] y0;
    wire signed [SAMPLE_W-1:0] y1;
    wire signed [SAMPLE_W-1:0] y2;
    wire signed [SAMPLE_W-1:0] y3;

    hp_iir_shift_1ch #(
        .SAMPLE_W   (SAMPLE_W),
        .STATE_W    (STATE_W),
        .STATE_FRAC (STATE_FRAC),
        .K          (K0)
    ) u_hp0 (
        .clk       (clk),
        .reset_n   (reset_n),
        .in_valid  (in_valid),
        .x_in      (x_in),
        .out_valid (v0),
        .y_out     (y0)
    );

    hp_iir_shift_1ch #(
        .SAMPLE_W   (SAMPLE_W),
        .STATE_W    (STATE_W),
        .STATE_FRAC (STATE_FRAC),
        .K          (K1)
    ) u_hp1 (
        .clk       (clk),
        .reset_n   (reset_n),
        .in_valid  (v0),
        .x_in      (y0),
        .out_valid (v1),
        .y_out     (y1)
    );

    hp_iir_shift_1ch #(
        .SAMPLE_W   (SAMPLE_W),
        .STATE_W    (STATE_W),
        .STATE_FRAC (STATE_FRAC),
        .K          (K2)
    ) u_hp2 (
        .clk       (clk),
        .reset_n   (reset_n),
        .in_valid  (v1),
        .x_in      (y1),
        .out_valid (v2),
        .y_out     (y2)
    );

    hp_iir_shift_1ch #(
        .SAMPLE_W   (SAMPLE_W),
        .STATE_W    (STATE_W),
        .STATE_FRAC (STATE_FRAC),
        .K          (K3)
    ) u_hp3 (
        .clk       (clk),
        .reset_n   (reset_n),
        .in_valid  (v2),
        .x_in      (y2),
        .out_valid (v3),
        .y_out     (y3)
    );

    assign out_valid = v3;
    assign y_out     = y3;

endmodule