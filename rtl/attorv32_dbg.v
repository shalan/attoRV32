/*-----------------------------------------------------------------------------
 * attorv32_dbg.v — Minimal debug SoC: core + RAM + stub ROM + UART.
 *
 * Memory map  (ADDR_WIDTH = RAM_AW + 1):
 *
 *   0x0000 – (2^RAM_AW – 17) : RAM  (read/write)
 *   (2^RAM_AW – 16) – (2^RAM_AW – 1) : I/O  (UART + control)
 *   2^RAM_AW – (2^(RAM_AW+1) – 1) : stub ROM  (combinational, read-only)
 *
 * Example with RAM_AW=12 → ADDR_WIDTH=13 (8 KiB total):
 *   0x0000 – 0x0FEF : 4080 bytes RAM
 *   0x0FF0 – 0x0FFF : I/O (4 × 32-bit registers)
 *   0x1000 – 0x1FFF : 4 KiB stub ROM
 *
 * The MSB of the address selects ROM vs RAM/IO.
 * Within the RAM/IO half, the top 16 bytes are IO.
 *
 * MTVEC_ADDR is set to the ROM base so every trap lands in the
 * ROM-resident ISR + GDB stub — no RAM is needed for trap code.
 *
 * Reset vector is 0x0000 (RAM), containing a c.j to _start.
 *
 * I/O register map (accent on UART for GDB RSP):
 *   +0x0 (IO_BASE+0)  UART_DATA   [7:0]  TX on write, RX on read
 *   +0x4 (IO_BASE+4)  UART_STATUS [0] TX ready  [1] RX valid
 *   +0x8 (IO_BASE+8)  reserved
 *   +0xC (IO_BASE+12) CTRL        [0] write 1 → finish sim (bench only)
 *---------------------------------------------------------------------------*/

module attorv32_dbg #(
   parameter RAM_AW = 12,                    // RAM address bits (4 KiB default)
   parameter RV32E  = 0
)(
   input              clk,
   input              resetn,            // active-low

   // External interrupt (directly to core)
   input              irq,

   // UART physical pins
   input              uart_rx,
   output             uart_tx
);

   /*---------------------------------------------------------------*/
   /* Derived constants                                             */
   /*---------------------------------------------------------------*/
   localparam ADDR_WIDTH = RAM_AW + 1;           // total address space
   localparam ROM_BASE   = (1 << RAM_AW);        // e.g. 0x1000
   localparam IO_BASE    = ROM_BASE - 16;        // e.g. 0x0FF0
   localparam ROM_AW     = RAM_AW;               // ROM same size as RAM half

   /*---------------------------------------------------------------*/
   /* CPU instance                                                  */
   /*---------------------------------------------------------------*/
   wire [31:0] mem_addr;
   wire [31:0] mem_wdata;
   wire [ 3:0] mem_wmask;
   wire [31:0] mem_rdata;
   wire        mem_rstrb;
   wire        mem_rbusy;
   wire        mem_wbusy;

   AttoRV32 #(
      .ADDR_WIDTH (ADDR_WIDTH),
      .RV32E      (RV32E),
      .MTVEC_ADDR (ROM_BASE[ADDR_WIDTH-1:0])    // traps land in ROM
   ) u_core (
      .clk               (clk),
      .reset             (resetn),
      .mem_addr          (mem_addr),
      .mem_wdata         (mem_wdata),
      .mem_wmask         (mem_wmask),
      .mem_rdata         (mem_rdata),
      .mem_rstrb         (mem_rstrb),
      .mem_rbusy         (mem_rbusy),
      .mem_wbusy         (mem_wbusy),
      .interrupt_request (irq),
      .nmi               (1'b0),
      .dbg_halt_req      (uart_break)     // UART break → debug halt
   );

   /*---------------------------------------------------------------*/
   /* Address decode                                                */
   /*---------------------------------------------------------------*/
   wire sel_rom = mem_addr[RAM_AW];                                   // MSB = 1
   wire sel_io  = ~sel_rom & (mem_addr[RAM_AW-1:4] == {(RAM_AW-4){1'b1}}); // top 16 B of RAM half
   wire sel_ram = ~sel_rom & ~sel_io;

   /*---------------------------------------------------------------*/
   /* RAM (behavioural; replace with SRAM macro for silicon)        */
   /*---------------------------------------------------------------*/
   localparam RAM_WORDS = (1 << RAM_AW) / 4;   // e.g. 1024

   reg [31:0] ram [0:RAM_WORDS-1];

   wire [RAM_AW-3:0] ram_waddr = mem_addr[RAM_AW-1:2];

   always @(posedge clk) begin
      if (sel_ram & mem_wmask[0]) ram[ram_waddr][ 7: 0] <= mem_wdata[ 7: 0];
      if (sel_ram & mem_wmask[1]) ram[ram_waddr][15: 8] <= mem_wdata[15: 8];
      if (sel_ram & mem_wmask[2]) ram[ram_waddr][23:16] <= mem_wdata[23:16];
      if (sel_ram & mem_wmask[3]) ram[ram_waddr][31:24] <= mem_wdata[31:24];
   end

   wire [31:0] ram_rdata = ram[mem_addr[RAM_AW-1:2]];

   /*---------------------------------------------------------------*/
   /* Stub ROM (combinational — no clock)                           */
   /*---------------------------------------------------------------*/
   wire [31:0] rom_rdata;

   stub_rom #(
      .AW  (ROM_AW - 2)              // word-address width
   ) u_rom (
      .addr  (mem_addr[ROM_AW-1:2]),
      .rdata (rom_rdata)
   );

   /*---------------------------------------------------------------*/
   /* I/O registers (directly instantiated — no sub-module)         */
   /*                                                               */
   /* Replace the UART stub below with a real UART for silicon.     */
   /* For simulation, a behavioural model is enough.                */
   /*---------------------------------------------------------------*/
   reg  [7:0] uart_tx_data;
   reg        uart_tx_valid;
   reg  [7:0] uart_rx_data;
   reg        uart_rx_valid;

   wire [1:0] io_reg_sel = mem_addr[3:2];   // 0..3

   reg  [31:0] io_rdata;
   always @(*) begin
      case (io_reg_sel)
         2'd0:    io_rdata = {24'b0, uart_rx_data};        // UART_DATA
         2'd1:    io_rdata = {30'b0, uart_rx_valid, 1'b1}; // UART_STATUS (TX always ready for now)
         default: io_rdata = 32'b0;
      endcase
   end

   always @(posedge clk) begin
      if (!resetn) begin
         uart_tx_valid <= 1'b0;
         uart_rx_valid <= 1'b0;
      end else begin
         // TX: write to UART_DATA
         if (sel_io & (io_reg_sel == 2'd0) & |mem_wmask) begin
            uart_tx_data  <= mem_wdata[7:0];
            uart_tx_valid <= 1'b1;
`ifdef BENCH
            $write("%c", mem_wdata[7:0]);
`endif
         end else begin
            uart_tx_valid <= 1'b0;
         end

         // RX: read from UART_DATA clears rx_valid
         if (sel_io & (io_reg_sel == 2'd0) & mem_rstrb)
            uart_rx_valid <= 1'b0;

`ifdef BENCH
         // Simulation finish on write to CTRL register
         if (sel_io & (io_reg_sel == 2'd3) & |mem_wmask)
            $finish;
`endif
      end
   end

   // Stub UART pins (replace with real UART TX/RX serdes for silicon)
   assign uart_tx = 1'b1;    // idle high
   wire _unused_rx = uart_rx;

   /*---------------------------------------------------------------*/
   /* UART break detector → dbg_halt_req                            */
   /*                                                               */
   /* A serial "break" is RX held low for longer than one frame.    */
   /* GDB sends this when the user hits Ctrl-C. We detect it with   */
   /* a saturating counter and pulse dbg_halt_req — this forces a   */
   /* trap into the ROM stub regardless of MIE.                     */
   /*---------------------------------------------------------------*/
   reg [3:0] brk_cnt;
   always @(posedge clk) begin
      if (!resetn)       brk_cnt <= 4'd0;
      else if (uart_rx)  brk_cnt <= 4'd0;          // RX high → reset
      else if (~(&brk_cnt)) brk_cnt <= brk_cnt + 1; // count while low (saturate at 15)
   end
   wire uart_break = &brk_cnt;  // RX low for 15+ cycles → break

   /*---------------------------------------------------------------*/
   /* Read mux + handshake                                          */
   /*---------------------------------------------------------------*/
   // ROM is combinational → no wait states for ROM fetches.
   // RAM is synchronous → 1-cycle read latency handled by the core's
   // existing S_FETCH_INSTR → S_WAIT_INSTR pipeline.
   assign mem_rdata = sel_rom ? rom_rdata :
                      sel_io  ? io_rdata  :
                                ram_rdata ;

   assign mem_rbusy = 1'b0;
   assign mem_wbusy = 1'b0;

   /*---------------------------------------------------------------*/
   /* Firmware loading (simulation only)                            */
   /*---------------------------------------------------------------*/
`ifdef BENCH
   reg [256*8-1:0] hex_file;
   integer i;
   initial begin
      // Pre-zero all RAM (avoids x-propagation in uninitialized BSS).
      for (i = 0; i < RAM_WORDS; i = i + 1)
         ram[i] = 32'h00000000;
      if ($value$plusargs("hex=%s", hex_file))
         $readmemh(hex_file, ram);
   end
`endif

endmodule
