module blink (
    input clk,          
    output [5:0] led 
);

    reg [24:0] counter = 0;

    always @(posedge clk) begin
        counter <= counter + 1;
    end

    assign led[0] = counter[24];
    assign led[1] = 1'b1;
    assign led[2] = 1'b1;
    assign led[3] = 1'b1;
    assign led[4] = 1'b1;
    assign led[5] = 1'b1;

endmodule
