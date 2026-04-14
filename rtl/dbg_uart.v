/*---------------------------------------------------------------------------
 * dbg_uart.v — Minimal debug UART: auto-baud (0x55), 8N1, break detect.
 *
 * Auto-baud calibration:
 *   After reset the UART waits for a 0x55 byte ('U'). On the wire
 *   (LSB-first, 8N1) this produces evenly-spaced falling edges:
 *
 *     IDLE  S  D0 D1 D2 D3 D4 D5 D6 D7 STOP
 *      1    0   1  0  1  0  1  0  1  0   1
 *           ↓      ↓     ↓     ↓     ↓         ← 5 falling edges
 *           |←--------  8 bit periods  -------→|
 *
 *   The counter between the 1st and 5th falling edge is divided by 8
 *   (right-shift 3) to derive the bit period. The 0x55 byte is consumed
 *   and NOT delivered to the CPU.
 *
 * Break detection (for Ctrl-C / debug halt):
 *   After baud lock, if RX stays low for ≥12 bit-periods (longer than
 *   any valid frame) `brk` pulses high for one clock cycle.
 *
 * CPU interface:
 *   wr_data / wr_en   — write a byte to TX (check tx_ready first)
 *   rd_data / rd_valid — received byte available (cleared by rd_en)
 *   locked             — baud rate acquired
 *   brk                — break detected (active one cycle)
 *---------------------------------------------------------------------------*/

module dbg_uart (
    input            clk,
    input            resetn,

    // Serial pins
    input            rx_pin,
    output reg       tx_pin,

    // CPU-side interface
    input      [7:0] wr_data,
    input            wr_en,        // pulse: enqueue TX byte
    output           tx_ready,     // TX idle, safe to write

    output reg [7:0] rd_data,
    output reg       rd_valid,     // byte available
    input            rd_en,        // pulse: consume byte

    // Status
    output           brk,          // break detected (one-cycle pulse)
    output           locked        // baud rate acquired
);

    /*---------------------------------------------------------------*/
    /* RX synchroniser (2-FF) + edge detect                         */
    /*---------------------------------------------------------------*/
    reg [1:0] rx_sync;
    reg       rx_d;
    always @(posedge clk) begin
        rx_sync <= {rx_sync[0], rx_pin};
        rx_d    <= rx_sync[1];
    end
    wire rx      = rx_sync[1];
    wire rx_fall = rx_d & ~rx;

    /*---------------------------------------------------------------*/
    /* Baud rate register                                            */
    /*---------------------------------------------------------------*/
    reg [9:0]  baud_div;           // clocks per bit period (max 1023)
    reg        baud_locked;
    assign locked = baud_locked;

    /*---------------------------------------------------------------*/
    /* Auto-baud calibration                                         */
    /*---------------------------------------------------------------*/
    reg [12:0] cal_cnt;            // clock counter (up to 8 × 1023)
    reg [2:0]  cal_edge;           // falling-edge counter (1 .. 5)
    reg        cal_active;

    /*---------------------------------------------------------------*/
    /* RX datapath                                                   */
    /*---------------------------------------------------------------*/
    reg [9:0]  rx_timer;
    reg [3:0]  rx_bit;             // 0 = start verify, 1–8 = data, 9 = stop
    reg [7:0]  rx_sr;
    reg        rx_busy;

    /*---------------------------------------------------------------*/
    /* TX datapath                                                   */
    /*---------------------------------------------------------------*/
    reg [9:0]  tx_timer;
    reg [3:0]  tx_bit;             // 0–7 = data, 8 = stop, 9 = done
    reg [7:0]  tx_sr;
    reg        tx_busy;
    assign tx_ready = baud_locked & ~tx_busy;

    /*---------------------------------------------------------------*/
    /* Break detector                                                */
    /*---------------------------------------------------------------*/
    reg [9:0]  brk_timer;          // counts clocks within one bit period
    reg [3:0]  brk_cnt;            // counts consecutive low bit periods
    wire       brk_now = (brk_cnt == 4'd12);
    reg        brk_prev;
    assign brk = brk_now & ~brk_prev;   // rising-edge pulse

    /*---------------------------------------------------------------*/
    /* Main sequential logic                                         */
    /*---------------------------------------------------------------*/
    always @(posedge clk) begin
        if (!resetn) begin
            rx_sync     <= 2'b11;
            rx_d        <= 1'b1;
            baud_locked <= 1'b0;
            cal_active  <= 1'b0;
            rx_busy     <= 1'b0;
            tx_busy     <= 1'b0;
            tx_pin      <= 1'b1;          // idle high
            rd_valid    <= 1'b0;
            brk_cnt     <= 4'd0;
            brk_timer   <= 10'd0;
            brk_prev    <= 1'b0;
        end else begin

            brk_prev <= brk_now;

            /* RX read clears valid */
            if (rd_en & rd_valid)
                rd_valid <= 1'b0;

            /*===================================================*/
            /* AUTO-BAUD CALIBRATION                              */
            /*===================================================*/
            if (!baud_locked) begin
                if (!cal_active) begin
                    // Wait for first falling edge (start bit of 0x55)
                    if (rx_fall) begin
                        cal_active <= 1'b1;
                        cal_cnt    <= 13'd0;
                        cal_edge   <= 3'd1;
                    end
                end else begin
                    cal_cnt <= cal_cnt + 1;
                    if (rx_fall) begin
                        if (cal_edge == 3'd4) begin
                            // 5th falling edge → 8 bit periods elapsed
                            baud_div    <= cal_cnt[12:3]; // count / 8
                            baud_locked <= 1'b1;
                            cal_active  <= 1'b0;
                        end else begin
                            cal_edge <= cal_edge + 1;
                        end
                    end
                    // Timeout: counter overflow → abort, retry
                    if (&cal_cnt)
                        cal_active <= 1'b0;
                end
            end

            /*===================================================*/
            /* RX                                                 */
            /*===================================================*/
            if (baud_locked & ~rx_busy & rx_fall) begin
                // Falling edge → potential start bit
                rx_busy  <= 1'b1;
                rx_timer <= {1'b0, baud_div[9:1]};   // ½ bit → mid-sample
                rx_bit   <= 4'd0;
            end else if (rx_busy) begin
                if (rx_timer == 10'd0) begin
                    rx_timer <= baud_div;
                    rx_bit   <= rx_bit + 1;
                    case (rx_bit)
                        4'd0: begin                   // mid-start-bit
                            if (rx) rx_busy <= 1'b0;  // false start, abort
                        end
                        4'd1, 4'd2, 4'd3, 4'd4,
                        4'd5, 4'd6, 4'd7, 4'd8: begin // data bits (LSB first)
                            rx_sr <= {rx, rx_sr[7:1]};
                        end
                        4'd9: begin                   // stop bit
                            rx_busy <= 1'b0;
                            if (rx) begin             // valid stop → deliver
                                rd_data  <= rx_sr;
                                rd_valid <= 1'b1;
                            end
                            // invalid stop → frame error, discard silently
                        end
                    endcase
                end else begin
                    rx_timer <= rx_timer - 1;
                end
            end

            /*===================================================*/
            /* TX                                                 */
            /*===================================================*/
            if (baud_locked & ~tx_busy & wr_en) begin
                tx_busy  <= 1'b1;
                tx_sr    <= wr_data;
                tx_pin   <= 1'b0;              // start bit
                tx_timer <= baud_div;
                tx_bit   <= 4'd0;
            end else if (tx_busy) begin
                if (tx_timer == 10'd0) begin
                    tx_timer <= baud_div;
                    tx_bit   <= tx_bit + 1;
                    if (tx_bit <= 4'd7) begin  // data bits (LSB first)
                        tx_pin <= tx_sr[0];
                        tx_sr  <= {1'b0, tx_sr[7:1]};
                    end else if (tx_bit == 4'd8) begin
                        tx_pin <= 1'b1;        // stop bit
                    end else begin             // tx_bit == 9 → done
                        tx_busy <= 1'b0;
                    end
                end else begin
                    tx_timer <= tx_timer - 1;
                end
            end

            /*===================================================*/
            /* BREAK DETECTOR (only when locked)                  */
            /*===================================================*/
            if (baud_locked) begin
                if (rx) begin
                    brk_cnt   <= 4'd0;
                    brk_timer <= 10'd0;
                end else begin
                    if (brk_timer == baud_div) begin
                        brk_timer <= 10'd0;
                        if (~brk_now)          // saturate at 12
                            brk_cnt <= brk_cnt + 1;
                    end else begin
                        brk_timer <= brk_timer + 1;
                    end
                end
            end

        end // !reset
    end

endmodule
