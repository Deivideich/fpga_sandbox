PROJECT = blink

CHIP = GW2AR-LV18QN88C8/I7
FAMILY = GW2A-18C
PINS = pins.cst

all: $(PROJECT).fs

$(PROJECT).json: $(PROJECT).v
	yosys -p "synth_gowin -json $(PROJECT).json" $(PROJECT).v

$(PROJECT)_pnr.json: $(PROJECT).json $(PINS)
	nextpnr-himbaechel --json $(PROJECT).json --write $(PROJECT)_pnr.json --device $(CHIP) --vopt family=$(FAMILY) --vopt cst=$(PINS)

$(PROJECT).fs: $(PROJECT)_pnr.json
	gowin_pack -d $(FAMILY) -o $(PROJECT).fs $(PROJECT)_pnr.json

flash: $(PROJECT).fs
	openFPGALoader -b tangnano20k $(PROJECT).fs

clean:
	rm -f *.json *.fs

.PHONY: all flash clean
