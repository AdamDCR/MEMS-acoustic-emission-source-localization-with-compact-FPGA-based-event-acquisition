onbreak {quit -f}
onerror {quit -f}

vsim -lib xil_defaultlib adc_dclk_in_opt

do {wave.do}

view wave
view structure
view signals

do {adc_dclk_in.udo}

run -all

quit -force
