#!/bin/bash

# Check if the number of arguments is correct
if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <tool_name>"
  exit 1
fi

# Download the tool
tool_name=$1
download_url="https://hgdownload.cse.ucsc.edu/admin/exe/macOSX.x86_64/$tool_name"

# Download using wget
wget -O "HL_kent_binaries/$tool_name" "$download_url"
chmod +x "HL_kent_binaries/$tool_name"

# Check if the download was successful
if [ $? -eq 0 ]; then
  echo "Successfully downloaded $tool_name."
else
  echo "Failed to download $tool_name."
  exit 1
fi
