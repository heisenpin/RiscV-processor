`timescale 1ns/1ps
// Testbench for risc_top. Uses small DB_LIMIT/DIV_LIMIT parameters so the
// debounce filter and step clock settle in a handful of cycles instead of
// the millions of cycles the real ~10ms/~1Hz hardware values would need.

module tb_risc_v_core;

    reg         clk;
    reg  [15:0] sw;
    reg  [3:0]  btn;
    wire [15:0] led;
    wire [7:0]  D0_SEG, D1_SEG;
    wire [3:0]  D0_AN, D1_AN;
    wire [2:0]  RGB0, RGB1;

    localparam VAL_X1 = 4'd5;
    localparam VAL_X2 = 4'd3;

    risc_top #(
        .DB_LIMIT  (20'd4),
        .DIV_LIMIT (27'd4)
    ) dut (
        .clk(clk), .sw(sw), .btn(btn), .led(led),
        .D0_SEG(D0_SEG), .D0_AN(D0_AN),
        .D1_SEG(D1_SEG), .D1_AN(D1_AN),
        .RGB0(RGB0), .RGB1(RGB1)
    );

    // 100 MHz clock
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Hold a button asserted, then release, long enough to clear the
    // debounce filter both ways and let edge_detect fire one pulse.
    task press_button(input integer bit_idx);
        begin
            btn[bit_idx] = 1'b1;
            repeat (20) @(posedge clk);
            btn[bit_idx] = 1'b0;
            repeat (20) @(posedge clk);
        end
    endtask

    integer errors = 0;
    task check(input [199:0] name, input [31:0] actual, input [31:0] expected);
        begin
            if (actual !== expected) begin
                $display("FAIL %0s : got %0d expected %0d", name, actual, expected);
                errors = errors + 1;
            end else
                $display("PASS %0s : %0d", name, actual);
        end
    endtask

    initial begin
        btn = 4'b0000;
        sw  = {8'h00, VAL_X2, VAL_X1};  // sw[3:0]=x1 preload, sw[7:4]=x2 preload

        btn[2] = 1'b1;          // manual single-step mode
        press_button(0);        // reset: x1<=5, x2<=3, PC<=0

        check("x0_hardwired_zero", dut.rf0.regs[0], 32'd0);
        check("x1_preload",        dut.rf0.regs[1], VAL_X1);
        check("x2_preload",        dut.rf0.regs[2], VAL_X2);

        press_button(1); check("add  x3,x1,x2",  dut.rf0.regs[3],  VAL_X1 + VAL_X2);
        press_button(1); check("sub  x4,x1,x2",  dut.rf0.regs[4],  VAL_X1 - VAL_X2);
        press_button(1); check("and  x5,x1,x2",  dut.rf0.regs[5],  VAL_X1 & VAL_X2);
        press_button(1); check("or   x6,x1,x2",  dut.rf0.regs[6],  VAL_X1 | VAL_X2);
        press_button(1); check("xor  x7,x1,x2",  dut.rf0.regs[7],  VAL_X1 ^ VAL_X2);
        press_button(1); check("slt  x8,x1,x2",  dut.rf0.regs[8],  (VAL_X1 < VAL_X2) ? 32'd1 : 32'd0);
        press_button(1); check("mul  x9,x1,x2",  dut.rf0.regs[9],  VAL_X1 * VAL_X2);
        press_button(1); check("div  x10,x1,x2", dut.rf0.regs[10], VAL_X1 / VAL_X2);
        press_button(1); check("addi x11,x1,5",  dut.rf0.regs[11], VAL_X1 + 5);
        press_button(1); check("andi x12,x1,15", dut.rf0.regs[12], VAL_X1 & 15);
        press_button(1); check("not  x13,x1",    dut.rf0.regs[13], ~{28'd0, VAL_X1});
        press_button(1); check("xnor x14,x1,x2", dut.rf0.regs[14], ~({28'd0, VAL_X1} ^ {28'd0, VAL_X2}));

        // Divide-by-zero path: reset with x2 = 0 and step until PC points at
        // the div instruction (PC=7). The div_zero flag is purely combinational
        // off the currently-fetched instruction, so it's checked here -- before
        // stepping past it -- not after (once stepped past, the flag reflects
        // whatever instruction is fetched next, same as the real hardware LEDs).
        sw = {8'h00, 4'd0, VAL_X1};
        press_button(0);                        // reset: x1<=5, x2<=0
        repeat (7) press_button(1);              // execute add,sub,and,or,xor,slt,mul
        check("div_by_zero_led_pre_step", led[11], 1'b1);

        press_button(1);                         // commit div x10,x1,x2 (x2=0) to the reg file
        check("div_by_zero_result", dut.rf0.regs[10], 32'hFFFFFFFF);

        if (errors == 0) $display("\nALL TESTS PASSED");
        else              $display("\n%0d TEST(S) FAILED", errors);

        $finish;
    end

endmodule