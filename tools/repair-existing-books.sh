#!/bin/bash
# Copyright (C) 2026 Mitchell Scott
# SPDX-License-Identifier: GPL-3.0-only

set -eu
shopt -s nullglob

xochitl_library=/home/root/.local/share/remarkable/xochitl
library=${LIBRARY:-$xochitl_library}
backup_directory=${BACKUP_DIRECTORY:-/home/root/fix-ligature-text-backup}
dry_run=false
requested_uuids=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run] [UUID...]

Repairs the text of EB Garamond ligatures (ff, fi, fl, ffi, ffl) in ebooks that were
typeset before fix-ligature-text was installed, without typesetting them again.
Only the PDF's text map changes: pages, page count and annotations stay as they are.

With no UUID, every ebook in $library is checked.

  --dry-run   show what would change, write nothing

Stop xochitl before repairing: systemctl stop xochitl
The original PDF of each repaired book is kept in $backup_directory.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run=true ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) requested_uuids+=("$1") ;;
    esac
    shift
done

if ! $dry_run && [ "$library" = "$xochitl_library" ] && pidof xochitl >/dev/null; then
    echo "xochitl is running. Stop it first: systemctl stop xochitl" >&2
    exit 1
fi

rendered_ebook_uuids() {
    local content uuid
    for content in "$library"/*.content; do
        uuid=$(basename "$content" .content)
        grep -q '"fileType": *"epub"' "$content" && [ -f "$library/$uuid.pdf" ] && echo "$uuid"
    done
}

document_name() {
    sed -n 's/.*"visibleName": *"\([^"]*\)".*/\1/p' "$library/$1.metadata" 2>/dev/null | sed -n 1p
}

read_bytes() {
    dd if="$1" iflag=skip_bytes,count_bytes skip="$2" count="$3" 2>/dev/null
}

is_plain_pdf() {
    local pdf=$1 size
    size=$(stat -c %s "$pdf")
    [ "$(read_bytes "$pdf" 0 5)" = "%PDF-" ] || return 1
    read_bytes "$pdf" $((size > 64 ? size - 64 : 0)) 64 | grep -q '^startxref'
}

plan_repair() {
    awk -v cmap_directory="$1" '
    function hex_to_number(hex,    i, value) {
        value = 0
        hex = toupper(hex)
        for (i = 1; i <= length(hex); i++)
            value = value * 16 + index("0123456789ABCDEF", substr(hex, i, 1)) - 1
        return value
    }
    function reference_after(text, key,    fragment) {
        if (!match(text, key " \\[?[0-9]+ 0 R")) return ""
        fragment = substr(text, RSTART + length(key) + 1)
        sub(/^\[/, "", fragment)
        sub(/ .*/, "", fragment)
        return fragment
    }
    function load_widths(cid_font_text, widths,    text, tokens, count, i, first, last, width, depth) {
        text = cid_font_text
        if (!match(text, /\/W \[/)) return
        text = substr(text, RSTART + 4)
        gsub(/\[/, " [ ", text)
        gsub(/\]/, " ] ", text)
        count = split(text, tokens, /[ \n\r\t]+/)
        i = 1
        while (i <= count) {
            if (tokens[i] == "") { i++; continue }
            if (tokens[i] == "]") break
            first = tokens[i] + 0
            i++
            while (tokens[i] == "") i++
            if (tokens[i] == "[") {
                i++
                while (i <= count && tokens[i] != "]") {
                    if (tokens[i] != "") widths[first++] = tokens[i] + 0
                    i++
                }
                i++
            } else {
                last = tokens[i] + 0
                i++
                while (tokens[i] == "") i++
                width = tokens[i] + 0
                i++
                for (; first <= last; first++) widths[first] = width
            }
        }
    }
    function load_mapped_cids(cmap_text, mapped, codepoint_of,    lines, count, i, in_range, in_char, fields, field_count, first, last, k) {
        count = split(cmap_text, lines, "\n")
        for (i = 1; i <= count; i++) {
            if (lines[i] ~ /beginbfrange$/) { in_range = 1; continue }
            if (lines[i] ~ /^endbfrange/) { in_range = 0; continue }
            if (lines[i] ~ /beginbfchar$/) { in_char = 1; continue }
            if (lines[i] ~ /^endbfchar/) { in_char = 0; continue }
            field_count = split(lines[i], fields, /[]<>[ ]+/)
            if (in_range && lines[i] ~ /^<[0-9A-Fa-f]+> <[0-9A-Fa-f]+>/) {
                first = hex_to_number(fields[2]); last = hex_to_number(fields[3])
                for (k = 0; first + k <= last; k++) {
                    mapped[first + k] = 1
                    if (lines[i] ~ /\[/) {
                        if (length(fields[4 + k]) == 4) codepoint_of[first + k] = hex_to_number(fields[4 + k])
                    } else if (length(fields[4]) == 4) {
                        codepoint_of[first + k] = hex_to_number(fields[4]) + k
                    }
                }
            } else if (in_char && lines[i] ~ /^<[0-9A-Fa-f]+>/) {
                mapped[hex_to_number(fields[2])] = 1
                if (length(fields[3]) == 4) codepoint_of[hex_to_number(fields[2])] = hex_to_number(fields[3])
            }
        }
    }
    function ebgaramond_weight(widths, codepoint_of,    cid, letter, checked, matches_regular, matches_bold, difference) {
        for (cid in codepoint_of) {
            letter = codepoint_of[cid]
            if (!(letter in regular_letter_width) || !(cid in widths)) continue
            checked++
            difference = widths[cid] - regular_letter_width[letter]
            if (difference >= -1 && difference <= 1) matches_regular++
            difference = widths[cid] - bold_letter_width[letter]
            if (difference >= -1 && difference <= 1) matches_bold++
        }
        if (checked < 4) return 0
        if (matches_regular == checked) return 400
        if (matches_bold == checked) return 700
        return 0
    }
    BEGIN {
        ligature_count = split("ff fi fl ffi ffl", ligature_names, " ")
        split("575 518 506 776 761", regular_widths, " ")
        split("664 591 602 895 905", bold_widths, " ")
        split("00660066 00660069 0066006C 006600660069 00660066006C", ligature_utf16, " ")
        letter_count = split("97 101 104 110 111 114 115 116", letters, " ")
        split("399 390 515 528 495 334 323 314", regular_widths_by_letter, " ")
        split("438 417 559 566 503 414 360 375", bold_widths_by_letter, " ")
        for (i = 1; i <= letter_count; i++) {
            regular_letter_width[letters[i]] = regular_widths_by_letter[i]
            bold_letter_width[letters[i]] = bold_widths_by_letter[i]
        }
    }
    NR == FNR {
        if ($0 ~ /^[0-9]+ 0 obj$/) { current = $1; buffer = ""; buffered_lines = 0; in_object = 1; next }
        if ($0 == "trailer") { in_trailer = 1; trailer_text = ""; next }
        if (in_trailer) {
            if ($0 == "startxref") { in_trailer = 0; expect_startxref = 1; next }
            trailer_text = trailer_text " " $0
            next
        }
        if (expect_startxref) { last_startxref = $0 + 0; expect_startxref = 0; next }
        if (!in_object) next
        if ($0 == "endobj") {
            in_object = 0
            if (buffer ~ /\/Subtype \/Type0/) {
                face = "(unnamed)"
                if (match(buffer, /\/BaseFont \/[^ \n\/]+/)) face = substr(buffer, RSTART + 11, RLENGTH - 11)
                cid_font = reference_after(buffer, "/DescendantFonts")
                to_unicode = reference_after(buffer, "/ToUnicode")
                if (cid_font != "" && to_unicode != "") {
                    font_face[current] = face; font_cid[current] = cid_font; font_to_unicode[current] = to_unicode
                    wanted[cid_font] = 1; wanted[to_unicode] = 1
                }
            }
            next
        }
        if (buffered_lines < 400) { buffer = buffer $0 "\n"; buffered_lines++ }
        next
    }
    {
        if ($0 ~ /^[0-9]+ 0 obj$/) {
            collecting = ($1 in wanted) ? $1 : ""
            if (collecting != "") { collected[collecting] = ""; in_stream[collecting] = 0 }
            next
        }
        if (collecting == "") next
        if ($0 == "endobj") { collecting = ""; next }
        if ($0 == "stream") { in_stream[collecting] = 1; stream_text[collecting] = ""; next }
        if ($0 == "endstream") { in_stream[collecting] = 0; next }
        if (in_stream[collecting]) stream_text[collecting] = stream_text[collecting] $0 "\n"
        else collected[collecting] = collected[collecting] $0 "\n"
    }
    END {
        gsub(/\/Prev [0-9]+/, "", trailer_text)
        sub(/^ *<< */, "", trailer_text)
        sub(/ *>> *$/, "", trailer_text)
        gsub(/  +/, " ", trailer_text)
        print "TRAILER " trailer_text
        print "STARTXREF " last_startxref
        for (font in font_face) {
            face = font_face[font]; to_unicode = font_to_unicode[font]
            if (!(to_unicode in stream_text)) continue
            split("", widths); split("", mapped); split("", codepoint_of)
            load_widths(collected[font_cid[font]], widths)
            load_mapped_cids(stream_text[to_unicode], mapped, codepoint_of)
            weight = ebgaramond_weight(widths, codepoint_of)
            if (!weight) continue
            additions = ""; addition_count = 0; summary = ""
            for (cid in widths) {
                if (cid + 0 == 0 || (cid in mapped)) continue
                match_index = 0
                for (i = 1; i <= ligature_count; i++) {
                    reference = (weight == 700) ? bold_widths[i] : regular_widths[i]
                    difference = widths[cid] - reference
                    if (difference >= -1 && difference <= 1) {
                        if (match_index) { match_index = -1; break }
                        match_index = i
                    }
                }
                if (match_index <= 0) continue
                additions = additions sprintf("<%04X> <%s>\n", cid, ligature_utf16[match_index])
                addition_count++
                summary = summary " " sprintf("%d=%s", cid, ligature_names[match_index])
            }
            if (!addition_count) continue
            cmap = stream_text[to_unicode]
            sub(/\n$/, "", cmap)
            if (!sub(/\nendcmap/, "\n" addition_count " beginbfchar\n" additions "endbfchar\nendcmap", cmap)) continue
            printf "%s", cmap > (cmap_directory "/" to_unicode ".cmap")
            close(cmap_directory "/" to_unicode ".cmap")
            print "REPAIR " to_unicode " " face " (EB Garamond " weight ")" summary
        }
    }' "$2" "$2"
}

append_incremental_update() {
    local pdf=$1 cmap_directory=$2 startxref=$3 trailer_entries=$4
    shift 4
    local object offsets=() objects=() xref_offset length
    for object in "$@"; do
        objects+=("$object")
        offsets+=("$(stat -c %s "$pdf")")
        length=$(wc -c < "$cmap_directory/$object.cmap")
        printf '%d 0 obj\n<< /Length %d >>\nstream\n' "$object" "$length" >> "$pdf"
        cat "$cmap_directory/$object.cmap" >> "$pdf"
        printf '\nendstream\nendobj\n' >> "$pdf"
    done
    xref_offset=$(stat -c %s "$pdf")
    {
        printf 'xref\n'
        local i
        for i in "${!objects[@]}"; do
            printf '%d 1\n%010d 00000 n \n' "${objects[$i]}" "${offsets[$i]}"
        done
        printf 'trailer\n<< %s /Prev %d >>\nstartxref\n%d\n%%%%EOF\n' "$trailer_entries" "$startxref" "$xref_offset"
    } >> "$pdf"
}

repair_book() {
    local uuid=$1 pdf="$library/$1.pdf" name work startxref trailer_entries repaired_objects=()
    name=$(document_name "$uuid")
    if ! is_plain_pdf "$pdf"; then
        echo "skip     $uuid  $name  (not a plain Qt PDF)"
        return
    fi
    mkdir -p "$backup_directory"
    work=$(mktemp -d "$backup_directory/work.XXXXXX")
    tr '\000' '\n' < "$pdf" > "$work/text"
    plan_repair "$work" "$work/text" > "$work/plan"
    mapfile -t repaired_objects < <(sed -n 's/^REPAIR \([0-9]*\) .*/\1/p' "$work/plan" | sort -n)
    if [ ${#repaired_objects[@]} -eq 0 ]; then
        echo "ok       $uuid  $name"
        rm -r "$work"
        return
    fi
    sed -n 's/^REPAIR [0-9]* /repair   '"$uuid"'  '"$name"'  /p' "$work/plan"
    if $dry_run; then
        rm -r "$work"
        return
    fi
    startxref=$(sed -n 's/^STARTXREF //p' "$work/plan")
    trailer_entries=$(sed -n 's/^TRAILER //p' "$work/plan")
    cp "$pdf" "$work/repaired.pdf"
    append_incremental_update "$work/repaired.pdf" "$work" "$startxref" "$trailer_entries" "${repaired_objects[@]}"
    [ -f "$backup_directory/$uuid.pdf" ] || cp "$pdf" "$backup_directory/$uuid.pdf"
    mv "$work/repaired.pdf" "$pdf"
    rm -r "$work"
}

if [ ${#requested_uuids[@]} -eq 0 ]; then
    mapfile -t requested_uuids < <(rendered_ebook_uuids)
fi

for uuid in "${requested_uuids[@]}"; do
    repair_book "$uuid"
done
