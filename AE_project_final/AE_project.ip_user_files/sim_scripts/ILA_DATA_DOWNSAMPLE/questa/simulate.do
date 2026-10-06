onbreak {quit -f}
onerror {quit -f}

vsim -lib xil_defaultlib ILA_DATA_DOWNSAMPLE_opt

do {wave.do}

view wave
view structure
view signals

do {ILA_DATA_DOWNSAMPLE.udo}

run -all

quit -force
