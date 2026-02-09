`timescale 1ns / 1ps

typedef enum {
    OOR_SUB  = 0,
    OOR_NAN  = 1,
    OOR_INF  = 2,
    OOR_ZERO = 3
} oor_e;

module fpmult_tb #(parameter int P = 8, parameter int Q = 8) ();

    logic           rst_in_N;  // synchronous active-low reset
    logic           clk_in;  // clock
    logic [P+Q-1:0] x_in;  // input X; x_in[15] is the sign bit
    logic [P+Q-1:0] y_in;  // input Y: y_in[15] is the sign bit
    logic [ 1:0]    round_in;  // rounding mode specifier
    logic           start_in;  // signal to start multiplication
    logic [P+Q-1:0] p_out;  // output P: p_out[15] is the sign bit
    logic [ 3:0]    oor_out;  // out-of-range indicator
    logic           valid_out;  // the outputs are valid
    logic           ready_out;  // the FPM is ready to receive new inputs

    fpmult #(.P(P), .Q(Q)) dut (
        .rst_in_N (rst_in_N),
        .clk_in   (clk_in),
        .x_in     (x_in),
        .y_in     (y_in),
        .round_in (round_in),
        .start_in (start_in),
        .p_out    (p_out),
        .oor_out  (oor_out),
        .valid_out(valid_out),
        .ready_out(ready_out)
    );

    reg [53:0] line;  // Every test vectors is exactly this long
    integer fd;  // file descriptor
    integer code, num_tests, num_wrong, num_displayed;
    integer counter;

    localparam DESIRED = 2;

    logic [15:0] test_x, test_y, test_p;
    logic [3:0] oor;
    logic [1:0] round_mode;
    logic out_is_nan;

    initial begin
        clk_in = 0;
        forever begin
            #5 clk_in = ~clk_in;
        end
        //every 5 ns switch...so period of clock is 10 ns...100 MHz clock
    end

    //initial block...this is our test simulation
    initial begin
        fd = $fopen("tests.txt", "r");  // STUDENTS: Edit me to edit your test vector
        // Set initial values
        rst_in_N = 1;
        num_tests = 0;
        num_displayed = 0;
        num_wrong = 0;

        @(posedge clk_in);
        rst_in_N = 0;
        @(posedge clk_in);
        rst_in_N = 1;

        while (!$feof(
            fd
        )) begin : test_loop
            // Get next line
            $fscanf(fd, "%x\n", line);

            counter += 1;
            if (counter != DESIRED) continue;

            $display("Desired line is %x\n", line);

            round_mode = line[53:52];
            test_x = line[51:36];
            test_y = line[35:20];
            test_p = line[19:4];
            oor = line[3:0];

            // Set inputs
            x_in = test_x;
            y_in = test_y;
            round_in = round_mode;
            start_in = 0;

            while (!ready_out) begin
                @(posedge clk_in);  // wait for FPM to be ready to consume data
            end
            @(negedge clk_in)
            start_in = 1;
            @(negedge clk_in);  // FPM should consume data by this time
            start_in = 0;
            x_in = 'x;
            y_in = 'x;
            round_in = 'x;

            while (!valid_out) begin
                @(posedge clk_in);  // wait for FPM to have a valid output
            end

            // By here, FPM has finished. In current design, FPM should just
            // holds value until a new start signal is received.
            num_tests++;
            out_is_nan = oor_out[OOR_NAN] && (p_out[P+Q-2:P-1] == '1) && (p_out[P-2:0] != '0);
            if ((p_out != test_p) && !(oor[OOR_NAN] && out_is_nan)) begin
                if (num_displayed < 12) begin
                    $display("ERROR: x_in = %x, y_in = %x, expected %x, got %x", test_x, test_y,
                             test_p, p_out);
                    $display(
                        "       (binary: x_in = %s%0b.%b*2^%0d, y_in = %s%0d.%b*2^%0d, expected %s%0d.%b*2^%0d, got %s%0d.%b*2^%0d)",
                        test_x[P+Q-1] ? "-" : "+", test_x[P+Q-2:P-1] == 0 ? 0 : 1, test_x[P-2:0],
                        test_x[P+Q-2:P-1] == 0 ? -126 : $signed({1'b0, test_x[P+Q-2:P-1]})
                        - (2 ** (Q - 1) - 1), test_y[P+Q-1] ? "-" : "+",
                        test_y[P+Q-2:P-1] == 0 ? 0 : 1, test_y[P-2:0],
                        test_y[P+Q-2:P-1] == 0 ? -126 : $signed({1'b0, test_y[P+Q-2:P-1]})
                        - (2 ** (Q - 1) - 1), test_p[P+Q-1] ? "-" : "+",
                        test_p[P+Q-2:P-1] == 0 ? 0 : 1, test_p[P-2:0],
                        test_p[P+Q-2:P-1] == 0 ? -126 : $signed({1'b0, test_p[P+Q-2:P-1]})
                        - (2 ** (Q - 1) - 1), p_out[P+Q-1] ? "-" : "+",
                        p_out[P+Q-2:P-1] == 0 ? 0 : 1, p_out[P-2:0],
                        p_out[P+Q-2:P-1] == 0 ? -126 : $signed({1'b0, p_out[P+Q-2:P-1]})
                        - (2 ** (Q - 1) - 1),);
                    num_displayed++;
                end

                num_wrong++;
            end
        end : test_loop
        $fclose(fd);
        $display("%d errors out of %d test vectors", num_wrong, num_tests);
        $finish;
    end

endmodule : fpmult_tb
`default_nettype wire