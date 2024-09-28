; vim: filetype=nasm
BITS 16
; ORG 0x7C00 - this is done during linking

; Useful constants
SECTOR_SIZE     equ 512
PAGE_SIZE       equ 4096
KiB             equ 1024
MiB             equ 1024 * KiB
SEGMENT_SIZE    equ 64 * KiB

; Fixed memory locations
MEMORY_MAP      equ 0x01000
BOOT_LOADER     equ 0x07C00
STACK_TOP       equ BOOT_LOADER - 0x70 ; grows downward
KERNEL_START    equ 0x07E00
PAGE_MAP        equ 0x7C000 ; right before the EBDA
MAX_KERNEL_SIZE equ PAGE_MAP - KERNEL_START
PML4            equ PAGE_MAP
PDP             equ PML4 + PAGE_SIZE
PD              equ PDP + PAGE_SIZE
VIDEO_MEM_TEXT  equ 0xB8000

main:
    ; Disable interrupts
    cli

    ; Make sure we're at 0x0000:0x7C00 instead of 0x07C0:0x0000
    jmp 0x0000:.setcs

.setcs:
    ; Set up other segment registers
    xor eax, eax
    mov ds, ax
    mov es, ax

    ; Save drive number passed in by the firmware
    mov byte [driveNumber], dl

    ; Enable the A20 line
    in al, 0x92
    or al, 2
    out 0x92, al

    ; Probe the BIOS memory map, store at MEMORY_MAP (with first dword = # of entries)
    xor eax, eax
    mov dword [MEMORY_MAP], eax
    mov di, MEMORY_MAP + 4
    mov eax, 0xE820
    mov ebx, 0
    mov ecx, 24
    mov edx, 'PAMS'
    int 0x15
    jc error

    ; Check that the first call at least succeeded
    mov edx, 'PAMS'
    cmp eax, edx
    jne error
    test ebx, ebx
    jz error
    jmp .e820Entry

.e820loop:
    mov eax, 0xE820
    mov ecx, 24
    mov edx, 'PAMS'
    int 0x15
    jc .loadKernel

.e820Entry:
    cmp ecx, 24
    jnl .loopNext
    mov dword es:[di + 20], 1

.loopNext:
    inc dword [MEMORY_MAP]
    add di, 24

    ; Finished when ebx=0
    test ebx, ebx
    jne .e820loop

.loadKernel:
    mov cx, word [dap.size]

    ; If the kernel is too large to fit in one segment, read 64k at a time
    cmp cx, SEGMENT_SIZE / SECTOR_SIZE
    jl .readSectors
    mov word [dap.size], SEGMENT_SIZE / SECTOR_SIZE

    ; Load the kernel from disk
.readSectors:
    mov si, dap  ; data structure describing read
    mov ah, 0x42 ; extended read
    mov dl, byte [driveNumber] ; boot drive
    int 0x13
    jc error

    sub cx, word [dap.size]
    jz .finishedLoadKernel

    mov word [dap.size], cx
    add word [dap.segment], SEGMENT_SIZE / 16
    add dword [dap.offset], SEGMENT_SIZE / SECTOR_SIZE
    jmp .loadKernel

.finishedLoadKernel:
    ; Identity map the first 2MiB into virtual memory using a single large page

    ; Clear space for the entire page map
    mov ax, PAGE_MAP / 16
    mov es, ax
    xor di, di
    mov ecx, 3 * PAGE_SIZE / 4 ; 3 levels of tables, each one page, in dwords
    xor eax, eax
    cld
    rep stosd

    ; Page Map Level 4
    mov di, PML4 - PAGE_MAP
    mov eax, PDP
    or eax, 3 ; PAGE_PRESENT | PAGE_WRITEABLE
    mov [es:di], eax

    ; Page Directory Pointer Table
    mov di, PDP - PAGE_MAP
    mov eax, PD
    or eax, 3 ; PAGE_PRESENT | PAGE_WRITEABLE
    mov [es:di], eax

    ; Page Directory
    mov di, PD - PAGE_MAP
    xor eax, eax ; Physical address 0
    or eax, 0x83 ; PAGE_PRESENT | PAGE_WRITEABLE | PAGE_SIZE
    mov [es:di], eax

    ; Set PAE (Physical Address Extension) and PGE (Page Global Enabled) flags
    mov eax, 10100000b
    mov cr4, eax

    ; Point cr3 to the PML4 to set up paging
    mov edx, PAGE_MAP
    mov cr3, edx

    ; Set the LME (long mode enabled) bit of the EFER (extended feature enable register) MSR (model-specific register)
    mov ecx, 0xC0000080
    rdmsr
    or eax, 0x00000100
    wrmsr

    ; Load the GDT (global descriptor table)
    xor ax, ax
    mov ds, ax
    lgdt [GDT.pointer]

    ; Activate long mode by enabling paging and entering protected mode at the same time
    mov ebx, cr0
    or ebx, 0x80000001
    mov cr0, ebx

    ; Far jump to clear the instruction pipeline and load cs with the correct selector
    jmp GDT.code0:.longMode

BITS 64
.longMode:
    ; Zero out data-segment registers (not used in 64-bit mode)
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax

    ; Set up a stack right below the boot sector
    mov ax, GDT.data0
    mov ss, ax
    mov rsp, STACK_TOP
    mov rbp, rsp

    ; Jump to entry point of the kernel (indirect so that the linker doesn't try to relocate it)
    mov rax, KERNEL_START
    call rax

    ; The kernel shouldn't return, but just in case, halt and loop
.forever:
    hlt
    jmp .forever

    ; If there was an error during boot, fill the screen with red
error:
    cld
    mov al, 'E'
    out 0xE9, al
    mov ax, VIDEO_MEM_TEXT / 16
    mov es, ax
    mov di, 0
    mov ax, 0x4020
    mov cx, 80 * 25
    rep stosw
    hlt
    jmp $

; Global descriptor table
GDT:
    .null: equ $ - GDT
        dq 0

    .code0: equ $ - GDT
        times 5 db 0
        db 10011000b        ; present, ring 0, non-system, executable, non-conforming
        db 00100000b        ; long mode
        db 0

    .data0: equ $ - GDT
        times 5 db 0
        db 10010010b        ; present, ring 0, non-system, data, writeable
        times 2 db 0

    .pointer:
        dw $ - GDT - 1
        dd GDT

; Store the drive number passed in DL to the boot loader by the firmware
driveNumber:
    db 0

; Disk address packet structure describing how to load the kernel. The starting LBA
; and size in sectors are filled in when the disk image is created
dap:
    db 0x10                    ; size of this structure (16 bytes)
    db 0                       ; always zero
    .size:
    dw 0                       ; number of sectors to transfer (each is 512 bytes)
    dw 0                       ; destination offset
    .segment:
    dw KERNEL_START / 16       ; destination segment (right after the boot sector)
    .offset:
    dd 0                       ; lower 32-bits of starting LBA
    dd 0                       ; upper 16-bits of starting LBA

; MBR partition table starts at offset 1B8h
times 0x1B8 - ($ - $$) db 0

partitionTable:
.diskSignature:
    dd 0
    dw 0

.partition1:
    times 2 dq 0

.partition2:
    times 2 dq 0

.partition3:
    times 2 dq 0

.partition4:
    times 2 dq 0

%if ($ - $$) != 510
%error "bootloader is too large"
%endif

; Boot sector must end with this magic number
db 0x55
db 0xAA
