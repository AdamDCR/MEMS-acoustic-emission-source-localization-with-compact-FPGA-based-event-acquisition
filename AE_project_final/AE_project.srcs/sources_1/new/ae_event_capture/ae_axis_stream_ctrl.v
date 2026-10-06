// ============================================================================
// AXI stream controller: frame bank -> AXI4-Stream
// Handles frame bank B-port read latency and AXI backpressure.
// This conservative implementation issues one BRAM read only when the output
// register and read pipeline are empty, so no skid FIFO is required.
// ============================================================================
module ae_axis_stream_ctrl #(
    parameter integer MAX_CH           = 16,
    parameter integer DATA_W           = 256,
    parameter integer FRAME_SAMPLES    = 8192,
    parameter integer FRAME_AW         = 13,
    parameter integer AXIS_USER_W      = 64,
    parameter integer FRAME_RD_LATENCY = 3
)(
    input                           sys_clk,
    input                           reset_n,
    input                           sys_path_ready,

    output wire                     m_axis_tvalid,
    input                           m_axis_tready,
    output wire [DATA_W-1:0]        m_axis_tdata,
    output wire                     m_axis_tlast,
    output wire [AXIS_USER_W-1:0]   m_axis_tuser,

    input                           bank0_ready,
    input                           bank1_ready,
    input      [MAX_CH-1:0]         bank0_ch_mask,
    input      [MAX_CH-1:0]         bank1_ch_mask,
    input      [31:0]               bank0_trig_idx,
    input      [31:0]               bank1_trig_idx,
    input      [DATA_W-1:0]         bank0_rd_data,
    input      [DATA_W-1:0]         bank1_rd_data,

    output wire                     bank_rd_en,
    output wire                     bank_rd_sel,
    output wire [FRAME_AW-1:0]      bank_rd_addr,
    output reg                      bank_release_pulse,
    output reg                      bank_release_sel,
    output wire                     stream_busy
);

    localparam ST_IDLE = 1'b0;
    localparam ST_SEND = 1'b1;

    reg                         state_cur;
    reg                         state_nxt;

    reg                         bank_sel_r;
    reg [FRAME_RD_LATENCY-1:0]  rd_valid_pipe_r;
    reg                         data_valid_r;
    reg [FRAME_AW:0]            issue_cnt_r;
    reg [FRAME_AW:0]            send_cnt_r;

    reg [DATA_W-1:0]            data_r;
    reg                         last_r;
    reg [AXIS_USER_W-1:0]       user_r;
    reg [MAX_CH-1:0]            ch_mask_r;
    reg [31:0]                  trig_idx_r;

    wire                        start_stream;
    wire                        bank_rd_fire;
    wire                        rd_data_valid;
    wire                        axis_fire;
    wire                        axis_last_fire;
    wire                        pipe_empty;
    wire [DATA_W-1:0]           selected_bank_data;

    assign start_stream = sys_path_ready &&
                          !bank_release_pulse &&
                          (bank0_ready || bank1_ready);

    assign pipe_empty = (rd_valid_pipe_r == {FRAME_RD_LATENCY{1'b0}});

    assign bank_rd_fire = (state_cur == ST_SEND) &&
                          !data_valid_r &&
                          pipe_empty &&
                          (issue_cnt_r < FRAME_SAMPLES);

    assign rd_data_valid = rd_valid_pipe_r[FRAME_RD_LATENCY-1];

    assign selected_bank_data = bank_sel_r ? bank1_rd_data : bank0_rd_data;

    assign bank_rd_en   = bank_rd_fire;
    assign bank_rd_sel  = bank_sel_r;
    assign bank_rd_addr = issue_cnt_r[FRAME_AW-1:0];

    assign m_axis_tvalid = data_valid_r;
    assign m_axis_tdata  = data_r;
    assign m_axis_tlast  = data_valid_r && last_r;
    assign m_axis_tuser  = user_r;

    assign axis_fire      = data_valid_r && m_axis_tready;
    assign axis_last_fire = axis_fire && last_r;
    assign stream_busy    = (state_cur != ST_IDLE);

    always @(posedge sys_clk or negedge reset_n) begin
        if (!reset_n)
            state_cur <= ST_IDLE;
        else
            state_cur <= state_nxt;
    end

    always @(*) begin
        state_nxt = state_cur;

        if (!sys_path_ready) begin
            state_nxt = ST_IDLE;
        end
        else begin
            case (state_cur)
                ST_IDLE: begin
                    if (start_stream)
                        state_nxt = ST_SEND;
                end

                ST_SEND: begin
                    if (axis_last_fire)
                        state_nxt = ST_IDLE;
                end

                default: begin
                    state_nxt = ST_IDLE;
                end
            endcase
        end
    end

    always @(posedge sys_clk or negedge reset_n) begin
        if (!reset_n) begin
            bank_sel_r         <= 1'b0;
            rd_valid_pipe_r    <= {FRAME_RD_LATENCY{1'b0}};
            data_valid_r       <= 1'b0;
            issue_cnt_r        <= {(FRAME_AW + 1){1'b0}};
            send_cnt_r         <= {(FRAME_AW + 1){1'b0}};
            data_r             <= {DATA_W{1'b0}};
            last_r             <= 1'b0;
            user_r             <= {AXIS_USER_W{1'b0}};
            ch_mask_r          <= {MAX_CH{1'b0}};
            trig_idx_r         <= 32'd0;
            bank_release_pulse <= 1'b0;
            bank_release_sel   <= 1'b0;
        end
        else begin
            bank_release_pulse <= 1'b0;

            if (FRAME_RD_LATENCY == 1)
                rd_valid_pipe_r <= {bank_rd_fire};
            else
                rd_valid_pipe_r <= {rd_valid_pipe_r[FRAME_RD_LATENCY-2:0], bank_rd_fire};

            if (!sys_path_ready) begin
                rd_valid_pipe_r <= {FRAME_RD_LATENCY{1'b0}};
                data_valid_r    <= 1'b0;
                issue_cnt_r     <= {(FRAME_AW + 1){1'b0}};
                send_cnt_r      <= {(FRAME_AW + 1){1'b0}};
            end
            else begin
                if ((state_cur == ST_IDLE) && (state_nxt == ST_SEND)) begin
                    bank_sel_r      <= bank0_ready ? 1'b0 : 1'b1;
                    ch_mask_r       <= bank0_ready ? bank0_ch_mask : bank1_ch_mask;
                    trig_idx_r      <= bank0_ready ? bank0_trig_idx : bank1_trig_idx;
                    rd_valid_pipe_r <= {FRAME_RD_LATENCY{1'b0}};
                    data_valid_r    <= 1'b0;
                    issue_cnt_r     <= {(FRAME_AW + 1){1'b0}};
                    send_cnt_r      <= {(FRAME_AW + 1){1'b0}};
                    last_r          <= 1'b0;
                    user_r          <= {AXIS_USER_W{1'b0}};
                end

                if (bank_rd_fire) begin
                    issue_cnt_r  <= issue_cnt_r + 1'b1;
                end

                if (rd_data_valid && !data_valid_r) begin
                    data_r       <= selected_bank_data;
                    data_valid_r <= 1'b1;
                    last_r       <= (send_cnt_r == FRAME_SAMPLES - 1);

                    user_r       <= {AXIS_USER_W{1'b0}};
                    user_r[0]    <= (send_cnt_r == 0);           // SOF
                    user_r[16:1] <= ch_mask_r;                   // channel mask
                    user_r[48:17]<= trig_idx_r;                  // trigger index
                    user_r[51:49]<= 3'd0;                        // 8192 frame code
                end

                if (axis_fire) begin
                    data_valid_r <= 1'b0;
                    send_cnt_r   <= send_cnt_r + 1'b1;
                    last_r       <= 1'b0;
                    user_r[0]    <= 1'b0;
                end

                if (axis_last_fire) begin
                    bank_release_pulse <= 1'b1;
                    bank_release_sel   <= bank_sel_r;
                end
            end
        end
    end

endmodule
