const std = @import("std");

pub fn decodeSourceURL(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(allocator);

    // Mapping hex pairs to characters, as per GoAnime/Curd
    var i: usize = 0;
    while (i + 1 < encoded.len) {
        const pair = encoded[i .. i+2];
        var mapped: u8 = 0;
        
        if (std.mem.eql(u8, pair, "01")) mapped = '9'
        else if (std.mem.eql(u8, pair, "08")) mapped = '0'
        else if (std.mem.eql(u8, pair, "05")) mapped = '='
        else if (std.mem.eql(u8, pair, "0a")) mapped = '2'
        else if (std.mem.eql(u8, pair, "0b")) mapped = '3'
        else if (std.mem.eql(u8, pair, "0c")) mapped = '4'
        else if (std.mem.eql(u8, pair, "07")) mapped = '?'
        else if (std.mem.eql(u8, pair, "00")) mapped = '8'
        else if (std.mem.eql(u8, pair, "5c")) mapped = 'd'
        else if (std.mem.eql(u8, pair, "0f")) mapped = '7'
        else if (std.mem.eql(u8, pair, "5e")) mapped = 'f'
        else if (std.mem.eql(u8, pair, "17")) mapped = '/'
        else if (std.mem.eql(u8, pair, "54")) mapped = 'l'
        else if (std.mem.eql(u8, pair, "09")) mapped = '1'
        else if (std.mem.eql(u8, pair, "48")) mapped = 'p'
        else if (std.mem.eql(u8, pair, "4f")) mapped = 'w'
        else if (std.mem.eql(u8, pair, "0e")) mapped = '6'
        else if (std.mem.eql(u8, pair, "5b")) mapped = 'c'
        else if (std.mem.eql(u8, pair, "5d")) mapped = 'e'
        else if (std.mem.eql(u8, pair, "0d")) mapped = '5'
        else if (std.mem.eql(u8, pair, "53")) mapped = 'k'
        else if (std.mem.eql(u8, pair, "1e")) mapped = '&'
        else if (std.mem.eql(u8, pair, "5a")) mapped = 'b'
        else if (std.mem.eql(u8, pair, "59")) mapped = 'a'
        else if (std.mem.eql(u8, pair, "4a")) mapped = 'r'
        else if (std.mem.eql(u8, pair, "4c")) mapped = 't'
        else if (std.mem.eql(u8, pair, "4e")) mapped = 'v'
        else if (std.mem.eql(u8, pair, "57")) mapped = 'o'
        else if (std.mem.eql(u8, pair, "51")) mapped = 'i';

        if (mapped != 0) {
            try out.append(allocator, mapped);
        } else {
            try out.appendSlice(allocator, pair);
        }
        i += 2;
    }

    if (i < encoded.len) {
        try out.append(allocator, encoded[i]);
    }

    // if string contains /clock, replace with /clock.json per GoAnime
    const decoded_str = out.items;
    var res_str: []u8 = undefined;
    
    if (std.mem.indexOf(u8, decoded_str, "/clock?")) |idx| {
        // "/clock?id=..." -> "/clock.json?id=..."
        res_str = try std.fmt.allocPrint(allocator, "{s}/clock.json{s}", .{
            decoded_str[0..idx],
            decoded_str[idx + 6 ..],
        });
    } else {
        res_str = try allocator.dupe(u8, decoded_str);
    }
    
    defer allocator.free(res_str);

    if (std.mem.startsWith(u8, res_str, "/")) {
        const full_url = try std.fmt.allocPrint(allocator, "https://api.allanime.day{s}", .{res_str});
        return full_url;
    }

    return allocator.dupe(u8, res_str);
}

test "decoding allanime hash" {
    const alloc = std.testing.allocator;
    const hash = "e2bb4a8d42d3cbb42137d579b28b9c7b2c93b3z52a92a3bbab4fc0d71ba3f07a2w4803z20fa94bf551381274955c42bc8ccdb990a82bcefc62";
    const decoded = try decodeSourceURL(alloc, hash);
    defer alloc.free(decoded);
    try std.testing.expect(decoded.len > 0);
}
