//! Named id_extra bases — replaces magic `+70000` / `+11000` numbers so the
//! widget-id collision class (see components.divider/sectionHeader) is
//! trackable by name. Spaced by 1_000; never overlap two families.
pub const grid_cell: usize = 11_000;
pub const search_item: usize = 43_000;
pub const chat_bubble: usize = 70_000;
