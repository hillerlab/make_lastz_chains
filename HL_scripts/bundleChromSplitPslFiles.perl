#!/usr/bin/env perl

# Michael Hiller, 2015
# see usage

use strict;
use warnings;
use POSIX;
use Getopt::Long qw(:config no_ignore_case no_auto_abbrev);
use FindBin qw($Bin);
use lib "$Bin";
use Globals;

$| = 1;		# == fflush(stdout)
my $maxBases = 30000000;
my $warningOnly = 0;
my $verbose = 0;
my $maxFilesPerBundle = 1000;  # to avoid that the shell errors because we have too many files for the 'cat', we limit the number of files
# options
my $usage = "usage: $0 inputDir chrom.sizes outputDir [-maxBases num -warningOnly -v]
The tool combines chrom-split psl files until the summed size of these chroms reaches maxBases (default 30,000,000, i.e. 30Mb).
If there are individual chroms that exceed maxBases in size, the chrom-split file will just be copied and not split further. 
The files in inputDir must have the ending .psl !
\
The main purpose is to bundle pls files for assemblies that have thousands of scaffolds.
\
	inputDir is a directory with psl files named \$chrom.psl (output of pslSortAcc)
	chrom.sizes is the chrom.sizes file for the reference species
	outputDir is a directory where the bundled psl files will be put
	-maxBases determines up to which size psl files will be bundled
	-warningOnly  if set, just output a warning if there are psl files in inDir that were not bundled and thus are not in outDir. Those files have names that do not correspond to entries in chrom.sizes. Default: error-exit.
";
GetOptions ("v|verbose"  => \$verbose, "maxBases=i" => \$maxBases, "warningOnly" => \$warningOnly, "verbose" => \$verbose) ||	die "$usage\n";
die "$usage\n" if ($#ARGV < 2);

sub readChromSizeHash {
	my $chromSizeFile = shift; 

	my %hash;
	open(FI,"$chromSizeFile") || die "ERROR: cannot open file $chromSizeFile\n";
	while (my $line=<FI>) {
		chomp($line);
		my @f = split(/\t/, $line);
		$hash{$f[0]} = $f[1];
	}
	close(FI);
	return %hash;
}

my $inDir = $ARGV[0];
my %chromSize = readChromSizeHash($ARGV[1]);

# make outDir
my $outDir = $ARGV[2];
my $call = "set -o pipefail; mkdir -p $outDir";
system("$call") == 0 || die("ERROR: $call failed\n");

# read the input dir into a hash. Used to later check that we have copied or bundled all files.
my %inputFileRead;
opendir(DIR, $inDir) or die "can't opendir $inDir: $!";
while (defined(my $file = readdir(DIR))) {
	 if ($file =~ /.psl$/) {
		 $inputFileRead{$file} = 0;
	 }
}
closedir(DIR);

# now bundle
# we sort and start with the biggest chrom
my $curBases = 0;
my $bundlePslFileList = "";
my $bundlePslFileCount = 0;
my $curBundleCount = 0;
foreach my $chr (	reverse sort { $chromSize{$a} <=> $chromSize{$b} } keys %chromSize) {
	printf "\nConsider %s %d\n", $chr, $chromSize{$chr} if ($verbose);
	if (! exists $inputFileRead{"$chr.psl"}) {
		print "\t--> file $chr.psl does not exist. Next\n" if ($verbose);
		next;
	}
	# add chrom to the string and its size
	$curBases += $chromSize{$chr};
	$bundlePslFileList .= "$inDir/$chr.psl ";
	$bundlePslFileCount ++;
	$inputFileRead{"$chr.psl"} = 1;

	print "curBases: $curBases  num files: $bundlePslFileCount   $bundlePslFileList\n" if ($verbose);

	# bundle if we exceed the max
	if ($curBases >= $maxBases || $bundlePslFileCount > $maxFilesPerBundle) {
		$call = "set -o pipefail; cat $bundlePslFileList > $outDir/bundle.$curBundleCount.psl";
		print "$call\n";
		system("$call") == 0 || die("ERROR: $call failed\n");
		$curBundleCount++;
		# reset variables
		$curBases = 0;
		$bundlePslFileList = "";
		$bundlePslFileCount = 0;
	}
}
# last bundle
if ($curBases > 0) {
	$call = "set -o pipefail; cat $bundlePslFileList > $outDir/bundle.$curBundleCount.psl";
	print "$call\n\n";
	system("$call") == 0 || die("ERROR: $call failed\n");
}


# check if there are psl files that we have not bundled --> they must have names that do not correspond to entries in chrom.sizes
foreach my $chr (	keys %inputFileRead) {
	if ($inputFileRead{$chr} == 0) {
		my $message = "file $inDir/$chr was not bundled as the chrom could not be found in $ARGV[1]";
		if ($warningOnly) {
			printf STDERR "WARNING: $message\n";
		}else{
			die "ERROR: $message\n";
		}
	}
}

print "DONE. Produced ", $curBundleCount + 1, " files\n";