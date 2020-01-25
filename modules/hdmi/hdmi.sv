// Implementation of HDMI Spec v1.4a
// By Sameer Puri https://github.com/sameer

module hdmi 
#(
    // Defaults to 640x480 which should be supported by almost if not all HDMI sinks.
    // See README.md or CEA-861-D for enumeration of video id codes.
    // README.md lists supported codes.
    // Pixel repetition, interlaced scans and other special output modes are not implemented (yet).
    parameter VIDEO_ID_CODE = 7'd1,

    // Defaults to minimum bit lengths required to represent positions.
    // Modify these parameters if you have alternate desired bit lengths.
    parameter BIT_WIDTH = VIDEO_ID_CODE < 4 ? 10 : VIDEO_ID_CODE == 4 ? 11 : 12,
    parameter BIT_HEIGHT = VIDEO_ID_CODE == 16 ? 11: 10,

    // A true HDMI signal can send auxiliary data (i.e. audio, preambles) which prevents it from being parsed by DVI signal sinks.
    // HDMI signal sinks are fortunately backwards-compatible with DVI signals.
    // Enable this flag if the output should be a DVI signal. You might want to do this to reduce logic cell usage or if you're only outputting video.
    parameter DVI_OUTPUT = 1'b0,

    // **All parameters below matter ONLY IF you plan on sending auxiliary data (DVI_OUTPUT == 1'b0)**

    // 59.94 Hz = 0, 60Hz = 1
    parameter VIDEO_RATE = 0,

    // As noted in Section 7.3, the minimal audio requirements are met: 16-bit to 24-bit L-PCM audio at 32 kHz, 44.1 kHz, or 48 kHz.
    // See Table 7-4 or README.md
    parameter AUDIO_RATE = 32000,

    // Defaults to 16-bit audio. Can be anywhere from 16-bit to 24-bit.
    parameter AUDIO_BIT_WIDTH = 16
)
(
    input logic clk_tmds,
    input logic clk_pixel,
    input logic clk_audio,
    input logic [23:0] rgb,
    input logic [AUDIO_BIT_WIDTH-1:0] audio_sample_word [1:0],

    output logic [2:0] tmds_p,
    output logic tmds_clock_p,
    output logic [2:0] tmds_n,
    output logic tmds_clock_n,
    output logic [BIT_WIDTH-1:0] cx = BIT_WIDTH'(0),
    output logic [BIT_HEIGHT-1:0] cy = BIT_HEIGHT'(0)
);

localparam NUM_CHANNELS = 3;

// All channels are initialized to the 0,0 control signal from 5.4.2.
// This gives time for the first pixel to be generated by the first clock.
logic [9:0] tmds_shift [NUM_CHANNELS-1:0] = '{10'b1101010100, 10'b1101010100, 10'b1101010100};

// True differential buffer built with altera_gpio_lite from the Intel IP Catalog.
// Interchangeable with Xilinx OBUFDS primitive where .din is .I, .pad_out is .O, .pad_out_b is .OB
OBUFDS obufds(.din({tmds_shift[2][0], tmds_shift[1][0], tmds_shift[0][0], clk_pixel}), .pad_out({tmds_p, tmds_clock_p}), .pad_out_b({tmds_n,tmds_clock_n}));

// See CEA-861-D for more specifics formats described below.
logic [BIT_WIDTH-1:0] frame_width;
logic [BIT_HEIGHT-1:0] frame_height;
logic [BIT_WIDTH-1:0] screen_width;
logic [BIT_HEIGHT-1:0] screen_height;
logic [BIT_WIDTH-1:0] screen_start_x;
logic [BIT_HEIGHT-1:0] screen_start_y;
logic hsync;
logic vsync;

generate
    case (VIDEO_ID_CODE)
        1:
        begin
            assign frame_width = 800;
            assign frame_height = 525;
            assign screen_width = 640;
            assign screen_height = 480;
            assign hsync = ~(cx > 15 && cx <= 15 + 96);
            assign vsync = ~(cy < 2);
            end
        2, 3:
        begin
            assign frame_width = 858;
            assign frame_height = 525;
            assign screen_width = 720;
            assign screen_height = 480;
            assign hsync = ~(cx > 15 && cx <= 15 + 62);
            assign vsync = ~(cy > 5 && cy < 12);
            end
        4:
        begin
            assign frame_width = 1650;
            assign frame_height = 750;
            assign screen_width = 1280;
            assign screen_height = 720;
            assign hsync = cx > 109 && cx <= 109 + 40;
            assign vsync = cy < 5;
        end
        16:
        begin
            assign frame_width = 2200;
            assign frame_height = 1125;
            assign screen_width = 1920;
            assign screen_height = 1080;
            assign hsync = cx > 87 && cx <= 87 + 44;
            assign vsync = cy < 5;
        end
        17, 18:
        begin
            assign frame_width = 864;
            assign frame_height = 625;
            assign screen_width = 720;
            assign screen_height = 576;
            assign hsync = ~(cx > 11 && cx <= 11 + 64);
            assign vsync = ~(cy < 5);
        end
        19:
        begin
            assign frame_width = 1980;
            assign frame_height = 750;
            assign screen_width = 1280;
            assign screen_height = 720;
            assign hsync = cx > 439 && cx <= 439 + 40;
            assign vsync = cy < 5;
        end
    endcase
    assign screen_start_x = frame_width - screen_width;
    assign screen_start_y = frame_height - screen_height;
endgenerate

// Wrap-around pixel position counters indicating the pixel to be generated in the NEXT pixel clock.
always @(posedge clk_pixel)
begin
    cx <= cx == frame_width-1'b1 ? BIT_WIDTH'(0) : cx + 1'b1;
    cy <= cx == frame_width-1'b1 ? cy == frame_height-1'b1 ? BIT_HEIGHT'(0) : cy + 1'b1 : cy;
end

// See Section 5.2
logic video_data_period = 1;
logic video_guard = 0;
logic video_preamble = 0;

// See Section 5.2.3.1
integer max_num_packets_alongside;
logic [4:0] num_packets_alongside;
assign max_num_packets_alongside = (screen_start_x /* VD period */ - 2 /* V guard */ - 8 /* V preamble */ - 12 /* 12px control period */ - 2 /* DI guard */ - 2 /* DI start guard */ - 8 /* DI premable */) / 32;
assign num_packets_alongside = max_num_packets_alongside > 18 ? 5'd18 : 5'(max_num_packets_alongside);

logic data_island_guard = 0;
logic data_island_preamble = 0;
logic data_island_period = 0;

logic data_island_period_instantaneous;
assign data_island_period_instantaneous = !DVI_OUTPUT && num_packets_alongside > 0 && cx >= 10 && cx < 10 + num_packets_alongside * 32;
logic packet_enable;
assign packet_enable = data_island_period_instantaneous && (cx - 10) % 32 == 0;

always @(posedge clk_pixel)
begin
    video_data_period <= cx >= screen_start_x && cy >= screen_start_y;
    video_guard <= !DVI_OUTPUT && (cx >= screen_start_x - 2 && cx < screen_start_x) && cy >= screen_start_y;
    video_preamble <= !DVI_OUTPUT && (cx >= screen_start_x - 10 && cx < screen_start_x - 2) && cy >= screen_start_y;
    data_island_guard <= !DVI_OUTPUT && num_packets_alongside > 0 && ((cx >= 8 && cx < 10) || (cx >= 10 + num_packets_alongside * 32 && cx < 10 + num_packets_alongside * 32 + 2));
    data_island_preamble <= !DVI_OUTPUT && num_packets_alongside > 0 && cx >= 0 && cx < 8;
    data_island_period <= data_island_period_instantaneous;
end

// See Section 5.3
logic [23:0] headers [255:0];
logic [55:0] subs [255:0] [3:0];

// NULL packet
// "An HDMI Sink shall ignore bytes HB1 and HB2 of the Null Packet Header and all bytes of the Null Packet Body."
assign headers[0] = {8'dX, 8'dX, 8'd0}; assign subs[0] = '{56'dX, 56'dX, 56'dX, 56'dX};

localparam SAMPLING_FREQUENCY = AUDIO_RATE == 32000 ? 4'b0011
    : AUDIO_RATE == 44100 ? 4'b0000
    : AUDIO_RATE == 88200 ? 4'b1000
    : AUDIO_RATE == 176400 ? 4'b1100
    : AUDIO_RATE == 48000 ? 4'b0010
    : AUDIO_RATE == 96000 ? 4'b1010
    : AUDIO_RATE == 192000 ? 4'b1110
    : 4'bXXXX;

logic audio_clock_regeneration_sent = 1'b0;
logic audio_info_frame_sent = 1'b0;
logic [3:0] remaining;
logic [AUDIO_BIT_WIDTH-1:0] audio_out [1:0];
audio_buffer #(.CHANNELS(2), .BIT_WIDTH(AUDIO_BIT_WIDTH), .BUFFER_SIZE(16)) audio_buffer (.clk_audio(clk_audio), .clk_pixel(clk_pixel), .packet_enable(packet_enable && remaining > 3'd0), .audio_in(audio_sample_word), .audio_out(audio_out), .remaining(remaining));

localparam REGEN_WIDTH = $clog2(SAMPLING_FREQUENCY/100);
logic [REGEN_WIDTH-1:0] regen_counter = 0;
always @(posedge clk_audio)
    regen_counter <= regen_counter == REGEN_WIDTH'(SAMPLING_FREQUENCY/100 - 1) ? 1'd0 : regen_counter + 1'd1;

logic [19:0] cts_counter = 20'd0, cts = 20'd0;
always @(posedge clk_pixel)
    cts_counter <= regen_counter == REGEN_WIDTH'(0) ? 20'd0 : cts_counter + 1'd1;

logic [7:0] packet_type = 8'd0;
logic [23:0] audio_sample_word_padded [1:0];
always @(posedge clk_pixel)
begin
    if (cx == 0 && cy == 0) // RESET
        audio_info_frame_sent <= 1'b0;
    if (regen_counter == REGEN_WIDTH'(0))
    begin
        audio_clock_regeneration_sent <= 1'b0;
        cts <= cts_counter;
    end
    if (packet_enable)
    begin
        if (remaining > 0)
        begin
            packet_type <= 8'd2;
            audio_sample_word_padded <= '{{(24-AUDIO_BIT_WIDTH)'(0), audio_out[1]}, {(24-AUDIO_BIT_WIDTH)'(0), audio_out[0]}};
        end
        else if (!audio_clock_regeneration_sent)
        begin
            packet_type <= 8'd1;
            audio_clock_regeneration_sent <= 1'b1;
        end
        else if (!audio_info_frame_sent)
        begin
            packet_type <= 8'h84;
            audio_info_frame_sent <= 1'b1;
        end
        else
            packet_type <= 8'd0;
    end
end

audio_clock_regeneration_packet #(.VIDEO_ID_CODE(VIDEO_ID_CODE), .VIDEO_RATE(VIDEO_RATE), .AUDIO_RATE(AUDIO_RATE), .SAMPLING_FREQUENCY(SAMPLING_FREQUENCY)) audio_clock_regeneration_packet (.cts(cts), .header(headers[1]), .sub(subs[1]));

localparam AUDIO_BIT_WIDTH_COMPARATOR = AUDIO_BIT_WIDTH < 20 ? 20 : AUDIO_BIT_WIDTH == 20 ? 25 : AUDIO_BIT_WIDTH < 24 ? 24 : AUDIO_BIT_WIDTH == 24 ? 29 : -1;
localparam WORD_LENGTH = 3'(AUDIO_BIT_WIDTH_COMPARATOR - AUDIO_BIT_WIDTH);
localparam WORD_LENGTH_LIMIT = AUDIO_BIT_WIDTH <= 20 ? 1'b0 : 1'b1;
logic [4:0] packet_pixel_counter;
logic [7:0] frame_counter = 8'd0;
always @(posedge clk_pixel)
    if (data_island_period && packet_pixel_counter == 5'd31 && packet_type == 8'h02) // Keep track of current IEC 60958 frame
        frame_counter <= frame_counter == 8'd191 ? 8'd0 : frame_counter + 1'b1;
audio_sample_packet #(.SAMPLING_FREQUENCY(SAMPLING_FREQUENCY), .WORD_LENGTH({{WORD_LENGTH[0], WORD_LENGTH[1], WORD_LENGTH[2]}, WORD_LENGTH_LIMIT})) audio_sample_packet (.frame_counter(frame_counter), .valid_bit(2'b00), .user_data_bit(2'b00), .audio_sample_word(audio_sample_word_padded), .header(headers[2]), .sub(subs[2]));

auxiliary_video_information_info_frame #(.VIDEO_ID_CODE(7'(VIDEO_ID_CODE))) auxiliary_video_information_info_frame(.header(headers[130]), .sub(subs[130]));
audio_info_frame audio_info_frame(.header(headers[132]), .sub(subs[132]));

// See Section 5.2.3.4
logic [23:0] header;
logic [55:0] sub [3:0];
logic [8:0] packet_data;
packet_assembler packet_assembler (.clk_pixel(clk_pixel), .data_island_period(data_island_period), .header(header), .sub(sub), .packet_data(packet_data), .counter(packet_pixel_counter));
packet_picker packet_picker (.packet_type(packet_type), .headers(headers), .subs(subs), .header(header), .sub(sub));

logic [2:0] mode = 3'd1;
logic [23:0] video_data = 24'd0;
logic [11:0] data_island_data = 12'd0;
logic [5:0] control_data = 6'd0;

always @(posedge clk_pixel)
begin
    mode <= data_island_guard ? 3'd4 : data_island_period ? 3'd3 : video_guard ? 3'd2 : video_data_period ? 3'd1 : 3'd0;
    video_data <= rgb;
    // See Section 5.2.3.4, Section 5.3.1, Section 5.3.2
    data_island_data[11:4] <= packet_data[8:1];
    data_island_data[3] <= cx != screen_start_x;
    data_island_data[2] <= packet_data[0];
    data_island_data[1:0] <= {vsync, hsync};
    control_data <= {{1'b0, data_island_preamble}, {1'b0, video_preamble || data_island_preamble}, {vsync, hsync}}; // ctrl3, ctrl2, ctrl1, ctrl0, vsync, hsync
end

logic [9:0] tmds [NUM_CHANNELS-1:0];
genvar i;
generate
    for (i = 0; i < NUM_CHANNELS; i++)
    begin: tmds_gen
        tmds_channel #(.CN(i)) tmds_channel (.clk_pixel(clk_pixel), .video_data(video_data[i*8+7:i*8]), .data_island_data(data_island_data[i*4+3:i*4]), .control_data(control_data[i*2+1:i*2]), .mode(mode), .tmds(tmds[i]));
    end
endgenerate

// See Section 5.4.1
logic [3:0] tmds_counter = 4'd0;

integer j;
always @(posedge clk_tmds)
begin
    if (tmds_counter == 4'd9)
    begin
        tmds_shift <= tmds;
        tmds_counter <= 4'd0;
    end
    else
    begin
        tmds_counter <= tmds_counter + 4'd1;
        for (j = 0; j < NUM_CHANNELS; j++)
            tmds_shift[j] <= {1'bX, tmds_shift[j][9:1]};
    end
end

endmodule
