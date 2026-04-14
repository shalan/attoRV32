/*-----------------------------------------------------------------------------
 * attorv32_dbg.v — Minimal debug SoC: core + RAM + stub ROM + UART.
 *
 * Memory map (16-bit address space, page-aligned regions):
 *
 *   0x0000 – 0x0FFF : RAM  (4 KiB, read/write, synchronous SRAM)
 *   0x1000 – 0x1FFF : Stub ROM  (4 KiB, combinational, read-only)
 *   0x2000 – 0x2FFF : I/O  (4 KiB = 16 peripheral slots × 256 bytes)
 *
 * Address decode: mem_addr[15:12]
 *   4'h0 → RAM     4'h1 → ROM     4'h2 → I/O
 *
 * I/O slot 0 (0x2000–0x20FF) — System Control:
 *   8 sub-slots × 32 bytes, decoded by mem_addr[7:5].
 *   Each sub-slot has 8 word-aligned registers (mem_addr[4:2]).
 *
 *   Sub  [7:5]  Address   Block             Registers
 *    0   000    0x2000    UART              DATA, STATUS
 *    1   001    0x2020    HW Breakpoints    BP_CTRL, BP_HIT, BP_COUNT, rsvd,
 *                                           BP_ADDR[0], BP_ADDR[1], BP_ADDR[2], BP_ADDR[3]
 *    2   010    0x2040    System Timer      (TBD)
 *    3   011    0x2060    PIC               (TBD)
 *    4   100    0x2080    Clocking          (TBD)
 *    5   101    0x20A0    Control           CTRL (write 1 → $finish, bench only)
 *    6   110    0x20C0    (reserved)
 *    7   111    0x20E0    (reserved)
 *
 * Slots 1–15 (0x2100–0x2FFF) — User peripherals (reserved / future).
 *
 * MTVEC_ADDR = ROM base (0x1000). Reset vector = 0x0000 (RAM).
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
   localparam ADDR_WIDTH = RAM_AW + 2;           // covers RAM + ROM + I/O
   localparam ROM_BASE   = (1 << RAM_AW);        // 0x1000
   localparam ROM_AW     = RAM_AW;               // ROM same size as RAM

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
   wire [ADDR_WIDTH-1:0] core_pc;
   wire        bp_halt;

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
      .dbg_halt_req      (uart_break | bp_halt),
      .pc_out            (core_pc)
   );

   /*---------------------------------------------------------------*/
   /* Address decode                                                */
   /*---------------------------------------------------------------*/
   wire [3:0] page_sel = mem_addr[15:12];

   wire sel_ram = (page_sel == 4'h0);            // 0x0000–0x0FFF
   wire sel_rom = (page_sel == 4'h1);            // 0x1000–0x1FFF
   wire sel_io  = (page_sel == 4'h2);            // 0x2000–0x2FFF

   // I/O: 16 peripheral slots × 256 bytes
   wire [3:0] io_slot = mem_addr[11:8];          // slot number

   // Slot 0 — System Control: 8 sub-slots × 32 bytes
   wire       sel_sys     = sel_io & (io_slot == 4'd0);
   wire [2:0] sys_subslot = mem_addr[7:5];       // sub-slot within slot 0
   wire [2:0] sys_reg     = mem_addr[4:2];       // register within sub-slot

   wire sel_uart = sel_sys & (sys_subslot == 3'd0);
   wire sel_bkpt = sel_sys & (sys_subslot == 3'd1);
   wire sel_ctrl = sel_sys & (sys_subslot == 3'd5);

   /*---------------------------------------------------------------*/
   /* RAM (synchronous read/write; maps to real SRAM)              */
   /*---------------------------------------------------------------*/
   localparam RAM_WORDS = (1 << RAM_AW) / 4;

   reg [31:0] ram [0:RAM_WORDS-1];

   wire [RAM_AW-3:0] ram_waddr = mem_addr[RAM_AW-1:2];

   always @(posedge clk) begin
      if (sel_ram & mem_wmask[0]) ram[ram_waddr][ 7: 0] <= mem_wdata[ 7: 0];
      if (sel_ram & mem_wmask[1]) ram[ram_waddr][15: 8] <= mem_wdata[15: 8];
      if (sel_ram & mem_wmask[2]) ram[ram_waddr][23:16] <= mem_wdata[23:16];
      if (sel_ram & mem_wmask[3]) ram[ram_waddr][31:24] <= mem_wdata[31:24];
   end

   reg [31:0] ram_rdata;
   always @(posedge clk)
      ram_rdata <= ram[mem_addr[RAM_AW-1:2]];

   /*---------------------------------------------------------------*/
   /* Stub ROM (combinational — no clock)                           */
   /*---------------------------------------------------------------*/
   wire [31:0] rom_rdata;

   stub_rom #(
      .AW  (ROM_AW - 2)
   ) u_rom (
      .addr  (mem_addr[ROM_AW-1:2]),
      .rdata (rom_rdata)
   );

   /*---------------------------------------------------------------*/
   /* Sub-slot 0: UART                                              */
   /*---------------------------------------------------------------*/
   wire uart_wr_en = sel_uart & (sys_reg == 3'd0) & |mem_wmask;
   wire uart_rd_en = sel_uart & (sys_reg == 3'd0) & mem_rstrb;

`ifdef BENCH
   reg  [7:0] uart_tx_data;
   reg        uart_tx_valid;
   reg  [7:0] uart_rx_data;
   reg        uart_rx_valid;
   wire       uart_tx_ready = 1'b1;
   wire       uart_baud_locked = 1'b1;

   always @(posedge clk) begin
      if (!resetn) begin
         uart_tx_valid <= 1'b0;
         uart_rx_valid <= 1'b0;
      end else begin
         if (uart_wr_en) begin
            uart_tx_data  <= mem_wdata[7:0];
            uart_tx_valid <= 1'b1;
            $write("%c", mem_wdata[7:0]);
         end else begin
            uart_tx_valid <= 1'b0;
         end
         if (uart_rd_en)
            uart_rx_valid <= 1'b0;
         if (sel_ctrl & |mem_wmask)
            $finish;
      end
   end

   assign uart_tx = 1'b1;
   wire _unused_rx = uart_rx;

   /* Break detector (simple counter for simulation) */
   reg [3:0] brk_cnt;
   always @(posedge clk) begin
      if (!resetn)       brk_cnt <= 4'd0;
      else if (uart_rx)  brk_cnt <= 4'd0;
      else if (~(&brk_cnt)) brk_cnt <= brk_cnt + 1;
   end
   wire uart_break = &brk_cnt;

`else
   wire [7:0] uart_rx_data;
   wire       uart_rx_valid;
   wire       uart_tx_ready;
   wire       uart_baud_locked;
   wire       uart_break;

   dbg_uart u_uart (
      .clk      (clk),
      .resetn   (resetn),
      .rx_pin   (uart_rx),
      .tx_pin   (uart_tx),
      .wr_data  (mem_wdata[7:0]),
      .wr_en    (uart_wr_en),
      .tx_ready (uart_tx_ready),
      .rd_data  (uart_rx_data),
      .rd_valid (uart_rx_valid),
      .rd_en    (uart_rd_en),
      .brk      (uart_break),
      .locked   (uart_baud_locked)
   );

   always @(posedge clk) begin
`ifdef BENCH_FINISH
      if (sel_ctrl & |mem_wmask)
         $finish;
`endif
   end
`endif

   /*---------------------------------------------------------------*/
   /* Sub-slot 1: Hardware breakpoints (4 slots)                    */
   /*---------------------------------------------------------------*/
   wire [31:0] bp_rdata;

   hw_bkpt #(
      .N          (4),
      .ADDR_WIDTH (ADDR_WIDTH)
   ) u_bkpt (
      .clk      (clk),
      .resetn   (resetn),
      .pc_in    (core_pc),
      .halt_req (bp_halt),
      .sel      (sel_bkpt),
      .reg_addr (sys_reg),                       // 3-bit word offset within 32-byte sub-slot
      .wdata    (mem_wdata),
      .wmask    (mem_wmask),
      .rstrb    (mem_rstrb),
      .rdata    (bp_rdata)
   );

   /*---------------------------------------------------------------*/
   /* Slot 0 (System Control) read mux                              */
   /*                                                                */
   /* sys_subslot  Block                                             */
   /*   0          UART: reg 0 = DATA, reg 1 = STATUS               */
   /*   1          HW breakpoints                                    */
   /*   5          Control                                           */
   /*---------------------------------------------------------------*/
   reg  [31:0] sys_rdata;
   always @(*) begin
      case (sys_subslot)
         3'd0: begin    // UART
            case (sys_reg[0])
               1'b0:    sys_rdata = {24'b0, uart_rx_data};
               1'b1:    sys_rdata = {29'b0, uart_baud_locked, uart_rx_valid, uart_tx_ready};
            endcase
         end
         3'd1:    sys_rdata = bp_rdata;            // HW breakpoints
         default: sys_rdata = 32'b0;
      endcase
   end

   /*---------------------------------------------------------------*/
   /* Top-level I/O read mux                                        */
   /*---------------------------------------------------------------*/
   reg  [31:0] io_rdata;
   always @(*) begin
      case (io_slot)
         4'd0:    io_rdata = sys_rdata;           // System Control
         default: io_rdata = 32'b0;               // slots 1–15: future
      endcase
   end

   /*---------------------------------------------------------------*/
   /* Read mux + handshake                                          */
   /*---------------------------------------------------------------*/
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
      for (i = 0; i < RAM_WORDS; i = i + 1)
         ram[i] = 32'h00000000;
      if ($value$plusargs("hex=%s", hex_file))
         $readmemh(hex_file, ram);
   end
`endif

endmodule
