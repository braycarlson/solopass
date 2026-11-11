set shell := ["sh", "-c"]
set windows-shell := ["powershell.exe", "-c"]

bin := home_directory() / ".local/bin"
data := env("XDG_DATA_HOME", home_directory() / ".local/share")
executable := justfile_directory() / "zig-out/bin/solopass"
release := justfile_directory() / "zig-out/release"

[doc('Redraw the brand asset pack, the application icon, and the tray pixmaps')]
brand:
    python3 -I tools/brand.py

[doc('Compile every artifact without running it')]
check:
    zig build check

[doc('Compile every artifact for Linux from any host')]
check-linux:
    zig build check -Dtarget=x86_64-linux-gnu

[doc('Run the continuous integration pipeline')]
ci:
    zig build ci
    zig build test:unit -Doptimize=safe

[doc('Format build.zig and every source file')]
fmt:
    zig fmt build.zig src

[doc('Rebuild the Geist fonts with the kern table stb_truetype reads')]
fonts:
    uv run --no-project --with fonttools==4.68.0 --with uharfbuzz==0.57.0 python3 -I tools/fonts.py

[doc('Build a release and install the program, its desktop entry, icons, licenses, and polkit rule')]
install:
    zig build --release=safe --prefix '{{ release }}'
    install -D -m 755 '{{ release }}/bin/solopass' '{{ bin }}/solopass.new'
    mv -f '{{ bin }}/solopass.new' '{{ bin }}/solopass'
    mkdir -p '{{ data }}'
    cp -R \
        '{{ release }}/share/applications' \
        '{{ release }}/share/icons' \
        '{{ release }}/share/licenses' \
        '{{ data }}/'
    sudo install -D -m 644 \
        '{{ release }}/share/polkit-1/rules.d/50-solopass.rules' \
        /etc/polkit-1/rules.d/50-solopass.rules

[doc('Lint build.zig, every source file, and the tools with tigerstyle-lsp')]
lint:
    tigerstyle-lsp check build.zig src tools --format concise

[default]
[doc('List every recipe')]
list:
    @just --list

[doc('Register this build with the desktop, which shows the icon only for a desktop entry')]
register:
    zig build
    mkdir -p '{{ data }}/applications'
    cp -R zig-out/share/icons '{{ data }}/'
    sed 's|^Exec=.*|Exec="{{ executable }}"|' contrib/solopass.desktop \
        >'{{ data }}/applications/solopass.desktop'

[doc('Build, register, and run the application')]
run: register
    zig build run

[doc('Render the window states to PNG images in zig-out/snapshots')]
snapshot:
    zig build snapshot

[doc('Run every test suite and the format check')]
test:
    zig build test

[doc('Run the unit tests and the tidy check: just unit [filter]')]
unit filter="":
    zig build test:unit {{ if filter == "" { "" } else { "-Dtest-filter=" + filter } }}
