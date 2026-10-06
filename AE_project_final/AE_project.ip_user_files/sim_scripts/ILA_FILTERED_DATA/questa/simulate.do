onbreak {quit -f}
onerror {quit -f}

vsim -lib xil_defaultlib ILA_FILTERED_DATA_opt

do {wave.do}

view wave
view structure
view signals

do {ILA_FILTERED_DATA.udo}

run -all

quit -force
