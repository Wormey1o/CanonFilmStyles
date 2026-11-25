/* SPDX-License-Identifier: GPL-2.0-or-later */
.syntax unified
.arch armv5te
.arm
.section .guard,"ax",%progbits
.global installer_guard
installer_guard:
 ldr r0,=0x902f3c
 ldr r1,=0x004e5552
 swp r2,r1,[r0]
 ldr r3,=0x00202020
 cmp r2,r3
 bxne lr
 push {r4,lr}
 ldr r0,=installer_result
 bl installer_body
 cmp r0,#2
 beq unqualified_return
 cmp r0,#8
 beq unqualified_return
 cmp r0,#9
 beq unqualified_return
 mov r2,r0
 ldr r0,=0x902f33
 ldr r1,=installer_format
 bl canon_sprintf
unqualified_return:
 pop {r4,pc}
 .ltorg
.section .args,"ax",%progbits
.global inert_command,installer_result,installer_format
inert_command:
 mov r0,#1
 bx lr
installer_format: .asciz "%08X"
.balign 4
installer_result: .space 16,0
.section .callsite,"ax",%progbits
.global installer_callsite
installer_callsite:
 ldr r3,[fp,#-16]
 str r3,[sp]
 bl installer_guard
 nop
 nop
 nop
 mov r0,#0
 mov r1,#0
 ldr r2,[pc,#0x78]
 mov r3,#1
 bl canon_constructor
