onbreak {quit -f}
onerror {quit -f}

vsim -lib xil_defaultlib ae_frame_bank_bram_opt

do {wave.do}

view wave
view structure
view signals

do {ae_frame_bank_bram.udo}

run -all

quit -force
