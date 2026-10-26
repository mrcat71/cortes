"""A one-drag installation layout, matching Cuadro's release disk image."""
from pathlib import Path

application = defines["app"]  # Provided by dmgbuild's -D option.
app_name = Path(application).name

format = "ULFO"
files = [application]
symlinks = {"Applications": "/Applications"}
background = "builtin-arrow"
window_rect = ((200, 200), (640, 280))
default_view = "icon-view"
icon_size = 128
text_size = 13
icon_locations = {app_name: (140, 120), "Applications": (500, 120)}
# Hiding the extension adds FinderInfo to the already-signed app and breaks strict verification.
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
