#!/usr/bin/env perl 

use warnings;
use strict;
use Data::Dumper;
use Getopt::Long;
use File::Basename qw/basename dirname/;
use File::Copy qw/mv/;
use File::Path qw/rmtree/;
use File::Find qw/find/;
use Net::FTP;
use Cwd qw/getcwd/;

use version 0.77;
our $VERSION = '0.1.2';

our $baseUrl = "ftp.ncbi.nlm.nih.gov";
our $localFiles = $ENV{HOME} . "/.pdtk";
our $defaultDb = "$localFiles/pdtk.sqlite3";

local $0 = basename $0;
sub logmsg{local $0=basename $0; print STDERR "$0: @_\n";}
exit(main());

sub main{
  my $settings={};
  GetOptions($settings,qw(sample1=s sample2=s db=s within=i amr query debug version find-target=s list download help)) or die $!;
  usage() if($$settings{help});

  # Set up where the database lives
  $$settings{db} //= $defaultDb;
  $localFiles = dirname($$settings{db});

  if($$settings{version}){
    print "$0 v$VERSION\n";
    return 0;
  }

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
    my @header = keys(%{ $$res{$sampleHit[0]} });
    print join("\t", @header)."\n";
    for my $s(@sampleHit){
      my $line;
      for my $h(@header){
        $$res{$s}{$h} //= "NULL";
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

  my $db = $$settings{db};
  if(!-e $db){
    die "ERROR: no database found at $db. Please run $0 --download to correct";
  }
  logmsg "Reading from $db";

  my $cmd = qq(sqlite3 $db -separator "\t" --header '
  SELECT *
  FROM SNP_distances AS snps
  WHERE sample_name_1 LIKE "$query" 
    OR sample_name_2 LIKE "$query" 
    OR biosample_acc_1 LIKE "$query"
    OR biosample_acc_2 LIKE "$query"
    OR target_acc_1 LIKE "$query" 
    OR target_acc_2 LIKE "$query"
    OR gencoll_acc_1 LIKE "$query"
    OR gencoll_acc_2 LIKE "$query"
    OR PDS_acc LIKE "$query"');
  
  # If we want AMR results, add in a LEFT JOIN statement
  if($$settings{amr}){
    $cmd =~ s/(FROM SNP_distances AS snps)/$1\nLEFT JOIN amr_metadata AS amr\nON snps.target_acc_1 = amr.target_acc OR snps.target_acc_2 = amr.target_acc\n/;
  }

  system($cmd);

  return 1;
}

sub querySample{
  my($settings) = @_;

  my $sample1 = $$settings{sample1} 
    or die "ERROR: required parameter --sample1 not found";

  # Check to make sure database is there
  my $db = $$settings{db};
  if(!-e $db){
    die "ERROR: no database found at $db. Please run $0 --download to correct";
  }

  my $within = $$settings{within} || 1000;

  logmsg "Reading from $db";

  my $cmd = qq(sqlite3 $db -separator "\t" --header '
    SELECT *
    FROM SNP_distances AS snps
    WHERE (target_acc_1 = "$sample1" OR target_acc_2 = "$sample1")
      AND compatible_distance+0 <= $within
    ');

  # If the second sample is provided, then ignore --within
  if($$settings{sample2}){
    $cmd = qq(sqlite3 $db -separator "\t" --header '
    SELECT *
    FROM SNP_distances AS snps
    WHERE (target_acc_1 = "$sample1" AND target_acc_2 = "$$settings{sample2}")
      OR (target_acc_2 = "$sample1" AND target_acc_1 = "$$settings{sample2}")
    ');
  }
  
  # If we want AMR results, add in a LEFT JOIN statement
  if($$settings{amr}){
    $cmd =~ s/(FROM SNP_distances AS snps)/$1\nLEFT JOIN amr_metadata AS amr\nON snps.target_acc_1 = amr.target_acc OR snps.target_acc_2 = amr.target_acc\n/;
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

  if($$settings{debug}){
    splice(@$taxa, 2,1000);
    logmsg "DEBUGGING: just keeping two taxa: ".join(" ",@$taxa);
  }

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

sub createBlankDb{
  my($db, $settings) = @_;

  qx(sqlite3 \Q$db\E '
    -- Table: all_isolates
    CREATE TABLE all_isolates (
        target_acc TEXT PRIMARY KEY,
        min_dist_same INTEGER,
        min_dist_opp INTEGER,
        PDS_acc TEXT
    );

    -- Table: cluster_list
    CREATE TABLE cluster_list (
        PDS_acc TEXT,
        target_acc TEXT,
        biosample_acc TEXT,
        gencoll_acc TEXT,
        PRIMARY KEY (PDS_acc, target_acc)
    );

    -- Table: new_isolates
    CREATE TABLE new_isolates (
        target_acc TEXT PRIMARY KEY,
        min_dist_same INTEGER,
        min_dist_opp INTEGER,
        PDS_acc TEXT
    );

    -- Table: SNP_distances
    CREATE TABLE SNP_distances (
        target_acc_1 TEXT,
        biosample_acc_1 TEXT,
        gencoll_acc_1 TEXT,
        sample_name_1 TEXT,
        target_acc_2 TEXT,
        biosample_acc_2 TEXT,
        gencoll_acc_2 TEXT,
        sample_name_2 TEXT,
        PDS_acc TEXT,
        aligned_bases_pre_filtered INTEGER,
        aligned_bases_post_filtered INTEGER,
        delta_positions_unambiguous INTEGER,
        delta_positions_one_N INTEGER,
        delta_positions_both_N INTEGER,
        informative_positions INTEGER,
        total_positions INTEGER,
        pairwise_bases_post_filtered INTEGER,
        compatible_distance INTEGER,
        compatible_positions INTEGER,
        PRIMARY KEY (target_acc_1, target_acc_2, PDS_acc)
    );

    -- Table: amr_metadata
    CREATE TABLE amr_metadata (
        FDA_lab_id TEXT,
        HHS_region TEXT,
        IFSAC_category TEXT,
        LibraryLayout TEXT,
        PFGE_PrimaryEnzyme_pattern TEXT,
        PFGE_SecondaryEnzyme_pattern TEXT,
        Platform TEXT,
        Runasm_acc TEXT,
        asm_level TEXT,
        asm_stats_contig_n50 TEXT,
        asm_stats_length_bp TEXT,
        asm_stats_n_contig TEXT,
        assembly_method TEXT,
        attribute_package TEXT,
        bioproject_acc TEXT,
        bioproject_center TEXT,
        biosample_acc TEXT,
        isolate_identifiers TEXT,
        collected_by TEXT,
        collection_date TEXT,
        epi_type TEXT,
        fullasm_id TEXT,
        geo_loc_name TEXT,
        host TEXT,
        host_diseaseisolation_source TEXT,
        lat_lon TEXT,
        ontological_term TEXT,
        outbreak TEXT,
        sample_name TEXT,
        scientific_name TEXT,
        serovar TEXT,
        source_type TEXT,
        species_taxid TEXT,
        sra_center TEXT,
        sra_release_date TEXT,
        strain TEXT,
        sequenced_by TEXT,
        project_name TEXT,
        target_acc TEXT PRIMARY_KEY,
        target_creation_date TEXT,
        taxid TEXT,
        wgs_acc_prefix TEXT,
        wgs_master_acc TEXT,
        minsame TEXT,
        mindiff TEXT,
        computed_types TEXT,
        number_drugs_resistant TEXT,
        number_drugs_intermediate TEXT,
        number_drugs_susceptible TEXT,
        number_drugs_tested TEXT,
        number_amr_genes TEXT,
        number_core_amr_genes TEXT,
        AST_phenotypes TEXT,
        AMR_genotypes TEXT,
        AMR_genotypes_core TEXT,
        number_stress_genes TEXT,
        stress_genotypes TEXT,
        number_virulence_genes INTEGER,
        virulence_genotypes TEXT,
        amrfinder_version TEXT,
        refgene_db_version TEXT,
        amrfinder_analysis_type TEXT,
        amrfinder_applied TEXT
    );

  ');
  
  return $db;
}

sub indexAll{
  my($settings) = @_;

  my $doneMarker = "$localFiles/.03_index";

  if(-e $doneMarker){
    logmsg "NOTE: files have already been compressed. Remove $doneMarker to release the lock.";
    return 0;
  }

  my $db = "$localFiles/pdtk.sqlite3";
  unlink($db);
  createBlankDb($db, $settings);

  find({
    wanted=>sub{
      if($_ =~ /\.(\w+)$/){
        my $ext = $1;
        return if($ext !~ /tsv/);
      } else {
        return;
      }

      logmsg "Indexing $File::Find::name";
      my $sqlXopts = "-separator '\t' $db";
      my $importXopts = "--skip 1";
      my $cmd = "echo 'INTERNAL ERROR: no command supplied with file $File::Find::name.'; exit 2;";
      if($_ =~ /reference_target.all_isolates.tsv/){
        $cmd = qq(sqlite3 $sqlXopts '.import $importXopts $File::Find::name all_isolates');
      }
      elsif($_ =~ /reference_target.cluster_list.tsv/){
        $cmd = qq(sqlite3 $sqlXopts '.import $importXopts $File::Find::name cluster_list');
      }
      elsif($_ =~ /reference_target.new_isolates.tsv/){
        $cmd = qq(sqlite3 $sqlXopts '.import $importXopts $File::Find::name new_isolates');
      }
      elsif($_ =~ /reference_target.SNP_distances.tsv/){
        $cmd = qq(sqlite3 $sqlXopts '.import $importXopts $File::Find::name SNP_distances');
      }
      # amr is too much for right now
      elsif($_ =~ /amr.metadata.tsv/){
        return;
        $cmd = qq(sqlite3 $sqlXopts '.import $importXopts $File::Find::name amr_metadata');
      }
      # Don't import straight metadata
      elsif($_ =~ /metadata.tsv/){
        return;
      }
      # Don't import the exceptions file
      elsif($_ =~ /exceptions.tsv/){
        return;
      }

      system($cmd);
      my $exit_code = $? << 8;
      if($exit_code){
        logmsg "COMMAND was:\n  $cmd";
        die "ERROR: Could not index into sqlite3: $File::Find::name: $!";
      }
      unlink($File::Find::name) if(!$$settings{debug});
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
  --version          Print the version and exit

  OPTIONS
  --db       DBPATH  Location of sqlite database (default: $defaultDb)
                     If --download, temporary files will be placed in
                     the same directory that the database is in.
  --sample1  S1      PDT accession to query from
  --within   X       Number of SNPs to query away from S1
  --sample2  S2      PDT accession to query from S1
  --amr              When querying, also include AMR results

  \n";
  exit 0;
}

