# ALINX AX7010 pinout reference

Everything here is taken from the AX7010 User Manual (parts 5.2, 7.1, 7.4–7.7),
the AX7010/AX7020 schematic V2.0 (sheets 5 and 15), and the Vivado package file
for `xc7z010clg400` (which is where the MRCC / SRCC annotations come from).

Part: **`xc7z010clg400-1`** — Zynq-7000, 400-pin FBGA.

## What is and is not available to PL-only logic

| Peripheral | Reachable from PL alone? |
|---|---|
| 50 MHz oscillator, 4 LEDs, 4 keys | yes |
| HDMI (raw TMDS, bank 34) | yes |
| J10 / J11 expansion IO (34 pins each) | yes |
| DDR3, gigabit Ethernet, SD, USB, **USB-UART** | **no** — all on PS MIO |

The missing UART is the reason this project uses the HDMI screen and the LEDs
as its debug channel rather than printing.

## Clock

| Signal | Zynq pin | Pin name | Notes |
|---|---|---|---|
| `PL_GCLK` | **U18** | `IO_L12P_T1_MRCC_34` | 50 MHz single-ended, 3.3 V |

## LEDs and keys

LEDs are **active low** (drive 0 to light). Keys read **0 when pressed**.

| Signal | Zynq pin | Bank |
|---|---|---|
| LED1 | M14 | 35 |
| LED2 | M15 | 35 |
| LED3 | K16 | 35 |
| LED4 | J16 | 35 |
| KEY1 | N15 | 35 |
| KEY2 | N16 | 35 |
| KEY3 | T17 | 34 |
| KEY4 | R17 | 34 |

## HDMI

The board has **no HDMI encoder chip**. The four TMDS pairs run straight from
PL bank 34 to the connector through ESD protection, so the 8b/10b encoding and
the 10:1 serialisation are the FPGA's job. `HDMI_SCL` / `HDMI_SDA` reach the
sink through a GTL2002D level shifter for EDID, which this project does not use.

| Signal | Zynq pin | Pin name |
|---|---|---|
| `HDMI_CLK_P` / `_N` | N18 / P19 | `IO_L13P/N_T2_MRCC_34` |
| `HDMI_D0_P` / `_N` (blue) | V20 / W20 | `IO_L16P/N_T2_34` |
| `HDMI_D1_P` / `_N` (green) | T20 / U20 | `IO_L15P/N_T2_DQS_34` |
| `HDMI_D2_P` / `_N` (red) | N20 / P20 | `IO_L14P/N_T2_SRCC_34` |
| `HDMI_OUT_EN` | V16 | drives a TPS2051B that supplies +5 V to the sink |
| `HDMI_HPD` | Y19 | hot-plug detect — reaches the FPGA through U18 (NC7WZ07), an **open-drain** buffer, so this pin needs `PULLUP true` or it reads 0 always |
| `HDMI_SCL` / `HDMI_SDA` | R18 / R16 | DDC, unused here |

Every P/N pair lines up with the FPGA's own P/N, so no swaps are needed.
Bank 34 is 3.3 V, which is what makes the `TMDS_33` standard legal.

`HDMI_OUT_EN` is assumed **active high** (TPS2051B in SOT-23-5: pin 5 IN,
pin 4 EN, pin 1 OUT, pin 3 /OC pulled up through 1 k). If a monitor never sees
a source, measure +5 V on HDMI connector pin 18 before suspecting the TMDS.

## Expansion header J11 (used for the camera)

40-pin 2.54 mm, all 34 IOs in **bank 35**, 3.3 V by default, with a 33 Ω
resistor in series on every signal. J10 is the same idea but its IOs sit in
bank 34 except `EX_IO1_16` / `EX_IO1_17`, which are in bank 35.

Power and ground: **pin 1, 37, 38 = GND**, pin 2 = +5 V, **pin 39, 40 = +3.3 V**.

| J11 pin | Net | Zynq pin | Pin name |
|---|---|---|---|
| 3 / 4 | EX_IO2_1N / 1P | F17 / F16 | `IO_L6N/P_T0_35` |
| 5 / 6 | EX_IO2_2N / 2P | F20 / F19 | `IO_L15N/P_T2_DQS_35` |
| 7 / 8 | EX_IO2_3N / 3P | G20 / G19 | `IO_L18N/P_T2_35` |
| 9 / 10 | EX_IO2_4N / 4P | H18 / J18 | `IO_L14N/P_T2_SRCC_35` |
| 11 / 12 | EX_IO2_5N / 5P | L20 / L19 | `IO_L9N/P_T1_DQS_35` |
| 13 / 14 | EX_IO2_6N / 6P | M20 / M19 | `IO_L7N/P_T1_35` |
| **15 / 16** | EX_IO2_7N / 7P | K18 / **K17** | **`IO_L12N/P_T1_MRCC_35`** |
| 17 / 18 | EX_IO2_8N / 8P | J19 / K19 | `IO_L10N/P_T1_35` |
| 19 / 20 | EX_IO2_9N / 9P | H20 / J20 | `IO_L17N/P_T2_35` |
| 21 / 22 | EX_IO2_10N / 10P | L17 / L16 | `IO_L11N/P_T1_SRCC_35` |
| 23 / 24 | EX_IO2_11N / 11P | M18 / M17 | `IO_L8N/P_T1_35` |
| 25 / 26 | EX_IO2_12N / 12P | D20 / D19 | `IO_L4N/P_T0_35` |
| 27 / 28 | EX_IO2_13N / 13P | E19 / E18 | `IO_L5N/P_T0_35` |
| 29 / 30 | EX_IO2_14N / 14P | G18 / G17 | `IO_L16N/P_T2_35` |
| **31 / 32** | EX_IO2_15N / 15P | H17 / **H16** | **`IO_L13N/P_T2_MRCC_35`** |
| 33 / 34 | EX_IO2_16N / 16P | G15 / H15 | `IO_L19N/P_T3_35` |
| 35 / 36 | EX_IO2_17N / 17P | J14 / K14 | `IO_L20N/P_T3_35` |

### Clock-capable pins on the headers

An incoming pixel clock has to land on a clock-capable pin to reach a BUFG
without going through fabric routing.

| Header | Pin | Zynq pin | Type |
|---|---|---|---|
| J11-16 | EX_IO2_7P | **K17** | MRCC (bank 35) — used for OV7670 PCLK |
| J11-15 | EX_IO2_7N | K18 | MRCC |
| J11-32 | EX_IO2_15P | H16 | MRCC — spare |
| J11-31 | EX_IO2_15N | H17 | MRCC |
| J11-10 / 9 | EX_IO2_4P / 4N | J18 / H18 | SRCC |
| J11-22 / 21 | EX_IO2_10P / 10N | L16 / L17 | SRCC |
| J10-16 / 15 | EX_IO1_7P / 7N | U14 / U15 | SRCC (bank 34) |

J10 has no MRCC pin: bank 34's MRCC pair is U18/U19, and U18 is the on-board
50 MHz oscillator. That is the main reason the camera goes on J11.

## Bank voltages

Banks 34 and 35 are both 3.3 V as shipped. Both can be changed by replacing the
SPX3819M5-3-3 regulator, but nothing in this project needs that. Do not connect
5 V logic to the headers directly.
