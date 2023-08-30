#!/usr/bin/env perl 

use warnings;
use strict;
use Data::Dumper;
use Getopt::Long;
use File::Basename qw/basename/;
use File::Copy qw/mv/;
use File::Path qw/rmtree/;
use File::Find qw/find/;
use Net::FTP;
use Cwd qw/getcwd/;

use version 0.77;
our $VERSION = '0.1.1';

our $baseUrl = "ftp.ncbi.nlm.nih.gov";
our $localFiles = $ENV{HOME} . "/.pdtk";

local $0 = basename $0;
sub logmsg{local $0=basename $0; print STDERR "$0: @_\n";}
exit(main());

sub main{
  my $settings={};
  GetOptions($settings,qw(sample1=s sample2=s within=i query taxon=s find-target=s list download help)) or die $!;
  usage() if($$settings{help});

  # Subcommand: List all taxa
  if($$settings{list}){
    my $list = fetchListOfTaxa($settings);
    print $_."\n" for(@$list);

    return 0;
  }

  # Subcommand: download whole database
  if($$settings{download}){
    downloadAll($settings);
    indexAll($settings);
    #compressAll($settings);
    return 0;
  }

  # Subcommand: find target
  if($$settings{'find-target'}){
    findTarget($$settings{'find-target'}, $settings);
    return 0;
  }

  # Subcommand: query
  if($$settings{query}){
    my $res = querySample($settings);
    my @sampleHit = sort keys(%$res);

    # Print the header from the db
    my @header = keys($$res{$sampleHit[0]});
    print join("\t", @header)."\n";
    for my $s(@sampleHit){
      my $line;
      for my $h(@header){
        $line .= $$res{$s}{$h} ."\t";
      }
      $line =~ s/\t$//; # remove last tab
      print $line ."\n";
    }
    return 0;
  }

  return 0;
}

sub findTarget{
  my($query, $settings) = @_;

  # Check to make sure database is there
  if(!-d "$localFiles/ftp.ncbi.nlm.nih.gov"){
    die "ERROR: no database found at $localFiles. Please run $0 --download to correct";
  }
  if(!$$settings{taxon}){
    die "ERROR: required parameter --taxon missing";
  }

  my $clustersDir = "$localFiles/ftp.ncbi.nlm.nih.gov/pathogen/Results/$$settings{taxon}/latest_snps/Clusters";
  my $db = (glob("$clustersDir/*.reference_target.SNP_distances.tsv.sqlite3"))[0];
  if(!-e $db){
    die "ERROR: could not find expected sqlite3 distance file in $clustersDir with suffix .reference_target.SNP_distances.tsv.sqlite3";
  }
  logmsg "Reading from $db";

  my $cmd = qq(sqlite3 $db -separator "\t" --header 'SELECT * FROM SNP_distances
  WHERE sample_name_1 LIKE "$query" 
    OR sample_name_2 LIKE "$query" 
    OR biosample_acc_1 LIKE "$query"
    OR biosample_acc_2 LIKE "$query"
    OR target_acc_1 LIKE "$query" 
    OR target_acc_2 LIKE "$query"
    OR gencoll_acc_1 LIKE "$query"
    OR gencoll_acc_2 LIKE "$query"
    OR PDS_acc LIKE "$query"');
  #logmsg $cmd;
  system($cmd);
  # sample_name, biosample_acc, target_acc, gencoll_acc, PDS_acc

  return 1;
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
  my $db = (glob("$clustersDir/*.reference_target.SNP_distances.tsv.sqlite3"))[0];
  if(!-e $db){
    die "ERROR: could not find expected sqlite3 distance file in $clustersDir with suffix .reference_target.SNP_distances.tsv.sqlite3";
  }
  logmsg "Reading from $db";

  my $cmd = qq(sqlite3 $db -separator "\t" --header 'SELECT * FROM SNP_distances WHERE (target_acc_1 = "$sample1" OR target_acc_2 = "$sample1") AND compatible_distance+0 <= $within ');

  # If the second sample is provided, then ignore --within
  if($$settings{sample2}){
    $cmd = qq(sqlite3 $db -separator "\t" --header 'SELECT * FROM SNP_distances WHERE (target_acc_1 = "$sample1" AND target_acc_2 = "$$settings{sample2}") OR (target_acc_2 = "$sample1" AND target_acc_1 = "$$settings{sample2}")' );
  }
  
  my @res = `$cmd`;
  if(!@res){
    logmsg "WARNING: no hits found with query\n  $cmd";
    return {};
  }

  chomp(@res);
  my @header = split(/\t/, shift(@res));

  # Put it into a hash of hashes where sample2 is the key
  my %resHashes;
  for(my $i=0;$i<@res;$i++){
    my %F;
    my @F = split(/\t/, $res[$i]);
    for(my $j=0;$j<@header;$j++){
      $F{$header[$j]} = $F[$j];
    }

    my $key = $F{target_acc_1};
    if($key eq $sample1){
      $key = $F{target_acc_2};
    }

    $resHashes{$key} = \%F;
  }

  return \%resHashes;
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

sub indexAll{
  my($settings) = @_;

  my $doneMarker = "$localFiles/.03_index";

  if(-e $doneMarker){
    logmsg "NOTE: files have already been compressed. Remove $doneMarker to release the lock.";
    return 0;
  }

  # TODO be smarter about combining the tsv files in Clusters directories
  find({
    wanted=>sub{
      if($_ =~ /\.(\w+)$/){
        my $ext = $1;
        return if($ext !~ /tsv/);
      } else {
        return;
      }
      logmsg "Indexing $File::Find::name";
      my $cmd = "sqlite3 --header -separator \$'\\t' $File::Find::name.sqlite3  '.import $File::Find::name SNP_distances'";
      system($cmd);
      my $exit_code = $? << 8;
      if($exit_code){
        logmsg "COMMAND was:\n  $cmd";
        die "ERROR: Could not index into sqlite3: $File::Find::name: $!";
      }
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
  --find-target S1   Find rows matching an accession.
                     Useful for finding PDT accessions.
                     Searches fields: sample_name, biosample_acc, target_acc, gencoll_acc, PDS_acc
                     Use SQLite syntax for wildcards, e.g., %
  --help             This useful help menu

  OPTIONS
  --taxon    TAXON   Limit the query to this taxon
  --sample1  S1      PDT accession to query from
  --within   X       Number of SNPs to query away from S1
  --sample2  S2      PDT accession to query from S1

  \n";
  exit 0;
}

