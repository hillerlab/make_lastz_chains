#!/usr/bin/env perl
#
#
#
# <Nikolai Tue Jan 30 17:41:09 CET 2018>
#
use strict;
use Carp;
use Getopt::Long;
use POSIX;
use List::Util qw/shuffle/;

### options
my $inf = "";
my $prefix = "";
my $n;
undef $n;

my $usage = "Usage:\n\t$0 [OPTIONS]\n";
$usage .= "\t-c|chain\t\tFILENAME\tChain file to be split\n";
$usage .= "\t-p|prefix\t\tSTRING\t\tPrefix for output files\n";
$usage .= "\t-n|nsplit\t\tINTEGER\t\tNumber desired files chain is split into\n\n";
$usage .= "Splits a chain file into n chain split files, randomly picking chain ids.\nExample usage:\n $0 -c hg38.speTri2.all.chain -n 100 -p splitChains_hg38_speTri2_\n\n";
$usage .= "Given very large chains this script might be somewhat heavy on memory for storing millions of chainIDs.\n";

GetOptions(
    "c|chain=s" =>  \$inf,
    "p|prefix=s" => \$prefix,
    "n|nsplit=i" => \$n
    );

# check mandatory options
if($inf eq "" || $prefix eq "" || !defined($n) )
{
    print $usage;
    croak "Too few or wrong arguments.";
}


### main
my @achainIds = (); # store chain IDs
my %h_idfh = (); # hash will assign chain IDs to file handle array positions
my @fhs = (); # file handles

my $fh;

# get chain IDs
open($fh, "<$inf") || croak "Can't open chain file '$inf'.";

while(<$fh>)
{
    my $line = $_;
    chomp($line);

    # store chain ID
    if($line =~ /^chain.*\s+(\d+)$/)
    {
	my $id = $1;
	push(@achainIds, $id);
    }
}
close($fh);

my $nids = @achainIds;
print "Found $nids chain IDs\n";

# shuffle ids
@achainIds = shuffle @achainIds;

# create file handle hash
my $pos = 0;

for(my $i=0; $i < @achainIds; $i++)
{
    $h_idfh{$achainIds[$i]} = $pos;
    
    # increment pos or set it back to 0
    $pos = ($pos + 1) < $n ? ($pos + 1) : 0;
}


### open all file handles
for(my $i=0; $i < $n; $i++)
{
    my $outf = $prefix.$i;
    my $tfh;
    open($tfh, ">$outf") || croak "Failed to open file handle for split file '$outf'";
     $fhs[$i] = \$tfh; # store file handle references
    
}

### process chain file and store write to assigned file handle
open($fh, "<$inf") || croak "Can't open chain file '$inf'.";

while(<$fh>)
{
    my $line = $_;
    chomp($line);

    # store chain ID
    if($line =~ /^chain.*\s+(\d+)$/)
    {
	# get file handle 
	my $id = $1;
	my $fhpos = $h_idfh{$id};
	my $refoutfh = $fhs[$fhpos];
	my $outfh = $$refoutfh;

	# write chain header
	print $outfh "$line\n";

	# get process lines and write output
	while( ($line = <$fh>) =~ /^\d+/)
	{
	    print $outfh "$line";
	}
	#print final empty line
	print $outfh "\n";
    }
}
close($fh);


### close all file handles
for(my $i=0; $i < $n; $i++)
{
    my $reftfh = $fhs[$i];
    my $tfh = $$reftfh;
    close($tfh);
}

print "Wrote output to $n files starting with '$prefix'.\n"
