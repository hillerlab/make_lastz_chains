#!/usr/bin/env perl

# lightweight version of UCSC's kent src doBlastzChainNet.pl that automates lastz and chaining
# This script also runs chainGapFiller and chainCleaner

use Getopt::Long;
use warnings;
use strict;
use diagnostics;
use FindBin qw($Bin);
use lib "$Bin";
use HgAutomate;
use HgRemoteScript;
use HgStepManager;
use Carp;


# Hardcoded paths/command sequences:
print "BIN: $Bin\n";
# my $blastzRunUcsc = "blastz-run-ucsc";
my $blastzRunUcsc = "run_lastz.py";  # instead of blastz-run-ucsc
my $partition = "partitionSequence.pl";  # fine, here
my $splitChain_into_randomParts = "splitChain_into_randomParts.pl";  # fine, here
my $axtChain = `set -o pipefail; which axtChain`; chomp($axtChain);  # fine, here
my $chainSort = `set -o pipefail; which chainSort`; chomp($chainSort);  # fine, here
my $scoreChain = `set -o pipefail; which chainScore`; chomp($scoreChain);  # replaced with chainScore
my $chainGapFiller = `set -o pipefail; which chainGapFiller.py`; chomp($chainGapFiller);
my $chainExtractID = `set -o pipefail; which chainExtractID.py`; chomp($chainExtractID);
my $lastz = "lastz";  # installed
my $chainCleaner = "chainCleaner";  # somewhat here ++ not for macBook yet
my $chainAntiRepeat = "chainAntiRepeat";   # is here
my $chainMergeSort = "chainMergeSort";  # installed
my $bundleChromSplitPslFiles = "bundleChromSplitPslFiles.perl";  # here
my $pslSortAcc = "pslSortAcc";  # !! missing

# Bogdan, also needed:
# axtToPsl


# Option variable names, both common and peculiar to doBlastz:
use vars @HgAutomate::commonOptionVars;
use vars @HgStepManager::optionVars;

my $chainMinScore = "1000";		# default for axtChain
my $chainLinearGap = "loose";	# default chain gap costs (we prefer loose over medium, also for closely related species)
my $clusterRunDir = ".";		# dir where the temp files will be produced
my $keepTempFiles = 0;		# flag: if set, do not remove temp files
my $defaultSeq1Limit = 30;		# defaults for splitting the genome (in case this is not specified in DEF)
my $defaultSeq2Limit = 100;
my $fillChains = 0;			# flag for chain gap filler
my $fillUnmask = 0;                 # flag for unmasking chains during chain gap filling
my $fillExclChr = "";               # comma separated list for excluding chroms from patching
my $cleanChains = 0;			# flag for cleaning chains
my $debug = 0;				# flag for do not run the actual steps

my $chainingQueue = "long";		# queue for chaining jobs (long is default)
my $chainingMemory = 15000;		# memory limit for chaining jobs in MB
my $chainCleanMemory = 100000;	# memory limit for chainClean jobs in MB

my $maxNumLastzJobs = 6000;		# number job limit for lastz step
my $numFillJobs = 1000;		# number of cluster jobs for the fillChain step
my $nf_executor = "local";  # cluster jobs executor, default local, possible: slurm, lsf, etc
# TODO: thing about other executor params?

# Specify the steps supported with -continue / -stop:
my $stepper = new HgStepManager(
    [ { name => 'partition',  func => \&doPartition },
      { name => 'lastz',     func => \&doLastzClusterRun },
      { name => 'cat',        func => \&doCatRun },
      { name => 'chainRun',   func => \&doChainRun },
      { name => 'chainMerge', func => \&doChainMerge },
      { name => 'fillChains', func => \&doFillChains },
      { name => 'cleanChains', func => \&doCleanChains }
    ]
);

# other Globals:
my %defVars = ();
my ($DEF, $tDb, $qDb, $buildDir, $hub);
my ($secondsStart, $secondsEnd);


#################################################################################################
# Usage / HowTo
#################################################################################################
sub usage {
	my ($status) = @_;
	print "Automates UCSC's lastz/chain pipeline, including chainGapFiller and chainCleaner.";

print "
    -clusterRunDir dir    Optional: Full path to a directory ƒthat will hold all temporary files and steps during the cluster run (default current directory).
    -keepTempFiles        Optional flag: If set, do not cleanup the temporary files
    -chainMinScore n      Specify minimum score for a chain in axtChain (default: $chainMinScore)
    -chainLinearGap type  Specify gap costs used in axtChain (can be loose|medium|filename. default: loose)
    -maxNumLastzJobs n    max number of lastz jobs that will be submitted to the cluster queue (default $maxNumLastzJobs)
    -numFillJobs n        number of jobs for the chainGapFiller step that will be submitted to the cluster queue (default $numFillJobs)
    -verbose              Optional flag: Enable verbose output	 
    -debug                Don't actually run commands, just display them.
	-executor            Select cluster jobs executor, local is default (see nextflow executor documentation for more)  
";
	print $stepper->getOptionHelp();
	exit $status;
}



#################################################################################################
# Make sure command line options are valid/supported.
#################################################################################################
sub checkOptions {
	my $ok = GetOptions(
		"clusterRunDir=s" => \$clusterRunDir,
		"keepTempFiles" => \$keepTempFiles,
		"chainMinScore=i" => \$chainMinScore,
		"chainLinearGap=s" => \$chainLinearGap,
		"maxNumLastzJobs=i" => \$maxNumLastzJobs,
		"numFillJobs=i" => \$numFillJobs,
		"continue=s" => \$opt_continue,
		"stop=s" => \$opt_stop,
		"verbose" => \$opt_verbose,
		"executor=s" => \$nf_executor,
		"debug" => \$debug);
	&usage(1) if (!$ok);
	&HgAutomate::processCommonOptions();
	my $err = $stepper->processOptions();
	usage(1) if ($err);

	&HgAutomate::verbose(1, "PARAMETERS:\n\tclusterRunDir $clusterRunDir\n\tchainMinScore $chainMinScore\n\tchainLinearGap $chainLinearGap\n\tmaxNumLastzJobs $maxNumLastzJobs\n\tnumFillJobs $numFillJobs\n\tverbose $opt_verbose\n\tdebug $debug\n");
}

##################################################################################################################################################
# The following routines were taken almost verbatim from blastz-run-ucsc,
# so may be good candidates for libification!  unless that would slow down
# blastz-run-ucsc...
# nfsNoodge() was removed from loadDef() and loadSeqSizes() -- since this
# script will not be run on the cluster, we should fully expect files to
# be immediately visible.
##################################################################################################################################################
sub loadDef {
  # Read parameters from a bash script with Scott's param variable names:
  my ($def) = @_;
  my $fh = &HgAutomate::mustOpen("$def");
  while (<$fh>) {
    s/^\s*export\s+//;
    next if (/^\s*#/ || /^\s*$/);
    if (/(\w+)\s*=\s*(.*)/) {
      my ($var, $val) = ($1, $2);
      while ($val =~ /\$(\w+)/) {
	my $subst = $defVars{$1};
	if (defined $subst) {
	  $val =~ s/\$$1/$subst/;
	} else {
	  croak "Can't find value to substitute for \$$1 in $DEF var $var.\n";
	}
      }
      $defVars{$var} = $val;
    }
  }
  close($fh);
  
  # test if TMPDIR in DEF exists; if not create it
  if (exists $defVars{TMPDIR} && ! -e $defVars{TMPDIR}) {
  		warn "create $defVars{TMPDIR}\n";
		system "set -o pipefail; mkdir -p $defVars{TMPDIR}";
  }  
}

sub loadSeqSizes {
  # Load up sequence -> size mapping from $sizeFile into $hashRef.
  my ($sizeFile, $hashRef) = @_;
  my $fh = &HgAutomate::mustOpen("$sizeFile");
  while (<$fh>) {
    chomp;
    my ($seq, $size) = split;
    $hashRef->{$seq} = $size;
  }
  close($fh);
}

# end shared stuff from blastz-run-ucsc
##################################################################################################################################################


##################################################################################################################################################
# three helper functions to check for existence and correctness of parameters in DEF
##################################################################################################################################################
sub requireVar {
  my ($var) = @_;
  croak "Error: $DEF is missing variable $var\n" if (! defined $defVars{$var});
}

sub requirePath {
  my ($var) = @_;
  my $val = $defVars{$var};
  croak "Error: $DEF $var=$val must specify a complete path\n"
    if ($val !~ m@^/\S+/\S+@);
  if ( -d $val ) {
    my $fileCount = `set -o pipefail; find $val -maxdepth 1 -type f | wc -l`;
    chomp $fileCount;
    if ($fileCount < 1) {
	croak "Error: $DEF variable: $var=$val specifies an empty directory.\n";
    }
  } elsif ( ! -s $val ) {
    croak "Error: $DEF variable: $var=$val is not a file or directory.\n";
  }
}

sub requireNum {
  my ($var) = @_;
  my $val = $defVars{$var};
  croak "Error: $DEF variable $var=$val must specify a number.\n"
    if ($val !~ /^\d+$/);
}
##################################################################################################################################################




##############################################################################################################################################
# Make sure %defVars contains what we need and looks consistent with our assumptions.
##############################################################################################################################################
sub checkDef {
  # Bogdan: SEQ1_DIR SEQ1_LEN et cetera are binded to our setup
  # Bogdan: chrom.sizes -- I'd generate them on fly if not present together with 2bit
  foreach my $s ('SEQ1_', 'SEQ2_') {
    foreach my $req ('DIR', 'LEN', 'CHUNK', 'LAP') {
      &requireVar("$s$req");
    }
    &requirePath($s . 'DIR');
    &requirePath($s . 'LEN');
    &requireNum($s . 'CHUNK');
    &requireNum($s . 'LAP');
  }

  &requireVar('ref');
  &requireVar('query');

  $tDb = $defVars{'ref'};
  $qDb = $defVars{'query'};

  HgAutomate::verbose(1, "$DEF looks OK!\n\ttDb=$tDb\n\tqDb=$qDb\n\tseq1dir=$defVars{SEQ1_DIR}\n\tseq2dir=$defVars{SEQ2_DIR}\n");

  # chain gap filling: if enabled, check if relevant parameters exist in DEF
  if (exists $defVars{'FILL_CHAIN'} && $defVars{'FILL_CHAIN'} == 1) {
	$fillChains = 1;
	croak "ERROR: $DEF doesn't specify FILL_CHAIN_MINSCORE\n" if ( ! exists $defVars{'FILL_CHAIN_MINSCORE'});
	croak "ERROR: $DEF doesn't specify FILL_GAPMAXSIZE_T\n" if ( ! exists $defVars{'FILL_GAPMAXSIZE_T'});
	croak "ERROR: $DEF doesn't specify FILL_GAPMAXSIZE_Q\n" if ( ! exists $defVars{'FILL_GAPMAXSIZE_Q'});
	croak "ERROR: $DEF doesn't specify FILL_GAPMINSIZE_T\n" if ( ! exists $defVars{'FILL_GAPMINSIZE_T'});
	croak "ERROR: $DEF doesn't specify FILL_GAPMINSIZE_Q\n" if ( ! exists $defVars{'FILL_GAPMINSIZE_Q'});
	croak "ERROR: $DEF doesn't specify FILL_BLASTZ_K\n" if ( ! exists $defVars{'FILL_BLASTZ_K'});
	croak "ERROR: $DEF doesn't specify FILL_BLASTZ_L\n" if ( ! exists $defVars{'FILL_BLASTZ_L'});
	croak "ERROR: $DEF doesn't specify FILL_MEMORY\n" if ( ! exists $defVars{'FILL_MEMORY'});
	croak "ERROR: $DEF doesn't specify FILL_PREPARE_MEMORY\n" if ( ! exists $defVars{'FILL_PREPARE_MEMORY'});

	if(defined($defVars{'FILL_UNMASK'}) && $defVars{'FILL_UNMASK'} == 1)	{
	    $fillUnmask = 1;
	}
	if(defined($defVars{'FILL_EXCLUDECHROMS'}) && $defVars{'FILL_EXCLUDECHROMS'} ne "")	{
	    $fillExclChr = $defVars{'FILL_EXCLUDECHROMS'};
	}
  }

  # chain cleaning: if enabled, set flag
  $cleanChains = 1 if (exists $defVars{'CLEANCHAIN'} && $defVars{'CLEANCHAIN'} == 1); 

  croak "ERROR: $DEF doesn't specify BLASTZ variable\n" if (! exists $defVars{'BLASTZ'});
  $lastz = $defVars{'BLASTZ'};
}


##############################################################################################################################################
# Small helper function to test if the step starts clean and if the previous step was successful
##############################################################################################################################################
sub testCleanState {
	my ($curStep, $curDir, $curFile, $prevStep, $prevFile) = @_;

	&HgAutomate::verbose(1, "testCleanState current step: $curStep, $curDir, $curFile     previous step: $prevStep, $prevFile\n");

	# Make sure we're starting clean.
	if (-e "$curFile" && ! $debug) {
		croak "$curStep: looks like this was run successfully already ($curFile exists).  Either run with -continue at some later step, or move aside/remove $curDir/ and run again.\n";
	}
	# Make sure that previous step was successful
	if (! -e $prevFile && ! $debug) {
		croak "$curStep: previous step ($prevStep) did not complete, as $prevFile does not exist\n";
	}
	return 0;
}


##############################################################################################################################################
# Partition the sequence up before lastz.
##############################################################################################################################################
sub doPartition {
	&HgAutomate::verbose(1, "doPartition ....\n");

	my $runDir = "$buildDir/TEMP_run.lastz";
	my $targetList = "$tDb.lst";
	my $queryList = "$qDb.lst";

	my $tPartDir = '-lstDir tParts';
	my $qPartDir = '-lstDir qParts';
	my $outRoot = "$buildDir/TEMP_psl";

	# First, make sure we're starting clean.
	if (-e "$runDir/partition.done") {
		croak "doPartition: looks like doPartition was already successful ($runDir/partition.done exists).\nEither -continue {some later step} or move aside/remove $runDir/ and run again.\n";
	}

	my $seq1Dir = $defVars{'SEQ1_DIR'};
	my $seq2Dir = $defVars{'SEQ2_DIR'};
	my $seq1Len = $defVars{'SEQ1_LEN'};
	my $seq2Len = $defVars{'SEQ2_LEN'};
	my $seq1Limit = (defined $defVars{'SEQ1_LIMIT'}) ? $defVars{'SEQ1_LIMIT'} :  $defaultSeq1Limit;
	my $seq2Limit = (defined $defVars{'SEQ2_LIMIT'}) ? $defVars{'SEQ2_LIMIT'} :  $defaultSeq2Limit;
	&HgAutomate::verbose(1, "doPartition: seq2MaxLength ....\n");
	my $seq2MaxLength = `set -o pipefail; awk '{print \$2}' $seq2Len | sort -rn | head -1`;
	chomp $seq2MaxLength;
	&HgAutomate::verbose(1, "doPartition: seq2MaxLength = $seq2MaxLength\n");

	my $partitionTargetCmd = ("$partition $defVars{SEQ1_CHUNK} $defVars{SEQ1_LAP} $seq1Dir $seq1Len -xdir xdir.sh -rawDir $outRoot $seq1Limit $tPartDir > $targetList");
	my $partitionQueryCmd = ("$partition $defVars{SEQ2_CHUNK} $defVars{SEQ2_LAP} $seq2Dir $seq2Len $seq2Limit $qPartDir > $queryList");
	&HgAutomate::verbose(1, "doPartition: partitionTargetCmd $partitionTargetCmd\n");
	&HgAutomate::verbose(1, "doPartition: partitionQueryCmd $partitionQueryCmd\n");

	&HgAutomate::mustMkdir($runDir);
	my $whatItDoes = "Partitions reference and query genome into chunks for the lastz cluster run\n";
	my $bossScript = newBash HgRemoteScript("$runDir/doPartition.bash", "", $runDir, $whatItDoes, $DEF);

	$bossScript->add(<<_EOF_
$partitionTargetCmd
export L1=`wc -l < $targetList`
$partitionQueryCmd
export L2=`wc -l < $queryList`
export L=`echo \$L1 \$L2 | awk '{print \$1*\$2}'`
echo "cluster batch jobList size: \$L = \$L1 * \$L2"

if [ -d tParts ]; then
  echo 'constructing tParts/*.2bit files'
  ls tParts/*.lst | sed -e 's#tParts/##; s#.lst##;' | while read tPart
  do
    sed -e 's#.*.2bit:##;' tParts/\$tPart.lst | twoBitToFa -seqList=stdin $seq1Dir stdout | faToTwoBit stdin tParts/\$tPart.2bit
  done
fi
if [ -d qParts ]; then
  echo 'constructing qParts/*.2bit files'
  ls qParts/*.lst | sed -e 's#qParts/##; s#.lst##;' | while read qPart
  do
    sed -e 's#.*.2bit:##;' qParts/\$qPart.lst | twoBitToFa -seqList=stdin $seq2Dir stdout | faToTwoBit stdin qParts/\$qPart.2bit
  done
fi
_EOF_
    );
	
	&HgAutomate::verbose(1, "content of $runDir/doPartition.bash\n");
	`cat $runDir/doPartition.bash` if ($opt_verbose);

	if (! $debug) { 
		$bossScript->execute();

		my $noJobsT = `set -o pipefail; wc -l < $runDir/$targetList`;
		my $noJobsQ = `set -o pipefail; wc -l < $runDir/$queryList`;
		my $noJobs = $noJobsT * $noJobsQ;
		if( $noJobs > $maxNumLastzJobs ) {
			print ( "*** The number of jobs should not exceed $maxNumLastzJobs" ); 
			print ( "Stopped $0. You have $noJobs right now.\nTo achieve a good number of jobs in the range of $maxNumLastzJobs, you can adapt your DEF file.");
			print ( "Run 'rm -rf $buildDir/TEMP_run.lastz $buildDir/TEMP_psl' before restarting $0.\n" );
			exit(1); 
		}

#		&HgAutomate::run("'(cd $runDir; csh -ef xdir.sh)'");
		my $call = "(cd $runDir; csh -ef xdir.sh)";
		&HgAutomate::verbose(1, "$call\n");
		system("$call") == 0 || die("ERROR: $call failed\n");
	}
	`touch $runDir/partition.done`;
	&HgAutomate::verbose(1, "doPartition DONE\n");

}



##############################################################################################################################################
# Set up and perform the cluster lastz run.
##############################################################################################################################################
sub doLastzClusterRun {
	&HgAutomate::verbose(1, "doLastzClusterRun ....\n");
	my $runDir = "$buildDir/TEMP_run.lastz";
	my $targetList = "$tDb.lst";
	my $outRoot = "$buildDir/TEMP_psl";
	my $queryList = "$qDb.lst";

	# Make sure we're starting clean and that previous step was run successfully
	testCleanState("doLastzClusterRun", $runDir, "$runDir/lastz.done", "doPartition", "$runDir/partition.done");

	my $checkOutExists ="$outRoot" . '/$(file1)/$(file1)_$(file2).psl';
	# my $templateCmd = "$blastzRunUcsc -outFormat psl \$(path1) \$(path2) ../DEF " . $checkOutExists;
	my $templateCmd = "$blastzRunUcsc --outFormat psl \$(path1) \$(path2) $buildDir/DEF " . $checkOutExists;
	&HgAutomate::makeGsub($runDir, $templateCmd);

	my $myParaRun = "
parallel_executor.py lastz_$tDb$qDb jobList -q day --memoryMb 10000 -e $nf_executor\n";

	my $whatItDoes = "Set up and perform the all-vs-all lastz cluster run.";
  
	my $bossScript = newBash HgRemoteScript("$runDir/doClusterRun.sh", "", $runDir, $whatItDoes, $DEF);
## Never indent the content of the add() function!
	$bossScript->add(<<_EOF_
$HgAutomate::gensub2 $targetList $queryList gsub jobList
$myParaRun
_EOF_
    );
	$bossScript->execute() if (! $debug);

	`touch $runDir/lastz.done`;
	&HgAutomate::verbose(1, "doLastzClusterRun DONE\n");
}	#	sub doLastzClusterRun {}


##############################################################################################################################################
# Do a cluster run to concatenate the lowest level of chunk result
# files from the big cluster lastz run.  This brings results up to the
# next level: per-target-chunk results, which may still need to be
# concatenated into per-target-sequence in the next step after this one chaining.
##############################################################################################################################################
sub doCatRun {
	&HgAutomate::verbose(1, "doCatRun ....\n");
	my $runDir = "$buildDir/TEMP_run.cat";
	
	# Make sure we're starting clean and that previous step was run successfully
	testCleanState("doCatRun", $runDir, "$runDir/cat.done", "doLastzClusterRun", "$buildDir/TEMP_run.lastz/lastz.done");

	my $checkOutExists = "$buildDir/TEMP_pslParts/\$(file1).psl.gz";
	my $outRoot = "$buildDir/TEMP_psl";

	&HgAutomate::mustMkdir($runDir);
	&HgAutomate::makeGsub($runDir, "pyCat.py $outRoot/\$(path1) $checkOutExists");

	my $myParaRun = "
parallel_executor.py catRun_$tDb$qDb jobList -q day --memoryMb 4000 -e $nf_executor\n";

	my $whatItDoes = "Sets up and perform a cluster run to concatenate all files in each subdirectory of $outRoot into a per-target-chunk file.";
	my $bossScript = new HgRemoteScript("$runDir/doCatRun.csh", "", $runDir, $whatItDoes, $DEF);
	$bossScript->add(<<_EOF_
(cd $outRoot; find . -maxdepth 1 -type d | grep '^./') | sed -e 's#/\$##; s#^./##' > tParts.lst

$HgAutomate::gensub2 tParts.lst single gsub jobList
mkdir -p ../TEMP_pslParts
$myParaRun
_EOF_
 	);

	$bossScript->execute() if (! $debug);
	`touch $runDir/cat.done`;
	&HgAutomate::verbose(1, "doCatRun DONE\n");
}	##	sub doCatRun {}



############################################
# added by Michael Hiller
# ##########################################
sub bundlePslForChaining {
	my ($inputDir, $outputDir, $outputFileList, $maxBases, $gzipped) = @_; 
	&HgAutomate::verbose(1, "bundlePslForChaining ....\n");
 
	&HgAutomate::verbose(1, "bundlePslForChaining: $inputDir, $outputDir, $outputFileList, maxBases=$maxBases, gzipped=$gzipped\n");
	my $gzip = "";
	$gzip = ".gz" if ($gzipped == 1);

	# get filelist
	my $fileList = `set -o pipefail; find $inputDir -name "*psl$gzip" -printf "%p "`; 
	chomp($fileList);
	&HgAutomate::verbose(1, "fileList: $fileList\n");

	# we need 2 tmpDirs. One for pslSortAcc internally. One for the chrom-split files
	my $splitPSL = `set -o pipefail; mktemp -d`; chomp($splitPSL);
	my $tmpDir = `set -o pipefail; mktemp -d`; chomp($tmpDir);
	my $call = "set -o pipefail; $pslSortAcc nohead $splitPSL $tmpDir $fileList";
	&HgAutomate::verbose(1, "$call\n");
	system("$call") == 0 || die("ERROR: $call failed\n");
	`set -o pipefail; rm -rf $tmpDir`;

	# bundle
	$call = "set -o pipefail; $bundleChromSplitPslFiles $splitPSL $defVars{'SEQ1_LEN'} $outputDir -maxBases $maxBases";
	&HgAutomate::verbose(1, "$call\n");
	system("$call") == 0 || die("ERROR: $call failed\n");
	`set -o pipefail; rm -rf $splitPSL`;

	# get output filelist
	$call = "set -o pipefail; (cd $outputDir; find . -name \"*.psl\" -printf \"%f\\n\" > $outputFileList )";
	&HgAutomate::verbose(1, "$call\n");
	system("$call") == 0 || die("ERROR: $call failed\n");
	my $numFiles = `set -o pipefail; cat $outputFileList | wc -l`; chomp($numFiles);
	print "outputFileList $outputFileList created with $numFiles files\n";
	&HgAutomate::verbose(1, "bundlePslForChaining DONE\n");
}



##############################################################################################################################################
# cluster run to chain alignments to each target sequence.
##############################################################################################################################################
sub doChainRun {
	my $runDir = "$buildDir/TEMP_axtChain/run";
	&HgAutomate::verbose(1, "doChainRun ....\n");

	# Make sure we're starting clean and that previous step was run successfully
	testCleanState("doChainRun", $runDir, "$runDir/chain.done", "doCatRun", "$buildDir/TEMP_run.cat/cat.done");

	&HgAutomate::mustMkdir($runDir);
	&HgAutomate::verbose(1, "made $runDir\n");
 
	my $checkOutExists = "$runDir/chain/\$(file1).chain";
	&HgAutomate::makeGsub($runDir, "$runDir/chain.csh \$(file1) $checkOutExists");

	my $seq1Dir = $defVars{'SEQ1_DIR'};
	my $seq2Dir = $defVars{'SEQ2_DIR'};
	my $matrix = $defVars{'BLASTZ_Q'} ? "-scoreScheme=$defVars{BLASTZ_Q} " : "";
	my $minScore = "-minScore=$chainMinScore";
	my $linearGap = "-linearGap=$chainLinearGap";

	my $fh = &HgAutomate::mustOpen(">$runDir/chain.csh");
	print $fh  <<_EOF_
#!/bin/csh -ef
cat $runDir/splitPSL/\$1 | $axtChain -psl -verbose=0 $matrix $minScore $linearGap stdin $seq1Dir $seq2Dir stdout \\
| $chainAntiRepeat $seq1Dir $seq2Dir stdin \$2
_EOF_
;
	close($fh);

	# this splits the psls into chroms and bundles them and produces pslParts.lst 
	if (! $debug) {
		bundlePslForChaining("$buildDir/TEMP_pslParts", "$runDir/splitPSL", "$runDir/pslParts.lst", 50000000, 1);
	}
	# customize the $myparaRun variable depending upon the clusterType: 
	# request 15 GB of mem for the chaining jobs. Some take more than 5 GB apparently

	my $myParaRun = "
parallel_executor.py chainRun_$tDb$qDb jobList -q $chainingQueue --memoryMb $chainingMemory -e $nf_executor\n";
	
	my $whatItDoes = "Set up and perform cluster run to chain all co-linear local alignments.";
	my $bossScript = new HgRemoteScript("$runDir/doChainRun.csh", "", $runDir, $whatItDoes, $DEF);
	$bossScript->add(<<_EOF_
chmod a+x chain.csh
$HgAutomate::gensub2 pslParts.lst single gsub jobList
mkdir -p chain
$myParaRun

_EOF_
  );

	$bossScript->execute() if (! $debug);
	`touch $runDir/chain.done`;
	&HgAutomate::verbose(1, "doChainRun DONE\n");
}	# sub doChainRun {}




##############################################################################################################################################
# added by Michael Hiller
# merge the results from the chainRun step.
##############################################################################################################################################
sub doChainMerge {
	&HgAutomate::verbose(1, "doChainMerge ....\n");
	my $runDir = "$buildDir/TEMP_axtChain";
	my $outputChain = "$runDir/$tDb.$qDb.all.chain.gz";

	# Make sure we're starting clean and that previous step was run successfully
	testCleanState("doChainMerge", $runDir, "$runDir/chainMerge.done", "doChainRun", "$buildDir/TEMP_axtChain/run/chain.done");

	my $call="find $runDir/run/chain -name \"*.chain\" | $chainMergeSort -inputList=stdin | gzip -c > $outputChain";
	&HgAutomate::verbose(1, "$call\n");
	if (! $debug) {
		system("$call") == 0 || die("ERROR: $call failed\n");
	}
	&HgAutomate::verbose(1, "doChainMerge DONE\n");
	`touch $runDir/chainMerge.done`;
}	# sub doChainMerge {}



############################################################################################################################################
# added by Nikolai Hecker
# runs chainGapFiller
############################################################################################################################################
sub doFillChains {
	&HgAutomate::verbose(1, "doFillChains ....\n");

	if ($fillChains == 0) {
		print "skip filling chain gaps.\n";
		return;
	}
 	my $runDir = "$buildDir/TEMP_run.fillChain";
    
	# Make sure we're starting clean and that previous step was run successfully
	testCleanState("doFillChains", $runDir, "$runDir/fillChain.done", "doChainMerge", "$buildDir/TEMP_axtChain/chainMerge.done");

	# chain to be gap-filled
	my $inputChain = "$buildDir/TEMP_axtChain/$tDb.$qDb.all.chain.gz";
	croak "doFillChain: can't find input chain file $inputChain\n" if (! defined $inputChain && ! $debug);

	# output chain name
	my $filledChain = "$buildDir/TEMP_axtChain/$tDb.$qDb.allfilled.chain";
	&HgAutomate::verbose(1, "doFillChains: inputChain $inputChain  outputChain $filledChain\n");

	# create runDir and filledChains etc.
	&HgAutomate::mustMkdir($runDir);
	my $filledDir = "$runDir/filledChain";
	&HgAutomate::mustMkdir($filledDir);
	my $jobsDir = "$runDir/jobs";
	&HgAutomate::mustMkdir($jobsDir);

	## process chainGapfiller parameters
	my $lastzParameters = "K=$defVars{'FILL_BLASTZ_K'} L=$defVars{'FILL_BLASTZ_L'}";
	$lastzParameters .= " W=$defVars{'FILL_BLASTZ_W'}" if (defined($defVars{'FILL_BLASTZ_W'}));
	$lastzParameters .= " Q=$defVars{'FILL_BLASTZ_Q'}" if (defined($defVars{'FILL_BLASTZ_Q'}));
	$lastzParameters .= " M=$defVars{'FILL_BLASTZ_M'}" if (defined($defVars{'FILL_BLASTZ_M'}));
	$lastzParameters .= " T=$defVars{'FILL_BLASTZ_T'}" if (defined($defVars{'FILL_BLASTZ_T'}));

	my $scoreChainParameters = "";
	$scoreChainParameters .= " -scoreScheme=$defVars{'FILL_BLASTZ_Q'}" if (defined($defVars{'FILL_BLASTZ_Q'}));

	### specify chain, index, and 2bit file paths during cluster run
	my $param = "";
	$param .= " --chainMinScore $defVars{'FILL_CHAIN_MINSCORE'} --gapMaxSizeT $defVars{'FILL_GAPMAXSIZE_T'} --gapMaxSizeQ $defVars{'FILL_GAPMAXSIZE_Q'}";
	$param .= " --scoreThreshold $defVars{'FILL_INSERTCHAIN_MINSCORE'}" if (defined($defVars{'FILL_INSERTCHAIN_MINSCORE'}));
	$param .= " --gapMinSizeT $defVars{'FILL_GAPMINSIZE_T'} --gapMinSizeQ $defVars{'FILL_GAPMINSIZE_Q'}";
	$param .= " --unmask" if ($fillUnmask == 1);

	my $fillChainMemory = $defVars{'FILL_MEMORY'};
	my $fillPrepMemory = $defVars{'FILL_PREPARE_MEMORY'};
	
	#### --- set up para calls

	# para fill chain (major part of step)
	my $paraRun = "parallel_executor.py fillChain_$tDb$qDb jobList.txt -q medium --memoryMb $fillChainMemory -e $nf_executor\n";

	# para prepare chain filling (unzipped and build index)
	my $jobfprepare = "$runDir/jobList_prepare.txt";
	my $prepareScript = "$runDir/fillPrepare.sh";
	my $runFillScript = "$runDir/runChainGapFiller.sh";
	my $paraRunPrep = "parallel_executor.py $runDir/fillPrepare_$tDb$qDb $jobfprepare -q medium --memoryMb $fillPrepMemory --maxNumResubmission 1 -e $nf_executor\n";

	# para merge chains and gzip
	my $jobfmerge = "$runDir/jobList_merge.txt";
	my $mergeScript = "$runDir/fillMerge.sh";
	# my $paraRunMerge = "para make fillMerge_$tDb$qDb $jobfmerge -q medium -memoryMb $fillChainMemory\n";

	my $paraRunMerge = "parallel_executor.py $runDir/fillMerge_$tDb$qDb $jobfmerge -q medium --memoryMb $fillChainMemory -e $nf_executor\n";


	## write job preparation script	
	my $fh;
	open($fh, ">$prepareScript") || croak "ERROR! Can't write to fillChain prepare job list file '$prepareScript'.";
	print $fh "#!/usr/bin/env bash\nset -e\nset -o pipefail\n";
	print $fh "zcat $inputChain > $runDir/all.chain\n";
	# create jobs 
	print $fh "$splitChain_into_randomParts -c $runDir/all.chain -n $numFillJobs -p $jobsDir/infillChain_\n";
	print $fh "for f in $jobsDir/infillChain_*\n";
	print $fh "do\n";
	print $fh "\techo $runFillScript \$f >> $runDir/jobList.txt\n";
	print $fh "done\n";
	close($fh);

	### write script for calling runChainGapFiller on cluster 
	open($fh, ">$runFillScript") || croak "ERROR! Can't write to chainGapFiller script '$runDir/$runFillScript'.";
	print $fh "#!/usr/bin/env bash\nset -eo pipefail\n";
	print $fh "#get variables paths\n";
	print $fh "chainf=\$1\n";
	print $fh "rseq=$defVars{'SEQ1_DIR'}\n";
	print $fh "qseq=$defVars{'SEQ2_DIR'}\n";
#	print $fh "tdir=`mktemp -d`\n";
#	print $fh "trap \"echo \\\"cleanup tempdir \$tdir\\\"; rm -rf \$tdir\" EXIT\n";
	print $fh "tnamechainf=\${chainf##*/in}\n\n";
	print $fh "#run chainGapFiller\n";
	print $fh "echo \"..calling chainGapFiller: \"\n";
#	print $fh "$chainGapFiller --workdir \$tdir --chainExtractID $chainExtractID --lastz $lastz --axtChain $axtChain --chainSort $chainSort -c \$chainf -T2 \$rseq -Q2 \$qseq $param --lastzParameters '$lastzParameters ' | $scoreChain -linearGap=$chainLinearGap $scoreChainParameters stdin \$rseq \$qseq stdout | $chainSort stdin $filledDir/\$tnamechainf.chain\n";
	print $fh "$chainGapFiller --workdir $runDir --chainExtractID $chainExtractID --lastz $lastz --axtChain $axtChain --chainSort $chainSort -c \$chainf -T2 \$rseq -Q2 \$qseq $param --lastzParameters '$lastzParameters ' | $scoreChain -linearGap=$chainLinearGap $scoreChainParameters stdin \$rseq \$qseq stdout | $chainSort stdin $filledDir/\$tnamechainf.chain\n";
#	print $fh "echo \"..clean up temp directory: \"\n";
#	print $fh "rm -rf \$tdir\n";
	close($fh);

	## write merging script
	open($fh, ">$mergeScript") || croak "ERROR! Can't write to fillChain merge job list file '$mergeScript'.";
	print $fh "#!/usr/bin/env bash\nset -e\nset -o pipefail\n";
	print $fh "find $filledDir -type f -name \"*.chain\" -print | $chainMergeSort -inputList=stdin | gzip -c > $filledChain.gz\n";
	print $fh "rm -r $filledDir\n";
	print $fh "rm -r $jobsDir\n";
	# delete the unzipped chain file
	print $fh "rm -f $runDir/all.chain\n";
	close($fh);

	## create boss script that runs all commands
	my $whatItDoes = "Creates an index for a chain file; sets ups and runs a cluster job for filling gaps in chains and merges chains into new chain.";
	my $bossScript = newBash HgRemoteScript("$runDir/doFillChain.sh", "", $runDir, $whatItDoes, $DEF);
	
	#### create boss script
	$bossScript->add(<<_EOF_
# create job files and make scripts executable
# prepare script creates index and all job fills for chainFill jobs
echo \"$prepareScript\" > $jobfprepare
chmod 755 $prepareScript
# merge script merges chains
echo \"$mergeScript\" > $jobfmerge
chmod 755 $mergeScript			 
chmod 755 $runFillScript

### run para
$paraRunPrep

$paraRun

$paraRunMerge
_EOF_
    );
      
	# start chain gap filling
	$bossScript->execute() if (! $debug);
	`touch $runDir/fillChain.done`;
	&HgAutomate::verbose(1, "doFillChains DONE\n");
}



##############################################################################################################################################
# added by Michael Hiller
# remove random chain-breaking alignments using chainCleaner
##############################################################################################################################################
sub doCleanChains {
	&HgAutomate::verbose(1, "doCleanChains ....\n");
 	if ($cleanChains == 0) {
    		print "skip cleaning Chains\n";
		return;
	}

	# all or allpatched chains are in this runDir
 	my $runDir = "$buildDir/TEMP_axtChain";

	# Make sure we're starting clean and that previous step was run successfully
	my $inputChain = "";
	if ($fillChains == 1) {
		testCleanState("doCleanChains", $runDir, "$runDir/cleanChain.done", "doFillChains", "$buildDir/TEMP_run.fillChain/fillChain.done");
		$inputChain = "$buildDir/TEMP_axtChain/$tDb.$qDb.allfilled.chain.gz";
		croak "doCleanChains: can't find input chain $inputChain\n" if (! defined $inputChain && ! $debug);
	}else{
		testCleanState("doCleanChains", $runDir, "$runDir/cleanChain.done", "doChainMerge", "$buildDir/TEMP_axtChain/chainMerge.done");
		$inputChain = "$buildDir/TEMP_axtChain/$tDb.$qDb.all.chain.gz";
		croak "doCleanChains: can't find input chain $inputChain\n" if (! defined $inputChain && ! $debug);
	}
	# NOTE: input chain will be renamed below to $tDb.$qDb.beforeCleaning.chain.gz
	# output chain will be called all[filled].chain
	# at the end, it will be gzipped 
	my $outputChain = $inputChain;
	$outputChain =~ s/.gz$//g;

	# create the script that cleans the chains
	my $seq1Dir = $defVars{'SEQ1_DIR'};
	my $seq2Dir = $defVars{'SEQ2_DIR'};
	my $matrix = $defVars{'BLASTZ_Q'} ? "-scoreScheme=$defVars{BLASTZ_Q} " : "";
	my $linearGap = "-linearGap=$chainLinearGap";

	# request 60 GB
	my $paraCleanChain = "
parallel_executor.py cleanChain_$tDb$qDb jobListChainCleaner -q short --memoryMb $chainCleanMemory -e $nf_executor\n";

	open FILE, ">$runDir/jobListChainCleaner" or croak $!;
	print FILE "./cleanChains.csh\n";
	close FILE;
	
	system "mv ${inputChain} ${buildDir}/TEMP_axtChain/${tDb}.${qDb}.beforeCleaning.chain.gz" || croak "ERROR in chainClean: Cannot mv ${inputChain} ${buildDir}/TEMP_axtChain/${tDb}.${qDb}.beforeCleaning.chain.gz\n";

	my $fh;
	open($fh, ">$runDir/cleanChains.csh") || croak "ERROR! Can't write to chainClean script file '$runDir/cleanChains.csh'.";
	print $fh "#!/usr/bin/env bash\nset -e\nset -o pipefail\n";
	print $fh "$chainCleaner $buildDir/TEMP_axtChain/$tDb.$qDb.beforeCleaning.chain.gz $seq1Dir $seq2Dir $outputChain removedSuspects.bed $linearGap $matrix -tSizes=$defVars{SEQ1_LEN} -qSizes=$defVars{SEQ2_LEN} $defVars{'CLEANCHAIN_PARAMETERS'} >& $buildDir/TEMP_axtChain/log.chainCleaner\n";
	print $fh "gzip $outputChain\n";
	close($fh);

### Bogdan: this one is unstable
# I replaced it with solution used in other scripts
# my fh, open, print, close

# 	# cleanChains.csh runs the actual chainCleaner command
# 	my $fh = &HgAutomate::mustOpen(">$runDir/cleanChains.csh");
# 		my $fh;

# 	# input chain will be renamed to $tDb.$qDb.beforeCleaning.chain.gz
# 	print $fh <<_EOF_
# #!/bin/csh -ef

# # /bin/mv ${inputChain} ${buildDir}/TEMP_axtChain/${tDb}.${qDb}.beforeCleaning.chain.gz | true

# time $chainCleaner $buildDir/TEMP_axtChain/$tDb.$qDb.beforeCleaning.chain.gz $seq1Dir $seq2Dir $outputChain removedSuspects.bed $linearGap $matrix -tSizes=$defVars{SEQ1_LEN} -qSizes=$defVars{SEQ2_LEN} $defVars{'CLEANCHAIN_PARAMETERS'} >& log.chainCleaner

# gzip $outputChain
# _EOF_
# ;
# 	close($fh);

	my $whatItDoes = "It performs a chainCleaner run on the cluster.";
	# script that we execute. This pushes the chainCleaner cluster job.
	my $bossScript = newBash HgRemoteScript("$runDir/doCleanChain.sh", "", $runDir, $whatItDoes, $DEF);
	$bossScript->add(<<_EOF_
# clean chain
chmod a+x cleanChains.csh
$paraCleanChain
_EOF_
	  );

	$bossScript->execute() if (! $debug);
	`touch $runDir/cleanChain.done`;
	&HgAutomate::verbose(1, "doCleanChains DONE\n");
}  # do clean chains



##############################################################################################################################################
# Produce cleanUp.csh to remove intermediate files.
##############################################################################################################################################
sub cleanup {
	&HgAutomate::verbose(1, "cleanup ....\n");
	if ($keepTempFiles == 1) {
		&HgAutomate::verbose(1, "-keepTempFiles is set. Therefore, no cleanup of temp files in $clusterRunDir\n");
		return; 
	}

	my $runDir = $buildDir;

	my $whatItDoes = "Cleans up files after a successful $0 run.";  # Bogdan: leave quotes
	my $bossScript = new HgRemoteScript("$buildDir/cleanUp.csh", "", $runDir, $whatItDoes, $DEF);
	$bossScript->add(<<_EOF_
rm -fr TEMP_run.lastz/ TEMP_run.cat/ TEMP_run.fillChain/ TEMP_pslParts/ TEMP_axtChain/ TEMP_psl/ cleanUp.csh 
_EOF_
	);

	# we do not automatically cleanup. Just produce the cleanUp.csh file
	system "chmod +x $buildDir/cleanUp.csh" || croak "ERROR in cleanup: Cannot chmod +x $buildDir/cleanUp.csh\n";
	&HgAutomate::verbose(1, "cleanup DONE\n");
}



##################################################################################################################################################
# -- main --
##################################################################################################################################################

&checkOptions();

&usage(1) if ($#ARGV < 0);
$secondsStart = `set -o pipefail; date "+%s"`;
chomp $secondsStart;
($DEF) = @ARGV;

&loadDef($DEF);
&checkDef();
croak "\n-clusterRunDir must specify a full path.\n" if ($clusterRunDir !~ /^\//);

print "Will run chainGapFiller. \n" if ($fillChains == 1);
print "Will run chainCleaner " if ($cleanChains == 1);
if (exists $defVars{'CLEANCHAIN_PARAMETERS'}) {
	print "with parameters: $defVars{'CLEANCHAIN_PARAMETERS'}\n";
}else{
	print "\n";
}

$chainingQueue = $defVars{'CHAININGQUEUE'} if (exists $defVars{'CHAININGQUEUE'});
croak "ERROR: variable CHAININGQUEUE in DEF $chainingQueue is neither long/medium/short\n" if (! ($chainingQueue eq "long" || $chainingQueue eq "medium" || $chainingQueue eq "short"));
$chainingMemory = defined($defVars{'CHAININGMEMORY'}) ? $defVars{'CHAININGMEMORY'} : $chainingMemory;
$chainCleanMemory = defined($defVars{'CHAINCLEANMEMORY'}) ? $defVars{'CHAINCLEANMEMORY'} : $chainCleanMemory;

print "max number of lastz cluster jobs: $maxNumLastzJobs\n";

my $date = `set -o pipefail; date +%Y-%m-%d`;
chomp $date;
$buildDir = $clusterRunDir;
&HgAutomate::mustMkdir($buildDir) if (! -d $buildDir);
&HgAutomate::verbose(1, "The $0 run will be performed in directory $buildDir. All temp files will be written there.\n");
&HgAutomate::run("cp $DEF $buildDir/DEF") if (! -e "$buildDir/DEF");

# now run all steps
$stepper->execute();

# move final file into buildDir
my $finalChainFile = "$tDb.$qDb.all.chain.gz";
$finalChainFile = "$tDb.$qDb.allfilled.chain.gz" if ($fillChains == 1);
if (! $debug) {
	system "mv $buildDir/TEMP_axtChain/$finalChainFile $buildDir" || croak "ERROR: failed to move the final chain file $finalChainFile to $buildDir\n";
}

# produce cleanup file
cleanup();

# get total runtime 
$secondsEnd = `set -o pipefail; date "+%s"`;
chomp $secondsEnd;
my $elapsedSeconds = $secondsEnd - $secondsStart;
my $elapsedMinutes = int($elapsedSeconds/60);
$elapsedSeconds -= $elapsedMinutes * 60;

print "\n *** All done !  Elapsed time: ${elapsedMinutes}m${elapsedSeconds}s\n";
print "The final chain file is: $buildDir/$finalChainFile\n";
print "Run cleanUp.csh to cleanup the temporary files and directories\n" if (! $keepTempFiles);
