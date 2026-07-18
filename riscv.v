// ============================================================
//  Single-Cycle RV32I / RV32M Core  -  Boolean Board (xc7a35tcpg236-1)
//  Vivado 2020+  /  Verilog-2001
//
//  This is a REAL RISC-V core: the instruction word, opcode field,
//  funct3/funct7 fields, and register numbers all follow the RV32I
//  spec exactly. There is no branch/jump/load/store unit and no
//  data memory -- the board has no external RAM interface, so this
//  core only implements the arithmetic/logic subset (R-type + I-type),
//  the RV32M multiply/divide extension, and xnor from the ratified
//  Zbb bit-manipulation extension. not is not a real opcode on any
//  RISC-V core -- it's the standard pseudo-instruction "xori rd,rs1,-1",
//  which is how it's implemented here too.
//
//  SWITCH MAP:
//    sw[3:0]  -> x1  (loaded into the register file at reset)
//    sw[7:4]  -> x2  (loaded into the register file at reset)
//    sw[15:8] unused (mirrored to led[15])
//
//  BUTTON MAP:
//    btn[0] = reset (loads x1/x2 from switches, PC <- 0)
//    btn[1] = manual single-step (advance PC by one instruction)
//    btn[2] = mode: 0 = auto ~1Hz stepping, 1 = manual step
//    btn[3] = unused (mirrored to led[15])
//
//  LED MAP:
//    led[7:0]   = ALU result, lower byte
//    led[8]     = zero flag
//    led[9]     = carry   (display only -- RISC-V has no flags register)
//    led[10]    = overflow (display only)
//    led[11]    = div-by-zero (display only)
//    led[14:12] = funct3 of the current instruction
//    led[15]    = sw[15:8] OR btn[3]
//
//  7-SEG:  D0 = lower nibble of ALU result, D1 = upper nibble
//  RGB0: R=overflow G=zero B=carry
//  RGB1: R=I-type  G=base R-type  B=RV32M (mul/div)
//
//  PROGRAM (word-addressed instr_mem, PC increments by 4 bytes):
//    PC=0 : add  x3, x1, x2
//    PC=1 : sub  x4, x1, x2
//    PC=2 : and  x5, x1, x2
//    PC=3 : or   x6, x1, x2
//    PC=4 : xor  x7, x1, x2
//    PC=5 : slt  x8, x1, x2
//    PC=6 : mul  x9, x1, x2      (RV32M)
//    PC=7 : div  x10,x1, x2      (RV32M)
//    PC=8 : addi x11,x1, 5
//    PC=9 : andi x12,x1, 15
//    PC=10: not  x13,x1          (pseudo-op -> xori x13,x1,-1)
//    PC=11: xnor x14,x1, x2      (Zbb: opcode=R-type, funct3=100, funct7=0100000)
//    PC=12+: addi x0,x0,0        (canonical RISC-V NOP, 0x00000013)
// ============================================================

module clk_divider #(
    parameter DIV_LIMIT = 27'd49_999_999   // 100 MHz -> ~1 Hz toggle
)(
    input  wire clk,
    input  wire reset,
    output reg  slow_clk
);
    reg [26:0] cnt;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            cnt      <= 27'd0;
            slow_clk <= 1'b0;
        end else if (cnt == DIV_LIMIT) begin
            cnt      <= 27'd0;
            slow_clk <= ~slow_clk;
        end else
            cnt <= cnt + 27'd1;
    end
endmodule

// Debounce, ~10 ms at 100 MHz by default
module debounce #(
    parameter DB_LIMIT = 20'd999_999
)(
    input  wire clk,
    input  wire btn_in,
    output reg  btn_out
);
    reg [19:0] cnt;
    reg        q0, q1;
    initial begin cnt = 0; q0 = 0; q1 = 0; btn_out = 0; end

    always @(posedge clk) begin
        q0 <= btn_in;
        q1 <= q0;
        if (q0 != q1)
            cnt <= 20'd0;
        else if (cnt == DB_LIMIT) begin
            btn_out <= q1;
            cnt     <= 20'd0;
        end else
            cnt <= cnt + 20'd1;
    end
endmodule

// Rising-edge detector -> single-cycle pulse
module edge_detect (
    input  wire clk,
    input  wire sig_in,
    output wire pulse
);
    reg prev;
    initial prev = 1'b0;
    always @(posedge clk) prev <= sig_in;
    assign pulse = sig_in & ~prev;
endmodule

// Program counter, byte-addressed, +4 per instruction (real RISC-V PC behaviour)
module prog_counter (
    input  wire       clk,
    input  wire       reset,
    output reg  [7:0] pc_out
);
    always @(posedge clk or posedge reset) begin
        if (reset) pc_out <= 8'h00;
        else       pc_out <= pc_out + 8'd4;
    end
endmodule

// Instruction ROM -- real RV32I/RV32M encoded words.
// Field order in each literal, MSB to LSB: funct7 | rs2 | rs1 | funct3 | rd | opcode (R-type)
//                                          imm[11:0] | rs1 | funct3 | rd | opcode  (I-type)
module instr_mem (
    input  wire [3:0]  word_addr,   // = pc[5:2]
    output reg  [31:0] instr
);
    always @(*) begin
        case (word_addr)
            4'd0: instr = 32'b0000000_00010_00001_000_00011_0110011; // add  x3, x1, x2
            4'd1: instr = 32'b0100000_00010_00001_000_00100_0110011; // sub  x4, x1, x2
            4'd2: instr = 32'b0000000_00010_00001_111_00101_0110011; // and  x5, x1, x2
            4'd3: instr = 32'b0000000_00010_00001_110_00110_0110011; // or   x6, x1, x2
            4'd4: instr = 32'b0000000_00010_00001_100_00111_0110011; // xor  x7, x1, x2
            4'd5: instr = 32'b0000000_00010_00001_010_01000_0110011; // slt  x8, x1, x2
            4'd6: instr = 32'b0000001_00010_00001_000_01001_0110011; // mul  x9, x1, x2   (RV32M)
            4'd7: instr = 32'b0000001_00010_00001_100_01010_0110011; // div  x10,x1, x2   (RV32M)
            4'd8:  instr = 32'b000000000101_00001_000_01011_0010011; // addi x11,x1, 5
            4'd9:  instr = 32'b000000001111_00001_111_01100_0010011; // andi x12,x1, 15
            4'd10: instr = 32'b111111111111_00001_100_01101_0010011; // xori x13,x1,-1  (= not x13,x1)
            4'd11: instr = 32'b0100000_00010_00001_100_01110_0110011; // xnor x14,x1, x2 (Zbb)
            default: instr = 32'h00000013;                          // addi x0,x0,0 (NOP)
        endcase
    end
endmodule

// I-type immediate, sign-extended (only immediate format this subset needs)
module imm_gen (
    input  wire [31:0] instr,
    output wire [31:0] imm_i
);
    assign imm_i = {{20{instr[31]}}, instr[31:20]};
endmodule

// 32 x 32-bit register file. x0 is hardwired to zero, as required by the ISA.
// x1/x2 are preloaded from switches at reset; synchronous write, async read.
module reg_file (
    input  wire        clk,
    input  wire        reset,
    input  wire        we,
    input  wire [4:0]  rs1,
    input  wire [4:0]  rs2,
    input  wire [4:0]  rd,
    input  wire [31:0] wdata,
    input  wire [31:0] sw_x1,
    input  wire [31:0] sw_x2,
    output wire [31:0] rdata1,
    output wire [31:0] rdata2
);
    reg [31:0] regs [0:31];
    integer i;

    assign rdata1 = (rs1 == 5'd0) ? 32'd0 : regs[rs1];
    assign rdata2 = (rs2 == 5'd0) ? 32'd0 : regs[rs2];

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            for (i = 0; i < 32; i = i + 1) regs[i] <= 32'd0;
            regs[1] <= sw_x1;
            regs[2] <= sw_x2;
        end else if (we && rd != 5'd0) begin
            regs[rd] <= wdata;
        end
    end
endmodule

// Decodes opcode/funct3/funct7 into an ALU operation -- this is the actual
// RV32I/RV32M decode table, not a made-up opcode->ALU mapping.
module alu_control (
    input  wire [6:0] opcode,
    input  wire [2:0] funct3,
    input  wire [6:0] funct7,
    output reg  [3:0] alu_op,
    output reg        reg_write,
    output reg        alu_src_imm   // 1 = use immediate as operand B, 0 = use rs2
);
    localparam ADD=4'b0000, SUB=4'b0001, AND_OP=4'b0010, OR_OP=4'b0011,
               XOR_OP=4'b0100, SLT=4'b0101, MUL=4'b0110, DIV=4'b0111,
               XNOR_OP=4'b1000;

    always @(*) begin
        alu_op      = ADD;
        reg_write   = 1'b0;
        alu_src_imm = 1'b0;
        case (opcode)
            7'b0110011: begin // R-type: base RV32I, RV32M (funct7=0000001), Zbb (funct7=0100000)
                reg_write = 1'b1;
                case (funct3)
                    3'b000:  alu_op = (funct7 == 7'b0000001) ? MUL :
                                       (funct7 == 7'b0100000) ? SUB : ADD;
                    3'b111:  alu_op = AND_OP;
                    3'b110:  alu_op = OR_OP;
                    3'b100:  alu_op = (funct7 == 7'b0000001) ? DIV :
                                       (funct7 == 7'b0100000) ? XNOR_OP : XOR_OP;
                    3'b010:  alu_op = SLT;
                    default: alu_op = ADD;
                endcase
            end
            7'b0010011: begin // I-type
                reg_write   = 1'b1;
                alu_src_imm = 1'b1;
                case (funct3)
                    3'b000:  alu_op = ADD;    // addi
                    3'b111:  alu_op = AND_OP; // andi
                    3'b110:  alu_op = OR_OP;  // ori
                    3'b100:  alu_op = XOR_OP; // xori (imm=-1 gives the "not" pseudo-op)
                    default: alu_op = ADD;
                endcase
            end
            default: reg_write = 1'b0;        // unimplemented opcode -> treated as NOP
        endcase
    end
endmodule

// 32-bit ALU. carry/overflow/div_zero exist only for the board's LEDs --
// RISC-V itself has no architectural flags register.
module alu_unit (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [3:0]  alu_op,
    output reg  [31:0] result,
    output reg         zero,
    output reg         carry,
    output reg         overflow,
    output reg         div_zero
);
    localparam ADD=4'b0000, SUB=4'b0001, AND_OP=4'b0010, OR_OP=4'b0011,
               XOR_OP=4'b0100, SLT=4'b0101, MUL=4'b0110, DIV=4'b0111,
               XNOR_OP=4'b1000;

    reg [32:0] add_sub_ext;
    reg [63:0] mul_ext;

    always @(*) begin
        result = 32'd0; carry = 0; overflow = 0; div_zero = 0;
        add_sub_ext = 33'd0; mul_ext = 64'd0;

        case (alu_op)
            ADD: begin
                add_sub_ext = {1'b0,a} + {1'b0,b};
                result   = add_sub_ext[31:0];
                carry    = add_sub_ext[32];
                overflow = (~a[31]&~b[31]& result[31])|(a[31]&b[31]&~result[31]);
            end
            SUB: begin
                add_sub_ext = {1'b0,a} - {1'b0,b};
                result   = add_sub_ext[31:0];
                carry    = add_sub_ext[32];
                overflow = (~a[31]&b[31]&result[31])|(a[31]&~b[31]&~result[31]);
            end
            AND_OP:  result = a & b;
            OR_OP:   result = a | b;
            XOR_OP:  result = a ^ b;
            XNOR_OP: result = ~(a ^ b);
            SLT:     result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            MUL: begin
                mul_ext = a * b;
                result  = mul_ext[31:0];
                carry   = |mul_ext[63:32];
            end
            DIV: begin
                if (b == 32'd0) begin
                    result   = 32'hFFFFFFFF;
                    div_zero = 1'b1;
                end else
                    result = $signed(a) / $signed(b);
            end
            default: result = 32'd0;
        endcase

        zero = (result == 32'd0);
    end
endmodule

// 7-segment decoder, common-anode active-low
module seg7_dec (
    input  wire [3:0] digit,
    output reg  [7:0] seg
);
    always @(*) begin
        case (digit)
            4'h0: seg = 8'b1100_0000;
            4'h1: seg = 8'b1111_1001;
            4'h2: seg = 8'b1010_0100;
            4'h3: seg = 8'b1011_0000;
            4'h4: seg = 8'b1001_1001;
            4'h5: seg = 8'b1001_0010;
            4'h6: seg = 8'b1000_0010;
            4'h7: seg = 8'b1111_1000;
            4'h8: seg = 8'b1000_0000;
            4'h9: seg = 8'b1001_0000;
            4'hA: seg = 8'b1000_1000;
            4'hB: seg = 8'b1000_0011;
            4'hC: seg = 8'b1100_0110;
            4'hD: seg = 8'b1010_0001;
            4'hE: seg = 8'b1000_0110;
            4'hF: seg = 8'b1000_1110;
            default: seg = 8'b1111_1111;
        endcase
    end
endmodule

// ===========================================================
//  TOP MODULE
// ===========================================================
module risc_top #(
    parameter DB_LIMIT  = 20'd999_999,
    parameter DIV_LIMIT = 27'd49_999_999
)(
    input  wire        clk,
    input  wire [15:0] sw,
    input  wire [3:0]  btn,
    output wire [15:0] led,
    output wire [7:0]  D0_SEG,
    output reg  [3:0]  D0_AN,
    output wire [7:0]  D1_SEG,
    output reg  [3:0]  D1_AN,
    output wire [2:0]  RGB0,
    output wire [2:0]  RGB1
);

    // Buttons
    wire rst, btn1_db, btn2_db;
    debounce #(.DB_LIMIT(DB_LIMIT)) db_rst  (.clk(clk), .btn_in(btn[0]), .btn_out(rst));
    debounce #(.DB_LIMIT(DB_LIMIT)) db_stp  (.clk(clk), .btn_in(btn[1]), .btn_out(btn1_db));
    debounce #(.DB_LIMIT(DB_LIMIT)) db_mode (.clk(clk), .btn_in(btn[2]), .btn_out(btn2_db));

    // PC clock: auto ~1 Hz, or manual single-step
    wire slow_clk, step_pulse;
    clk_divider #(.DIV_LIMIT(DIV_LIMIT)) clkdiv (.clk(clk), .reset(rst), .slow_clk(slow_clk));
    edge_detect ed_stp (.clk(clk), .sig_in(btn1_db), .pulse(step_pulse));
    wire pc_clk = btn2_db ? step_pulse : slow_clk;

    // Program counter + instruction memory
    wire [7:0] pc_val;
    prog_counter pc0 (.clk(pc_clk), .reset(rst), .pc_out(pc_val));

    wire [31:0] instr;
    instr_mem imem (.word_addr(pc_val[5:2]), .instr(instr));

    // Real RV32I instruction fields
    wire [6:0] opcode = instr[6:0];
    wire [4:0] rd     = instr[11:7];
    wire [2:0] funct3 = instr[14:12];
    wire [4:0] rs1    = instr[19:15];
    wire [4:0] rs2    = instr[24:20];
    wire [6:0] funct7 = instr[31:25];

    wire [31:0] imm_i;
    imm_gen ig0 (.instr(instr), .imm_i(imm_i));

    // Control
    wire [3:0] alu_op;
    wire       reg_wr, alu_src_imm;
    alu_control cu0 (.opcode(opcode), .funct3(funct3), .funct7(funct7),
                      .alu_op(alu_op), .reg_write(reg_wr), .alu_src_imm(alu_src_imm));

    // Register file: x1 <= sw[3:0], x2 <= sw[7:4] at reset
    wire [31:0] rf_q1, rf_q2, alu_res;
    reg_file rf0 (
        .clk(pc_clk), .reset(rst), .we(reg_wr),
        .rs1(rs1), .rs2(rs2), .rd(rd), .wdata(alu_res),
        .sw_x1({28'd0, sw[3:0]}), .sw_x2({28'd0, sw[7:4]}),
        .rdata1(rf_q1), .rdata2(rf_q2)
    );

    wire [31:0] alu_b = alu_src_imm ? imm_i : rf_q2;

    wire f_carry, f_zero, f_ovf, f_divz;
    alu_unit alu0 (
        .a(rf_q1), .b(alu_b), .alu_op(alu_op), .result(alu_res),
        .zero(f_zero), .carry(f_carry), .overflow(f_ovf), .div_zero(f_divz)
    );

    // LEDs
    assign led[7:0]   = alu_res[7:0];
    assign led[8]     = f_zero;
    assign led[9]     = f_carry;
    assign led[10]    = f_ovf;
    assign led[11]    = f_divz;
    assign led[14:12] = funct3;
    assign led[15]    = |sw[15:8] | btn[3];

    // 7-segment: lower byte of the ALU result
    seg7_dec sd0 (.digit(alu_res[3:0]), .seg(D0_SEG));
    seg7_dec sd1 (.digit(alu_res[7:4]), .seg(D1_SEG));

    always @(posedge clk) begin
        D0_AN <= 4'b1110;
        D1_AN <= 4'b1110;
    end

    // RGB0: flags   RGB1: instruction class (I-type / base R-type / RV32M)
    assign RGB0 = {f_ovf, f_zero, f_carry};
    assign RGB1[0] = (opcode == 7'b0010011);                            // I-type -> red
    assign RGB1[1] = (opcode == 7'b0110011) && (funct7 != 7'b0000001);  // base R-type -> green
    assign RGB1[2] = (funct7 == 7'b0000001);                            // RV32M -> blue

endmodule