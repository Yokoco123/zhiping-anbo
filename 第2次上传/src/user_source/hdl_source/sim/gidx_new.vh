function [15:0] gidx;               // 16'hFFFF = 字库里没有
    input [15:0] cp;
    reg   [15:0] k;
    reg          hit;
    begin
        hit = 1'b1;
        if      (cp >= 16'h0020 && cp <= 16'h007E) k = 16'h0020;
        else if (cp >= 16'h00A0 && cp <= 16'h00FF) k = 16'h0041;
        else if (cp >= 16'h2000 && cp <= 16'h206F) k = 16'h1F41;
        else if (cp >= 16'h3000 && cp <= 16'h303F) k = 16'h2ED1;
        else if (cp >= 16'h4E00 && cp <= 16'h9FFF) k = 16'h4C91;
        else if (cp >= 16'hFF00 && cp <= 16'hFFEF) k = 16'hAB91;
        else begin k = 16'h0000; hit = 1'b0; end
        gidx = hit ? (cp - k) : 16'hFFFF;
    end
endfunction