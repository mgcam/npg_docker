#!/bin/bash

set -o pipefail
set -e

# Globals
INDEX=$1; shift                   # $1
PROJECT_ID=$1; shift              # $2
INDEX_WORDLEN=$1; shift           # $3
INDEX_STEPSIZE=$1; shift          # $4
INSERT_MAX=$1; shift              # $5
INSERT_MIN=$1; shift              # $6

# Catch empty input, set to standard values
[[ -z "$INDEX_WORDLEN" ]] && INDEX_WORDLEN="13"
[[ -z "$INDEX_STEPSIZE" ]] && INDEX_STEPSIZE="$INDEX_WORDLEN"
[[ -z "$INSERT_MAX" ]] && INSERT_MAX="500"
[[ -z "$INSERT_MIN" ]] &&  INSERT_MIN="0"

# Indexing
smalt index -k "$INDEX_WORDLEN" -s "$INDEX_STEPSIZE" "$INDEX" "$INDEX.fa"

# Prepare output folders, respecting Basespace naming convention
mkdir -p "/data/output/appresults/$PROJECT_ID/smalt"

# Iterate over all files
for input_file in /data/input/samples/*/*; do
  filename=$(basename "$input_file" .fastq.gz)
  output_file=/data/output/appresults/$PROJECT_ID/smalt/$filename

  # Only process R1 (following Illumina naming convention), check for R2 below
  if [[ $filename =~ _R1_[0-9]{3} ]]; then
    gzip -dc "$input_file" > input.fastq

    # Set post-processing pipeline:
    # bamsort | bamstreamingduplicates | samtools flagstat & stats | recompress
    mkfifo postproc_pipe && \
    bamsort level=0 SO=coordinates fixmates=1 adddupmarksupport=1 \
    < postproc_pipe \
    | bamstreamingmarkduplicates level=0 \
    | tee >(samtools flagstat - > "$output_file.flagstat") \
          >(samtools stats - > "$output_file.stats") \
    | bamrecompress md5=1 md5filename="$output_file.md5" \
                    index=1 indexfilename="$output_file.index" \
    > "$output_file.bam" &

    # Check for R2; Map paired reads, pipe into postproc_pipe
    mate=${input_file/_R1_/_R2_}
    if [ -e "$mate" ]; then
      gzip -dc "$mate" > mate.fastq
      mate="mate.fastq"
      smalt map -n "$(nproc)" -f bam -i "$INSERT_MAX" -j "$INSERT_MIN" \
      "$INDEX" input.fastq "$mate" > postproc_pipe

    # Else: Map single reads, pipe into postproc_pipe
    else
      smalt map -n "$(nproc)" -f bam "$INDEX" input.fastq > postproc_pipe
    fi

    wait # for pipe: incomplete results otherwise

    # Plot stats
    plot-bamstats "$output_file.stats" \
     -p "/data/output/appresults/$PROJECT_ID/smalt/plot-bamstats/$filename"

    # Tidy up
    rm postproc_pipe input.fastq
    [[ -e "$mate" ]] && rm "$mate"
  fi
done

exit 0
