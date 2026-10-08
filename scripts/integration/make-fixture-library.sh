#!/bin/bash
# Generates the fixture Library for the integration harness into an empty directory: short silent MP3s plus a
# metadata.json per Book (the scanner's highest-precedence metadata source).
#
#   Ada Fixture/The First Light   Fixture Saga #1     1 file  (120 s), 3 Chapters, the only Book with a cover
#   Ada Fixture/Between Lights    Fixture Saga #1.5   3 files (3 x 60 s), 4 Chapters spanning the files
#   Ada Fixture/Second Dawn       Fixture Saga #2     1 file  (120 s), 2 Chapters
#   Ada Fixture/The Long Dark     Fixture Saga        1 file  (90 s), 2 Chapters, no sequence number
#   Ben Example/Plain Silence     no Series           1 file  (120 s), no Chapters
#   Ben Example/Loose Parts       no Series           2 files (2 x 60 s), no metadata Chapters, so the Server
#                                                     makes one Chapter per file
#
# Books are at least a minute long so positions mid-Book stay clear of the 10 s auto-finish threshold.
#
# Usage: scripts/integration/make-fixture-library.sh <empty dir> <audiobookshelf image>
# The image's own ffmpeg makes the audio, so nothing else needs installing.
set -euo pipefail

out="$1"
image="$2"

silence="$out/.silence"
mkdir -p "$silence"
docker run --rm --entrypoint sh -v "$silence:/out" "$image" -c '
    for seconds in 60 90 120; do
        ffmpeg -loglevel error -f lavfi -i anullsrc=r=22050:cl=mono -t "$seconds" \
            -c:a libmp3lame -b:a 32k "/out/$seconds.mp3"
    done
    ffmpeg -loglevel error -f lavfi -i color=c=steelblue:s=600x600 -frames:v 1 /out/cover.jpg'

# book <author> <title> <metadata.json> <seconds per file>...
book() {
    local dir="$out/$1/$2" metadata="$3"
    shift 3
    mkdir -p "$dir"
    printf '%s\n' "$metadata" >"$dir/metadata.json"
    local index=1
    for seconds in "$@"; do
        cp "$silence/$seconds.mp3" "$dir/$(printf '%02d' "$index").mp3"
        index=$((index + 1))
    done
}

book "Ada Fixture" "The First Light" '{
  "title": "The First Light",
  "authors": ["Ada Fixture"],
  "narrators": ["Nell Narrator"],
  "series": ["Fixture Saga #1"],
  "publishedYear": "2001",
  "description": "First Book of the Fixture Saga.",
  "genres": ["Fixture"],
  "chapters": [
    {"start": 0, "end": 40, "title": "Dawn"},
    {"start": 40, "end": 80, "title": "Noon"},
    {"start": 80, "end": 120, "title": "Dusk"}
  ]
}' 120
cp "$silence/cover.jpg" "$out/Ada Fixture/The First Light/cover.jpg"

book "Ada Fixture" "Between Lights" '{
  "title": "Between Lights",
  "authors": ["Ada Fixture"],
  "narrators": ["Nell Narrator"],
  "series": ["Fixture Saga #1.5"],
  "publishedYear": "2002",
  "description": "A novella between the first and second Books, in three files.",
  "chapters": [
    {"start": 0, "end": 45, "title": "One"},
    {"start": 45, "end": 90, "title": "Two"},
    {"start": 90, "end": 135, "title": "Three"},
    {"start": 135, "end": 180, "title": "Four"}
  ]
}' 60 60 60

book "Ada Fixture" "Second Dawn" '{
  "title": "Second Dawn",
  "authors": ["Ada Fixture"],
  "narrators": ["Nell Narrator"],
  "series": ["Fixture Saga #2"],
  "publishedYear": "2003",
  "chapters": [
    {"start": 0, "end": 60, "title": "Before"},
    {"start": 60, "end": 120, "title": "After"}
  ]
}' 120

book "Ada Fixture" "The Long Dark" '{
  "title": "The Long Dark",
  "authors": ["Ada Fixture"],
  "series": ["Fixture Saga"],
  "publishedYear": "2004",
  "chapters": [
    {"start": 0, "end": 45, "title": "Night"},
    {"start": 45, "end": 90, "title": "Morning"}
  ]
}' 90

book "Ben Example" "Plain Silence" '{
  "title": "Plain Silence",
  "authors": ["Ben Example"],
  "publishedYear": "2010"
}' 120

book "Ben Example" "Loose Parts" '{
  "title": "Loose Parts",
  "authors": ["Ben Example"],
  "publishedYear": "2011"
}' 60 60

rm -rf "$silence"
