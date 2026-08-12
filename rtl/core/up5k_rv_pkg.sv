// up5k-rv -- M1 P2-1: core package.
//
// Shared constants and types for the RV32I core. No logic here -- this
// package only declares names used by the leaf modules and the core top.
// One module per file rule is satisfied (a package is not a module).
//
// Decode constants follow the RISC-V base integer instruction format
// (RV32I). Shift-immediate handling: `slli/srli/srai` place shamt in
// insn[24:20]; funct7 bit 0 distinguishes srai/sra from srli/srl.
//
// Stage scope (deepwork m1-core-rvfi.md P2-1): this file only.

package up5k_rv_pkg;

  // ---- RV32I opcodes (insn[6:0]) -------------------------------------------
  localparam logic [6:0] OPCODE_OP     = 7'b0110011;  // register-register ALU
  localparam logic [6:0] OPCODE_OP_IMM = 7'b0010011;  // immediate ALU
  localparam logic [6:0] OPCODE_LUI    = 7'b0110111;
  localparam logic [6:0] OPCODE_AUIPC  = 7'b0010111;
  localparam logic [6:0] OPCODE_JAL    = 7'b1101111;
  localparam logic [6:0] OPCODE_JALR   = 7'b1100111;
  localparam logic [6:0] OPCODE_BRANCH = 7'b1100011;
  localparam logic [6:0] OPCODE_LOAD   = 7'b0000011;
  localparam logic [6:0] OPCODE_STORE  = 7'b0100011;
  localparam logic [6:0] OPCODE_MISC_MEM = 7'b0001111;  // fence, fence.i
  localparam logic [6:0] OPCODE_SYSTEM = 7'b1110011;    // ecall/ebreak/csr

  // ---- funct3 values --------------------------------------------------------
  localparam logic [2:0] FUNCT3_BEQ  = 3'b000;
  localparam logic [2:0] FUNCT3_BNE  = 3'b001;
  localparam logic [2:0] FUNCT3_BLT  = 3'b100;
  localparam logic [2:0] FUNCT3_BGE  = 3'b101;
  localparam logic [2:0] FUNCT3_BLTU = 3'b110;
  localparam logic [2:0] FUNCT3_BGEU = 3'b111;

  localparam logic [2:0] FUNCT3_LB  = 3'b000;
  localparam logic [2:0] FUNCT3_LH  = 3'b001;
  localparam logic [2:0] FUNCT3_LW  = 3'b010;
  localparam logic [2:0] FUNCT3_LBU = 3'b100;
  localparam logic [2:0] FUNCT3_LHU = 3'b101;

  localparam logic [2:0] FUNCT3_SB = 3'b000;
  localparam logic [2:0] FUNCT3_SH = 3'b001;
  localparam logic [2:0] FUNCT3_SW = 3'b010;

  // ---- M-extension (OP opcode, funct7 = 0000001) ----------------------------
  localparam logic [6:0] FUNCT7_M = 7'b0000001;

  // ---- C-extension quadrants (insn[1:0] of a 16-bit instruction) ------------
  localparam logic [1:0] C_QUAD0 = 2'b00;  // c.addi4spn, c.lw, c.sw
  localparam logic [1:0] C_QUAD1 = 2'b01;  // c.addi, c.jal, c.li, c.lui/c.addi16sp,
                                           // c.srli/c.srai/c.andi/c.sub/xor/or/and,
                                           // c.j, c.beqz/c.bnez
  localparam logic [1:0] C_QUAD2 = 2'b10;  // c.slli, c.lwsp, c.swsp,
                                           // c.mv/c.jr, c.add/c.jalr/c.ebreak

  // ---- ALU operations -------------------------------------------------------
  typedef enum logic [4:0] {
    ALU_ADD,
    ALU_SUB,
    ALU_SLL,
    ALU_SLT,
    ALU_SLTU,
    ALU_XOR,
    ALU_SRL,
    ALU_SRA,
    ALU_OR,
    ALU_AND,
    // M-extension ALTOPS fake ops (D18): (rs1 +- rs2) ^ mask, byte-exact vs the
    // riscv-formal rv32imc models (which assert rvfi_rd_wdata exactly). Real
    // fixed-latency MUL/DIV (D6) replace these at M3 with wrapper-side ALTOPS
    // compensation.
    ALU_MUL_ALT,
    ALU_MULH_ALT,
    ALU_MULHSU_ALT,
    ALU_MULHU_ALT,
    ALU_DIV_ALT,
    ALU_DIVU_ALT,
    ALU_REM_ALT,
    ALU_REMU_ALT
  } alu_op_e;

  // ---- CSR read-modify-write class -------------------------------------------
  typedef enum logic [1:0] {
    CSR_RW,  // csrrw / csrrwi:      write operand unconditionally
    CSR_RS,  // csrrs / csrrsi:      set bits (write only if operand != 0)
    CSR_RC   // csrrc / csrrci:      clear bits (write only if operand != 0)
  } csr_op_e;

  // ---- ALU operand-a source select ------------------------------------------
  typedef enum logic [1:0] {
    OPA_X0,   // zero (lui)
    OPA_RS1,  // register rs1
    OPA_PC    // current PC (auipc)
  } alu_a_sel_e;

  // ---- ALU operand-b source select ------------------------------------------
  typedef enum logic [1:0] {
    OPB_RS2,  // register rs2
    OPB_IMM,  // sign-extended I/S/B/J immediate, or zero-extended shamt
    OPB_UIMM  // upper immediate {insn[31:12], 12'b0} (lui/auipc)
  } alu_b_sel_e;

  // ---- Execute-pipeline phase -----------------------------------------------
  typedef enum logic [2:0] {
    PH_IDLE,  // waiting for a fetched instruction
    PH_ID,    // decode + register read
    PH_EX,    // ALU / branch resolve
    PH_MEM,   // LSU request (loads/stores only)
    PH_WB     // writeback + retire (RVFI asserted here)
  } phase_e;

  // ---- Fetch-unit phase ------------------------------------------------------
  typedef enum logic [1:0] {
    F_IDLE,   // idle, waiting for start_i / redirect_i
    F_REQ     // SBus read request outstanding (waiting rsp_valid_i)
  } fetch_phase_e;

endpackage
