# fix-ligature-text

[![rm1](https://img.shields.io/badge/rM1-supported-green)](https://remarkable.com/store/remarkable)
[![rm2](https://img.shields.io/badge/rM2-supported-green)](https://remarkable.com/store/remarkable-2)
[![rmpp](https://img.shields.io/badge/rMPP-supported-green)](https://remarkable.com/products/remarkable-paper/pro)
[![rmppmove](https://img.shields.io/badge/rMPPMove-supported-green)](https://remarkable.com/products/remarkable-paper/pro-move)
[![rmppure](https://img.shields.io/badge/rMPPure-supported-green)](https://remarkable.com/products/remarkable-paper/pure)


A xovi extension that fixes the text behind ligatures in the PDFs a reMarkable writes. Without it, selecting, copying, searching or exporting text drops or garbles letters: `floor` becomes `oor` or `Soor`, `find` becomes `nd`, `office` becomes `oce`. The page looks right, but its hidden text layer is wrong.

A font draws `ff`, `fi`, `fl`, `ffi` and `ffl` as single ligature glyphs. Qt builds a PDF's text map by looking each glyph up in the font's character map, and a ligature glyph is usually not in it, so Qt writes no text for it. Readers then drop the glyph or print its internal number as a letter. EB Garamond, the default ebook font, and the reMarkable Serif font used for typed text both do this.

This extension records the text each glyph was shaped from while the PDF is drawn, and writes a corrected text map for each font. Ligatures then extract as plain letters. The pages themselves are drawn exactly as before.

## Dependencies

- [xovi](https://github.com/asivery/rm-xovi-extensions) - Extension framework

## Installation

### Vellum

```
vellum add fix-ligature-text
```

### Manual

1. Ensure xovi is installed
2. Download the build for your device from the [latest release](https://github.com/rmitchellscott/rm-fix-ligature-text/releases/latest): `fix-ligature-text-aarch64.so` for the Paper Pro, Paper Pro Move and Paper Pure, or `fix-ligature-text-armv7.so` for the reMarkable 1 and 2
3. Place it in `/home/root/xovi/extensions.d/` on your reMarkable, renamed to `fix-ligature-text.so`
4. Restart xovi

## Usage

Notebook exports are fixed from the next export on.

Ebooks are fixed when they are typeset while the extension is loaded. A book that was already on the tablet keeps its broken text until it is typeset again by adjusting any view settings.

Typesetting a book again repaginates it. Handwritten annotations stay on the page number they were written on, so in a book you have annotated they may no longer line up with the text.

## Repairing books already on the tablet

The extension fixes books as they are typeset. `tools/repair-existing-books.sh` fixes the text of EB Garamond ligatures in books that were typeset before it was installed, without typesetting them again, so pages and handwritten annotations stay where they are. It runs on the tablet:

```
scp tools/repair-existing-books.sh root@10.11.99.1:
ssh root@10.11.99.1
systemctl stop xochitl
bash repair-existing-books.sh --dry-run
bash repair-existing-books.sh
systemctl start xochitl
```

With no arguments it checks every ebook; pass document UUIDs to limit it. It recognizes EB Garamond, the default ebook font, by its letter widths and repairs only that font. The original PDF is kept in `/home/root/fix-ligature-text-backup/`, and the repaired PDF syncs to your other devices.

## License

Copyright (C) 2026 Mitchell Scott

Licensed under the GNU General Public License v3.0.
