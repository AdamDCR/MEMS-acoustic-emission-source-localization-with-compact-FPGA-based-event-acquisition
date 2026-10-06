`timescale 1ns/1ps

// ============================================================
// LSM6DS3TR driver (I2C mode)
// 默认功能：
//   1) 通过 CSB=1 进入 I2C 模式
//   2) 配置 CTRL3_C = 0x44 (BDU=1, IF_INC=1)
//   3) 配置 CTRL2_G = 0x40 (Gyro ODR=104Hz, FS=245dps)
//   4) 周期性读取 OUTX_L_G ~ OUTZ_H_G 六个字节
//
// 输出：
//   gyro_x_raw / gyro_y_raw / gyro_z_raw : 三轴陀螺原始码
//   data_valid : 新数据有效脉冲
//
// 参数：
//   SA0_HIGH = 0 -> 7-bit地址 0x6A
//   SA0_HIGH = 1 -> 7-bit地址 0x6B
//
// 三段式状态机
// ============================================================
module lsm6ds3tr_driver #(
    parameter integer CLK_FREQ_HZ = 200_000_000,
    parameter integer I2C_FREQ_HZ = 100_000,
    parameter integer SA0_HIGH    = 0
)(
    input  wire              clk,
    input  wire              rst_n,

    // I2C pins
    input  wire              scl_i,
    input  wire              sda_i,
    output wire              scl_oe,
    output wire              sda_oe,

    // force I2C mode
    output wire              csb,

    // optional interrupt inputs from sensor
    input  wire              int1,
    input  wire              int2,

    output reg               data_valid,
    output reg               sensor_ok,
    output reg signed [15:0] gyro_x_raw,
    output reg signed [15:0] gyro_y_raw,
    output reg signed [15:0] gyro_z_raw
);

    localparam [7:0] DEV_W = (SA0_HIGH == 0) ? 8'hD4 : 8'hD6; // 7-bit: 0x6A/0x6B
    localparam [7:0] DEV_R = (SA0_HIGH == 0) ? 8'hD5 : 8'hD7;

    localparam integer MS_DIV = CLK_FREQ_HZ / 1000;

    // 寄存器地址
    localparam [7:0] REG_CTRL2_G = 8'h11;
    localparam [7:0] REG_CTRL3_C = 8'h12;
    localparam [7:0] REG_OUTX_L_G = 8'h22;

    // 状态定义
    localparam [5:0]
        S_PWRUP      = 6'd0,

        S_CFG1_ST    = 6'd1,
        S_CFG1_AW    = 6'd2,
        S_CFG1_RG    = 6'd3,
        S_CFG1_DT    = 6'd4,
        S_CFG1_SP    = 6'd5,

        S_CFG2_ST    = 6'd6,
        S_CFG2_AW    = 6'd7,
        S_CFG2_RG    = 6'd8,
        S_CFG2_DT    = 6'd9,
        S_CFG2_SP    = 6'd10,

        S_WAIT       = 6'd11,

        S_RD_ST1     = 6'd12,
        S_RD_AW      = 6'd13,
        S_RD_RG      = 6'd14,
        S_RD_ST2     = 6'd15,
        S_RD_AR      = 6'd16,

        S_RD_B0      = 6'd17,
        S_RD_B1      = 6'd18,
        S_RD_B2      = 6'd19,
        S_RD_B3      = 6'd20,
        S_RD_B4      = 6'd21,
        S_RD_B5      = 6'd22,

        S_RD_SP      = 6'd23,
        S_PARSE      = 6'd24;

    reg [5:0] state, next_state;

    reg [15:0] div_cnt;
    reg [15:0] ms_cnt;
    reg        issued;

    wire ms_tick = (div_cnt == MS_DIV - 1);

    reg        i2c_cmd_valid;
    reg [1:0]  i2c_cmd;
    reg [7:0]  i2c_tx;
    reg        i2c_read_ack;

    wire [7:0] i2c_rx;
    wire       i2c_ack_ok;
    wire       i2c_busy;
    wire       i2c_done;

    // data buffers
    reg [7:0] gxl, gxh, gyl, gyh, gzl, gzh;

    // 强制 I2C 模式：CSB=1
    assign csb = 1'b1;

    i2c_byte_ctrl #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .I2C_FREQ_HZ(I2C_FREQ_HZ)
    ) u_i2c (
        .clk      (clk),
        .rst_n    (rst_n),
        .sda_i    (sda_i),
        .scl_oe   (scl_oe),
        .sda_oe   (sda_oe),
        .cmd_valid(i2c_cmd_valid),
        .cmd      (i2c_cmd),
        .tx_byte  (i2c_tx),
        .read_ack (i2c_read_ack),
        .rx_byte  (i2c_rx),
        .ack_ok   (i2c_ack_ok),
        .busy     (i2c_busy),
        .done     (i2c_done)
    );

    // ========================================================
    // 1) 状态寄存器
    // ========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= S_PWRUP;
        else
            state <= next_state;
    end

    // ========================================================
    // 2) 次态逻辑
    // ========================================================
    always @(*) begin
        next_state = state;

        case (state)
            S_PWRUP:   if (ms_tick && (ms_cnt == 16'd20)) next_state = S_CFG1_ST;

            // 配置 CTRL3_C = 0x44
            S_CFG1_ST: if (i2c_done) next_state = S_CFG1_AW;
            S_CFG1_AW: if (i2c_done) next_state = S_CFG1_RG;
            S_CFG1_RG: if (i2c_done) next_state = S_CFG1_DT;
            S_CFG1_DT: if (i2c_done) next_state = S_CFG1_SP;
            S_CFG1_SP: if (i2c_done) next_state = S_CFG2_ST;

            // 配置 CTRL2_G = 0x40
            S_CFG2_ST: if (i2c_done) next_state = S_CFG2_AW;
            S_CFG2_AW: if (i2c_done) next_state = S_CFG2_RG;
            S_CFG2_RG: if (i2c_done) next_state = S_CFG2_DT;
            S_CFG2_DT: if (i2c_done) next_state = S_CFG2_SP;
            S_CFG2_SP: if (i2c_done) next_state = S_WAIT;

            // 等待新数据
            S_WAIT:    if (ms_tick && (ms_cnt == 16'd10)) next_state = S_RD_ST1;

            // 先写寄存器地址 0x22
            S_RD_ST1:  if (i2c_done) next_state = S_RD_AW;
            S_RD_AW:   if (i2c_done) next_state = S_RD_RG;
            S_RD_RG:   if (i2c_done) next_state = S_RD_ST2;

            // repeated start + read
            S_RD_ST2:  if (i2c_done) next_state = S_RD_AR;
            S_RD_AR:   if (i2c_done) next_state = S_RD_B0;
            S_RD_B0:   if (i2c_done) next_state = S_RD_B1;
            S_RD_B1:   if (i2c_done) next_state = S_RD_B2;
            S_RD_B2:   if (i2c_done) next_state = S_RD_B3;
            S_RD_B3:   if (i2c_done) next_state = S_RD_B4;
            S_RD_B4:   if (i2c_done) next_state = S_RD_B5;
            S_RD_B5:   if (i2c_done) next_state = S_RD_SP;
            S_RD_SP:   if (i2c_done) next_state = S_PARSE;

            S_PARSE:   next_state = S_WAIT;

            default:   next_state = S_PWRUP;
        endcase
    end

    // ========================================================
    // 3) 时序输出 / 数据通路
    // ========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt        <= 16'd0;
            ms_cnt         <= 16'd0;
            issued         <= 1'b0;

            i2c_cmd_valid  <= 1'b0;
            i2c_cmd        <= 2'd0;
            i2c_tx         <= 8'd0;
            i2c_read_ack   <= 1'b0;

            data_valid     <= 1'b0;
            sensor_ok      <= 1'b0;

            gyro_x_raw     <= 16'sd0;
            gyro_y_raw     <= 16'sd0;
            gyro_z_raw     <= 16'sd0;

            gxl <= 8'd0; gxh <= 8'd0;
            gyl <= 8'd0; gyh <= 8'd0;
            gzl <= 8'd0; gzh <= 8'd0;
        end else begin
            i2c_cmd_valid <= 1'b0;
            data_valid    <= 1'b0;

            // 1ms 分频
            if (div_cnt == MS_DIV - 1)
                div_cnt <= 16'd0;
            else
                div_cnt <= div_cnt + 16'd1;

            // 进入新状态后允许重新发命令
            if (state != next_state)
                issued <= 1'b0;

            case (state)
                S_PWRUP: begin
                    if (ms_tick) begin
                        if (ms_cnt == 16'd20)
                            ms_cnt <= 16'd0;
                        else
                            ms_cnt <= ms_cnt + 16'd1;
                    end
                end

                // ------------------------------------------------
                // CFG1: CTRL3_C = 0x44
                // BDU=1, IF_INC=1
                // ------------------------------------------------
                S_CFG1_ST: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd0; // START
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                end

                S_CFG1_AW: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd2; // WRITE
                        i2c_tx        <= DEV_W;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                    if (i2c_done && i2c_ack_ok)
                        sensor_ok <= 1'b1;
                end

                S_CFG1_RG: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd2;
                        i2c_tx        <= REG_CTRL3_C;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                end

                S_CFG1_DT: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd2;
                        i2c_tx        <= 8'h44;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                end

                S_CFG1_SP: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd1; // STOP
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                end

                // ------------------------------------------------
                // CFG2: CTRL2_G = 0x40
                // ODR_G=104Hz, FS_G=245dps
                // ------------------------------------------------
                S_CFG2_ST: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd0;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                end

                S_CFG2_AW: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd2;
                        i2c_tx        <= DEV_W;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                end

                S_CFG2_RG: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd2;
                        i2c_tx        <= REG_CTRL2_G;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                end

                S_CFG2_DT: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd2;
                        i2c_tx        <= 8'h40;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                end

                S_CFG2_SP: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd1;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                    if (i2c_done)
                        ms_cnt <= 16'd0;
                end

                // ------------------------------------------------
                // 周期等待
                // ------------------------------------------------
                S_WAIT: begin
                    if (ms_tick) begin
                        if (ms_cnt == 16'd10)
                            ms_cnt <= 16'd0;
                        else
                            ms_cnt <= ms_cnt + 16'd1;
                    end
                end

                // ------------------------------------------------
                // 读陀螺仪六字节
                // 先写起始寄存器地址 0x22
                // ------------------------------------------------
                S_RD_ST1: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd0;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                end

                S_RD_AW: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd2;
                        i2c_tx        <= DEV_W;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                end

                S_RD_RG: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd2;
                        i2c_tx        <= REG_OUTX_L_G;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                end

                S_RD_ST2: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd0; // repeated START
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                end

                S_RD_AR: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd2;
                        i2c_tx        <= DEV_R;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                end

                S_RD_B0: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd3;
                        i2c_read_ack  <= 1'b1;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                    if (i2c_done) gxl <= i2c_rx;
                end

                S_RD_B1: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd3;
                        i2c_read_ack  <= 1'b1;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                    if (i2c_done) gxh <= i2c_rx;
                end

                S_RD_B2: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd3;
                        i2c_read_ack  <= 1'b1;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                    if (i2c_done) gyl <= i2c_rx;
                end

                S_RD_B3: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd3;
                        i2c_read_ack  <= 1'b1;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                    if (i2c_done) gyh <= i2c_rx;
                end

                S_RD_B4: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd3;
                        i2c_read_ack  <= 1'b1;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                    if (i2c_done) gzl <= i2c_rx;
                end

                S_RD_B5: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd3;
                        i2c_read_ack  <= 1'b0; // 最后一个字节发送 NACK
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                    if (i2c_done) gzh <= i2c_rx;
                end

                S_RD_SP: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd1; // STOP
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                end

                // ------------------------------------------------
                // 数据拼接
                // ------------------------------------------------
                S_PARSE: begin
                    if (sensor_ok) begin
                        gyro_x_raw <= $signed({gxh, gxl});
                        gyro_y_raw <= $signed({gyh, gyl});
                        gyro_z_raw <= $signed({gzh, gzl});
                        data_valid <= 1'b1;
                    end
                end

                default: begin
                end
            endcase
        end
    end

endmodule
