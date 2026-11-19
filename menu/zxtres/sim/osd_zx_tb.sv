// Frame of the ZXTRES menu OSD (../osd_zx.v) as the menu core shows it:
// 640x480 at the menu core's timing (800x525 clocks, blanks used), the
// commands of the io controller replayed from a text file on the OSD SPI
// channel, and the second frame written as a PPM picture.
//
//   +SPI=<file>   one SPI transaction per line, hexadecimal bytes
//   +OUT=<file>   the PPM picture (default frame.ppm)
`timescale 1ns/1ps
module osd_zx_tb;
    reg clk = 1'b0;
    always #20 clk = ~clk;                 // 25 MHz pixel clock

    reg sck = 1'b0, ss3 = 1'b1, sdi = 1'b0;

    // menu core timing (Menu_MIST/menu.sv): 640 active of 800, 480 of 525
    reg [9:0] hc = 0, vc = 0;
    reg hblank = 0, vblank = 0, hsync = 0, vsync = 0;
    always @(posedge clk) begin
        hc <= hc == 799 ? 10'd0 : hc + 1'd1;
        if (hc == 799) vc <= vc == 524 ? 10'd0 : vc + 1'd1;
        hblank <= hc >= 639;
        hsync  <= hc >= 655 && hc < 751;
        vblank <= vc >= 480;
        vsync  <= vc >= 490 && vc < 492;
    end

    // background: a grey ramp, as the menu core's own picture
    wire [7:0] bg = 8'd110 + vc[9:2];
    wire [7:0] r, g, b;

    osd #(.OSD_X_OFFSET(11'd10), .OSD_Y_OFFSET(11'd0), .OSD_COLOR(3'd4), .OSD_AUTO_CE(1'b0),
          .USE_BLANKS(1'b1), .OUT_COLOR_DEPTH(8), .BIG_OSD(1'b1)) dut (
        .clk_sys(clk), .ce(1'b1),
        .SPI_SCK(sck), .SPI_SS3(ss3), .SPI_DI(sdi),
        .rotate(2'b00),
        .R_in(bg), .G_in(bg), .B_in(bg),
        .HBlank(hblank), .VBlank(vblank), .HSync(~hsync), .VSync(~vsync),
        .R_out(r), .G_out(g), .B_out(b));

    task automatic spi_byte(input [7:0] v);
        for (int i = 7; i >= 0; i--) begin
            sdi = v[i];
            #100 sck = 1'b1;
            #100 sck = 1'b0;
        end
    endtask

    // one transaction per line of the file
    task automatic replay(input string fn);
        int fd, c, n;
        string line;
        fd = $fopen(fn, "r");
        if (fd == 0) begin $display("cannot open %s", fn); $finish; end
        while (!$feof(fd)) begin
            if ($fgets(line, fd) == 0) break;
            if (line.len() < 2) continue;
            ss3 = 1'b0;
            #100;
            n = 0;
            while (n + 1 < line.len()) begin
                if (line[n] == " " || line[n] == "\n" || line[n] == "\r") begin n++; continue; end
                c = line.substr(n, n + 1).atohex();
                spi_byte(c[7:0]);
                n += 2;
            end
            #100 ss3 = 1'b1;
            #200;
        end
        $fclose(fd);
    endtask

    integer fo;
    string spi_file, out_file;
    initial begin
        if (!$value$plusargs("SPI=%s", spi_file)) spi_file = "osd.spi";
        if (!$value$plusargs("OUT=%s", out_file)) out_file = "frame.ppm";
        replay(spi_file);
        // a whole frame for the OSD to measure the picture, then capture one
        @(posedge clk iff (hc == 0 && vc == 0));
        @(posedge clk iff (hc == 0 && vc == 0));
        fo = $fopen(out_file, "wb");
        $fwrite(fo, "P6\n640 480\n255\n");
        for (int y = 0; y < 480; y++)
            for (int x = 0; x < 640; x++) begin
                @(posedge clk iff (hc == x[9:0] + 10'd1 && vc == y[9:0]));
                #1 $fwrite(fo, "%c%c%c", r, g, b);
            end
        $fclose(fo);
        $display("OSD_ZX_FRAME %s", out_file);
        $finish;
    end
endmodule
