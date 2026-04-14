/*----------------------------------------------------------------------------
 * tb.v — AttoRV32 self-checking testbench
 *
 * Wraps the core with:
 *   - a 2^ADDR_WIDTH byte-addressable memory initialized from firmware.hex
 *   - memory-mapped DONE / DEBUG / IRQ registers in the top 16 bytes:
 *
 *        0x...F0  DONE    :  write 0  => PASS; write non-zero => FAIL code
 *        0x...F4  DEBUG   :  write a byte -> printed to stdout as a char
 *        0x...F8  IRQ_STS :  read  -> pending bits;  bit 0 = tick source
 *        0x...FC  IRQ_CLR :  write -> clears the matching pending bits
 *
 *   - a single external IRQ source that auto-asserts periodically and
 *     deasserts when the ISR writes IRQ_CLR, matching the core's non-sticky
 *     IRQ contract.
 *
 * Plusargs:
 *   +hex=<file>     firmware image (default "firmware.hex")
 *   +timeout=<N>    max simulation cycles (default 1_000_000)
 *   +vcd=<file>     if given, dumps a VCD trace
 *
 * Exit: $finish with a PASS / FAIL message and exit status.
 *---------------------------------------------------------------------------*/

`timescale 1ns/1ps

module tb;
   parameter ADDR_WIDTH     = 12;
   parameter RV32E          = 0;
   parameter IRQ_PERIOD     = 5000;    // cycles between auto-IRQ pulses

   localparam RAM_BYTES     = 1 << ADDR_WIDTH;

   reg  clk   = 0;
   reg  rst_n = 0;
   always #5 clk = ~clk;               // 100 MHz (period 10 ns)

   // --------------------------------------------------------------------
   //  CPU signals
   // --------------------------------------------------------------------
   wire [31:0] mem_addr;
   wire [31:0] mem_wdata;
   wire  [3:0] mem_wmask;
   reg  [31:0] mem_rdata;
   wire        mem_rstrb;
   wire        mem_rbusy = 1'b0;
   wire        mem_wbusy = 1'b0;

   reg         irq_line  = 1'b0;
   reg         irq_pending_tick = 1'b0;

   AttoRV32 #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .RV32E     (RV32E)
   ) u_cpu (
      .clk               (clk),
      .reset             (rst_n),
      .mem_addr          (mem_addr),
      .mem_wdata         (mem_wdata),
      .mem_wmask         (mem_wmask),
      .mem_rdata         (mem_rdata),
      .mem_rstrb         (mem_rstrb),
      .mem_rbusy         (mem_rbusy),
      .mem_wbusy         (mem_wbusy),
      .interrupt_request (irq_line),
      .nmi               (1'b0),
      .dbg_halt_req      (1'b0),
      .pc_out            ()
   );

   // --------------------------------------------------------------------
   //  Byte-addressable RAM, initialized from firmware.hex
   // --------------------------------------------------------------------
   reg [7:0] ram [0:RAM_BYTES-1];

   wire [ADDR_WIDTH-1:0] addr = mem_addr[ADDR_WIDTH-1:0] & ~2'b11;  // word-aligned

   // I/O register addresses (top 16 bytes of the address space).
   localparam [ADDR_WIDTH-1:0] IO_DONE    = RAM_BYTES - 16;   // 0x...F0
   localparam [ADDR_WIDTH-1:0] IO_DEBUG   = RAM_BYTES - 12;   // 0x...F4
   localparam [ADDR_WIDTH-1:0] IO_IRQ_STS = RAM_BYTES -  8;   // 0x...F8
   localparam [ADDR_WIDTH-1:0] IO_IRQ_CLR = RAM_BYTES -  4;   // 0x...FC

   wire is_io     = (addr == IO_DONE) | (addr == IO_DEBUG)
                  | (addr == IO_IRQ_STS) | (addr == IO_IRQ_CLR);

   // Combinational read (RAM word or I/O).
   always @* begin
      if (addr == IO_IRQ_STS)
         mem_rdata = {31'b0, irq_pending_tick};
      else
         mem_rdata = {ram[addr+3], ram[addr+2], ram[addr+1], ram[addr]};
   end

   // Byte-masked write — RAM or I/O.
   integer i;
   reg [7:0] db;
   always @(posedge clk) begin
      if (|mem_wmask && !is_io) begin
         if (mem_wmask[0]) ram[addr+0] <= mem_wdata[ 7: 0];
         if (mem_wmask[1]) ram[addr+1] <= mem_wdata[15: 8];
         if (mem_wmask[2]) ram[addr+2] <= mem_wdata[23:16];
         if (mem_wmask[3]) ram[addr+3] <= mem_wdata[31:24];
      end
      if (|mem_wmask && is_io) begin
         case (addr)
            IO_DONE: begin
               if (mem_wdata == 0) begin
                  $display("[tb] PASS at cycle %0d", cycle);
                  $finish(0);
               end else begin
                  $display("[tb] FAIL code=0x%08h at cycle %0d (PC=0x%08h)",
                           mem_wdata, cycle, u_cpu.PC);
                  $finish(1);
               end
            end
            IO_DEBUG: begin
               db = mem_wdata[7:0];
               $write("%c", db);
               $fflush;
            end
            IO_IRQ_CLR: begin
               if (mem_wdata[0]) irq_pending_tick <= 1'b0;
            end
            default: ;
         endcase
      end
   end

   // --------------------------------------------------------------------
   //  IRQ generator: pulses every IRQ_PERIOD cycles, cleared by software.
   //  Core treats irq_line as non-sticky, so we hold it high until the ISR
   //  writes IO_IRQ_CLR.
   // --------------------------------------------------------------------
   integer cycle = 0;
   integer next_irq = IRQ_PERIOD;
   always @(posedge clk) begin
      cycle <= cycle + 1;
      if (cycle == next_irq) begin
         irq_pending_tick <= 1'b1;
         next_irq <= cycle + IRQ_PERIOD;
      end
   end
   always @* irq_line = irq_pending_tick;

   // --------------------------------------------------------------------
   //  Bring-up, timeout, optional VCD
   // --------------------------------------------------------------------
   reg [255*8-1:0] hexfile;
   reg [255*8-1:0] vcdfile;
   integer        timeout;

   initial begin
      // Clear RAM so uninitialized fetches behave predictably (0 => c.unimp).
      for (i = 0; i < RAM_BYTES; i = i + 1) ram[i] = 8'h00;

      if (!$value$plusargs("hex=%s", hexfile))
         hexfile = "firmware.hex";
      $display("[tb] loading %0s (ADDR_WIDTH=%0d, RV32E=%0d)",
               hexfile, ADDR_WIDTH, RV32E);
      $readmemh(hexfile, ram);

      if (!$value$plusargs("timeout=%d", timeout))
         timeout = 1_000_000;

      if ($value$plusargs("vcd=%s", vcdfile)) begin
         $dumpfile(vcdfile);
         $dumpvars(0, tb);
      end

      // Reset pulse
      rst_n = 1'b0;
      repeat (8) @(posedge clk);
      rst_n = 1'b1;

      // Timeout watchdog
      repeat (timeout) @(posedge clk);
      $display("[tb] TIMEOUT after %0d cycles (PC=0x%08h)",
               timeout, u_cpu.PC);
      $finish(2);
   end

endmodule
