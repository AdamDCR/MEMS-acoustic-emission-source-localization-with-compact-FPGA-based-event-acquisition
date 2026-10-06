`timescale 1ns / 1ps

module ae_event_header_gen #(

    parameter integer HEADER_WORDS = 4      ,
    parameter integer FRAME_SAMPLES = 8192,
    parameter integer PRE_SAMPLES  = 4096,
    parameter integer POST_SAMPLES = 4096
)(
    input                [ 255: 0]      meta_info                  ,
    input                [  29: 0]      ddr_base_addr              ,
    input                [  31: 0]      slot_index                 ,
    input                [  31: 0]      slot_bytes                 ,

    output wire          [ 255: 0]      hdr0                       ,
    output wire          [ 255: 0]      hdr1                       ,
    output wire          [ 255: 0]      hdr2                       ,
    output wire          [ 255: 0]      hdr3                        
);

    // ------------------------------------------------------------------------
    // meta_info 字段定义
    // [255:224] event_seq
    // [223:208] threshold
    // [207:192] ch_mask
    // [191:160] trigger_sample_index
    // [159:128] payload_words
    // [127:32]  time_info
    // [31:0]    flags
    //
    // time_info 字段定义
    // [95:80] year
    // [79:72] month
    // [71:64] day
    // [63:56] hour
    // [55:48] minute
    // [47:40] second
    // [39:8]  subsec_us
    // [7]     time_valid
    // [6:0]   reserved
    // ------------------------------------------------------------------------

    wire                 [  31: 0]      event_seq                  ;
    wire                 [  15: 0]      threshold                  ;
    wire                 [  15: 0]      ch_mask                    ;
    wire                 [  31: 0]      trigger_sample_index       ;
    wire                 [  31: 0]      payload_words              ;
    wire                 [  95: 0]      time_info                  ;
    wire                 [  31: 0]      flags                      ;

    wire                 [  15: 0]      year                       ;
    wire                 [   7: 0]      month                      ;
    wire                 [   7: 0]      day                        ;
    wire                 [   7: 0]      hour                       ;
    wire                 [   7: 0]      minute                     ;
    wire                 [   7: 0]      second                     ;
    wire                 [  31: 0]      subsec_us                  ;
    wire                                time_valid                 ;

    wire                 [  31: 0]      frame_words                ;
    wire                 [  31: 0]      total_bytes                ;
    wire                 [  15: 0]      sample_rate_div            ;
    wire                 [  15: 0]      trig_mask                  ;

    assign                              sample_rate_div             = flags[15:0]          ;
    assign                              trig_mask                   = flags[31:16]         ;
    assign                              event_seq                   = meta_info[255:224]   ;
    assign                              threshold                   = meta_info[223:208]   ;
    assign                              ch_mask                     = meta_info[207:192]   ;
    assign                              trigger_sample_index        = meta_info[191:160]   ;
    assign                              payload_words               = meta_info[159:128]   ;
    assign                              time_info                   = meta_info[127:32]    ;
    assign                              flags                       = meta_info[31:0]      ;

    assign                              year                        = time_info[95:80]     ;
    assign                              month                       = time_info[79:72]     ;
    assign                              day                         = time_info[71:64]     ;
    assign                              hour                        = time_info[63:56]     ;
    assign                              minute                      = time_info[55:48]     ;
    assign                              second                      = time_info[47:40]     ;
    assign                              subsec_us                   = time_info[39:8]      ;
    assign                              time_valid                  = time_info[7]         ;

    assign                              frame_words                 = payload_words + HEADER_WORDS[31:0];
    assign                              total_bytes                 = frame_words << 5     ;

    // ------------------------------------------------------------------------
    // Header Word 0
    // ------------------------------------------------------------------------
    assign hdr0 = {
        32'hAE5A_5A5A,                                              // magic
        16'h0001,                                                   // version
        HEADER_WORDS[7:0],                                          // header words
        8'd0,                                                       // reserved
        event_seq,
        threshold,
        ch_mask,
        trigger_sample_index,
        payload_words,
        frame_words,
        flags
    };

    // ------------------------------------------------------------------------
    // Header Word 1
    // ------------------------------------------------------------------------
    assign hdr1 = {
        year,
        month,
        day,
        hour,
        minute,
        second,
        subsec_us,
        167'd0,
        time_valid
    };

    // ------------------------------------------------------------------------
    // Header Word 2
    // ------------------------------------------------------------------------
    assign hdr2 = {
        2'd0,
        ddr_base_addr,
        slot_index,
        slot_bytes,
        total_bytes,
        32'd0,
        32'd0,
        64'd0
    };

    // ------------------------------------------------------------------------
    // Header Word 3：预留
    // ------------------------------------------------------------------------
assign hdr3 = {
    32'h4145_4D45,                                                  // "AEME"，AE meta 扩展标识
    FRAME_SAMPLES[15:0],
    PRE_SAMPLES[15:0],
    POST_SAMPLES[15:0],
    PRE_SAMPLES[15:0],                                              // trigger_offset
    sample_rate_div,
    trig_mask,
    128'd0
};

endmodule
