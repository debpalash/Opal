const fileassoc = @import("../settings_fileassoc.zig");
const settings = @import("../settings.zig");
const sectionHeader = settings.sectionHeader;

pub fn renderFileAssocTab() void {
    sectionHeader("Default File Associations", "Register Opal as the default handler for media, torrents, and comics", 70, @src());
    fileassoc.render();
}
