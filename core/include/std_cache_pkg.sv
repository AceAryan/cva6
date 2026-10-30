// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba    <zarubaf@iis.ee.ethz.ch>, ETH Zurich
//         Michael Schaffner <schaffner@iis.ee.ethz.ch>, ETH Zurich
// Date: 15.08.2018

// ******* WIP *******
// Description: package for the standard Ariane cache subsystem.

package std_cache_pkg;

  // localparam DECISION_BIT = 30; // bit on which to decide whether the request is cache-able or not

  typedef struct packed {
    logic [1:0]      id;     // id for which we handle the miss
    logic            valid;
    logic            we;
    logic [55:0]     addr;
    logic [7:0][7:0] wdata;
    logic [7:0]      be;
  } mshr_t;

  typedef struct packed {
    logic        valid;
    logic [63:0] addr;
    logic [7:0]  be;
    logic [1:0]  size;
    logic        we;
    logic [63:0] wdata;
    logic        bypass;
  } miss_req_t;

  typedef struct packed {
    logic                req;
    ariane_pkg::ad_req_t reqtype;
    ariane_pkg::amo_t    amo;
    logic [3:0]          id;
    logic [63:0]         addr;
    logic [63:0]         wdata;
    logic                we;
    logic [7:0]          be;
    logic [1:0]          size;
  } bypass_req_t;

  typedef struct packed {
    logic        gnt;
    logic        valid;
    logic [63:0] rdata;
  } bypass_rsp_t;

  // ----------------------
  // MSI coherence
  // ----------------------
  // Line states are encoded in the valid/owned/dirty bits of the status array:
  //   I: valid = 0
  //   S: valid = 1, owned = 0 (never dirty)
  //   M: valid = 1, owned = 1 (dirty only if written since the fill)
  typedef enum logic [1:0] {
    CC_GETS = 2'b00,  // read a line, other caches downgrade M -> S
    CC_GETM = 2'b01,  // obtain ownership, other caches invalidate
    CC_PUTM = 2'b10   // write back an owned line, nobody else holds it
  } cc_req_type_e;

  // Coherence bus request, held until granted. The grant starts a tenure
  // during which no other cache touches memory or receives a conflicting
  // snoop; the requester ends it with a single-cycle done pulse.
  typedef struct packed {
    logic         valid;
    cc_req_type_e req_type;
    logic [55:0]  addr;  // line-aligned physical address
  } cc_req_t;

  // Snoop towards a cache; only CC_GETS and CC_GETM are ever snooped.
  typedef struct packed {
    logic         valid;
    cc_req_type_e req_type;
    logic [55:0]  addr;  // line-aligned physical address
  } cc_snoop_t;

endpackage : std_cache_pkg

