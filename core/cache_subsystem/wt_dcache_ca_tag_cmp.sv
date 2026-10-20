// Copyright 2026 OpenHW Group
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"). You may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

module wt_dcache_ca_tag_cmp #(
    parameter int unsigned ADDR_WIDTH = 56,
    parameter int unsigned DEPTH = 8
) (
    input  logic [DEPTH-1:0]                  valid_i,
    input  logic [DEPTH-1:0][ADDR_WIDTH-1:0]   addr_i,
    input  logic [ADDR_WIDTH-1:0]              query_addr_i,
    output logic [DEPTH-1:0]                  match_oh_o,
    output logic                              hit_o
);

  for (genvar i = 0; i < DEPTH; i++) begin : gen_addr_cmp
    assign match_oh_o[i] = valid_i[i] && (addr_i[i] == query_addr_i);
  end

  assign hit_o = |match_oh_o;

endmodule
