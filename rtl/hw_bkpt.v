/*---------------------------------------------------------------------------
 * hw_bkpt.v — Hardware breakpoint unit (memory-mapped).
 *
 * Compares the CPU's PC against N programmable address registers.
 * When a match is found and the breakpoint is enabled, `halt_req`
 * is asserted for one cycle, causing the core to trap into the
 * debug stub (same path as EBREAK / dbg_halt_req).
 *
 * Register map (8 registers in a 32-byte sub-slot):
 *
 *   reg_addr  Offset   Name          Description
 *     0       0x00     BP_CTRL       [N-1:0] enable bits (R/W)
 *     1       0x04     BP_HIT        [N-1:0] hit bits (R/W1C — write 1 to clear)
 *     2       0x08     BP_COUNT      [7:0] number of breakpoints (RO)
 *     3       0x0C     (reserved)
 *     4       0x10     BP_ADDR[0]    breakpoint 0 address (R/W)
 *     5       0x14     BP_ADDR[1]    breakpoint 1 address (R/W)
 *     6       0x18     BP_ADDR[2]    breakpoint 2 address (R/W)
 *     7       0x1C     BP_ADDR[3]    breakpoint 3 address (R/W)
 *
 * Parameters:
 *   N         : number of breakpoint slots (default 4, max 4)
 *   ADDR_WIDTH: width of PC / address (must match core)
 *
 * Typical SoC wiring (32-byte sub-slot):
 *   .pc_in    (core_pc_out),
 *   .halt_req (bp_halt),
 *   .sel      (sel_bkpt),           // sub-slot select
 *   .reg_addr (mem_addr[4:2]),      // 3-bit word offset
 *   .wdata    (mem_wdata),
 *   .wmask    (mem_wmask),
 *   .rstrb    (mem_rstrb),
 *   .rdata    (bp_rdata)
 *---------------------------------------------------------------------------*/

module hw_bkpt #(
    parameter N          = 4,
    parameter ADDR_WIDTH = 16
)(
    input                    clk,
    input                    resetn,

    // PC from core
    input  [ADDR_WIDTH-1:0]  pc_in,

    // Halt output (active-high, one-cycle pulse per hit)
    output reg               halt_req,

    // Memory-mapped register interface
    input                    sel,           // sub-slot select
    input  [2:0]             reg_addr,      // word offset (bits [4:2])
    input  [31:0]            wdata,
    input  [3:0]             wmask,
    input                    rstrb,
    output reg [31:0]        rdata
);

    /*---------------------------------------------------------------*/
    /* Breakpoint address registers + enable/hit                     */
    /*---------------------------------------------------------------*/
    reg [ADDR_WIDTH-1:0] bp_addr [0:N-1];
    reg [N-1:0]          bp_en;
    reg [N-1:0]          bp_hit;

    /*---------------------------------------------------------------*/
    /* PC match logic                                                */
    /*---------------------------------------------------------------*/
    wire [N-1:0] match;
    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : bp_cmp
            assign match[g] = bp_en[g] & (pc_in == bp_addr[g]);
        end
    endgenerate

    wire any_match = |match;

    /*---------------------------------------------------------------*/
    /* Register read mux                                             */
    /*---------------------------------------------------------------*/
    /* verilator lint_off WIDTHTRUNC */
    always @(*) begin
        rdata = 32'b0;
        if (sel & rstrb) begin
            case (reg_addr)
                3'd0: rdata = {{(32-N){1'b0}}, bp_en};
                3'd1: rdata = {{(32-N){1'b0}}, bp_hit};
                3'd2: rdata = N;
                // 3'd3: reserved
                3'd4: rdata = {{(32-ADDR_WIDTH){1'b0}}, bp_addr[0]};
                3'd5: rdata = (N > 1) ? {{(32-ADDR_WIDTH){1'b0}}, bp_addr[1]} : 32'b0;
                3'd6: rdata = (N > 2) ? {{(32-ADDR_WIDTH){1'b0}}, bp_addr[2]} : 32'b0;
                3'd7: rdata = (N > 3) ? {{(32-ADDR_WIDTH){1'b0}}, bp_addr[3]} : 32'b0;
            endcase
        end
    end
    /* verilator lint_on WIDTHTRUNC */

    /*---------------------------------------------------------------*/
    /* Register write + halt generation                              */
    /*---------------------------------------------------------------*/
    integer i;
    always @(posedge clk) begin
        if (!resetn) begin
            bp_en    <= {N{1'b0}};
            bp_hit   <= {N{1'b0}};
            halt_req <= 1'b0;
            for (i = 0; i < N; i = i + 1)
                bp_addr[i] <= {ADDR_WIDTH{1'b0}};
        end else begin
            // Halt on PC match (one-cycle pulse)
            halt_req <= any_match;
            bp_hit   <= bp_hit | match;

            // Register writes
            if (sel & |wmask) begin
                case (reg_addr)
                    3'd0: bp_en  <= wdata[N-1:0];          // BP_CTRL
                    3'd1: bp_hit <= bp_hit & ~wdata[N-1:0]; // BP_HIT (W1C)
                    // 3'd2: BP_COUNT is read-only
                    // 3'd3: reserved
                    3'd4: bp_addr[0] <= wdata[ADDR_WIDTH-1:0];
                    3'd5: if (N > 1) bp_addr[1] <= wdata[ADDR_WIDTH-1:0];
                    3'd6: if (N > 2) bp_addr[2] <= wdata[ADDR_WIDTH-1:0];
                    3'd7: if (N > 3) bp_addr[3] <= wdata[ADDR_WIDTH-1:0];
                endcase
            end
        end
    end

endmodule
