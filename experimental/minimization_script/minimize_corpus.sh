#!/bin/sh
#
# american fuzzy lop - corpus minimization tool
# ---------------------------------------------
#
# Written and maintained by Michal Zalewski <lcamtuf@google.com>
#
# Copyright 2014 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at:
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# This tool tries to find the smallest subset of files in the input directory
# that still trigger the full range of instrumentation data points seen in
# the starting corpus. This has two uses:
#
#   - Screening large corpora of input files before using them as a seed for
#     seed for afl-fuzz,
#
#   - Cleaning up the corpus generated by afl-fuzz.
#
# The tool assumes that the tested program reads from stdin and requires no
# cmdline parameters; very simple edits are required to support other use
# cases.
#
# If you set AFL_EDGES_ONLY beforehand, the afl-showmap utility will only
# report branch hit information, not hit counts, producing a more traditional
# and smaller corpus that more directly maps to edge coverage.
#

echo "corpus minimization tool for afl-fuzz by <lcamtuf@google.com>"
echo

ulimit -v 100000 2>/dev/null
ulimit -d 100000 2>/dev/null

if [ ! "$#" = "2" ]; then
  echo "Usage: $0 /path/to/corpus_dir /path/to/tested_binary" 1>&2
  echo 1>&2
  echo "Note: the tested binary must accept input on stdin and require no additional" 1>&2
  echo "parameters. For more complex use cases, you need to edit this script." 1>&2
  echo 1>&2
  exit 1
fi

DIR="`echo "$1" | sed 's/\/$//'`"
BIN="$2"

if [ ! -f "$BIN" -o ! -x "$BIN" ]; then
  echo "Error: binary '$2' not found or is not executable." 1>&2
  exit 1
fi

if [ ! -d "$DIR" ]; then
  echo "Error: directory '$1' not found." 1>&2
  exit 1
fi

# Try to find afl-showmap somewhere...

if [ "$AFL_PATH" = "" ]; then
  SM=`which afl-showmap 2>/dev/null`
  test "$SM" = "" && SM="./afl-showmap"
else
  SM="$AFL_PATH/afl-showmap"
fi

if [ ! -x "$SM" ]; then
  echo "Can't find $SM - please set AFL_PATH."
  exit 1
fi

CCOUNT=$((`ls -- "$DIR" 2>/dev/null | wc -l`))

if [ "$CCOUNT" = "0" ]; then
  echo "No inputs in the target directory - nothing to be done."
  exit 0
fi

rm -rf .traces 2>/dev/null
mkdir .traces || exit 1

if [ "$AFL_EDGES_ONLY" = "" ]; then
  OUT_DIR="$DIR.minimized"
else
  OUT_DIR="$DIR.edges.minimized"
fi

rm -rf -- "$OUT_DIR" 2>/dev/null
mkdir "$OUT_DIR" || exit 1

echo "[*] Evaluating $CCOUNT input files in '$DIR'..."

CUR=0

for fn in `ls "$DIR"`; do

  CUR=$((CUR+1))
  printf "\\r    Processing file $CUR/$CCOUNT... "

  # Modify this if $BIN needs to be called with additional parameters, etc.

  AFL_SINK_OUTPUT=1 AFL_QUIET=1 "$SM" "$BIN" <"$DIR/$fn" >".traces/$fn" 2>&1

  FSIZE=`wc -c <"$DIR/$fn"`

  cat ".traces/$fn" >>.traces/.all
  awk '{print "'$((FSIZE))'~" $0 "~'"$fn"'"}' <".traces/$fn" >>.traces/.lookup

done

echo
echo "[*] Sorting trace sets..."

# Find the least common tuples; let's start with ones that have just one
# or a couple test cases, since we probably won't be able to avoid these
# test cases no matter how hard we try.

sort .traces/.all | uniq -c | sort -n >.traces/.all_uniq

# Prepare a list of files for each tuple, smallest first.

sort -n .traces/.lookup >.traces/.lookup_sorted

TCOUNT=$((`grep -c . .traces/.all_uniq`))

echo "[+] Found $TCOUNT unique tuples across $CCOUNT files."
echo "[*] Minimizing (this will get progressively faster)..."

touch .traces/.already_have

CUR=0

SYS=`uname -s`

while read -r cnt tuple; do

  CUR=$((CUR+1))
  printf "\\r    Processing tuple $CUR/$TCOUNT... "

  # If we already have this tuple, skip it.

  grep -q "^$tuple\$" .traces/.already_have && continue

  # Find the best (smallest) candidate for this tuple.

  if [ "$SYS" = "Linux" ]; then
    FN=`grep -F -m 1 "~$tuple~" .traces/.lookup_sorted | cut -d~ -f3-`
  else
    FN=`grep -F "~$tuple~" .traces/.lookup_sorted | head -1 | cut -d~ -f3-`
  fi

  ln "$DIR/$FN" "$OUT_DIR/$FN"

  if [ "$((CUR % 5))" = "0" ]; then
    cat ".traces/$FN" ".traces/.already_have" | sort -u >.traces/.tmp
    mv -f .traces/.tmp .traces/.already_have
  else
    cat ".traces/$FN" >>".traces/.already_have"
  fi

done <.traces/.all_uniq

NCOUNT=`ls -- "$OUT_DIR" | wc -l`

echo
echo "[+] Narrowed down to $NCOUNT files, saved in '$OUT_DIR'."

rm -rf .traces
