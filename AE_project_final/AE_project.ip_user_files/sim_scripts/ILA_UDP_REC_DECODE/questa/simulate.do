onbreak {quit -f}
onerror {quit -f}

vsim -lib xil_defaultlib ILA_UDP_REC_DECODE_opt

do {wave.do}

view wave
view structure
view signals

do {ILA_UDP_REC_DECODE.udo}

run -all

quit -force
