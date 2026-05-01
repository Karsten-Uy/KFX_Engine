package fx_gain_tb_pkg;

    import audio_base_pkg::*;

    // Forward declaration so the driver knows the item exists
    typedef class fx_gain_item;

    // ------------------------------------------------------
    // 1. Transaction Item
    // ------------------------------------------------------
    class fx_gain_item extends audio_item_base;
        rand logic [7:0] gain;
    endclass

    // ------------------------------------------------------
    // 2. Driver
    // ------------------------------------------------------
    class fx_gain_driver;
        // Use the virtual interface handle to talk to the physical pins
        virtual fx_gain_if vif;
        mailbox #(fx_gain_item) mbx;

        function new(virtual fx_gain_if vif, mailbox #(fx_gain_item) mbx);
            this.vif = vif;
            this.mbx = mbx;
        endfunction

        task run();
            vif.audio_in  <= '0;
            vif.fx_gain   <= 8'd32;
            vif.sample_en <= 1'b0;

            forever begin
                fx_gain_item item;
                mbx.get(item); 

                @(posedge vif.clk);
                vif.audio_in[0] <= item.left;
                vif.audio_in[1] <= item.right;
                vif.fx_gain     <= item.gain;
                vif.sample_en   <= 1'b1;

                @(posedge vif.clk);
                vif.sample_en <= 1'b0;

                // Spacing out samples (e.g., for 48kHz processing)
                repeat(4) @(posedge vif.clk);
            end
        endtask
    endclass

    // ------------------------------------------------------
    // 3. Sequence
    // ------------------------------------------------------
    class fx_gain_sequence;
        mailbox #(fx_gain_item) mbx;

        function new(mailbox #(fx_gain_item) mbx);
            this.mbx = mbx;
        endfunction

        task send_item(string desc, int left, int right, int gain);
            fx_gain_item item = new();
            item.description = desc; 
            item.left        = left; 
            item.right       = right;
            item.gain        = gain;
            mbx.put(item);
        endtask

        task body();
            $display("[%0t] [SEQ] Starting stimulus sequence...", $time);

            // --- 1. Basic Functionality ---
            send_item("Unity Gain",     16'sd1000, -16'sd1000, 8'd32);  // 1.0x
            send_item("Mute Test",      16'sd5000,  16'sd5000, 8'd0);   // 0.0x
            send_item("Half Volume",    16'sd4000, -16'sd4000, 8'd16);  // 0.5x
            send_item("Double Volume",  16'sd2000, -16'sd2000, 8'd64);  // 2.0x

            // --- 2. Corner Cases (Full Scale Inputs) ---
            send_item("Max Pos Input",  16'sd32767, 16'sd32767, 8'd32);
            send_item("Max Neg Input", -16'sd32768, -16'sd32768, 8'd32);

            // --- 3. Saturation (Clipping) Tests ---
            // Max input (32767) * Max gain (approx 8.0x) should trigger sat16
            send_item("Pos Saturation", 16'sd10000, 16'sd20000, 8'd255); 
            send_item("Neg Saturation", -16'sd10000, -16'sd20000, 8'd255);

            // --- 4. Small Signal / Precision Test ---
            // Testing if very small gains or inputs result in zero (underflow)
            send_item("Underflow Test", 16'sd10, -16'sd10, 8'd1); 

            // --- 5. Randomized Stimuli (ModelSim-Friendly Style) ---
            repeat(20) begin
                fx_gain_item rand_item = new();
                
                // If the Questasim warning blocks you, use manual randomization:
                rand_item.left  = $signed($urandom);
                rand_item.right = $signed($urandom);
                rand_item.gain  = $urandom_range(0, 255);
                
                rand_item.description = "Random Test";
                mbx.put(rand_item);
            end

            $display("[%0t] [SEQ] Stimulus sequence complete.", $time);
        endtask
    endclass
    
endpackage