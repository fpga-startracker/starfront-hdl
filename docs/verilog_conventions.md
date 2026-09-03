# Verilog Naming & Coding Conventions

## Project: OV7670 Camera → VGA Display on Basys 3

---

## 1. General Naming Rules

- **All lowercase** — no camelCase or UPPERCASE for signal names.
- **Use underscores** (`_`) as word separators.
- **Module names** follow `snake_case` (e.g., `sccb_master`, `vga_controller`, `frame_buffer`).

---

## 2. Signal Naming Conventions

### 2.1 AXI Stream Signals

Pattern: `{s|m}_axis_<signal>`

| Prefix   | Meaning              |
|----------|----------------------|
| `s_axis` | Slave (input) side   |
| `m_axis` | Master (output) side |

Standard suffixes:

| Signal    | Description              |
|-----------|--------------------------|
| `_tdata`  | Transfer data bus        |
| `_tvalid` | Transfer valid indicator |
| `_tready` | Transfer ready indicator |

Example: `s_axis_tdata`, `m_axis_tvalid`

### 2.2 AXI Lite Signals

Pattern: `{s|m}_axi_<channel><signal>`

Channels: `ar` (read address), `aw` (write address), `r` (read data), `w` (write data), `b` (write response).

Examples: `m_axi_araddr`, `m_axi_arvalid`, `m_axi_wdata`, `m_axi_wstrb`, `m_axi_bresp`

### 2.3 OV7670 Camera Interface Signals

Pattern: `ov7670_<signal>` — prefix ทุก signal ที่เชื่อมต่อกับ OV7670 โดยตรง

| Signal            | Dir    | Description                                            |
|-------------------|--------|--------------------------------------------------------|
| `ov7670_pclk`     | input  | Pixel clock จาก camera                                 |
| `ov7670_href`     | input  | Horizontal reference (active-high = valid pixel data)  |
| `ov7670_vsync`    | input  | Vertical sync (frame boundary)                         |
| `ov7670_data`     | input  | Pixel data bus `[7:0]`                                 |
| `ov7670_xclk`     | output | System clock ที่ส่งให้ camera (เช่น 25 MHz)            |
| `ov7670_reset_n`  | output | Camera reset (active-low, ใช้ `_n` suffix)             |
| `ov7670_pwdn`     | output | Power-down control (active-high)                       |

```verilog
input  wire        ov7670_pclk,
input  wire        ov7670_href,
input  wire        ov7670_vsync,
input  wire [7:0]  ov7670_data,
output wire        ov7670_xclk,
output wire        ov7670_reset_n,
output wire        ov7670_pwdn
```

### 2.4 SCCB Interface Signals

Pattern: `sccb_<signal>` — ใช้สำหรับ Serial Camera Control Bus (I2C-like)

| Signal        | Dir    | Description                         |
|---------------|--------|-------------------------------------|
| `sccb_sio_c`  | output | SCCB clock (SIO_C)                  |
| `sccb_sio_d`  | inout  | SCCB data (SIO_D, bidirectional)    |

สำหรับ internal logic ภายใน SCCB master module:

| Signal              | Description                             |
|---------------------|-----------------------------------------|
| `sccb_sio_d_oe`     | Output enable สำหรับ SIO_D (tri-state)  |
| `sccb_sio_d_out`    | Data ที่จะขับออก SIO_D                   |
| `sccb_sio_d_in`     | Data ที่อ่านกลับจาก SIO_D               |

```verilog
output wire        sccb_sio_c,
inout  wire        sccb_sio_d,
// internal tri-state control
reg                sccb_sio_d_oe  = 1'b0;
reg                sccb_sio_d_out = 1'b1;
wire               sccb_sio_d_in;
assign sccb_sio_d    = sccb_sio_d_oe ? sccb_sio_d_out : 1'bz;
assign sccb_sio_d_in = sccb_sio_d;
```

### 2.5 VGA Output Signals

Pattern: `vga_<signal>` — ทุก signal ที่ขับออกไป VGA connector

| Signal        | Width | Description                                   |
|---------------|-------|-----------------------------------------------|
| `vga_red`     | [3:0] | Red channel (4-bit, Basys 3 resistor DAC)     |
| `vga_grn`     | [3:0] | Green channel (4-bit)                         |
| `vga_blu`     | [3:0] | Blue channel (4-bit)                          |
| `vga_hsync`   | 1     | Horizontal sync                               |
| `vga_vsync`   | 1     | Vertical sync                                 |

```verilog
output wire [3:0]  vga_red,
output wire [3:0]  vga_grn,
output wire [3:0]  vga_blu,
output wire        vga_hsync,
output wire        vga_vsync
```

สำหรับ internal VGA timing:

| Signal              | Description                              |
|---------------------|------------------------------------------|
| `vga_h_count`       | Horizontal pixel counter                 |
| `vga_v_count`       | Vertical line counter                    |
| `vga_active`        | Active display area flag                 |
| `vga_pixel_x`       | Pixel X coordinate (0–639)               |
| `vga_pixel_y`       | Pixel Y coordinate (0–479)               |

### 2.6 Frame Buffer / Memory Signals

Pattern: `fb_<signal>` — สำหรับ frame buffer หรือ block RAM

| Signal          | Description                       |
|-----------------|-----------------------------------|
| `fb_addr_wr`    | Write address                     |
| `fb_addr_rd`    | Read address                      |
| `fb_data_in`    | Data to write                     |
| `fb_data_out`   | Data read out                     |
| `fb_we`         | Write enable                      |

### 2.7 Clock & Reset

| Signal    | Description                                  |
|-----------|----------------------------------------------|
| `clk`     | System clock (100 MHz จาก Basys 3)           |
| `clk_25`  | 25 MHz pixel clock (VGA / OV7670 XCLK)      |
| `clk_50`  | 50 MHz clock (ถ้าต้องใช้)                    |
| `rst`     | Synchronous reset (active-high)              |
| `rst_n`   | Asynchronous reset (active-low, ใช้ `_n`)    |

- Active-low signals ใช้ suffix `_n` เสมอ.
- Clock ที่ผ่าน PLL/MMCM ใช้ `clk_<freq>` pattern.

### 2.8 Debug / Miscellaneous

- Debug probes use descriptive names with `_out` suffix: `state_out`.
- LED outputs: `led` (e.g., `led[15:0]`).
- Switch inputs: `sw` (e.g., `sw[15:0]`).
- Button inputs: `btn_c`, `btn_u`, `btn_d`, `btn_l`, `btn_r`.

---

## 3. Register & Output Naming

- Internal registers mirror the output port name with a `_reg` suffix.
- Outputs are assigned from registers via continuous `assign` statements.

```verilog
reg [3:0]  vga_red_reg = 4'b0;
assign vga_red = vga_red_reg;
```

---

## 4. State Machine Conventions

- States are defined using `localparam` with descriptive `UPPER_CASE` names.
- State encoding uses sized literals (e.g., `3'd0`).
- State register is named `state`.

```verilog
// SCCB master states
localparam SCCB_IDLE       = 3'd0;
localparam SCCB_START      = 3'd1;
localparam SCCB_SEND_BIT   = 3'd2;
localparam SCCB_STOP       = 3'd3;
reg [2:0] state = SCCB_IDLE;

// Camera capture states
localparam CAP_WAIT_VSYNC  = 2'd0;
localparam CAP_WAIT_HREF   = 2'd1;
localparam CAP_CAPTURE     = 2'd2;
reg [1:0] state = CAP_WAIT_VSYNC;
```

- ถ้ามีหลาย state machine ใน module เดียว ให้ตั้งชื่อ state register ต่างกัน เช่น `sccb_state`, `cap_state`.

---

## 5. Internal Constants & Parameters

- Use `localparam` for fixed values, `parameter` for configurable values.
- Constant names are `UPPER_CASE`.

```verilog
// OV7670 SCCB address (write)
localparam OV7670_ADDR_W  = 8'h42;
localparam OV7670_ADDR_R  = 8'h43;

// VGA 640x480 @ 60Hz timing (25 MHz pixel clock)
localparam H_DISPLAY  = 10'd640;
localparam H_FP       = 10'd16;    // front porch
localparam H_SYNC     = 10'd96;    // sync pulse
localparam H_BP       = 10'd48;    // back porch
localparam H_TOTAL    = 10'd800;

localparam V_DISPLAY  = 10'd480;
localparam V_FP       = 10'd10;
localparam V_SYNC     = 10'd2;
localparam V_BP       = 10'd29;    // 33 lines total (sync + bp)
localparam V_TOTAL    = 10'd521;

// RGB565 pixel format
localparam PIXEL_WIDTH = 16;
```

---

## 6. Project Module Hierarchy

```
top_ov7670_vga                ← Top-level (Basys 3)
├── clk_gen                   ← Clock wizard / PLL (100 → 25 MHz)
├── sccb_master               ← SCCB controller (I2C-like)
│   └── sccb_sender           ← Low-level bit driver
├── ov7670_init               ← OV7670 register config sequence
├── ov7670_capture            ← Pixel capture from camera
├── frame_buffer              ← Dual-port BRAM (write from capture, read from VGA)
└── vga_controller            ← VGA timing + pixel output
    └── vga_sync_gen          ← H/V sync generator
```

---

## 7. File & Module Structure

The standard module layout follows this order:

1. **Timescale directive** — `` `timescale 1ns / 1ps ``
2. **Module comment block** — brief description of the module's purpose.
3. **Port declarations** — grouped and commented by interface:
   - Clock and reset
   - OV7670 camera interface
   - SCCB interface
   - VGA output interface
   - Frame buffer interface
   - AXI interfaces (if applicable)
   - Debug probes
4. **Parameters / localparams** (timing constants, addresses)
5. **State machine localparams**
6. **Output register declarations** (with default initialization)
7. **Continuous assigns** (output ports ← registers)
8. **Internal constants**
9. **Behavioral logic** (`always` blocks)

---

## 8. Coding Style Rules

| Rule | Convention |
|------|------------|
| Port direction keywords | `input wire`, `output wire`, `inout wire` — always explicit |
| Register initialization | Use inline initialization (e.g., `reg [2:0] state = IDLE;`) |
| Bit widths | Always specify width for multi-bit signals; use `[ N:0]` MSB-left |
| Literal values | Sized and typed (e.g., `1'b0`, `8'h42`, `10'd640`) |
| Reset | Synchronous, inside `always @(posedge clk)` block |
| Active-low signals | Use `_n` suffix (e.g., `ov7670_reset_n`) |
| AXI handshakes | Use `valid & ready` pattern for transfers |
| Alignment | Align colons and `<=` operators vertically |
| Port alignment | Align port widths and names in the module header |
| Clock domain crossing | ใช้ double-flop synchronizer สำหรับ signal ข้าม domain |
| Tri-state | แยก `_oe`, `_out`, `_in` signals สำหรับ inout ports |

---

## 9. Quick Reference — Naming Patterns

```
Module:         snake_case                   → sccb_master, vga_controller
OV7670 Camera:  ov7670_<signal>              → ov7670_pclk, ov7670_data
SCCB Bus:       sccb_<signal>                → sccb_sio_c, sccb_sio_d
VGA Output:     vga_<signal>                 → vga_red, vga_hsync
Frame Buffer:   fb_<signal>                  → fb_addr_wr, fb_data_in
AXI Stream:     {s|m}_axis_t{data|valid|ready}
AXI Lite:       {s|m}_axi_{ar|aw|r|w|b}{signal}
Registers:      <port_name>_reg
States:         UPPER_CASE                   → SCCB_IDLE, CAP_WAIT_VSYNC
Constants:      UPPER_CASE                   → H_DISPLAY, OV7670_ADDR_W
Clock:          clk, clk_<freq>              → clk, clk_25
Reset:          rst (active-high), rst_n (active-low)
Active-low:     <name>_n                     → ov7670_reset_n
Tri-state:      <name>_oe / _out / _in       → sccb_sio_d_oe
Debug:          <name>_out                   → state_out
```
