`timescale 1ns / 1ps

module umul #(parameter P) (input logic clk, reset, logic [P-1:0] a, logic [P-1:0] b, logic start, output logic done, output logic [2*P-1:0] out);
    logic [2 * P - 1:0] vector;

    localparam COUNTER_BITS = $clog2(P);
    logic [COUNTER_BITS-1:0] counter;

    logic state;

    localparam logic [COUNTER_BITS-1:0] P_MINUS_ONE = COUNTER_BITS'(P - 1);

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
                        //$display("a is %b, b is %b", a, b);
                    end
                    done <= 1'b0;
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

                    multiplied = b & {P{vector[0]}};
                    product = vector[2 * P - 1:P];
                    sum = multiplied + product;
                    should_fin = 0;
                    new_vector = {sum, vector[P-1:1]};

                    // Add into current product.


                    vector <= new_vector;

                    new_counter = counter + 1;
                    counter <= new_counter;
                    done <= counter == P_MINUS_ONE;

                    if (counter == P_MINUS_ONE) begin
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
module normalizer #(parameter int P, parameter int Q) (input logic [P - 1:0] significand, logic [Q:0] exponent, logic [2:0] flags_in,
        output logic [P - 1:0] out_sig, logic [Q:0] out_exp, logic [1:0] flags_out);
    always_comb begin
        logic new_round, new_sticky;
        if (significand[P - 1] == 0) begin
            new_round = flags_in[1];
            new_sticky = flags_in[0];
            out_sig = {significand[P - 2:0], flags_in[2]};
            out_exp = exponent;
            flags_out = {new_round, new_sticky};
        end else begin
            new_round = flags_in[2];
            new_sticky = flags_in[1] | flags_in[0];

            out_exp = exponent + 1;
            out_sig = significand;
            flags_out = {new_round, new_sticky};
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
module rounder #(parameter int P, parameter int Q) (input logic [1:0] round_mode, logic sign_bit, logic signed [Q:0] exponent, logic [P - 1:0] significand, logic [1:0] flags, output logic [P - 1:0] out_sig, logic out_guard, logic is_inf, logic [Q:0] out_exponent);

    logic round, sticky;
    assign {round, sticky} = flags;

    // all 1's no bias: 2 ** Q - 1
    // all 1's with bias: 2**Q - 1 - (2**(Q - 1) - 1)
    // simplify: 2**Q - 1 - 2**(Q-1) + 1
    // simplify: 2**(Q-1)
    // but we don't use all 1's as Emax (reserved), so take away one
    // 2**(Q-1) - 1
    localparam int Emax = 2 ** (Q - 1) - 1;

    // round modes:
    // RTE - 0
    // RTZ - 1
    // RD - 2
    // RU - 3
    always_comb begin
        logic [P:0] sum;
        logic [P:0] n_max_sig;
        logic exponent_too_big;

        sum = '0;
        n_max_sig = { 1'b0, {P{1'b1}} };
        exponent_too_big = exponent > (Q+1)'(Emax);

        out_exponent = exponent;

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
                    sum = significand + 1;
                    out_guard = sum[0];
                    out_sig = sum[P:1];

                    // if carry:
                    // 2 * 2^{old exp}
                    // 1.0000000000000... * 2^{old exp + 1}
                end else begin
                    // choose whichever significand is even.
                    sum = 0;
                    out_sig = {1'b0, significand[P-1:1]};
                    out_guard = significand[0];
                end

                is_inf = exponent_too_big;
            end

            // RTZ - Do nothing (truncate).
            // _ means end of storable precision
            // 1.01_10 -> 1.01
            // -1.01_10 -> -1.01
            // 1.01_01 -> 1.01
            // -1.01_01 -> -1.01
            2'b01: begin
                sum = 0;
                out_sig = {1'b0, significand[P-1:1]};
                out_guard = significand[0];

                is_inf = 0;

                if (exponent_too_big) begin
                    { out_sig, out_guard } = n_max_sig;
                    out_exponent = (Q+1)'(Emax);
                end
            end


            // RD
            // 1.01_10 -> 1.01
            // -1.01_10 -> -1.10
            // 1.01_01 -> 1.01
            // -1.01_01 -> -1.01
            2'b10: begin
                if ((!round && !sticky) || !sign_bit) begin
                    // truncate (obv).
                    sum = 0;
                    out_sig = {1'b0, significand[P-1:1]};
                    out_guard = significand[0];
                end else begin
                    // (round || sticky) && sign
                    sum = significand + 1;
                    out_guard = sum[0];
                    out_sig = sum[P:1];
                end

                is_inf = sign_bit && exponent_too_big;

                if (!sign_bit && exponent_too_big) begin
                    { out_sig, out_guard } = n_max_sig;
                    out_exponent = (Q+1)'(Emax);
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
                    sum = 0;
                    out_sig = {1'b0, significand[P-1:1]};
                    out_guard = significand[0];
                end else begin
                    // (round || sticky) && !sign
                    sum = significand + 1;
                    out_guard = sum[0];
                    out_sig = sum[P:1];
                end

                is_inf = !sign_bit && exponent_too_big;

                if (sign_bit && exponent_too_big) begin
                    { out_sig, out_guard } = n_max_sig;
                    out_exponent = (Q+1)'(Emax);
                end
            end
        endcase


        // Not necessary because we'll do this in the end anyway (is_inf will be set).
        if (is_inf) begin
            out_exponent = { 1'b0, {Q{1'b1}} };
            { out_sig, out_guard } = '0;
        end
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
        PRENORM_FIXUP,
        NORMALIZE,
        POSTNORM_FIXUP,
        ROUND,
        DONE
    } State;

    logic [2:0] state;
    logic [1:0] round_mode;

    logic [2 * P - 1:0] significand_product_raw;
    logic [2 * P - 1:0] big_product;
    logic [P-1:0] working_significand;
    logic multiplier_done;
    logic [2:0] flags;

    logic [2:0] flag_computer_new_flags;

    logic [P+Q-1:0] input_x, input_y;
    logic sign_bit;
    logic signed [Q:0] exponent;

    logic [2:0] normalizer_new_flags;
    logic [P-1:0] normalizer_new_sig;
    logic signed [Q:0] normalizer_new_exponent;

    logic start_multiplier;

    logic [Q-1:0] in_x_exp, in_y_exp;
    assign in_x_exp = input_x[P + Q - 2:P - 1];
    assign in_y_exp = input_y[P + Q - 2:P - 1];

    umul #(.P(P)) dummy(clk_in, ~rst_in_N, {in_x_exp == '0 ? 1'b0 : 1'b1, input_x[P-2:0]}, {in_y_exp == '0 ? 1'b0 : 1'b1, input_y[P-2:0]}, start_multiplier, multiplier_done, significand_product_raw);
    compute_flags #(.P(P)) flag_computer(big_product, flag_computer_new_flags);
    normalizer #(.P(P), .Q(Q)) normalizer(working_significand, exponent, flags, normalizer_new_sig, normalizer_new_exponent, normalizer_new_flags[1:0]);

    logic [P - 1:0] rounder_new_sig;
    logic [Q:0] rounder_new_exponent;
    logic rounder_new_guard;
    logic rounder_is_inf;
    rounder #(.P(P), .Q(Q)) the_rounder(round_mode, sign_bit, exponent, working_significand, flags[1:0], rounder_new_sig, rounder_new_guard, rounder_is_inf, rounder_new_exponent);

    logic rounding_complete;

    logic is_inf, is_nan;

    localparam int BIAS = 2**(Q - 1) - 1;
    localparam logic [Q-1:0] BIAS_LOGIC = BIAS[Q-1:0];
    localparam int Emin = 1 - BIAS;

    always_ff @(posedge clk_in) begin
        if (~rst_in_N) begin
            state <= LOAD;
            valid_out <= 0;
            start_multiplier <= 0;
        end else begin
            case (state)
                LOAD: begin
                    valid_out <= 0;
                    if (start_in) begin
                        logic signed [Q:0] exponent_sum;
                        logic [Q-1:0] x_exp, y_exp;
                        logic [P-2:0] x_mant, y_mant;
                        logic x_is_nan, x_inf, x_zero, y_is_nan, y_inf, y_zero, result_is_nan, result_is_inf;

                        //$display("x_in is %b, y_in is %b", x_in, y_in);

                        round_mode <= round_in;

                        x_exp = x_in[P+Q-2:P-1];
                        x_mant = x_in[P-2:0];
                        x_is_nan = (x_exp == '1) && (x_mant != '0);
                        x_inf = (x_exp == '1) && (x_mant == '0);
                        x_zero = (x_exp == '0) && (x_mant == '0);

                        y_exp = y_in[P+Q-2:P-1];
                        y_mant = y_in[P-2:0];
                        y_is_nan = (y_exp == '1) && (y_mant != '0);
                        y_inf = (y_exp == '1) && (y_mant == '0);
                        y_zero = (y_exp == '0) && (y_mant == '0);

                        exponent_sum = x_exp - BIAS_LOGIC + (x_exp == '0 ? 1 : 0) + y_exp - BIAS_LOGIC + (y_exp == '0 ? 1 : 0);
                        //$display("exponent_sum is %d", exponent_sum);
                        input_x <= x_in;
                        input_y <= y_in;
                        sign_bit <= x_in[P + Q - 1] ^ y_in[P + Q - 1];
                        rounding_complete <= 0;
                        exponent <= exponent_sum;

                        result_is_nan = (x_is_nan || y_is_nan) || (x_inf && y_zero) || (x_zero && y_inf);
                        result_is_inf = (x_inf || y_inf) && !result_is_nan;
                        is_inf <= result_is_inf;
                        is_nan <= result_is_nan;

                        if (result_is_nan) begin
                            working_significand <= x_is_nan ? {1'b1, x_mant} : {1'b1, y_mant};
                            state <= DONE;
                        end else if (result_is_inf || x_zero || y_zero) begin
                            working_significand <= '0;
                            // Ignored if result_is_inf.
                            exponent <= (Q+1)'(Emin);
                            state <= DONE;
                        end else begin
                            start_multiplier <= 1;
                            state <= EXECUTE;
                        end

                        // $display("x_in is %x, y_in is %x", x_in, y_in);
                    end

                    ready_out <= 1;
                end
                EXECUTE: begin
                    start_multiplier <= 0;
                    if (multiplier_done) begin
                        big_product <= significand_product_raw;
                        state <= PRENORM_FIXUP;
                        // TODO: Maybe special case this guy on if the product is zero and then don't do it.
                    end    
                end
                PRENORM_FIXUP: begin
                    if (big_product[2*P-1] == 1'b0 && big_product[2*P-2] == 1'b0 && exponent > (Q+1)'(Emin)) begin
                        exponent <= exponent - 1;
                        //$display("current_exponent is %d, new_exponent will be %d, the product is %b", exponent, exponent - 1, big_product);
                        big_product <= { big_product[2 * P - 2:0], 1'b0 };
                    end else begin
                        // after done do this
                        flags <= flag_computer_new_flags;
                        working_significand <= big_product[2*P-1:P];
                        state <= NORMALIZE;
                    end
                end
                NORMALIZE: begin
                    normalizer_new_flags[2] = 0;


                    if (rounding_complete) begin
                        state <= DONE;
                        flags <= normalizer_new_flags;
                        working_significand <= normalizer_new_sig;
                        exponent <= normalizer_new_exponent;
                    end else begin
                        logic [2:0] new_flags;
                        // $display("in normalize, exponent is %d, flags %b, w_sig %b", exponent, normalizer_new_flags, normalizer_new_sig);
                        if (normalizer_new_exponent + (Q+1)'(P) < (Q+1)'(Emin)) begin
                                     // guard, round, new sticky
                            new_flags = { 1'b0, 1'b0, |{working_significand, normalizer_new_flags[1], normalizer_new_flags[0]}};
                            flags <= new_flags;
                            state <= ROUND;
                            working_significand <= '0;
                            exponent <= (Q+1)'(Emin);
                        end else begin
                            flags <= normalizer_new_flags;
                            state <= POSTNORM_FIXUP;
                            working_significand <= normalizer_new_sig;
                            exponent <= normalizer_new_exponent;
                        end
                        // p cycles.
                        // 1.xxxxx
                        // 0.00000  0 1 | anything after (including previous sticky)
                    end
                end
                POSTNORM_FIXUP: begin
                    if (exponent < (Q+1)'(Emin)) begin
                        //$display("w_sig %b, flags %b, exponent %d", working_significand, flags, exponent);
                        working_significand <= {1'b0, working_significand[P - 1:1]};

                        // guard, round, sticky
                        // guard doesn't have any meaning at this point, because we already did the first NORMALIZE pass.
                        flags <= { 1'b0, working_significand[0], flags[0] | flags[1] };
                        exponent <= exponent + 1;
                    end else begin
                        state <= ROUND;
                    end
                end
                ROUND: begin
                    working_significand <= rounder_new_sig;
                    flags <= { rounder_new_guard, 1'b0, 1'b0 };
                    
                    rounding_complete <= 1;
                    state <= NORMALIZE;
                    is_inf <= rounder_is_inf;
                    exponent <= rounder_new_exponent;
                end
                DONE: begin
                    logic [P-2:0] without_hidden;
                    logic [P + Q - 1:0] the_output;
                    logic [Q-1:0] final_exponent;
                    logic [Q:0] biased_exponent;
                    
                    if (is_inf || is_nan) begin
                        p_out <= { sign_bit, {Q{1'b1}}, {(P-1){is_nan || !is_inf}} };
                    end else begin
                        without_hidden = working_significand[P-2:0];
                        // check whether the exponent is actually in range. if not, either +/- 0, +/- infinity, or +/- Nmax

                        biased_exponent = exponent + (Q+1)'(BIAS);
                        // if the hidden bit is 0, change exponent representation from 1 to 0
                        //$display("the hidden bit is %d", working_significand[P - 1]);
                        final_exponent = biased_exponent[Q-1:0] - {{Q-1{1'b0}}, ~working_significand[P-1]}; // - Q'(~working_significand[P-1]);

                        the_output = { sign_bit, final_exponent, without_hidden };
                        p_out <= the_output;
                    end

                    oor_out <= { working_significand == '0, is_inf, is_nan, ~working_significand[P - 1] };

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
