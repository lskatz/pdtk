#!/usr/bin/env perl 

use warnings;
use strict;
use Data::Dumper;
use Getopt::Long;
use File::Basename qw/basename dirname/;
use File::Copy qw/mv/;
use File::Path qw/rmtree/;
use File::Find qw/find/;
use List::Util qw/max/;
use Net::FTP;
use Cwd qw/getcwd/;

use version 0.77;
our $VERSION = '0.1.6';

our $baseUrl = "ftp.ncbi.nlm.nih.gov";
our $localFiles = $ENV{HOME} . "/.pdtk";
our $defaultDb = "$localFiles/pdtk.sqlite3";

local $0 = basename $0;
sub logmsg{local $0=basename $0; print STDERR "$0: @_\n";}
exit(main());

sub main{
  usage() if(!@ARGV);

  my $settings={};
  GetOptions($settings,qw(sample1=s sample2=s db=s limit=i within=i amr query debug version find-target=s list taxa=s download clean veryclean help)) or die $!;
  usage() if($$settings{help});

  $$settings{limit} ||= 0;
  $$settings{taxa}  ||= '';

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

  # Clean up the download directory
  elsif($$settings{clean} || $$settings{veryclean}){
    cleanup($settings);
    return 0;
  }

  # Subcommand: download whole database
  elsif($$settings{download}){
    downloadAll($settings);
    indexAll($settings);
    #compressAll($settings);
    return 0;
  }

  # Subcommand: find target
  elsif($$settings{'find-target'}){
    findTarget($$settings{'find-target'}, $settings);
    return 0;
  }

  # Subcommand: query
  elsif($$settings{query}){
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

sub cleanup{
  my($settings) = @_;
  find({wanted=>sub{
      my @F = split(/\./, basename($File::Find::name));

      # If this is one of the files I fixed in fixSpreadsheet(), rm it
      if($F[-1] eq 'fixed'){
        _rm($File::Find::name);
      }

      # I don't use the xml files for anything in the toolkit
      elsif($F[-1] eq 'xml'){
        _rm($File::Find::name);
      }

      # I don't use the exeption files in the toolkit
      elsif($File::Find::name =~ /exceptions.tsv/){
        _rm($File::Find::name);
      }

      elsif($$settings{veryclean}){
        if($F[-1] eq 'tsv'){
          _rm($File::Find::name);
        }
      }
    },
    no_chdir=>1}, "$localFiles/ftp.ncbi.nlm.nih.gov/pathogen/Results"
  );

  if($$settings{veryclean}){
    _rm("$localFiles/.01_downloaded");
    for my $f(glob("$localFiles/cat/*.tsv")){
      _rm($f);
    }
  }

  return 1;
}

sub _rm{
  my($f, $settings) = @_;
  if($$settings{debug}){
    logmsg "NOTE: --debug was set. I would have unlinked $f";
  } else {
    unlink($f) or logmsg "WARNING: could not unlink $f: $!";
  }
  return 1;
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

  my $cmd = qq(sqlite3 $db -separator "\t" -header "
  SELECT *
  FROM SNP_distances AS snps
  WHERE sample_name_1 LIKE '$query' 
    OR sample_name_2 LIKE '$query' 
    OR biosample_acc_1 LIKE '$query'
    OR biosample_acc_2 LIKE '$query'
    OR target_acc_1 LIKE '$query' 
    OR target_acc_2 LIKE '$query'
    OR gencoll_acc_1 LIKE '$query'
    OR gencoll_acc_2 LIKE '$query'
    OR PDS_acc LIKE '$query'");
  
  if($$settings{limit}){
    $cmd =~ s/(['"])$/\nLIMIT $$settings{limit}$1/;
  }

  # If we want AMR results, add in a LEFT JOIN statement
  if($$settings{amr}){
    $cmd =~ s/(FROM SNP_distances AS snps)/$1\nLEFT JOIN amr_metadata AS amr\nON snps.target_acc_1 = amr.target_acc OR snps.target_acc_2 = amr.target_acc\n/;
  }
  if($$settings{debug}){
    logmsg "COMMAND: ".$cmd;
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

  if($$settings{limit}){
    $cmd =~ s/(')$/\nLIMIT $$settings{limit}$1/;
  }

  if($$settings{debug}){
    logmsg "COMMAND: $cmd";
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
    if(!-d "log"){
      mkdir("log")
        or die "ERROR: could not make a directory $localFiles/log: $!";
    }

    for my $TAXON(@$taxa){
      logmsg "Downloading $TAXON";
      system("wget --continue -r \\
          -X/pathogen/Results/$TAXON/latest_snps/SNP_trees \\
          -X/pathogen/Results/$TAXON/latest_snps/Trees \\
          ftp://ftp.ncbi.nlm.nih.gov/pathogen/Results/$TAXON/latest_snps/ \\
          > log/$TAXON.log 2>&1
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
        label TEXT,
        FDA_lab_id TEXT,
        HHS_region TEXT,
        IFSAC_category TEXT,
        LibraryLayout TEXT,
        PFGE_PrimaryEnzyme_pattern TEXT,
        PFGE_SecondaryEnzyme_pattern TEXT,
        Platform TEXT,
        Run TEXT,
        asm_acc TEXT,
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
        host_disease TEXT,
        isolation_source TEXT,
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

# Import everything into the database using sqlite's import function
sub indexAll{
  my($settings) = @_;

  my $doneMarker = "$localFiles/.03_index";

  if(-e $doneMarker){
    logmsg "NOTE: files have already been indexed. Remove $doneMarker to release the lock.";
    return 0;
  }

  my $db = "$localFiles/pdtk.sqlite3";
  if(-e $db){
    _rm($db);
  }
  createBlankDb($db, $settings);
  my $catDir = "$localFiles/cat";
  if(!-d $catDir){
    mkdir($catDir) or die "ERROR: could not make dir $catDir: $!";
  }

  # Make a few file handles whose keys are $fileType
  # e.g., amr.metadata
  my %outFh;

  find({
    wanted=>sub{
      if($_ =~ /\.(\w+)$/){
        my $ext = $1;
        return if($ext !~ /tsv/);
      } else {
        # Return if we don't have an extension
        return;
      }

      my($PDG, $version, $fileType, $ext, $other) = split(/\./, basename($File::Find::name));
      if($fileType eq 'amr' && $ext eq 'metadata'){
        $fileType = "amr.metadata";
        $ext = $other;
      }
      if($fileType eq 'reference_target'){
        $fileType .= ".$ext";
        $ext = $other;
      }

      if(!$outFh{$fileType}){
        open($outFh{$fileType}, ">", "$catDir/$fileType.$ext") or die "ERROR: could not write to $catDir/$fileType.$ext: $!";
      }

      # Read the fixed TSV and cat it onto the running tsv for this file.
      logmsg "Reading in $File::Find::name";
      my $fixedTsv = fixSpreadsheet($File::Find::name, $settings);
      {
        local $/ = undef;
        open(my $fh, "<", $fixedTsv) or die "ERROR: could not read $fixedTsv: $!";
        my $content = <$fh>;
        close $fh;

        my $outFh = $outFh{$fileType};
        print $outFh $content;
      }
    },
    no_chdir=>1}, "$localFiles/ftp.ncbi.nlm.nih.gov/pathogen/Results"
  );
  logmsg "Done reading individual files and catting them. Now indexing.";

  my $sqlXopts = "-separator '\t' $db";
  my $importXopts = "";
  my $cmd = "echo 'INTERNAL ERROR: no command supplied.'; exit 2;";

  # AMR metadata
  logmsg "Indexing $localFiles/cat/amr.metadata.tsv";
  $cmd = qq(sqlite3 $sqlXopts '.import $importXopts $localFiles/cat/amr.metadata.tsv amr_metadata');
  system($cmd);
  my $exit_code = $? << 8;
  if($exit_code){
    logmsg "COMMAND was:\n  $cmd";
    die "ERROR: Could not index into sqlite3: $$localFiles/cat/amr.metadata.tsv $!";
  }

  # snp distances
  logmsg "Indexing $localFiles/cat/reference_target.SNP_distances.tsv";
  $cmd = qq(sqlite3 $sqlXopts '.import $importXopts $localFiles/cat/reference_target.SNP_distances.tsv SNP_distances');
  system($cmd);
  $exit_code = $? << 8;
  if($exit_code){
    logmsg "COMMAND was:\n  $cmd";
    die "ERROR: Could not index into sqlite3: $localFiles/cat/reference_target.SNP_distances.tsv: $!";
  }

  # Mark as complete
  open(my $fh, ">", $doneMarker) or logmsg "WARNING: could not create file $doneMarker: $!";
  close $fh;

  return 1;
}

# Ensure that all rows have the same number of fields.
# This replaces the file contents.
sub fixSpreadsheet{
  my($tsv, $settings) = @_;

  # What is the max number of fields?
  my $maxFields=0;
  open(my $fh, $tsv) or die "ERROR: could not read tsv $tsv: $!";
  while(<$fh>){
    my @F = split /\t/;
    $maxFields = max(scalar(@F), $maxFields);
  }
  close $fh;
  #logmsg "MAX FIELDS $maxFields $tsv";

  open($fh, $tsv) or die "ERROR: could not read tsv $tsv: $!";
  my $header = <$fh>; # discard the header
  open(my $outFh, ">", "$tsv.fixed") or die "ERROR: could not write to $tsv.fixed: $!";
  while(<$fh>){
    chomp;

    # escape any " characters
    s/"/\\"/g;
    my @F = split /\t/;
    while(@F < $maxFields){
      push(@F, "NULL");
    }
    # sanitize away any whitespace
    for(@F){
      s/^\s+$//g;
    }
    print $outFh join("\t", @F)."\n";
  }
  close $outFh;
  close $fh;

  #mv("$tsv.fixed", $tsv) or die "ERROR: could not replace $tsv with fixed version: $!";
  return "$tsv.fixed";
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

  # Limit the taxa if the user requests it
  if($$settings{taxa}){
    my @wantedTaxa = split(/,/, $$settings{taxa});
    # compare the list vs what's online
    for my $w(@wantedTaxa){
      if(!grep{$_ eq $w} @list){
        die "ERROR: user requested $w but it is not a taxon listed in PD";
      }
    }

    # Now that these requested taxa are cleared, set the taxa
    @list = @wantedTaxa;
  }

  if($$settings{debug}){
    splice(@list, 2,1000);
    logmsg "NOTE: --debug was given; just keeping two taxa: ".join(" ",@list);
  }

  return \@list;
}

sub usage{
  print "$0: interacts with the NCBI Pathogens Portal
  Usage: $0 [options] 
  SUBCOMMANDS
  --list             List which taxa are available
  --download         Download data to ~/.pdtk
  --query            Query from S1
  --clean            Clean up any unneeded files in ~/.pdtk
  --veryclean        Cleans up anything in --clean, plus
                     removes any files created in --download.
                     The database remains intact.
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
  --amr              (TODO) When querying, also include AMR results
  --limit    LMT     How many database entries to return at once.
                     Default: 0 (unlimited)
  --debug            When --download, only downloads the first two taxa
                     When --query, prints the SQL command
                     When --find-target, prints the SQL command
  --taxa     TAXA    Limit to certain taxa. Comma separated.
                     Default: '', indicating all taxa.
                     When --download, only limits to certain taxa.
                     When --list, only limits to certain taxa.
  \n";
  exit 0;
}

