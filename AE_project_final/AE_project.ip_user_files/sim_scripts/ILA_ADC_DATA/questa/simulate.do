onbreak {quit -f}
onerror {quit -f}

vsim -lib xil_defaultlib ILA_ADC_DATA_opt

do {wave.do}

view wave
view structure
view signals

do {ILA_ADC_DATA.udo}

run -all

quit -force
