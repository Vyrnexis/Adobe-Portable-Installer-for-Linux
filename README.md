# Adobe Portable Installer for Linux

Simple installer/uninstaller scripts for running Adobe portable apps in a Wine prefix on Linux.

## Arch Linux install notes

Install dependencies:

```bash
sudo pacman -S --needed wine winetricks cabextract p7zip file gawk tar desktop-file-utils
```

Notes:
- `desktop-file-utils` provides `update-desktop-database` (optional but recommended).
- Winetricks will download extra components on first run.

## Usage

1) Place `PhotoshopPortable.tar.gz` and/or `LightroomPortable.tar.gz` in the same folder as `Installer.sh`.
2) Run the installer:

```bash
chmod +x Installer.sh
./Installer.sh
```

Options include installing Photoshop, Lightroom, both, or "prefix only" (deps + optional dark mode). You can also choose a custom prefix path.

Download sources:
- PhotoshopPortable.tar.gz: https://drive.google.com/file/d/1ZaDXQ-4cX0tgQgQTG777esYd_WmitBc1/view?usp=sharing
- LightroomPortable.tar.gz: https://drive.google.com/file/d/1y0rEsa405nQd7MLv0ndiYGAJHkMEUHkV/view?usp=sharing

To uninstall:

```bash
chmod +x Uninstaller.sh
./Uninstaller.sh
```

## Tips

- If you install an app later into the same prefix, dependencies are not reinstalled (a marker file is used).
- Use the same custom prefix path for both install and uninstall if you don't use the default `~/.adobe`.
