const menu_mod = @import("menu.zig");
const extras = @import("app_extras.zig");

pub const Activation = enum { regular, accessory };

pub const Options = struct {
    name: []const u8 = "nanoui",
    /// Quit when the last window closes.
    quit_on_last_window_closed: bool = true,
    /// Given to the hooks below.
    ctx: ?*anyopaque = null,
    /// Links the system asks the app to open (the default browser's).
    on_open_urls: ?*const fn (ctx: ?*anyopaque, urls: []const []const u8) void = null,
    /// The Dock icon was clicked with no non-minimized window on screen; if a
    /// window is minimized in the Dock, nanoui restores it instead of opening
    /// a second window and calls `on_reopen` only when no window remains.
    on_reopen: ?*const fn (ctx: ?*anyopaque) void = null,
    /// The Dock icon's menu, above the system's items.
    dock_menu: ?[]const menu_mod.MenuItem = null,
    /// Asked before any quit takes effect (including the native Quit command).
    /// False leaves the app running; after asynchronous confirmation, call
    /// `quit` again and return true only once it is safe to terminate.
    should_terminate: ?*const fn (ctx: ?*anyopaque) bool = null,
    /// The app is about to quit (⌘Q, its last window, `quit`): save what must be saved.
    on_terminate: ?*const fn (ctx: ?*anyopaque) void = null,
    /// Handoff from another device: the page's address.
    on_continue_activity: ?*const fn (ctx: ?*anyopaque, url: []const u8) void = null,
    /// The app became active (true) or stopped being active.
    on_active: ?*const fn (ctx: ?*anyopaque, active: bool) void = null,
    /// The system changed between light and dark appearance.
    on_appearance_change: ?*const fn (ctx: ?*anyopaque, dark: bool) void = null,
    /// The computer is about to sleep.
    on_sleep: ?*const fn (ctx: ?*anyopaque) void = null,
    /// The computer woke from sleep.
    on_wake: ?*const fn (ctx: ?*anyopaque) void = null,
    /// What the About panel (the menu's `.about` role, `showAbout`) shows.
    about: extras.About = .{},
    /// `.accessory`: a menu bar app (a tray, `LSUIElement`), with no Dock
    /// icon and no menu bar of its own, which can still show windows: it
    /// does not come forward at launch, and a window it shows comes
    /// forward with `Window.focus`. `.regular`: a Dock icon and menus,
    /// whatever the bundle's Info.plist says.
    activation: Activation = .regular,
};
