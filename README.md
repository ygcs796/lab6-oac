# RISC-V Single-Cycle com MMIO

Implementação em SystemVerilog de um processador RISC-V RV32I single-cycle com suporte a Memory-Mapped I/O (MMIO), baseada no Capítulo 4 de *Patterson & Hennessy — Computer Organization and Design (RISC-V Edition)*. Alvo: placa **DE2-115** (Intel Cyclone IV E, EP4CE115F29C7, 50 MHz).

---

## Sumário

1. [Compilando um programa com o assembler](#compilando-um-programa-com-o-assembler)
2. [Organização do MMIO](#organização-do-mmio)
3. [Arquitetura](#arquitetura)
4. [Instruções suportadas](#instruções-suportadas)
5. [Sinais de controle](#sinais-de-controle)
6. [Síntese no Quartus](#síntese-no-quartus)
7. [Simulação no ModelSim](#simulação-no-modelsim)

---

## Compilando um programa com o assembler

O script `assembler/assembler.py` traduz um arquivo de texto com instruções RISC-V para um arquivo `.mif` no formato que o Quartus usa para inicializar a memória de instruções na FPGA.

### 1. Escreva o programa em `assembler/instructions.txt`

Uma instrução por linha, sem rótulos. Formatos aceitos:

```
<instr> <rd>,<rs1>,<rs2>        # R-type  (ex: add  x3,x1,x2)
<instr> <rd>,<rs1>,<imm>        # I-type  (ex: addi x1,x0,8)
<instr> <rd>,<imm>(<rs1>)       # Load    (ex: lw   x2,0(x1))
<instr> <rs2>,<imm>(<rs1>)      # Store   (ex: sw   x2,8(x1))
<instr> <rs1>,<rs2>,<imm>       # Branch  (ex: beq  x0,x0,-8)
<instr> <rd>,<imm>              # U / J   (ex: lui  x1,1)
```

**Exemplo** — espelhar SW nos LEDR continuamente:

```
lw x1,0(x0)
lw x2,0(x1)
sw x2,8(x1)
beq x0,x0,-8
```

### 2. Execute o assembler

```bash
cd assembler
python3 assembler.py
```

O script gera `assembler/instruction.mif`. Cada linha corresponde a uma **palavra de 32 bits** com o seu **endereço de palavra** em hexadecimal (endereço de palavra = endereço de byte / 4):

```
DEPTH = 256;
WIDTH = 32;
ADDRESS_RADIX = HEX;
DATA_RADIX = HEX;
CONTENT
BEGIN

000 : 00002083;  -- lw x1,0(x0)
001 : 0000A103;  -- lw x2,0(x1)
002 : 0020A423;  -- sw x2,8(x1)
003 : FE000CE3;  -- beq x0,x0,-8
END;
```

### 3. Copie o MIF para a raiz do projeto

```bash
cp assembler/instruction.mif instruction.mif
```

O módulo `sc_imem.sv` lê `instruction.mif` via atributo de síntese:

```systemverilog
(* ram_init_file = "instruction.mif" *) logic [31:0] rom [0:255];
```

O Quartus embute o conteúdo desse arquivo no bitstream durante a compilação. Para trocar de programa, basta gerar um novo `.mif`, copiá-lo e recompilar.

### 4. Memória de dados inicial

Se o programa precisar de constantes pré-carregadas em `dmem` (por exemplo, o endereço base MMIO `0x400`), crie ou edite um arquivo `.mif` no mesmo formato e aponte para ele em `sc_dmem.sv`:

```systemverilog
(* ram_init_file = "meu_data.mif" *) logic [31:0] ram [0:255];
```

Exemplo de `data.mif` com o endereço base MMIO na palavra 0:

```
000 : 00000400;  -- MMIO base (lido por: lw x1, 0(x0))
[001..0FF] : 00000000;
```

### 5. Resintetize e grave na FPGA

No Quartus: **Processing → Start Compilation**, depois **Tools → Programmer**.

---

## Organização do MMIO

O MMIO é implementado no módulo `sc_mmio.sv` e mapeia os periféricos físicos da DE2-115 no espaço de endereços do processador.

### Decodificação de endereço

A separação entre memória de dados e MMIO é feita pelo **bit 10** do resultado da ULA (endereço calculado pela instrução `lw`/`sw`):

```
alu_result[10] = 0  →  sc_dmem  (0x000 – 0x3FC, memória de dados comum)
alu_result[10] = 1  →  sc_mmio  (0x400 – 0x40C, periféricos)
```

Dentro da janela MMIO, os bits `[3:2]` selecionam o periférico:

```
alu_result[3:2] = 00  →  0x400  SW[17:0]   (leitura)
alu_result[3:2] = 01  →  0x404  KEY[3:0]   (leitura)
alu_result[3:2] = 10  →  0x408  LEDR[17:0] (escrita)
alu_result[3:2] = 11  →  0x40C  LEDG[8:0]  (escrita)
```

### Mapa de endereços

| Endereço | Periférico  | Direção | Largura | Pinos DE2-115        |
|----------|-------------|---------|---------|----------------------|
| `0x400`  | `SW[17:0]`  | leitura | 18 bits | Chaves deslizantes   |
| `0x404`  | `KEY[3:0]`  | leitura | 4 bits  | Botões (KEY[0] = reset) |
| `0x408`  | `LEDR[17:0]`| escrita | 18 bits | LEDs vermelhos       |
| `0x40C`  | `LEDG[8:0]` | escrita | 9 bits  | LEDs verdes          |

### Comportamento elétrico

- **Leituras** (`lw`): combinatoriais — o valor nos pinos físicos é lido no ciclo em que a instrução executa.
- **Escritas** (`sw`): registradas — o valor é registrado no registrador de LED na borda de subida do clock do mesmo ciclo.
- **Reset** (`KEY[0]`, ativo em baixo): `LEDR` e `LEDG` são zerados assincronamente.

### Usando o MMIO no programa

O endereço base `0x400` não pode ser carregado diretamente com `addi` (campo imediato de 12 bits, mas o valor tem bit 10 = 1 e parte alta zero). A solução é armazená-lo na memória de dados e carregá-lo com `lw`:

```asm
# data.mif palavra 0 = 0x00000400
lw  x1,  0(x0)      # x1 = 0x400  (base MMIO)

lw  x2,  0(x1)      # lê SW[17:0]    (addr 0x400)
lw  x3,  4(x1)      # lê KEY[3:0]    (addr 0x404)
sw  x2,  8(x1)      # escreve LEDR   (addr 0x408)
sw  x3, 12(x1)      # escreve LEDG   (addr 0x40C)
```

O `MemWrite` é internamente multiplexado por `mmio_sel` para evitar que um `sw` para um endereço MMIO corrompa a memória de dados, e vice-versa:

```systemverilog
// sc_datapath.sv
sc_dmem dmem (.MemWrite(MemWrite & ~mmio_sel), .addr(alu_result[9:2]), ...);
sc_mmio mmio (.MemWrite(MemWrite &  mmio_sel), .addr(alu_result[3:2]), ...);
```

---

## Arquitetura

```
sc_top
├── pll_10mhz          — ALTPLL: 50 MHz → 10 MHz
└── sc_cpu
    ├── sc_control     — Unidade de controle (decodifica opcode)
    └── sc_datapath
        ├── sc_imem    — Memória de instruções (256 × 32 bits)
        ├── sc_regfile — Banco de registradores (32 × 32 bits)
        ├── sc_sign_ext— Extensor de sinal (formatos I, S, B)
        ├── sc_alu_ctrl— Controle da ALU
        ├── sc_alu     — ALU de 32 bits
        ├── sc_dmem    — Memória de dados (256 × 32 bits)
        └── sc_mmio    — MMIO: SW, KEY, LEDR, LEDG
```

### Memórias — leitura assíncrona

`sc_imem` e `sc_dmem` são implementadas como arrays SystemVerilog com leitura puramente combinacional:

```systemverilog
assign instr    = rom[addr];   // sc_imem: sem clock
assign ReadData = ram[addr];   // sc_dmem: sem clock
```

Escritas em `sc_dmem` são síncronas na borda de subida:

```systemverilog
always @(posedge clk)
    if (MemWrite) ram[addr] <= WriteData;
```

O Quartus infere **MLAB** (LUT-RAM) para arrays com leitura combinacional, que suportam leitura assíncrona no Cyclone IV.

### Clock e reset

O clock da CPU é **10 MHz**, derivado do `CLOCK_50` pelo PLL. O reset (`KEY[0]`) mantém o processador em reset até que o PLL trave (`pll_locked`), evitando execução em clock instável no boot.

---

## Instruções suportadas

### Hardware implementado (`sc_control.sv`)

| Tipo   | Instrução | Opcode    |
|--------|-----------|-----------|
| R-type | `add`, `sub`, `and`, `or`, `slt` | `0110011` |
| I-type | `lw`      | `0000011` |
| S-type | `sw`      | `0100011` |
| B-type | `beq`     | `1100011` |

### Suportadas pelo assembler (requerem extensão do controle)

O assembler codifica corretamente todas as instruções abaixo, mas o hardware precisaria ser estendido para executá-las:

| Tipo   | Instruções |
|--------|-----------|
| R-type | `xor`, `sll`, `srl`, `sra`, `sltu` |
| I-type | `addi`, `slti`, `xori`, `ori`, `andi`, `slli`, `srli`, `srai`, `jalr` |
| S-type | `sb`, `sh` |
| B-type | `bne`, `blt`, `bge`, `bltu`, `bgeu` |
| U-type | `lui`, `auipc` |
| J-type | `jal` |

---

## Sinais de controle

| Sinal    | R-type | `lw` | `sw` | `beq` |
|----------|:------:|:----:|:----:|:-----:|
| ALUSrc   | 0      | 1    | 1    | 0     |
| MemtoReg | 0      | 1    | —    | —     |
| RegWrite | 1      | 1    | 0    | 0     |
| MemRead  | 0      | 1    | 0    | 0     |
| MemWrite | 0      | 0    | 1    | 0     |
| Branch   | 0      | 0    | 0    | 1     |
| ALUOp    | `10`   | `00` | `00` | `01`  |

ALUOp: `00` = força ADD (load/store), `01` = força SUB (branch), `10` = R-type (ALU ctrl decodifica funct3/funct7).

---

## Síntese no Quartus

1. Abra `quartus/riscv_single_cycle.qpf` no **Quartus Prime 21.1**.
2. Certifique-se de que `instruction.mif` e o `.mif` de dados estão na **raiz do projeto**.
3. Execute **Processing → Start Compilation**.
4. Grave com **Tools → Programmer** (USB-Blaster, dispositivo EP4CE115F29C7).

---

## Simulação no ModelSim

Os arquivos `modelsim/program.hex` e `modelsim/data.hex` são carregados via `$readmemh` nos blocos `initial` (guardados por `// synthesis translate_off`).

```bash
cd modelsim

vlog -sv ../sc_alu.sv ../sc_alu_ctrl.sv ../sc_control.sv \
         ../sc_sign_ext.sv ../sc_regfile.sv               \
         ../sc_imem.sv ../sc_dmem.sv ../sc_mmio.sv        \
         ../sc_datapath.sv ../sc_cpu.sv ../sc_cpu_tb.sv

vsim work.sc_cpu_tb
run -all
```

O testbench imprime cada escrita no console, gera `output.txt` e compara com `golden.txt`:

```
[cycle   5] REG  x1  <= 00000400
[cycle   6] MMIO LEDR  <= 3ffff
=== PASS: all 36 lines match ===
```

---

## Referências

- Patterson, D. A.; Hennessy, J. L. *Computer Organization and Design: RISC-V Edition*. 2ª ed. Morgan Kaufmann, 2020. Capítulos 4.1–4.4.
- [RISC-V Instruction Set Manual, Volume I: Unprivileged ISA](https://riscv.org/specifications/)
