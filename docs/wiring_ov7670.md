# Wiring a bare OV7670 module to the AX7010

The camera goes on **J11**, whose 34 IOs are all in bank 35 at 3.3 V and each
have a 33 Ω resistor in series on the board — which happens to act as source
series termination, so it helps rather than hurts here.

J11 pin numbering follows the usual 2×20 convention: **odd pins on one row,
even on the other, pin 1 marked on the silkscreen** (pins 1, 2, 39 and 40 are
all labelled).

## Connections

| OV7670 pin | J11 pin | Zynq pin | Note |
|---|---|---|---|
| 3V3 | 39 or 40 | – | +3.3 V |
| GND | 1, and 37 or 38 | – | run **at least two** ground wires |
| D0 | 3 | F17 | |
| D1 | 4 | F16 | |
| D2 | 5 | F20 | |
| D3 | 6 | F19 | |
| D4 | 7 | G20 | |
| D5 | 8 | G19 | |
| D6 | 9 | H18 | |
| D7 | 10 | J18 | |
| HREF | 11 | L20 | |
| VSYNC | 12 | L19 | |
| SIOC | 13 | M20 | needs a pull-up, see below |
| SIOD | 14 | M19 | needs a pull-up, see below |
| *(leave empty)* | 15 | K18 | guard pin next to PCLK — do not connect |
| **PCLK** | **16** | **K17** | must stay here: only MRCC pin in reach |
| PWDN | 33 | G15 | driven low by the FPGA |
| RESET# | 34 | H15 | held low ~2.6 ms after reset, then released |
| **XCLK** | **36** | **K14** | deliberately at the far end of the header |

D0–D7, HREF, VSYNC, SIOC and SIOD occupy J11 pins 3–14 in order, so a 2×6
ribbon segment covers the whole bus in one go.

## Before powering anything on

1. **Check the pull-ups on SIOC and SIOD.** Cheap OV7670 modules vary: some
   carry 4.7 kΩ or 10 kΩ to their own 3.3 V rail, some carry nothing. With the
   module unpowered, measure from SIOC and from SIOD to the module's 3V3 pin.
   Anything above roughly 20 kΩ means there is no usable pull-up — add 4.7 kΩ
   from each line to J11 pin 39 or 40.

   The XDC does set `PULLUP true` on SIOD, but the Zynq internal pull-up is
   around 50 kΩ. It is a fallback, not a substitute for real resistors.

2. **Check the module's supply voltage.** Some OV7670 breakouts want 3.3 V and
   some want 2.8 V with an on-board regulator. Feeding 3.3 V into a 2.8 V-only
   part will not end well. J11 pin 2 is +5 V — never connect it to the camera.

3. **Do not connect J11 pin 15.** It is the other half of PCLK's differential
   pair on the PCB, and leaving it idle keeps the noisiest neighbour away from
   the incoming clock.

## Signal integrity with jumper wires

PCLK runs at 25 MHz, which is the one place flying leads genuinely bite.

- Keep every wire **10 cm or shorter**, and keep the bundle flat rather than
  coiled.
- Run a ground wire **immediately alongside PCLK**, ideally twisted with it.
  This is the single highest-value thing you can do.
- XCLK is the aggressor: it is a 25 MHz clock the FPGA drives out. It is placed
  on J11 pin 36 specifically so it is nowhere near PCLK on pin 16 or the data
  bus on pins 3–10. Keep its wire physically separated from the rest.
- If the picture is stable but shows occasional pixel noise, the first thing to
  try is halving the pixel rate: write `CLKRC = 0x01` so the sensor divides XCLK
  by two, giving a 12.5 MHz PCLK. `sccb_probe` already writes and restores this
  register, so it is a one-line change.
- A `PCLK_INVERT` option (sample on the falling edge instead of the rising one)
  is worth adding to `cam_capture` in milestone 4 as a second escape hatch. It
  does not exist yet - there is no capture logic to put it in.

## Why J11 and not J10

J10 has no MRCC pin available. Bank 34's MRCC pair is U18/U19 and U18 is the
board's own 50 MHz oscillator, so the best J10 can offer an incoming pixel
clock is an SRCC pin (U14/U15). J11 has two full MRCC pairs, K17/K18 and
H16/H17, and all of its IOs sit in one bank.
