Directory to store Kent binaries necessary to run the pipeline,
which are not included in the $PATH for some reason,
and were downloaded using install_dependencies.py script.

Although NetFilterNonNested.perl is not actually a binary, it's only purpose
is to serve as a dependency to chainCleaner, as well as ChainNet, which is not
used directly by the pipeline.
