#!/usr/bin/env perl

use strict;
use warnings;
use lib './lib';
use File::Basename qw/dirname/;
use FindBin qw/$RealBin/;
use Data::Dumper;
use File::Which qw/which/;

use Test::More tests => 4;

$ENV{PATH} = "$RealBin/../scripts:".$ENV{PATH};

my $db = "$RealBin/pdtk/pdtk.sqlite3";
my $sample1 = "PDT000505696.1";
my $sample2 = "PDT000711751.1";

subtest 'the basics' => sub{
  diag `pdtk.pl -h`;
  my $exit_code = $? << 8;
  is($exit_code, 0, "exit code");
  isnt(which("sqlite3"), "", "Found sqlite3");
};

subtest 'download' => sub{
  system("pdtk.pl --download --debug --db $db");

  my $statDb = stat($db);

  is(-e $db, 1, "Database was created");
  cmp_ok(-s $db, '>', 0, "Database has a size > 0");

};

subtest 'find-target' => sub{
  for my $sample($sample1, $sample2){
    my @res = `pdtk.pl --find-target $sample --db $db `;
    cmp_ok(scalar(@res), '>', 1, "Got results with a header when querying $sample");
  }
};

subtest 'query' => sub{
  my $within  = 40;
  my @res = `pdtk.pl --query --db $db --sample1 $sample1 --within $within`;
  cmp_ok(scalar(@res), '>', 1, "Got results with a header when querying $sample1");

  # Check for basic information I'd expect
  ok("@res" =~ /Acinetobacter/, "Found Acinetobacter in the results");
  ok("@res" =~ /$sample1/, "Found $sample1 in the results");

  subtest "Between $sample1 and $sample2" => sub{
    @res = `pdtk.pl --query --db $db --sample1 $sample1 --sample2 $sample2`;
    chomp(@res);
    my @header = split(/\t/,shift(@res));
    my %r;
    my @oneResult = split(/\t/, shift(@res));
    for(my $i=0;$i<@header;$i++){
      $r{$header[$i]} = $oneResult[$i];
    }
    my %exp = (
        'compatible_distance' => '37',
        'sample_name_2' => 'BA35394',
        'delta_positions_unambiguous' => '38',
        'total_positions' => '52',
        'pairwise_bases_post_filtered' => 'NULL',
        'target_acc_1' => 'PDT000505696.1',
        'delta_positions_one_N' => '2',
        'biosample_acc_1' => 'SAMN11621520',
        'aligned_bases_pre_filtered' => '4166795',
        'PDS_acc' => 'PDS000060293.7',
        'informative_positions' => '50',
        'compatible_positions' => '52',
        'biosample_acc_2' => 'SAMN14299445',
        'sample_name_1' => 'Carbapenem resistant Acinetobacter baumannii_P7774_hybrid assembly',
        'delta_positions_both_N' => '0',
        'target_acc_2' => 'PDT000711751.1',
        'gencoll_acc_1' => 'GCA_005518095.1',
        'gencoll_acc_2' => 'GCA_011601545.1',
        'aligned_bases_post_filtered' => '4085466'
    );

    while(my($key,$value) = each(%exp)){
      is($r{$key}, $exp{$key}, $key);
    }

    # With AMR
    #@res = `pdtk.pl --query --db $db --sample1 $sample1 --sample2 $sample2 --amr`;
    #chomp(@res);
    #@header = split(/\t/,shift(@res));
    #%r = ();
    #@oneResult = split(/\t/, shift(@res));
    #for(my $i=0;$i<@header;$i++){
    #  $r{$header[$i]} = $oneResult[$i];
    #}
    #print Dumper \%r;
  };
};


