# DMA Engine UVM Verification Environment 

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [File Structure](#2-file-structure)
3. [DMA Engine (RTL) — Deep Dive](#3-dma-engine-rtl--deep-dive)
   - 3.1 [Parameters & Port List](#31-parameters--port-list)
   - 3.2 [APB Slave — CSR Register Map](#32-apb-slave--csr-register-map)
   - 3.3 [FSM States & Full Transfer Flow](#33-fsm-states--full-transfer-flow)
   - 3.4 [Scatter-Gather (SG) Chaining](#34-scatter-gather-sg-chaining)
   - 3.5 [Round-Robin Channel Arbitration](#35-round-robin-channel-arbitration)
   - 3.6 [Burst Buffer](#36-burst-buffer)
   - 3.7 [Interrupts & Channel Status](#37-interrupts--channel-status)
   - 3.8 [Known Bug Fixes Embedded in RTL](#38-known-bug-fixes-embedded-in-rtl)
4. [UVM Testbench Architecture](#4-uvm-testbench-architecture)
   - 4.1 [Hierarchy Diagram](#41-hierarchy-diagram)
   - 4.2 [Interfaces (dma_interfaces.sv)](#42-interfaces-dma_interfacessv)
5. [Sequence Item (dma_seq_item.sv)](#5-sequence-item-dma_seq_itemsv)
6. [APB Agent (dma_apb_agent.sv)](#6-apb-agent-dma_apb_agentsv)
   - 6.1 [APB Driver — Register Programming & Descriptor Pre-loading](#61-apb-driver--register-programming--descriptor-pre-loading)
   - 6.2 [APB Monitor — Shadow CSR & Transfer Emission](#62-apb-monitor--shadow-csr--transfer-emission)
   - 6.3 [APB Sequencer & Agent](#63-apb-sequencer--agent)
7. [AXI Memory Agent (dma_axi_mem_agent.sv)](#7-axi-memory-agent-dma_axi_mem_agentsv)
   - 7.1 [AXI Slave Driver — Shared Static Memory](#71-axi-slave-driver--shared-static-memory)
   - 7.2 [AXI Bus Monitor](#72-axi-bus-monitor)
   - 7.3 [AXI Memory Sequence Item](#73-axi-memory-sequence-item)
8. [Sequences (dma_sequences.sv)](#8-sequences-dma_sequencessv)
   - 8.1 [Base Sequence & fill_basic_item()](#81-base-sequence--fill_basic_item)
   - 8.2 [Directed Sequences](#82-directed-sequences)
   - 8.3 [Scatter-Gather, Misalign & Error Injection Sequences](#83-scatter-gather-misalign--error-injection-sequences)
   - 8.4 [Adaptive Virtual Sequence](#84-adaptive-virtual-sequence)
9. [Virtual Sequencer (dma_virtual_sequencer.sv)](#9-virtual-sequencer-dma_virtual_sequencersv)
10. [Scoreboard (dma_scoreboard.sv)](#10-scoreboard-dma_scoreboardsv)
11. [Coverage (dma_coverage.sv)](#11-coverage-dma_coveragesv)
12. [Environment (dma_env.sv)](#12-environment-dma_envsv)
13. [Tests (dma_test.sv)](#13-tests-dma_testsv)
14. [Testbench Top (tb_top.sv)](#14-testbench-top-tb_topsv)
15. [Data Flow: End-to-End Transaction Trace](#15-data-flow-end-to-end-transaction-trace)
16. [Memory Map Summary](#16-memory-map-summary)
17. [Running the Simulation](#17-running-the-simulation)
18. [Bug Fix Log](#18-bug-fix-log)

---

## 1. Project Overview

This project implements a **4-channel, scatter-gather capable DMA engine** in synthesizable SystemVerilog, paired with a full **UVM (Universal Verification Methodology) testbench** that stress-tests the DUT using randomized, directed, and error-injected stimulus.

### What the DMA does

- Accepts **descriptor-based transfer commands** via an APB slave (control/status registers).
- Executes **memory-to-memory copies** over an AXI4 master port, reading data from a source address and writing it to a destination address.
- Supports **scatter-gather (SG) chains** a linked list of descriptors so one "start" command can transfer to/from discontiguous memory regions.
- Issues a **completion interrupt** when a transfer or chain finishes.
- Arbitrates among **4 independent channels** using round-robin scheduling.

### What the UVM testbench does

- Instantiates the DUT and connects it to interface wrappers for APB, AXI, and interrupt signals.
- Drives realistic APB register writes to program descriptor memory and start transfers.
- Acts as an **AXI slave** serving read/write transactions from the DUT using a shared software-model memory.
- **Checks correctness** by comparing actual destination bytes (read back via backdoor from the software memory) with the expected bytes that were in source memory.
- Measures **functional coverage** over channels, SG depth, alignment, and error injection.

---

## 2. File Structure

```
dma_engine.sv           — DUT: the synthesizable DMA RTL
dma_interfaces.sv       — SV interfaces: APB, AXI, IRQ (with clocking blocks)
dma_uvm_pkg.sv          — Package that includes all UVM files in order
dma_seq_item.sv         — UVM sequence item (the transaction descriptor)
dma_sequences.sv        — All UVM sequences (directed, SG, misalign, error, adaptive)
dma_apb_agent.sv        — APB driver, monitor, sequencer, agent
dma_axi_mem_agent.sv    — AXI slave driver, AXI bus monitor, agent
dma_virtual_sequencer.sv— Virtual sequencer (coordinates APB and AXI sub-sequencers)
dma_scoreboard.sv       — Self-checking scoreboard (data integrity checker)
dma_coverage.sv         — Functional coverage collector
dma_env.sv              — UVM environment (wires everything together)
dma_test.sv             — All test classes
tb_top.sv               — Top-level testbench module (clock, reset, DUT, UVM kickoff)
```

---

## 3. DMA Engine (RTL) — Deep Dive

### 3.1 Parameters & Port List

```
Parameter     Default  Meaning
DATA_WIDTH     64      AXI data bus width in bits (8 bytes per beat)
ADDR_WIDTH     32      AXI/APB address width
ID_WIDTH        4      AXI ID field width
NUM_CHANNELS    4      Number of independent DMA channels
```

**APB Slave Ports** (input/output to a CPU-side bus):

| Signal   | Dir | Width | Purpose |
|----------|-----|-------|---------|
| paddr    | in  | 12    | Register address |
| psel     | in  | 1     | Select (start of transaction) |
| penable  | in  | 1     | Enable (second phase of APB) |
| pwrite   | in  | 1     | 1=write, 0=read |
| pwdata   | in  | 32    | Write data |
| prdata   | out | 32    | Read data |
| pready   | out | 1     | Always tied high (zero wait) |
| pslverr  | out | 1     | Always tied low (no error) |

**AXI4 Master Ports**: Full AXI4 master with separate AR/R (read) and AW/W/B (write) channels, plus burst length, size, and burst-type signals. The DUT always uses INCR bursts (`awburst/arburst = 2'b01`) and 8-byte transfers (`awsize/arsize = 3'b011`).

**Interrupt/Status Ports**:

| Signal    | Dir | Width | Purpose |
|-----------|-----|-------|---------|
| irq       | out | 4     | Per-channel completion interrupt |
| ch_active | out | 4     | Combinatorial: channel is currently being serviced |
| dma_busy  | out | 1     | Any channel is running |

---

### 3.2 APB Slave — CSR Register Map

The DMA exposes a flat 12-bit address space. The base address is `0x000`. Each of the 4 channels occupies a `0x100`-byte slot starting at `0x100`.

**Global Register:**

| Address  | Bits | Field     | Description |
|----------|------|-----------|-------------|
| `0x000`  | [0]  | global_en | Master enable. No channel can run unless this is 1. |

**Per-Channel Registers** (channel `i` at base `0x100 + i * 0x100`):

| Offset | Bits   | Field       | Description |
|--------|--------|-------------|-------------|
| `0x00` | [0]    | ch_en       | Channel enable |
| `0x00` | [1]    | ch_start    | Write 1 to start; auto-cleared by HW when `ch_done` fires |
| `0x00` | [3]    | ch_irq_en   | Enable IRQ on completion |
| `0x00` | [4]    | ch_done (r) | Read-back: 1 when transfer finished |
| `0x00` | [31]   | ch_error(r) | Read-back: 1 if an AXI error was seen |
| `0x04` | [31:0] | ch_desc_addr| Physical address of first descriptor in memory |
| `0x10` | [7:0]  | ch_burst_len| AXI burst length (number of 8-byte beats) |

**Read path**: Combinatorial decode: whenever `psel=1` and `pwrite=0`, `prdata` is driven from the matching shadow register.

**Write path**: Registered: on `psel && penable && pwrite`, the corresponding register is updated on the rising clock edge.

**Auto-clear**: When `ch_done[i]` asserts (FSM reaches `ST_DONE`), `ch_start[i]` is automatically cleared in the same clock cycle's always_ff block. This prevents re-triggering on the same start command.

---

### 3.3 FSM States & Full Transfer Flow

The DMA uses a single 10-state FSM that processes one channel at a time in a pipeline:

```
ST_IDLE → ST_AR_DESC → ST_R_DESC → ST_AR_DATA → ST_R_DATA
                                        ↑              ↓
                                  ST_NEXT_DESC ← ST_B_DATA ← ST_W_DATA ← ST_AW_DATA
                                        ↓
                                    ST_DONE → ST_IDLE
```

**ST_IDLE**
- Asserts `dma_busy = 0`.
- Polls the round-robin arbiter every clock. When any channel has `ch_start=1` and `global_en=1`, latch `curr_ch`, assert `dma_busy = 1`, go to `ST_AR_DESC`.

**ST_AR_DESC** — *Issue AXI Read for Descriptor*
- Drives `arvalid=1`, `araddr = ch_desc_addr[curr_ch]`, `arlen = 8'h01` (2-beat burst), `arid = {2'b00, curr_ch}`.
- The 2-beat burst fetches a 16-byte region: beat 0 = src+dst addresses, beat 1 = length+flags+next pointer.
- Stays in this state holding `arvalid` high until both `arvalid` and `arready` are seen simultaneously (AXI handshake). This ensures the slave has registered the address. Transitions to `ST_R_DESC`, asserts `rready=1`.

**ST_R_DESC** — *Receive Descriptor Beats*
- Beat 0: `rdata[31:0]` → `desc_src`; `rdata[63:32]` → `desc_dst`.
- Beat 1 (rlast): `rdata[15:0]` → `desc_len`; `rdata[23:16]` → `desc_flags`; `rdata[63:32]` → `desc_next`.
- On `rlast`, also latches `curr_src ← desc_src`, `curr_dst ← desc_dst`, `bytes_left ← desc_len`.
- Clears `rready`, transitions to `ST_AR_DATA`.

**ST_AR_DATA** — *Issue AXI Read for Source Data*
- If `bytes_left == 0`: skip directly to `ST_NEXT_DESC` (zero-length SG node).
- Otherwise: compute burst beat count:
  - If remaining bytes > `burst_len * 8`: full burst → `arlen = burst_len - 1`.
  - Else: partial burst → `arlen = (bytes_left - 1) / 8`, beat count = `(bytes_left - 1) / 8 + 1`.
- Sets `arid = {2'b01, curr_ch}` to distinguish data reads from descriptor reads.
- Same valid/ready handshake pattern as `ST_AR_DESC`.

**ST_R_DATA** — *Receive Source Data Beats*
- Stores each `rdata` beat into `burst_buf[]` and `burst_strb[]` (always `0xFF` = all bytes valid).
- Checks `rresp`: if not `2'b00`, sets `ch_error[curr_ch]`.
- On `rlast`, clears `rready`, transitions to `ST_AW_DATA`.

**ST_AW_DATA** — *Issue AXI Write Address*
- Drives `awvalid=1`, `awaddr = curr_dst`, `awlen = burst_count - 1`, `awid = {2'b10, curr_ch}`.
- On `awvalid && awready`: preloads `wdata/wstrb/wlast` from `burst_buf[0]`, asserts `wvalid=1`, transitions to `ST_W_DATA`.

**ST_W_DATA** — *Stream Write Data Beats*
- On each `wvalid && wready` handshake: advances `buf_rd_idx`, loads next beat from `burst_buf`.
- Sets `wlast` when the last beat (`buf_rd_idx == burst_count - 1`) is reached.
- After last beat: de-asserts `wvalid`, asserts `bready`, transitions to `ST_B_DATA`.

**ST_B_DATA** — *Wait for Write Response*
- On `bvalid && bready`: checks `bresp` for errors.
- Updates: `curr_src += burst_count * 8`, `curr_dst += burst_count * 8`.
- If `bytes_left <= burst_count * 8`: transfer segment complete → `bytes_left = 0` → go to `ST_NEXT_DESC`.
- Else: `bytes_left -= burst_count * 8` → go back to `ST_AR_DATA` for the next burst.

**ST_NEXT_DESC** — *Scatter-Gather Chain Walk*
- If `desc_flags[0] == 1`: linked list continues → `ch_desc_addr[curr_ch] = desc_next` → loop back to `ST_AR_DESC` to fetch the next descriptor.
- Else: all descriptors done → go to `ST_DONE`.

**ST_DONE** — *Signal Completion*
- Asserts `ch_done[curr_ch] = 1`.
- If `desc_flags[1] == 1` OR `ch_irq_en[curr_ch] == 1`: asserts `irq[curr_ch] = 1`.
- Returns to `ST_IDLE`.

---

### 3.4 Scatter-Gather (SG) Chaining

A descriptor is a 16-byte structure in memory:

```
Byte offset  Content
[0  .. 3]    src_addr  (32-bit, little-endian)
[4  .. 7]    dst_addr  (32-bit, little-endian)
[8  .. 9]    xfer_len  (16-bit, number of bytes to copy)
[10]         flags     [0]=sg_valid (1=chain continues) [1]=irq [2]=src_fixed [3]=dst_fixed
[11]         reserved
[12 .. 15]   next_ptr  (32-bit address of next descriptor, used if flags[0]=1)
```

When `flags[0] = 1`, the FSM enters `ST_NEXT_DESC`, updates `ch_desc_addr` to `desc_next`, and re-enters `ST_AR_DESC`. This allows chains of arbitrary length (bounded only by descriptor memory). The last descriptor in a chain has `flags[0] = 0`.

---

### 3.5 Round-Robin Channel Arbitration

```systemverilog
for (int i = 1; i <= NUM_CHANNELS; i++) begin
    if (ch_start[(curr_ch + i) % NUM_CHANNELS]) begin
        start_any = 1;
        next_ch   = (curr_ch + i) % NUM_CHANNELS;
        break;
    end
end
```

Starting from the channel *after* the last-served channel, it scans in order and picks the first pending channel. This is purely combinatorial (evaluated every clock in `ST_IDLE`) so a new channel starts immediately in the next cycle after one completes.

---

### 3.6 Burst Buffer

```
logic [63:0] burst_buf  [16];   // up to 16 beats of 64-bit data
logic [7:0]  burst_strb [16];   // byte enables per beat
logic [4:0]  burst_count;       // actual beats in this burst
logic [4:0]  buf_wr_idx;        // write pointer (incremented during ST_R_DATA)
logic [4:0]  buf_rd_idx;        // read pointer (incremented during ST_W_DATA)
```

The buffer acts as a **ping-pong scratch pad**: ST_R_DATA fills it beat by beat, then ST_AW_DATA/ST_W_DATA drain it. Since the FSM is sequential (read then write), there is no simultaneous read/write so a single buffer is sufficient.

Maximum buffer size = 16 beats × 8 bytes = **128 bytes per burst**. This caps burst transfers to 128 bytes before looping back to ST_AR_DATA.

---

### 3.7 Interrupts & Channel Status

- `irq[i]` is asserted in `ST_DONE` and auto-cleared when `ch_start[i]` is written again (new transfer).
- `ch_active[i]` is a combinatorial signal: `(curr_ch == i) && (state != ST_IDLE)`. All four channels have their active bit decoded simultaneously.
- `dma_busy` is a registered output: set to 1 entering `ST_AR_DESC`, cleared to 0 in `ST_IDLE`.

---

### 3.8 Known Bug Fixes Embedded in RTL

The RTL comments document several important historical bugs:

| Bug | Location | Problem | Fix |
|-----|----------|---------|-----|
| Bug #4 | ST_AR_DESC/ST_AR_DATA | arvalid was de-asserted one cycle before arready arrived, causing the handshake to be missed. | arvalid is now held high every cycle in the state; exit is gated on both arvalid AND arready being 1. |
| Bug #5 | ST_R_DESC | `curr_src`/`curr_dst` were loaded from `rdata` of the *last* beat, which contains `len/flags/next_ptr`, not addresses. | Now latched in beat 0 into `desc_src`/`desc_dst` first, then assigned to `curr_src`/`curr_dst` on rlast. |
| Bug (C) | ST_AR_DATA | When `bytes_left == 0` on entry (zero-length descriptor), the old code re-initialized from `desc_len` which was also 0, creating an infinite loop. | Now exits directly to `ST_NEXT_DESC` on `bytes_left == 0`. |

---

## 4. UVM Testbench Architecture

### 4.1 Hierarchy Diagram

```
tb_top (module)
│
├── dma_engine (DUT)
├── dma_axi_if (interface)
├── dma_apb_if (interface)
├── dma_irq_if (interface)
│
└── UVM Root
    └── dma_adaptive_stress_test (uvm_test)
        └── dma_env (uvm_env)
            ├── dma_apb_agent (uvm_agent)  [UVM_ACTIVE]
            │   ├── dma_apb_driver         drives psel/penable/pwrite/pwdata
            │   ├── dma_apb_monitor        observes completed APB writes
            │   └── dma_apb_sequencer      delivers sequence items to driver
            │
            ├── dma_axi_mem_agent (uvm_agent)  [UVM_ACTIVE]
            │   ├── dma_axi_mem_driver     acts as AXI slave (arready, rvalid, etc.)
            │   ├── dma_axi_mem_monitor    observes AXI bus transactions
            │   └── dma_axi_mem_sequencer
            │
            ├── dma_scoreboard (uvm_scoreboard)
            │   ├── apb_imp  ← from apb_agent.ap
            │   └── axi_imp  ← from mem_agent.ap
            │
            ├── dma_coverage (uvm_subscriber)
            │   └── analysis_export ← from apb_agent.ap
            │
            └── dma_virtual_sequencer (uvm_sequencer)
                ├── apb_seqr  → apb_agent.sequencer
                ├── axi_seqr  → mem_agent.sequencer
                └── irq_vif   → dma_irq_if (for DMA busy polling)
```

**Analysis port connections:**
```
apb_agent.ap  ──┬──→ scoreboard.apb_imp
                └──→ coverage.analysis_export

mem_agent.ap  ──────→ scoreboard.axi_imp
```

---

### 4.2 Interfaces (dma_interfaces.sv)

Three interfaces are declared, each with clocking blocks:

**dma_apb_if** — bidirectional APB bus
- `master_mp` modport: drives paddr/pwdata/psel/penable/pwrite, samples prdata/pready.
- `monitor_mp` modport: samples all signals read-only.
- Clocking block `master_cb` and `monitor_cb` with 1-step input sample / 1ns output skew.

**dma_axi_if** — full AXI4 bus
- `slave_mp` modport: drives arready/rvalid/rdata/rlast/rresp/rid, awready/wready/bvalid/bresp/bid; samples arvalid/awvalid/wvalid/bready.
- `monitor_mp` modport: samples all signals.
- Clocking block `slave_cb` and `monitor_cb`.

**dma_irq_if** — interrupt/status observer
- `monitor_mp` modport: samples irq[3:0], ch_active[3:0], dma_busy.
- Clocking block `monitor_cb`.

---

## 5. Sequence Item (dma_seq_item.sv)

`dma_seq_item` extends `uvm_sequence_item`. It is the **transaction descriptor**: one object encodes everything needed to program one DMA transfer (or SG chain).

### Fields

| Field            | Type          | Description |
|------------------|---------------|-------------|
| src_addr         | rand [31:0]   | Source memory base address |
| dst_addr         | rand [31:0]   | Destination memory base address |
| xfer_len         | rand [15:0]   | Transfer length in bytes per descriptor |
| flags            | rand [3:0]    | [0]=sg_valid [1]=irq [2]=src_fixed [3]=dst_fixed |
| next_desc_ptr    | rand [31:0]   | Pointer to next descriptor (SG chains) |
| channel          | rand int      | Which of the 4 channels (0..3) |
| burst_len        | rand [7:0]    | AXI burst beats (1..16) |
| sg_depth         | rand int      | Number of descriptors in the SG chain |
| inject_read_err  | rand bit      | Ask AXI slave to inject SLVERR on reads |
| inject_write_err | rand bit      | Ask AXI slave to inject SLVERR on writes |
| inject_desc_err  | rand bit      | Corrupt the descriptor fetch response |
| src_align_mod    | rand [1:0]    | Byte offset to misalign source address |
| dst_align_mod    | rand [1:0]    | Byte offset to misalign destination address |
| exp_data[]       | logic [7:0][] | Expected bytes (filled by scoreboard, not constrained) |

### Key Constraints

- `c_channel`: channel ∈ {0,1,2,3}
- `c_xfer_len`: 1..4096 bytes, never zero
- `c_addr_range`: src in `[0x0000_1000 .. 0x0FFF_FFFF]`, dst in `[0x1000_0000 .. 0x1FFF_FFFF]` — these two regions never overlap by design
- `c_no_overlap`: extra guard ensuring `dst > src + xfer_len + 0xFF` or vice versa
- `c_sg_flag`: `flags[0]` is automatically 1 when `sg_depth > 1`, 0 when `sg_depth == 1`
- `c_irq_en`: `flags[1]` is always 1 (request completion IRQ for monitoring)
- `c_no_err_default`: soft constraints set error injection to 0 by default; specific sequences override this
- `c_align_default`: soft constraints set misalignment to 0 by default

### Methods

- `do_copy()`: deep copies all fields for cloning
- `do_compare()`: compares key identification fields (channel, src, dst, len, flags)
- `convert2string()`: returns a formatted one-line description for log messages

---

## 6. APB Agent (dma_apb_agent.sv)

### 6.1 APB Driver — Register Programming & Descriptor Pre-loading

The APB driver is the most complex component. It does two things for every sequence item:

**Step 1: Descriptor Pre-loading**

Before touching the DUT at all, the driver writes the descriptor(s) directly into `dma_axi_mem_driver::mem[]` — the **static shared memory** that the AXI slave will serve back when the DUT fetches descriptors.

The memory layout written:
```
Base address = 0xC000_0000 + channel * 0x1000
For each descriptor d in sg_depth:
  addr = base + d * 0x20
  mem[addr+0 .. addr+3]  = src_addr  + d * xfer_len   (little-endian)
  mem[addr+4 .. addr+7]  = dst_addr  + d * xfer_len   (little-endian)
  mem[addr+8 .. addr+9]  = xfer_len                   (little-endian)
  mem[addr+10]           = flags (with sg_valid cleared on last descriptor)
  mem[addr+11]           = 0 (reserved)
  mem[addr+12..addr+15]  = next_ptr (base + (d+1)*0x20, or 0 for last)
  mem[addr+16..addr+31]  = 0 (padding)
```

Each SG descriptor advances src/dst by one `xfer_len` increment so the chain copies a contiguous source region to a contiguous destination region in segments.

**Step 2: DUT CSR Programming via APB**

The driver programs 4 registers in this order:

```
apb_write(0x100 + ch*0x100 + 0x04,  desc_addr)     // descriptor pointer
apb_write(0x100 + ch*0x100 + 0x10,  burst_len)     // burst length
apb_write(0x100 + ch*0x100 + 0x00,  0x0B)          // ch_en=1, ch_start=1, ch_irq_en=1
apb_write(0x000,                     0x01)          // global enable
```

**APB write protocol** (`apb_write` task):
1. Clock edge: drive `paddr`, `pwdata`, `psel=1`, `pwrite=1` (SETUP phase).
2. Next clock edge: add `penable=1` (ACCESS phase).
3. Poll `pready` (through `master_cb` clocking block) up to 256 cycles.
4. De-assert `psel` and `penable`.

This strictly follows the 2-phase APB protocol. Using the clocking block (`master_cb`) for all signal access is required by the modport restrictions — accessing raw signals via a modport handle is rejected by some simulators.

---

### 6.2 APB Monitor — Shadow CSR & Transfer Emission

The APB monitor does **not** drive signals. Instead it watches every completed APB transaction (when `psel && penable && pready && pwrite` are all 1) and maintains a **shadow copy** of the DUT's CSR state:

```
shadow_global_en        — mirrors global_en
shadow_desc_addr[0..3]  — mirrors ch_desc_addr per channel
shadow_burst_len[0..3]  — mirrors ch_burst_len per channel
shadow_ch_en[0..3]      — mirrors ch_en
shadow_ch_start[0..3]   — mirrors ch_start
```

When the monitor observes a channel start (writes to `ch_base + 0x00` with bit 1 set, while `global_en` is already 1), it calls `emit_transfer(ch)`. This function:

1. Reads the descriptor from shared memory (`dma_axi_mem_driver::mem[]`) using `read_shared_word` and `read_shared_halfword` helpers.
2. Reconstructs all descriptor fields: `src_addr`, `dst_addr`, `xfer_len`, `flags`, `next_desc_ptr`.
3. Walks the SG chain by following `flags[0]` and `next_ptr`, counting `sg_depth`.
4. Creates a `dma_seq_item` with all reconstructed fields.
5. Writes it to the analysis port `ap`, which connects to the scoreboard.

This means the scoreboard receives a fully populated transaction at the moment the DMA is *started*, before any AXI activity occurs. The scoreboard then knows exactly what bytes to expect at the destination.

---

### 6.3 APB Sequencer & Agent

`dma_apb_sequencer` is a bare `uvm_sequencer #(dma_seq_item)` — no custom logic needed.

`dma_apb_agent`:
- In `build_phase`: creates monitor always; creates driver + sequencer only if `UVM_ACTIVE`.
- In `connect_phase`: connects `driver.seq_item_port` → `sequencer.seq_item_export`; connects `monitor.ap` → agent's own `ap` (bubbles up for the environment to connect).

---

## 7. AXI Memory Agent (dma_axi_mem_agent.sv)

### 7.1 AXI Slave Driver — Shared Static Memory

`dma_axi_mem_driver` serves as the **memory subsystem** for the entire testbench. It owns a single static (class-level) associative array:

```systemverilog
static logic [7:0] mem [logic[31:0]];
```

Being `static`, this array is shared across all instances of the class and is accessible directly by name from other classes (`dma_axi_mem_driver::mem[addr]`), which is how the APB driver pre-loads descriptors without needing an interface.

**init_memory()**: Called once at simulation start.
- Fills `0x0000_1000 .. 0x0000_4FFF` with `i[7:0]` (byte = address[7:0]) — this is the pre-initialized *source data* the DUT will read.
- Zeroes `0xC000_0000 .. 0xC000_0FFF` — the descriptor region.

**handle_reads()** (runs as a fork): Implements an AXI read slave:
1. Assert `arready`.
2. Poll until `arvalid` is seen (explicit poll loop, not a clocking-block iff guard).
3. Sample `araddr`, `arlen`, `arsize`, `arid`.
4. For each beat 0..arlen: optionally insert backpressure delay, drive `rvalid=1`, `rdata = read_mem(addr + beat*8)`, `rresp = 2'b00` (or `2'b10` for injected errors), `rlast` on last beat. Wait for `rready`.

**handle_writes()** (runs as a fork): Implements an AXI write slave:
1. Assert `awready`, poll until `awvalid`.
2. For each beat: assert `wready`, poll until `wvalid`, call `write_mem()` (respects wstrb byte enables).
3. Drive `bvalid=1`, `bresp=2'b00` (or `2'b10` for injected errors), poll until `bready`.

**read_mem / write_mem helpers**: Read returns `0xAD` for uninitialized addresses (sentinel for debugging). Write only commits bytes where the corresponding `wstrb` bit is 1.

**backdoor_read()**: Used by the scoreboard to read destination bytes without going through the AXI bus. Returns `0xAD` for uninitialized (same sentinel as AXI reads, so expected and actual are consistent).

---

### 7.2 AXI Bus Monitor

`dma_axi_mem_monitor` passively observes all AXI transactions. Unlike the driver, it uses `iff` guards in clocking block waits (safe for a purely passive observer since it cannot deadlock).

**monitor_reads()**: Captures AR handshake (`arvalid && arready`), then collects all R beats until `rlast`. Detects descriptor fetches by checking `arid[3:2] == 2'b00` (descriptor reads use `arid = {2'b00, ch}`). Publishes a `dma_mem_seq_item` to `ap`.

**monitor_writes()**: Captures AW handshake, collects all W beats, captures B response. Publishes a `dma_mem_seq_item` to `ap`.

The monitor's `ap` is connected in the environment to `scoreboard.axi_imp`.

---

### 7.3 AXI Memory Sequence Item

`dma_mem_seq_item` is the transaction type used by the AXI monitor:

| Field        | Type     | Description |
|--------------|----------|-------------|
| txn_type     | enum     | READ or WRITE |
| addr         | [31:0]   | Base address of the transaction |
| len          | [7:0]    | AXI burst length (0=1 beat) |
| size         | [2:0]    | AXI burst size (3 = 8 bytes) |
| data[]       | [63:0][] | Dynamic array of beat data |
| resp[]       | [1:0][]  | Response codes per beat (reads) or one B response (writes) |
| is_desc_fetch| bit      | True if arid[3:2] == 2'b00 |
| channel_id   | int      | AXI ID lower 2 bits |

---

## 8. Sequences (dma_sequences.sv)

### 8.1 Base Sequence & fill_basic_item()

`dma_base_seq` provides `fill_basic_item()` — a shared helper function that programmatically (not via randomize()) builds a `dma_seq_item` with controlled values:

- **len_bytes**: random multiple of 8 between 8 and 512 bytes.
- **burst_cfg**: random 1..8.
- **Source address guard**: calculates max safe `src_slot` so the entire SG chain (sg_depth × len_bytes) fits within the initialized source window `0x1000..0x4FFF`. Without this, transfers near the top of the window would read `0xAD` (uninitialized) while the scoreboard expected the `i[7:0]` pattern → false failures.
- Assigns `src_addr = 0x1000 + src_slot * 0x100 + src_mod` and `dst_addr = 0x1000_0000 + dst_slot * 0x1000 + dst_mod`.
- Sets `flags = 0b0010` (irq enabled), sets `flags[0] = 1` if `sg_depth > 1`.

---

### 8.2 Directed Sequences

All directed sequences inherit from `dma_directed_base_seq` which calls `fill_basic_item()` then overrides `xfer_len` and `burst_len` with fixed values.

| Sequence Class                    | sg_depth | xfer_len | burst_len | Notes |
|-----------------------------------|----------|----------|-----------|-------|
| dma_directed_single_desc_seq      | 1        | 64 bytes | 1         | Single burst, single descriptor |
| dma_directed_multi_burst_seq      | 1        | 256 bytes| 4         | Multiple bursts, single descriptor |
| dma_directed_sg16_seq             | 16       | 128 bytes| 4         | Full SG chain |
| dma_directed_misalign_seq         | 1        | 128 bytes| 4         | Forces src/dst misalignment |
| dma_directed_repro_fail_seq       | 16       | 320 bytes| 6         | Exact reproduction of a stress test failure (ch=0, src=0x3F00, dst=0x100A3000) |

---

### 8.3 Scatter-Gather, Misalign & Error Injection Sequences

- **dma_sg_chain_seq**: Calls `fill_basic_item(req, sg_len, 0, 0, 0)`. The `sg_len` field is set by the caller (virtual sequence or test) before calling `start()`.
- **dma_misalign_seq**: Calls `fill_basic_item(req, 1, force_misalign=1, ...)`. This causes `src_mod` and `dst_mod` to be 1..3, misaligning addresses.
- **dma_error_inj_seq**: Calls `fill_basic_item(req, 1, 0, rand_read_err, rand_write_err)`. Randomly enables read or write error injection.

---

### 8.4 Adaptive Virtual Sequence

`dma_adaptive_virtual_seq` is the main stress sequence. It runs `num_txns` iterations (default 25, configurable via `+DMA_NUM_TXNS=N` plusarg).

**Weighted random selection each iteration:**

```systemverilog
seq_type dist {
    0 := weight_sg_len_1,   // single-descriptor transfer
    1 := weight_sg_len_16,  // 16-descriptor SG chain
    2 := weight_misalign,   // misaligned addresses
    3 := weight_err         // error injection
};
```

Weights are taken live from `p_sequencer` (the virtual sequencer), which increases corner-case weights over simulation time for coverage closure.

**After each transaction**: calls `wait_for_dma_completion()`:
- Polls `p_sequencer.irq_vif.monitor_cb.dma_busy` every clock.
- Waits until it sees `dma_busy` go 1 then 0 (full busy→idle cycle).
- If `dma_busy` never rises within `dma_start_grace_cycles` (32): treats as no-op and continues (prevents hanging on zero-length transfers).
- If it never falls after `dma_complete_timeout_cycles` (20000): reports `uvm_error`.

This polling-based synchronization ensures each transaction completes before the next is issued.

---

## 9. Virtual Sequencer (dma_virtual_sequencer.sv)

`dma_virtual_sequencer` extends `uvm_sequencer` (not parameterized — it does not produce items itself). It holds:

| Field         | Type                   | Purpose |
|---------------|------------------------|---------|
| apb_seqr      | dma_apb_sequencer*     | Handle to real APB sequencer (set in env connect_phase) |
| axi_seqr      | dma_axi_mem_sequencer* | Handle to real AXI sequencer |
| irq_vif       | virtual dma_irq_if     | Used by adaptive virtual seq to poll dma_busy |
| weight_sg_len_1  | int (10)            | Initial weight for sg=1 transactions |
| weight_sg_len_16 | int (10)            | Initial weight for sg=16 |
| weight_misalign  | int (10)            | Initial weight for misaligned |
| weight_no_err    | int (20)            | Unused by dist directly but present for completeness |
| weight_err       | int (5)             | Initial weight for error injection |

**run_phase**: Every 10µs calls `update_weights()`:
```
weight_sg_len_16 += 5
weight_misalign  += 5
weight_err       += 2
```

This means as simulation progresses, SG-chain, misalignment, and error cases appear more frequently — a classic **adaptive coverage closure** technique.

---

## 10. Scoreboard (dma_scoreboard.sv)

The scoreboard receives items from two analysis ports and cross-checks them:

### write_apb() — on transfer launch

Called by the APB monitor when a DMA is started. Creates a `transfer_t` struct and pushes it to `pending_q`:

- Computes `exp_data[]`: a byte array of `xfer_len * sg_depth` entries, filled by calling `mem_driver.backdoor_read(src_addr + d*xfer_len + b)` for each descriptor `d` and byte `b`. This captures the exact source bytes at launch time.
- Computes `expected_write_rsp`: total number of AXI write bursts expected = `sg_depth * ceil(xfer_len / burst_bytes)`. Used to know when all writes for a transfer are done.

### write_axi() — on each AXI write burst

Called by the AXI monitor for every write transaction. Finds the matching pending transfer by checking if the write address falls within any of the transfer's destination segments (`addr_hits_transfer()`). Increments `seen_write_rsp`. When `seen_write_rsp >= expected_write_rsp`, calls `check_transfer()`.

### check_transfer() — byte-level correctness check

For each byte at `dst_addr + d*xfer_len + b` across all SG segments:
- Reads the actual value via `mem_driver.backdoor_read()`.
- Compares with `exp_data[d*xfer_len + b]`.
- Reports `uvm_error` for each mismatch (capped at 8 per transfer to avoid log flooding).
- Reports pass/fail and moves the transfer to `completed_q`.

### check_phase & report_phase

At end-of-simulation:
- `check_phase`: any transfers still in `pending_q` are timed-out → reported as errors.
- `report_phase`: prints a formatted summary:
  ```
  ====== SCOREBOARD SUMMARY ======
    Total transactions : N
    Passed             : N
    Failed             : N
    Timed out          : N
    Total bytes checked: N
  ================================
  ```

---

## 11. Coverage (dma_coverage.sv)

`dma_coverage` extends `uvm_subscriber #(dma_seq_item)` and is connected to the APB agent's analysis port. Every time a DMA is launched, `write()` is called, which samples the covergroup.

**Covergroup cg_dma_trans:**

| Coverpoint     | Bins | What it measures |
|----------------|------|-----------------|
| cp_channel     | ch0..ch3 | All 4 channels exercised |
| cp_sg_depth    | 1,2,4,8,16 | SG chain lengths |
| cp_src_align   | aligned(0), misaligned 1/2/3, other 4-7 | Source address alignment |
| cp_dst_align   | same as above | Destination address alignment |
| cp_rd_err      | no_err, err | Read error injection seen |
| cp_wr_err      | no_err, err | Write error injection seen |
| cross_sg_align | cp_sg_depth × cp_src_align | SG depth combined with alignment |
| cross_err      | cp_rd_err × cp_wr_err | Read+write error combination |

100% coverage of all bins and crosses indicates all corner cases have been exercised.

---

## 12. Environment (dma_env.sv)

`dma_env` is the top-level container. In `build_phase`:

1. Sets both agents to `UVM_ACTIVE` in `uvm_config_db` (critical — without this the drivers are never created and the simulation hangs).
2. Creates all 5 sub-components: `apb_agent`, `mem_agent`, `scoreboard`, `coverage`, `vsqr`.

In `connect_phase`:

```
apb_agent.ap  → scoreboard.apb_imp       (APB monitor → scoreboard)
mem_agent.ap  → scoreboard.axi_imp       (AXI monitor → scoreboard)
scoreboard.mem_driver = mem_agent.driver  (backdoor read access)
apb_agent.ap  → coverage.analysis_export (APB monitor → coverage)
vsqr.apb_seqr = apb_agent.sequencer      (virtual seqr has reference to APB seqr)
vsqr.axi_seqr = mem_agent.sequencer      (virtual seqr has reference to AXI seqr)
```

---

## 13. Tests (dma_test.sv)

### dma_base_test

- Creates `dma_env`.
- Sets UVM simulation timeout to **150ms** (200 transactions × 500µs worst-case per SG-16 transfer + margin).

### dma_adaptive_stress_test

- Creates and starts `dma_adaptive_virtual_seq` on `env.vsqr`.
- Number of transactions controlled by `+DMA_NUM_TXNS=N` plusarg (default 25).
- After vseq completes: waits 10µs for last IRQ/write to settle, then drops objection.

### Directed Tests

All directed tests inherit `dma_directed_base_test`, which:
- Calls `run_one_sequence()` (overridden by each child class).
- Calls `wait_for_dma_idle()`: polls `env.vsqr.irq_vif.monitor_cb.dma_busy` up to 50,000 clock cycles.
- Waits 1µs then drops objection.

| Test Class                      | Sequence Run |
|---------------------------------|--------------|
| dma_directed_single_desc_test   | dma_directed_single_desc_seq |
| dma_directed_multi_burst_test   | dma_directed_multi_burst_seq |
| dma_directed_sg16_test          | dma_directed_sg16_seq |
| dma_directed_misalign_test      | dma_directed_misalign_seq |
| dma_directed_repro_fail_test    | dma_directed_repro_fail_seq |

---

## 14. Testbench Top (tb_top.sv)

- Generates a **100MHz clock** (`#5ns` toggle).
- Asserts reset (`rst_n=0`) for 20ns, then deasserts.
- Instantiates all three interfaces and connects them to the DUT.
- In the initial block: sets all three virtual interfaces into `uvm_config_db` under wildcard path `"*"` so any component can retrieve them.
- Calls `run_test(selected_test)` — `selected_test` is a string variable set to `"dma_adaptive_stress_test"` by default (can be overridden by a plusarg on supported simulators).
- Optionally dumps VCD waveforms when `+DMA_DUMP_VCD` plusarg is present.

---

## 15. Data Flow: End-to-End Transaction Trace

Here is the complete lifecycle of one DMA transaction through the entire system:

```
1. TEST creates dma_adaptive_virtual_seq, starts it on virtual sequencer.

2. VIRTUAL SEQ picks seq_type (e.g., sg_len=1), creates dma_sg_chain_seq,
   starts it on apb_seqr.

3. APB SEQUENCER delivers a dma_seq_item to APB DRIVER.

4. APB DRIVER:
   a. Writes descriptor bytes directly to dma_axi_mem_driver::mem[]
      at address 0xC000_0000 + ch*0x1000.
   b. Programs 4 APB registers: desc_addr, burst_len, control/start, global_en.

5. DUT (dma_engine) sees ch_start=1 and global_en=1 → FSM exits ST_IDLE.

6. DUT ST_AR_DESC: issues AXI read AR to 0xC000_0000 + ch*0x1000.

7. AXI SLAVE DRIVER: accepts AR, serves 2 beats from mem[]:
   beat0 → src_addr, dst_addr
   beat1 → xfer_len, flags, next_ptr

8. DUT ST_R_DESC: latches descriptor fields.

9. DUT ST_AR_DATA: issues AXI read AR to curr_src (e.g., 0x1000).

10. AXI SLAVE DRIVER: serves N beats of source data from mem[0x1000..].

11. DUT ST_R_DATA: fills burst_buf[] with read data.

12. DUT ST_AW_DATA + ST_W_DATA: issues AXI write to curr_dst (e.g., 0x1000_0000),
    drains burst_buf[] as write data beats.

13. AXI SLAVE DRIVER: receives write beats, calls write_mem() → stores in mem[dst..].

14. DUT ST_B_DATA: receives BRESP, advances curr_src/curr_dst, loops back to
    ST_AR_DATA until bytes_left == 0.

15. DUT ST_NEXT_DESC: flags[0]=0 (single descriptor) → go to ST_DONE.

16. DUT ST_DONE: asserts ch_done, irq. Returns to ST_IDLE. dma_busy drops.

17. VIRTUAL SEQ: sees dma_busy fall → transaction complete, loop to next.

18. APB MONITOR (parallel): observed step 4b APB writes → reconstructed item →
    sent to scoreboard via ap.

19. AXI MONITOR (parallel): observed steps 12-13 AXI writes → sent write item
    to scoreboard via ap.

20. SCOREBOARD:
    - write_apb(): snapshot exp_data[] from mem[src..] at launch time.
    - write_axi(): count write bursts, call check_transfer() when all done.
    - check_transfer(): backdoor-read mem[dst..] and compare with exp_data[].
    - PASS or ERROR reported.

21. COVERAGE: write() called by APB analysis port → samples cg_dma_trans.
```

---

## 16. Memory Map Summary

| Address Range            | Owner / Purpose |
|--------------------------|-----------------|
| `0x0000_0000..0x0000_0FFF` | Reserved (null page) |
| `0x0000_1000..0x0000_4FFF` | Source data (initialized by AXI slave driver, i[7:0] pattern) |
| `0x1000_0000..0x1FFF_FFFF` | Destination data (written by DUT, read back by scoreboard) |
| `0xC000_0000..0xC000_0FFF` | Descriptor region (4 channels × 0x1000 bytes each) |

**APB Register Map (DUT internal):**

| Address      | Register |
|--------------|----------|
| `0x000`      | Global enable |
| `0x100`      | Channel 0 control (offset 0x00), desc_addr (0x04), burst_len (0x10) |
| `0x200`      | Channel 1 (same offsets) |
| `0x300`      | Channel 2 |
| `0x400`      | Channel 3 |

---

## 17. Running the Simulation

### Adaptive Stress Test (default)

```bash
# Vivado/XSim
xvlog --sv dma_uvm_pkg.sv tb_top.sv
xelab tb_top -top tb_top -sv_lib uvm
xsim tb_top -R +UVM_TESTNAME=dma_adaptive_stress_test +DMA_NUM_TXNS=100

# VCS
vcs -sverilog -ntb_opts uvm-1.2 dma_uvm_pkg.sv tb_top.sv -o simv
./simv +UVM_TESTNAME=dma_adaptive_stress_test +DMA_NUM_TXNS=100
```

### Directed Tests

Replace `+UVM_TESTNAME=` with any of:
- `dma_directed_single_desc_test`
- `dma_directed_multi_burst_test`
- `dma_directed_sg16_test`
- `dma_directed_misalign_test`
- `dma_directed_repro_fail_test`

### Waveform Dump

Add `+DMA_DUMP_VCD` to generate `dma_dump.vcd`.

### Verbosity

Add `+UVM_VERBOSITY=UVM_HIGH` for full per-cycle driver/monitor/scoreboard logging.

---

## 18. Bug Fix Log

| ID | Location | Root Cause | Fix |
|----|----------|-----------|-----|
| Bug #1 | APB driver | `write_desc_to_mem()` wrote to a local `mem[]` variable not visible to the AXI slave → DUT always fetched all-zero descriptor → `bytes_left=0` → FSM stuck in `ST_AR_DATA` infinite loop. | Changed to write directly into `dma_axi_mem_driver::mem[]` (static shared array). |
| Bug #2 | APB driver & monitor | Accessed `pready`, `psel`, etc. via raw modport handle. xsim rejects raw signal access through a modport (`VRFC 10-3602`). | All signal accesses now go through `master_cb` or `monitor_cb` clocking blocks. |
| Bug #3 | AXI slave driver | Used `@(clocking_block iff signal)` guard syntax. xsim does not reliably evaluate iff guards on combinatorially-driven or pre-asserted signals — can miss the condition and block forever. | Replaced all iff guards with explicit poll-loop tasks (`wait_for_high_ar()`, etc.). |
| Bug #4 | DMA FSM ST_AR_DESC/ST_AR_DATA | arvalid was de-asserted one cycle before arready arrived, causing missed handshake and FSM stuck in ST_AR_DESC forever. | arvalid held high unconditionally every cycle of the state; FSM exits only when arvalid was already 1 the previous cycle AND arready is 1. |
| Bug #5 | DMA FSM ST_R_DESC | `curr_src`/`curr_dst` were incorrectly loaded from the beat-1 `rdata` (which contains len/flags/next_ptr) instead of beat-0. | Latch `desc_src`/`desc_dst` from beat 0; assign to `curr_src`/`curr_dst` on rlast using those latches. |
| Bug #6 | APB driver | Driver held an unused `axi_vif` handle fetched from config_db, creating risk of accidentally driving AXI slave signals. | Removed `axi_vif` from APB driver entirely. |
| Bug #7 | Scoreboard report_phase | Multiple format strings passed to `$sformatf()` as extra positional arguments (only first was used) → garbled/empty summary. | Built summary by string concatenation, single `$sformatf` per line. |
| Bug #8 | Virtual sequencer | Dead `weight_align` field declared but never read; `dma_sequences.sv` referenced `weight_misalign` causing confusion. | Removed `weight_align`; kept only `weight_misalign`. |
| Bug #9 | Adaptive virtual seq | Previous version tried `uvm_config_db::get(null, ...)` to get `irq_vif` from inside a sequence body — always fails silently in xsim (sequences have no component path). Caused a 100µs fallback delay × 200 txns = simulation appeared hung. | Virtual sequence now accesses `irq_vif` via `p_sequencer.irq_vif` (the virtual sequencer holds the handle, fetched correctly in its build_phase). |

---

*End of README*
