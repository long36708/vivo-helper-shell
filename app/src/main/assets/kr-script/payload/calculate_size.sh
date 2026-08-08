#!/bin/bash

# Function to calculate the offset of each file entry in the zip file
get_zip_entry_offset() {
  zip_file=$1
  zip_entry=$2

  # Use zipinfo to get the local header offset
  header_offset=$(zipinfo -l "$zip_file" | grep "$zip_entry" | awk '{print $2}')
  
  # Use zipinfo to get filename length and extra field length (manually calculated)
  local_header_length=30
  file_name_length=$(zipinfo -l "$zip_file" | grep "$zip_entry" | awk '{print $9}')
  extra_field_length=0  # You may need to adjust this based on your zipfile

  # Calculate the offset
  file_offset=$((header_offset + local_header_length + file_name_length + extra_field_length))
  echo "$file_offset"
}

# Function to calculate the file offsets and sizes in the zip file
calculate_zip_offsets() {
  zip_file=$1
  result=()

  # Get all the entries of the zip file except for META-INF/com/android/otacert
  entries=$(unzip -l "$zip_file" | awk '{print $4}' | grep -v "META-INF/com/android/otacert")

  # Iterate through each entry
  for entry in $entries; do
    # Get file size
    file_size=$(unzip -l "$zip_file" | grep "$entry" | awk '{print $1}')

    # Skip empty files
    if [ "$file_size" -gt 0 ]; then
      # Get basename of the entry (filename without path)
      file_name=$(basename "$entry")

      # Get file offset
      file_offset=$(get_zip_entry_offset "$zip_file" "$entry")

      # Append to the result
      result+=("$file_name:$file_offset:$file_size")
    fi
  done

  # Join the result with commas
  echo "ota-streaming-property-files=$(IFS=,; echo "${result[*]}")"
}

# Main script logic
if [ $# -ne 1 ]; then
  echo "Usage: $0 <zip_file>"
  exit 1
fi

zip_file=$1

# Check if the file exists
if [ ! -f "$zip_file" ]; then
  echo "Error: File not found!"
  exit 1
fi

# Call the function to calculate offsets and sizes
calculate_zip_offsets "$zip_file"
