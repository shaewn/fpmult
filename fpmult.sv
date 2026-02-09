`timescale 1ns / 1ps

module umul #(parameter P) (input logic clk, reset, logic [P-1:0] a, logic [P-1:0] b, logic start, output logic done, output logic [2*P-1:0] out);
    logic [2 * P - 1:0] vector;

    localparam COUNTER_BITS = $clog2(P);
    logic [COUNTER_BITS-1:0] counter;

    logic state;

    always_ff @(posedge clk) begin
        if (reset) begin
            state <= 1'b0;
            counter <= '0;
            done <= 1'b0; // We do actually need this here. If this is set to 1 before the wait state updates it, the control unit will think we're done immediately.
            vector <= '0;
            out <= '0;
        end else begin
            case (state) 
                // Wait state.
                1'b0: begin
                    if (start) begin
                        state <= 1'b1;
                        counter <= 'b0;
                        vector[2 * P - 1:P] <= 'b0;
                        vector[P-1:0] <= a;
                        $display("a is %x, b is %x\n", a, b);
                        done <= 1'b0;
                    end
                end

                // Multiply state.
                1'b1: begin
                    // Multiply.
                    logic [P-1:0] multiplied;
                    logic [P-1:0] product; 
                    logic [P:0] sum;
                    logic should_fin;
                    logic [COUNTER_BITS-1:0] new_counter;
                    logic [2 * P - 1:0] new_vector;

                    // $display("vector is %x\n", vector);
                    multiplied = b & {P{vector[0]}};
                    product = vector[2 * P - 1:P];
                    sum = multiplied + product;
                    should_fin = 0;
                    new_vector = {sum, vector[P-1:1]};

                    // Add into current product.


                    vector <= new_vector;

                    // TODO: Replace this with a comparator so that it becomes more general.
                    {should_fin, new_counter} = counter + 1;
                    counter <= new_counter;
                    done <= should_fin;

                    if (should_fin) begin
                        state <= 1'b0;
                        out <= new_vector;
                    end
                end

            endcase
        end
    end
endmodule: umul

// flags_in: {guard, round, sticky}
// flags_out: {round, sticky}
module normalizer #(parameter int P, parameter int Q) (input logic [P - 1:0] significand, logic [Q - 1:0] exponent, logic [2:0] flags_in,
        output logic [P - 1:0] out_sig, logic [Q - 1:0] out_exp, logic ovfl, logic [1:0] flags_out);
    always_comb begin
        logic new_round, new_sticky;
        if (significand[P - 1] == 0) begin
            new_round = flags_in[1];
            new_sticky = flags_in[0];
            assign out_sig = {significand[P - 2:0], flags_in[2]};
            assign out_exp = exponent;
            assign ovfl = 0;
            assign flags_out = {new_round, new_sticky};
        end else begin
            new_round = flags_in[2];
            new_sticky = flags_in[1] | flags_in[0];

            assign out_exp = exponent + 1; // NOTE: exponent could become too large!
            assign ovfl = exponent + 1 == '1 ? 1 : 0;
            assign out_sig = significand;
            assign flags_out = {new_round, new_sticky};
            // base 10 example: 35.4 * 10^0 -> 3.54 * 10^1
            // base 2 
        end
    end
endmodule: normalizer

// significant [2*]
// flags: {guard, round, sticky}
module compute_flags #(parameter int P) (input logic [2 * P - 1:0] vector, output logic [2:0] flags);
    assign flags[2] = vector[P-1];
    assign flags[1] = vector[P-2];
    assign flags[0] = |vector[P-3:0];
endmodule: compute_flags

// guard - 
// round -
// sticky - 
// 1.11111111111111111111... (rounds to) -> 10.00000000000000000000 -> [10.0000000000000000000, 0]
// 1.11111111111111111110... (rounds to) -> 1.11111111111111111111 -> [01.1111111111111111111, 1]
// the input significand is expected to in the format x.xxxxxx...
// the output significand is in the format xx.xxxxx...
module rounder #(parameter int P) (input logic [1:0] round_mode, logic sign_bit, logic [P - 1:0] significand, logic [1:0] flags, output logic [P - 1:0] out_sig, logic out_guard);

    logic round, sticky;
    assign {round, sticky} = flags;
    // round modes:
    // RTE - 0
    // RTZ - 1
    // RD - 2
    // RU - 3
    always_comb begin
        logic [P:0] sum;
        case (round_mode) 
            // RTE - Round to nearest, ties if even
            // if round = 0, we round down (its already < 0.5)
            // if round = 1, we round if sticky is set (it is > 0.5)
            2'b00: begin
                // round up case
                // 1.xxxxxxx   11
                //              r (OBVIOUSLY go up... not down to ????? 00) 
                // (round && sticky) || (round && significand[0])
                if (round && (sticky || significand[0])) begin
                    assign sum = significand + 1;
                    assign out_guard = sum[0];
                    assign out_sig = sum[P:1];

                    // if carry:
                    // 2 * 2^{old exp}
                    // 1.0000000000000... * 2^{old exp + 1}
                end else begin
                    // choose whichever significand is even.
                    assign sum = 0;
                    assign out_sig[P-1:0] = {1'b0, significand[P-1:1]};
                    assign out_guard = significand[0];
                end
            end

            // RTZ - Do nothing (truncate).
            // _ means end of storable precision
            // 1.01_10 -> 1.01
            // -1.01_10 -> -1.01
            // 1.01_01 -> 1.01
            // -1.01_01 -> -1.01
            2'b01: begin
                assign sum = 0;
                assign out_sig[P-1:0] = {1'b0, significand[P-1:1]};
                assign out_guard = significand[0];
            end


            // RD
            // 1.01_10 -> 1.01
            // -1.01_10 -> -1.10
            // 1.01_01 -> 1.01
            // -1.01_01 -> -1.01
            2'b10: begin
                if ((!round && !sticky) || !sign_bit) begin
                    // truncate (obv).
                    assign sum = 0;
                    assign out_sig[P-1:0] = {1'b0, significand[P-1:1]};
                    assign out_guard = significand[0];
                end else begin
                    // (round || sticky) && sign
                    assign sum = significand + 1;
                    assign out_guard = sum[0];
                    assign out_sig = sum[P:1];
                end
            end

            // RU
            // 1.01_10 -> 1.10
            // -1.01_10 -> -1.01
            // 1.01_01 -> 1.10
            // -1.01_01 -> -1.01
            2'b11: begin
                if ((!round && !sticky) || sign_bit) begin
                    // truncate (obv).
                    assign sum = 0;
                    assign out_sig[P-1:0] = {1'b0, significand[P-1:1]};
                    assign out_guard = significand[0];
                end else begin
                    // (round || sticky) && !sign
                    assign sum = significand + 1;
                    assign out_guard = sum[0];
                    assign out_sig = sum[P:1];
                end
            end
        endcase
    end

endmodule: rounder

module fpmult #(parameter int P = 8, parameter int Q = 8) (
    input  logic rst_in_N,           // synchronous active-low reset
    input  logic clk_in,             // clock
    input  logic [P+Q-1:0] x_in,     // input X; x_in[P+Q-1] is the sign bit
    input  logic [P+Q-1:0] y_in,     // input Y: y_in[P+Q-1] is the sign bit
    input  logic [1:0] round_in,     // rounding mode specifier
    input  logic start_in,           // signal to start multiplication
    output logic [P+Q-1:0] p_out,    // output P: p_out[P+Q-1] is the sign bit
    output logic [3:0] oor_out,      // out-of-range indicator vector
    output logic valid_out,          // the outputs are valid
    output logic ready_out           // the FPM is ready to receive new inputs
);

    typedef enum logic [2:0] { 
        LOAD,
        EXECUTE,
        NORMALIZE,
        ROUND,
        DONE
    } State;

    logic [2:0] state;

    logic [2 * P - 1:0] significand_product_raw;
    logic [P-1:0] working_significand;
    logic multiplier_done;
    logic [2:0] flags;

    logic [2:0] flag_computer_new_flags;

    logic [P+Q-1:0] input_x, input_y;
    logic sign_bit;
    logic [Q-1:0] exponent;

    logic [2:0] normalizer_new_flags;
    logic [P-1:0] normalizer_new_sig;
    logic [Q-1:0] normalizer_new_exponent;
    logic normalizer_ovfl;

    logic start_multiplier;

    umul #(.P(P)) dummy(clk_in, ~rst_in_N, {1'b1, input_x[P-2:0]}, {1'b1, input_y[P-2:0]}, start_multiplier, multiplier_done, significand_product_raw);
    compute_flags #(.P(P)) flag_computer(significand_product_raw, flag_computer_new_flags);
    normalizer #(.P(P), .Q(Q)) normalizer(working_significand, exponent, flags, normalizer_new_sig, normalizer_new_exponent, normalizer_ovfl, normalizer_new_flags[1:0]);

    logic [P - 1:0] rounder_new_sig;
    logic rounder_new_guard;
    rounder #(.P(P)) the_rounder(round_in, sign_bit, working_significand, flags[1:0], rounder_new_sig, rounder_new_guard);

    logic rounding_complete;
    localparam int BIAS = 2**(Q - 1) - 1;
    localparam logic [Q-1:0] BIAS_LOGIC = BIAS[Q-1:0];

    always_ff @(posedge clk_in) begin
        if (~rst_in_N) begin
            state <= LOAD;
        end else begin
            case (state)
                LOAD: begin
                    if (start_in) begin
                        logic [Q:0] exponent_sum;

                        exponent_sum = (x_in[P+Q-2:P-1] + y_in[P+Q-2:P-1]) - BIAS_LOGIC;
                        input_x <= x_in;
                        input_y <= y_in;
                        // $display("%x, %x\n", x_in, y_in);
                        sign_bit <= x_in[P + Q - 1] ^ y_in[P + Q - 1];
                        state <= EXECUTE;
                        start_multiplier <= 1;
                        rounding_complete <= 0;
                        exponent <= exponent_sum[Q-1:0];
                        state <= EXECUTE;
                    end

                    ready_out <= 1;
                end
                EXECUTE: begin
                    if (multiplier_done) begin
                        flags <= flag_computer_new_flags;
                        working_significand <= significand_product_raw[2*P-1:P];
                        // $display("the working_significand is intialized as %x\n", significand_product_raw[2*P-1:0]);
                        state <= NORMALIZE;
                    end    
                 end
                NORMALIZE: begin
                    normalizer_new_flags[2] = 0;

                    flags <= normalizer_new_flags;
                    exponent <= normalizer_new_exponent;
                    working_significand <= normalizer_new_sig;

                    if (rounding_complete) begin
                        state <= DONE;
                    end else begin
                        state <= ROUND;
                    end
                end
                ROUND: begin
                    working_significand <= rounder_new_sig;
                    flags <= { rounder_new_guard, 1'b0, 1'b0 };

                    rounding_complete <= 1;
                    state <= NORMALIZE;
                end
                DONE: begin
                    logic [P-2:0] without_hidden;
                    logic [P + Q - 1:0] the_output;

                    without_hidden = working_significand[P-2:0];
                    the_output = { sign_bit, exponent, without_hidden };
                    p_out <= the_output;
                    oor_out = 4'b0;
                    valid_out <= 1;
                    state <= LOAD;
                end
                default: begin end
            endcase
        end
    end

// states we need:
/*

idle (0), do nothing, transition on positive edge of start_in to load state.
load state (1), add exponents and load the registers, transition unconditionally to execute
execute (2), start the multiplier, transition on positive edge of multiplier_done to normalization
normalization (3), truncate retaining guard round and sticky and then normalize, transition to rounding
rounding (4), round, transition to re-normalization
re-normalization (5), normalize, transition to completion
completion ???

*/


endmodule: fpmult
