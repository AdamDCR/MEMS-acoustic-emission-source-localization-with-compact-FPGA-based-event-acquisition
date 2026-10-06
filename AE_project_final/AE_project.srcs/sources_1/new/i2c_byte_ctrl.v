`timescale 1ns/1ps

// ============================================================
// I2C byte controller
// cmd:
//   2'd0 -> START
//   2'd1 -> STOP
//   2'd2 -> WRITE 1 byte
//   2'd3 -> READ  1 byte
//
// 接口说明：
//   scl_oe = 1 -> 拉低 SCL
//   scl_oe = 0 -> 释放 SCL
//   sda_oe = 1 -> 拉低 SDA
//   sda_oe = 0 -> 释放 SDA
//
// 三段式状态机：
//   1) 状态寄存器
//   2) 次态组合逻辑
//   3) 时序输出/数据通路
// ============================================================
module i2c_byte_ctrl #(
    parameter integer CLK_FREQ_HZ = 200_000_000,
    parameter integer I2C_FREQ_HZ = 100_000
)(
    input  wire       clk,
    input  wire       rst_n,

    input  wire       sda_i,
    output reg        scl_oe,
    output reg        sda_oe,

    input  wire       cmd_valid,
    input  wire [1:0] cmd,
    input  wire [7:0] tx_byte,
    input  wire       read_ack,   // READ 后是否发送 ACK: 1=ACK, 0=NACK

    output reg  [7:0] rx_byte,
    output reg        ack_ok,
    output reg        busy,
    output reg        done
);

    localparam integer HALF_DIV = CLK_FREQ_HZ / (I2C_FREQ_HZ * 2);

    localparam [3:0]
        S_IDLE        = 4'd0,
        S_START_0     = 4'd1,
        S_START_1     = 4'd2,
        S_STOP_0      = 4'd3,
        S_STOP_1      = 4'd4,
        S_WR_BIT_0    = 4'd5,
        S_WR_BIT_1    = 4'd6,
        S_WR_ACK_0    = 4'd7,
        S_WR_ACK_1    = 4'd8,
        S_RD_BIT_0    = 4'd9,
        S_RD_BIT_1    = 4'd10,
        S_RD_ACK_0    = 4'd11,
        S_RD_ACK_1    = 4'd12;

    reg [3:0] state, next_state;

    reg [15:0] div_cnt;
    reg [7:0]  shifter;
    reg [3:0]  bit_cnt;
    reg        read_ack_r;

    wire tick = (div_cnt == HALF_DIV - 1);

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
                        2'd0: next_state = S_START_0;
                        2'd1: next_state = S_STOP_0;
                        2'd2: next_state = S_WR_BIT_0;
                        2'd3: next_state = S_RD_BIT_0;
                        default: next_state = S_IDLE;
                    endcase
                end
            end

            S_START_0:   if (tick) next_state = S_START_1;
            S_START_1:   if (tick) next_state = S_IDLE;

            S_STOP_0:    if (tick) next_state = S_STOP_1;
            S_STOP_1:    if (tick) next_state = S_IDLE;

            S_WR_BIT_0:  if (tick) next_state = S_WR_BIT_1;
            S_WR_BIT_1:  if (tick) begin
                            if (bit_cnt == 4'd0)
                                next_state = S_WR_ACK_0;
                            else
                                next_state = S_WR_BIT_0;
                         end
            S_WR_ACK_0:  if (tick) next_state = S_WR_ACK_1;
            S_WR_ACK_1:  if (tick) next_state = S_IDLE;

            S_RD_BIT_0:  if (tick) next_state = S_RD_BIT_1;
            S_RD_BIT_1:  if (tick) begin
                            if (bit_cnt == 4'd0)
                                next_state = S_RD_ACK_0;
                            else
                                next_state = S_RD_BIT_0;
                         end
            S_RD_ACK_0:  if (tick) next_state = S_RD_ACK_1;
            S_RD_ACK_1:  if (tick) next_state = S_IDLE;

            default: next_state = S_IDLE;
        endcase
    end

    // --------------------------------------------------------
    // 3) 时序输出 / 数据通路
    // --------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_oe     <= 1'b0;
            sda_oe     <= 1'b0;
            rx_byte    <= 8'd0;
            ack_ok     <= 1'b0;
            busy       <= 1'b0;
            done       <= 1'b0;
            div_cnt    <= 16'd0;
            shifter    <= 8'd0;
            bit_cnt    <= 4'd0;
            read_ack_r <= 1'b0;
        end else begin
            done <= 1'b0;

            if (state == S_IDLE)
                div_cnt <= 16'd0;
            else if (tick)
                div_cnt <= 16'd0;
            else
                div_cnt <= div_cnt + 16'd1;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (cmd_valid) begin
                        busy       <= 1'b1;
                        shifter    <= tx_byte;
                        bit_cnt    <= 4'd7;
                        read_ack_r <= read_ack;
                        ack_ok     <= 1'b0;
                    end
                end

                // ---------- START ----------
                S_START_0: begin
                    // SCL=1, SDA:1->0
                    scl_oe <= 1'b0;
                    sda_oe <= 1'b1;
                end

                S_START_1: begin
                    // 拉低 SCL，完成 start
                    scl_oe <= 1'b1;
                    sda_oe <= 1'b1;
                    if (tick) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                    end
                end

                // ---------- STOP ----------
                S_STOP_0: begin
                    // SCL=0, SDA=0
                    scl_oe <= 1'b1;
                    sda_oe <= 1'b1;
                end

                S_STOP_1: begin
                    // SCL=1, SDA:0->1
                    scl_oe <= 1'b0;
                    sda_oe <= 1'b0;
                    if (tick) begin
                        busy <= 1'b0;
                        done <= 1'b1;
                    end
                end

                // ---------- WRITE ----------
                S_WR_BIT_0: begin
                    // SCL 低期间放数据
                    scl_oe <= 1'b1;
                    sda_oe <= ~shifter[bit_cnt]; // 发送0=>拉低, 发送1=>释放
                end

                S_WR_BIT_1: begin
                    // SCL 拉高，目标器件采样
                    scl_oe <= 1'b0;
                    if (tick && bit_cnt != 0)
                        bit_cnt <= bit_cnt - 4'd1;
                end

                S_WR_ACK_0: begin
                    // 释放 SDA，准备读 ACK
                    scl_oe <= 1'b1;
                    sda_oe <= 1'b0;
                end

                S_WR_ACK_1: begin
                    scl_oe <= 1'b0;
                    ack_ok <= ~sda_i; // ACK=0
                    if (tick) begin
                        scl_oe <= 1'b1;
                        busy   <= 1'b0;
                        done   <= 1'b1;
                    end
                end

                // ---------- READ ----------
                S_RD_BIT_0: begin
                    // 释放 SDA，准备从机驱动
                    scl_oe <= 1'b1;
                    sda_oe <= 1'b0;
                end

                S_RD_BIT_1: begin
                    // SCL 高期间采样
                    scl_oe <= 1'b0;
                    shifter[bit_cnt] <= sda_i;
                    if (tick && bit_cnt != 0)
                        bit_cnt <= bit_cnt - 4'd1;
                end

                S_RD_ACK_0: begin
                    // 发送主机 ACK/NACK
                    scl_oe <= 1'b1;
                    sda_oe <= read_ack_r ? 1'b1 : 1'b0; // ACK=拉低, NACK=释放
                end

                S_RD_ACK_1: begin
                    scl_oe  <= 1'b0;
                    rx_byte <= shifter;
                    if (tick) begin
                        scl_oe <= 1'b1;
                        sda_oe <= 1'b0;
                        busy   <= 1'b0;
                        done   <= 1'b1;
                    end
                end

                default: begin
                    busy <= 1'b0;
                end
            endcase
        end
    end

endmodule