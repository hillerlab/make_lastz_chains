#!/usr/bin/env python3
"""Python replacement fot cat.csh.


Defined as:
	my $fh = &HgAutomate::mustOpen(">$runDir/cat.csh");
	print $fh <<_EOF_
#!/bin/csh -ef
find $outRoot/\$1/ -name "*.psl" | xargs cat | grep "^#" -v | gzip -c > \$2
_EOF_
;
  	close($fh); 

"""

import sys
import os
import gzip


def gzip_str(string_: str) -> bytes:
    ret = gzip.compress(string_.encode())
    del string_
    return ret


def main():
    if len(sys.argv) < 3:
        sys.exit(f"Usage: {sys.argv[0]} [input] [output] [-v|--verbose]")
    _v = False
    if "-v" in sys.argv or "--verbose" in sys.argv:
        _v = True

    in_ = sys.argv[1]
    out_ = sys.argv[2]
    print(f"Input: {in_}\nOutput: {out_}") if _v else None

    psl_filenames = [x for x in os.listdir(in_) if x.endswith(".psl")]
    buffer = []
    print(f"Psl filenames: {psl_filenames}") if _v else None

    # read all psl files excluding those containing #
    for fname in psl_filenames:
        path = os.path.join(in_, fname)
        print(f"   Reading {path}...") if _v else None
        f = open(path, 'r')
        for line in f:
            if "#" in line:
                continue
            buffer.append(line)
        f.close()
    print(f"Lines in buffer: {len(buffer)}") if _v else None
    # zip the strings we get
    str_to_zip = "".join(buffer)
    print(f"Unzipped string len: {len(str_to_zip)}") if _v else None
    zipped_str = gzip_str(str_to_zip)
    print(f"Saving {len(zipped_str)} bytes to output")
    with open(out_, 'wb') as f:
        f.write(zipped_str)


if __name__ == "__main__":
    main()
