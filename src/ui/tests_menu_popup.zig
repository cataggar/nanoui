//! Headless `ui.Tester` suites for `ui.popupMenu` and `ui.dropdownMenu`:
//! trigger toggling, immediate-mode items/labels/separators, disabled items,
//! consumptive outside clicks, `checkboxItem` (`close_on_select`), and
//! keyboard navigation (`Down`, `Up`, `Home`, `End`, `Enter`, `Space`, `Escape`)
//! under stationary pointer hover (`keyboard_modality`).
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");

fn clickLabel(t: *ui.Tester, s: []const u8) !void {
    if (t.findText(s)) |r| {
        t.click(r.x + r.w / 2, r.y + r.h / 2);
        return;
    }
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.indexOf(u8, tx.str, s) != null) {
            t.click(n.rect.x + n.rect.w / 2, n.rect.y + n.rect.h / 2);
            return;
        },
        else => {},
    };
    return error.TextNotFound;
}

fn isItemHighlighted(t: *ui.Tester, label: []const u8) bool {
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, label)) {
            var cur = n.parent;
            while (cur != @import("context.zig").none) {
                const p = t.ctx.nodes.items[cur];
                if (p.interactive) {
                    if (p.style.background) |bg| return bg.a > 0.02;
                    return false;
                }
                cur = p.parent;
            }
        },
        else => {},
    };
    return false;
}

test "dropdownMenu trigger, immediate-mode items, disabled guard, and outside click consumption" {
    const Scene = struct {
        renamed: u32 = 0,
        duplicated: u32 = 0,
        archived: u32 = 0,
        deleted: u32 = 0,
        pinned: bool = false,
        workspace_clicks: u32 = 0,

        fn view(s: *@This(), c: *ui.Context) void {
            const root = ui.div(c).column().sizeFull().p(16).gap(12);
            defer root.end();

            if (ui.dropdownMenu(c, "more", "More", .{})) |m| {
                defer m.end();
                m.label("Actions");
                if (m.item("Rename", .{ .icon = "pencil" })) s.renamed += 1;
                if (m.item("Duplicate", .{})) s.duplicated += 1;
                m.separator();
                if (m.item("Archive", .{ .disabled = true })) s.archived += 1;
                _ = m.checkboxItem("Pin", &s.pinned, .{});
                if (m.item("Delete", .{ .danger = true, .shortcut = "⌫" })) s.deleted += 1;
            }

            const ws = ui.div(c).wFull().grow().center().bg(c.theme.surface).control();
            if (ws.clicked()) s.workspace_clicks += 1;
            ui.text(c, "Workspace", .{});
            ws.end();
        }
    };

    var s: Scene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .width = 480, .height = 360, .scale = 1 });
    defer t.deinit();
    t.settle(0.5);

    try testing.expect(!t.hasText("Rename"));

    // Click "More" -> menu opens with all items, heading, and shortcut.
    try clickLabel(&t, "More");
    t.settle(1);
    try testing.expect(t.hasText("Actions"));
    try testing.expect(t.hasText("Rename"));
    try testing.expect(t.hasText("Duplicate"));
    try testing.expect(t.hasText("Archive"));
    try testing.expect(t.hasText("Pin"));
    try testing.expect(t.hasText("Delete"));
    try testing.expect(t.hasText("⌫"));

    // Clicking disabled "Archive" does NOT fire and keeps the menu open.
    try t.clickText("Archive");
    t.settle(0.5);
    try testing.expectEqual(@as(u32, 0), s.archived);
    try testing.expect(t.hasText("Rename"));

    // Clicking "Rename" fires once and auto-closes the menu.
    try t.clickText("Rename");
    t.settle(1);
    try testing.expectEqual(@as(u32, 1), s.renamed);
    try testing.expect(!t.hasText("Rename"));

    // Clicking "More" while open closes cleanly without reopening on release.
    try clickLabel(&t, "More");
    t.settle(1);
    try testing.expect(t.hasText("Rename"));
    try clickLabel(&t, "More");
    t.settle(1);
    try testing.expect(!t.hasText("Rename"));

    // Clicking outside over "Workspace" dismisses the menu WITHOUT clicking "Workspace".
    try clickLabel(&t, "More");
    t.settle(1);
    try testing.expect(t.hasText("Rename"));
    t.click(420, 320);
    t.settle(1);
    try testing.expect(!t.hasText("Rename"));
    try testing.expectEqual(@as(u32, 0), s.workspace_clicks);

    // Once closed, the same outside point reaches "Workspace".
    t.click(420, 320);
    try testing.expectEqual(@as(u32, 1), s.workspace_clicks);
}

test "checkboxItem with close_on_select false vs true" {
    const CheckScene = struct {
        open: bool = true,
        grid: bool = false,
        snap: bool = false,
        grid_toggles: u32 = 0,
        snap_toggles: u32 = 0,

        fn view(s: *@This(), c: *ui.Context) void {
            const root = ui.div(c).column().sizeFull();
            defer root.end();
            if (ui.popupMenu(c, "view-menu", &s.open, .fromPoint(.{ .x = 24, .y = 24 }), .{})) |m| {
                defer m.end();
                if (m.checkboxItem("Show Grid", &s.grid, .{ .close_on_select = false })) s.grid_toggles += 1;
                if (m.checkboxItem("Snap Guides", &s.snap, .{})) s.snap_toggles += 1;
            }
        }
    };

    var s: CheckScene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, CheckScene.view), .{ .width = 360, .height = 260, .scale = 1 });
    defer t.deinit();
    t.settle(1);

    // close_on_select = false: toggles false -> true -> false while staying open.
    try t.clickText("Show Grid");
    t.settle(0.3);
    try testing.expect(s.grid);
    try testing.expect(s.open);
    try testing.expectEqual(@as(u32, 1), s.grid_toggles);

    try t.clickText("Show Grid");
    t.settle(0.3);
    try testing.expect(!s.grid);
    try testing.expect(s.open);
    try testing.expectEqual(@as(u32, 2), s.grid_toggles);

    // Default close_on_select = true: toggles *bool and closes the menu.
    try t.clickText("Snap Guides");
    t.settle(1);
    try testing.expect(s.snap);
    try testing.expect(!s.open);
    try testing.expectEqual(@as(u32, 1), s.snap_toggles);
    try testing.expect(!t.hasText("Snap Guides"));
}

test "popupMenu keyboard navigation skips separator and disabled items and honors keyboard_modality" {
    const Pick = enum { none, cut, paste, select_all };
    const KeyScene = struct {
        open: bool = true,
        picked: Pick = .none,
        picks: u32 = 0,

        fn view(s: *@This(), c: *ui.Context) void {
            const root = ui.div(c).column().sizeFull();
            defer root.end();
            if (ui.popupMenu(c, "edit-menu", &s.open, .fromPoint(.{ .x = 24, .y = 24 }), .{})) |m| {
                defer m.end();
                if (m.item("Cut", .{})) {
                    s.picked = .cut;
                    s.picks += 1;
                }
                m.separator();
                if (m.item("Paste", .{ .disabled = true })) {
                    s.picked = .paste;
                    s.picks += 1;
                }
                if (m.item("Select All", .{})) {
                    s.picked = .select_all;
                    s.picks += 1;
                }
            }
        }
    };

    var s: KeyScene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, KeyScene.view), .{ .width = 360, .height = 280, .scale = 1 });
    defer t.deinit();
    t.settle(0.5);

    // 1st Down highlights "Cut" (0).
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    t.settle(0.25);
    try testing.expect(isItemHighlighted(&t, "Cut"));
    try testing.expect(!isItemHighlighted(&t, "Select All"));

    // Place stationary mouse over "Cut", then press Down (Key.down):
    // skips separator & disabled "Paste" to highlight "Select All" without
    // stationary mouse over "Cut" stealing the highlight back!
    const cut_r = t.findText("Cut").?;
    t.moveTo(cut_r.x + 8, cut_r.y + cut_r.h / 2);
    t.key(.down);
    t.settle(0.25);
    try testing.expect(isItemHighlighted(&t, "Select All"));
    try testing.expect(!isItemHighlighted(&t, "Cut"));

    // Down again wraps around to "Cut"; Up wraps back to "Select All".
    _ = t.shortcut(.{ .key = ui.Shortcut.down });
    t.settle(0.25);
    try testing.expect(isItemHighlighted(&t, "Cut"));

    t.key(.up);
    t.settle(0.25);
    try testing.expect(isItemHighlighted(&t, "Select All"));

    // Home jumps to first enabled ("Cut"); End jumps to last enabled ("Select All").
    _ = t.shortcut(.{ .key = ui.Shortcut.home });
    t.settle(0.25);
    try testing.expect(isItemHighlighted(&t, "Cut"));

    t.key(.end);
    t.settle(0.25);
    try testing.expect(isItemHighlighted(&t, "Select All"));

    // Enter activates "Select All" and closes the menu.
    _ = t.shortcut(.{ .key = ui.Shortcut.enter });
    t.settle(1);
    try testing.expectEqual(Pick.select_all, s.picked);
    try testing.expectEqual(@as(u32, 1), s.picks);
    try testing.expect(!s.open);

    // Reopen, navigate with Home, and activate with Space.
    s.open = true;
    t.settle(0.5);
    t.key(.home);
    _ = t.shortcut(.{ .key = ' ' });
    t.settle(1);
    try testing.expectEqual(Pick.cut, s.picked);
    try testing.expectEqual(@as(u32, 2), s.picks);
    try testing.expect(!s.open);

    // Reopen, highlight an item, and press Escape: closes without firing.
    s.open = true;
    t.settle(0.5);
    t.key(.down);
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    t.settle(1);
    try testing.expect(!s.open);
    try testing.expectEqual(@as(u32, 2), s.picks);
}

test "popupMenu keyboard navigation and Enter activation scale past 64 items" {
    const LargeMenuScene = struct {
        open: bool = true,
        activated: ?usize = null,
        activations: u32 = 0,

        fn view(s: *@This(), c: *ui.Context) void {
            const root = ui.div(c).column().sizeFull();
            defer root.end();
            if (ui.popupMenu(c, "large-menu", &s.open, .fromPoint(.{ .x = 24, .y = 24 }), .{})) |m| {
                defer m.end();
                for (0..75) |i| {
                    if (m.item(c.print("Item {d}", .{i}), .{ .disabled = (i == 70) })) {
                        s.activated = i;
                        s.activations += 1;
                    }
                }
            }
        }
    };

    var s: LargeMenuScene = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, LargeMenuScene.view), .{ .width = 360, .height = 280, .scale = 1 });
    defer t.deinit();
    t.settle(0.5);

    // End jumps straight to index 74 (> 63).
    t.key(.end);
    t.settle(0.2);
    try testing.expect(isItemHighlighted(&t, "Item 74"));

    // Step Up to 71 (74 -> 73 -> 72 -> 71), then Up skips disabled index 70 -> 69.
    t.key(.up);
    t.key(.up);
    t.key(.up);
    t.settle(0.2);
    try testing.expect(isItemHighlighted(&t, "Item 71"));

    t.key(.up);
    t.settle(0.2);
    try testing.expect(isItemHighlighted(&t, "Item 69"));
    try testing.expect(!isItemHighlighted(&t, "Item 70"));

    // End back to index 74 and press Enter: activates index 74 and closes.
    t.key(.end);
    t.key(.enter);
    t.settle(1);
    try testing.expectEqual(@as(?usize, 74), s.activated);
    try testing.expectEqual(@as(u32, 1), s.activations);
    try testing.expect(!s.open);
    try testing.expectEqual(@as(u32, 0), t.ctx.overlay.prev_menus.count());
    try testing.expectEqual(@as(u32, 0), t.ctx.overlay.next_menus.count());
}
