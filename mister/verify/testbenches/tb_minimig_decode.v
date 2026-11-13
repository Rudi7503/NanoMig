`timescale 1ns/1ps

module tb_minimig_decode;
    reg [23:1] cpu_address_out;

    // Decoding expressions
    wire audio_ext_selected = (cpu_address_out[23:10] == 14'b1101_1111_1111_01);
    
    // OLD decoding
    wire old_audio_irq_selected = (cpu_address_out[23:4] == (24'hDFF804 >> 4)) && (cpu_address_out[3:1] <= 3'd3);
    
    // NEW fixed decoding
    wire new_audio_irq_selected = (cpu_address_out[23:4] == (24'hDFF804 >> 4)) && 
                                  (cpu_address_out[3:1] >= 3'd2 && cpu_address_out[3:1] <= 3'd5);
    wire [1:0] new_irq_addr = cpu_address_out[2:1] ^ 2'b10; // or cpu_address_out[3:1] - 3'd2

    wire ham_ext_selected  = (cpu_address_out[23:1] == (24'hDFF800 >> 1));
    wire cap_ctrl_selected = (cpu_address_out[23:1] == (24'hDFF802 >> 1));
    wire audio_cap_selected = (cpu_address_out[23:13] == 11'b1101_1111_100);

    task test_addr(input [23:0] addr, input [80*8:1] desc);
        begin
            cpu_address_out = addr[23:1];
            #1;
            $display("Addr %h (%0s):", addr, desc);
            $display("  cap_ctrl=%b, old_irq=%b, new_irq=%b (addr=%0d), ham=%b, ext=%b, cap_buf=%b",
                cap_ctrl_selected, old_audio_irq_selected, new_audio_irq_selected, new_irq_addr,
                ham_ext_selected, audio_ext_selected, audio_cap_selected);
        end
    endtask

    initial begin
        $display("=== TESTING MINIMIG DECODING LOGIC ===");
        test_addr(24'hDFF800, "HAM control");
        test_addr(24'hDFF802, "AUD_CAP capture ctrl");
        test_addr(24'hDFF804, "Audio IRQ INTENA HI");
        test_addr(24'hDFF806, "Audio IRQ INTENA LO");
        test_addr(24'hDFF808, "Audio IRQ INTREQ HI");
        test_addr(24'hDFF80A, "Audio IRQ INTREQ LO");
        test_addr(24'hDF8000, "AUD_BUF_A start");
        test_addr(24'hDF8FFE, "AUD_BUF_A end");
        test_addr(24'hDF9000, "AUD_BUF_B start");
        test_addr(24'hDF9FFE, "AUD_BUF_B end");
        test_addr(24'hDFF400, "AUDIO_EXT base");
        test_addr(24'hDFF7FE, "AUDIO_EXT end");
        test_addr(24'hDFF180, "COLOR00 standard custom reg");
        $finish;
    end
endmodule
