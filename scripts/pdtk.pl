#!/usr/bin/env perl 

use warnings;
use strict;
use Data::Dumper;
use Getopt::Long;
use IO::Uncompress::AnyUncompress qw/anyuncompress $AnyUncompressError/;
use File::Basename qw/basename/;
use File::Copy qw/mv/;
use File::Path qw/rmtree/;
use File::Find qw/find/;
use Net::FTP;
#use Net::FTP::Recursive;
use LWP::Simple qw/get head/;
use Cwd qw/getcwd/;
use IO::Compress::Gzip qw(gzip $GzipError) ;

use version 0.77;
our $VERSION = '0.1.1';

our $baseUrl = "ftp.ncbi.nlm.nih.gov";
our $localFiles = $ENV{HOME} . "/.pdtk";

local $0 = basename $0;
sub logmsg{local $0=basename $0; print STDERR "$0: @_\n";}
exit(main());

sub main{
  my $settings={};
  GetOptions($settings,qw(sample1=s sample2=s within=i query taxon=s list download help)) or die $!;
  usage() if($$settings{help});

  ##### subcommands

  # Subcommand: List all taxa
  if($$settings{list}){
    my $list = fetchListOfTaxa($settings);
    print $_."\n" for(@$list);

    return 0;
  }

  # Subcommand: download whole database
  if($$settings{download}){
    downloadAll($settings);
    compressAll($settings);
    return 0;
  }

  if($$settings{query}){
    querySample($settings);
    return 0;
  }

  ######

  return 0;
}

sub querySample{
  my($settings) = @_;

  my $sample1 = $$settings{sample1} 
    or die "ERROR: required parameter --sample1 not found";

  # Check to make sure database is there
  if(!-d "$localFiles/ftp.ncbi.nlm.nih.gov"){
    die "ERROR: no database found at $localFiles. Please run $0 --download to correct";
  }

  if(!$$settings{taxon}){
    die "ERROR: required parameter --taxon missing";
  }
  
  my $within = $$settings{within} || 1000;

  my $clustersDir = "$localFiles/ftp.ncbi.nlm.nih.gov/pathogen/Results/$$settings{taxon}/latest_snps/Clusters";
  my $snpsFile = (glob("$clustersDir/*.reference_target.SNP_distances.tsv.gz"))[0];
  if(!-e $snpsFile){
    die "ERROR: could not find expected SNP distance file in $clustersDir with suffix .reference_target.SNP_distances.tsv";
  }
  logmsg "Reading from $snpsFile";

  my $z = IO::Uncompress::AnyUncompress->new($snpsFile)
      or die "IO::Uncompress::AnyUncompress failed on $snpsFile: $AnyUncompressError\n";
  my $header = $z->getline();
  chomp($header);
  my @header = split(/\t/, $header);
  while(my $line = <$z>){
    chomp $line;
    my @F = split(/\t/, $line);
    my %F;
    for(my $i=0;$i<@header;$i++){
      $F{$header[$i]} = $F[$i];
    }

    if($F{target_acc_1} eq $sample1 || $F{target_acc_2} eq $sample1){

      if($F{compatible_distance} <= $$settings{within}){
        print $line ."\n";
      }

    }
  }
  
}

sub downloadAll{
  my($settings) = @_;

  my $doneMarker = "$localFiles/.01_downloaded";

  if(-e $doneMarker){
    logmsg "NOTE: files have already been downloaded. Remove $doneMarker to release the lock.";
    return 0;
  }

  my $taxa = fetchListOfTaxa($settings);

  logmsg "Downloading to $localFiles ...";

  # Make the new local dir
  if(! -d $localFiles){
    mkdir($localFiles)
      or die "ERROR: could not make local directory $localFiles: $!";
  }

  # In this block, we are inside of $localFiles
  {
    my $cwd = getcwd;
    chdir($localFiles);
    for my $TAXON(@$taxa){
      logmsg "Downloading $TAXON";
      system("wget --continue -r \\
          -X/pathogen/Results/$TAXON/latest_snps/SNP_trees \\
          -X/pathogen/Results/$TAXON/latest_snps/Trees \\
          ftp://ftp.ncbi.nlm.nih.gov/pathogen/Results/$TAXON/latest_snps/ \\
          > $TAXON.log 2>&1
        ");
      my $exit_code = $? << 8;
      if($exit_code){
        die "ERROR: downloading for taxon $TAXON: $!\n  Error log can be found in $localFiles/$TAXON.log";
      }
    }

    chdir($cwd) or die "ERROR: could not return to original directory $cwd: $!";
  }

  # Mark as complete
  open(my $fh, ">", $doneMarker) or logmsg "WARNING: could not create file $doneMarker: $!";
  close $fh;

  return 1;
}

sub compressAll{
  my($settings) = @_;

  my $doneMarker = "$localFiles/.02_compress";

  if(-e $doneMarker){
    logmsg "NOTE: files have already been compressed. Remove $doneMarker to release the lock.";
    return 0;
  }

  find({
    wanted=>sub{
      if($_ =~ /\.(\w+)$/){
        my $ext = $1;
        return if($ext !~ /tsv/);
      } else {
        return;
      }
      logmsg "Compressing $_";
      gzip(
        $File::Find::name => $File::Find::name . ".gz"
      ) or die "gzip failed on $File::Find::name: $GzipError\n";
      unlink($File::Find::name);
    },
    no_chdir=>1}, "$localFiles/ftp.ncbi.nlm.nih.gov/pathogen/Results"
  );


  # Mark as complete
  open(my $fh, ">", $doneMarker) or logmsg "WARNING: could not create file $doneMarker: $!";
  close $fh;

  return 1;
}

sub fetchListOfTaxa{
  my($settings) = @_;

  my @list;

  my $ftp = Net::FTP->new($baseUrl)
    or die "Cannot connect to $baseUrl: $@";

  $ftp->login("anonymous","-anonymous@")
    or die "Cannot login ".$ftp->message;

  $ftp->cwd("/pathogen/Results")
    or die "Cannot change working directory :".$ftp->message;

  @list = $ftp->ls;

  # sort and filter
  @list = sort {$a cmp $b}
    grep {! /WARNING.txt|BioProject_hierarchy/i }
    @list;

  return \@list;
}

sub usage{
  print "$0: interacts with the NCBI Pathogens Portal
  Usage: $0 [options] 
  SUBCOMMANDS
  --list             List which taxa are available
  --download         Download data to ~/.pdtk
  --query            Query from S1
  --clean            (TODO) clean up ~/.pdtk
  --help             This useful help menu

  OPTIONS
  --taxon    TAXON   Limit the query to this taxon
  --sample1  S1      PDT accession to query from
  --within   X       Number of SNPs to query away from S1
  --sample2  S2      PDT accession to query from S1

  \n";
  exit 0;
}

