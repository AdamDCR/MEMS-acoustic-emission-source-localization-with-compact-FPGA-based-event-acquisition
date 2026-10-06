`timescale 1ns/1ps

// ============================================================
// 1-Wire byte controller
// cmd:
//   2'd0 -> reset + presence detect
//   2'd1 -> write one byte (LSB first)
//   2'd2 -> read one byte  (LSB first)
// 三段式状态机：
//   1) 状态寄存器
//   2) 次态组合逻辑
//   3) 时序输出/数据通路
// ============================================================
module onewire_byte_ctrl #(
    parameter integer CLK_FREQ_HZ = 200_000_000
)(
    input  wire       clk,
    input  wire       rst_n,

    input  wire       dq_i,
    output reg        dq_oe,        // 1: 拉低总线; 0: 释放总线

    input  wire       cmd_valid,
    input  wire [1:0] cmd,
    input  wire [7:0] tx_byte,

    output reg  [7:0] rx_byte,
    output reg        presence_ok,
    output reg        busy,
    output reg        done
);

    localparam integer US_DIV = CLK_FREQ_HZ / 1_000_000;

    localparam [3:0]
        S_IDLE      = 4'd0,
        S_RST_LOW   = 4'd1,
        S_RST_REL   = 4'd2,
        S_RST_WAIT  = 4'd3,
        S_WR_LOW    = 4'd4,
        S_WR_SLOT   = 4'd5,
        S_RD_LOW    = 4'd6,
        S_RD_SAMPLE = 4'd7,
        S_RD_SLOT   = 4'd8;

    reg [3:0] state, next_state;

    reg [15:0] div_cnt;
    reg [19:0] us_cnt;
    reg [7:0]  shifter;
    reg [3:0]  bit_cnt;

    wire us_tick = (div_cnt == US_DIV - 1);

    // --------------------------------------------------------
    // 1) 状态寄存器
    // --------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= S_IDLE;
        else
            state <= next_state;
    end

    // --------------------------------------------------------
    // 2) 次态逻辑
    // --------------------------------------------------------
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE: begin
                if (cmd_valid) begin
                    case (cmd)
                        2'd0: next_state = S_RST_LOW;
                        2'd1: next_state = S_WR_LOW;
                        2'd2: next_state = S_RD_LOW;
                        default: next_state = S_IDLE;
                    endcase
                end
            end

            S_RST_LOW:   if (us_tick && (us_cnt == 0)) next_state = S_RST_REL;
            S_RST_REL:   if (us_tick && (us_cnt == 0)) next_state = S_RST_WAIT;
            S_RST_WAIT:  if (us_tick && (us_cnt == 0)) next_state = S_IDLE;

            S_WR_LOW:    if (us_tick && (us_cnt == 0)) next_state = S_WR_SLOT;
            S_WR_SLOT:   if (us_tick && (us_cnt == 0))
                            next_state = (bit_cnt == 4'd7) ? S_IDLE : S_WR_LOW;

            S_RD_LOW:    if (us_tick && (us_cnt == 0)) next_state = S_RD_SAMPLE;
            S_RD_SAMPLE: if (us_tick && (us_cnt == 0)) next_state = S_RD_SLOT;
            S_RD_SLOT:   if (us_tick && (us_cnt == 0))
                            next_state = (bit_cnt == 4'd7) ? S_IDLE : S_RD_LOW;

            default: next_state = S_IDLE;
        endcase
    end

    // --------------------------------------------------------
    // 3) 时序输出 / 数据通路
    // --------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dq_oe       <= 1'b0;
            rx_byte     <= 8'd0;
            presence_ok <= 1'b0;
            busy        <= 1'b0;
            done        <= 1'b0;
            div_cnt     <= 16'd0;
            us_cnt      <= 20'd0;
            shifter     <= 8'd0;
            bit_cnt     <= 4'd0;
        end else begin
            done <= 1'b0;

            // 1us 分频
            if (state == S_IDLE)
                div_cnt <= 16'd0;
            else if (us_tick)
                div_cnt <= 16'd0;
            else
                div_cnt <= div_cnt + 16'd1;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    dq_oe <= 1'b0;

                    if (cmd_valid) begin
                        busy        <= 1'b1;
                        presence_ok <= 1'b0;
                        bit_cnt     <= 4'd0;
                        shifter     <= tx_byte;

                        case (cmd)
                            2'd0: begin
                                dq_oe  <= 1'b1;      // reset: 先拉低
                                us_cnt <= 20'd500;   // 500us
                            end

                            2'd1: begin
                                dq_oe  <= 1'b1;      // write slot 起始拉低
                                us_cnt <= tx_byte[0] ? 20'd6 : 20'd60;
                            end

                            2'd2: begin
                                dq_oe   <= 1'b1;     // read slot 起始拉低
                                us_cnt  <= 20'd6;
                                shifter <= 8'd0;
                            end

                            default: begin
                                dq_oe  <= 1'b0;
                                us_cnt <= 20'd0;
                            end
                        endcase
                    end
                end

                // ---------- reset ----------
                S_RST_LOW: begin
                    if (us_tick) begin
                        if (us_cnt == 0) begin
                            dq_oe  <= 1'b0;       // 释放总线
                            us_cnt <= 20'd70;     // 70us 后采 presence
                        end else begin
                            us_cnt <= us_cnt - 20'd1;
                        end
                    end
                end

                S_RST_REL: begin
                    if (us_tick) begin
                        if (us_cnt == 0) begin
                            presence_ok <= ~dq_i; // presence 为低
                            us_cnt      <= 20'd410;
                        end else begin
                            us_cnt <= us_cnt - 20'd1;
                        end
                    end
                end

                S_RST_WAIT: begin
                    if (us_tick) begin
                        if (us_cnt == 0) begin
                            done <= 1'b1;
                            busy <= 1'b0;
                        end else begin
                            us_cnt <= us_cnt - 20'd1;
                        end
                    end
                end

                // ---------- write byte ----------
                S_WR_LOW: begin
                    if (us_tick) begin
                        if (us_cnt == 0) begin
                            dq_oe  <= 1'b0;   // 释放总线
                            us_cnt <= shifter[bit_cnt] ? 20'd64 : 20'd10;
                        end else begin
                            us_cnt <= us_cnt - 20'd1;
                        end
                    end
                end

                S_WR_SLOT: begin
                    if (us_tick) begin
                        if (us_cnt == 0) begin
                            if (bit_cnt == 4'd7) begin
                                done <= 1'b1;
                                busy <= 1'b0;
                            end else begin
                                bit_cnt <= bit_cnt + 4'd1;
                                dq_oe   <= 1'b1;
                                us_cnt  <= shifter[bit_cnt + 1] ? 20'd6 : 20'd60;
                            end
                        end else begin
                            us_cnt <= us_cnt - 20'd1;
                        end
                    end
                end

                // ---------- read byte ----------
                S_RD_LOW: begin
                    if (us_tick) begin
                        if (us_cnt == 0) begin
                            dq_oe  <= 1'b0;   // 释放总线，准备采样
                            us_cnt <= 20'd9;  // 约在 15us 左右采样
                        end else begin
                            us_cnt <= us_cnt - 20'd1;
                        end
                    end
                end

                S_RD_SAMPLE: begin
                    if (us_tick) begin
                        if (us_cnt == 0) begin
                            shifter[bit_cnt] <= dq_i;
                            us_cnt           <= 20'd55;
                        end else begin
                            us_cnt <= us_cnt - 20'd1;
                        end
                    end
                end

                S_RD_SLOT: begin
                    if (us_tick) begin
                        if (us_cnt == 0) begin
                            if (bit_cnt == 4'd7) begin
                                rx_byte <= shifter;
                                done    <= 1'b1;
                                busy    <= 1'b0;
                            end else begin
                                bit_cnt <= bit_cnt + 4'd1;
                                dq_oe   <= 1'b1;
                                us_cnt  <= 20'd6;
                            end
                        end else begin
                            us_cnt <= us_cnt - 20'd1;
                        end
                    end
                end

                default: begin
                    busy <= 1'b0;
                    dq_oe <= 1'b0;
                end
            endcase
        end
    end

endmodule