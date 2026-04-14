/*-----------------------------------------------------------------------------
 * attorv32_ahbl.v — AHB-Lite master wrapper around AttoRV32.
 *
 * Exposes a single AHB-Lite master port. Issues one beat at a time
 * (HTRANS = NONSEQ -> IDLE). Size is derived from mem_wmask for stores
 * and fixed to WORD for fetches and loads (the CPU extracts the needed
 * lane internally).
 *
 * Reset is active-low on HRESETn (AMBA convention); the internal core
 * reset pin is active-low too, so it is passed through unchanged.
 *---------------------------------------------------------------------------*/

module attorv32_ahbl #(
   parameter ADDR_WIDTH       = 32,
   parameter RV32E            = 0,
   parameter [31:0] MTVEC_ADDR = 32'h00000010
)(
   // AHB-Lite clock / reset
   input              HCLK,
   input              HRESETn,

   // AHB-Lite master
   output reg [31:0]  HADDR,
   output reg         HWRITE,
   output reg [ 2:0]  HSIZE,
   output reg [ 2:0]  HBURST,
   output reg [ 3:0]  HPROT,
   output reg [ 1:0]  HTRANS,
   output             HMASTLOCK,
   output     [31:0]  HWDATA,
   input      [31:0]  HRDATA,
   input              HREADY,
   input              HRESP,

   // External interrupt (active-high, non-sticky — source holds until taken)
   input              interrupt_request,
   input              nmi,              // non-maskable interrupt
   input              dbg_halt_req      // debug halt (bypasses MIE + mcause)
);

   assign HMASTLOCK = 1'b0;

   /*---------------------------------------------------------------------*/
   /* CPU-side signals                                                    */
   /*---------------------------------------------------------------------*/
   wire [31:0] mem_addr;
   wire [31:0] mem_wdata;
   wire [ 3:0] mem_wmask;
   wire        mem_rstrb;
   reg  [31:0] mem_rdata;
   reg         mem_rbusy;
   reg         mem_wbusy;

   AttoRV32 #(
      .ADDR_WIDTH (ADDR_WIDTH),
      .RV32E      (RV32E),
      .MTVEC_ADDR (MTVEC_ADDR[ADDR_WIDTH-1:0])
   ) u_core (
      .clk               (HCLK),
      .reset             (HRESETn),
      .mem_addr          (mem_addr),
      .mem_wdata         (mem_wdata),
      .mem_wmask         (mem_wmask),
      .mem_rdata         (mem_rdata),
      .mem_rstrb         (mem_rstrb),
      .mem_rbusy         (mem_rbusy),
      .mem_wbusy         (mem_wbusy),
      .interrupt_request (interrupt_request),
      .nmi               (nmi),
      .dbg_halt_req      (dbg_halt_req)
   );

   /*---------------------------------------------------------------------*/
   /* HSIZE encoding from byte-mask (stores only)                         */
   /*---------------------------------------------------------------------*/
   function [2:0] size_from_mask;
      input [3:0] m;
      begin
         casez (m)
            4'b1111             : size_from_mask = 3'b010; // word
            4'b1100, 4'b0011    : size_from_mask = 3'b001; // half
            default             : size_from_mask = 3'b000; // byte
         endcase
      end
   endfunction

   /*---------------------------------------------------------------------*/
   /* Master FSM                                                          */
   /*---------------------------------------------------------------------*/
   localparam S_IDLE = 1'b0;
   localparam S_DATA = 1'b1;

   reg        state;
   reg        is_write_d;      // write/read recorded in addr phase

   wire       cpu_req = mem_rstrb | (|mem_wmask);

   // HWDATA is only valid in the data phase of a write; the CPU
   // already has byte-replicated data, so we forward mem_wdata.
   assign HWDATA = mem_wdata;

   always @(posedge HCLK or negedge HRESETn) begin
      if (!HRESETn) begin
         state      <= S_IDLE;
         HTRANS     <= 2'b00;       // IDLE
         HADDR      <= 32'b0;
         HWRITE     <= 1'b0;
         HSIZE      <= 3'b010;
         HBURST     <= 3'b000;      // SINGLE
         HPROT      <= 4'b0011;     // data, privileged, non-bufferable, non-cacheable
         is_write_d <= 1'b0;
      end else begin
         case (state)
            S_IDLE: begin
               if (cpu_req) begin
                  HTRANS     <= 2'b10;                      // NONSEQ
                  HADDR      <= mem_addr;
                  HWRITE     <= |mem_wmask;
                  HSIZE      <= (|mem_wmask) ? size_from_mask(mem_wmask)
                                             : 3'b010;
                  HBURST     <= 3'b000;                     // SINGLE
                  HPROT      <= mem_rstrb & ~(|mem_wmask)
                                ? 4'b0010      // instr/data: bit0=0 means opcode; here we keep data
                                : 4'b0011;
                  is_write_d <= |mem_wmask;
                  state      <= S_DATA;
               end else begin
                  HTRANS <= 2'b00;                          // IDLE
               end
            end

            S_DATA: begin
               // After the address phase, go back to IDLE on the bus.
               // The data phase overlaps this cycle (HREADY samples it).
               HTRANS <= 2'b00;
               if (HREADY) begin
                  state <= S_IDLE;
               end
            end
         endcase
      end
   end

   /*---------------------------------------------------------------------*/
   /* CPU-side handshakes                                                 */
   /*                                                                     */
   /* We hold mem_rbusy / mem_wbusy high from the cycle the CPU issues    */
   /* the request until HREADY=1 in the data phase. On that cycle we      */
   /* latch HRDATA and drop busy so the CPU advances next edge.           */
   /*---------------------------------------------------------------------*/
   always @(*) begin
      mem_rbusy = 1'b0;
      mem_wbusy = 1'b0;
      if (state == S_IDLE && cpu_req) begin
         // About to issue — stall the CPU for at least this cycle.
         mem_rbusy =  mem_rstrb;
         mem_wbusy = |mem_wmask;
      end else if (state == S_DATA && !HREADY) begin
         mem_rbusy = ~is_write_d;
         mem_wbusy =  is_write_d;
      end
   end

   always @(posedge HCLK) begin
      if (state == S_DATA && HREADY && !is_write_d)
         mem_rdata <= HRDATA;
   end

   /* HRESP: AHB-Lite only signals error as a 2-cycle sequence; this
    * simple wrapper ignores it. A production version should translate
    * a sustained HRESP into a synchronous abort (e.g. drive into a
    * bus-fault trap via a private NMI) and back off HTRANS. */
   wire _unused_resp = HRESP;

endmodule
