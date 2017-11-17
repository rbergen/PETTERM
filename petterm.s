;-----------------------------------------------------------------------
; PET Term
; Version 0.1
;
; A bit-banged full duplex serial terminal for the PET 2001 computers,
; including those running BASIC 1.
;
; Targets 8N1 serial. Baud rate will be whatever we can set the timer for
; and be able to handle interrupts fast enough.
;
; References:
;     http://www.6502.org/users/andre/petindex/progmod.html 
;     http://www.zimmers.net/cbmpics/cbm/PETx/petmem.txt
;     http://www.commodore.ca/manuals/commodore_pet_2001_quick_reference.pdf

; I believe the VIA should be running at CPU clock rate of 1MHz
; This does not divide evenly to common baud rates, there will be some error
; Though the error values seem almost insignificant, even with the int. divisor
;  Timer values for various common baud rates:
;	110  - $2383  (9090.90...)  0.001% error
;	  Are you hooking this up to an ASR-33 or something?
; 	300  - $0D05  (3333.33...)  -0.01% error
;	600  - $0683  (1666.66...)  -0.04% error
;	1200 - $0341  (833.33...)   -0.04% error
;	2400 - $01A1  (416.66...)    0.08% error
;	4800 - $00D0  (208.33...)   -0.16% error
;	9600 - $0068  (104.16...)   -0.16% error
;	  I'd be impressed if we could run this fast without overrun
; Since we need 3x oversampling for our bit-bang routines, the valus we need
; are for 3x the baud rate:
;	110  - $0BD6  (3030.30...)  -0.01% error
; 	300  - $0457  (1111.11...)  -0.01% error
;	600  - $022C  (555.55...)   +0.08% error
;	1200 - $0116  (277.77...)   +0.08% error
;	2400 - $008B  (138.88...)   +0.08% error
;	4800 - $0045  (69.44...)    -0.64% error
;	9600 - $0023  (34.722...)   +0.80% error
;
; All of these are within normal baud rate tollerances of +-2% 
; Thus we should be fine to use them, though we'll be limited by just how
; fast our bit-bang isr is. I don't think the slowest path is < 35 cycles
; 2400 is probably the upper limit if we optimize, especially since we have
; to handle each character as well as recieve it. Though with flow control
; we might be able to push a little bit.
;
; Hayden Kroepfl 2017
;
; Written for the DASM assembler
;----------------------------------------------------------------------- 
	PROCESSOR 6502

;-----------------------------------------------------------------------
; Zero page definitions
; TODO: Should we move this to program memory so we don't overwrite
;  any BASIC variables? Then we don't have to worry about using KERNAL
;  routines as much.
;-----------------------------------------------------------------------
	SEG.U	ZPAGE
	RORG	$0

SERCNT	DS.B	1		; Current sample number
TXTGT	DS.B	1		; Sample number of next send event
RXTGT	DS.B	1		; Sample number of next recv event
TXCUR	DS.B	1		; Current byte being transmitted
RXCUR	DS.B	1		; Current byte being received
TXSTATE	DS.B	1		; Next Transmit state
RXSTATE	DS.B	1		; Next Receive state
TXBIT	DS.B	1		; Tx data bit #
RXBIT	DS.B	1		; Rx data bit #
RXSAMP	DS.B	1		; Last sampled value

TXBYTE	DS.B	1		; Next byte to transmit
RXBYTE	DS.B	1		; Last receved byte

RXNEW	DS.B	1		; Indicates byte has been recieved
TXNEW	DS.B	1		; Indicates to start sending a byte

BAUD	DS.B	1		; Current baud rate, index into table

COL	DS.B	1		; Current cursor position		
ROW	DS.B	1

CURLOC	DS.W	1		; Pointer to current screen location

TMP1	DS.B	1	
TMP2	DS.B	1

TMPA	DS.W	1
TMPA2	DS.W	1

POLLRES	DS.B	1		; KBD Polling interval for baud
POLLTGT	DS.B	1		; Polling interval counter

KBDBYTE	DS.B	1
KBDNEW	DS.B	1
KEY	DS.B	1
SHIFT	DS.B	1

	RORG	$90

	DS.B	1		; Reserve so we get a compiler error
; Make sure not to use $90-95	, Vectors for BASIC 2+
	REND
;-----------------------------------------------------------------------

;-----------------------------------------------------------------------
; GLOBAL Defines
;-----------------------------------------------------------------------
STSTART	EQU	0		; Waiting/Sending for start bit
STRDY	EQU	1		; Ready to start sending
STBIT	EQU	2		; Sending/receiving data
STSTOP	EQU	3		; Sending/receiving stop bit
STIDLE	EQU	4

BITCNT	EQU	8		; 8-bit bytes to recieve
BITMSK	EQU	$FF		; No mask

SCRCOL	EQU	40		; Screen columns
SCRROW	EQU	25

COLMAX	EQU	40		; Max display columns
ROWMAX	EQU	25

; 6522 VIA 
VIA_PORTB  EQU	$E840
VIA_PORTAH EQU	$E841		; User-port with CA2 handshake (messes with screen)
VIA_DDRB   EQU	$E842
VIA_DDRA   EQU	$E843		; User-port directions
VIA_TIM1L  EQU	$E844		; Timer 1 low byte
VIA_TIM1H  EQU	$E845		; high
VIA_TIM1LL EQU	$E846		; Timer 1 low byte latch
VIA_TIM1HL EQU	$E847		; high latch
VIA_TIM2L  EQU	$E848		; Timer 2 low byte
VIA_TIM2H  EQU	$E849		; high
VIA_SR     EQU	$E84A
VIA_ACR	   EQU	$E84B
VIA_PCR    EQU  $E84C
VIA_IFR    EQU	$E84D		; Interrupt flag register
VIA_IER    EQU	$E84E		; Interrupt enable register
VIA_PORTA  EQU	$E84F		; User-port without CA2 handshake


PIA1_PA	   EQU	$E810
PIA1_PB	   EQU	$E812
PIA1_CRA   EQU  $E811
PIA1_CRB   EQU  $E813



PIA2_CRA   EQU  $E821
PIA2_CRB   EQU  $E823

SCRMEM     EQU	$8000		; Start of screen memory
SCREND	   EQU	SCRMEM+(SCRCOL*SCRROW) ; End of screen memory
SCRBTML	   EQU  SCRMEM+(SCRCOL*(SCRROW-1)) ; Start of last row

; These are for BASIC2/4 according to 
; http://www.zimmers.net/cbmpics/cbm/PETx/petmem.txt
; Also make sure our ZP allocations don't overwrite
BAS4_VECT_IRQ  EQU	$0090	; 90/91 - Hardware interrupt vector
BAS4_VECT_BRK  EQU	$0092	; 92/93 - BRK vector

; This is for a 2001-8 machine according to:
; http://www.commodore.ca/manuals/commodore_pet_2001_quick_reference.pdf
; This is presumably for a BASIC 1.0 machine!
BAS1_VECT_IRQ  EQU	$0219	; 219/220 - Interrupt vector
BAS1_VECT_BRK  EQU	$0216	; 216/217 - BRK vector


;-----------------------------------------------------------------------
; Start of loaded data
	SEG	CODE
	ORG	$0401           ; Start address for PET computers
	
;-----------------------------------------------------------------------
; Simple Basic 'Loader' - BASIC Statement to jump into our program
BLDR
	DC.W BLDR_ENDL	; LINK (To end of program)
	DC.W 10		; Line Number = 10
	DC.B $9E	; SYS
	; Decimal Address in ASCII $30 is 0 $31 is 1, etc
	DC.B (INIT/10000)%10 + '0
	DC.B (INIT/ 1000)%10 + '0
	DC.B (INIT/  100)%10 + '0
	DC.B (INIT/   10)%10 + '0
	DC.B (INIT/    1)%10 + '0

	DC.B $0		; Line End
BLDR_ENDL
	DC.W $0		; LINK (End of program)
;-----------------------------------------------------------------------


;-----------------------------------------------------------------------
; Initialization
INIT	SUBROUTINE
	SEI			; Disable interrupts
	
	; Clear ZP?
	
	; We never plan to return to BASIC, steal everything!
	LDX	#$FF		; Set start of stack
	TXS			; Set stack pointer to top of stack
	
	; Determine which version of BASIC we have for a KERNAL
	; TODO: What's a reliable way? Maybe probe for a byte that's
	; different in each version. Find such a byte using emulators.
	
	
	
	; Set timer to 3x desired initial baud rate
	LDA	#$01		; 300 baud
	STA	BAUD
	
	
	LDA	PIA1_CRB
	AND	#$FE		; Disable interrupts (60hz retrace int?)
	STA	PIA1_CRB	
	LDA	PIA1_CRA
	AND	#$FE
	STA	PIA1_CRA	; Disable interrupts
	
	LDA	PIA2_CRB
	AND	#$FE		; Disable interrupts (60hz retrace int?)
	STA	PIA2_CRB	
	LDA	PIA2_CRA
	AND	#$FE
	STA	PIA2_CRA	; Disable interrupts
	
	
	
	; Install IRQ
	LDA	#<IRQHDLR
	LDX	#>IRQHDLR
	STA	BAS1_VECT_IRQ	; Modify based on BASIC version
	STX	BAS1_VECT_IRQ+1
	STA	BAS4_VECT_IRQ	; Let's see if we can get away with modifying
	STX	BAS4_VECT_IRQ+1	; both versions vectors
	
	
	JSR	INITVIA
	
	
	; Initialize state
	LDA	#STSTART
	STA	RXSTATE
	LDA	#STIDLE		; Output 1 idle tone first
	STA	TXSTATE
	
	LDA	#1
	JSR	SETTX		; Make sure we're outputting idle tone
	
	LDA	#0
	STA	SERCNT
	STA	TXTGT		; Fire Immediatly
	STA	RXTGT		; Fire immediatly
	STA	RXNEW		; No bytes ready
	STA	TXNEW		; No bytes ready
	STA	ROW
	STA	COL
	
	STA	CURLOC
	LDA	#$80
	STA	CURLOC+1
	
	; Set-up screen
	JSR	CLRSCR
	
	LDA	#0
	STA	VIA_TIM1L
	STA	VIA_TIM1H	; Need to clear high before writing latch
				; Otherwise it seems to fail half the tile?
	LDX	BAUD
	LDA	BAUDTBLL,X
	STA	VIA_TIM1LL
	LDA	BAUDTBLH,X
	STA	VIA_TIM1HL
	LDA	POLLINT,X
	STA	POLLRES
	STA	POLLTGT
	
	
	
	; Fall into START
;-----------------------------------------------------------------------
; Start of program (after INIT called)
START	SUBROUTINE
	
	CLI	; Enable interrupts

; Init for GETBUF
;	LDA	#<BUF
;	STA	TMPA2
;	LDA	#>BUF
;	STA	TMPA2+1


.loop
	LDA	RXNEW
	BEQ	.norx		; Loop till we get a character in
	LDA	#$0
	STA	RXNEW		; Acknowledge byte
	LDA	RXBYTE
	JSR	PARSECH
.norx
	LDA	KBDNEW
	BEQ	.nokey
	LDA	#$0
	STA	KBDNEW
	LDA	KBDBYTE
	
; LOCAL ECHOBACK CODE
	PHA
	JSR	PARSECH		; Local-echoback for now
	PLA
	PHA
	CMP	#$0D		; \r
	BNE	.noechonl
	LDA	#$0A
	JSR	PARSECH
.noechonl
	PLA
; LOCAL ECHOBACK CODE
	
	; Check if we can push the byte
	LDX	TXNEW
	CPX	#$FF
	BEQ	.nokey		; Ignore key if one waiting to send
	STA	TXBYTE
	LDA	#$FF
	STA	TXNEW		; Signal to transmit
.nokey
	JMP	.loop




; Get a character from the serial port (blocking)
GETCH	SUBROUTINE	
	LDA	RXNEW
	BEQ	GETCH		; Loop till we get a character in
	LDA	#$0
	STA	RXNEW		; Acknowledge byte
	LDA	RXBYTE
	RTS
	


;-----------------------------------------------------------------------
;-- Bit-banged serial code ---------------------------------------------
;-----------------------------------------------------------------------
	INCLUDE "serial.s"
;-----------------------------------------------------------------------
;-- ANSI escape code handling ------------------------------------------
;-----------------------------------------------------------------------
	INCLUDE "ansi.s"
;-----------------------------------------------------------------------
;-- Screen routines and cursor control ---------------------------------
;-----------------------------------------------------------------------
	INCLUDE "screen.s"
;-----------------------------------------------------------------------
;-- Keyboard polling code ----------------------------------------------
;-----------------------------------------------------------------------
	INCLUDE "kbd.s"
	
	
	


	
	

;-----------------------------------------------------------------------
; Static data

; Baud rate timer values, 3x the baud rate
;		 110  300  600 1200 2400 4800 9600
BAUDTBLL 
	DC.B	$D6, $57, $2c, $16, $8B, $45, $23
BAUDTBLH	
	DC.B	$0B, $04, $02, $01, $00, $00, $00
	
; Poll interval mask for ~60Hz polling based on the baud timer
	; 	110  300   600 1200 2400 4800  9600 (Baud)
POLLINT	; 	330  900  1800 2400 4800 9600 19200 (Calls/sec)
	DC.B	  5,  15,  30,  60, 120, 240, 480
;Ideal for 60Hz 5.5   15   30   60  120  240  480
;Poll freq Hz  	66    60   60   60   60   60   60
;-----------------------------------------------------------------------




;-----------------------------------------------------------------------
; Interrupt handler
IRQHDLR	SUBROUTINE
	; We'll assume that the only IRQ firing is for the VIA timer 1
	; (ie. We've set it up right)
	LDA	VIA_TIM1L	; Acknowlege the interrupt
	JSR	SERSAMP		; Do our sampling
	
	DEC	POLLTGT		; Check if we're due to poll
	BNE	.exit
	
	LDA	POLLRES
	STA	POLLTGT
	JSR	KBDPOLL		; Do keyboard polling
	
	CMP	KBDBYTE		; Check if the same byte as before
	STA	KBDBYTE
	BEQ	.exit		; Don't repeat
	LDA	KBDBYTE
	BEQ	.exit		; Don't signal blank keys
	LDA	#$FF
	STA	KBDNEW		; Signal a pressed key
.exit
	; Restore registers saved on stack by KERNAL
	PLA			; Pop Y
	TAY
	PLA			; Pop X
	TAX
	PLA			; Pop A
	RTI			; Return from interrupt


	


;-----------------------------------------------------------------------
; Initialize VIA and userport
INITVIA SUBROUTINE
	LDA	#$00		; Rx pin in (PA0) (rest input as well)
	STA	VIA_DDRA	; Set directions
	LDA	#$40		; Shift register disabled, no latching, T1 free-run
	STA	VIA_ACR		
	LDA	#$EC		; Tx as output high, uppercase+graphics ($EE for lower)
	STA	VIA_PCR		
	; Set VIA interrupts so that our timer is the only interrupt source
	LDA	#$7F		; Clear all interrupt flags
	STA	VIA_IER
	LDA	#$C0		; Enable VIA interrupt and Timer 1 interrupt
	STA	VIA_IER
	RTS
	
	


