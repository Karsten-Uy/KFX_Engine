package audio_base_pkg;

    virtual class audio_item_base;
        rand logic signed [15:0] left;
        rand logic signed [15:0] right;
        string                   description;

        function void display();
            $display("[%s] L: %0d, R: %0d", description, left, right);
        endfunction
    endclass

endpackage