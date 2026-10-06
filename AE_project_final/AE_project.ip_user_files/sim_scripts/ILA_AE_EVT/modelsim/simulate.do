onbreak {quit -f}
onerror {quit -f}

vsim -voptargs="+acc" -L xpm -L xil_defaultlib -L unisims_ver -L unimacro_ver -L secureip -lib xil_defaultlib xil_defaultlib.ILA_AE_EVT xil_defaultlib.glbl

do {wave.do}

view wave
view structure
view signals

do {ILA_AE_EVT.udo}

run -all

quit -force
