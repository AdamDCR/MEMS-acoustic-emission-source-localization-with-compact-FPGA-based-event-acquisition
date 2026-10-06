`timescale 1ns / 1ps

module tb_top_system;
    localparam integer AD9257_WORD_BITS = 14;
    localparam [13:0]  AD9257_FRAME_WORD = 14'h3F80;
    localparam integer SAMPLE_W = 16;

    reg  sys_clk_p = 1'b0;
    wire sys_clk_n = ~sys_clk_p;
    reg  reset_sys_clk = 1'b0;

    wire [3:0] EN;
    wire [3:0] INA;
    wire [3:0] INB;
    wire [3:0] INC;
    wire [3:0] LED_OUT;
    wire       SYS_OUT;
    reg  [3:0] KEY = 4'hF;
    reg  [7:0] BIN = 8'h00;

    reg        Inertia_SDX  = 1'b0;
    reg        Inertia_SCX  = 1'b0;
    reg        Inertia_INT1 = 1'b0;
    reg        Inertia_INT2 = 1'b0;
    reg        Inertia_OSCB = 1'b0;
    reg        Inertia_OSDO = 1'b0;
    wire       Inertia_SDO;
    wire       Inertia_CSB;
    tri1       Inertia_SCL;
    tri1       Inertia_SDA;
    tri1       TEM;
    tri1       H_SCL;
    tri1       H_SDA;

    wire       adc1_pdwn;
    wire       adc1_spi_sck;
    wire       adc1_spi_csn;
    tri        adc1_spi_dio;
    wire       adc1_sync;
    wire       adc1_clk_out_p;
    wire       adc1_clk_out_n;
    reg        adc1_fclk_p = 1'b0;
    wire       adc1_fclk_n = ~adc1_fclk_p;
    reg  [7:0] adc1_data_in_p = 8'h00;
    wire [7:0] adc1_data_in_n = ~adc1_data_in_p;

    wire       adc2_pdwn;
    wire       adc2_spi_sck;
    wire       adc2_spi_csn;
    tri        adc2_spi_dio;
    wire       adc2_sync;
    wire       adc2_clk_out_p;
    wire       adc2_clk_out_n;
    reg        adc2_fclk_p = 1'b0;
    wire       adc2_fclk_n = ~adc2_fclk_p;
    reg  [7:0] adc2_data_in_p = 8'h00;
    wire [7:0] adc2_data_in_n = ~adc2_data_in_p;

    reg        adc_dclk_p = 1'b0;
    wire       adc_dclk_n = ~adc_dclk_p;

    reg        eth_rxc    = 1'b0;
    reg        eth_rx_ctl = 1'b0;
    reg  [3:0] eth_rxd    = 4'h0;
    wire       eth_txc;
    wire       eth_tx_ctl;
    wire [3:0] eth_txd;
    wire       eth_rst_n;

    wire [14:0] ddr3_addr;
    wire [2:0]  ddr3_ba;
    wire        ddr3_cas_n;
    wire [0:0]  ddr3_ck_n;
    wire [0:0]  ddr3_ck_p;
    wire [0:0]  ddr3_cke;
    wire        ddr3_ras_n;
    wire        ddr3_reset_n;
    wire        ddr3_we_n;
    tri  [31:0] ddr3_dq;
    tri  [3:0]  ddr3_dqs_n;
    tri  [3:0]  ddr3_dqs_p;
    wire [0:0]  ddr3_cs_n;
    wire [3:0]  ddr3_dm;
    wire [0:0]  ddr3_odt;

    reg [13:0] adc1_serial_word [0:7];
    reg [13:0] adc2_serial_word [0:7];
    reg [13:0] raw1_ch0, raw1_ch1, raw1_ch2, raw1_ch3;
    reg [13:0] raw1_ch4, raw1_ch5, raw1_ch6, raw1_ch7;
    reg [13:0] raw2_ch0, raw2_ch1, raw2_ch2, raw2_ch3;
    reg [13:0] raw2_ch4, raw2_ch5, raw2_ch6, raw2_ch7;
    integer raw_sample_idx;
    integer serial_edge_idx;
    integer raw_valid;
    integer raw_mode;
    integer pulse_remaining;
    integer error_count;

    always #2.5 sys_clk_p = ~sys_clk_p;
    always #4.0 eth_rxc = ~eth_rxc;
    always #1.785714 adc_dclk_p = ~adc_dclk_p;

    top #(
        .SIM_AXI_MEM(1),
        .SIM_SENSOR_STUB(1),
        .SIM_ADC_PREPROCESS_STUB(1),
        .AE_FRAME_SAMPLES(256),
        .AE_PRE_SAMPLES(128),
        .AE_POST_SAMPLES(128)
    ) dut (
        .sys_clk_p      (sys_clk_p),
        .sys_clk_n      (sys_clk_n),
        .reset_sys_clk  (reset_sys_clk),
        .EN             (EN),
        .INA            (INA),
        .INB            (INB),
        .INC            (INC),
        .LED_OUT        (LED_OUT),
        .SYS_OUT        (SYS_OUT),
        .KEY            (KEY),
        .BIN            (BIN),
        .Inertia_SDO    (Inertia_SDO),
        .Inertia_SDX    (Inertia_SDX),
        .Inertia_SCX    (Inertia_SCX),
        .Inertia_INT1   (Inertia_INT1),
        .Inertia_INT2   (Inertia_INT2),
        .Inertia_OSCB   (Inertia_OSCB),
        .Inertia_OSDO   (Inertia_OSDO),
        .Inertia_CSB    (Inertia_CSB),
        .Inertia_SCL    (Inertia_SCL),
        .Inertia_SDA    (Inertia_SDA),
        .TEM            (TEM),
        .H_SCL          (H_SCL),
        .H_SDA          (H_SDA),
        .adc1_pdwn      (adc1_pdwn),
        .adc1_spi_sck   (adc1_spi_sck),
        .adc1_spi_csn   (adc1_spi_csn),
        .adc1_spi_dio   (adc1_spi_dio),
        .adc1_sync      (adc1_sync),
        .adc1_clk_out_p (adc1_clk_out_p),
        .adc1_clk_out_n (adc1_clk_out_n),
        .adc1_fclk_p    (adc1_fclk_p),
        .adc1_fclk_n    (adc1_fclk_n),
        .adc1_dclk_p    (adc_dclk_p),
        .adc1_dclk_n    (adc_dclk_n),
        .adc1_data_in_p (adc1_data_in_p),
        .adc1_data_in_n (adc1_data_in_n),
        .adc2_pdwn      (adc2_pdwn),
        .adc2_spi_sck   (adc2_spi_sck),
        .adc2_spi_csn   (adc2_spi_csn),
        .adc2_spi_dio   (adc2_spi_dio),
        .adc2_sync      (adc2_sync),
        .adc2_clk_out_p (adc2_clk_out_p),
        .adc2_clk_out_n (adc2_clk_out_n),
        .adc2_fclk_p    (adc2_fclk_p),
        .adc2_fclk_n    (adc2_fclk_n),
        .adc2_dclk_p    (adc_dclk_p),
        .adc2_dclk_n    (adc_dclk_n),
        .adc2_data_in_p (adc2_data_in_p),
        .adc2_data_in_n (adc2_data_in_n),
        .eth_rxc        (eth_rxc),
        .eth_rx_ctl     (eth_rx_ctl),
        .eth_rxd        (eth_rxd),
        .eth_txc        (eth_txc),
        .eth_tx_ctl     (eth_tx_ctl),
        .eth_txd        (eth_txd),
        .eth_rst_n      (eth_rst_n),
        .ddr3_addr      (ddr3_addr),
        .ddr3_ba        (ddr3_ba),
        .ddr3_cas_n     (ddr3_cas_n),
        .ddr3_ck_n      (ddr3_ck_n),
        .ddr3_ck_p      (ddr3_ck_p),
        .ddr3_cke       (ddr3_cke),
        .ddr3_ras_n     (ddr3_ras_n),
        .ddr3_reset_n   (ddr3_reset_n),
        .ddr3_we_n      (ddr3_we_n),
        .ddr3_dq        (ddr3_dq),
        .ddr3_dqs_n     (ddr3_dqs_n),
        .ddr3_dqs_p     (ddr3_dqs_p),
        .ddr3_cs_n      (ddr3_cs_n),
        .ddr3_dm        (ddr3_dm),
        .ddr3_odt       (ddr3_odt)
    );

    function [13:0] clip_s14;
        input integer value;
        reg signed [13:0] clipped;
        begin
            if (value > 8191)
                clipped = 14'sd8191;
            else if (value < -8192)
                clipped = -14'sd8192;
            else
                clipped = value[13:0];
            clip_s14 = clipped[13:0];
        end
    endfunction

    function ad9257_serial_bit;
        input [13:0] word;
        input integer edge_idx;
        begin
            ad9257_serial_bit = word[13-edge_idx];
        end
    endfunction

    function integer abs_s16;
        input [15:0] value;
        reg signed [15:0] signed_value;
        begin
            signed_value = value;
            if (signed_value < 0)
                abs_s16 = -signed_value;
            else
                abs_s16 = signed_value;
        end
    endfunction

    task fail;
        input [1023:0] msg;
        begin
            $display("ERROR: %0s", msg);
            error_count = error_count + 1;
        end
    endtask

    task pass;
        input [1023:0] msg;
        begin
            $display("PASS : %0s", msg);
        end
    endtask

    task check;
        input condition;
        input [1023:0] msg;
        begin
            if (condition)
                pass(msg);
            else
                fail(msg);
        end
    endtask

    task set_raw_all;
        input [13:0] value;
        begin
            raw1_ch0 = value; raw1_ch1 = value; raw1_ch2 = value; raw1_ch3 = value;
            raw1_ch4 = value; raw1_ch5 = value; raw1_ch6 = value; raw1_ch7 = value;
            raw2_ch0 = value; raw2_ch1 = value; raw2_ch2 = value; raw2_ch3 = value;
            raw2_ch4 = value; raw2_ch5 = value; raw2_ch6 = value; raw2_ch7 = value;
        end
    endtask

    task clear_ad9257_serial_words;
        integer ch;
        begin
            for (ch = 0; ch < 8; ch = ch + 1) begin
                adc1_serial_word[ch] = 14'd0;
                adc2_serial_word[ch] = 14'd0;
            end
        end
    endtask

    task latch_ad9257_parallel_words;
        begin
            adc1_serial_word[0] = raw1_ch0;
            adc1_serial_word[1] = raw1_ch1;
            adc1_serial_word[2] = raw1_ch2;
            adc1_serial_word[3] = raw1_ch3;
            adc1_serial_word[4] = raw1_ch4;
            adc1_serial_word[5] = raw1_ch5;
            adc1_serial_word[6] = raw1_ch6;
            adc1_serial_word[7] = raw1_ch7;
            adc2_serial_word[0] = raw2_ch0;
            adc2_serial_word[1] = raw2_ch1;
            adc2_serial_word[2] = raw2_ch2;
            adc2_serial_word[3] = raw2_ch3;
            adc2_serial_word[4] = raw2_ch4;
            adc2_serial_word[5] = raw2_ch5;
            adc2_serial_word[6] = raw2_ch6;
            adc2_serial_word[7] = raw2_ch7;
        end
    endtask

    task drive_ad9257_idle;
        begin
            adc1_fclk_p    = 1'b0;
            adc1_data_in_p = 8'h00;
            adc2_fclk_p    = 1'b0;
            adc2_data_in_p = 8'h00;
        end
    endtask

    task drive_ad9257_serial_edge;
        input integer edge_idx;
        reg frame_bit;
        reg [7:0] adc1_bits;
        reg [7:0] adc2_bits;
        integer ch;
        begin
            frame_bit = ad9257_serial_bit(AD9257_FRAME_WORD, edge_idx);
            for (ch = 0; ch < 8; ch = ch + 1) begin
                adc1_bits[ch] = ad9257_serial_bit(adc1_serial_word[ch], edge_idx);
                adc2_bits[ch] = ad9257_serial_bit(adc2_serial_word[ch], edge_idx);
            end
            adc1_fclk_p    = frame_bit;
            adc1_data_in_p = adc1_bits;
            adc2_fclk_p    = frame_bit;
            adc2_data_in_p = adc2_bits;
        end
    endtask

    task update_raw_samples;
        integer pulse_value;
        begin
            raw_sample_idx = raw_sample_idx + 1;
            if ((raw_mode == 1) && (pulse_remaining > 0)) begin
                pulse_value = ((raw_sample_idx % 400) < 200) ? 8191 : -8192;
                set_raw_all(clip_s14(pulse_value));
                pulse_remaining = pulse_remaining - 1;
            end else begin
                set_raw_all(clip_s14(0));
            end
        end
    endtask

    task start_ad9257_serial_stream;
        begin
            raw_valid = 1;
            serial_edge_idx = 0;
            latch_ad9257_parallel_words();
            update_raw_samples();
            drive_ad9257_serial_edge(0);
        end
    endtask

    task advance_ad9257_serial_stream;
        integer next_edge_idx;
        begin
            if (!reset_sys_clk || (adc1_pdwn !== 1'b0) || (adc2_pdwn !== 1'b0)) begin
                raw_valid = 0;
                raw_sample_idx = 0;
                serial_edge_idx = 0;
                pulse_remaining = 0;
                set_raw_all(clip_s14(0));
                clear_ad9257_serial_words();
                drive_ad9257_idle();
            end else if (!raw_valid) begin
                start_ad9257_serial_stream();
            end else begin
                if (serial_edge_idx == (AD9257_WORD_BITS-1)) begin
                    next_edge_idx = 0;
                    latch_ad9257_parallel_words();
                    update_raw_samples();
                end else begin
                    next_edge_idx = serial_edge_idx + 1;
                end
                serial_edge_idx = next_edge_idx;
                drive_ad9257_serial_edge(next_edge_idx);
            end
        end
    endtask

    always @(posedge adc_dclk_p or negedge adc_dclk_p) begin
        #0.2;
        advance_ad9257_serial_stream();
    end

    task send_rgmii_byte;
        input [7:0] data;
        begin
            @(negedge eth_rxc);
            eth_rx_ctl <= 1'b1;
            eth_rxd    <= data[3:0];
            @(posedge eth_rxc);
            #0.1;
            eth_rx_ctl <= 1'b1;
            eth_rxd    <= data[7:4];
        end
    endtask

    task send_word_be;
        input [31:0] word;
        begin
            send_rgmii_byte(word[31:24]);
            send_rgmii_byte(word[23:16]);
            send_rgmii_byte(word[15:8]);
            send_rgmii_byte(word[7:0]);
        end
    endtask

    task send_word_le;
        input [31:0] word;
        begin
            send_rgmii_byte(word[7:0]);
            send_rgmii_byte(word[15:8]);
            send_rgmii_byte(word[23:16]);
            send_rgmii_byte(word[31:24]);
        end
    endtask

    task send_udp_cfg_frame;
        input [15:0] sample_rate_value;
        input [15:0] channel_mask_value;
        input [15:0] threshold_value;
        input        adc_enable_value;
        input        req_upload_value;
        input        time_sync_value;
        reg [31:0] ctrl_word;
        integer k;
        begin
            ctrl_word = 32'd0;
            ctrl_word[25] = adc_enable_value;
            ctrl_word[26] = req_upload_value;
            ctrl_word[27] = time_sync_value;

            for (k = 0; k < 7; k = k + 1)
                send_rgmii_byte(8'h55);
            send_rgmii_byte(8'hD5);

            send_rgmii_byte(8'hFF); send_rgmii_byte(8'hFF); send_rgmii_byte(8'hFF);
            send_rgmii_byte(8'hFF); send_rgmii_byte(8'hFF); send_rgmii_byte(8'hFF);
            send_rgmii_byte(8'h02); send_rgmii_byte(8'h00); send_rgmii_byte(8'h00);
            send_rgmii_byte(8'h00); send_rgmii_byte(8'h00); send_rgmii_byte(8'h01);
            send_rgmii_byte(8'h08); send_rgmii_byte(8'h00);

            send_rgmii_byte(8'h45); send_rgmii_byte(8'h00);
            send_rgmii_byte(8'h00); send_rgmii_byte(8'h5C);
            send_rgmii_byte(8'h12); send_rgmii_byte(8'h34);
            send_rgmii_byte(8'h40); send_rgmii_byte(8'h00);
            send_rgmii_byte(8'h40); send_rgmii_byte(8'h11);
            send_rgmii_byte(8'h00); send_rgmii_byte(8'h00);
            send_rgmii_byte(8'hC0); send_rgmii_byte(8'hA8);
            send_rgmii_byte(8'h64); send_rgmii_byte(8'h91);
            send_rgmii_byte(8'hC0); send_rgmii_byte(8'hA8);
            send_rgmii_byte(8'h64); send_rgmii_byte(8'hEA);

            send_rgmii_byte(8'h04); send_rgmii_byte(8'hD2);
            send_rgmii_byte(8'h04); send_rgmii_byte(8'hD2);
            send_rgmii_byte(8'h00); send_rgmii_byte(8'h48);
            send_rgmii_byte(8'h00); send_rgmii_byte(8'h00);

            send_word_be(32'h5553_4E44);
            send_word_le(32'd0);
            send_word_le(32'd0);
            send_word_le(32'd0);
            send_word_le(32'd0);
            send_word_le(32'd0);
            send_word_le(32'd0);
            send_word_le(32'd0);
            send_word_le({16'd0, sample_rate_value});
            send_word_le({16'd0, channel_mask_value});
            send_word_le({16'd2026, 4'd0, 4'd5, 3'd0, 5'd13});
            send_word_le({3'd0, 5'd14, 2'd0, 6'd36, 2'd0, 6'd0, 8'd0});
            send_word_le(ctrl_word);
            send_word_le({16'd0, threshold_value});
            send_word_le(32'd0);
            send_word_be(32'h454E_4421);

            @(negedge eth_rxc);
            #0.1;
            eth_rx_ctl <= 1'b0;
            eth_rxd    <= 4'h0;
            repeat (16) @(posedge eth_rxc);
        end
    endtask

    task wait_udp_config_applied;
        input [15:0] sample_rate_value;
        input [15:0] channel_mask_value;
        input [15:0] threshold_value;
        input        adc_enable_value;
        input integer timeout_cycles;
        integer n;
        integer seen;
        begin
            seen = 0;
            for (n = 0; n < timeout_cycles; n = n + 1) begin
                @(posedge dut.sys_clk);
                if ((dut.sample_rate == sample_rate_value) &&
                    (dut.channel_en == channel_mask_value) &&
                    (dut.ctrl_ae_threshold == threshold_value) &&
                    (dut.ctrl_adc_rx_enable == adc_enable_value)) begin
                    seen = 1;
                    n = timeout_cycles;
                end
            end
            check(seen, "UDP downlink decoded and applied control packet");
        end
    endtask

    task wait_for_adc_pdwn_low;
        input integer timeout_cycles;
        integer n;
        integer seen;
        begin
            seen = 0;
            for (n = 0; n < timeout_cycles; n = n + 1) begin
                @(posedge dut.sys_clk);
                if ((adc1_pdwn === 1'b0) && (adc2_pdwn === 1'b0)) begin
                    seen = 1;
                    n = timeout_cycles;
                end
            end
            check(seen, "ADC9257 control path released both ADCs from power-down without force");
        end
    endtask

    task wait_sample_valids;
        input integer target_count;
        input integer timeout_cycles;
        integer n;
        integer seen;
        begin
            seen = 0;
            for (n = 0; n < timeout_cycles; n = n + 1) begin
                @(posedge dut.adc_clk);
                if (dut.ae_sample_valid)
                    seen = seen + 1;
                if (seen >= target_count)
                    n = timeout_cycles;
            end
            check(seen >= target_count, "ADC LVDS input produced filtered sample_valid at top");
        end
    endtask

    task wait_adc_pulse;
        input integer timeout_cycles;
        input [1023:0] label;
        integer n;
        integer seen;
        integer cur_abs;
        integer max_abs;
        integer top_abs;
        integer top_max_abs;
        integer stub_abs;
        integer stub_max_abs;
        integer pin_seen;
        integer sample_valid_seen;
        integer ds_valid_seen;
        integer ds_raw_abs;
        integer ds_raw_max_abs;
        integer trigger_hit_seen;
        begin
            seen = 0;
            max_abs = 0;
            top_max_abs = 0;
            stub_max_abs = 0;
            pin_seen = 0;
            sample_valid_seen = 0;
            ds_valid_seen = 0;
            ds_raw_max_abs = 0;
            trigger_hit_seen = 0;
            for (n = 0; n < timeout_cycles; n = n + 1) begin
                @(posedge dut.adc_clk);
                if ((|adc1_data_in_p) || (|adc2_data_in_p))
                    pin_seen = 1;
                if (dut.ae_sample_valid)
                    sample_valid_seen = sample_valid_seen + 1;
                top_abs = abs_s16(dut.ae_trigger_sample_data[0 +: SAMPLE_W]);
                if (top_abs > top_max_abs)
                    top_max_abs = top_abs;
                stub_abs = abs_s16(dut.gen_adc_preprocess_stub.sim_adc_sample_data[0 +: SAMPLE_W]);
                if (stub_abs > stub_max_abs)
                    stub_max_abs = stub_abs;
                ds_raw_abs = abs_s16(dut.ae_event_capture_inst.ds_trigger_sample_data[0 +: SAMPLE_W]);
                if (ds_raw_abs > ds_raw_max_abs)
                    ds_raw_max_abs = ds_raw_abs;
                if (dut.ae_event_capture_inst.trigger_hit)
                    trigger_hit_seen = 1;
                if (dut.ae_event_capture_inst.ds_sample_valid_dbg) begin
                    ds_valid_seen = ds_valid_seen + 1;
                    cur_abs = abs_s16(dut.ae_event_capture_inst.ds_trigger_sample_data_masked[0 +: SAMPLE_W]);
                    if (cur_abs > max_abs)
                        max_abs = cur_abs;
                end
                if (dut.ae_trig_pulse) begin
                    seen = 1;
                    n = timeout_cycles;
                end
            end
            if (!seen) begin
                $display("AE DEBUG: ds_max_abs=%0d ds_raw_max_abs=%0d top_max_abs=%0d stub_max_abs=%0d pin_seen=%0d sample_valid_seen=%0d ds_valid_seen=%0d trigger_hit_seen=%0d raw_mode=%0d pulse_remaining=%0d adc1_p=0x%0h sample_rate_adc=%0d cfg_update=%0b cap_en_adc=%0b cap_state=%0d prefill=%0d threshold=%0d active=0x%0h trig=0x%0h cap_en=%0b busy=%0b wait_ddr=%0b wait_upload=%0b",
                         max_abs,
                         ds_raw_max_abs,
                         top_max_abs,
                         stub_max_abs,
                         pin_seen,
                         sample_valid_seen,
                         ds_valid_seen,
                         trigger_hit_seen,
                         raw_mode,
                         pulse_remaining,
                         adc1_data_in_p,
                         dut.ae_event_capture_inst.sample_rate_adc,
                         dut.ae_event_capture_inst.cfg_update_adc_pulse,
                         dut.ae_event_capture_inst.cap_en_adc,
                         dut.ae_event_capture_inst.ae_cap_ctrl_inst.state_cur,
                         dut.ae_event_capture_inst.ae_cap_ctrl_inst.prefill_cnt_r,
                         dut.ae_event_capture_inst.trig_threshold_dbg,
                         dut.ae_event_capture_inst.active_ch_mask_dbg,
                         dut.ae_trig_mask,
                         dut.ae_cap_en,
                         dut.ae_capture_busy,
                         dut.ae_event_wait_ddr,
                         dut.ae_event_wait_upload);
                fail(label);
                $display("FAIL: tb_top_system errors=%0d", error_count);
                $finish;
            end else begin
                pass(label);
            end
        end
    endtask

    task wait_sys_pulse;
        input integer timeout_cycles;
        input integer selector;
        input [1023:0] label;
        integer n;
        integer seen;
        begin
            seen = 0;
            for (n = 0; n < timeout_cycles; n = n + 1) begin
                @(posedge dut.sys_clk);
                if ((selector == 0 && dut.ae_committed_event_pulse) ||
                    (selector == 1 && dut.udp_upload_done_pulse) ||
                    (selector == 2 && dut.ctrl_req_upload_pulse)) begin
                    seen = 1;
                    n = timeout_cycles;
                end
            end
            check(seen, label);
        end
    endtask

    task wait_tx_start;
        input integer timeout_cycles;
        integer n;
        integer seen;
        begin
            seen = 0;
            for (n = 0; n < timeout_cycles; n = n + 1) begin
                @(posedge dut.gmii_tx_clk);
                if (dut.udp_tx_start_en) begin
                    seen = 1;
                    n = timeout_cycles;
                end
            end
            check(seen, "UDP upload path asserted tx_start_en");
        end
    endtask

    task wait_tx_activity;
        input integer timeout_cycles;
        integer n;
        integer seen;
        begin
            seen = 0;
            for (n = 0; n < timeout_cycles; n = n + 1) begin
                @(posedge dut.gmii_tx_clk);
                if (eth_tx_ctl === 1'b1 || dut.udp_gmii_tx_en === 1'b1) begin
                    seen = 1;
                    n = timeout_cycles;
                end
            end
            check(seen, "top Ethernet TX interface became active");
        end
    endtask

    initial begin
        #1000000;
        fail("simulation timeout");
        $display("FAIL: tb_top_system errors=%0d", error_count);
        $finish;
    end

    initial begin
        error_count = 0;
        raw_sample_idx = 0;
        serial_edge_idx = 0;
        raw_valid = 0;
        raw_mode = 0;
        pulse_remaining = 0;
        set_raw_all(clip_s14(0));
        clear_ad9257_serial_words();
        drive_ad9257_idle();

        repeat (20) @(posedge sys_clk_p);
        reset_sys_clk = 1'b1;
        wait (dut.reset_n === 1'b1);
        repeat (40) @(posedge dut.sys_clk);

        send_udp_cfg_frame(16'd1, 16'h00FF, 16'd32767, 1'b1, 1'b0, 1'b1);
        wait_udp_config_applied(16'd1, 16'h00FF, 16'd32767, 1'b1, 20000);
        check(dut.sample_rate == 16'd1, "sample_rate updated from UDP control packet");
        check(dut.channel_en == 16'h00FF, "channel_en updated from UDP control packet");
        check(dut.ctrl_ae_threshold == 16'd32767, "AE threshold updated from UDP control packet");
        check(dut.ctrl_adc_rx_enable == 1'b1, "ADC receive enable updated from UDP control packet");

        wait_for_adc_pdwn_low(500000);
        wait_sample_valids(32, 200000);
        wait_sample_valids(160, 300000);
        check(!dut.ae_capture_busy && !dut.ae_event_wait_ddr && !dut.ae_event_wait_upload,
              "AE capture stayed idle during ADC/filter warmup");

        send_udp_cfg_frame(16'd1, 16'h00FF, 16'd1, 1'b1, 1'b0, 1'b0);
        wait_udp_config_applied(16'd1, 16'h00FF, 16'd1, 1'b1, 20000);
        raw_mode = 1;
        pulse_remaining = 8192;
        wait_adc_pulse(20000, "AE event capture triggered from ADC input pins");
        wait_sys_pulse(100000, 0, "AE DDR accepted and committed captured event");
        @(posedge dut.sys_clk);
        check(dut.ae_event_available == 1'b1, "AE event marked available for upload");

        send_udp_cfg_frame(16'd1, 16'h00FF, 16'd1, 1'b1, 1'b1, 1'b0);
        wait_tx_start(100000);
        check(dut.tx_byte_num >= 16'd224, "AEUP upload packet length is valid");
        wait_tx_activity(20000);
        wait_sys_pulse(100000, 1, "udp_event_sensor_tx completed full upload request");
        @(posedge dut.sys_clk);
        check(dut.ae_event_available == 1'b0, "AE upload completion cleared availability flag");

        if (error_count == 0)
            $display("PASS: tb_top_system completed UDP downlink, ADC/filter, AE capture, DDR, and UDP upload checks");
        else
            $display("FAIL: tb_top_system errors=%0d", error_count);
        $finish;
    end
endmodule
