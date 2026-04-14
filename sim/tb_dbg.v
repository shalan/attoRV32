/*----------------------------------------------------------------------------
 * tb_dbg.v — Debug facility testbench for AttoRV32
 *
 * Instantiates attorv32_dbg (core + RAM + stub ROM + UART).
 * Tests the GDB RSP stub by:
 *   1. Loading a simple user program (counter loop).
 *   2. Letting it run, then asserting UART break to halt.
 *   3. Injecting RSP packets via hierarchical register pokes.
 *   4. Verifying responses on the TX output.
 *
 * UART injection uses hierarchical references to uart_rx_data/uart_rx_valid
 * rather than bit-serial RX timing. TX output is captured the same way
 * (uart_tx_data/uart_tx_valid).
 *
 * Plusargs:
 *   +hex=<file>     firmware image (default "dbg_test.hex")
 *   +timeout=<N>    max simulation cycles (default 2_000_000)
 *   +vcd=<file>     if given, dumps a VCD trace
 *---------------------------------------------------------------------------*/

`timescale 1ns/1ps

module tb_dbg;
   parameter RAM_AW = 12;
   parameter RV32E  = 0;

   reg clk   = 0;
   reg rst_n = 0;
   always #5 clk = ~clk;   // 100 MHz

   /*---------------------------------------------------------------*/
   /* DUT                                                           */
   /*---------------------------------------------------------------*/
   reg  uart_rx_pin = 1'b1;  // idle high

   wire uart_tx_pin;

   attorv32_dbg #(
      .RAM_AW (RAM_AW),
      .RV32E  (RV32E)
   ) u_dut (
      .clk     (clk),
      .resetn  (rst_n),
      .irq     (1'b0),
      .uart_rx (uart_rx_pin),
      .uart_tx (uart_tx_pin)
   );

   /*---------------------------------------------------------------*/
   /* Timeout / VCD                                                 */
   /*---------------------------------------------------------------*/
   integer timeout = 2_000_000;
   integer cycle = 0;
   reg [127:0] vcd_file;
   reg [127:0] hex_file;

   initial begin
      if ($value$plusargs("timeout=%d", timeout)) ;
      if ($value$plusargs("vcd=%s", vcd_file)) begin
         $dumpfile("dbg.vcd");
         $dumpvars(0, tb_dbg);
      end
   end

   always @(posedge clk) begin
      cycle <= cycle + 1;
      if (cycle >= timeout) begin
         $display("TIMEOUT at cycle %0d", cycle);
         $finish;
      end
      /* Uncomment for debug PC trace:
       * if (cycle > 2000 && cycle < 4000 && cycle % 100 == 0)
       *    $display("  [PC] cycle=%0d  PC=0x%08X  state=%0d", cycle,
       *             u_dut.u_core.PC, u_dut.u_core.state);
       */
   end

   /*---------------------------------------------------------------*/
   /* TX capture — snoop the DUT's internal uart_tx_data/valid      */
   /*---------------------------------------------------------------*/
   reg [8*512-1:0] tx_log;    // captured TX bytes as a flat string
   integer tx_len = 0;

   always @(posedge clk) begin
      if (u_dut.uart_tx_valid) begin
         tx_log[tx_len*8 +: 8] <= u_dut.uart_tx_data;
         tx_len <= tx_len + 1;
         /* Uncomment for TX debug:
          * $display("  [TX] byte=0x%02X '%c'", u_dut.uart_tx_data, u_dut.uart_tx_data);
          */
      end
   end

   /* Extract a byte from the TX log. */
   function [7:0] tx_byte;
      input integer idx;
      tx_byte = tx_log[idx*8 +: 8];
   endfunction

   /*---------------------------------------------------------------*/
   /* UART RX injection — poke bytes into the DUT's rx registers    */
   /*---------------------------------------------------------------*/
   task inject_byte;
      input [7:0] b;
      begin
         @(posedge clk);
         /* Wait until any previous RX byte has been consumed. */
         while (u_dut.uart_rx_valid) @(posedge clk);
         u_dut.uart_rx_data  = b;
         u_dut.uart_rx_valid = 1'b1;
         @(posedge clk);
         /* The DUT will clear rx_valid when it reads the byte. */
      end
   endtask

   /* Inject a full string. Verilog string literals are MSB-first
    * (rightmost char at [7:0]), so we send from MSB to LSB. */
   task inject_string;
      input [8*256-1:0] s;
      input integer     len;
      integer i;
      begin
         for (i = len - 1; i >= 0; i = i - 1)
            inject_byte(s[i*8 +: 8]);
      end
   endtask

   /* Compute RSP checksum of a string. */
   function [7:0] rsp_checksum;
      input [8*256-1:0] s;
      input integer     len;
      integer i;
      reg [7:0] sum;
      begin
         sum = 0;
         for (i = 0; i < len; i = i + 1)
            sum = sum + s[i*8 +: 8];
         rsp_checksum = sum;
      end
   endfunction

   /* Hex nibble to ASCII. */
   function [7:0] hex_char;
      input [3:0] nib;
      hex_char = (nib < 10) ? (8'h30 + nib) : (8'h61 + nib - 10);
   endfunction

   /* Inject a complete RSP packet: $<payload>#<checksum> */
   task inject_packet;
      input [8*256-1:0] payload;
      input integer     plen;
      reg [7:0] ck;
      begin
         ck = rsp_checksum(payload, plen);
         inject_byte("$");
         inject_string(payload, plen);
         inject_byte("#");
         inject_byte(hex_char(ck[7:4]));
         inject_byte(hex_char(ck[3:0]));
      end
   endtask

   /*---------------------------------------------------------------*/
   /* Wait for a TX packet ($...#XX) and capture it.                */
   /*---------------------------------------------------------------*/
   reg [8*256-1:0] rx_pkt;    // received packet payload
   integer rx_pkt_len;

   task wait_tx_packet;
      input integer max_cycles;
      integer start_cycle;
      integer saw_dollar;
      integer done;
      reg [7:0] b;
      begin
         rx_pkt_len = 0;
         saw_dollar = 0;
         done = 0;
         start_cycle = cycle;

         while (cycle - start_cycle < max_cycles && !done) begin
            @(posedge clk);
            if (u_dut.uart_tx_valid) begin
               b = u_dut.uart_tx_data;
               if (!saw_dollar) begin
                  if (b == "$") saw_dollar = 1;
                  /* else: skip ACK (+) or other chars */
               end else if (b == "#") begin
                  /* Consume two checksum chars. */
                  @(posedge clk);
                  while (!u_dut.uart_tx_valid) @(posedge clk);
                  @(posedge clk);
                  while (!u_dut.uart_tx_valid) @(posedge clk);
                  done = 1;
               end else begin
                  rx_pkt[rx_pkt_len*8 +: 8] = b;
                  rx_pkt_len = rx_pkt_len + 1;
               end
            end
         end
         if (!done)
            $display("ERROR: timeout waiting for TX packet");
      end
   endtask

   /* Check first N bytes of received packet against expected.
    * Verilog string literals are MSB-first (rightmost char is [7:0]),
    * but rx_pkt stores bytes LSB-first (first byte at [7:0]).
    * So we compare: rx_pkt[i] == expected[elen-1-i]. */
   task check_rx_starts_with;
      input [8*32-1:0] expected;
      input integer    elen;
      input [8*64-1:0] msg;
      integer i;
      reg ok;
      begin
         ok = 1;
         if (rx_pkt_len < elen) ok = 0;
         for (i = 0; i < elen && ok; i = i + 1)
            if (rx_pkt[i*8 +: 8] !== expected[(elen-1-i)*8 +: 8]) ok = 0;

         if (ok)
            $display("  PASS: %0s", msg);
         else begin
            $display("  FAIL: %0s (rx_pkt_len=%0d, expected_len=%0d)", msg, rx_pkt_len, elen);
            $finish;
         end
      end
   endtask

   /*---------------------------------------------------------------*/
   /* Simulate UART break (drive RX low for 20+ cycles)            */
   /*---------------------------------------------------------------*/
   task uart_break;
      integer i;
      begin
         uart_rx_pin = 1'b0;
         for (i = 0; i < 20; i = i + 1)
            @(posedge clk);
         uart_rx_pin = 1'b1;
         /* Wait a few cycles for the break detector to trigger and
          * the core to trap into the ROM stub. */
         for (i = 0; i < 100; i = i + 1)
            @(posedge clk);
      end
   endtask

   /*---------------------------------------------------------------*/
   /* RAM read helper (for verification)                            */
   /*---------------------------------------------------------------*/
   function [31:0] ram_read;
      input integer byte_addr;
      ram_read = u_dut.ram[byte_addr >> 2];
   endfunction

   /*---------------------------------------------------------------*/
   /* Main test sequence                                            */
   /*---------------------------------------------------------------*/
   integer test_pass;
   reg [31:0] counter_before, counter_after;

   initial begin
      test_pass = 1;

      /* Firmware is loaded by attorv32_dbg's own `ifdef BENCH block
       * via the +hex=<file> plusarg.  The hex file must be word-oriented
       * (one 32-bit hex value per line) for the DUT's reg [31:0] ram. */

      /* Reset. */
      rst_n = 0;
      repeat (5) @(posedge clk);
      rst_n = 1;

      $display("\n=== Debug Facility Test ===\n");

      /* Let user program run for a while. */
      $display("Running user program for 2000 cycles...");
      repeat (2000) @(posedge clk);

      /* Read counter value from RAM. */
      counter_before = ram_read(8);
      $display("Counter before break: 0x%08X", counter_before);

      if (counter_before == 0) begin
         $display("FAIL: counter not incrementing");
         $finish;
      end
      $display("  PASS: user program running");

      /* ---- Test 1: UART break → halt ---- */
      $display("\nTest 1: UART break halt");
      uart_break;

      /* The stub should send $T05#b9 as the initial stop-reply.
       * Wait for it. */
      wait_tx_packet(50000);
      check_rx_starts_with("T05", 3, "stop-reply is T05");

      /* ---- Test 2: '?' → T05 ---- */
      $display("\nTest 2: '?' query");
      /* Send ACK first (the stub expects + after its T05 packet). */
      inject_byte("+");
      inject_packet("?", 1);
      wait_tx_packet(50000);
      /* Skip the ACK byte the stub sends for our ? packet. */
      check_rx_starts_with("T05", 3, "? reply is T05");

      /* ---- Test 3: 'g' → register dump ---- */
      $display("\nTest 3: 'g' read registers");
      inject_byte("+");
      inject_packet("g", 1);
      wait_tx_packet(50000);
      /* Reply should be 33 × 8 = 264 hex chars for RV32I. */
      if (rx_pkt_len == 264)
         $display("  PASS: g reply is 264 chars (33 regs × 8 hex)");
      else if (rx_pkt_len == 136)
         $display("  PASS: g reply is 136 chars (17 regs × 8 hex, RV32E)");
      else begin
         $display("  FAIL: g reply length = %0d (expected 264 or 136)", rx_pkt_len);
         $finish;
      end

      /* ---- Test 4: 'm0008,04' → read 4 bytes from RAM addr 0x8 ---- */
      $display("\nTest 4: 'm' memory read");
      inject_byte("+");
      inject_packet("m0008,04", 8);
      wait_tx_packet(50000);
      /* Reply should be 8 hex chars (4 bytes). */
      if (rx_pkt_len == 8)
         $display("  PASS: m reply is 8 hex chars");
      else begin
         $display("  FAIL: m reply length = %0d (expected 8)", rx_pkt_len);
         $finish;
      end

      /* ---- Test 5: 'c' → continue, verify counter resumes ---- */
      $display("\nTest 5: 'c' continue");
      inject_byte("+");
      counter_before = ram_read(8);
      inject_packet("c", 1);
      /* ACK the stub's implicit response. */
      inject_byte("+");

      /* Let user program run for 2000 more cycles. */
      repeat (2000) @(posedge clk);
      counter_after = ram_read(8);
      $display("Counter before continue: 0x%08X", counter_before);
      $display("Counter after continue:  0x%08X", counter_after);
      if (counter_after > counter_before)
         $display("  PASS: counter resumed incrementing");
      else begin
         $display("  FAIL: counter did not resume");
         $finish;
      end

      /* ---- Done ---- */
      $display("\n=== All debug tests PASS ===\n");
      $finish;
   end

endmodule
