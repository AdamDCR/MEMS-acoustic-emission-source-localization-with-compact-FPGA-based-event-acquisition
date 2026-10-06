onbreak {quit -f}
onerror {quit -f}

vsim -lib xil_defaultlib ILA_AE_EVT_opt

do {wave.do}

view wave
view structure
view signals

do {ILA_AE_EVT.udo}

run -all

quit -force
