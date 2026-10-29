package axi4l_agent_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // Preserve the agent package API while using the shared TB configuration.
  parameter int AXI4L_ADDR_WIDTH =
    axi4l_gpio_tb_cfg_pkg::AXI4L_ADDR_WIDTH;
  parameter int AXI4L_DATA_WIDTH =
    axi4l_gpio_tb_cfg_pkg::AXI4L_DATA_WIDTH;

  `include "axi4l_seq_item.sv"
  `include "axi4l_sequencer.sv"
  `include "axi4l_driver.sv"
  `include "axi4l_monitor.sv"
  `include "axi4l_agent.sv"
endpackage

