// --- markdown.zig (Final Corrected Version) ---
const std = @import("std");
const mem = std.mem;
const lexer = @import("lexer.zig");
const ascii = std.ascii;

// --- AST Node Definition ---
pub const AstNode = struct {
    tag: Tag,
    children: ?std.ArrayListUnmanaged(*AstNode),
    text: ?[]const u8,
    start_number: usize = 1,
    lang: ?[]const u8,

    pub const Tag = enum {
        document,
        paragraph,
        heading,
        bold,
        italic,
        text,
        blockquote,
        inline_code,
        unordered_list,
        list_item,
        ordered_list,
        code_block,
        strikethrough,
        horizontal_rule,
        link,
    };

    pub fn init(allocator: mem.Allocator, tag: Tag) !*AstNode {
        const node = try allocator.create(AstNode);
        node.* = .{
            .tag = tag,
            .children = std.ArrayListUnmanaged(*AstNode){},
            .text = null,
            .lang = null,
        };
        return node;
    }

    pub fn initText(allocator: mem.Allocator, text: []const u8) !*AstNode {
        const node = try allocator.create(AstNode);
        node.* = .{
            .tag = .text,
            .children = null,
            .text = try allocator.dupe(u8, text), // DUPLICATE THE TEXT
            .lang = null,
        };
        return node;
    }

    pub fn deinit(self: *AstNode, allocator: mem.Allocator) void {
        if (self.children) |*children| {
            for (children.items) |child| {
                child.deinit(allocator);
            }
            children.deinit(allocator);
        }
        // --- THIS IS THE CORRECTED LOGIC ---
        // We first check if the tag is .text, and *then* we check if the
        // optional self.text has a value to be freed.
        if (self.tag == .text) {
            if (self.text) |text| {
                allocator.free(text);
            }
        }
        allocator.destroy(self);
    }
};

pub const Delimiter = struct {
    token_index: usize,
    delim_char: u8,
    num_delims: usize,
    can_open: bool,
    can_close: bool,
};

pub const RenderableItem = struct {
    tag: Tag,
    payload: Payload,

    pub const Tag = enum {
        styled_text,
        blockquote,
        code_block,
        horizontal_rule,
        list,
        link,
        blank_line,
    };

    pub const Payload = union {
        styled_text: []const u8,
        blockquote: std.ArrayListUnmanaged(RenderableItem),
        code_block: struct {
            content: []const u8,
            lang: ?[]const u8,
        },
        horizontal_rule: void,
        list: struct {
            is_ordered: bool,
            start_number: usize,
            items: std.ArrayListUnmanaged(std.ArrayListUnmanaged(RenderableItem)),
        },
        link: struct {
            text: []const u8,
            url: []const u8,
        },
        blank_line: void,
    };

    pub fn deinit(self: *RenderableItem, allocator: mem.Allocator) void {
        switch (self.tag) {
            .styled_text => allocator.free(self.payload.styled_text),
            .code_block => {
                allocator.free(self.payload.code_block.content);
                if (self.payload.code_block.lang) |lang| {
                    allocator.free(lang);
                }
            },
            .blockquote => {
                for (self.payload.blockquote.items) |*item| {
                    item.deinit(allocator);
                }
                self.payload.blockquote.deinit(allocator);
            },
            .list => {
                for (self.payload.list.items.items) |*item_blocks| {
                    for (item_blocks.items) |*block| {
                        block.deinit(allocator);
                    }
                    item_blocks.deinit(allocator);
                }
                self.payload.list.items.deinit(allocator);
            },
            .link => {
                allocator.free(self.payload.link.text);
                allocator.free(self.payload.link.url);
            },
            .horizontal_rule => {},
            .blank_line => {},
        }
    }
};

const Classification = struct {
    can_open: bool,
    can_close: bool,
};

fn isPunctuation(char: u8) bool {
    return std.mem.indexOfScalar(u8, "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~", char) != null;
}

fn classifyDelimiter(
    tokens: []const lexer.Token,
    start_index: usize,
    length: usize,
) Classification {
    const end_index = start_index + length - 1;
    const delim_char = tokens[start_index].text[0];

    const char_before: ?u8 = if (start_index > 0 and tokens[start_index - 1].text.len > 0)
        tokens[start_index - 1].text[tokens[start_index - 1].text.len - 1]
    else
        null;

    const char_after: ?u8 = if (end_index < tokens.len - 1 and tokens[end_index + 1].text.len > 0)
        tokens[end_index + 1].text[0]
    else
        null;

    const followed_by_whitespace = (char_after == null) or std.ascii.isWhitespace(char_after.?);
    var can_open = !followed_by_whitespace and
        (char_before == null or std.ascii.isWhitespace(char_before.?) or isPunctuation(char_before.?));

    const preceded_by_whitespace = (char_before == null) or std.ascii.isWhitespace(char_before.?);
    var can_close = !preceded_by_whitespace and
        (char_after == null or std.ascii.isWhitespace(char_after.?) or isPunctuation(char_after.?));

    if (delim_char == '_') {
        const preceded_by_non_whitespace = (char_before != null) and !std.ascii.isWhitespace(char_before.?);
        const followed_by_non_whitespace = (char_after != null) and !std.ascii.isWhitespace(char_after.?);

        if (preceded_by_non_whitespace and followed_by_non_whitespace) {
            if (char_before != null and !isPunctuation(char_before.?)) {
                if (char_after != null and !isPunctuation(char_after.?)) {
                    can_open = false;
                    can_close = false;
                }
            }
        }
    }

    return Classification{
        .can_open = can_open,
        .can_close = can_close,
    };
}

const Parser = struct {
    allocator: mem.Allocator,
    tokens: []lexer.Token,
    pos: usize = 0,

    fn init(allocator: mem.Allocator, tokens: []lexer.Token) Parser {
        return .{ .allocator = allocator, .tokens = tokens };
    }

    fn eof(self: *const Parser) bool {
        return self.pos >= self.tokens.len;
    }

    fn peek(self: *const Parser) ?lexer.Token {
        if (self.eof()) return null;
        return self.tokens[self.pos];
    }

    fn advance(self: *Parser) void {
        if (!self.eof()) self.pos += 1;
    }

    fn consume(self: *Parser, tag: lexer.Token.Tag) bool {
        if (self.peek()) |tok| {
            if (tok.tag == tag) {
                self.advance();
                return true;
            }
        }
        return false;
    }

    fn consumeNewline(self: *Parser) void {
        while (self.peek()) |tok| {
            if (tok.tag == .newline) self.advance() else break;
        }
    }

    fn isBlockStarter(self: *const Parser, token: lexer.Token) bool {
        _ = self;
        return switch (token.tag) {
            .atx_heading, .blockquote, .code_fence, .unordered_list_marker, .ordered_list_marker => true,
            else => false,
        };
    }

    fn parseLink(self: *Parser, parent_list: *std.ArrayListUnmanaged(?*AstNode)) !void {
        var scan_pos = self.pos + 1;
        var found_close_bracket = false;
        while (scan_pos < self.tokens.len) {
            const tok = self.tokens[scan_pos];
            if (tok.tag == .newline) break;
            if (tok.tag == .left_bracket) break;
            if (tok.tag == .right_bracket) {
                found_close_bracket = true;
                scan_pos += 1;
                break;
            }
            scan_pos += 1;
        }

        if (!found_close_bracket or scan_pos >= self.tokens.len) {
            try parent_list.append(self.allocator, try AstNode.initText(self.allocator, self.peek().?.text));
            self.advance();
            return;
        }

        const next_tok = self.tokens[scan_pos];
        const is_link = (next_tok.tag == .text and next_tok.text.len > 1 and next_tok.text[0] == '(' and next_tok.text[next_tok.text.len - 1] == ')');
        if (!is_link) {
            try parent_list.append(self.allocator, try AstNode.initText(self.allocator, self.peek().?.text));
            self.advance();
            return;
        }

        self.advance();

        const link_node = try AstNode.init(self.allocator, .link);
        while (self.peek().?.tag != .right_bracket) {
            try link_node.children.?.append(self.allocator, try AstNode.initText(self.allocator, self.peek().?.text));
            self.advance();
        }

        self.advance();

        const url_tok = self.peek().?;
        const url = url_tok.text[1 .. url_tok.text.len - 1];
        link_node.text = try self.allocator.dupe(u8, url);
        self.advance();

        try parent_list.append(self.allocator, link_node);
    }

    fn parseInline(self: *Parser, parent_list: *std.ArrayListUnmanaged(*AstNode)) !void {
        var delimiters = std.ArrayListUnmanaged(Delimiter){};
        defer delimiters.deinit(self.allocator);

        var nodes = std.ArrayListUnmanaged(?*AstNode){};
        defer {
            for (nodes.items) |node| {
                if (node) |non_null_node| {
                    non_null_node.deinit(self.allocator);
                }
            }
            nodes.deinit(self.allocator);
        }

        while (self.peek()) |token| {
            if (token.tag == .newline) break;
            switch (token.tag) {
                .text => {
                    try nodes.append(self.allocator, try AstNode.initText(self.allocator, token.text));
                    self.advance();
                },
                .backtick => {
                    // Count opening backticks (CommonMark: delimiter length must match)
                    var open_count: usize = 0;
                    while (self.pos < self.tokens.len and self.tokens[self.pos].tag == .backtick) {
                        open_count += 1;
                        self.advance();
                    }

                    var content_buffer = std.ArrayListUnmanaged(u8){};
                    defer content_buffer.deinit(self.allocator);

                    // Collect content until finding matching closing delimiter
                    while (self.peek()) |tok| {
                        if (tok.tag == .newline) break; // Don't cross line boundaries

                        if (tok.tag == .backtick) {
                            // Count consecutive closing backticks
                            var close_count: usize = 0;
                            while (self.pos < self.tokens.len and self.tokens[self.pos].tag == .backtick) {
                                close_count += 1;
                                self.advance();
                            }

                            if (close_count == open_count) {
                                // Found matching closer!
                                break;
                            } else {
                                // Not a match, add these backticks to content
                                for (0..close_count) |_| {
                                    try content_buffer.append(self.allocator, '`');
                                }
                            }
                        } else {
                            // Normal content
                            try content_buffer.appendSlice(self.allocator, tok.text);
                            self.advance();
                        }
                    }

                    const code_node = try AstNode.init(self.allocator, .inline_code);
                    code_node.text = try content_buffer.toOwnedSlice(self.allocator);
                    try nodes.append(self.allocator, code_node);
                },
                .left_bracket => {
                    try self.parseLink(&nodes);
                },
                .asterisk, .underscore, .tilde => {
                    const start_pos = self.pos;
                    var current_pos = self.pos;
                    while (current_pos < self.tokens.len and self.tokens[current_pos].tag == token.tag) {
                        current_pos += 1;
                    }
                    const num_delims = current_pos - start_pos;
                    const classification = classifyDelimiter(self.tokens, start_pos, num_delims);

                    try delimiters.append(self.allocator, .{
                        .token_index = nodes.items.len,
                        .delim_char = token.text[0],
                        .num_delims = num_delims,
                        .can_open = classification.can_open,
                        .can_close = classification.can_close,
                    });
                    self.pos = current_pos;
                },
                else => {
                    try nodes.append(self.allocator, try AstNode.initText(self.allocator, token.text));
                    self.advance();
                },
            }
        }

        try processDelimiters(self.allocator, &nodes, &delimiters);

        for (nodes.items) |node| {
            if (node) |non_null_node| {
                try parent_list.append(self.allocator, non_null_node);
            }
        }

        for (nodes.items) |*node_ptr| {
            node_ptr.* = null;
        }
    }

    fn findMatchingOpener(delimiters: *const std.ArrayListUnmanaged(Delimiter), closer_idx: usize) ?usize {
        const closer = delimiters.items[closer_idx];
        var i: i64 = @as(i64, @intCast(closer_idx)) - 1;
        while (i >= 0) : (i -= 1) {
            const opener = delimiters.items[@intCast(i)];
            if (opener.can_open and opener.delim_char == closer.delim_char) {
                if (!((opener.can_close or closer.can_open) and (opener.num_delims + closer.num_delims) % 3 == 0 and (opener.num_delims % 3 != 0 or closer.num_delims % 3 != 0))) {
                    return @intCast(i);
                }
            }
        }
        return null;
    }

    fn processDelimiters(
        allocator: mem.Allocator,
        nodes: *std.ArrayListUnmanaged(?*AstNode),
        delimiters: *std.ArrayListUnmanaged(Delimiter),
    ) !void {
        var i: i64 = if (delimiters.items.len == 0) -1 else @as(i64, @intCast(delimiters.items.len - 1));
        while (i >= 0) : (i -= 1) {
            const closer_idx = @as(usize, @intCast(i));
            var closer = &delimiters.items[closer_idx];

            if (!closer.can_close) continue;

            if (findMatchingOpener(delimiters, closer_idx)) |opener_idx| {
                var opener = &delimiters.items[opener_idx];

                const num_delims = if (opener.num_delims < closer.num_delims) opener.num_delims else closer.num_delims;

                const tag: AstNode.Tag = if (opener.delim_char == '~')
                    .strikethrough
                else if (num_delims >= 2)
                    .bold
                else
                    .italic;

                const styled_node = try AstNode.init(allocator, tag);
                const start_node_idx = opener.token_index;
                const end_node_idx = closer.token_index;

                if (start_node_idx < end_node_idx) {
                    for (nodes.items[start_node_idx..end_node_idx]) |node| {
                        if (node) |non_null_node| {
                            try styled_node.children.?.append(allocator, non_null_node);
                        }
                    }
                }

                nodes.items[start_node_idx] = styled_node;

                var j = start_node_idx + 1;
                while (j < end_node_idx) : (j += 1) {
                    nodes.items[j] = null;
                }

                opener.num_delims -= num_delims;
                closer.num_delims -= num_delims;
            }
        }

        var final_nodes = std.ArrayListUnmanaged(*AstNode){};
        defer final_nodes.deinit(allocator);

        var node_cursor: usize = 0;
        var delim_cursor: usize = 0;
        while (node_cursor < nodes.items.len or delim_cursor < delimiters.items.len) {
            const next_delim_idx = if (delim_cursor < delimiters.items.len)
                delimiters.items[delim_cursor].token_index
            else
                std.math.maxInt(usize);

            if (node_cursor < next_delim_idx) {
                if (nodes.items[node_cursor]) |node| {
                    try final_nodes.append(allocator, node);
                }
                node_cursor += 1;
            } else if (delim_cursor < delimiters.items.len) {
                const delim = delimiters.items[delim_cursor];
                if (delim.num_delims > 0) {
                    var text_buf = std.ArrayListUnmanaged(u8){};
                    defer text_buf.deinit(allocator);
                    for (0..delim.num_delims) |_| try text_buf.append(allocator, delim.delim_char);
                    try final_nodes.append(allocator, try AstNode.initText(allocator, try text_buf.toOwnedSlice(allocator)));
                }
                delim_cursor += 1;
            } else {
                break;
            }
        }

        nodes.clearRetainingCapacity();
        for (final_nodes.items) |node| {
            try nodes.append(allocator, node);
        }
    }

    fn isHorizontalRule(self: *const Parser) bool {
        var scan_pos = self.pos;
        if (scan_pos >= self.tokens.len) return false;

        const first_tok = self.tokens[scan_pos];
        const rule_char_opt: ?u8 = switch (first_tok.tag) {
            .asterisk => '*',
            .underscore => '_',
            .text => blk: {
                const trimmed = mem.trim(u8, first_tok.text, " ");
                if (trimmed.len == 0) break :blk null;
                const c = trimmed[0];
                if (c != '*' and c != '_' and c != '-') {
                    break :blk null;
                }
                break :blk c;
            },
            else => null,
        };
        const rule_char = rule_char_opt orelse return false;

        var count: usize = 0;
        while (scan_pos < self.tokens.len) {
            const tok = self.tokens[scan_pos];
            if (tok.tag == .newline) break;

            for (tok.text) |c| {
                if (c == rule_char) {
                    count += 1;
                } else if (c != ' ') {
                    return false;
                }
            }
            scan_pos += 1;
        }

        return count >= 3;
    }

    fn parseBlock(self: *Parser, min_indent: usize) anyerror!?*AstNode {
        if (self.eof()) return null;
        const backup_pos = self.pos;
        var indent_width: usize = 0;
        if (self.peek()) |tok| {
            if (tok.tag == .indent) {
                indent_width = tok.indent_width;
                self.advance();
            }
        }
        if (indent_width < min_indent) {
            self.pos = backup_pos;
            return null;
        }

        if (self.isHorizontalRule()) {
            while (!self.eof() and self.peek().?.tag != .newline) {
                self.advance();
            }
            return try AstNode.init(self.allocator, .horizontal_rule);
        }

        self.pos = backup_pos;
        if (self.peek()) |tok| {
            if (tok.tag == .indent) {
                self.advance();
            }
        }
        if (self.eof()) return null;

        return switch (self.peek().?.tag) {
            .atx_heading => self.parseHeading(),
            .blockquote => self.parseBlockquote(indent_width),
            .code_fence => self.parseCodeBlock(),
            .unordered_list_marker, .ordered_list_marker => self.parseList(indent_width),
            else => self.parseParagraph(),
        };
    }

    fn parseHeading(self: *Parser) anyerror!*AstNode {
        const heading = try AstNode.init(self.allocator, .heading);
        self.advance();

        if (!self.eof() and self.peek().?.tag == .text and self.peek().?.text.len > 0 and self.peek().?.text[0] == ' ') {
            self.tokens[self.pos].text = self.tokens[self.pos].text[1..];
        }

        try self.parseInline(&heading.children.?);
        return heading;
    }

    fn parseParagraph(self: *Parser) anyerror!*AstNode {
        const para = try AstNode.init(self.allocator, .paragraph);

        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(self.allocator);

        while (self.peek()) |tok| {
            if (self.isBlockStarter(tok)) break;
            if (tok.tag == .newline) {
                if (self.pos + 1 < self.tokens.len and self.tokens[self.pos + 1].tag == .newline) {
                    self.advance();
                    break;
                }
                try buffer.append(self.allocator, ' ');
                self.advance();
                continue;
            }

            try buffer.appendSlice(self.allocator, tok.text);
            self.advance();
        }

        if (buffer.items.len > 0) {
            var temp_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer temp_arena.deinit();
            const temp_allocator = temp_arena.allocator();

            var paragraph_tokens = try lexer.tokenize(temp_allocator, buffer.items);
            defer paragraph_tokens.deinit(temp_allocator);

            if (paragraph_tokens.items.len > 0) {
                var inline_parser = Parser.init(self.allocator, paragraph_tokens.items);
                try inline_parser.parseInline(&para.children.?);
            }
        }

        return para;
    }

    fn parseCodeBlock(self: *Parser) anyerror!*AstNode {
        const open_fence = self.peek().?.text;
        self.advance();

        const node = try AstNode.init(self.allocator, .code_block);
        if (!self.eof() and self.peek().?.tag == .text) {
            node.lang = self.peek().?.text;
            self.advance();
        }
        _ = self.consume(.newline);

        var content = std.ArrayListUnmanaged(u8){};
        defer content.deinit(self.allocator);
        while (!self.eof()) {
            const tok = self.peek().?;
            if (tok.tag == .code_fence and mem.eql(u8, tok.text, open_fence)) {
                self.advance();
                break;
            }
            try content.appendSlice(self.allocator, tok.text);
            self.advance();
        }
        node.text = try content.toOwnedSlice(self.allocator);
        return node;
    }

    fn parseBlockquote(self: *Parser, _: usize) anyerror!*AstNode {
        const quote = try AstNode.init(self.allocator, .blockquote);
        var buffer = std.ArrayListUnmanaged(u8){};
        defer buffer.deinit(self.allocator);

        while (!self.eof()) {
            const backup_pos = self.pos;

            if (self.peek().?.tag == .blockquote) {
                self.advance();
                if (!self.eof() and self.peek().?.tag == .text and self.peek().?.text.len > 0 and self.peek().?.text[0] == ' ') {
                    self.tokens[self.pos].text = self.tokens[self.pos].text[1..];
                }
            } else {
                if (buffer.items.len > 0) {
                    self.pos = backup_pos;
                    break;
                }
            }

            while (!self.eof()) {
                const tok = self.peek().?;
                if (tok.tag == .newline) {
                    try buffer.append(self.allocator, '\n');
                    self.advance();
                    break;
                }
                try buffer.appendSlice(self.allocator, tok.text);
                self.advance();
            }

            if (self.peek()) |next_tok| {
                if (self.isBlockStarter(next_tok)) break;
            } else {
                break;
            }
        }

        var sub_tokens = try lexer.tokenize(self.allocator, buffer.items);
        defer sub_tokens.deinit(self.allocator);

        if (sub_tokens.items.len > 0) {
            var sub_parser = Parser.init(self.allocator, sub_tokens.items);
            const sub_ast = try sub_parser.parse();
            defer sub_ast.deinit(self.allocator);
            try quote.children.?.appendSlice(self.allocator, sub_ast.children.?.items);
            sub_ast.children = null;
        }
        return quote;
    }

    fn parseList(self: *Parser, indent_width: usize) anyerror!*AstNode {
        const first_marker_tok = self.peek().?;
        const list_type = first_marker_tok.tag;
        const list = try AstNode.init(self.allocator, if (list_type == .unordered_list_marker) .unordered_list else .ordered_list);

        if (list_type == .ordered_list_marker) {
            var j: usize = 0;
            while (j < first_marker_tok.text.len and ascii.isDigit(first_marker_tok.text[j])) {
                j += 1;
            }
            if (j > 0) {
                list.start_number = std.fmt.parseInt(usize, first_marker_tok.text[0..j], 10) catch 1;
            }
        }

        while (true) {
            const item_backup_pos = self.pos;

            var current_indent: usize = 0;
            if (self.peek()) |tok| {
                if (tok.tag == .indent) {
                    current_indent = tok.indent_width;
                    self.advance();
                }
            }

            if (current_indent < indent_width) {
                self.pos = item_backup_pos;
                break;
            }

            if (self.peek() == null or self.peek().?.tag != list_type) {
                if (list.children.?.items.len > 0) {
                    const last_item = list.children.?.items[list.children.?.items.len - 1];
                    self.pos = item_backup_pos;
                    try self.parseListItemContinuation(last_item, indent_width);
                    if (self.pos == item_backup_pos) {
                        break;
                    } else {
                        continue;
                    }
                }
                self.pos = item_backup_pos;
                break;
            }

            try list.children.?.append(self.allocator, try self.parseListItem(indent_width));

            if (self.eof()) break;
        }

        return list;
    }

    fn parseListItem(self: *Parser, list_indent: usize) anyerror!*AstNode {
        const item = try AstNode.init(self.allocator, .list_item);
        const para = try AstNode.init(self.allocator, .paragraph);
        try item.children.?.append(self.allocator, para);

        self.advance();

        if (self.peek()) |tok| {
            if (tok.tag == .text and tok.text.len > 0 and tok.text[0] == ' ') {
                self.tokens[self.pos].text = tok.text[1..];
            }
        }

        try self.parseInline(&para.children.?);
        try self.parseListItemContinuation(item, list_indent);

        return item;
    }

    fn parseListItemContinuation(self: *Parser, item: *AstNode, list_indent: usize) !void {
        const required_indent = list_indent + 1;

        while (true) {
            const continuation_backup_pos = self.pos;
            self.consumeNewline();
            if (self.eof()) break;

            var next_indent: usize = 0;
            if (self.peek().?.tag == .indent) {
                next_indent = self.peek().?.indent_width;
            } else {
                self.pos = continuation_backup_pos;
                break;
            }

            if (next_indent < required_indent) {
                self.pos = continuation_backup_pos;
                break;
            }
            self.advance();

            if (try self.parseBlock(next_indent)) |block| {
                try item.children.?.append(self.allocator, block);
            } else {
                const para = try AstNode.init(self.allocator, .paragraph);
                try self.parseInline(&para.children.?);
                try item.children.?.append(self.allocator, para);
            }
        }
    }

    fn parse(self: *Parser) anyerror!*AstNode {
        const doc = try AstNode.init(self.allocator, .document);
        while (!self.eof()) {
            self.consumeNewline();
            if (self.eof()) break;

            if (try self.parseBlock(0)) |block| {
                try doc.children.?.append(self.allocator, block);
            } else {
                const para = try self.parseParagraph();
                if (para.children.?.items.len > 0) {
                    try doc.children.?.append(self.allocator, para);
                } else {
                    para.deinit(self.allocator);
                }
            }
        }
        return doc;
    }
};

const ANSI_BOLD_START = "\x1b[1m";
const ANSI_ITALIC_START = "\x1b[3m";
const ANSI_UNDERLINE_START = "\x1b[4m";
const ANSI_STRIKETHROUGH_START = "\x1b[9m";
const ANSI_RESET = "\x1b[0m";
const ANSI_BG_GREY_START = "\x1b[48;5;250m";
const ANSI_BG_RESET = "\x1b[49m"; // Reset background only, preserves foreground and other styles

fn renderNodeToStringRecursive(
    node: *AstNode,
    buffer: *std.ArrayListUnmanaged(u8),
    allocator: mem.Allocator,
) error{OutOfMemory}!void {
    switch (node.tag) {
        .document, .paragraph, .list_item => {
            for (node.children.?.items) |child| {
                try renderNodeToStringRecursive(child, buffer, allocator);
            }
        },
        .blockquote => {
            for (node.children.?.items) |child| {
                try renderNodeToStringRecursive(child, buffer, allocator);
            }
        },
        .heading => {
            try buffer.appendSlice(allocator, ANSI_BOLD_START);
            try buffer.appendSlice(allocator, ANSI_UNDERLINE_START);
            for (node.children.?.items) |child| {
                try renderNodeToStringRecursive(child, buffer, allocator);
            }
            try buffer.appendSlice(allocator, ANSI_RESET);
        },
        .bold => {
            try buffer.appendSlice(allocator, ANSI_BOLD_START);
            for (node.children.?.items) |child| {
                try renderNodeToStringRecursive(child, buffer, allocator);
            }
            try buffer.appendSlice(allocator, ANSI_RESET);
        },
        .italic => {
            try buffer.appendSlice(allocator, ANSI_ITALIC_START);
            for (node.children.?.items) |child| {
                try renderNodeToStringRecursive(child, buffer, allocator);
            }
            try buffer.appendSlice(allocator, ANSI_RESET);
        },
        .strikethrough => {
            try buffer.appendSlice(allocator, ANSI_STRIKETHROUGH_START);
            for (node.children.?.items) |child| {
                try renderNodeToStringRecursive(child, buffer, allocator);
            }
            try buffer.appendSlice(allocator, ANSI_RESET);
        },
        .inline_code => {
            try buffer.appendSlice(allocator, ANSI_BG_GREY_START);
            if (node.text) |text| try buffer.appendSlice(allocator, text);
            try buffer.appendSlice(allocator, ANSI_BG_RESET); // Use BG reset instead of full reset to preserve outer styles
        },
        .link => {
            try buffer.appendSlice(allocator, ANSI_UNDERLINE_START);
            for (node.children.?.items) |child| {
                try renderNodeToStringRecursive(child, buffer, allocator);
            }
            try buffer.appendSlice(allocator, ANSI_RESET);
        },
        .text => if (node.text) |text| try buffer.appendSlice(allocator, text),
        .code_block, .horizontal_rule, .unordered_list, .ordered_list => {},
    }
}

fn renderNodeToString(allocator: mem.Allocator, node: *AstNode) ![]const u8 {
    var buffer = std.ArrayListUnmanaged(u8){};
    try renderNodeToStringRecursive(node, &buffer, allocator);
    return buffer.toOwnedSlice(allocator);
}

fn astToRenderableItems(allocator: mem.Allocator, root: *AstNode) !std.ArrayListUnmanaged(RenderableItem) {
    var items = std.ArrayListUnmanaged(RenderableItem){};

    if (root.children) |children| {
        for (children.items) |child| {
            switch (child.tag) {
                .paragraph => {
                    const is_blank_line = if (child.children.?.items.len == 1) blk: {
                        const first_child = child.children.?.items[0];
                        if (first_child.tag == .text and first_child.text.?.len == 0) {
                            break :blk true;
                        }
                        break :blk false;
                    } else false;

                    if (is_blank_line) {
                        try items.append(allocator, .{ .tag = .blank_line, .payload = .{ .blank_line = {} } });
                    } else {
                        const text = try renderNodeToString(allocator, child);
                        if (text.len > 0) {
                            try items.append(allocator, .{ .tag = .styled_text, .payload = .{ .styled_text = text } });
                        } else {
                            allocator.free(text);
                        }
                    }
                },
                .heading => {
                    const text = try renderNodeToString(allocator, child);
                    if (text.len > 0) {
                        try items.append(allocator, .{ .tag = .styled_text, .payload = .{ .styled_text = text } });
                    } else {
                        allocator.free(text);
                    }
                },
                .blockquote => {
                    const sub_items = try astToRenderableItems(allocator, child);
                    try items.append(allocator, .{ .tag = .blockquote, .payload = .{ .blockquote = sub_items } });
                },
                .code_block => {
                    try items.append(allocator, .{
                        .tag = .code_block,
                        .payload = .{ .code_block = .{ .content = child.text.?, .lang = child.lang } },
                    });
                },
                .horizontal_rule => {
                    try items.append(allocator, .{ .tag = .horizontal_rule, .payload = .{ .horizontal_rule = {} } });
                },
                .unordered_list, .ordered_list => {
                    var list_items = std.ArrayListUnmanaged(std.ArrayListUnmanaged(RenderableItem)){};
                    if (child.children) |li_nodes| {
                        for (li_nodes.items) |li_node| {
                            const item_blocks = try astToRenderableItems(allocator, li_node);
                            try list_items.append(allocator, item_blocks);
                        }
                    }
                    try items.append(allocator, .{
                        .tag = .list,
                        .payload = .{ .list = .{
                            .is_ordered = (child.tag == .ordered_list),
                            .start_number = child.start_number,
                            .items = list_items,
                        }},
                    });
                },
                .link => {
                    const text = try renderNodeToString(allocator, child);
                    const url = if (child.text) |url| try allocator.dupe(u8, url) else try allocator.dupe(u8, "");
                    try items.append(allocator, .{
                        .tag = .link,
                        .payload = .{ .link = .{ .text = text, .url = url } },
                    });
                },
                else => {},
            }
        }
    }
    return items;
}

fn cloneRenderableItem(
    gpa: std.mem.Allocator,
    item: *const RenderableItem,
) !RenderableItem {
    return switch (item.tag) {
        .styled_text => .{
            .tag = .styled_text,
            .payload = .{ .styled_text = try gpa.dupe(u8, item.payload.styled_text) },
        },
        .horizontal_rule => .{
            .tag = .horizontal_rule,
            .payload = .{ .horizontal_rule = {} },
        },
        .blank_line => .{
            .tag = .blank_line,
            .payload = .{ .blank_line = {} },
        },
        .code_block => .{
            .tag = .code_block,
            .payload = .{ .code_block = .{
                .content = try gpa.dupe(u8, item.payload.code_block.content),
                .lang = if (item.payload.code_block.lang) |lang| try gpa.dupe(u8, lang) else null,
            }},
        },
        .blockquote => {
            var cloned_sub_items = std.ArrayListUnmanaged(RenderableItem){};
            for (item.payload.blockquote.items) |*sub_item| {
                try cloned_sub_items.append(gpa, try cloneRenderableItem(gpa, sub_item));
            }
            return .{
                .tag = .blockquote,
                .payload = .{ .blockquote = cloned_sub_items },
            };
        },
        .list => {
            var cloned_list_items = std.ArrayListUnmanaged(std.ArrayListUnmanaged(RenderableItem)){};
            for (item.payload.list.items.items) |li_blocks| {
                var cloned_blocks = std.ArrayListUnmanaged(RenderableItem){};
                for (li_blocks.items) |*block| {
                    try cloned_blocks.append(gpa, try cloneRenderableItem(gpa, block));
                }
                try cloned_list_items.append(gpa, cloned_blocks);
            }
            return .{
                .tag = .list,
                .payload = .{ .list = .{
                    .is_ordered = item.payload.list.is_ordered,
                    .start_number = item.payload.list.start_number,
                    .items = cloned_list_items,
                }},
            };
        },
        .link => .{
            .tag = .link,
            .payload = .{ .link = .{
                .text = try gpa.dupe(u8, item.payload.link.text),
                .url = try gpa.dupe(u8, item.payload.link.url),
            }},
        },
    };
}

pub fn processMarkdown(gpa: std.mem.Allocator, markdown_text: []const u8) !std.ArrayListUnmanaged(RenderableItem) {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tokens = try lexer.tokenize(allocator, markdown_text);
    defer tokens.deinit(allocator);

    var p = Parser.init(allocator, tokens.items);
    const ast_root = try p.parse();
    defer ast_root.deinit(allocator);

    var arena_items = try astToRenderableItems(allocator, ast_root);
    defer {
        for (arena_items.items) |*item| {
            item.deinit(allocator);
        }
        arena_items.deinit(allocator);
    }

    var gpa_items = std.ArrayListUnmanaged(RenderableItem){};
    errdefer gpa_items.deinit(gpa);
    for (arena_items.items) |*item| {
        try gpa_items.append(gpa, try cloneRenderableItem(gpa, item));
    }

    return gpa_items;
}
