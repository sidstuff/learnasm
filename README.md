# Learn x86-64 Assembly building a Brainfuck interpreter

<table><tr><td><b>We're going to be writing a Brainfuck interpreter with a REPL, in x86-64 NASM assembly for Linux. If you just want the final code or executable, visit <a href="https://github.com/sidstuff/bf-repl">sidstuff/bf-repl</a>.</b></td></tr></table>

> [!Note]
> Numbers beginning with `0x` are hexadecimal. Familiarity with them, as well as with the command line and basic computer concepts, is assumed throughout this tutorial.

Before we write any code, let's go over some prerequisites.

$\fbox{\textsf{Registers}}$ are small but fast memory in the CPU. They are made out of SRAM, which when compared to the DRAM main memory is made from, is faster and requires less power, but more transistors and thus space and money. x86 CPU registers each stored 32 bits. x86-64 increased this to 64.

A $\fbox{\textsf{CPU cache}}$ is a smaller, faster memory, located closer to a processor core, which stores copies of the data from frequently used main memory locations. Most CPUs have a hierarchy of multiple cache levels (L1, L2, often L3, and rarely even L4), with different instruction-specific and data-specific caches at level 1. The cache memory is typically implemented with SRAM, in modern CPUs by far the largest part of them by chip area, but SRAM is not always used for all levels (of I- or D-cache), or even any level, sometimes some latter or all levels are implemented with eDRAM.

Modern computers use $\fbox{\textsf{virtual memory}}$, where each process gets the same large virtual address space (say, `0x000000000000` to `0x7FFFFFFFFFFF`), which is divided into fixed-length (usually 4 KiB) contiguous blocks called pages for faster finding of memory locations. Physical memory is similarly divided into "frames" of the same size, and each process has a page table that maps its pages to frames. The page table is set up by the OS, and may be read and written during the virtual address translation process by the CPU's memory management unit (MMU) or by low-level system software or firmware. Recent mappings are stored to the MMU's translation lookaside buffer (TLB), an associative cache. Processes may share a single copy of a program/library on physical memory. A transfer of pages between main memory and an auxiliary store, such as a hard disk drive, is referred to as paging or swapping.

x86 registers could only store 32 bit virtual addresses, providing an address space of only 2³² B or 4 GiB, which became insufficient by the 2010s. Indeed, computer memory went from KB in the 80s to MB in the 90s, to GB in the 00s. However, such exponential growth is unsustainable, and has slowed down. The full 64 bit address space of 16 EiB will not be needed by the vast majority of users for decades to come.

AMD, therefore, decided that using the full 64 bit addresses increases the cost of address translation with no real benefit, and to only use the lower 48 bits. Moreover, the highest bit of these 48 is used akin to sign extension – the 16 unused bits must be copies of it. If it is `0`, it is user space (`0x0000000000000000` to `0x00007FFFFFFFFFFF`), and if it is `1`, it is kernel space (`0xFFFF800000000000` to `0xFFFFFFFFFFFFFFFF`), 128 TiB each. Page tables are stored in kernel space. If more memory is needed in the future, these canonical addresses can be expanded towards the middle without breaking existing software. The vast majority of the virtual address space is non-canonical.

Note that the maximum physical address space is 64 TiB because the kernel needs to map all of it (`0xffff888000000000` to `0xffffc87fffffffff`)and still have space left over.[^1]
[^1]: https://www.kernel.org/doc/html/latest/arch/x86/x86_64/mm.html

The highest 4096 bytes comprise a special guard page you can't map to,[^2] bringing us to `0x7ffffffff000`. At the highest addresses, the ELF auxiliary vector, environment variables, and command-line arguments are stored. Below it, we have a data structure called the $\fbox{\textsf{stack}}$ that grows downwards (so the top of the stack has the lowest address), and you can push values onto the top of it, or pop them off the top into a register. Its maximum size on Linux is 8 MiB and exceeding that causes the stack overflow error. However, due to address space layout randomization (ASLR), a security feature, all these are offset by a random amount downwards. The maximum address is changed by randomizing a certain number of its bits (given by the kernel tunable [vm.mmap_rnd_bits](https://sysctl-explorer.net/vm/mmap_rnd_bits)), usually 28: `0x7f???????000`. Linux also has kernel address space layout randomization (KASLR).
[^2]: https://github.com/torvalds/linux/blob/b18cb64ead400c01bf1580eeba330ace51f8087d/arch/x86/include/asm/processor.h#L757 

A $\fbox{\textsf{position independent executable (PIE)}}$, can have its load address randomized as well, but due to the slight overhead of relative addressing, PIEs aren't always used. Shared libraries, however, must be position independent so that they can be loaded to any desired address.

---

A CPU architechture has a set of instructions, each represented by a numeric code, that it can execute. Machine code consists of these instructions' opcodes and operands, and is directly run by the CPU. Assembly laguage is human readable code whose instructions strongly correspond to machine code instructions, but also includes constants, comments, assembler directives, and symbolic labels. An assembler converts assembly code to an object file that contains machine code and other data. We will be using Linux system calls, and the NASM assembler and syntax. NASM is case-insensitive, except for symbol names, and Whitespace and indentation do not matter.

The assembler can produce output in a variety of formats, with the required headers, sections, etc. The Executable and Linkable Format (ELF) is the standard binary file format for Unix and Unix-like systems. In ELF, some special section names that begin with a period, have a predefined type and attributes. Common ones are:

<table><tr><td>.text</td><td>the program instructions, executable</td>
</tr><tr>
<td>.bss</td><td>zero-initialized data that occupies no file space, writable</td>
</tr><tr>
<td>.data</td><td>initiaized data stored in the file, writable</td>
</tr><tr>
<td>.rodata</td><td>read only data</td>
</tr><tr>
<td>.symtab</td><td>symbol table</td>
</tr><tr>
<td>.strtab</td><td>string table, holds the symbol names</td>
</tr><tr>
<td>.shstrab</td><td>section header string table, holds the section names</td>
</tr></table>

Let's start writing a simple hello world program [`hello.asm`](hello.asm). First, `.rodata`
```asm
section .rodata

strWelcome:    db "Hello, World!", 10
strWelcomeLen equ $-strWelcome
```
The `db` (define byte) pseudo-instruction places an array of bytes (here the characters of the string and a newline) in the output file, starting at the label `strWelcome`. Soon we'll print this to the terminal; any modern one almost certainly uses the UTF-8 character encoding. 10 or `0xA` is the character code for a line feed (`LF`), which is the newline in Unix. A UTF-8 character may need upto four bytes: 😀 is `0xF0, 0x9F, 0x98, 0x80`. You can look up these codes at [UTF-8 Tool](https://www.cogsci.ed.ac.uk/~richard/utf-8.cgi). We also have `dw`, `dd`, and `dq` for words (16 bits), doublewords (32 bits), and quadwords (64 bits), repectively.

NASM supports two special tokens `$` and `$$`, which evaluate to the assembly position at the beginning of the line and the current section, respectively. Thus subtracting the positition of the label `strWelcome` from `$` yields the number of bytes we just placed.

The `equ` pseudo-instruction lets you define a symbol to a constant value that cannot be changed later. All instances of the symbol are simply replaced with that value in the output.

Now, `.text`
```asm
section .text

SYSCALL_WRITE equ 1
SYSCALL_EXIT  equ 60
STDOUT equ 1
```
The POSIX file descriptors for `stdin`, `stdout`, and `stderr`, are 0, 1, and 2, respectively. We also need the Linux system call numbers to request services from the OS.

x86-64 CPUs have 16 64-bit general purpose registers (GPRs): `rax`, `rcx`, `rdx`, `rbx`, `rsp`, `rbp`, `rsi`, `rdi`, `r8`, `r9`, `r10`, `r11`, `r12`, `r13`, `r14`, `r15`. For statically linked ELF binaries on Linux, these are zero-initialized (except for `rsp`, more on it near the end).[^3] Even so, it's best practice to explicitly zero those that need to be zero-initialized, for the sake of clarity and ease of adding to the code. We'll see how, very soon. Memory locations are indicated by square brackets around their address, expressed in a valid [addressing mode](https://en.wikipedia.org/wiki/Addressing_mode). `mov r, s` means copy `s` to `r`.
[^3]: https://stackoverflow.com/q/9147455

For system calls, we store the syscall number in `rax` and its arguments in the specified registers (look these up at [Linux Syscall Table](https://filippo.io/linux-syscall-table)), then use the `syscall` instruction. The return value, if any, appears in `rax`. A failed syscall returns negative `errno` (in two's complement) to `rax` (look these up at [Linux Error Number Table](https://www.chromium.org/chromium-os/developer-library/reference/linux-constants/errnos) or run `errno -l`). `rcx` and `r11` are clobbered by syscalls (their values end up destroyed).
```asm
mov rax, SYSCALL_WRITE    ; syscall to be made - write()
mov rdi, STDOUT           ; arg 1: where to write to
mov rsi, strWelcome       ; arg 2: where in buffer to write from
mov rdx, strWelcomeLen    ; arg 3: max num of bytes to write
syscall                   ; Write up to rdx bytes to rdi from the buffer starting at rsi.
                          ; Returns to rax the num of bytes written.

mov rax, SYSCALL_EXIT     ; syscall to be made - exit()
xor edi, edi              ; Exit code 0
syscall                   ; Exit with status 0
                          ; Does not return any value
```
`edi`, `di`, and `dil` refer to the lower `32`, `16`, and `8` bits of `rdi`. Similar notation exists for other registers too, see [Registers in x86 Assembly](https://www.cs.uaf.edu/2017/fall/cs301/lecture/09_11_registers.html). The result of `xor r, s` is stored in `r`, so `xor r, r` is just a faster and smaller instruction to zero `r`.[^4] An additional byte called the REX prefix is required for 64 bit and all numbered registers (8–15). `edi` is used here instead of `rdi` to save a byte, Since all instructions with a 32-bit destination operand zero the upper 32 bits. This does not apply to 8 or 16 bit operands and can cause dependency between instructions that prevents out-of-order execution and register renaming.<a href="#id">†</a> Even for numbered registers where using their 32 bit versions would not save a byte, it is still preferred, since Silvermont CPUs do not recognize `xor r64, r64` as dependency-breaking.[^4]. Also, NASM optimizes `mov r64, imm32` to `mov r32, imm32`.
[^4]: https://stackoverflow.com/a/33668295

<a id="ref" href="#ref">†</a> To avoid this, `movzx`/`movsx` can be used, which zero/sign-extends the 8 or 16 bit value to fill the register, breaking dependency. Their latency and throughput are also not significantly different from `mov`. To look up such values for various CPUs, see [Agner Fog's instruction tables](http://www.agner.org/optimize/#manual_instr_tab). Also, yes, a named register is an abstraction and the CPU can assign it any physical register on the fly, allowing out-of-order execution based on the availability of input data and execution units. Modern CPUs also implement instruction-level parallelism via superscalar execution, i.e., executing more than one instruction during a clock cycle by simultaneously dispatching multiple instructions to different execution units on the processor.

Now let's assemble it into an ELF file
```
nasm -f elf64 -o hello.o hello.asm
```
You can omit `-o hello.o` here since that will be the output name by default. To analyze it, run `readelf -a hello.o`
```
ELF Header:
  Magic:   7f 45 4c 46 02 01 01 00 00 00 00 00 00 00 00 00 
  Class:                             ELF64
  Data:                              2's complement, little endian
  Version:                           1 (current)
  OS/ABI:                            UNIX - System V
  ABI Version:                       0
  Type:                              REL (Relocatable file)
  Machine:                           Advanced Micro Devices X86-64
  Version:                           0x1
  Entry point address:               0x0
  Start of program headers:          0 (bytes into file)
  Start of section headers:          64 (bytes into file)
  Flags:                             0x0
  Size of this header:               64 (bytes)
  Size of program headers:           0 (bytes)
  Number of program headers:         0
  Size of section headers:           64 (bytes)
  Number of section headers:         7
  Section header string table index: 3

Section Headers:
  [Nr] Name              Type             Address           Offset    Size              EntSize          Flags  Link  Info  Align
  [ 0]                   NULL             0000000000000000  00000000  0000000000000000  0000000000000000           0     0     0
  [ 1] .rodata           PROGBITS         0000000000000000  00000200  000000000000000e  0000000000000000   A       0     0     4
  [ 2] .text             PROGBITS         0000000000000000  00000210  0000000000000024  0000000000000000  AX       0     0     16
  [ 3] .shstrtab         STRTAB           0000000000000000  00000240  0000000000000034  0000000000000000           0     0     1
  [ 4] .symtab           SYMTAB           0000000000000000  00000280  00000000000000d8  0000000000000018           5     9     8
  [ 5] .strtab           STRTAB           0000000000000000  00000360  0000000000000046  0000000000000000           0     0     1
  [ 6] .rela.text        RELA             0000000000000000  000003b0  0000000000000018  0000000000000018           4     2     8
Key to Flags:
  W (write), A (alloc), X (execute), M (merge), S (strings), I (info), L (link order), O (extra OS processing required),
  G (group), T (TLS), C (compressed), x (unknown), o (OS specific), E (exclude), D (mbind), l (large), p (processor specific)

There are no section groups in this file.

There are no program headers in this file.

There is no dynamic section in this file.

Relocation section '.rela.text' at offset 0x3b0 contains 1 entry:
  Offset          Info           Type           Sym. Value    Sym. Name + Addend
00000000000c  000200000001 R_X86_64_64       0000000000000000 .rodata + 0
No processor specific unwind information to decode

Symbol table '.symtab' contains 9 entries:
   Num:    Value          Size Type    Bind   Vis      Ndx Name
     0: 0000000000000000     0 NOTYPE  LOCAL  DEFAULT  UND 
     1: 0000000000000000     0 FILE    LOCAL  DEFAULT  ABS hello.asm
     2: 0000000000000000     0 SECTION LOCAL  DEFAULT    1 .rodata
     3: 0000000000000000     0 SECTION LOCAL  DEFAULT    2 .text
     4: 0000000000000000     0 NOTYPE  LOCAL  DEFAULT    1 strWelcome
     5: 000000000000000e     0 NOTYPE  LOCAL  DEFAULT  ABS strWelcomeLen
     6: 0000000000000001     0 NOTYPE  LOCAL  DEFAULT  ABS SYSCALL_WRITE
     7: 000000000000003c     0 NOTYPE  LOCAL  DEFAULT  ABS SYSCALL_EXIT
     8: 0000000000000001     0 NOTYPE  LOCAL  DEFAULT  ABS STDOUT

No version information found in this file.
```
As you can see, this is a relocatable file. We need to assign everything their runtime load addresses. A linker combines multiple object files into a single executable, library, or object file. Here we only have a single object file, but the linker can also perform relocation. Let's use the GNU linker `ld`. The `-T` flag lets us specify a custom linker script, and `-s` strips the now unneeded symbol information from the output file (equivalent to using the `strip` command afterwards). So let's run
```bash
echo 'SECTIONS { . = 0x100e8; }' | ld -s -T /dev/stdin -o hello hello.o
```
The period is the location counter. We're simply starting the sections from the address `0x100e8`. Why? In Linux, [vm.mmap_min_addr](https://wiki.debian.org/mmap_min_addr) is a kernel tunable that specifies the minimum virtual address that a process is allowed to mmap, for security reasons. You can check your value using `cat /proc/sys/vm/mmap_min_addr`, the default is usually `0x10000`. In the ELF executable, we also have a 64 B ELF header and two 56 B program headers (for the two segments) before the sections, hence they begin another 176 (`0xe8`) bytes later. You can see this by running `readelf -a hello`
```
ELF Header:
  Magic:   7f 45 4c 46 02 01 01 00 00 00 00 00 00 00 00 00 
  Class:                             ELF64
  Data:                              2's complement, little endian
  Version:                           1 (current)
  OS/ABI:                            UNIX - System V
  ABI Version:                       0
  Type:                              EXEC (Executable file)
  Machine:                           Advanced Micro Devices X86-64
  Version:                           0x1
  Entry point address:               0x100f0
  Start of program headers:          64 (bytes into file)
  Start of section headers:          320 (bytes into file)
  Flags:                             0x0
  Size of this header:               64 (bytes)
  Size of program headers:           56 (bytes)
  Number of program headers:         2
  Size of section headers:           64 (bytes)
  Number of section headers:         4
  Section header string table index: 3

Section Headers:
  [Nr] Name              Type             Address           Offset    Size              EntSize          Flags  Link  Info  Align
  [ 0]                   NULL             0000000000000000  00000000  0000000000000000  0000000000000000           0     0     0
  [ 1] .text             PROGBITS         00000000000100f0  000000f0  0000000000000024  0000000000000000  AX       0     0     16
  [ 2] .rodata           PROGBITS         0000000000010114  00000114  000000000000000e  0000000000000000   A       0     0     4
  [ 3] .shstrtab         STRTAB           0000000000000000  00000122  0000000000000019  0000000000000000           0     0     1
Key to Flags:
  W (write), A (alloc), X (execute), M (merge), S (strings), I (info), L (link order), O (extra OS processing required),
  G (group), T (TLS), C (compressed), x (unknown), o (OS specific), E (exclude), D (mbind), l (large), p (processor specific)

There are no section groups in this file.

Program Headers:
  Type           Offset             VirtAddr           PhysAddr           FileSiz            MemSiz              Flags  Align
  LOAD           0x0000000000000000 0x0000000000010000 0x000000000000f000 0x00000000000000b0 0x00000000000000b0  R      0x1000
  LOAD           0x00000000000000f0 0x00000000000100f0 0x00000000000100f0 0x0000000000000032 0x0000000000000032  R E    0x1000

 Section to Segment mapping:
  Segment Sections...
   00     
   01     .text .rodata 

There is no dynamic section in this file.

There are no relocations in this file.
No processor specific unwind information to decode

No version information found in this file.
```
You may have noticed that the sections actually start at `0x100f0`, that is because the sections are padded and aligned for faster memory access. Add `align=1` after the section names and the exact value will be used. Anyway, let's run our program.
```
~ $ ./hello
Hello, World!
~$
```

Perfect. Now let's start writing the code `bf.asm` for the Brainfuck interpreter `bf`. We can actually just put the welcome string in the `.text` section, but to prevent its execution, we have to specify the entry point to be after it.

If using a custom linker script, here's how the entry point is determined, in descending order of priority:[^5]
* the `-e' entry command-line option;
* the ENTRY(symbol) command in a linker control script;
* the value of the symbol start, if present;
* the address of the first byte of the .text section, if present;
* The address 0.
[^5]: https://ftp.gnu.org/old-gnu/Manuals/ld-2.9.1/html_node/ld_24.html

Let's use the symbol `start`. By default, symbols are for internal use only, so we have to use the `global` directive. We'll also add a `.bss` section and reserve some bytes there using `resb`. As before, there also exists `resw`, `resd`, and `resq`. Also place some label there, that we can use to address memory locations in `.bss`. I'll use `PROG_BUFF`, short for the program buffer.
```asm
section .text
global start

strWelcome:    db "Brainfuck Interpreter v1.0", 10, 10
strWelcomeLen equ $-strWelcome

start:

SYSCALL_WRITE equ 1
SYSCALL_EXIT  equ 60
STDOUT equ 1

mov rax, SYSCALL_WRITE
mov rdi, STDOUT
mov rsi, strWelcome
mov rdx, strWelcomeLen
syscall

mov rax, SYSCALL_EXIT
xor edi, edi
syscall

section .bss
PROG_BUFF:
resb 0xA0000
```
Assembling and linking like before results in the warning
```
ld: warning: bf has a LOAD segment with RWX permissions
```
This is because .text and .bss have been put into the same segment with RWX permissions, which means that the user may be able to modify the code. To put them in separate RX and RW segments, we could use the `PHDRS` command in the custom linker script, but it's easier to just use the default linker script (run `ld --verbose` to print it). It uses `ENTRY(_start)`, so we'll have to replace `start` in our code with `_start`. To still begin the `.text` section at `0x100e8`, our command will be
```bash
ld -s -Ttext=0x100e8 -o bf bf.o
```
This time we get no warning. Running `readelf -a bf` yields
```
ELF Header:
  Magic:   7f 45 4c 46 02 01 01 00 00 00 00 00 00 00 00 00 
  Class:                             ELF64
  Data:                              2's complement, little endian
  Version:                           1 (current)
  OS/ABI:                            UNIX - System V
  ABI Version:                       0
  Type:                              EXEC (Executable file)
  Machine:                           Advanced Micro Devices X86-64
  Version:                           0x1
  Entry point address:               0x1010c
  Start of program headers:          64 (bytes into file)
  Start of section headers:          328 (bytes into file)
  Flags:                             0x0
  Size of this header:               64 (bytes)
  Size of program headers:           56 (bytes)
  Number of program headers:         3
  Size of section headers:           64 (bytes)
  Number of section headers:         4
  Section header string table index: 3

Section Headers:
  [Nr] Name              Type             Address           Offset    Size              EntSize          Flags  Link  Info  Align
  [ 0]                   NULL             0000000000000000  00000000  0000000000000000  0000000000000000           0     0     0
  [ 1] .text             PROGBITS         00000000000100e8  000000e8  0000000000000048  0000000000000000  AX       0     0     8
  [ 2] .bss              NOBITS           0000000000011000  00001000  00000000000a0000  0000000000000000  WA       0     0     4
  [ 3] .shstrtab         STRTAB           0000000000000000  00000130  0000000000000016  0000000000000000           0     0     1
Key to Flags:
  W (write), A (alloc), X (execute), M (merge), S (strings), I (info), L (link order), O (extra OS processing required),
  G (group), T (TLS), C (compressed), x (unknown), o (OS specific), E (exclude), D (mbind), l (large), p (processor specific)

There are no section groups in this file.

Program Headers:
  Type           Offset             VirtAddr           PhysAddr           FileSiz            MemSiz              Flags  Align
  LOAD           0x0000000000000000 0x0000000000010000 0x000000000000f000 0x00000000000000e8 0x00000000000000e8  R      0x1000
  LOAD           0x00000000000000e8 0x00000000000100e8 0x00000000000100e8 0x0000000000000048 0x0000000000000048  R E    0x1000
  LOAD           0x0000000000000000 0x0000000000011000 0x0000000000011000 0x0000000000000000 0x00000000000a0000  RW     0x1000

 Section to Segment mapping:
  Segment Sections...
   00     
   01     .text 
   02     .bss 

There is no dynamic section in this file.

There are no relocations in this file.
No processor specific unwind information to decode

No version information found in this file.
```
NASM does have a `segment` directive, but it is exactly equivalent to `section`.

Before we proceed, here's how a `read()` syscall is done.
```asm
SYSCALL_READ equ 0
STDIN equ 0
BUFF_MAX_SIZE equ 0x10000

mov rax, SYSCALL_READ     ; syscall to be made - read()
mov rdi, STDIN            ; arg 1: where to read from
mov rsi, PROG_BUFF        ; arg 2: where in buffer to read to
mov rdx, BUFF_MAX_SIZE    ; arg 3: max num of bytes to read
syscall                   ; Read upto rdx bytes from rdi into the buffer starting at rsi.
                          ; Returns to rax the num of bytes read
```
We'll read upto `0x10000` bytes of Brainfuck input. In the near future, I'll update this project to use `malloc` and work with arbitrarily large inputs.

In Brainfuck, we have an instruction pointer which points to the character being executed and moves from left to right, as well as a data/cell pointer which starts from zero (the first "cell") and points to a location in memory from/to which a byte can be read/written. We will use `rbp` and `rbx` for the cell and instruction pointers, respectively. Within a session, the position of the cell pointer, as well as the cell contents, is preserved across commands.

Here are the eight characters used in Brainfuck:
<table><tr><td><code>></code></td><td>increment data pointer</td>
</tr><tr>
<td><code><</code></td><td>decrement data pointer</td>
</tr><tr>
<td><code>+</code></td><td>increment byte at data pointer</td>
</tr><tr>
<td><code>-</code></td><td>decrement byte at data pointer</td>
</tr><tr>
<td><code>.</code></td><td>output byte at data pointer</td>
</tr><tr>
<td><code>,</code></td><td>store input byte at data pointer</td>
</tr><tr>
<td><code>[</code></td><td>if byte at data pointer is zero, jump to the character after the matching <code>]</code></td>
</tr><tr>
<td><code>]</code></td><td>if byte at data pointer is not zero, jump to the character after the matching <code>[</code></td>
</tr></table>

Anything else is ignored.

We will preprocess the Brainfuck code. For each `]` byte in the code, we'll store its 8 byte position, hence we need a `PP_BUFF_MAX_SIZE equ BUFF_MAX_SIZE * 8`. This PP (preprocessor) buffer will be stored `PP_BUFF equ PROG_BUFF + BUFF_MAX_SIZE` onwards in memory. After that, from `CELLS equ PP_BUFF + PP_BUFF_MAX_SIZE` onwards, we will store the user data – `0x10000` bytes of it, since we reserved a total of `0xA0000` bytes.

A couple more instructions we need to know before proceeding are `cmp` (compare), `jmp` (jump to), `je` (jump to if equal), and `jne` (jump to if not equal). For a full list of x86-84 instrictions, visit the [X86 Opcode and Instruction Reference](http://ref.x86asm.net/coder64.html).

If the user simply presses <kbd>⏎ Enter</kbd> when prompted for a command, the input is a single byte `0xA` (the newline) on Linux. So if the number of bytes read (which is returned to `rax`) is 1, we want our interpreter to exit.

Thus, our program structure will be
```asm
section .text
global _start

BUFF_MAX_SIZE    equ 0x10000
PP_BUFF_MAX_SIZE equ BUFF_MAX_SIZE * 8
PP_BUFF          equ PROG_BUFF + BUFF_MAX_SIZE
CELLS            equ PP_BUFF + PP_BUFF_MAX_SIZE

strWelcome:    db "Brainfuck Interpreter v1.0", 10, 10
strWelcomeLen equ $-strWelcome
strPrompt:     db "bf> "
strPromptLen  equ $-strPrompt

_start:

xor ebp, ebp   ; cell pointer

; say hello
mov rax, 1
mov rdi, 1
mov rsi, strWelcome
mov rdx, strWelcomeLen
syscall

mainLoop:

	; print prompt
	mov rax, 1
	mov rdi, 1
	mov rsi, strPrompt
	mov rdx, strPromptLen
	syscall
	
	; read input
	xor eax, eax
	xor edi, edi
	mov rsi, PROG_BUFF
	mov rdx, BUFF_MAX_SIZE
	syscall

	cmp rax, 1
	je exit
	
	ppLoop:
	; preprocess brainfuck code

	execLoop:
	; execute brainfuck code

	jmp mainLoop

exit:
mov rax, 60
xor edi, edi
syscall

section .bss
PROG_BUFF:
resb 0xA0000
```
`cmp r, s` is actually the same as `sub r, s` (subtract), except that `r` isn't overwritten with `r-s`. If these (or other arithmetic/logical) instructions produce zero, it sets what is called the zero flag (`ZF`) bit in the FLAGS register that is used by conditional instructions (jump, move, set byte, loop). Thus `je`/`jne` and `jz`/`jnz` (jump to if (not) zero) are the same instruction.

Other flags are the sign (`SF`), parity (`PF`), overflow (`OF`), and carry (`CF`) flags. `js`/`jns` will jump to if (not) negative.

`.bss` is zero initialized, so we didn't have to clear the cells. The code for this would have been
```asm
xor eax, eax
mov rcx, 0x10000
mov rdi, CELLS
rep stosb          ; Fill rcx bytes at [rdi] with al.
```

To learn more about the various assembly instructions, visit the [x86 and amd64 instruction reference](https://www.felixcloutier.com/x86).

`lea r, [addr]` (load effective address) calculates the effective address within the square brackets and copies it into `r`, provided it is a valid addressing mode, but is often used as a fast way to perform arithmetic in a single intruction.

In NASM, a label beginning with a single period, eg., `.subLabel`, is local and associated with the previous non-local label, say, `myLabel`; if needed, it can be referenced elsewhere as `myLabel.subLabel` and appears in the symbol table as such.

Now let's code the preprocessor loop.
```asm
mov r8, rax                                 ; r8 is now the num of bytes in the user command.
lea rbx, [r8 - 1]                           ; rbx = r8 - 1
                                            ; We will decrement rbx at the end of each loop and terminate at -1,
ppLoop:	                                    ; so rbx goes from r8-1 to 0, and we go from the last to first byte of the command.
	cmp byte [PROG_BUFF + rbx], ']'     ; Compare byte rbx of command with ']'
	jne .nst                            ; If not equal, jump to .nst
	push rbx                            ; Otherwise, add rbx to the top of the stack
	jmp .nnd                            ; and jump to .nnd
	.nst:
	cmp byte [PROG_BUFF + rbx], '['     ; Compare byte rbx of command with '['
	jne .nnd                            ; If not equal, jump to .nnd
	pop rsi                             ; Otherwise, pop the top of the stack into rsi
	mov qword [PP_BUFF + rbx*8], rsi    ; and copy it to [PP_BUFF + rbx*8]
	.nnd:
	dec rbx                             ; Decrement rbx
	jns ppLoop                          ; If rbx ≥ 0, run loop again
```
In summary, moving from right to left, if the byte at position `rbx` in the command is:
* `]`, push `rbx` to top of stack
* neither `]` nor `[`, skip
* `[`, pop top of stack to `[PP_BUFF + rbx*8]`

Thus, for a `[` at position `rbx` in the command, the position (in the command) of the corresponding `]` is given by the value at `[PP_BUFF + rbx*8]`

The execution loop will look like
```asm
mov rdx, 1                           ; Bytes to read/write
xor ebx, ebx                         ; Zero the instruction pointer

execLoop:                            ; We will increment rbx at the end of each loop and terminate at r8,
	                             ; so rbx goes from 0 to r8-1, and we go from the first to last byte of the command.
	mov cl, [PROG_BUFF + rbx]    ; Copy byte rbx of command to cl, the LSB of rcx
	
	; execute brainfuck code
	
	.next:
	inc rbx                      ; Move to the next character
	cmp rbx, r8                  ; If rbx < r8,
	jl execLoop                  ; run loop again

jmp mainLoop                         ; Otherwise, jump to mainLoop
```

The strategy for executing the Brainfuck code is
```asm
cmp cl, '�'
jne .notQue
; do the � thing
jmp .next

.notQue:
cmp cl, '￼'
jne .notObj
; do the ￼ thing
jmp .next

.notObj
; and so on. . .
```

Before we proceed, know that the register `rsp` always points to the top of the stack. Also, even if we don't wish to preserve the popped value, `pop r` where `r` is any register we don't mind overwriting, is smaller and faster than `add rsp, 8`. Of course, if you need to move the stack pointer by multiple register widths, `add` or `lea` is better. I'll pop unneeded values into `rsi`, since it never stores anything that we don't finish using immediately afterwards.

Thus our code is
```asm
cmp cl, '>'
jne .notRight
inc bp
jmp .next

.notRight:
cmp cl, '<'
jne .notLeft
dec bp
jmp .next

.notLeft:
cmp cl, '+'
jne .notInc
inc byte [CELLS + rbp]
jmp .next

.notInc:
cmp cl, '-'
jne .notDec
dec byte [CELLS + rbp]
jmp .next

.notDec:
cmp cl, '.'
jne .notPrt
mov rax, 1
mov rdi, 1
lea rsi, [CELLS + rbp]
syscall
jmp .next

.notPrt:
cmp cl, ','
jne .notInp
xor eax, eax
xor edi, edi
lea rsi, [CELLS + rbp]
syscall
jmp .next

.notInp:
cmp cl, '['
jne .notLBR
cmp byte [CELLS + rbp], 0
jne .notZero
mov rbx, [PP_BUFF + rbx*8]    ; move to corresponding ']'
jmp .next                     ; and jump to .next
.notZero:
push rbx                      ; push position of '[' to top of stack
jmp .next

.notLBR:
cmp cl, ']'
jne .next
cmp byte [CELLS + rbp], 0
je .isZero
mov rbx, [rsp]    ; move to corresponding '[', position of which is stored on top of the stack
jmp .next
.isZero:
pop rsi           ; remove positon of corresponding '[' from top of stack

.next:
```

Since `bp` is a 16-bit register, any attempt to increment/decrement it beyond the 2¹⁶ cells will just bring you to their opposite end. For instance, using `<` at the start of your Brainfuck code will take you to the very last cell.

And with that we have finished coding a Brainfuck interpreter with a read-eval-print loop (REPL). But there's a feature we can easily add to this. The ability to do `./bf code.b`.

The number of command line arguments supplied, `argc`, is at [rsp], the top of the stack. At `[rsp + 8]` is stored the address of the string `./bf` (argv[0], the first argument). At `[rsp + 16]` is stored the address of the string `code.b` (`argv[1]`, the second argument).

The open() syscall lets us open files in three modes: 0 is `O_RDONLY` (open read-only), 1 is `O_WRONLY` (open write-only), and 2 is `O_RDWR` (open read-write). The file descriptor of the opened file will be 3, but it's best not to use that fact since adding to the program may change that.

Anyway, we modify the code to
```asm
xor ebp, ebp    ; cell pointer

cmp qword [rsp], 1
je repl

; open file
mov rax, 2             ; syscall to be made - open()
mov rdi, [rsp + 16]    ; address of filename
xor esi, esi           ; mode 0 (O_RDONLY)
syscall                ; file descriptor of opened file is returned to rax
mov rdi, rax           ; copy it to rdi to read()
jmp readInput

repl:

; say hello
```
and
```asm
; print prompt
mov rax, 1
mov rdi, 1
mov rsi, strPrompt
mov rdx, strPromptLen
syscall

xor edi, edi
readInput:
xor eax, eax
mov rsi, PROG_BUFF
mov rdx, BUFF_MAX_SIZE
syscall
```
And after execution, jump to `mainLoop` only if in a REPL. That is,
```asm
cmp qword [rsp], 1
je mainLoop

exit:
```
`[rsp]` once again contains `argc` because any values pushed onto the stack during preprocessing or execution will have been popped off.

And with that, we are done. The final code is [here](bf.asm).

Let's try it out. After assembling and linking,
```
~ $ ./bf
Brainfuck Interpreter v1.0

bf> ,.,.,.,.
hey
hey
bf>
~ $ █
```
This was a simple Brainfuck script that stores an input byte and immediately prints it, four times. `h` `e` `y` `\n`

Now here's [`rot13.b`](rot13.b) from [brainfuck.org](https://brainfuck.org/). ROT13 is a simple letter substitution cipher that replaces a letter with the 13th letter after it in the Latin alphabet.
```brainfuck
,[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>++++++++++++++<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>>+++++[<----->-]<<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>++++++++++++++<-[>+<-[>+<-[>+<-[>+<-[>+<-[>++++++++++++++<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>>+++++[<----->-]<<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>+<-[>++++++++++++++<-[>+<-]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]]>.[-]<,]
```
Either do `./bf` and paste it, or do `./bf rot13.b`. Let's see if works.
```
cAEsaR
pNRfnE
CiPhEr    
PvCuRe
^C
```
It does! Our project is complete.

### References
