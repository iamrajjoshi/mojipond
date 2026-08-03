from pathlib import Path


application = Path(defines["application"]).resolve()
background_path = Path(defines["background"]).resolve()

if not application.is_dir() or application.suffix != ".app":
    raise ValueError(f"Invalid application bundle: {application}")
if not background_path.is_file():
    raise ValueError(f"Missing DMG background: {background_path}")

format = "UDZO"
filesystem = "HFS+"
size = None

files = [str(application)]
symlinks = {"Applications": "/Applications"}

icon = str(application / "Contents" / "Resources" / "AppIcon.icns")
background = str(background_path)

window_rect = ((120, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 14
icon_size = 128
show_icon_preview = False
include_icon_view_settings = "auto"
include_list_view_settings = "auto"

hide_extensions = ["MojiPond.app"]
icon_locations = {
    "MojiPond.app": (170, 225),
    "Applications": (490, 225),
}
