class axi4l_driver extends uvm_driver #(axi4l_seq_item);
  `uvm_component_utils(axi4l_driver)

  virtual axi4l_if #(AXI4L_ADDR_WIDTH, AXI4L_DATA_WIDTH) vif;

  // Three deliberately distinct operating modes are kept:
  //   legacy/default       - item_done() follows the B/R response;
  //   limited_overlap_mode - v2.1 coverage-only bounded overlap;
  //   pipelined_mode       - v3 ordered request/response decoupling.
  bit transaction_aborted;
  bit limited_overlap_mode;
  bit pipelined_mode;

  mailbox #(axi4l_seq_item) limited_response_mailbox;
  longint unsigned limited_requests_issued;
  longint unsigned limited_responses_completed;

  int unsigned max_write_outstanding = 1;
  int unsigned max_read_outstanding  = 1;
  mailbox #(axi4l_seq_item) pending_write_response_fifo;
  mailbox #(axi4l_seq_item) pending_read_response_fifo;
  semaphore write_credits;
  semaphore read_credits;
  int write_credit_balance;
  int read_credit_balance;
  int unsigned write_outstanding;
  int unsigned read_outstanding;
  longint unsigned v3_write_requests_issued;
  longint unsigned v3_read_requests_issued;
  longint unsigned v3_write_responses_completed;
  longint unsigned v3_read_responses_completed;
  longint unsigned driver_cycle;

  function new(string name = "axi4l_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual axi4l_if #(AXI4L_ADDR_WIDTH,
                                           AXI4L_DATA_WIDTH))::get(
          this, "", "vif", vif))
      `uvm_fatal("NOVIF", "axi4l_driver did not receive its virtual interface")

    void'(uvm_config_db#(bit)::get(this, "", "limited_overlap_mode",
                                   limited_overlap_mode));
    void'(uvm_config_db#(bit)::get(this, "", "pipelined_mode",
                                   pipelined_mode));
    void'(uvm_config_db#(int unsigned)::get(
      this, "", "max_write_outstanding", max_write_outstanding));
    void'(uvm_config_db#(int unsigned)::get(
      this, "", "max_read_outstanding", max_read_outstanding));

    if (limited_overlap_mode && pipelined_mode)
      `uvm_fatal("DRIVER_MODE",
                 "limited_overlap_mode and pipelined_mode are mutually exclusive")

    if (limited_overlap_mode)
      limited_response_mailbox = new();

    if (pipelined_mode) begin
      if ((max_write_outstanding == 0) || (max_read_outstanding == 0))
        `uvm_fatal("V3_DEPTH", "v3 outstanding depths must both be at least one")
      pending_write_response_fifo = new();
      pending_read_response_fifo  = new();
      write_credits = new(max_write_outstanding);
      read_credits  = new(max_read_outstanding);
      write_credit_balance = max_write_outstanding;
      read_credit_balance  = max_read_outstanding;
    end
  endfunction

  task run_phase(uvm_phase phase);
    drive_idle();
    fork
      count_driver_cycles();
      begin
        if (pipelined_mode) begin
          `uvm_info("V3_PIPELINED",
            $sformatf("enabled: max_write_outstanding=%0d max_read_outstanding=%0d",
                      max_write_outstanding, max_read_outstanding), UVM_LOW)
          fork
            pipelined_request_loop();
            pipelined_write_response_loop();
            pipelined_read_response_loop();
          join
        end else if (limited_overlap_mode) begin
          `uvm_info("LIMITED_OVERLAP",
                    "enabled request/response decoupling for bounded stall stress",
                    UVM_LOW)
          fork
            limited_request_loop();
            limited_response_loop();
          join
        end else begin
          run_blocking_loop();
        end
      end
    join
  endtask

  task count_driver_cycles();
    forever begin
      @(vif.drv_cb);
      driver_cycle++;
    end
  endtask

  // Legacy blocking path.  This remains the default so existing v2 tests keep
  // their original request-plus-response item_done() contract.
  task run_blocking_loop();
    axi4l_seq_item req;

    forever begin
      wait_for_reset_release();
      seq_item_port.get_next_item(req);
      req.resp                = 'x;
      req.rdata               = 'x;
      req.transaction_aborted = 1'b0;
      transaction_aborted     = 0;

      case (req.access)
        AXI4L_WRITE: drive_write(req);
        AXI4L_READ:  drive_read(req);
        default:     `uvm_error("BAD_ACCESS", "Unknown AXI4-Lite access type")
      endcase

      req.transaction_aborted = transaction_aborted;
      drive_idle();
      seq_item_port.item_done();
    end
  endtask

  // v2.1 coverage-only overlap path, preserved unchanged in behavior.
  task limited_request_loop();
    axi4l_seq_item req;

    forever begin
      wait_for_reset_release();
      seq_item_port.get_next_item(req);
      req.resp                = 'x;
      req.rdata               = 'x;
      req.transaction_aborted = 1'b0;
      transaction_aborted     = 0;

      case (req.access)
        AXI4L_WRITE: drive_write_request(req);
        AXI4L_READ:  drive_read_request(req);
        default:     `uvm_error("BAD_ACCESS", "Unknown AXI4-Lite access type")
      endcase

      if (!transaction_aborted) begin
        limited_requests_issued++;
        limited_response_mailbox.put(req);
      end
      req.transaction_aborted = transaction_aborted;
      seq_item_port.item_done();
    end
  endtask

  task limited_response_loop();
    axi4l_seq_item req;
    bit response_aborted;

    forever begin
      limited_response_mailbox.get(req);
      response_aborted = 0;
      case (req.access)
        AXI4L_WRITE: collect_write_response(req, response_aborted);
        AXI4L_READ:  collect_read_response(req, response_aborted);
        default:     `uvm_error("BAD_ACCESS", "Unknown AXI4-Lite access type")
      endcase
      limited_responses_completed++;
    end
  endtask

  task wait_for_limited_idle();
    if (!limited_overlap_mode)
      `uvm_fatal("LIMITED_OVERLAP",
                 "wait_for_limited_idle called while stress mode is disabled")
    wait (limited_requests_issued == limited_responses_completed);
  endtask

  // v3 formal pipelined path.  A credit is reserved before request-side
  // driving.  A write becomes pending only after both AW and W handshakes; a
  // read becomes pending after AR.  item_done() then releases the request,
  // while independent collectors retain context until B/R completes.
  task pipelined_request_loop();
    axi4l_seq_item req;
    axi4l_seq_item req_ctx;
    bit credit_acquired;

    forever begin
      wait_for_pipelined_reset_release();
      seq_item_port.get_next_item(req);
      if (!$cast(req_ctx, req.clone()))
        `uvm_fatal("V3_REQ_CLONE", "Failed to clone pipelined request context")
      // Explicitly retain the UVM routing IDs; object copy alone is not the
      // response association contract.
      req_ctx.set_id_info(req);
      req_ctx.resp                = 'x;
      req_ctx.rdata               = 'x;
      req_ctx.transaction_aborted = 1'b0;
      transaction_aborted         = 0;

      case (req_ctx.access)
        AXI4L_WRITE: begin
          acquire_pipelined_credit(write_credits, credit_acquired,
                                   transaction_aborted);
          if (credit_acquired)
            write_credit_balance--;
          if (!transaction_aborted)
            drive_write_request(req_ctx);
          if (transaction_aborted) begin
            req_ctx.transaction_aborted = 1'b1;
            if (credit_acquired) begin
              write_credits.put(1);
              write_credit_balance++;
            end
            // This request has already left the sequencer.  Release its
            // request-side ownership exactly once before routing the single
            // synthetic abort response back to the originating sequence.
            seq_item_port.item_done();
            publish_v3_response(req_ctx);
          end else begin
            req_ctx.accept_cycle = (req_ctx.aw_cycle > req_ctx.w_cycle)
                                 ? req_ctx.aw_cycle : req_ctx.w_cycle;
            write_outstanding++;
            v3_write_requests_issued++;
            pending_write_response_fifo.put(req_ctx);
            `uvm_info("V3_REQ",
              $sformatf("WRITE issue_cycle=%0d AW=%0d W=%0d addr=0x%0h outstanding=%0d/%0d seq_id=%0d tr_id=%0d",
                        req_ctx.accept_cycle, req_ctx.aw_cycle, req_ctx.w_cycle,
                        req_ctx.addr, write_outstanding,
                        max_write_outstanding, req_ctx.get_sequence_id(),
                        req_ctx.get_transaction_id()), UVM_NONE)
            // In v3 this means request-side ownership has transferred; it is
            // intentionally not complete AXI transaction retirement.
            seq_item_port.item_done();
          end
        end

        AXI4L_READ: begin
          acquire_pipelined_credit(read_credits, credit_acquired,
                                   transaction_aborted);
          if (credit_acquired)
            read_credit_balance--;
          if (!transaction_aborted)
            drive_read_request(req_ctx);
          if (transaction_aborted) begin
            req_ctx.transaction_aborted = 1'b1;
            if (credit_acquired) begin
              read_credits.put(1);
              read_credit_balance++;
            end
            seq_item_port.item_done();
            publish_v3_response(req_ctx);
          end else begin
            read_outstanding++;
            v3_read_requests_issued++;
            pending_read_response_fifo.put(req_ctx);
            `uvm_info("V3_REQ",
              $sformatf("READ issue_cycle=%0d addr=0x%0h outstanding=%0d/%0d seq_id=%0d tr_id=%0d",
                        req_ctx.accept_cycle, req_ctx.addr, read_outstanding,
                        max_read_outstanding, req_ctx.get_sequence_id(),
                        req_ctx.get_transaction_id()), UVM_NONE)
            seq_item_port.item_done();
          end
        end

        default: begin
          `uvm_error("BAD_ACCESS", "Unknown AXI4-Lite access type")
          seq_item_port.item_done();
        end
      endcase
    end
  endtask

  // A blocking semaphore get cannot observe reset.  In particular, a request
  // already fetched with get_next_item() could otherwise wait for a collector
  // to return a credit during reset, then survive into the next reset epoch.
  // Polling try_get at clock boundaries makes that request abortable and also
  // records whether there is a credit to return on the abort path.
  task automatic acquire_pipelined_credit(semaphore credits,
                                            output bit acquired,
                                            output bit aborted);
    acquired = 1'b0;
    aborted  = 1'b0;
    forever begin
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        aborted = 1'b1;
        return;
      end
      if (credits.try_get(1)) begin
        acquired = 1'b1;
        return;
      end
      @(vif.drv_cb);
    end
  endtask

  task pipelined_write_response_loop();
    axi4l_seq_item req_ctx;
    bit response_aborted;

    forever begin
      pending_write_response_fifo.get(req_ctx);
      collect_write_response(req_ctx, response_aborted);
      req_ctx.transaction_aborted = response_aborted;
      req_ctx.response_cycle      = driver_cycle;
      write_outstanding--;
      v3_write_responses_completed++;
      write_credits.put(1);
      write_credit_balance++;
      `uvm_info("V3_RSP",
        $sformatf("WRITE response_cycle=%0d addr=0x%0h BRESP=%02b aborted=%0b outstanding=%0d/%0d seq_id=%0d tr_id=%0d",
                  req_ctx.response_cycle, req_ctx.addr, req_ctx.resp,
                  req_ctx.transaction_aborted, write_outstanding,
                  max_write_outstanding, req_ctx.get_sequence_id(),
                  req_ctx.get_transaction_id()), UVM_NONE)
      publish_v3_response(req_ctx);
    end
  endtask

  task pipelined_read_response_loop();
    axi4l_seq_item req_ctx;
    bit response_aborted;

    forever begin
      pending_read_response_fifo.get(req_ctx);
      collect_read_response(req_ctx, response_aborted);
      req_ctx.transaction_aborted = response_aborted;
      req_ctx.response_cycle      = driver_cycle;
      read_outstanding--;
      v3_read_responses_completed++;
      read_credits.put(1);
      read_credit_balance++;
      `uvm_info("V3_RSP",
        $sformatf("READ response_cycle=%0d addr=0x%0h RDATA=0x%08h RRESP=%02b aborted=%0b outstanding=%0d/%0d seq_id=%0d tr_id=%0d",
                  req_ctx.response_cycle, req_ctx.addr, req_ctx.rdata,
                  req_ctx.resp, req_ctx.transaction_aborted, read_outstanding,
                  max_read_outstanding, req_ctx.get_sequence_id(),
                  req_ctx.get_transaction_id()), UVM_NONE)
      publish_v3_response(req_ctx);
    end
  endtask

  task automatic publish_v3_response(axi4l_seq_item req_ctx);
    axi4l_seq_item rsp;
    if (!$cast(rsp, req_ctx.clone()))
      `uvm_fatal("V3_RSP_CLONE", "Failed to clone pipelined response")
    // set_id_info() is the standard UVM response association mechanism.  It
    // preserves both sequence_id and transaction_id for get_response().
    rsp.set_id_info(req_ctx);
    if (rsp.response_cycle == 0)
      rsp.response_cycle = driver_cycle;
    seq_item_port.put_response(rsp);
  endtask

  task wait_for_pipelined_idle();
    if (!pipelined_mode)
      `uvm_fatal("V3_PIPELINED",
                 "wait_for_pipelined_idle called while v3 mode is disabled")
    wait ((write_outstanding == 0) && (read_outstanding == 0) &&
          (v3_write_requests_issued == v3_write_responses_completed) &&
          (v3_read_requests_issued == v3_read_responses_completed));
  endtask

  task wait_for_reset_release();
    while (vif.drv_cb.ARESETN !== 1'b1) begin
      drive_idle();
      @(vif.drv_cb);
    end
  endtask

  task wait_for_pipelined_reset_release();
    while (vif.drv_cb.ARESETN !== 1'b1) begin
      // BREADY and RREADY belong exclusively to their collectors in v3.
      drive_request_idle();
      @(vif.drv_cb);
    end
  endtask

  function void drive_request_idle();
    vif.drv_cb.AWADDR  <= '0;
    vif.drv_cb.AWPROT  <= '0;
    vif.drv_cb.AWVALID <= 1'b0;
    vif.drv_cb.WDATA   <= '0;
    vif.drv_cb.WSTRB   <= '0;
    vif.drv_cb.WVALID  <= 1'b0;
    vif.drv_cb.ARADDR  <= '0;
    vif.drv_cb.ARPROT  <= '0;
    vif.drv_cb.ARVALID <= 1'b0;
  endfunction

  function void drive_idle();
    drive_request_idle();
    vif.drv_cb.BREADY  <= 1'b0;
    vif.drv_cb.RREADY  <= 1'b0;
  endfunction

  task automatic drive_aw(axi4l_seq_item tr);
    repeat (tr.aw_delay) begin
      @(vif.drv_cb);
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        transaction_aborted = 1;
        return;
      end
    end

    vif.drv_cb.AWADDR  <= tr.addr;
    vif.drv_cb.AWPROT  <= tr.prot;
    vif.drv_cb.AWVALID <= 1'b1;
    do begin
      @(vif.drv_cb);
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        vif.drv_cb.AWVALID <= 1'b0;
        transaction_aborted = 1;
        return;
      end
    end while (!vif.drv_cb.AWREADY);
    tr.aw_cycle = driver_cycle;
    vif.drv_cb.AWVALID <= 1'b0;
  endtask

  task automatic drive_w(axi4l_seq_item tr);
    repeat (tr.w_delay) begin
      @(vif.drv_cb);
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        transaction_aborted = 1;
        return;
      end
    end

    vif.drv_cb.WDATA  <= tr.data;
    vif.drv_cb.WSTRB  <= tr.strb;
    vif.drv_cb.WVALID <= 1'b1;
    do begin
      @(vif.drv_cb);
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        vif.drv_cb.WVALID <= 1'b0;
        transaction_aborted = 1;
        return;
      end
    end while (!vif.drv_cb.WREADY);
    tr.w_cycle = driver_cycle;
    vif.drv_cb.WVALID <= 1'b0;
  endtask

  task automatic drive_write_request(axi4l_seq_item tr);
    // AXI deliberately permits these channels to complete in either order.
    fork
      drive_aw(tr);
      drive_w(tr);
    join
  endtask

  task automatic collect_write_response(axi4l_seq_item tr,
                                        output bit aborted);
    aborted = 0;
    if (vif.drv_cb.ARESETN !== 1'b1) begin
      vif.drv_cb.BREADY <= 1'b0;
      aborted = 1;
      return;
    end

    repeat (tr.bready_delay) begin
      @(vif.drv_cb);
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        vif.drv_cb.BREADY <= 1'b0;
        aborted = 1;
        return;
      end
    end

    vif.drv_cb.BREADY <= 1'b1;
    do begin
      @(vif.drv_cb);
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        vif.drv_cb.BREADY <= 1'b0;
        aborted = 1;
        return;
      end
    end while (!vif.drv_cb.BVALID);

    tr.resp = vif.drv_cb.BRESP;
    vif.drv_cb.BREADY <= 1'b0;
  endtask

  task automatic drive_write(axi4l_seq_item tr);
    bit response_aborted;

    drive_write_request(tr);
    if (transaction_aborted)
      return;
    tr.accept_cycle = (tr.aw_cycle > tr.w_cycle) ? tr.aw_cycle : tr.w_cycle;
    collect_write_response(tr, response_aborted);
    if (response_aborted)
      transaction_aborted = 1;
    tr.response_cycle = driver_cycle;
  endtask

  task automatic drive_read_request(axi4l_seq_item tr);
    repeat (tr.ar_delay) begin
      @(vif.drv_cb);
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        transaction_aborted = 1;
        return;
      end
    end

    vif.drv_cb.ARADDR  <= tr.addr;
    vif.drv_cb.ARPROT  <= tr.prot;
    vif.drv_cb.ARVALID <= 1'b1;
    do begin
      @(vif.drv_cb);
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        vif.drv_cb.ARVALID <= 1'b0;
        transaction_aborted = 1;
        return;
      end
    end while (!vif.drv_cb.ARREADY);
    tr.accept_cycle = driver_cycle;
    vif.drv_cb.ARVALID <= 1'b0;
  endtask

  task automatic collect_read_response(axi4l_seq_item tr,
                                       output bit aborted);
    aborted = 0;
    if (vif.drv_cb.ARESETN !== 1'b1) begin
      vif.drv_cb.RREADY <= 1'b0;
      aborted = 1;
      return;
    end

    repeat (tr.rready_delay) begin
      @(vif.drv_cb);
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        vif.drv_cb.RREADY <= 1'b0;
        aborted = 1;
        return;
      end
    end

    vif.drv_cb.RREADY <= 1'b1;
    do begin
      @(vif.drv_cb);
      if (vif.drv_cb.ARESETN !== 1'b1) begin
        vif.drv_cb.RREADY <= 1'b0;
        aborted = 1;
        return;
      end
    end while (!vif.drv_cb.RVALID);

    tr.rdata = vif.drv_cb.RDATA;
    tr.resp  = vif.drv_cb.RRESP;
    vif.drv_cb.RREADY <= 1'b0;
  endtask

  task automatic drive_read(axi4l_seq_item tr);
    bit response_aborted;

    drive_read_request(tr);
    if (transaction_aborted)
      return;
    collect_read_response(tr, response_aborted);
    if (response_aborted)
      transaction_aborted = 1;
    tr.response_cycle = driver_cycle;
  endtask
endclass
