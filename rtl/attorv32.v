/******************************************************************************/
// AttoRV32 — a heavily-minimized, parameterized RV32 core
//
// Derived from FemtoRV32 "Gracilis" by Bruno Levy, Matthias Koch (2020-2021).
// Minimization pass + parameterization + serial arithmetic units: 2026.
//
// The goal is the smallest practical RISC-V on Sky130A that still runs
// standard GCC output. C (compressed) and interrupts are always on;
// everything else is optional.
//
// Fixed features:
//   - RV32 base, always with C (compressed)
//   - External interrupt: maskable (gated by mstatus.MIE), non-sticky —
//     source must hold request until accepted.
//   - NMI: non-maskable interrupt. Bypasses mstatus.MIE but blocked by
//     mcause (cannot nest into an active handler). Reports mcause=0x80000000.
//   - Debug halt: dbg_halt_req input. Bypasses BOTH mstatus.MIE AND mcause —
//     can halt the CPU at any time, even inside an ISR. Reports mcause=3
//     (same as EBREAK), so a ROM-resident GDB stub handles it transparently.
//     A 1-FF dbg_halt_mask prevents re-triggering; cleared on mret.
//   - Hardcoded mtvec (parameter MTVEC_ADDR)
//   - Proper EBREAK / ECALL: trap to MTVEC_ADDR with mcause=3/11.
//     MRET is strictly decoded (instr[31:20] == 12'h302).
//   - CSRs: mstatus (rw, bit 3 = MIE), mepc (rw), mcause (ro).
//     mcause format: bit 31 = interrupt flag, low bits = cause code.
//   - 4- or 5-state, binary-encoded FSM (depending on NRV_SINGLE_PORT_REGF)
//
// Trap priority (highest first):
//   dbg_halt_req > nmi > interrupt_request > env_trap (EBREAK/ECALL)
//
// Parameters:
//   ADDR_WIDTH : 8..16 (256 B .. 64 KiB address space)
//   RV32E      : 0 -> 32 registers (RV32I), 1 -> 16 registers (RV32E)
//   MTVEC_ADDR : trap vector address (default 0x10)
//
// Compile-time `defines (all default OFF):
//   `NRV_M                : enable M extension (MUL/DIV/REM + MULH*)
//   `NRV_SRA              : enable arithmetic right shift (SRA/SRAI)
//   `NRV_PERF_CSR         : enable rdcycle / rdcycleh (64-bit cycle counter)
//   `NRV_SINGLE_PORT_REGF : single-read-port register file (extra cycle
//                           for rs2 on branch/store/ALUreg)
//   `NRV_SHARED_ADDER     : one shared 32-bit adder (requires SINGLE_PORT)
//   `NRV_SERIAL_SHIFT     : 1-bit/cycle serial shifter (+shamt cycles)
//   `NRV_SERIAL_MUL       : serial shift-add multiplier (requires NRV_M)
//                           Default: radix-2, 32 cycles.
//   `NRV_RADIX4_MUL       : radix-4 modified Booth multiplier, 16 cycles
//                           (requires NRV_SERIAL_MUL)
//
// Port summary:
//   clk               : system clock
//   reset             : active-low synchronous reset
//   mem_addr[31:0]    : memory address (ADDR_WIDTH LSBs significant)
//   mem_wdata[31:0]   : write data (byte-lane-replicated)
//   mem_wmask[3:0]    : byte-enable store mask
//   mem_rdata[31:0]   : read data (sampled when !mem_rbusy)
//   mem_rstrb         : read strobe (fetch or load)
//   mem_rbusy         : stall CPU (read path)
//   mem_wbusy         : stall CPU (write path)
//   interrupt_request : maskable external interrupt (active-high, level)
//   nmi               : non-maskable interrupt (active-high, level)
//   dbg_halt_req      : debug halt (active-high, level)
/******************************************************************************/

// Uncomment to enable optional extensions:
// `define NRV_M
// `define NRV_SRA
// `define NRV_PERF_CSR
// `define NRV_SINGLE_PORT_REGF
// `define NRV_SHARED_ADDER

module AttoRV32 #(
   parameter ADDR_WIDTH       = 12,    // 8..12
   parameter RV32E            = 0,     // 0=RV32I, 1=RV32E
   parameter [ADDR_WIDTH-1:0] MTVEC_ADDR = 'h10
)(
   input                    clk,

   output [31:0]            mem_addr,
   output [31:0]            mem_wdata,
   output  [3:0]            mem_wmask,
   input  [31:0]            mem_rdata,
   output                   mem_rstrb,
   input                    mem_rbusy,
   input                    mem_wbusy,

   input                    interrupt_request,
   input                    nmi,             // non-maskable interrupt (edge-sensitive, level-held)
   input                    dbg_halt_req,    // debug halt request (active-high)
   input                    reset,       // active-low

   output [ADDR_WIDTH-1:0]  pc_out           // current PC (for hardware breakpoints)
);


   localparam NB_REGS  = RV32E ? 16 : 32;
   localparam REG_BITS = RV32E ? 4  : 5;

`ifdef BENCH
   initial begin
      if (ADDR_WIDTH < 8 || ADDR_WIDTH > 16) begin
         $display("ERROR: ADDR_WIDTH must be in 8..16 (got %0d)", ADDR_WIDTH);
         $finish;
      end
   end
`endif

   /***************************************************************************/
   // Instruction decoding
   /***************************************************************************/

   wire [REG_BITS-1:0] rdId  = instr       [ 7 +: REG_BITS];
   wire [REG_BITS-1:0] rs1Id = decompressed[15 +: REG_BITS];
   // NOTE: with single-port regfile, rs2 is read in a later cycle when
   // mem_rdata has already changed — so we read rs2Id from the LATCHED
   // instr, not from combinational decompressed.
`ifdef NRV_SINGLE_PORT_REGF
   wire [REG_BITS-1:0] rs2Id = instr       [20 +: REG_BITS];
`else
   wire [REG_BITS-1:0] rs2Id = decompressed[20 +: REG_BITS];
`endif

   (* onehot *)
   wire [7:0] funct3Is = 8'b00000001 << instr[14:12];

   wire [31:0] Uimm = {    instr[31],   instr[30:12], 12'b0};
   wire [31:0] Iimm = {{21{instr[31]}}, instr[30:20]};
   /* verilator lint_off UNUSED */
   wire [31:0] Simm = {{21{instr[31]}}, instr[30:25], instr[11:7]};
   wire [31:0] Bimm = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
   wire [31:0] Jimm = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};
   /* verilator lint_on UNUSED */

   wire isLoad    = (instr[6:2] == 5'b00000);
   wire isALUimm  = (instr[6:2] == 5'b00100);
   wire isAUIPC   = (instr[6:2] == 5'b00101);
   wire isStore   = (instr[6:2] == 5'b01000);
   wire isALUreg  = (instr[6:2] == 5'b01100);
   wire isLUI     = (instr[6:2] == 5'b01101);
   wire isBranch  = (instr[6:2] == 5'b11000);
   wire isJALR    = (instr[6:2] == 5'b11001);
   wire isJAL     = (instr[6:2] == 5'b11011);
   wire isSYSTEM  = (instr[6:2] == 5'b11100);

   wire isALU = isALUimm | isALUreg;

   // SYSTEM funct3=000 decodes strictly into MRET, WFI, or env-trap
   // (ECALL/EBREAK).  WFI (instr[31:20]=0x105) is a *hint* and is decoded
   // here as a distinct non-trapping instruction so it doesn't get
   // misrouted as EBREAK (0x00100073 is EBREAK; WFI is 0x10500073 which
   // shares instr[20]=1 with EBREAK and would otherwise land in the
   // is_env_trap bucket). Tier-0 behavior: NOP. Tier-1 behavior: stall
   // until wake (see wfi_stall below).
   wire is_sys_zero = isSYSTEM & funct3Is[0];
   wire is_mret     = is_sys_zero & (instr[31:20] == 12'h302);
   wire is_wfi      = is_sys_zero & (instr[31:20] == 12'h105);
   wire is_env_trap = is_sys_zero & ~is_mret & ~is_wfi;   // ECALL or EBREAK
   wire is_ecall    = is_env_trap & ~instr[20]; // 0x000 = ECALL, 0x001 = EBREAK

   /***************************************************************************/
   // Register file
   /***************************************************************************/

   reg [31:0] rs1;
   reg [31:0] rs2;
   reg [31:0] registerFile [NB_REGS-1:0];

`ifdef NRV_SINGLE_PORT_REGF
   // Single read port: address is muxed between S_WAIT_INSTR (rs1) and
   // S_FETCH_RS2 (rs2). Asynchronous read.
   wire [REG_BITS-1:0] rf_raddr = (state == S_WAIT_INSTR) ? rs1Id : rs2Id;
   wire [31:0]         rf_rdata = registerFile[rf_raddr];

   always @(posedge clk) begin
      if (state == S_WAIT_INSTR && !mem_rbusy) rs1 <= rf_rdata;
      if (state == S_FETCH_RS2)                rs2 <= rf_rdata;
      if (writeBack && rdId != 0)              registerFile[rdId] <= writeBackData;
   end
`else
   // Two read ports: both latched in S_WAIT_INSTR.
   always @(posedge clk) begin
      if (state == S_WAIT_INSTR && !mem_rbusy) begin
         rs1 <= registerFile[rs1Id];
         rs2 <= registerFile[rs2Id];
      end
      if (writeBack && rdId != 0) registerFile[rdId] <= writeBackData;
   end
`endif

   /***************************************************************************/
   // ALU
   /***************************************************************************/

   wire [31:0] aluIn1 = rs1;
   wire [31:0] aluIn2 = (isALUreg | isBranch) ? rs2 : Iimm;

`ifdef NRV_SHARED_ADDER
`ifndef NRV_SINGLE_PORT_REGF
   // NRV_SHARED_ADDER assumes serial rs1/rs2 read; require single-port.
   initial begin : shared_adder_needs_1p
      $display("ERROR: NRV_SHARED_ADDER requires NRV_SINGLE_PORT_REGF");
      $finish;
   end
`endif
   // One shared 32-bit adder replaces aluPlus, PCplusImm, loadstore_addr.
   // aluMinus (subtract/compare) stays separate — needed in parallel for
   // branch predicate evaluation.
   wire use_pc_add = isAUIPC | isJAL | isBranch;
   wire [31:0] add_a = use_pc_add ? {{(32-ADDR_WIDTH){1'b0}}, PC} : aluIn1;
   wire [31:0] add_b =
       isAUIPC  ? Uimm :
       isJAL    ? Jimm :
       isBranch ? Bimm :
       isStore  ? Simm :
       isALUreg ? rs2  :
                  Iimm ;  // Load, JALR, ALUimm (, SYSTEM: don't-care)
   wire [31:0] add_sum  = add_a + add_b;
   wire [31:0] aluPlus  = add_sum;
   wire [32:0] aluMinus = {1'b1, ~aluIn2} + {1'b0, aluIn1} + 33'b1;
`else
   wire [31:0] aluPlus  = aluIn1 + aluIn2;
   wire [32:0] aluMinus = {1'b1, ~aluIn2} + {1'b0, aluIn1} + 33'b1;
`endif
   wire        LT  = (aluIn1[31] ^ aluIn2[31]) ? aluIn1[31] : aluMinus[32];
   wire        LTU = aluMinus[32];
   wire        EQ  = (aluMinus[31:0] == 0);

   // Any shift (SLL/SRL/SRA) instruction
   wire isShiftOp = isALU & (funct3Is[1] | funct3Is[5]);

`ifdef NRV_SERIAL_SHIFT
   /*------------------------------------------------------------------*/
   /* Serial 1-bit/cycle shifter.                                      */
   /* Loaded in S_EXECUTE (aluWr & isShiftOp). Holds CPU in S_WAIT     */
   /* until shift_count reaches 0. Cost: +shamt cycles per shift.     */
   /* Area: saves ~2-3 kµm² vs barrel shifter + bit-reverse on Sky130. */
   /*------------------------------------------------------------------*/
   reg [31:0] shift_data;
   reg  [4:0] shift_count;
   reg        shift_is_left;
   reg        shift_is_arith;
   wire       shift_busy = |shift_count;

   always @(posedge clk) begin
      if (!reset) begin
         shift_count    <= 5'd0;
      end else if (aluWr & isShiftOp) begin
         shift_data     <= aluIn1;
         shift_count    <= aluIn2[4:0];
         shift_is_left  <= funct3Is[1];
`ifdef NRV_SRA
         shift_is_arith <= instr[30] & funct3Is[5];
`else
         shift_is_arith <= 1'b0;
`endif
      end else if (shift_busy) begin
         shift_data  <= shift_is_left
             ? {shift_data[30:0], 1'b0}
             : {shift_is_arith & shift_data[31], shift_data[31:1]};
         shift_count <= shift_count - 5'd1;
      end
   end

   wire [31:0] shifter    = shift_data;
   wire [31:0] leftshift  = shift_data;
`else
   /*------------------------------------------------------------------*/
   /* Default: barrel shifter (single 32-bit shift op + bit-reverse    */
   /* networks for left shift).                                        */
   /*------------------------------------------------------------------*/
   wire [31:0] shifter_in = funct3Is[1] ?
     {aluIn1[ 0], aluIn1[ 1], aluIn1[ 2], aluIn1[ 3], aluIn1[ 4], aluIn1[ 5],
      aluIn1[ 6], aluIn1[ 7], aluIn1[ 8], aluIn1[ 9], aluIn1[10], aluIn1[11],
      aluIn1[12], aluIn1[13], aluIn1[14], aluIn1[15], aluIn1[16], aluIn1[17],
      aluIn1[18], aluIn1[19], aluIn1[20], aluIn1[21], aluIn1[22], aluIn1[23],
      aluIn1[24], aluIn1[25], aluIn1[26], aluIn1[27], aluIn1[28], aluIn1[29],
      aluIn1[30], aluIn1[31]} : aluIn1;

`ifdef NRV_SRA
   /* verilator lint_off WIDTH */
   wire [31:0] shifter =
       $signed({instr[30] & aluIn1[31], shifter_in}) >>> aluIn2[4:0];
   /* verilator lint_on WIDTH */
`else
   /* verilator lint_off WIDTH */
   wire [31:0] shifter = {1'b0, shifter_in} >> aluIn2[4:0];
   /* verilator lint_on WIDTH */
`endif

   wire [31:0] leftshift = {
     shifter[ 0], shifter[ 1], shifter[ 2], shifter[ 3], shifter[ 4],
     shifter[ 5], shifter[ 6], shifter[ 7], shifter[ 8], shifter[ 9],
     shifter[10], shifter[11], shifter[12], shifter[13], shifter[14],
     shifter[15], shifter[16], shifter[17], shifter[18], shifter[19],
     shifter[20], shifter[21], shifter[22], shifter[23], shifter[24],
     shifter[25], shifter[26], shifter[27], shifter[28], shifter[29],
     shifter[30], shifter[31]};
`endif

   /***************************************************************************/

`ifdef NRV_M
   wire funcM    = instr[25];
   wire isDivide = isALUreg & funcM & instr[14];
   wire isMul    = isALUreg & funcM & ~instr[14];   // MUL/MULH/MULHSU/MULHU

   wire isMULH   = funct3Is[1];
   wire isMULHSU = funct3Is[2];

`ifdef NRV_SERIAL_MUL
   /*------------------------------------------------------------------*/
   /* Serial shift-add multiplier.                                     */
   /* Operates on absolute values, with final negation for signed ops. */
   /* Area: saves ~15-20 kµm² vs 33x33 parallel multiplier on Sky130.  */
   /*                                                                  */
   /*   NRV_RADIX4_MUL (define):                                       */
   /*     OFF → radix-2:  32 cycles, 1-bit/cycle, minimal logic.       */
   /*     ON  → radix-4 modified Booth: 16 cycles, 2-bits/cycle.       */
   /*           One 33-bit adder/subtractor + Booth decode.            */
   /*------------------------------------------------------------------*/
   wire mul_sign1 = aluIn1[31] & (isMULH | isMULHSU);
   wire mul_sign2 = aluIn2[31] &  isMULH;
   wire [31:0] mul_abs1 = mul_sign1 ? -aluIn1 : aluIn1;
   wire [31:0] mul_abs2 = mul_sign2 ? -aluIn2 : aluIn2;

   reg [63:0] mul_pm;      // {partial_product, multiplier/result}
   reg [31:0] mul_mcand;   // multiplicand (abs value)
   reg  [5:0] mul_count;   // iteration counter
   reg        mul_neg;     // apply final negation if set
   reg        mul_negate_pending;

`ifdef NRV_RADIX4_MUL
   /*--- Radix-4 modified Booth: 16+1 cycles, 2 bits/iteration --------*/
   /*                                                                  */
   /* Textbook radix-4 Booth recoding on UNSIGNED absolute values.     */
   /* We treat the partial product as a 33-bit signed accumulator      */
   /* (bit 32 = sign from Booth subtract) and shift the 65-bit         */
   /* {accumulator, multiplier} right by 2 each iteration.             */
   /*                                                                  */
   /*   {b1,b0,prev}  Action                                           */
   /*     000, 111     +0   (skip)                                     */
   /*     001, 010     +1×M                                            */
   /*     011          +2×M                                            */
   /*     100          −2×M                                            */
   /*     101, 110     −1×M                                            */
   /*                                                                  */
   /* After 16 iterations (32 multiplier bits), a carry fixup cycle    */
   /* handles the implicit 0 at bit 32.  If booth_prev is 1 after the  */
   /* last iteration, the Booth digit {0,0,1} = +1×M must be added     */
   /* to the accumulator.  Without this, unsigned multipliers with     */
   /* bit 31 set produce results off by M × 2^32.                     */
   /*                                                                  */
   /* Total: 16 (Booth) + 1 (fixup) + 0-1 (negate) = 17-18 cycles.   */
   /*------------------------------------------------------------------*/
   reg        mul_booth_prev;    // previous LSB for Booth recoding
   reg [32:0] mul_acc;           // 33-bit signed accumulator
   reg        mul_fixup;         // carry correction cycle pending

   wire [2:0] booth_bits = {mul_pm[1:0], mul_booth_prev};

   wire booth_p1 = (booth_bits == 3'b001) | (booth_bits == 3'b010);
   wire booth_p2 = (booth_bits == 3'b011);
   wire booth_m2 = (booth_bits == 3'b100);
   wire booth_m1 = (booth_bits == 3'b101) | (booth_bits == 3'b110);

   // 33-bit add/subtract (signed accumulator ± unsigned multiplicand)
   wire [32:0] booth_add1 = mul_acc + {1'b0, mul_mcand};
   wire [32:0] booth_add2 = mul_acc + {mul_mcand, 1'b0};
   wire [32:0] booth_sub1 = mul_acc - {1'b0, mul_mcand};
   wire [32:0] booth_sub2 = mul_acc - {mul_mcand, 1'b0};

   wire [32:0] booth_new_acc = booth_p1 ? booth_add1 :
                                booth_p2 ? booth_add2 :
                                booth_m1 ? booth_sub1 :
                                booth_m2 ? booth_sub2 :
                                           mul_acc;    // +0

   // Arithmetic right-shift by 2: new_acc[32] is the sign bit
   wire [32:0] booth_shifted_acc = {booth_new_acc[32], booth_new_acc[32],
                                    booth_new_acc[32:2]};
   wire [31:0] booth_shifted_lo  = {booth_new_acc[1:0], mul_pm[31:2]};

   wire mul_busy = (|mul_count) | mul_fixup | mul_negate_pending;

   always @(posedge clk) begin
      if (!reset) begin
         mul_count          <= 6'd0;
         mul_negate_pending <= 1'b0;
         mul_fixup          <= 1'b0;
      end else if (aluWr & isMul) begin
         mul_pm             <= {32'b0, mul_abs2};       // multiplier in low half
         mul_acc            <= 33'b0;                    // accumulator starts at 0
         mul_mcand          <= mul_abs1;
         mul_count          <= 6'd16;
         mul_neg            <= mul_sign1 ^ mul_sign2;
         mul_negate_pending <= 1'b0;
         mul_fixup          <= 1'b0;
         mul_booth_prev     <= 1'b0;
      end else if (|mul_count) begin
         mul_acc        <= booth_shifted_acc;
         mul_pm         <= {booth_shifted_acc[31:0], booth_shifted_lo};
         mul_booth_prev <= mul_pm[1];
         mul_count      <= mul_count - 6'd1;
         if (mul_count == 6'd1) mul_fixup <= 1'b1;
      end else if (mul_fixup) begin
         /* Carry correction: Booth recoding of an N-bit unsigned value    */
         /* needs an implicit 0 at bit N.  If booth_prev is 1, the final  */
         /* Booth digit is {0,0,1} = +1×M, so add M to the accumulator    */
         /* (equivalent to adding M × 2^32 to the 64-bit product).        */
         /* Also sync mul_pm[63:32] so mul_hi reads the correct value.    */
         if (mul_booth_prev) begin
            mul_acc <= mul_acc + {1'b0, mul_mcand};
            mul_pm  <= {mul_acc[31:0] + mul_mcand, mul_pm[31:0]};
         end else begin
            mul_pm  <= {mul_acc[31:0], mul_pm[31:0]};
         end
         mul_fixup          <= 1'b0;
         mul_negate_pending <= mul_neg;
      end else if (mul_negate_pending) begin
         mul_pm             <= -{mul_acc[31:0], mul_pm[31:0]};
         mul_negate_pending <= 1'b0;
      end
   end

`else
   /*--- Radix-2: 32 cycles, 1 bit/iteration, minimal logic -----------*/
   wire [32:0] mul_add = {1'b0, mul_pm[63:32]} + {1'b0, mul_mcand};
   wire [32:0] mul_new_upper = mul_pm[0] ? mul_add : {1'b0, mul_pm[63:32]};

   wire mul_busy = (|mul_count) | mul_negate_pending;

   always @(posedge clk) begin
      if (!reset) begin
         mul_count          <= 6'd0;
         mul_negate_pending <= 1'b0;
      end else if (aluWr & isMul) begin
         mul_pm             <= {32'b0, mul_abs2};
         mul_mcand          <= mul_abs1;
         mul_count          <= 6'd32;
         mul_neg            <= mul_sign1 ^ mul_sign2;
         mul_negate_pending <= 1'b0;
      end else if (|mul_count) begin
         mul_pm    <= {mul_new_upper, mul_pm[31:1]};
         mul_count <= mul_count - 6'd1;
         if (mul_count == 6'd1) mul_negate_pending <= mul_neg;
      end else if (mul_negate_pending) begin
         mul_pm             <= -mul_pm;
         mul_negate_pending <= 1'b0;
      end
   end
`endif

   wire [31:0] mul_lo = mul_pm[31:0];
   wire [31:0] mul_hi = mul_pm[63:32];
`else
   /*------------------------------------------------------------------*/
   /* Default: single-cycle 33x33 signed parallel multiplier.          */
   /*------------------------------------------------------------------*/
   wire sign1 = aluIn1[31] &  isMULH;
   wire sign2 = aluIn2[31] & (isMULH | isMULHSU);

   wire signed [32:0] signed1 = {sign1, aluIn1};
   wire signed [32:0] signed2 = {sign2, aluIn2};
   wire signed [63:0] multiply = signed1 * signed2;

   wire [31:0] mul_lo   = multiply[31:0];
   wire [31:0] mul_hi   = multiply[63:32];
   wire        mul_busy = 1'b0;
`endif

   reg [31:0] dividend;
   reg [62:0] divisor;
   reg [31:0] quotient;
   reg [31:0] quotient_msk;

   wire divstep_do      = (divisor <= {31'b0, dividend});
   wire [31:0] dividendN = divstep_do ? dividend - divisor[31:0] : dividend;
   wire [31:0] quotientN = divstep_do ? quotient | quotient_msk  : quotient;

   wire div_sign = ~instr[12] & (instr[13] ? aluIn1[31] :
                                 (aluIn1[31] != aluIn2[31]) & |aluIn2);

   always @(posedge clk) begin
      if (isDivide & aluWr) begin
         dividend     <= ~instr[12] & aluIn1[31] ? -aluIn1 : aluIn1;
         divisor      <= {(~instr[12] & aluIn2[31] ? -aluIn2 : aluIn2), 31'b0};
         quotient     <= 0;
         quotient_msk <= 32'h80000000;
      end else begin
         dividend     <= dividendN;
         divisor      <= divisor >> 1;
         quotient     <= quotientN;
         quotient_msk <= quotient_msk >> 1;
      end
   end

   reg [31:0] divResult;
   always @(posedge clk) divResult <= instr[13] ? dividendN : quotientN;

   wire [31:0] aluOut_muldiv =
      (  funct3Is[0]   ?  mul_lo : 32'b0) |
      ( |funct3Is[3:1] ?  mul_hi : 32'b0) |
      (  instr[14]     ?  (div_sign ? -divResult : divResult) : 32'b0);

   wire div_busy = |quotient_msk;
`else
   wire isDivide = 1'b0;
   wire isMul    = 1'b0;
   wire div_busy = 1'b0;
   wire mul_busy = 1'b0;
`endif

   /*---------------------------------------------------------------------*/
   /* aluBusy: OR of all multi-cycle units.                               */
   /*---------------------------------------------------------------------*/
`ifdef NRV_SERIAL_SHIFT
   wire aluBusy = div_busy | mul_busy | shift_busy;
`else
   wire aluBusy = div_busy | mul_busy;
`endif

   wire [31:0] aluOut_base =
     (funct3Is[0]  ? (instr[30] & instr[5] ? aluMinus[31:0] : aluPlus) : 32'b0) |
     (funct3Is[1]  ? leftshift                                         : 32'b0) |
     (funct3Is[2]  ? {31'b0, LT}                                       : 32'b0) |
     (funct3Is[3]  ? {31'b0, LTU}                                      : 32'b0) |
     (funct3Is[4]  ? aluIn1 ^ aluIn2                                   : 32'b0) |
     (funct3Is[5]  ? shifter                                           : 32'b0) |
     (funct3Is[6]  ? aluIn1 | aluIn2                                   : 32'b0) |
     (funct3Is[7]  ? aluIn1 & aluIn2                                   : 32'b0) ;

`ifdef NRV_M
   wire [31:0] aluOut = isALUreg & funcM ? aluOut_muldiv : aluOut_base;
`else
   wire [31:0] aluOut = aluOut_base;
`endif

   /***************************************************************************/
   // Branch predicate
   /***************************************************************************/

   wire predicate =
        funct3Is[0] &  EQ  |
        funct3Is[1] & !EQ  |
        funct3Is[4] &  LT  |
        funct3Is[5] & !LT  |
        funct3Is[6] &  LTU |
        funct3Is[7] & !LTU ;

   /***************************************************************************/
   // PC and branch target
   /***************************************************************************/

   reg  [ADDR_WIDTH-1:0] PC;
   assign pc_out = PC;
   reg  [31:2]           instr;

   wire [ADDR_WIDTH-1:0] PCplus2 = PC + 2;
   wire [ADDR_WIDTH-1:0] PCplus4 = PC + 4;
   wire [ADDR_WIDTH-1:0] PCinc   = long_instr ? PCplus4 : PCplus2;

`ifdef NRV_SHARED_ADDER
   wire [ADDR_WIDTH-1:0] PCplusImm      = add_sum[ADDR_WIDTH-1:0];
   wire [ADDR_WIDTH-1:0] loadstore_addr = add_sum[ADDR_WIDTH-1:0];
`else
   wire [ADDR_WIDTH-1:0] PCplusImm = PC + (instr[3] ? Jimm[ADDR_WIDTH-1:0] :
                                           instr[4] ? Uimm[ADDR_WIDTH-1:0] :
                                                      Bimm[ADDR_WIDTH-1:0]);

   wire [ADDR_WIDTH-1:0] loadstore_addr = rs1[ADDR_WIDTH-1:0] +
                   (instr[5] ? Simm[ADDR_WIDTH-1:0] : Iimm[ADDR_WIDTH-1:0]);
`endif

   /* verilator lint_off WIDTH */
   assign mem_addr = (state == S_WAIT_INSTR || state == S_FETCH_INSTR) ?
                     (fetch_second_half ? {PCplus4[ADDR_WIDTH-1:2], 2'b00}
                                        : {PC     [ADDR_WIDTH-1:2], 2'b00})
                     : loadstore_addr;
   /* verilator lint_on WIDTH */

   /***************************************************************************/
   // Interrupt & trap logic, CSRs
   /***************************************************************************/

   // Non-sticky IRQ: source must hold request until accepted.
   wire interrupt          = interrupt_request & mstatus & ~mcause;
   wire interrupt_accepted = interrupt      & (state == S_EXECUTE);
   wire env_trap_accepted  = is_env_trap    & (state == S_EXECUTE) & ~mcause;

   // NMI: bypasses MIE but still blocked by mcause (prevents nesting).
   wire nmi_accepted       = nmi         & ~mcause & (state == S_EXECUTE);

   // Debug halt: bypasses MIE AND mcause — can interrupt even an ISR.
   // Looks like EBREAK to the stub (mcause = 3).
   // The dbg_halt_mask prevents re-triggering: set on acceptance,
   // cleared on mret.  Cost: 1 FF + 2 gates.
   reg dbg_halt_mask;
   wire dbg_halt_accepted  = dbg_halt_req & ~dbg_halt_mask & (state == S_EXECUTE);

   wire trap_entry         = interrupt_accepted | env_trap_accepted
                           | nmi_accepted       | dbg_halt_accepted;

   // WFI (Tier 1) — stall S_EXECUTE until a wake event arrives. Wake is the
   // raw union of asynchronous sources, deliberately ungated by MIE/mcause
   // (spec: WFI must wake on pending interrupts even when MIE=0; if the
   // interrupt isn't actually accepted, execution simply continues past
   // the WFI). The normal trap_entry path above fires on the same cycle
   // when the source is accepted, so mepc ends up capturing PC_new (WFI+4)
   // via the async-trap branch — i.e., the handler returns *past* WFI.
   wire wfi_wake  = interrupt_request | nmi | dbg_halt_req;
   wire wfi_stall = is_wfi & (state == S_EXECUTE) & ~wfi_wake;

   wire interrupt_return   = is_mret;

   reg [ADDR_WIDTH-1:0] mepc;
   reg                  mstatus;       // MIE
   reg                  mcause;        // 1 = in handler (lock bit)
   reg                  mcause_irq;    // 1 = IRQ, 0 = env trap
   reg                  mcause_ecall;  // when !irq: 1 = ECALL, 0 = EBREAK
   reg                  mcause_nmi;    // 1 = NMI

`ifdef NRV_PERF_CSR
   reg [63:0] cycles;
   reg [63:0] instret;
   always @(posedge clk) cycles <= cycles + 1;

   /* Instruction retirement: fires once per completed instruction.       */
   /*   - Single-cycle instrs complete in S_EXECUTE (when !needToWait).   */
   /*   - Multi-cycle instrs (load/store/div/serial-shift/serial-mul)     */
   /*     complete when S_WAIT finishes.                                  */
   /*   - Traps in S_EXECUTE count as retired (RISC-V convention).        */
   wire instr_retired =
        (state == S_EXECUTE && !needToWait && !wfi_stall)            |
        (state == S_EXECUTE && needToWait && trap_entry)             |
        (state == S_WAIT    && !aluBusy && !mem_rbusy && !mem_wbusy) ;
   always @(posedge clk) begin
      if (!reset) instret <= 64'd0;
      else if (instr_retired) instret <= instret + 64'd1;
   end
`endif

   wire sel_mstatus  = (instr[31:20] == 12'h300);
   wire sel_mepc     = (instr[31:20] == 12'h341);
   wire sel_mcause   = (instr[31:20] == 12'h342);
`ifdef NRV_PERF_CSR
   wire sel_cycles   = (instr[31:20] == 12'hC00);
   wire sel_cyclesh  = (instr[31:20] == 12'hC80);
   wire sel_instret  = (instr[31:20] == 12'hC02);
   wire sel_instreth = (instr[31:20] == 12'hC82);
`endif

   // mcause read: RV-standard format.
   //   locked + irq           -> 0x8000_000B  (ext irq, code 11)
   //   locked + nmi           -> 0x8000_0000  (NMI, implementation-defined, code 0)
   //   locked + env + ECALL   -> 0x0000_000B  (M-mode env call, code 11)
   //   locked + env + EBREAK  -> 0x0000_0003  (breakpoint, code 3)
   //   not locked             -> 0
   // Note: dbg_halt reports mcause=3 (same as EBREAK) so the ROM stub
   //       handles it identically to a software breakpoint.
   wire [31:0] mcause_read =
        !mcause       ? 32'h0 :
         mcause_nmi   ? 32'h80000000 :
         mcause_irq   ? 32'h8000000B :
         mcause_ecall ? 32'h0000000B :
                        32'h00000003;

   /* verilator lint_off WIDTH */
   wire [31:0] CSR_read =
     (sel_mstatus ? {28'b0, mstatus, 3'b0}       : 32'b0) |
     (sel_mepc    ? mepc                         : 32'b0) |
     (sel_mcause  ? mcause_read                  : 32'b0)
`ifdef NRV_PERF_CSR
     |
     (sel_cycles   ? cycles[31:0]                 : 32'b0) |
     (sel_cyclesh  ? cycles[63:32]                : 32'b0) |
     (sel_instret  ? instret[31:0]               : 32'b0) |
     (sel_instreth ? instret[63:32]              : 32'b0)
`endif
     ;
   /* verilator lint_on WIDTH */

   wire [31:0] CSR_modifier = instr[14] ? {27'd0, instr[19:15]} : rs1;

   wire [31:0] CSR_write = (instr[13:12] == 2'b10) ?  CSR_modifier | CSR_read  :
                           (instr[13:12] == 2'b11) ? ~CSR_modifier & CSR_read  :
                                                     CSR_modifier ;

   wire csr_wr_en = isSYSTEM & (instr[14:12] != 3'b000) & (state == S_EXECUTE);

   // mstatus: reset=0, CSR-writable
   always @(posedge clk) begin
      if (!reset)                          mstatus <= 1'b0;
      else if (csr_wr_en & sel_mstatus)    mstatus <= CSR_write[3];
   end

   // mepc: written by HW on trap entry, by software via CSR otherwise.
   // (HW write takes priority — they never coincide in practice.)
   always @(posedge clk) begin
      if (trap_entry) begin
         /* verilator lint_off WIDTH */
         // Asynchronous traps (IRQ, NMI, dbg_halt) save PC_new (the
         // instruction that was *about* to execute). Synchronous traps
         // (EBREAK/ECALL) save PC (the trapping instruction itself).
         mepc <= (interrupt_accepted | nmi_accepted | dbg_halt_accepted)
                 ? PC_new : PC;
         /* verilator lint_on WIDTH */
      end else if (csr_wr_en & sel_mepc) begin
         mepc <= CSR_write[ADDR_WIDTH-1:0];
      end
   end

   // mcause / mcause_irq / mcause_ecall / mcause_nmi
   always @(posedge clk) begin
      if (!reset) begin
         mcause       <= 1'b0;
         mcause_irq   <= 1'b0;
         mcause_ecall <= 1'b0;
         mcause_nmi   <= 1'b0;
      end else if (trap_entry) begin
         mcause       <= 1'b1;
         mcause_irq   <= interrupt_accepted;       // 1=IRQ, 0=env-trap
         mcause_ecall <= env_trap_accepted & is_ecall; // ECALL vs EBREAK
         mcause_nmi   <= nmi_accepted;
      end else if (interrupt_return & (state == S_EXECUTE)) begin
         mcause       <= 1'b0;
      end
   end

   // dbg_halt_mask: prevents re-triggering of dbg_halt_req while the
   // debug stub is executing.  Set on acceptance, cleared on mret.
   always @(posedge clk) begin
      if (!reset)
         dbg_halt_mask <= 1'b0;
      else if (dbg_halt_accepted)
         dbg_halt_mask <= 1'b1;
      else if (interrupt_return & (state == S_EXECUTE))
         dbg_halt_mask <= 1'b0;
   end

   /***************************************************************************/
   // Write-back mux
   /***************************************************************************/

   /* verilator lint_off WIDTH */
   wire [31:0] writeBackData =
      (isSYSTEM         ? CSR_read  : 32'b0) |
      (isLUI            ? Uimm      : 32'b0) |
      (isALU            ? aluOut    : 32'b0) |
      (isAUIPC          ? PCplusImm : 32'b0) |
      (isJALR | isJAL   ? PCinc     : 32'b0) |
      (isLoad           ? LOAD_data : 32'b0);
   /* verilator lint_on WIDTH */

   /***************************************************************************/
   // LOAD / STORE
   /***************************************************************************/

   wire mem_byteAccess     = instr[13:12] == 2'b00;
   wire mem_halfwordAccess = instr[13:12] == 2'b01;

   wire LOAD_sign =
        !instr[14] & (mem_byteAccess ? LOAD_byte[7] : LOAD_halfword[15]);

   wire [31:0] LOAD_data =
         mem_byteAccess     ? {{24{LOAD_sign}},     LOAD_byte} :
         mem_halfwordAccess ? {{16{LOAD_sign}}, LOAD_halfword} :
                              mem_rdata;

   wire [15:0] LOAD_halfword =
               loadstore_addr[1] ? mem_rdata[31:16] : mem_rdata[15:0];

   wire  [7:0] LOAD_byte =
               loadstore_addr[0] ? LOAD_halfword[15:8] : LOAD_halfword[7:0];

   assign mem_wdata[ 7: 0] = rs2[7:0];
   assign mem_wdata[15: 8] = loadstore_addr[0] ? rs2[7:0]  : rs2[15: 8];
   assign mem_wdata[23:16] = loadstore_addr[1] ? rs2[7:0]  : rs2[23:16];
   assign mem_wdata[31:24] = loadstore_addr[0] ? rs2[7:0]  :
                             loadstore_addr[1] ? rs2[15:8] : rs2[31:24];

   wire [3:0] STORE_wmask =
        mem_byteAccess ?
           (loadstore_addr[1] ? (loadstore_addr[0] ? 4'b1000 : 4'b0100)
                              : (loadstore_addr[0] ? 4'b0010 : 4'b0001)) :
        mem_halfwordAccess ?
           (loadstore_addr[1] ? 4'b1100 : 4'b0011) :
        4'b1111;

   /***************************************************************************/
   // Unaligned fetch + RVC decompression
   /***************************************************************************/

   reg [ADDR_WIDTH-1:2] cached_addr;
   reg           [31:0] cached_data;

   wire current_cache_hit = cached_addr == PC    [ADDR_WIDTH-1:2];
   wire    next_cache_hit = cached_addr == PC_new[ADDR_WIDTH-1:2];

   wire current_unaligned_long = &cached_mem [17:16] & PC    [1];
   wire    next_unaligned_long = &cached_data[17:16] & PC_new[1];

   reg fetch_second_half;
   reg long_instr;

   // Does the newly fetched instruction use rs2? (skip FETCH_RS2 if not)
   wire [4:0] dec_opcode = decompressed[6:2];
   wire       uses_rs2 = (dec_opcode == 5'b01000)   // STORE
                       | (dec_opcode == 5'b01100)   // ALUreg
                       | (dec_opcode == 5'b11000);  // BRANCH

   wire [31:0] cached_mem   = current_cache_hit ? cached_data : mem_rdata;
   wire [31:0] decomp_input = PC[1] ? {mem_rdata[15:0], cached_mem[31:16]}
                                    : cached_mem;
   wire [31:0] decompressed;

   decompressor _decomp (.c(decomp_input), .d(decompressed));

   /***************************************************************************/
   // FSM
   /***************************************************************************/

`ifdef NRV_SINGLE_PORT_REGF
   localparam STATE_W = 3;
   localparam [STATE_W-1:0] S_FETCH_INSTR = 3'd0;
   localparam [STATE_W-1:0] S_WAIT_INSTR  = 3'd1;
   localparam [STATE_W-1:0] S_FETCH_RS2   = 3'd2;
   localparam [STATE_W-1:0] S_EXECUTE     = 3'd3;
   localparam [STATE_W-1:0] S_WAIT        = 3'd4;
`else
   localparam STATE_W = 2;
   localparam [STATE_W-1:0] S_FETCH_INSTR = 2'd0;
   localparam [STATE_W-1:0] S_WAIT_INSTR  = 2'd1;
   localparam [STATE_W-1:0] S_EXECUTE     = 2'd2;
   localparam [STATE_W-1:0] S_WAIT        = 2'd3;
`endif

   reg [STATE_W-1:0] state;
   reg               skip_fetch;

   wire writeBack =
        ~(isBranch | isStore) & (state == S_EXECUTE || state == S_WAIT);

   assign mem_rstrb = (state == S_EXECUTE && isLoad) || state == S_FETCH_INSTR;
   assign mem_wmask = {4{(state == S_EXECUTE) & isStore}} & STORE_wmask;

   wire aluWr = (state == S_EXECUTE) & isALU;

   wire jumpToPCplusImm = isJAL | (isBranch & predicate);

`ifdef NRV_SERIAL_SHIFT
   wire isShift_wait = isShiftOp;
`else
   wire isShift_wait = 1'b0;
`endif
`ifdef NRV_SERIAL_MUL
   wire isMul_wait = isMul;
`else
   wire isMul_wait = 1'b0;
`endif

   wire needToWait = isLoad | isStore | isDivide | isShift_wait | isMul_wait;

   /* verilator lint_off WIDTH */
   wire [ADDR_WIDTH-1:0] PC_new =
        isJALR           ? {aluPlus[ADDR_WIDTH-1:1], 1'b0} :
        jumpToPCplusImm  ? PCplusImm                       :
        interrupt_return ? mepc                            :
                           PCinc;
   /* verilator lint_on WIDTH */

   always @(posedge clk) begin
      if (!reset) begin
         state             <= S_WAIT;
         PC                <= {ADDR_WIDTH{1'b0}};
         cached_addr       <= {(ADDR_WIDTH-2){1'b1}};
         fetch_second_half <= 1'b0;
         skip_fetch        <= 1'b0;
      end else begin
         case (state)

            S_WAIT_INSTR: begin
               if (!mem_rbusy) begin
                  if (~current_cache_hit | fetch_second_half) begin
                     cached_addr <= mem_addr[ADDR_WIDTH-1:2];
                     cached_data <= mem_rdata;
                  end

                  instr      <= decompressed[31:2];
                  long_instr <= &decomp_input[1:0];

                  if (current_unaligned_long & ~fetch_second_half) begin
                     fetch_second_half <= 1'b1;
                     state             <= S_FETCH_INSTR;
                  end else begin
                     fetch_second_half <= 1'b0;
`ifdef NRV_SINGLE_PORT_REGF
                     // Only detour through FETCH_RS2 if rs2 is needed.
                     state             <= uses_rs2 ? S_FETCH_RS2 : S_EXECUTE;
`else
                     state             <= S_EXECUTE;
`endif
                  end
               end
            end

`ifdef NRV_SINGLE_PORT_REGF
            S_FETCH_RS2: begin
               state <= S_EXECUTE;
            end
`endif

            S_EXECUTE: begin
               if (wfi_stall) begin
                  // Tier-1 WFI: hold PC and state until wake. Memory bus
                  // goes quiet (mem_rstrb=0, mem_wmask=0 — WFI is a
                  // SYSTEM-class instruction, not a load/store/fetch).
                  // A wake event is handled on the very next cycle:
                  // either via trap_entry (accepted IRQ/NMI/dbg_halt) or
                  // by falling through to PC <= PC_new = WFI+4.
               end else if (trap_entry) begin
                  PC         <= MTVEC_ADDR;
                  skip_fetch <= 1'b0;
                  // env_trap never waits (not a load/store/divide);
                  // irq can coincide with a needToWait instr in flight.
                  state      <= (needToWait & interrupt_accepted)
                                ? S_WAIT : S_FETCH_INSTR;
               end else begin
                  PC <= PC_new;

                  skip_fetch        <= next_cache_hit & ~next_unaligned_long;
                  fetch_second_half <= next_cache_hit &  next_unaligned_long;

                  state <= needToWait ? S_WAIT :
                           (next_cache_hit & ~next_unaligned_long)
                              ? S_WAIT_INSTR : S_FETCH_INSTR;
               end
            end

            S_WAIT: begin
               if (!aluBusy & !mem_rbusy & !mem_wbusy)
                  state <= skip_fetch ? S_WAIT_INSTR : S_FETCH_INSTR;
            end

            default: begin // S_FETCH_INSTR
               state <= S_WAIT_INSTR;
            end
         endcase
      end
   end

`ifdef BENCH
   integer i;
   initial begin
`ifdef NRV_PERF_CSR
      cycles  = 0;
      instret = 0;
`endif
      for (i = 0; i < NB_REGS; i = i + 1) registerFile[i] = 0;
   end
`endif

endmodule

/*****************************************************************************/
// RVC decompressor (unchanged from upstream Gracilis)
/*****************************************************************************/

module decompressor(
   input  wire [31:0] c,
   output reg  [31:0] d
);

   localparam illegal = 32'h00000000;
   localparam unknown = 32'h00000000;

   wire [4:0] rcl = {2'b01, c[4:2]};
   wire [4:0] rch = {2'b01, c[9:7]};
   wire [4:0] rwl = c[ 6:2];
   wire [4:0] rwh = c[11:7];

   localparam x0 = 5'b00000;
   localparam x1 = 5'b00001;
   localparam x2 = 5'b00010;

   wire [4:0] shiftImm = c[6:2];

   wire [11:0] addi4spnImm = {2'b00, c[10:7], c[12:11], c[5], c[6], 2'b00};
   wire [11:0]     lwswImm = {5'b00000, c[5], c[12:10], c[6], 2'b00};
   wire [11:0]     lwspImm = {4'b0000, c[3:2], c[12], c[6:4], 2'b00};
   wire [11:0]     swspImm = {4'b0000, c[8:7], c[12:9], 2'b00};
   wire [11:0] addi16spImm = {{ 3{c[12]}}, c[4:3], c[5], c[2], c[6], 4'b0000};
   wire [11:0]      addImm = {{ 7{c[12]}}, c[6:2]};

   /* verilator lint_off UNUSED */
   wire [12:0] bImm   = {{ 5{c[12]}}, c[6:5], c[2], c[11:10], c[4:3], 1'b0};
   wire [20:0] jalImm = {{10{c[12]}}, c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3], 1'b0};
   wire [31:0] luiImm = {{15{c[12]}}, c[6:2], 12'b0};
   /* verilator lint_on UNUSED */

   always @* casez (c[15:0])
      16'b???___????????_???_11 : d = c;

/* verilator lint_off CASEOVERLAP */
      16'b000___00000000_000_00 : d = illegal;
      16'b000___????????_???_00 : d = {     addi4spnImm,              x2, 3'b000,                 rcl, 7'b00100_11};
/* verilator lint_on CASEOVERLAP */

      16'b010_???_???_??_???_00 : d = {         lwswImm,             rch, 3'b010,                 rcl, 7'b00000_11};
      16'b110_???_???_??_???_00 : d = {   lwswImm[11:5],        rcl, rch, 3'b010,        lwswImm[4:0], 7'b01000_11};

      16'b000_???_???_??_???_01 : d = {          addImm,             rwh, 3'b000,                 rwh, 7'b00100_11};
      16'b001____???????????_01 : d = {    jalImm[20], jalImm[10:1], jalImm[11], jalImm[19:12],   x1, 7'b11011_11};
      16'b010__?_?????_?????_01 : d = {          addImm,              x0, 3'b000,                 rwh, 7'b00100_11};
      16'b011__?_00010_?????_01 : d = {     addi16spImm,             rwh, 3'b000,                 rwh, 7'b00100_11};
      16'b011__?_?????_?????_01 : d = {   luiImm[31:12],                                          rwh, 7'b01101_11};
      16'b100_?_00_???_?????_01 : d = {      7'b0000000,   shiftImm, rch, 3'b101,                 rch, 7'b00100_11};
      16'b100_?_01_???_?????_01 : d = {      7'b0100000,   shiftImm, rch, 3'b101,                 rch, 7'b00100_11};
      16'b100_?_10_???_?????_01 : d = {          addImm,             rch, 3'b111,                 rch, 7'b00100_11};
      16'b100_011_???_00_???_01 : d = {      7'b0100000,        rcl, rch, 3'b000,                 rch, 7'b01100_11};
      16'b100_011_???_01_???_01 : d = {      7'b0000000,        rcl, rch, 3'b100,                 rch, 7'b01100_11};
      16'b100_011_???_10_???_01 : d = {      7'b0000000,        rcl, rch, 3'b110,                 rch, 7'b01100_11};
      16'b100_011_???_11_???_01 : d = {      7'b0000000,        rcl, rch, 3'b111,                 rch, 7'b01100_11};
      16'b101____???????????_01 : d = {    jalImm[20], jalImm[10:1], jalImm[11], jalImm[19:12],   x0, 7'b11011_11};
      16'b110__???_???_?????_01 : d = {bImm[12], bImm[10:5],      x0, rch, 3'b000, bImm[4:1], bImm[11], 7'b11000_11};
      16'b111__???_???_?????_01 : d = {bImm[12], bImm[10:5],      x0, rch, 3'b001, bImm[4:1], bImm[11], 7'b11000_11};

      16'b000__?_?????_?????_10 : d = {      7'b0000000,   shiftImm, rwh, 3'b001,                 rwh, 7'b00100_11};
      16'b010__?_?????_?????_10 : d = {         lwspImm,              x2, 3'b010,                 rwh, 7'b00000_11};
      16'b100__0_?????_00000_10 : d = {12'b000000000000,             rwh, 3'b000,                  x0, 7'b11001_11};
      16'b100__0_?????_?????_10 : d = {      7'b0000000,        rwl,  x0, 3'b000,                 rwh, 7'b01100_11};
      16'b100__1_00000_00000_10 : d = 32'h00100073; // c.ebreak -> ebreak
      16'b100__1_?????_00000_10 : d = {12'b000000000000,             rwh, 3'b000,                  x1, 7'b11001_11};
      16'b100__1_?????_?????_10 : d = {      7'b0000000,        rwl, rwh, 3'b000,                 rwh, 7'b01100_11};
      16'b110__?_?????_?????_10 : d = {   swspImm[11:5],        rwl,  x2, 3'b010,        swspImm[4:0], 7'b01000_11};

      default                   : d = unknown;
   endcase
endmodule
