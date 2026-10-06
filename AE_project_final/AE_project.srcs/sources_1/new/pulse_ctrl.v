`timescale 1ns/1ps

module pulse_ctrl(
    input               sys_clk,
    input               reset_n,
    input               pulse_out_en,
    input       [31:0]  pulsePar1,       // [31:16] frequency(kHz), [15:8] pulse count, [7:0] duty
    input       [31:0]  pulse_phase,
    input       [15:0]  pulse_gap,       // us
    input               pulse_en,
    output  reg [2:0]   pulse_ctrl_data
);

    parameter integer SYSTEM_FREQ = 200; // MHz

    localparam [31:0] PERIOD_DIVIDEND = SYSTEM_FREQ * 1000;
    localparam [31:0] DUTY_DIVISOR    = 32'd200;

    localparam [2:0] CALC_IDLE        = 3'd0;
    localparam [2:0] CALC_DIV_PERIOD  = 3'd1;
    localparam [2:0] CALC_MUL_DUTY    = 3'd2;
    localparam [2:0] CALC_ACCUM_DUTY  = 3'd3;
    localparam [2:0] CALC_START_DUTY  = 3'd4;
    localparam [2:0] CALC_DIV_DUTY    = 3'd5;
    localparam [2:0] CALC_COMMIT      = 3'd6;

    wire [15:0] pulse_freq_w = {pulsePar1[23:16], pulsePar1[31:24]};
    wire [ 7:0] pulse_duty_w = pulsePar1[7:0];
    wire [ 7:0] pulse_num_w  = pulsePar1[15:8];

    reg  [31:0] pulsePar1_cfg;
    reg  [31:0] pulse_phase_cfg;
    reg  [15:0] pulse_gap_cfg;
    reg  [ 7:0] pulse_duty_cfg;
    reg  [ 7:0] pulse_num;
    reg         params_ready;

    reg  [31:0] clk_counter;
    reg  [31:0] pulse_count;
    reg  [31:0] pulse_gap_cycles;
    reg  [31:0] pulse_period;
    reg  [31:0] duty_high;
    reg  [31:0] duty_low;
    reg  [31:0] duty_ground_side;
    reg  [31:0] duty_ground_mid;
    reg  [ 3:0] pulse_step;
    reg  [31:0] pulse_duty_cnt;

    reg  [ 2:0] calc_state;
    reg  [31:0] div_divisor;
    reg  [31:0] div_quotient;
    reg  [31:0] div_remainder;
    reg  [31:0] period_calc;
    reg  [31:0] duty_product;
    reg  [31:0] duty_accum;
    reg  [ 7:0] duty_accum_count;
    reg  [31:0] duty_high_calc;

    reg  [31:0] ground_total_next;
    reg  [31:0] ground_side_next;

    wire params_changed = (pulsePar1_cfg   != pulsePar1) ||
                          (pulse_phase_cfg != pulse_phase) ||
                          (pulse_gap_cfg   != pulse_gap);
    wire pulse_active = pulse_en && pulse_out_en && params_ready;

    always @(posedge sys_clk or negedge reset_n) begin
        if (!reset_n) begin
            pulsePar1_cfg      <= 32'd0;
            pulse_phase_cfg    <= 32'd0;
            pulse_gap_cfg      <= 16'd0;
            pulse_duty_cfg     <= 8'd0;
            pulse_num          <= 8'd0;
            params_ready       <= 1'b0;
            pulse_gap_cycles   <= 32'd0;
            pulse_period       <= 32'd0;
            duty_high          <= 32'd0;
            duty_low           <= 32'd0;
            duty_ground_side   <= 32'd0;
            duty_ground_mid    <= 32'd0;
            calc_state         <= CALC_IDLE;
            div_divisor        <= 32'd1;
            div_quotient       <= 32'd0;
            div_remainder      <= 32'd0;
            period_calc        <= 32'd0;
            duty_product       <= 32'd0;
            duty_accum         <= 32'd0;
            duty_accum_count   <= 8'd0;
            duty_high_calc     <= 32'd0;
        end
        else begin
            case (calc_state)
                CALC_IDLE: begin
                    if (params_changed) begin
                        pulsePar1_cfg    <= pulsePar1;
                        pulse_phase_cfg  <= pulse_phase;
                        pulse_gap_cfg    <= pulse_gap;
                        pulse_duty_cfg   <= pulse_duty_w;
                        pulse_num        <= pulse_num_w;
                        pulse_gap_cycles <= (({16'd0, pulse_gap} << 7) +
                                             ({16'd0, pulse_gap} << 6) +
                                             ({16'd0, pulse_gap} << 3));
                        params_ready     <= 1'b0;
                        div_divisor      <= (pulse_freq_w == 16'd0) ? 32'd1 : {16'd0, pulse_freq_w};
                        div_quotient     <= 32'd0;
                        div_remainder    <= PERIOD_DIVIDEND;
                        calc_state       <= CALC_DIV_PERIOD;
                    end
                end

                CALC_DIV_PERIOD: begin
                    if (div_remainder >= div_divisor) begin
                        div_remainder <= div_remainder - div_divisor;
                        div_quotient  <= div_quotient + 1'b1;
                    end
                    else begin
                        period_calc <= div_quotient;
                        calc_state  <= CALC_MUL_DUTY;
                    end
                end

                CALC_MUL_DUTY: begin
                    duty_accum       <= 32'd0;
                    duty_accum_count <= pulse_duty_cfg;
                    calc_state       <= CALC_ACCUM_DUTY;
                end

                CALC_ACCUM_DUTY: begin
                    if (duty_accum_count == 8'd0) begin
                        duty_product <= duty_accum;
                        calc_state   <= CALC_START_DUTY;
                    end
                    else begin
                        duty_accum       <= duty_accum + period_calc;
                        duty_accum_count <= duty_accum_count - 1'b1;
                    end
                end

                CALC_START_DUTY: begin
                    div_divisor   <= DUTY_DIVISOR;
                    div_quotient  <= 32'd0;
                    div_remainder <= duty_product;
                    calc_state    <= CALC_DIV_DUTY;
                end

                CALC_DIV_DUTY: begin
                    if (div_remainder >= div_divisor) begin
                        div_remainder <= div_remainder - div_divisor;
                        div_quotient  <= div_quotient + 1'b1;
                    end
                    else begin
                        duty_high_calc <= div_quotient;
                        calc_state     <= CALC_COMMIT;
                    end
                end

                CALC_COMMIT: begin
                    pulse_period <= period_calc;
                    duty_high    <= duty_high_calc;
                    duty_low     <= duty_high_calc;

                    if (period_calc > (duty_high_calc << 1)) begin
                        ground_total_next = period_calc - (duty_high_calc << 1);
                        ground_side_next  = ground_total_next >> 2;
                        duty_ground_side  <= ground_side_next;
                        duty_ground_mid   <= ground_total_next - (ground_side_next << 1);
                    end
                    else begin
                        duty_ground_side <= 32'd0;
                        duty_ground_mid  <= 32'd0;
                    end

                    params_ready <= 1'b1;
                    calc_state   <= CALC_IDLE;
                end

                default: begin
                    calc_state <= CALC_IDLE;
                end
            endcase
        end
    end

    always @(posedge sys_clk or negedge reset_n) begin
        if (!reset_n) begin
            clk_counter <= 32'd0;
        end
        else if (pulse_active) begin
            if (pulse_gap_cycles == 32'd0 || clk_counter >= pulse_gap_cycles) begin
                clk_counter <= 32'd0;
            end
            else begin
                clk_counter <= clk_counter + 1'b1;
            end
        end
        else begin
            clk_counter <= 32'd0;
        end
    end

    always @(posedge sys_clk or negedge reset_n) begin
        if (!reset_n) begin
            pulse_step      <= 4'd0;
            pulse_ctrl_data <= 3'b000;
            pulse_duty_cnt  <= 32'd0;
            pulse_count     <= 32'd0;
        end
        else if (pulse_active) begin
            if (clk_counter == 32'd0) begin
                pulse_step      <= 4'd0;
                pulse_ctrl_data <= 3'b000;
                pulse_duty_cnt  <= 32'd0;
                pulse_count     <= 32'd0;
            end
            else if (clk_counter >= pulse_phase_cfg && pulse_count < {24'd0, pulse_num}) begin
                case (pulse_step)
                    4'd0: begin
                        pulse_ctrl_data <= 3'b001;
                        if (pulse_duty_cnt >= duty_ground_side) begin
                            pulse_step     <= 4'd1;
                            pulse_duty_cnt <= 32'd0;
                        end
                        else begin
                            pulse_duty_cnt <= pulse_duty_cnt + 1'b1;
                        end
                    end
                    4'd1: begin
                        pulse_ctrl_data <= 3'b100;
                        if (pulse_duty_cnt >= duty_high) begin
                            pulse_step     <= 4'd2;
                            pulse_duty_cnt <= 32'd0;
                        end
                        else begin
                            pulse_duty_cnt <= pulse_duty_cnt + 1'b1;
                        end
                    end
                    4'd2: begin
                        pulse_ctrl_data <= 3'b001;
                        if (pulse_duty_cnt >= duty_ground_mid) begin
                            pulse_step     <= 4'd3;
                            pulse_duty_cnt <= 32'd0;
                        end
                        else begin
                            pulse_duty_cnt <= pulse_duty_cnt + 1'b1;
                        end
                    end
                    4'd3: begin
                        pulse_ctrl_data <= 3'b010;
                        if (pulse_duty_cnt >= duty_low) begin
                            pulse_step     <= 4'd4;
                            pulse_duty_cnt <= 32'd0;
                        end
                        else begin
                            pulse_duty_cnt <= pulse_duty_cnt + 1'b1;
                        end
                    end
                    4'd4: begin
                        pulse_ctrl_data <= 3'b001;
                        if (pulse_duty_cnt >= duty_ground_side) begin
                            pulse_step     <= 4'd0;
                            pulse_duty_cnt <= 32'd0;
                            pulse_count    <= pulse_count + 1'b1;
                        end
                        else begin
                            pulse_duty_cnt <= pulse_duty_cnt + 1'b1;
                        end
                    end
                    default: begin
                        pulse_step <= 4'd0;
                    end
                endcase
            end
            else begin
                pulse_ctrl_data <= 3'b000;
                pulse_step      <= 4'd0;
                pulse_duty_cnt  <= 32'd0;
            end
        end
        else begin
            pulse_step      <= 4'd0;
            pulse_ctrl_data <= 3'b000;
            pulse_duty_cnt  <= 32'd0;
            pulse_count     <= 32'd0;
        end
    end

endmodule
