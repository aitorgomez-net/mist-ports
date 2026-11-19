// A simple OSD implementation. Can be hooked up between a cores
// VGA output and the physical VGA pins
//
// ZXTRES menu core version (mist-ports/menu/zxtres/osd_zx.v): the MiST OSD
// of mist-modules, unchanged while the theme is off, plus a ZX Spectrum
// theme that the io controller (the RP2040 middle board firmware) switches
// on. With the theme on, the OSD is opaque, twice as wide (each OSD pixel is
// two picture pixels wide; lines are doubled as before on 31 kHz pictures),
// in Spectrum colours, framed in black, with a title bar above the text
// lines and a status bar below them, both black with the four Spectrum
// stripes at the right end.
//
// Commands added to the OSD SPI channel (SPI_SS3), none of which the classic
// OSD or the firmware used before:
//   C0h / C1h          theme off / on
//   Anh, attr          attribute of text line n (0-15):
//                        0 normal (black ink on white paper)
//                        1 directory (blue ink on white paper)
//                        2 selected (black ink on cyan paper)
//                        3 disabled (grey ink on white paper)
//   B0h, 256 bytes     bitmap of the title bar (column bytes, as a line)
//   B1h, 256 bytes     bitmap of the status bar
// The text lines keep the classic write command (2nh, 256 bytes).

module osd (
	// OSDs pixel clock, should be synchronous to cores pixel clock to
	// avoid jitter.
	input        clk_sys,
	input        ce,

	// SPI interface
	input        SPI_SCK,
	input        SPI_SS3,
	input        SPI_DI,

	input  [1:0] rotate, //[0] - rotate [1] - left or right

	// VGA signals coming from core
	input [OUT_COLOR_DEPTH-1:0] R_in,
	input [OUT_COLOR_DEPTH-1:0] G_in,
	input [OUT_COLOR_DEPTH-1:0] B_in,
	input        HBlank,
	input        VBlank,
	input        HSync,
	input        VSync,

	// VGA signals going to video connector
	output [OUT_COLOR_DEPTH-1:0] R_out,
	output [OUT_COLOR_DEPTH-1:0] G_out,
	output [OUT_COLOR_DEPTH-1:0] B_out
);

parameter OSD_X_OFFSET = 11'd0;
parameter OSD_Y_OFFSET = 11'd0;
parameter OSD_COLOR    = 3'd0;
parameter OSD_AUTO_CE  = 1'b1;
parameter USE_BLANKS   = 1'b0;
parameter OUT_COLOR_DEPTH = 6;
parameter BIG_OSD = 1'b0;

localparam OSD_WIDTH   = 11'd256;
localparam OSD_HEIGHT  = 11'd128;
localparam OSD_LINES   = 8 << BIG_OSD;

localparam OSD_WIDTH_PADDED = OSD_WIDTH + (OSD_WIDTH >> 1);  // 25% padding left and right

// *********************************************************************************
// spi client
// *********************************************************************************

// this core supports only the display related OSD commands
// of the minimig
reg        osd_enable;
// text lines 0-15 at 0000h-0FFFh, the title bar at 1000h, the status bar at
// 1100h (theme commands B0h and B1h)
// the OSD buffer itself (osd_zx_ram below): 16 text lines of 256 bytes, then
// the title bar at 1000h and the status bar at 1100h
wire       buffer_wr;
wire [7:0] osd_byte;
reg        theme = 1'b0;
reg  [1:0] line_attr[0:15];

// the OSD has its own SPI interface to the io controller
reg  [4:0] cnt;
reg [12:0] bcnt;
reg  [7:0] sbuf;
reg  [7:0] cmd;

// command 0x20: OSDCMDWRITE; B0h/B1h: title and status bars
assign buffer_wr = ((cmd[7:4] == 4'b0010) || (cmd[7:1] == 7'b1011000)) && (cnt == 15);
// commands Anh: attribute of line n (first payload byte only)
wire attr_wr   = (cmd[7:4] == 4'b1010) && (cnt == 15) && (bcnt[7:0] == 8'h00);

// the buffer is written without the asynchronous reset of the SPI logic, so
// that it is a block RAM
always@(posedge SPI_SCK) begin
	if(!SPI_SS3 && attr_wr)   line_attr[cmd[3:0]] <= {sbuf[0], SPI_DI};
end

always@(posedge SPI_SCK, posedge SPI_SS3) begin
	if(SPI_SS3) begin
		cnt  <= 0;
		bcnt <= 0;
	end else begin
		sbuf <= {sbuf[6:0], SPI_DI};

		// 0:7 is command, rest payload
		if(cnt < 15) cnt <= cnt + 1'd1;
			else cnt <= 8;

		if(cnt == 7) begin
			cmd <= {sbuf[6:0], SPI_DI};

			// lower four command bits are line address; B0h/B1h are the bars
			bcnt <= (sbuf[6:0] == 7'b1011000) ? {4'b1000, SPI_DI, 8'h00} : {1'b0, sbuf[2:0], SPI_DI, 8'h00};

			// command 0x40: OSDCMDENABLE, OSDCMDDISABLE
			if(sbuf[6:3] == 4'b0100) osd_enable <= SPI_DI;

			// commands C0h/C1h: theme off/on
			if(sbuf[6:0] == 7'b1100000) theme <= SPI_DI;
		end

		if(buffer_wr || attr_wr) bcnt <= bcnt + 1'd1;
	end
end

// *********************************************************************************
// video timing and sync polarity anaylsis
// *********************************************************************************

// horizontal counter
reg  [10:0] h_cnt;
reg  [10:0] hs_low, hs_high;
wire        hs_pol = hs_high < hs_low;
wire [10:0] dsp_width = (hs_pol & !USE_BLANKS) ? hs_low : hs_high;

// vertical counter
reg  [10:0] v_cnt;
reg  [10:0] vs_low, vs_high;
wire        vs_pol = vs_high < vs_low;
wire [10:0] dsp_height = (vs_pol & !USE_BLANKS) ? vs_low : vs_high;

wire doublescan = (dsp_height>350);

reg auto_ce_pix;
always @(posedge clk_sys) begin
	reg [15:0] cnt = 0;
	reg  [2:0] pixsz;
	reg  [2:0] pixcnt;
	reg        hs;

	cnt <= cnt + 1'd1;
	hs <= HSync;

	pixcnt <= pixcnt + 1'd1;
	if(pixcnt == pixsz) pixcnt <= 0;
	auto_ce_pix <= !pixcnt;

	if(hs && ~HSync) begin
		cnt <= 0;
		if(cnt <= OSD_WIDTH_PADDED * 2) pixsz <= 0;
		else if(cnt <= OSD_WIDTH_PADDED * 3) pixsz <= 1;
		else if(cnt <= OSD_WIDTH_PADDED * 4) pixsz <= 2;
		else if(cnt <= OSD_WIDTH_PADDED * 5) pixsz <= 3;
		else if(cnt <= OSD_WIDTH_PADDED * 6) pixsz <= 4;
		else pixsz <= 5;

		pixcnt <= 0;
		auto_ce_pix <= 1;
	end
end

wire ce_pix = OSD_AUTO_CE ? auto_ce_pix : ce;

always @(posedge clk_sys) begin
	reg hsD;
	reg vsD;

	if(ce_pix) begin
		if (USE_BLANKS) begin
			h_cnt <= h_cnt + 1'd1;
			if(HBlank) begin
				h_cnt <= 0;
				if (h_cnt != 0) begin
					hs_high <= h_cnt;
					v_cnt <= v_cnt + 1'd1;
				end
			end
			if(VBlank) begin
				v_cnt <= 0;
				if (v_cnt != 0 && vs_high != v_cnt + 1'd1) vs_high <= v_cnt;
			end
		end else begin
			// bring hsync into local clock domain
			hsD <= HSync;

			// falling edge of HSync
			if(!HSync && hsD) begin
				h_cnt <= 0;
				hs_high <= h_cnt;
			end

			// rising edge of HSync
			else if(HSync && !hsD) begin
				h_cnt <= 0;
				hs_low <= h_cnt;
				v_cnt <= v_cnt + 1'd1;
			end else begin
				h_cnt <= h_cnt + 1'd1;
			end

			vsD <= VSync;

			// falling edge of VSync
			if(!VSync && vsD) begin
				v_cnt <= 0;
				// if the difference is only one line, that might be interlaced picture
				if (vs_high != v_cnt + 1'd1) vs_high <= v_cnt;
			end

			// rising edge of VSync
			else if(VSync && !vsD) begin
				v_cnt <= 0;
				// if the difference is only one line, that might be interlaced picture
				if (vs_low != v_cnt + 1'd1) vs_low <= v_cnt;
			end
		end
	end
end

// area in which OSD is being displayed
reg [10:0] h_osd_start;
reg [10:0] h_osd_end;
reg [10:0] v_osd_start;
reg [10:0] v_osd_end;

always @(posedge clk_sys) begin
	h_osd_start <= ((dsp_width - OSD_WIDTH)>> 1) + OSD_X_OFFSET;
	h_osd_end   <= h_osd_start + OSD_WIDTH;
	v_osd_start <= ((dsp_height- (OSD_HEIGHT<<doublescan))>> 1) + OSD_Y_OFFSET;
	v_osd_end   <= v_osd_start + (OSD_HEIGHT<<doublescan);
end

wire [10:0] osd_hcnt    = h_cnt - h_osd_start;
wire [10:0] osd_vcnt    = v_cnt - v_osd_start;
wire [10:0] osd_hcnt_next  = osd_hcnt + 2'd1;  // one pixel offset for osd byte address register
reg         osd_de;

// The buffer has a single read port, through one registered address, so
// that it stays a block RAM: the classic OSD reads it while the theme is
// off, the theme (th_addr below) while it is on.
wire [11:0] cl_addr = !BIG_OSD ?
	(rotate[0] ? {rotate[1] ? osd_hcnt_next[7:5] : ~osd_hcnt_next[7:5],
	              rotate[1] ? (doublescan ? ~osd_vcnt[7:0] : ~{osd_vcnt[6:0], 1'b0}) :
	              (doublescan ?  osd_vcnt[7:0]  : {osd_vcnt[6:0], 1'b0})} :
	            {doublescan ? osd_vcnt[7:5] : osd_vcnt[6:4], osd_hcnt_next[7:0]}) :
	(rotate[0] ? {rotate[1] ? osd_hcnt_next[7:4] : ~osd_hcnt_next[7:4],
	              rotate[1] ? (doublescan ? ~osd_vcnt[7:0] : ~{osd_vcnt[6:0], 1'b0}) :
	              (doublescan ?  osd_vcnt[7:0]  : {osd_vcnt[6:0], 1'b0})} :
	            {doublescan ? osd_vcnt[7:4] : osd_vcnt[6:3], osd_hcnt_next[7:0]});

reg        osd_pixel;

always @(posedge clk_sys) begin
	if(ce_pix) begin
		if (!BIG_OSD) begin
			osd_pixel <= rotate[0]  ? osd_byte[rotate[1] ? osd_hcnt[4:2] : ~osd_hcnt[4:2]] :
			                          osd_byte[doublescan ? osd_vcnt[4:2] : osd_vcnt[3:1]];
		end else begin
			osd_pixel <= rotate[0]  ? osd_byte[rotate[1] ? osd_hcnt[3:1] : ~osd_hcnt[3:1]] :
			                          osd_byte[doublescan ? osd_vcnt[3:1] : osd_vcnt[2:0]];
		end

		osd_de <= osd_enable &&
		    ((USE_BLANKS && !HBlank) || (!USE_BLANKS && HSync != hs_pol)) && (h_cnt >= h_osd_start) && (h_cnt < h_osd_end) &&
		    ((USE_BLANKS && !VBlank) || (!USE_BLANKS && VSync != vs_pol)) && (v_cnt >= v_osd_start) && (v_cnt < v_osd_end);
	end
end

wire [OUT_COLOR_DEPTH-1:0] cl_r = !osd_de ? R_in : {osd_pixel, osd_pixel, OSD_COLOR[2], R_in[OUT_COLOR_DEPTH-1:3]};
wire [OUT_COLOR_DEPTH-1:0] cl_g = !osd_de ? G_in : {osd_pixel, osd_pixel, OSD_COLOR[1], G_in[OUT_COLOR_DEPTH-1:3]};
wire [OUT_COLOR_DEPTH-1:0] cl_b = !osd_de ? B_in : {osd_pixel, osd_pixel, OSD_COLOR[0], B_in[OUT_COLOR_DEPTH-1:3]};

// *********************************************************************************
// ZX Spectrum theme
// *********************************************************************************

// The box, in picture pixels: a black frame of one OSD pixel around the
// title bar (8 rows), the text lines and the status bar (8 rows), each OSD
// pixel two picture pixels wide, rows doubled on 31 kHz pictures.
localparam TH_ROWS  = OSD_LINES*8 + 16;     // OSD rows inside the frame
localparam TH_WIDTH = 11'd516;              // 256*2 + 2*2 frame pixels

reg [10:0] th_h_start;
reg [10:0] th_h_end;
reg [10:0] th_v_start;
reg [10:0] th_v_end;

always @(posedge clk_sys) begin
	// centred on the picture: the classic OSD offset (OSD_X_OFFSET) is not
	// applied to the theme, which put the box 10 pixels to the right
	th_h_start <= ((dsp_width - TH_WIDTH) >> 1);
	th_h_end   <= th_h_start + TH_WIDTH;
	th_v_start <= ((dsp_height - ((TH_ROWS + 11'd2) << doublescan)) >> 1) + OSD_Y_OFFSET;
	th_v_end   <= th_v_start + ((TH_ROWS + 11'd2) << doublescan);
end

wire [10:0] th_x  = h_cnt - th_h_start;              // 0-515 inside the box
wire [10:0] th_yl = v_cnt - th_v_start;
wire [10:0] th_y  = doublescan ? {1'b0, th_yl[10:1]} : th_yl;   // OSD row, frame included
wire        th_frame  = (th_x < 11'd2) || (th_x >= TH_WIDTH - 11'd2) ||
                        (th_y == 11'd0) || (th_y == TH_ROWS + 11'd1);
wire  [7:0] th_px     = th_x[8:1] - 1'd1;            // OSD column 0-255
wire [10:0] th_py     = th_y - 1'd1;                 // OSD row 0 to TH_ROWS-1
wire        th_title  = th_py < 11'd8;
wire        th_status = th_py >= TH_ROWS - 8;
wire [10:0] th_tl     = th_py - 11'd8;
wire  [3:0] th_line   = th_tl[6:3];
// the title bar, the text lines and the status bar start on multiples of 8
wire [12:0] th_addr   = th_title  ? {5'b10000, th_px} :
                        th_status ? {5'b10001, th_px} :
                                    {1'b0, th_line, th_px};

reg        th_de;
reg        th_frame_r;
reg  [1:0] th_kind;          // 0 text line, 1 status bar, 3 title bar
reg  [2:0] th_bit;
reg  [1:0] th_attr;
reg  [7:0] th_col;

// the theme reads the buffer through the registered address of the classic
// OSD: one more pixel of pipeline, which the colours below follow
osd_zx_ram osd_buffer (
	.wclk(SPI_SCK), .we(!SPI_SS3 && buffer_wr), .waddr(bcnt), .wdata({sbuf[6:0], SPI_DI}),
	.rclk(clk_sys), .re(ce_pix), .raddr(theme ? th_addr : {1'b0, cl_addr}), .rdata(osd_byte));
wire [7:0] th_byte = osd_byte;

always @(posedge clk_sys) begin
	if(ce_pix) begin
		th_frame_r <= th_frame;
		th_kind    <= th_title ? 2'd3 : th_status ? 2'd1 : 2'd0;
		th_bit     <= th_py[2:0];
		th_attr    <= line_attr[th_line];
		th_col     <= th_px;
		th_de <= osd_enable &&
		    ((USE_BLANKS && !HBlank) || (!USE_BLANKS && HSync != hs_pol)) && (h_cnt >= th_h_start) && (h_cnt < th_h_end) &&
		    ((USE_BLANKS && !VBlank) || (!USE_BLANKS && VSync != vs_pol)) && (v_cnt >= th_v_start) && (v_cnt < th_v_end);
	end
end

// the four stripes of the title bar: bands of 8 OSD columns, slanted one column
// per row, ending 8 columns before the right edge
wire [8:0] th_slant = {1'b0, th_col} + th_bit;          // 0-262
wire [8:0] th_rel   = th_slant - 9'd223;
wire       th_band  = (th_slant >= 9'd223) && (th_rel < 9'd32);
wire [1:0] th_bandn = th_rel[4:3];
wire       th_ink   = th_byte[th_bit];

// Spectrum colours, 8 bits per component: black, blue, red, yellow, green,
// bright cyan, bright white
function [23:0] th_colour;
	input frame, kind, ink, band;
	input [1:0] bandn;
	input [1:0] attr;
	begin
		if(frame)                    th_colour = 24'h000000;
		else if(kind) begin
			if(band) case(bandn)
				2'd0: th_colour = 24'hD70000;
				2'd1: th_colour = 24'hD7D700;
				2'd2: th_colour = 24'h00D700;
				default: th_colour = 24'h00FFFF;
			endcase
			else th_colour = ink ? 24'hFFFFFF : 24'h000000;
		end
		else case(attr)
			2'd1:    th_colour = ink ? 24'h0000D7 : 24'hFFFFFF;
			2'd2:    th_colour = ink ? 24'h000000 : 24'h00FFFF;
			default: th_colour = ink ? 24'h000000 : 24'hFFFFFF;
		endcase
	end
endfunction

wire [23:0] th_rgb = th_colour(th_frame_r, th_kind[0], th_ink, th_band && th_kind[1], th_bandn, th_attr);

assign R_out = (theme && th_de) ? th_rgb[23:24-OUT_COLOR_DEPTH] : theme ? R_in : cl_r;
assign G_out = (theme && th_de) ? th_rgb[15:16-OUT_COLOR_DEPTH] : theme ? G_in : cl_g;
assign B_out = (theme && th_de) ? th_rgb[7:8-OUT_COLOR_DEPTH]   : theme ? B_in : cl_b;

endmodule

// the OSD buffer: a simple dual port block RAM, written from the SPI clock,
// read with a registered output (the registered address of the MiST osd.v)
module osd_zx_ram (
	input             wclk,
	input             we,
	input      [12:0] waddr,
	input       [7:0] wdata,
	input             rclk,
	input             re,
	input      [12:0] raddr,
	output reg  [7:0] rdata
);

(* ram_style = "block" *) reg [7:0] mem[0:8191];

always @(posedge wclk) if (we) mem[waddr] <= wdata;
always @(posedge rclk) if (re) rdata <= mem[raddr];

endmodule
