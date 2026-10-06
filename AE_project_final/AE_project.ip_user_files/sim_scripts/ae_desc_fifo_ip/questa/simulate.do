onbreak {quit -f}
onerror {quit -f}

vsim -lib xil_defaultlib ae_desc_fifo_ip_opt

do {wave.do}

view wave
view structure
view signals

do {ae_desc_fifo_ip.udo}

run -all

quit -force
