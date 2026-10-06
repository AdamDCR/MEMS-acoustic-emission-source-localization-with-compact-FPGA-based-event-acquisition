onbreak {quit -f}
onerror {quit -f}

vsim -lib xil_defaultlib ILA_AE_EVENT_opt

do {wave.do}

view wave
view structure
view signals

do {ILA_AE_EVENT.udo}

run -all

quit -force
