section .rodata

strWelcome:    db "Hello, World!", 10
strWelcomeLen equ $-strWelcome

section .text

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
