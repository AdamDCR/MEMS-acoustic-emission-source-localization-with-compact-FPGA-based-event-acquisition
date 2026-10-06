`timescale 1ns / 1ps

`include "debug_cfg.vh"

module udp_rec_decode(
    input                               reset_n,
    input                               gmii_rx_clk,
    input                               sys_clk,
    input                               clk_125M,

    input                               rec_en,
    input               [   7: 0]       rec_data,
    input                               rec_pkt_done,
    input               [  15: 0]       rec_byte_num,

    output              [  15: 0]       sample_rate,
    output              [  15: 0]       channel_en,
    output              [  15: 0]       pulse_gap,

    output              [   3: 0]       EN,
    output              [   3: 0]       INA,
    output              [   3: 0]       INB,
    output              [   3: 0]       INC,

    output reg                          ctrl_time_set_valid,
    output reg          [  15: 0]       ctrl_set_year,
    output reg          [   3: 0]       ctrl_set_month,
    output reg          [   4: 0]       ctrl_set_day,
    output reg          [   4: 0]       ctrl_set_hour,
    output reg          [   5: 0]       ctrl_set_minute,
    output reg          [   5: 0]       ctrl_set_second,
    output reg          [  15: 0]       ctrl_ae_threshold,
    output reg                          ctrl_pulse_tx_enable,
    output reg                          ctrl_adc_rx_enable,
    output reg                          ctrl_req_upload_pulse,
    output reg                          ctrl_cfg_valid_pulse
);

    localparam integer WORD_COUNT        = 16;
    localparam [15:0]  PACKET_BYTES      = 16'd64;
    localparam [31:0]  WORD_USND         = 32'h5553_4E44; // "USND"
    localparam [31:0]  WORD_END          = 32'h454E_4421; // "END!"
    localparam [15:0]  DEFAULT_THRESHOLD = 16'd4000;

    // MATLAB packet:
    // word0  : ASCII "USND", byte order 55 53 4E 44
    // word1-14: uint32 typecast to uint8, little-endian on PC
    // word15 : ASCII "END!", byte order 45 4E 44 21
    reg                 [31:0]          rx_words [0:WORD_COUNT-1];
    reg                 [ 7:0]          byte0;
    reg                 [ 7:0]          byte1;
    reg                 [ 7:0]          byte2;
    reg                 [ 1:0]          byte_cnt;
    reg                 [ 4:0]          word_idx;
    reg                                 rx_active;
    reg                                 word_valid;
    reg                                 pkt_done_pending;
    reg                 [15:0]          pkt_byte_num;
    reg                 [ 4:0]          pkt_word_idx;
    reg                 [ 1:0]          pkt_byte_cnt;
    reg                                 cfg_toggle_rx;

    wire                [31:0]          ascii_word;
    wire                [31:0]          le_word;
    wire                [31:0]          assembled_word;
    wire                                packet_format_ok;

    assign ascii_word = {byte0, byte1, byte2, rec_data};
    assign le_word    = {rec_data, byte2, byte1, byte0};
    assign assembled_word = ((word_idx == 5'd0) || (word_idx == 5'd15)) ?
                            ascii_word : le_word;

    assign packet_format_ok = (pkt_byte_num == PACKET_BYTES) &&
                              (pkt_word_idx == 5'd15) &&
                              (pkt_byte_cnt == 2'd3) &&
                              (rx_words[0] == WORD_USND) &&
                              (rx_words[15] == WORD_END);

    integer i;

    reg                 [31:0]          rx_pulsePar1;
    reg                 [31:0]          rx_pulsePar2;
    reg                 [31:0]          rx_pulseDelayPar [0:3];
    reg                 [15:0]          rx_sample_rate;
    reg                 [15:0]          rx_channel_en;
    reg                 [31:0]          rx_tail;
    reg                 [15:0]          rx_ae_threshold;
    reg                 [15:0]          rx_set_year;
    reg                 [ 3:0]          rx_set_month;
    reg                 [ 4:0]          rx_set_day;
    reg                 [ 4:0]          rx_set_hour;
    reg                 [ 5:0]          rx_set_minute;
    reg                 [ 5:0]          rx_set_second;
    reg                                 rx_pulse_tx_enable;
    reg                                 rx_adc_rx_enable;
    reg                                 rx_req_upload;
    reg                                 rx_time_sync_enable;

    always @(posedge gmii_rx_clk or negedge reset_n) begin
        if (!reset_n) begin
            for (i = 0; i < WORD_COUNT; i = i + 1) begin
                rx_words[i] <= 32'd0;
            end
            for (i = 0; i < 4; i = i + 1) begin
                rx_pulseDelayPar[i] <= 32'd0;
            end
            byte0               <= 8'd0;
            byte1               <= 8'd0;
            byte2               <= 8'd0;
            byte_cnt            <= 2'd0;
            word_idx            <= 5'd0;
            rx_active           <= 1'b0;
            word_valid          <= 1'b0;
            pkt_done_pending    <= 1'b0;
            pkt_byte_num        <= 16'd0;
            pkt_word_idx        <= 5'd0;
            pkt_byte_cnt        <= 2'd0;
            cfg_toggle_rx       <= 1'b0;
            rx_pulsePar1        <= 32'd0;
            rx_pulsePar2        <= 32'd0;
            rx_sample_rate      <= 16'd1;
            rx_channel_en       <= 16'hFFFF;
            rx_tail             <= 32'd0;
            rx_ae_threshold     <= DEFAULT_THRESHOLD;
            rx_set_year         <= 16'd2026;
            rx_set_month        <= 4'd1;
            rx_set_day          <= 5'd1;
            rx_set_hour         <= 5'd0;
            rx_set_minute       <= 6'd0;
            rx_set_second       <= 6'd0;
            rx_pulse_tx_enable  <= 1'b0;
            rx_adc_rx_enable    <= 1'b0;
            rx_req_upload       <= 1'b0;
            rx_time_sync_enable <= 1'b0;
        end else begin
            word_valid <= 1'b0;

            if (rec_en && !rx_active) begin
                rx_active <= 1'b1;
                byte_cnt  <= 2'd0;
                word_idx  <= 5'd0;
            end

            if (rec_en) begin
                case (byte_cnt)
                    2'd0: begin
                        byte0    <= rec_data;
                        byte_cnt <= 2'd1;
                    end
                    2'd1: begin
                        byte1    <= rec_data;
                        byte_cnt <= 2'd2;
                    end
                    2'd2: begin
                        byte2    <= rec_data;
                        byte_cnt <= 2'd3;
                    end
                    default: begin
                        if (word_idx < WORD_COUNT[4:0]) begin
                            rx_words[word_idx] <= assembled_word;
                        end
                        word_valid <= 1'b1;
                        byte_cnt   <= 2'd0;
                        if (word_idx < 5'd15) begin
                            word_idx <= word_idx + 5'd1;
                        end
                    end
                endcase
            end else begin
                rx_active <= 1'b0;
                byte_cnt  <= 2'd0;
                word_idx  <= 5'd0;
            end

            if (rec_pkt_done) begin
                pkt_done_pending <= 1'b1;
                pkt_byte_num     <= rec_byte_num;
                pkt_word_idx     <= word_idx;
                pkt_byte_cnt     <= byte_cnt;
            end else if (pkt_done_pending) begin
                pkt_done_pending <= 1'b0;
                if (packet_format_ok) begin
                    rx_pulsePar1        <= {rx_words[2][23:16], rx_words[2][31:24],
                                            rx_words[2][15:8],  rx_words[2][7:0]};
                    rx_pulsePar2        <= rx_words[3];
                    rx_pulseDelayPar[0] <= rx_words[4];
                    rx_pulseDelayPar[1] <= rx_words[5];
                    rx_pulseDelayPar[2] <= rx_words[6];
                    rx_pulseDelayPar[3] <= rx_words[7];
                    rx_sample_rate      <= rx_words[8][15:0];
                    rx_channel_en       <= rx_words[9][15:0];
                    rx_tail             <= rx_words[12];
                    rx_set_year         <= rx_words[10][31:16];
                    rx_set_month        <= rx_words[10][11:8];
                    rx_set_day          <= rx_words[10][4:0];
                    rx_set_hour         <= rx_words[11][28:24];
                    rx_set_minute       <= rx_words[11][21:16];
                    rx_set_second       <= rx_words[11][13:8];
                    rx_pulse_tx_enable  <= rx_words[12][24];
                    rx_adc_rx_enable    <= rx_words[12][25];
                    rx_req_upload       <= rx_words[12][26];
                    rx_time_sync_enable <= rx_words[12][27];
                    rx_ae_threshold     <= rx_words[13][15:0];
                    cfg_toggle_rx       <= ~cfg_toggle_rx;
                end
            end
        end
    end

    reg                 [ 2:0]          cfg_toggle_sync;
    wire                                cfg_update_sys;

    reg                 [31:0]          pulsePar1;
    reg                 [31:0]          pulsePar2;
    reg                 [31:0]          pulseDelayPar [0:3];
    reg                 [15:0]          sample_rate_reg;
    reg                 [15:0]          channel_en_reg;
    reg                 [31:0]          tail_reg;

    assign cfg_update_sys = cfg_toggle_sync[2] ^ cfg_toggle_sync[1];

    always @(posedge sys_clk or negedge reset_n) begin
        if (!reset_n) begin
            cfg_toggle_sync        <= 3'b000;
            pulsePar1              <= 32'd0;
            pulsePar2              <= 32'd0;
            for (i = 0; i < 4; i = i + 1) begin
                pulseDelayPar[i] <= 32'd0;
            end
            sample_rate_reg        <= 16'd1;
            channel_en_reg         <= 16'hFFFF;
            tail_reg               <= 32'd0;
            ctrl_time_set_valid    <= 1'b0;
            ctrl_set_year          <= 16'd2026;
            ctrl_set_month         <= 4'd1;
            ctrl_set_day           <= 5'd1;
            ctrl_set_hour          <= 5'd0;
            ctrl_set_minute        <= 6'd0;
            ctrl_set_second        <= 6'd0;
            ctrl_ae_threshold      <= DEFAULT_THRESHOLD;
            ctrl_pulse_tx_enable   <= 1'b0;
            ctrl_adc_rx_enable     <= 1'b0;
            ctrl_req_upload_pulse  <= 1'b0;
            ctrl_cfg_valid_pulse   <= 1'b0;
        end else begin
            cfg_toggle_sync       <= {cfg_toggle_sync[1:0], cfg_toggle_rx};
            ctrl_time_set_valid   <= 1'b0;
            ctrl_req_upload_pulse <= 1'b0;
            ctrl_cfg_valid_pulse  <= 1'b0;

            if (cfg_update_sys) begin
                pulsePar1             <= rx_pulsePar1;
                pulsePar2             <= rx_pulsePar2;
                pulseDelayPar[0]      <= rx_pulseDelayPar[0];
                pulseDelayPar[1]      <= rx_pulseDelayPar[1];
                pulseDelayPar[2]      <= rx_pulseDelayPar[2];
                pulseDelayPar[3]      <= rx_pulseDelayPar[3];
                sample_rate_reg       <= rx_sample_rate;
                channel_en_reg        <= rx_channel_en;
                tail_reg              <= rx_tail;
                ctrl_set_year         <= rx_set_year;
                ctrl_set_month        <= rx_set_month;
                ctrl_set_day          <= rx_set_day;
                ctrl_set_hour         <= rx_set_hour;
                ctrl_set_minute       <= rx_set_minute;
                ctrl_set_second       <= rx_set_second;
                ctrl_ae_threshold     <= rx_ae_threshold;
                ctrl_pulse_tx_enable  <= rx_pulse_tx_enable;
                ctrl_adc_rx_enable    <= rx_adc_rx_enable;
                ctrl_time_set_valid   <= rx_time_sync_enable;
                ctrl_req_upload_pulse <= rx_req_upload;
                ctrl_cfg_valid_pulse  <= 1'b1;
            end
        end
    end

    assign sample_rate     = sample_rate_reg;
    assign channel_en      = channel_en_reg;
    assign pulse_gap       = pulsePar2[31:16];
    assign EN              = ctrl_pulse_tx_enable ? pulsePar2[3:0] : 4'd0;

    genvar pulse_chn;
    generate
        for (pulse_chn = 0; pulse_chn < 4; pulse_chn = pulse_chn + 1) begin : gen_pulse_ctrl
            pulse_ctrl pulse_ctrl_instance(
                .sys_clk         (sys_clk),
                .reset_n         (reset_n),
                .pulse_out_en    (ctrl_pulse_tx_enable),
                .pulsePar1       (pulsePar1),
                .pulse_phase     (pulseDelayPar[pulse_chn]),
                .pulse_gap       (pulse_gap),
                .pulse_en        (pulsePar2[pulse_chn]),
                .pulse_ctrl_data ({INA[pulse_chn], INB[pulse_chn], INC[pulse_chn]})
            );
        end
    endgenerate

`ifdef BOARD_ILA_ETH_REC_DECODE
    ILA_UDP_REC_DECODE ILA_UDP_REC_DECODE_inst (
    .clk                                (sys_clk                   ),// input wire clk


    .probe0                             (ctrl_adc_rx_enable        ),// input wire [0:0]  probe0  
    .probe1                             (ctrl_req_upload_pulse     ),// input wire [0:0]  probe1 
    .probe2                             (tail_reg[15:0]            ),// input wire [15:0]  probe2 
    .probe3                             (ctrl_set_year             ),// input wire [15:0]  probe3 
    .probe4                             (ctrl_ae_threshold         ),// input wire [15:0]  probe4 
    .probe5                             (channel_en_reg            ),// input wire [15:0]  probe5 
    .probe6                             (sample_rate_reg           ),// input wire [15:0]  probe6 
    .probe7                             (pulseDelayPar[0]          ) // input wire [31:0]  probe7
);
`endif

endmodule
