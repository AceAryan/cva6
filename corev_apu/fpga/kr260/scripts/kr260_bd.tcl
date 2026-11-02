# Block design for the two-core CVA6 on the KR260 (Vivado 2023.2).
#
#   cores (S_AXI_CORE, AXI4 64b) -> sc_core -> PS S_AXI_HP0_FPD (DDR)   @ 0x0000_0000, 2 GiB
#                                           -> bram_ctrl_core (mailbox)  @ 0xC000_0000, 8 KiB
#   PS M_AXI_HPM0_FPD -> sc_ps -> bram_ctrl_ps (same mailbox)            @ 0xA000_0000
#                              -> axi_gpio (cores_run)                   @ 0xA001_0000
#   PL clock pl_clk0 (50 MHz) drives everything.

set design kr260_bd
create_bd_design $design

# ---------------- PS ----------------
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ultra_ps_e_0]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $ps
set_property -dict [list \
  CONFIG.PSU__USE__M_AXI_GP0 {1} \
  CONFIG.PSU__USE__M_AXI_GP1 {0} \
  CONFIG.PSU__USE__M_AXI_GP2 {0} \
  CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
  CONFIG.PSU__USE__S_AXI_GP2 {1} \
  CONFIG.PSU__SAXIGP2__DATA_WIDTH {64} \
  CONFIG.PSU__FPGA_PL0_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {50} \
] $ps

set clk [get_bd_pins $ps/pl_clk0]
# the PS gets as close to 50 MHz as its dividers allow; ports must match it
set freq [get_property CONFIG.FREQ_HZ $clk]
connect_bd_net $clk [get_bd_pins $ps/maxihpm0_fpd_aclk] [get_bd_pins $ps/saxihp0_fpd_aclk]

set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst_pl]
connect_bd_net $clk [get_bd_pins $rst/slowest_sync_clk]
connect_bd_net [get_bd_pins $ps/pl_resetn0] [get_bd_pins $rst/ext_reset_in]
set aresetn [get_bd_pins $rst/peripheral_aresetn]

# ---------------- external ports ----------------
set s_axi [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI_CORE]
set_property -dict [list \
  CONFIG.PROTOCOL {AXI4} CONFIG.DATA_WIDTH {64} CONFIG.ADDR_WIDTH {32} CONFIG.ID_WIDTH {5} \
  CONFIG.HAS_BURST {1} CONFIG.HAS_LOCK {1} CONFIG.HAS_CACHE {1} CONFIG.HAS_PROT {1} \
  CONFIG.HAS_QOS {1} CONFIG.HAS_REGION {1} CONFIG.HAS_BRESP {1} CONFIG.HAS_RRESP {1} \
  CONFIG.HAS_WSTRB {1} CONFIG.NUM_READ_OUTSTANDING {8} CONFIG.NUM_WRITE_OUTSTANDING {8} \
  CONFIG.FREQ_HZ $freq \
] $s_axi

set p_clk [create_bd_port -dir O -type clk pl_clk]
set_property -dict [list CONFIG.ASSOCIATED_BUSIF {S_AXI_CORE} CONFIG.FREQ_HZ $freq] $p_clk
connect_bd_net $clk $p_clk
set p_rstn [create_bd_port -dir O -type rst pl_resetn]
connect_bd_net $aresetn $p_rstn
set_property CONFIG.ASSOCIATED_RESET {pl_resetn} $p_clk

# ---------------- core side ----------------
set sc_core [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect sc_core]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] $sc_core
connect_bd_net $clk [get_bd_pins $sc_core/aclk]
connect_bd_net $aresetn [get_bd_pins $sc_core/aresetn]
connect_bd_intf_net $s_axi [get_bd_intf_pins $sc_core/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins $sc_core/M00_AXI] [get_bd_intf_pins $ps/S_AXI_HP0_FPD]

set bram_core [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl bram_ctrl_core]
set_property -dict [list CONFIG.DATA_WIDTH {64} CONFIG.SINGLE_PORT_BRAM {1} CONFIG.ECC_TYPE {0}] $bram_core
connect_bd_net $clk [get_bd_pins $bram_core/s_axi_aclk]
connect_bd_net $aresetn [get_bd_pins $bram_core/s_axi_aresetn]
connect_bd_intf_net [get_bd_intf_pins $sc_core/M01_AXI] [get_bd_intf_pins $bram_core/S_AXI]

# ---------------- PS side ----------------
set sc_ps [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect sc_ps]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] $sc_ps
connect_bd_net $clk [get_bd_pins $sc_ps/aclk]
connect_bd_net $aresetn [get_bd_pins $sc_ps/aresetn]
connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_HPM0_FPD] [get_bd_intf_pins $sc_ps/S00_AXI]

set bram_ps [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl bram_ctrl_ps]
set_property -dict [list CONFIG.DATA_WIDTH {64} CONFIG.SINGLE_PORT_BRAM {1} CONFIG.ECC_TYPE {0}] $bram_ps
connect_bd_net $clk [get_bd_pins $bram_ps/s_axi_aclk]
connect_bd_net $aresetn [get_bd_pins $bram_ps/s_axi_aresetn]
connect_bd_intf_net [get_bd_intf_pins $sc_ps/M00_AXI] [get_bd_intf_pins $bram_ps/S_AXI]

set gpio [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio axi_gpio_run]
set_property -dict [list CONFIG.C_GPIO_WIDTH {1} CONFIG.C_ALL_OUTPUTS {1} CONFIG.C_DOUT_DEFAULT {0x00000000}] $gpio
connect_bd_net $clk [get_bd_pins $gpio/s_axi_aclk]
connect_bd_net $aresetn [get_bd_pins $gpio/s_axi_aresetn]
connect_bd_intf_net [get_bd_intf_pins $sc_ps/M01_AXI] [get_bd_intf_pins $gpio/S_AXI]
set p_run [create_bd_port -dir O -from 0 -to 0 cores_run]
connect_bd_net [get_bd_pins $gpio/gpio_io_o] $p_run

# ---------------- shared mailbox memory ----------------
set bram [create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen mailbox_mem]
set_property -dict [list CONFIG.Memory_Type {True_Dual_Port_RAM}] $bram
connect_bd_intf_net [get_bd_intf_pins $bram_core/BRAM_PORTA] [get_bd_intf_pins $bram/BRAM_PORTA]
connect_bd_intf_net [get_bd_intf_pins $bram_ps/BRAM_PORTA] [get_bd_intf_pins $bram/BRAM_PORTB]

# ---------------- addresses ----------------
set ddr_low [get_bd_addr_segs -of_objects [get_bd_intf_pins $ps/S_AXI_HP0_FPD] -filter {NAME =~ "*DDR_LOW*"}]
assign_bd_address -target_address_space [get_bd_addr_spaces S_AXI_CORE] -offset 0x00000000 -range 2G $ddr_low
assign_bd_address -target_address_space [get_bd_addr_spaces S_AXI_CORE] -offset 0xC0000000 -range 8K \
  [get_bd_addr_segs $bram_core/S_AXI/Mem0]
assign_bd_address -target_address_space [get_bd_addr_spaces $ps/Data] -offset 0xA0000000 -range 8K \
  [get_bd_addr_segs $bram_ps/S_AXI/Mem0]
assign_bd_address -target_address_space [get_bd_addr_spaces $ps/Data] -offset 0xA0010000 -range 4K \
  [get_bd_addr_segs $gpio/S_AXI/Reg]

validate_bd_design
save_bd_design
