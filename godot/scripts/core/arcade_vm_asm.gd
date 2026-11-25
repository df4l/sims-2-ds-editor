class_name ArcadeVmAsm
extends RefCounted
## The arcade VM in ARM (ArmAsm syntax), installed once in the ARM9 extension by ArcadeExt.install_vm
## (docs/formats/arcade_vm.md). It is a mirror of ArcadeVM._run (GDScript): change both together.
## Symbols: ArcadeExt.SYMS + BUDGET, NOPS. The line "; FONT" is replaced by the font (ArcadeVM.font()).

const SOURCE := """
; Game block G: +0 code, +4 sprites, +8 init entry (u16), +0xA frame entry, +0xC sprite count, +0xE flags (bit 0:
; palette changed), +0x10 palette now, +0x18 palette at start, +0x20 actor, +0x24 screen buffer, +0x30 vars[256].
; While running: r4 G, r5 pc, r6 operand stack (ascending, next free), r7 code, r8 vars, r9 budget,
; r10 call stack (ascending), r11 screen buffer. Op handlers may use r0-r3, r12, lr.

vm_init:                    ; Init(r0 actor, r1 attract) with r2 = G (game thunk)
	push {r4-r11, lr}
	sub sp, sp, #12
	mov r4, r2
	str r0, [r4, #0x20]
	str r1, [r4, #0x30]     ; attract
	mov r0, #0
	str r0, [r4, #0x34]     ; tick
	ldr r0, [r4, #0x18]     ; palette as at start
	str r0, [r4, #0x10]
	ldr r0, [r4, #0x1C]
	str r0, [r4, #0x14]
	ldr r0, [r4, #0x24]
	cmp r0, #0
	bne vi_buf
	mov r0, #SCREEN_SIZE
	mov r1, #3
	mov r2, #4
	bl ALLOC
	str r0, [r4, #0x24]
	cmp r0, #0
	beq vi_out
vi_buf:
	mov r1, #0
	mov r2, #SCREEN_SIZE
	bl MEMSET
	bl vm_uploadpal
	ldrh r0, [r4, #8]
	bl vm_run
vi_out:
	add sp, sp, #12
	pop {r4-r11, pc}

vm_update:                  ; Update() with r0 = G
	push {r4-r11, lr}
	sub sp, sp, #12
	mov r4, r0
	ldr r0, [r4, #0x24]
	cmp r0, #0
	beq vu_out
	ldrh r0, [r4, #0xA]
	bl vm_run
	ldr r0, [r4, #0x34]     ; tick + 1
	add r0, r0, #1
	str r0, [r4, #0x34]
	ldrh r0, [r4, #0xE]
	tst r0, #1
	blne vm_uploadpal
	mov r0, #0
	str r0, [sp]
	ldr r0, [r4, #0x20]
	add r0, r0, #MODEL
	mov r1, #1
	ldr r2, [r4, #0x24]
	mov r3, #SCREEN_SIZE
	bl UPLOAD_TEX
vu_out:
	add sp, sp, #12
	pop {r4-r11, pc}

vm_free:                    ; Free() with r0 = G
	push {r4, lr}
	mov r4, r0
	ldr r0, [r4, #0x24]
	cmp r0, #0
	blne FREE
	mov r0, #0
	str r0, [r4, #0x24]
	pop {r4, pc}

vm_uploadpal:               ; r4 = G; clears the "palette changed" flag
	push {r4, lr}
	sub sp, sp, #8
	mov r0, #0
	str r0, [sp]
	str r0, [sp, #4]
	ldrh r0, [r4, #0xE]
	bic r0, r0, #1
	strh r0, [r4, #0xE]
	ldr r0, [r4, #0x20]
	add r0, r0, #MODEL
	mov r1, #1
	add r2, r4, #0x10
	mov r3, #8
	bl UPLOAD_PAL
	add sp, sp, #8
	pop {r4, pc}

vm_run:                     ; run from code offset r0 until RET at depth 0, a bad opcode or the budget; r4 = G
	push {r3, lr}
	ldr r7, [r4]
	add r5, r7, r0
	ldr r6, =vm_stack
	ldr r10, =vm_calls
	add r8, r4, #0x30
	ldr r9, =BUDGET
	ldr r11, [r4, #0x24]
vm_next:
	subs r9, r9, #1
	beq vm_stop
	ldrb r0, [r5], #1
	cmp r0, #NOPS
	bhs vm_stop
	ldr r1, =vm_optab
	ldr pc, [r1, r0, lsl #2]
vm_stop:
	pop {r3, pc}

op_ret:
	ldr r12, =vm_calls
	cmp r10, r12
	beq vm_stop
	ldr r5, [r10, #-4]!
	b vm_next
op_pushb:
	ldrsb r0, [r5], #1
	str r0, [r6], #4
	b vm_next
op_pushh:
	ldrb r0, [r5], #1
	ldrb r1, [r5], #1
	orr r0, r0, r1, lsl #8
	mov r0, r0, lsl #16
	mov r0, r0, asr #16
	str r0, [r6], #4
	b vm_next
op_pushw:
	ldrb r0, [r5], #1
	ldrb r1, [r5], #1
	orr r0, r0, r1, lsl #8
	ldrb r1, [r5], #1
	orr r0, r0, r1, lsl #16
	ldrb r1, [r5], #1
	orr r0, r0, r1, lsl #24
	str r0, [r6], #4
	b vm_next
op_load:
	ldrb r0, [r5], #1
	ldr r0, [r8, r0, lsl #2]
	str r0, [r6], #4
	b vm_next
op_store:
	ldrb r0, [r5], #1
	ldr r1, [r6, #-4]!
	str r1, [r8, r0, lsl #2]
	b vm_next
op_loadx:                   ; base, size; index -> value (0 out of range)
	ldrb r0, [r5], #1
	ldrb r1, [r5], #1
	ldr r2, [r6, #-4]
	mov r3, #0
	cmp r2, r1
	addlo r0, r0, r2
	ldrlo r3, [r8, r0, lsl #2]
	str r3, [r6, #-4]
	b vm_next
op_storex:                  ; base, size; index, value
	ldrb r0, [r5], #1
	ldrb r1, [r5], #1
	ldmdb r6!, {r2, r3}
	cmp r2, r1
	addlo r0, r0, r2
	strlo r3, [r8, r0, lsl #2]
	b vm_next
op_jmp:
	ldrb r0, [r5]
	ldrb r1, [r5, #1]
	orr r0, r0, r1, lsl #8
	add r5, r7, r0
	b vm_next
op_jz:
	ldrb r0, [r5], #1
	ldrb r1, [r5], #1
	orr r0, r0, r1, lsl #8
	ldr r1, [r6, #-4]!
	cmp r1, #0
	addeq r5, r7, r0
	b vm_next
op_jnz:
	ldrb r0, [r5], #1
	ldrb r1, [r5], #1
	orr r0, r0, r1, lsl #8
	ldr r1, [r6, #-4]!
	cmp r1, #0
	addne r5, r7, r0
	b vm_next
op_call:
	ldrb r0, [r5], #1
	ldrb r1, [r5], #1
	orr r0, r0, r1, lsl #8
	ldr r12, =vm_calls_end
	cmp r10, r12
	bhs vm_stop
	str r5, [r10], #4
	add r5, r7, r0
	b vm_next
op_pop:
	sub r6, r6, #4
	b vm_next
op_dup:
	ldr r0, [r6, #-4]
	str r0, [r6], #4
	b vm_next
	.pool

op_add:
	ldmdb r6!, {r0, r1}
	add r0, r0, r1
	str r0, [r6], #4
	b vm_next
op_sub:
	ldmdb r6!, {r0, r1}
	sub r0, r0, r1
	str r0, [r6], #4
	b vm_next
op_mul:
	ldmdb r6!, {r0, r1}
	mul r2, r0, r1
	str r2, [r6], #4
	b vm_next
op_div:
	ldmdb r6!, {r0, r1}
	bl sdiv
	str r0, [r6], #4
	b vm_next
op_mod:
	ldmdb r6!, {r0, r1}
	bl sdiv
	str r1, [r6], #4
	b vm_next
op_and:
	ldmdb r6!, {r0, r1}
	and r0, r0, r1
	str r0, [r6], #4
	b vm_next
op_or:
	ldmdb r6!, {r0, r1}
	orr r0, r0, r1
	str r0, [r6], #4
	b vm_next
op_xor:
	ldmdb r6!, {r0, r1}
	eor r0, r0, r1
	str r0, [r6], #4
	b vm_next
op_shl:
	ldmdb r6!, {r0, r1}
	and r1, r1, #31
	mov r0, r0, lsl r1
	str r0, [r6], #4
	b vm_next
op_shr:
	ldmdb r6!, {r0, r1}
	and r1, r1, #31
	mov r0, r0, asr r1
	str r0, [r6], #4
	b vm_next
op_neg:
	ldr r0, [r6, #-4]
	rsb r0, r0, #0
	str r0, [r6, #-4]
	b vm_next
op_not:
	ldr r0, [r6, #-4]
	cmp r0, #0
	moveq r0, #1
	movne r0, #0
	str r0, [r6, #-4]
	b vm_next
op_bnot:
	ldr r0, [r6, #-4]
	mvn r0, r0
	str r0, [r6, #-4]
	b vm_next
op_eq:
	ldmdb r6!, {r0, r1}
	cmp r0, r1
	mov r0, #0
	moveq r0, #1
	str r0, [r6], #4
	b vm_next
op_ne:
	ldmdb r6!, {r0, r1}
	cmp r0, r1
	mov r0, #0
	movne r0, #1
	str r0, [r6], #4
	b vm_next
op_lt:
	ldmdb r6!, {r0, r1}
	cmp r0, r1
	mov r0, #0
	movlt r0, #1
	str r0, [r6], #4
	b vm_next
op_le:
	ldmdb r6!, {r0, r1}
	cmp r0, r1
	mov r0, #0
	movle r0, #1
	str r0, [r6], #4
	b vm_next
op_gt:
	ldmdb r6!, {r0, r1}
	cmp r0, r1
	mov r0, #0
	movgt r0, #1
	str r0, [r6], #4
	b vm_next
op_ge:
	ldmdb r6!, {r0, r1}
	cmp r0, r1
	mov r0, #0
	movge r0, #1
	str r0, [r6], #4
	b vm_next

op_cls:                     ; c
	ldr r1, [r6, #-4]!
	and r1, r1, #3
	mov r0, #0x55
	mul r2, r0, r1
	mov r1, r2
	mov r0, r11
	mov r2, #SCREEN_SIZE
	bl MEMSET
	b vm_next
op_spr:                     ; sprite, x, y, flip
	sub r6, r6, #16
	ldmia r6, {r0-r3}
	ldrh r12, [r4, #0xC]
	cmp r0, r12
	bhs vm_next
	ldr r12, [r4, #4]
	add r0, r12, r0, lsl #5
	bl drawspr
	b vm_next
op_rect:                    ; x, y, w, h, c
	sub r6, r6, #20
	ldr r12, [r6, #16]
	and r12, r12, #3
	ldmia r6, {r0-r3}
	bl fillrect
	b vm_next
op_pix:                     ; x, y, c
	sub r6, r6, #12
	ldr r12, [r6, #8]
	and r12, r12, #3
	ldmia r6, {r0, r1}
	bl plot
	b vm_next
op_text:                    ; x, y, c, size + inline length, characters
	sub r6, r6, #16
	ldr r0, [r6, #12]
	bl setscale
	ldrb r3, [r5], #1
	mov r2, r5
	add r5, r5, r3
	ldmia r6, {r0, r1, r12}
	and r12, r12, #3
	bl drawtext
	b vm_next
op_num:                     ; value, x, y, c, size
	sub r6, r6, #20
	ldr r0, [r6, #16]
	bl setscale
	push {r4, r5}
	ldr r4, =vm_numend
	ldr r0, [r6]
	mov r5, r0
	cmp r0, #0
	rsblt r0, r0, #0
num_digit:
	mov r1, #10
	bl udiv
	add r1, r1, #'0'
	strb r1, [r4, #-1]!
	cmp r0, #0
	bne num_digit
	cmp r5, #0
	bge num_pos
	mov r1, #'-'
	strb r1, [r4, #-1]!
num_pos:
	mov r2, r4
	ldr r3, =vm_numend
	sub r3, r3, r4
	pop {r4, r5}
	ldr r0, [r6, #4]
	ldr r1, [r6, #8]
	ldr r12, [r6, #12]
	and r12, r12, #3
	bl drawtext
	b vm_next
op_sfx:                     ; id
	ldr r0, [r6, #-4]!
	cmp r0, #0x2A0              ; past the game's sound table (672 ids): ignored
	bhs vm_next
	cmp r0, #0x22               ; the 3 looping cabinet ambiences: ignored
	cmpne r0, #0x29
	cmpne r0, #0x2E
	beq vm_next
	ldr r1, [r4, #0x20]
	add r1, r1, #0x78
	bl PLAY_SFX
	b vm_next
op_pal:                     ; index, colour
	ldmdb r6!, {r0, r1}
	and r0, r0, #3
	add r2, r4, #0x10
	add r2, r2, r0, lsl #1
	strh r1, [r2]
	ldrh r0, [r4, #0xE]
	orr r0, r0, #1
	strh r0, [r4, #0xE]
	b vm_next
op_held:                    ; mask -> keys held & mask
	ldr r1, =KEYS
	ldr r1, [r1]
	ldrh r1, [r1, #2]
	ldr r0, [r6, #-4]
	and r0, r0, r1
	str r0, [r6, #-4]
	b vm_next
op_pressed:                 ; mask -> keys pressed & mask
	ldr r1, =KEYS
	ldr r1, [r1]
	ldrh r1, [r1, #6]
	ldr r0, [r6, #-4]
	and r0, r0, r1
	str r0, [r6, #-4]
	b vm_next
op_rnd:                     ; n -> 0..n-1 (0 if n <= 0)
	ldr r1, [r6, #-4]
	mov r0, #0
	cmp r1, #0
	blgt RAND
	str r0, [r6, #-4]
	b vm_next
op_abs:
	ldr r0, [r6, #-4]
	cmp r0, #0
	rsblt r0, r0, #0
	str r0, [r6, #-4]
	b vm_next
op_min:
	ldmdb r6!, {r0, r1}
	cmp r0, r1
	movgt r0, r1
	str r0, [r6], #4
	b vm_next
op_max:
	ldmdb r6!, {r0, r1}
	cmp r0, r1
	movlt r0, r1
	str r0, [r6], #4
	b vm_next
op_hit:                     ; x1, y1, w1, h1, x2, y2, w2, h2 -> rectangles overlap
	sub r6, r6, #32
	mov r12, #0
	ldr r0, [r6]
	ldr r1, [r6, #16]
	ldr r2, [r6, #24]
	add r2, r1, r2
	cmp r0, r2
	bge hit_out
	ldr r2, [r6, #8]
	add r2, r0, r2
	cmp r1, r2
	bge hit_out
	ldr r0, [r6, #4]
	ldr r1, [r6, #20]
	ldr r2, [r6, #28]
	add r2, r1, r2
	cmp r0, r2
	bge hit_out
	ldr r2, [r6, #12]
	add r2, r0, r2
	cmp r1, r2
	bge hit_out
	mov r12, #1
hit_out:
	str r12, [r6], #4
	b vm_next
op_peek:                    ; x, y -> colour (0 off screen)
	ldmdb r6!, {r0, r1}
	mov r2, #0
	cmp r0, #128
	cmplo r1, #128
	bhs peek_out
	add r2, r11, r1, lsl #5
	add r2, r2, r0, lsr #2
	ldrb r2, [r2]
	and r0, r0, #3
	mov r0, r0, lsl #1
	mov r2, r2, lsr r0
	and r2, r2, #3
peek_out:
	str r2, [r6], #4
	b vm_next
	.pool

setscale:                   ; r0 -> text size 1..8
	cmp r0, #1
	movlt r0, #1
	cmp r0, #8
	movgt r0, #8
	ldr r1, =vm_scale
	str r0, [r1]
	bx lr

udiv:                       ; r0 / r1 unsigned -> r0 quotient, r1 remainder (x / 0 = 0, 0); uses r2, r3
	cmp r1, #0
	moveq r0, #0
	bxeq lr
	mov r2, #0
	mov r3, #1
ud_align:
	cmp r1, r0
	bhs ud_loop
	tst r1, #0x80000000
	bne ud_loop
	mov r1, r1, lsl #1
	mov r3, r3, lsl #1
	b ud_align
ud_loop:
	cmp r0, r1
	subhs r0, r0, r1
	orrhs r2, r2, r3
	mov r1, r1, lsr #1
	movs r3, r3, lsr #1
	bne ud_loop
	mov r1, r0
	mov r0, r2
	bx lr

sdiv:                       ; r0 / r1 signed, truncated -> r0 quotient, r1 remainder (sign of r0); x / 0 = 0, 0
	push {r4, r5, r12, lr}
	eor r4, r0, r1
	mov r5, r0
	cmp r0, #0
	rsblt r0, r0, #0
	cmp r1, #0
	rsblt r1, r1, #0
	bl udiv
	cmp r4, #0
	rsblt r0, r0, #0
	cmp r5, #0
	rsblt r1, r1, #0
	pop {r4, r5, r12, pc}

plot:                       ; pixel (r0, r1) = r12 (0..3) if on screen; uses r0-r3
	cmp r0, #128
	cmplo r1, #128
	bxhs lr
	add r2, r11, r1, lsl #5
	add r2, r2, r0, lsr #2
	and r0, r0, #3
	mov r0, r0, lsl #1
	ldrb r3, [r2]
	mov r1, #3
	bic r3, r3, r1, lsl r0
	orr r3, r3, r12, lsl r0
	strb r3, [r2]
	bx lr

fillrect:                   ; r0 x, r1 y, r2 w, r3 h, colour r12; clipped; uses r0-r3
	push {r4-r8, lr}
	add r6, r0, r2
	add r7, r1, r3
	cmp r0, #0
	movlt r0, #0
	cmp r1, #0
	movlt r1, #0
	cmp r6, #128
	movgt r6, #128
	cmp r7, #128
	movgt r7, #128
	mov r8, r0
	mov r5, r1
fr_row:
	cmp r5, r7
	bge fr_done
	mov r4, r8
fr_col:
	cmp r4, r6
	bge fr_nextrow
	mov r0, r4
	mov r1, r5
	bl plot
	add r4, r4, #1
	b fr_col
fr_nextrow:
	add r5, r5, #1
	b fr_row
fr_done:
	pop {r4-r8, pc}

drawspr:                    ; r0 -> 32-byte sprite, r1 x, r2 y, r3 flip (1 h, 2 v); uses r0-r3, r12
	push {r4-r10, lr}
	mov r4, r0
	mov r5, r1
	mov r6, r2
	mov r7, r3
	mov r8, #0
ds_row:
	mov r9, #0
ds_col:
	tst r7, #1
	rsbne r10, r9, #15
	moveq r10, r9
	tst r7, #2
	rsbne r0, r8, #7
	moveq r0, r8
	add r0, r4, r0, lsl #2
	add r0, r0, r10, lsr #2
	ldrb r0, [r0]
	and r10, r10, #3
	mov r10, r10, lsl #1
	mov r0, r0, lsr r10
	ands r12, r0, #3
	beq ds_skip
	add r0, r5, r9
	add r1, r6, r8
	bl plot
ds_skip:
	add r9, r9, #1
	cmp r9, #16
	blt ds_col
	add r8, r8, #1
	cmp r8, #8
	blt ds_row
	pop {r4-r10, pc}

drawtext:                   ; r0 x, r1 y, r2 -> characters, r3 count, colour r12, size [vm_scale]; uses r0-r3
	push {r4-r11, lr}
	sub sp, sp, #4
	str r0, [sp]            ; x at the start of a line
	mov r4, r0
	mov r5, r1
	mov r6, r2
	mov r7, r3
	ldr r8, =vm_scale
	ldr r8, [r8]
dt_char:
	subs r7, r7, #1
	blt dt_done
	ldrb r0, [r6], #1
	cmp r0, #10
	bne dt_glyph
	ldr r4, [sp]
	add r5, r5, r8, lsl #2
	add r5, r5, r8, lsl #1
	b dt_char
dt_glyph:
	cmp r0, #96
	subhs r0, r0, #32
	subs r0, r0, #32
	blt dt_adv
	cmp r0, #64
	bhs dt_adv
	ldr r1, =vm_font
	add r1, r1, r0, lsl #1
	ldrh r9, [r1]
	push {r6, r7}
	mov r10, r5
dt_row:
	cmp r9, #0
	beq dt_end
	mov r6, r4
	mov r7, #3
dt_col:
	tst r9, #1
	beq dt_skip
	mov r0, r6
	mov r1, r10
	mov r2, r8
	mov r3, r8
	bl fillrect
dt_skip:
	mov r9, r9, lsr #1
	add r6, r6, r8
	subs r7, r7, #1
	bne dt_col
	add r10, r10, r8
	b dt_row
dt_end:
	pop {r6, r7}
dt_adv:
	add r4, r4, r8, lsl #2
	b dt_char
dt_done:
	add sp, sp, #4
	pop {r4-r11, pc}
	.pool

	.align 4
vm_optab:
	.word op_ret, op_pushb, op_pushh, op_pushw, op_load, op_store, op_loadx, op_storex
	.word op_jmp, op_jz, op_jnz, op_call, op_pop, op_dup, vm_stop, vm_stop
	.word op_add, op_sub, op_mul, op_div, op_mod, op_and, op_or, op_xor
	.word op_shl, op_shr, op_neg, op_not, op_bnot, op_eq, op_ne, op_lt
	.word op_le, op_gt, op_ge, vm_stop, vm_stop, vm_stop, vm_stop, vm_stop
	.word vm_stop, vm_stop, vm_stop, vm_stop, vm_stop, vm_stop, vm_stop, vm_stop
	.word op_cls, op_spr, op_rect, op_pix, op_text, op_num, op_sfx, op_pal
	.word op_held, op_pressed, op_rnd, op_abs, op_min, op_max, op_hit, op_peek
vm_font:
	; FONT
vm_scale:
	.word 1
vm_numbuf:
	.space 12
vm_numend:
vm_stack:
	.space 256
vm_calls:
	.space 128
vm_calls_end:
"""
