`timescale 1ns/1ps

// ============================================================
// AHT20 driver
// 输出：
//   humidity_centi    : 0.01 %RH
//   temperature_centi : 0.01 摄氏度
//
// 流程：
//   1. 上电等待 >40ms
//   2. 初始化：0x70 0xBE 0x08 0x00
//   3. 测量：  0x70 0xAC 0x33 0x00
//   4. 等待 ~80ms
//   5. 读取 7 字节
//   6. 解析湿度和温度
//
// 三段式状态机
// ============================================================
module aht20_driver #(
    parameter integer CLK_FREQ_HZ = 200_000_000,
    parameter integer I2C_FREQ_HZ = 100_000
)(
    input  wire              clk,
    input  wire              rst_n,

    input  wire              scl_i,
    input  wire              sda_i,
    output wire              scl_oe,
    output wire              sda_oe,

    output reg               data_valid,
    output reg [15:0]        humidity_centi,
    output reg signed [15:0] temperature_centi
);

    localparam [7:0] DEV_W = 8'h70; // 7-bit地址0x38，写
    localparam [7:0] DEV_R = 8'h71; // 7-bit地址0x38，读
    localparam integer MS_DIV = CLK_FREQ_HZ / 1000;

    localparam [5:0]
        S_PWRUP      = 6'd0,

        S_I_START    = 6'd1,
        S_I_ADDR     = 6'd2,
        S_I_CMD      = 6'd3,
        S_I_D1       = 6'd4,
        S_I_D2       = 6'd5,
        S_I_STOP     = 6'd6,
        S_I_WAIT     = 6'd7,

        S_M_START    = 6'd8,
        S_M_ADDR     = 6'd9,
        S_M_CMD      = 6'd10,
        S_M_D1       = 6'd11,
        S_M_D2       = 6'd12,
        S_M_STOP     = 6'd13,
        S_M_WAIT     = 6'd14,

        S_R_START    = 6'd15,
        S_R_ADDR     = 6'd16,
        S_R_B0       = 6'd17,
        S_R_B1       = 6'd18,
        S_R_B2       = 6'd19,
        S_R_B3       = 6'd20,
        S_R_B4       = 6'd21,
        S_R_B5       = 6'd22,
        S_R_B6       = 6'd23,
        S_R_STOP     = 6'd24,

        S_PARSE      = 6'd25;

    reg [5:0] state, next_state;

    reg [15:0] div_cnt;
    reg [15:0] ms_cnt;
    reg        issued;

    reg        i2c_cmd_valid;
    reg [1:0]  i2c_cmd;
    reg [7:0]  i2c_tx;
    reg        i2c_read_ack;
    wire [7:0] i2c_rx;
    wire       i2c_ack_ok;
    wire       i2c_busy;
    wire       i2c_done;
    reg [7:0] b0, b1, b2, b3, b4, b5, b6;

    reg [19:0] hum_raw;
    reg [19:0] temp_raw;
    reg [39:0] calc_tmp;
    reg        sensor_ack_seen;

    wire ms_tick = (div_cnt == MS_DIV - 1);

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

    // --------------------------------------------------------
    // 1) 状态寄存器
    // --------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= S_PWRUP;
        else
            state <= next_state;
    end

    // --------------------------------------------------------
    // 2) 次态逻辑
    // --------------------------------------------------------
    always @(*) begin
        next_state = state;
        case (state)
            S_PWRUP:   if (ms_tick && (ms_cnt == 16'd40)) next_state = S_I_START;

            // init
            S_I_START: if (i2c_done) next_state = S_I_ADDR;
            S_I_ADDR : if (i2c_done) next_state = S_I_CMD;
            S_I_CMD  : if (i2c_done) next_state = S_I_D1;
            S_I_D1   : if (i2c_done) next_state = S_I_D2;
            S_I_D2   : if (i2c_done) next_state = S_I_STOP;
            S_I_STOP : if (i2c_done) next_state = S_I_WAIT;
            S_I_WAIT : if (ms_tick && (ms_cnt == 16'd10)) next_state = S_M_START;

            // measure
            S_M_START: if (i2c_done) next_state = S_M_ADDR;
            S_M_ADDR : if (i2c_done) next_state = S_M_CMD;
            S_M_CMD  : if (i2c_done) next_state = S_M_D1;
            S_M_D1   : if (i2c_done) next_state = S_M_D2;
            S_M_D2   : if (i2c_done) next_state = S_M_STOP;
            S_M_STOP : if (i2c_done) next_state = S_M_WAIT;
            S_M_WAIT : if (ms_tick && (ms_cnt == 16'd80)) next_state = S_R_START;

            // read
            S_R_START: if (i2c_done) next_state = S_R_ADDR;
            S_R_ADDR : if (i2c_done) next_state = S_R_B0;
            S_R_B0   : if (i2c_done) next_state = S_R_B1;
            S_R_B1   : if (i2c_done) next_state = S_R_B2;
            S_R_B2   : if (i2c_done) next_state = S_R_B3;
            S_R_B3   : if (i2c_done) next_state = S_R_B4;
            S_R_B4   : if (i2c_done) next_state = S_R_B5;
            S_R_B5   : if (i2c_done) next_state = S_R_B6;
            S_R_B6   : if (i2c_done) next_state = S_R_STOP;
            S_R_STOP : if (i2c_done) next_state = S_PARSE;

            S_PARSE  : next_state = S_M_START;

            default: next_state = S_PWRUP;
        endcase
    end

    // --------------------------------------------------------
    // 3) 时序输出 / 数据通路
    // --------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt           <= 16'd0;
            ms_cnt            <= 16'd0;
            issued            <= 1'b0;

            i2c_cmd_valid     <= 1'b0;
            i2c_cmd           <= 2'd0;
            i2c_tx            <= 8'd0;
            i2c_read_ack      <= 1'b0;

            data_valid        <= 1'b0;
            humidity_centi    <= 16'd0;
            temperature_centi <= 16'sd0;

            b0 <= 8'd0; b1 <= 8'd0; b2 <= 8'd0; b3 <= 8'd0;
            b4 <= 8'd0; b5 <= 8'd0; b6 <= 8'd0;
            hum_raw  <= 20'd0;
            temp_raw <= 20'd0;
            calc_tmp <= 40'd0;
            sensor_ack_seen <= 1'b0;
        end else begin
            i2c_cmd_valid <= 1'b0;
            data_valid    <= 1'b0;

            if (div_cnt == MS_DIV - 1)
                div_cnt <= 16'd0;
            else
                div_cnt <= div_cnt + 16'd1;

            if (state != next_state)
                issued <= 1'b0;

            case (state)
                S_PWRUP: begin
                    if (ms_tick) begin
                        if (ms_cnt == 16'd40)
                            ms_cnt <= 16'd0;
                        else
                            ms_cnt <= ms_cnt + 16'd1;
                    end
                end

                // ---------------- init: BE 08 00 ----------------
                S_I_START: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd0;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                end

                S_I_ADDR: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd2;
                        i2c_tx        <= DEV_W;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                    if (i2c_done && i2c_ack_ok)
                        sensor_ack_seen <= 1'b1;
                end

                S_I_CMD: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd2;
                        i2c_tx        <= 8'hBE;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                end

                S_I_D1: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd2;
                        i2c_tx        <= 8'h08;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                end

                S_I_D2: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd2;
                        i2c_tx        <= 8'h00;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                end

                S_I_STOP: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd1;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                    if (i2c_done)
                        ms_cnt <= 16'd0;
                end

                S_I_WAIT: begin
                    if (ms_tick) begin
                        if (ms_cnt == 16'd10)
                            ms_cnt <= 16'd0;
                        else
                            ms_cnt <= ms_cnt + 16'd1;
                    end
                end

                // ---------------- measure: AC 33 00 ----------------
                S_M_START: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd0;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                end

                S_M_ADDR: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd2;
                        i2c_tx        <= DEV_W;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                    if (i2c_done && i2c_ack_ok)
                        sensor_ack_seen <= 1'b1;
                end

                S_M_CMD: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd2;
                        i2c_tx        <= 8'hAC;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                end

                S_M_D1: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd2;
                        i2c_tx        <= 8'h33;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                end

                S_M_D2: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd2;
                        i2c_tx        <= 8'h00;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                end

                S_M_STOP: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd1;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                    if (i2c_done)
                        ms_cnt <= 16'd0;
                end

                S_M_WAIT: begin
                    if (ms_tick) begin
                        if (ms_cnt == 16'd80)
                            ms_cnt <= 16'd0;
                        else
                            ms_cnt <= ms_cnt + 16'd1;
                    end
                end

                // ---------------- read 7 bytes ----------------
                S_R_START: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd0;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                end

                S_R_ADDR: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd2;
                        i2c_tx        <= DEV_R;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                    if (i2c_done && i2c_ack_ok)
                        sensor_ack_seen <= 1'b1;
                end

                S_R_B0: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd3;
                        i2c_read_ack  <= 1'b1;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                    if (i2c_done) b0 <= i2c_rx;
                end

                S_R_B1: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd3;
                        i2c_read_ack  <= 1'b1;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                    if (i2c_done) b1 <= i2c_rx;
                end

                S_R_B2: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd3;
                        i2c_read_ack  <= 1'b1;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                    if (i2c_done) b2 <= i2c_rx;
                end

                S_R_B3: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd3;
                        i2c_read_ack  <= 1'b1;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                    if (i2c_done) b3 <= i2c_rx;
                end

                S_R_B4: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd3;
                        i2c_read_ack  <= 1'b1;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                    if (i2c_done) b4 <= i2c_rx;
                end

                S_R_B5: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd3;
                        i2c_read_ack  <= 1'b1;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                    if (i2c_done) b5 <= i2c_rx;
                end

                S_R_B6: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd3;
                        i2c_read_ack  <= 1'b0; // 最后一个字节回 NACK
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                    if (i2c_done) b6 <= i2c_rx;
                end

                S_R_STOP: begin
                    if (!issued) begin
                        i2c_cmd       <= 2'd1;
                        i2c_cmd_valid <= 1'b1;
                        issued        <= 1'b1;
                    end
                end                // ---------------- parse ----------------
                S_PARSE: begin
                    if (sensor_ack_seen && !b0[7]) begin
                        hum_raw  <= {b1, b2, b3[7:4]};
                        temp_raw <= {b3[3:0], b4, b5};

                        humidity_centi    <= ({20'd0, {b1, b2, b3[7:4]}} * 40'd10000) >> 20;
                        temperature_centi <= $signed((({20'd0, {b3[3:0], b4, b5}} * 40'd20000) >> 20)) - 16'sd5000;

                        data_valid <= 1'b1;
                    end
                end

                default: begin
                end
            endcase
        end
    end

endmodule
