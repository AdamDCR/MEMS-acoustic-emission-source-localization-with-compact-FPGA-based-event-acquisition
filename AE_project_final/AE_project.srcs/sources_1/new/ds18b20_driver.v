`timescale 1ns/1ps
// ============================================================
// DS18B20 driver
// 输出：
//   temp_raw_x16   : 原始格式，1 LSB = 1/16 摄氏度
//   temp_centi_deg : 0.01 摄氏度
// 三段式状态机
// ============================================================
module ds18b20_driver #(
    parameter integer CLK_FREQ_HZ = 200_000_000
)(
    input  wire              clk,
    input  wire              rst_n,
    inout  wire              dq,

    output reg               data_valid,
    output reg               sensor_present,
    output reg signed [15:0] temp_raw_x16,
    output reg signed [15:0] temp_centi_deg
);

    localparam integer MS_DIV = CLK_FREQ_HZ / 1000;

    localparam [3:0]
        S_PWRUP   = 4'd0,
        S_RST1    = 4'd1,
        S_SKIP1   = 4'd2,
        S_CONV    = 4'd3,
        S_WAIT    = 4'd4,
        S_RST2    = 4'd5,
        S_SKIP2   = 4'd6,
        S_RDCMD   = 4'd7,
        S_RDL     = 4'd8,
        S_RDM     = 4'd9,
        S_PARSE   = 4'd10;

    reg [3:0] state, next_state;

    reg [15:0] div_cnt;
    reg [15:0] ms_cnt;
    reg [7:0]  temp_lsb;
    reg [7:0]  temp_msb;
    reg        issued;

    wire ms_tick = (div_cnt == MS_DIV - 1);

    wire dq_i;
    wire dq_oe;

    reg        ow_cmd_valid;
    reg [1:0]  ow_cmd;
    reg [7:0]  ow_tx;
    wire [7:0] ow_rx;
    wire       ow_presence;
    wire       ow_busy;
    wire       ow_done;

    assign dq   = dq_oe ? 1'b0 : 1'bz;
    assign dq_i = dq;

    onewire_byte_ctrl #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ)
    ) u_onewire (
        .clk        (clk),
        .rst_n      (rst_n),
        .dq_i       (dq_i),
        .dq_oe      (dq_oe),
        .cmd_valid  (ow_cmd_valid),
        .cmd        (ow_cmd),
        .tx_byte    (ow_tx),
        .rx_byte    (ow_rx),
        .presence_ok(ow_presence),
        .busy       (ow_busy),
        .done       (ow_done)
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
            S_PWRUP: if (ms_tick && (ms_cnt == 16'd100)) next_state = S_RST1;

            S_RST1 : if (ow_done) next_state = S_SKIP1;
            S_SKIP1: if (ow_done) next_state = S_CONV;
            S_CONV : if (ow_done) next_state = S_WAIT;

            S_WAIT : if (ms_tick && (ms_cnt == 16'd750)) next_state = S_RST2;

            S_RST2 : if (ow_done) next_state = S_SKIP2;
            S_SKIP2: if (ow_done) next_state = S_RDCMD;
            S_RDCMD: if (ow_done) next_state = S_RDL;
            S_RDL  : if (ow_done) next_state = S_RDM;
            S_RDM  : if (ow_done) next_state = S_PARSE;

            S_PARSE: next_state = S_RST1;

            default: next_state = S_PWRUP;
        endcase
    end

    // --------------------------------------------------------
    // 3) 时序输出 / 数据通路
    // --------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt        <= 16'd0;
            ms_cnt         <= 16'd0;
            temp_lsb       <= 8'd0;
            temp_msb       <= 8'd0;
            issued         <= 1'b0;

            ow_cmd_valid   <= 1'b0;
            ow_cmd         <= 2'd0;
            ow_tx          <= 8'd0;

            data_valid     <= 1'b0;
            sensor_present <= 1'b0;
            temp_raw_x16   <= 16'sd0;
            temp_centi_deg <= 16'sd0;
        end else begin
            // 默认脉冲信号
            ow_cmd_valid <= 1'b0;
            data_valid   <= 1'b0;

            // ms 基准
            if (div_cnt == MS_DIV - 1)
                div_cnt <= 16'd0;
            else
                div_cnt <= div_cnt + 16'd1;

            // 状态切换时，允许新状态重新发命令
            if (state != next_state)
                issued <= 1'b0;

            case (state)
                S_PWRUP: begin
                    if (ms_tick) begin
                        if (ms_cnt == 16'd100)
                            ms_cnt <= 16'd0;
                        else
                            ms_cnt <= ms_cnt + 16'd1;
                    end
                end

                S_RST1: begin
                    if (!issued) begin
                        ow_cmd       <= 2'd0;   // reset
                        ow_cmd_valid <= 1'b1;
                        issued       <= 1'b1;
                    end
                    if (ow_done)
                        sensor_present <= ow_presence;
                end

                S_SKIP1: begin
                    if (!issued) begin
                        ow_cmd       <= 2'd1;
                        ow_tx        <= 8'hCC;  // Skip ROM
                        ow_cmd_valid <= 1'b1;
                        issued       <= 1'b1;
                    end
                end

                S_CONV: begin
                    if (!issued) begin
                        ow_cmd       <= 2'd1;
                        ow_tx        <= 8'h44;  // Convert T
                        ow_cmd_valid <= 1'b1;
                        issued       <= 1'b1;
                    end
                    if (ow_done)
                        ms_cnt <= 16'd0;
                end

                S_WAIT: begin
                    if (ms_tick) begin
                        if (ms_cnt == 16'd750)
                            ms_cnt <= 16'd0;
                        else
                            ms_cnt <= ms_cnt + 16'd1;
                    end
                end

                S_RST2: begin
                    if (!issued) begin
                        ow_cmd       <= 2'd0;
                        ow_cmd_valid <= 1'b1;
                        issued       <= 1'b1;
                    end
                    if (ow_done)
                        sensor_present <= ow_presence;
                end

                S_SKIP2: begin
                    if (!issued) begin
                        ow_cmd       <= 2'd1;
                        ow_tx        <= 8'hCC;  // Skip ROM
                        ow_cmd_valid <= 1'b1;
                        issued       <= 1'b1;
                    end
                end

                S_RDCMD: begin
                    if (!issued) begin
                        ow_cmd       <= 2'd1;
                        ow_tx        <= 8'hBE;  // Read Scratchpad
                        ow_cmd_valid <= 1'b1;
                        issued       <= 1'b1;
                    end
                end

                S_RDL: begin
                    if (!issued) begin
                        ow_cmd       <= 2'd2;   // read byte
                        ow_cmd_valid <= 1'b1;
                        issued       <= 1'b1;
                    end
                    if (ow_done)
                        temp_lsb <= ow_rx;
                end

                S_RDM: begin
                    if (!issued) begin
                        ow_cmd       <= 2'd2;   // read byte
                        ow_cmd_valid <= 1'b1;
                        issued       <= 1'b1;
                    end
                    if (ow_done)
                        temp_msb <= ow_rx;
                end

                S_PARSE: begin
                    temp_raw_x16   <= $signed({temp_msb, temp_lsb});
                    temp_centi_deg <= ($signed({temp_msb, temp_lsb}) * 32'sd100) >>> 4;
                    data_valid     <= 1'b1;
                end

                default: begin
                end
            endcase
        end
    end

endmodule