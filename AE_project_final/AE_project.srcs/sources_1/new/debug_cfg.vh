`ifndef DEBUG_CFG_VH
`define DEBUG_CFG_VH

// ============================================================
// 全局调试宏开关
// 默认全部关闭，先保证综合/实现主流程稳定通过。
// 需要抓板级波形时，再按模块逐项打开。
// ============================================================
// UDP 接收解码调试
//`define BOARD_ILA_ETH_REC_DECODE
// ADC SPI 调试
//`define DEBUG_ADC_SPI
// ADC 数据采集调试
//`define DEBUG_ADC_DATA_EN
`define ADC1_DEBUG_ILA_EN 0
`define ADC2_DEBUG_ILA_EN 0

`define ADC_FIR_DEBUG
`define ILA_ADC1_FILTERED_DATA_EN 0
`define ILA_ADC2_FILTERED_DATA_EN 0
// AE事件捕获调试
//`define DEBUG_ILA_DATA_DOWNSAMPLE
//`define DEBUG_ILA_AE_AXIS
//`define DEBUG_ILA_AE_EVENT

//udp发送调试
//`define DEBUG_ILA_AE_EVT
`endif
