import os
import re

DOMAINS = ["tmdb", "jf", "yt", "anime", "comic"]

def refactor_file(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    original = content
    for domain in DOMAINS:
        # We find state.app.tmdb_XXX and turn it into state.app.tmdb.XXX
        # Regex: state\.app\.tmdb_([a-zA-Z0-9_]+) -> state.app.tmdb.\1
        pattern = r"state\.app\." + domain + r"_([a-zA-Z0-9_]+)"
        replacement = r"state.app." + domain + r".\1"
        content = re.sub(pattern, replacement, content)
        
        # Also handle active_p.browser_title etc? No, only state.app.
        # But wait, what if someone uses `app.tmdb_`?
        pattern2 = r"\bapp\." + domain + r"_([a-zA-Z0-9_]+)"
        replacement2 = r"app." + domain + r".\1"
        content = re.sub(pattern2, replacement2, content)

    if content != original:
        with open(filepath, 'w') as f:
            f.write(content)
        print(f"Refactored: {filepath}")

for root, _, files in os.walk('src'):
    for file in files:
        if file.endswith('.zig'):
            # Skip state.zig, we will refactor the struct definition separately
            # Otherwise it rewrites `tmdb_view: TmdbView` to `tmdb.view: TmdbView`
            if file == "state.zig":
                continue
            refactor_file(os.path.join(root, file))

print("Refactoring complete.")
