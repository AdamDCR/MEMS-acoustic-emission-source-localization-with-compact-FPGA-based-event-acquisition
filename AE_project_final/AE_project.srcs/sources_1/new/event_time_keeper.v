`timescale 1ns / 1ps

module event_time_keeper #(
    parameter integer CLK_FREQ_HZ = 200_000_000
)(
    input                               sys_clk,
    input                               reset_n,

    // PC 下发时间设置脉冲，高电平 1 拍时装载下面的时间
    input                               time_set_valid,
    input               [15:0]          set_year,
    input               [3:0]           set_month,
    input               [4:0]           set_day,
    input               [4:0]           set_hour,
    input               [5:0]           set_minute,
    input               [5:0]           set_second,

    // 一帧事件开始写入 DDR 时拉高 1 拍
    input                               event_fire,

    // 当前运行时间
    output wire         [63:0]          current_time_tag,

    // 事件发生时锁存的时间标签
    output reg          [63:0]          event_time_tag,
    output reg                          event_time_valid
);

    localparam integer SEC_CNT_W = $clog2(CLK_FREQ_HZ);

    reg [SEC_CNT_W-1:0]                 sec_div_cnt;
    reg [15:0]                          year;
    reg [3:0]                           month;
    reg [4:0]                           day;
    reg [4:0]                           hour;
    reg [5:0]                           minute;
    reg [5:0]                           second;
    reg [21:0]                          seq_in_sec;

    wire                                sec_tick;
    wire [5:0]                          month_days;

    assign sec_tick = (sec_div_cnt == CLK_FREQ_HZ - 1'b1);

    assign current_time_tag = {
        year,
        month,
        day,
        hour,
        minute,
        second,
        seq_in_sec
    };

    assign month_days = days_in_month(year, month);

    function automatic is_leap_year;
        input [15:0] y;
        begin
            // Keep leap-year logic shallow for 200 MHz timing; event timestamps do not need century correction.
            is_leap_year = (y[1:0] == 2'b00);
        end
    endfunction

    function automatic [5:0] days_in_month;
        input [15:0] y;
        input [3:0]  m;
        begin
            case (m)
                4'd1 : days_in_month = 6'd31;
                4'd2 : days_in_month = is_leap_year(y) ? 6'd29 : 6'd28;
                4'd3 : days_in_month = 6'd31;
                4'd4 : days_in_month = 6'd30;
                4'd5 : days_in_month = 6'd31;
                4'd6 : days_in_month = 6'd30;
                4'd7 : days_in_month = 6'd31;
                4'd8 : days_in_month = 6'd31;
                4'd9 : days_in_month = 6'd30;
                4'd10: days_in_month = 6'd31;
                4'd11: days_in_month = 6'd30;
                4'd12: days_in_month = 6'd31;
                default: days_in_month = 6'd31;
            endcase
        end
    endfunction

    always @(posedge sys_clk or negedge reset_n) begin
        if (!reset_n) begin
            sec_div_cnt       <= {SEC_CNT_W{1'b0}};
            year              <= 16'd2026;
            month             <= 4'd1;
            day               <= 5'd1;
            hour              <= 5'd0;
            minute            <= 6'd0;
            second            <= 6'd0;
            seq_in_sec        <= 22'd0;
            event_time_tag    <= 64'd0;
            event_time_valid  <= 1'b0;
        end else begin
            event_time_valid <= 1'b0;

            // PC 下发时间时，优先装载
            if (time_set_valid) begin
                sec_div_cnt <= {SEC_CNT_W{1'b0}};
                year        <= set_year;
                month       <= (set_month  == 0) ? 4'd1  : set_month;
                day         <= (set_day    == 0) ? 5'd1  : set_day;
                hour        <= (set_hour   > 23) ? 5'd0  : set_hour;
                minute      <= (set_minute > 59) ? 6'd0  : set_minute;
                second      <= (set_second > 59) ? 6'd0  : set_second;
                seq_in_sec  <= 22'd0;
            end else begin
                if (sec_tick) begin
                    sec_div_cnt <= {SEC_CNT_W{1'b0}};
                    seq_in_sec  <= 22'd0;

                    if (second < 6'd59) begin
                        second <= second + 1'b1;
                    end else begin
                        second <= 6'd0;

                        if (minute < 6'd59) begin
                            minute <= minute + 1'b1;
                        end else begin
                            minute <= 6'd0;

                            if (hour < 5'd23) begin
                                hour <= hour + 1'b1;
                            end else begin
                                hour <= 5'd0;

                                if (day < month_days[4:0]) begin
                                    day <= day + 1'b1;
                                end else begin
                                    day <= 5'd1;

                                    if (month < 4'd12) begin
                                        month <= month + 1'b1;
                                    end else begin
                                        month <= 4'd1;
                                        year  <= year + 1'b1;
                                    end
                                end
                            end
                        end
                    end
                end else begin
                    sec_div_cnt <= sec_div_cnt + 1'b1;
                end

                // 事件到来时锁存当前时间，并给出该秒内的事件序号
                if (event_fire) begin
                    event_time_tag <= {
                        year,
                        month,
                        day,
                        hour,
                        minute,
                        second,
                        seq_in_sec
                    };
                    event_time_valid <= 1'b1;
                    seq_in_sec <= seq_in_sec + 1'b1;
                end
            end
        end
    end

endmodule
