#!/usr/bin/perl

package Globals;
use Exporter;
use Math::BigInt;
use Math::BigFloat;
use Math::Complex;
use Math::Trig;
our @ISA = ('Exporter');

my $genomePath = $ENV{'genomePath'};

# globals
our $verbose = 0;
our $CLUSTALPath = "$genomePath/bin/x86_64/";
our $CLUSTALBinary = $CLUSTALPath . "/clustalw2";

# downloaded from http://www.kazusa.or.jp/codon/cgi-bin/showcodon.cgi?species=Homo+sapiens+[gbpri]
our %CodonUsage = (
"TTT" => "17.5", "TCT" => "15.1", "TAT" => "12.1", "TGT" => "10.5",
"TTC" => "20.4", "TCC" => "17.7", "TAC" => "15.3", "TGC" => "12.6",
"TTA" => "7.6",  "TCA" => "12.2", "TAA" => "1.0",  "TGA" => "1.5",
"TTG" => "12.9", "TCG" => "4.4",  "TAG" => "0.8",  "TGG" => "13.2",

"CTT" => "13.1", "CCT" => "17.5", "CAT" => "10.8", "CGT" => "4.6",
"CTC" => "19.6", "CCC" => "19.8", "CAC" => "15.1", "CGC" => "10.5",
"CTA" => " 7.2", "CCA" => "16.9", "CAA" => "12.2", "CGA" => "6.2",
"CTG" => "39.8", "CCG" => "6.9",  "CAG" => "34.2", "CGG" => "11.5",

"ATT" => "15.9", "ACT" => "13.1", "AAT" => "16.9", "AGT" => "12.1",
"ATC" => "20.9", "ACC" => "18.9", "AAC" => "19.1", "AGC" => "19.5",
"ATA" => "7.4",  "ACA" => "15.0", "AAA" => "24.3", "AGA" => "12.1",
"ATG" => "22.1", "ACG" => "6.1",  "AAG" => "31.9", "AGG" => "11.9",

"GTT" => "11.0", "GCT" => "18.5", "GAT" => "21.8", "GGT" => "10.8",
"GTC" => "14.5", "GCC" => "27.9", "GAC" => "25.2", "GGC" => "22.3",
"GTA" => "7.1",  "GCA" => "15.9", "GAA" => "28.8", "GGA" => "16.5",
"GTG" => "28.2", "GCG" => "7.4",  "GAG" => "39.6", "GGG" => "16.4");

%GeneticCode = qw (TTT Phe TTC Phe TTA Leu TTG Leu TCT Ser TCC Ser TCA Ser TCG Ser TAT Tyr TAC Tyr TAA Ter TAG Ter TGT Cys TGC Cys TGA Ter TGG Trp CTT Leu CTC Leu CTA Leu CTG Leu CCT Pro CCC Pro CCA Pro CCG Pro CAT His CAC His CAA Gln CAG Gln CGT Arg CGC Arg CGA Arg CGG Arg ATT Ile ATC Ile ATA Ile ATG Met ACT Thr ACC Thr ACA Thr ACG Thr AAT Asn AAC Asn AAA Lys AAG Lys AGT Ser AGC Ser AGA Arg AGG Arg GTT Val GTC Val GTA Val GTG Val GCT Ala GCC Ala GCA Ala GCG Ala GAT Asp GAC Asp GAA Glu GAG Glu GGT Gly GGC Gly GGA Gly GGG Gly);

our @EXPORT = qw($verbose %CodonUsage %GeneticCode $CLUSTALPath $CLUSTALBinary);
