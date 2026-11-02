/* Bare-metal tests on the KR260 two-core CVA6: as the simulation link.ld,
   but tohost sits in the mailbox BRAM (uncached for the cores, read by the
   PS through xsdb at 0xA000_0000). */
OUTPUT_ARCH( "riscv" )
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) }
  . = ALIGN(0x1000);
  .text : { *(.text) }
  . = ALIGN(0x1000);
  .data : { *(.data) }
  .bss : { *(.bss) }
  _end = .;
  . = 0xC0000000;
  .tohost (NOLOAD) : { *(.tohost) }
}
