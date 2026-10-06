onbreak {quit -force}
onerror {quit -force}

asim +access +r +m+ae_desc_fifo_ip -L xpm -L fifo_generator_v13_2_5 -L xil_defaultlib -L unisims_ver -L unimacro_ver -L secureip -O5 xil_defaultlib.ae_desc_fifo_ip xil_defaultlib.glbl

do {wave.do}

view wave
view structure

do {ae_desc_fifo_ip.udo}

run -all

endsim

quit -force
