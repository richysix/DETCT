#!/usr/bin/env perl

# PODNAME: filter_output.pl
# ABSTRACT: Filter DETCT output using 3' ends

## Author         : is1
## Maintainer     : is1
## Created        : 2016-09-21
## Last commit by : $Author$
## Last modified  : $Date$
## Revision       : $Revision$
## Repository URL : $HeadURL$

use warnings;
use strict;
use autodie;
use Carp;
use Try::Tiny;

use Getopt::Long;
use Pod::Usage;
use Readonly;
use Path::Tiny;
use File::Spec;
use File::Path qw( make_path );
use List::MoreUtils qw( any );
use Sort::Naturally;
use Set::IntervalTree;
use DETCT::GeneFinder;
use DETCT::Analysis::DiffExpr;
use DETCT::Misc::Output;
use DETCT::Misc qw( write_or_die );

=head1 DESCRIPTION


=head1 EXAMPLES

    perl \
        -Ibranch-ensembl-74/ensembl/modules \
        filter_output.pl \
            --dir filter \
            --analysis_yaml analysis.yaml \
            --all_file all.tsv \
            --ends_file ends.tsv

=cut

# Constants
Readonly our $THREE_PRIME_END_POS_FIELD           => 0;
Readonly our $THREE_PRIME_END_READ_COUNT_FIELD    => 1;
Readonly our $IS_POLYA_FIELD                      => 2;
Readonly our $UPSTREAM_14_BP_FIELD                => 3;
Readonly our $DOWNSTREAM_14_BP_FIELD              => 4;
Readonly our $DISTANCE_HEXAMER_UPSTREAM_FIELD     => 5;
Readonly our $HEXAMER_FIELD                       => 6;
Readonly our $TRANSPOSON_DISTANCE_FIELD           => 7;
Readonly our $TRANSPOSON_POSITION_FIELD           => 8;
Readonly our $CONTINUOUS_RNASEQ_TRANSCRIPTS_FIELD => 9;

Readonly our $CONTINUOUS_RNASEQ_PADDING    => 20;
Readonly our $SIMPLE_REPEAT_PADDING        => 20;
Readonly our $ANNOTATED_DISTANCE_THRESHOLD => 100;

Readonly our %IS_PRIMARY_HEXAMER   => map { $_ => 1 } qw( AATAAA ATTAAA );
Readonly our %IS_SECONDARY_HEXAMER => map { $_ => 1 }
  qw( AGTAAA TATAAA CATAAA GATAAA AATATA AATACA AATAGA ACTAAA AAGAAA AATGAA );

# Regexps for checking for polyA
Readonly our $DOWNSTREAM_POLYA_LENGTH    => 6;
Readonly our $DOWNSTREAM_POLYA_THRESHOLD => 3;
Readonly our @POLYA_REGEXP               => (
    qr/\A AAA... \z/xms,
    qr/\A AA.A.. \z/xms,
    qr/\A AA..A. \z/xms,
    qr/\A AA...A \z/xms,
    qr/\A A.AA.. \z/xms,
    qr/\A A..AA. \z/xms,
    qr/\A .AAA.. \z/xms,
    qr/\A .A.AA. \z/xms,
    qr/\A ..AAA. \z/xms,
    qr/\A ..AA.A \z/xms,
);

# Default options
my $analysis_dir  = q{.};
my $analysis_yaml = File::Spec->catfile( $analysis_dir, 'analysis.yaml' );
my $all_file;
my $ends_file;
my $slice_regexp;
my @biotype;
my $keep_ends_without_biotype;
my $keep_regions_without_ends;
my $keep_ends_near_n;
my $keep_ends_far_from_annotation;
my $keep_ends_beyond_five_prime;
my $keep_ends_in_cds;
my $keep_ends_in_simple_repeat;
my $keep_ends_in_simple_repeat_if_coding;
my $keep_ends_in_simple_repeat_if_other;
my $keep_ends_in_transposon;
my $keep_polya_strict_ends;
my $keep_polya_stricter_ends;
my $keep_ends_without_hexamer;
my $keep_ends_without_rnaseq;
my $keep_ends_without_rnaseq_if_coding;
my $keep_ends_without_rnaseq_if_other;
## no critic (ProhibitMagicNumbers)
my $polya_threshold                     = 10;
my $downstream_polya_threshold          = 4;
my $hexamer_polya_threshold             = 14;
my $annotated_distance_threshold_coding = 5000;
my $annotated_distance_threshold_other  = 50;
## use critic
my $log;
my ( $help, $man );

# Get and check command line options
get_and_check_options();

if ( !-d $analysis_dir ) {
    make_path($analysis_dir);
}

my $log_fh;
if ($log) {
    ## no critic (RequireBriefOpen)
    open $log_fh, '>', File::Spec->catfile( $analysis_dir, 'filter.log' );
    ## use critic
    my @header = (
        '#Chr',
        'Region start',
        'Region end',
        q{3' end strand},
        q{3' end position},
        'Reason',
        q{3' end read count},
        'polyA?',
        '14 bp upstream',
        '14 bp downstream',
        'Distance hexamer upstream (up to 40 bp)',
        'Hexamer',
        'Continuous RNA-Seq transcripts',
        'Continuous RNA-Seq end distances',
        'Ensembl gene ID',
        'Gene type',
        'Ensembl transcript ID',
        'Transcript type',
        'Gene name',
    );
    write_or_die( $log_fh, sprintf "%s\n", join "\t", @header );
}

# Create analysis
my $analysis = DETCT::Analysis::DiffExpr->new_from_yaml($analysis_yaml);

my $gene_finder = DETCT::GeneFinder->new(
    {
        slice_adaptor     => $analysis->slice_adaptor,
        skip_transcripts  => $analysis->get_all_skip_transcripts,
        ensembl_db_types  => $analysis->get_all_ensembl_db_types,
        required_biotypes => \@biotype,
    }
);

my $cds_cache = get_cds_cache( $analysis->slice_adaptor, $slice_regexp );

my $simple_repeat_cache =
  get_simple_repeat_cache( $analysis->slice_adaptor, $slice_regexp );

my $ends_for = get_ends( $ends_file, $slice_regexp );

my $regions = get_regions( $all_file, $analysis, $slice_regexp );

if ( @biotype && !$keep_ends_without_biotype ) {
    $regions = remove_ends_by_biotype( $regions, $ends_for, $gene_finder );
}

if ( !$keep_ends_near_n ) {
    $regions = remove_ends_near_n( $regions, $ends_for );
}

if ( !$keep_ends_far_from_annotation ) {
    $regions = remove_ends_far_from_annotation( $regions, $ends_for,
        $analysis->slice_adaptor );
}

if ( !$keep_ends_beyond_five_prime ) {
    $regions = remove_ends_beyond_five_prime( $regions, $ends_for,
        $analysis->slice_adaptor );
}

if ( !$keep_ends_in_cds ) {
    $regions = remove_ends_in_cds( $regions, $ends_for, $cds_cache );
}

if (   !$keep_ends_in_simple_repeat_if_coding
    || !$keep_ends_in_simple_repeat_if_other )
{
    $regions =
      remove_ends_in_simple_repeat( $regions, $ends_for, $simple_repeat_cache,
        $gene_finder );
}

if ( !$keep_ends_in_transposon ) {
    $regions = remove_ends_in_transposon( $regions, $ends_for );
}

if ( !$keep_polya_strict_ends ) {
    $regions = remove_polya_strict( $regions, $ends_for );
}

if ( !$keep_polya_stricter_ends ) {
    $regions = remove_polya_stricter( $regions, $ends_for );
}

if ( !$keep_ends_without_hexamer ) {
    $regions = remove_ends_without_hexamer( $regions, $ends_for, $gene_finder );
}

if (   !$keep_ends_without_rnaseq_if_coding
    || !$keep_ends_without_rnaseq_if_other )
{
    $regions = remove_ends_without_rnaseq( $regions, $ends_for, $gene_finder );
}

if ( !$keep_regions_without_ends ) {
    $regions = remove_regions_without_ends($regions);
}

if ($log) {
    log_kept_ends( $regions, $ends_for );
    close $log_fh;
}

# Reannotate (perhaps only with required biotypes)
$regions = $gene_finder->add_gene_annotation($regions);

DETCT::Misc::Output::dump_as_table(
    {
        analysis => $analysis,
        dir      => $analysis_dir,
        regions  => $regions,
    }
);

sub get_cds_cache {
    my ( $sa, $slice_regexp ) = @_;    ## no critic (ProhibitReusedNames)

    my %cds_cache;

    # Get all transcripts
    my $slices = $sa->fetch_all('toplevel');
    if ($slice_regexp) {
        @{$slices} =
          grep { $_->seq_region_name =~ m/\A $slice_regexp \z/xms } @{$slices};
    }
    foreach
      my $slice ( sort { ncmp( $a->seq_region_name, $b->seq_region_name ) }
        @{$slices} )
    {
        my $chr = $slice->seq_region_name;
        if ( !exists $cds_cache{$chr} ) {
            $cds_cache{$chr}{-1} = Set::IntervalTree->new;
            $cds_cache{$chr}{1}  = Set::IntervalTree->new;
        }

        my $transcripts = $slice->get_all_Transcripts();
        foreach my $transcript ( @{$transcripts} ) {
            if ( defined $transcript->translation ) {
                my $strand = $transcript->seq_region_strand;
                my $exons  = $transcript->get_all_Exons();
                foreach my $exon ( @{$exons} ) {
                    next if !defined $exon->coding_region_start($transcript);
                    $cds_cache{$chr}{$strand}->insert(
                        {
                            start => $exon->coding_region_start($transcript),
                            end   => $exon->coding_region_end($transcript),
                        },
                        $exon->coding_region_start($transcript),
                        $exon->coding_region_end($transcript) + 1
                    );
                }
            }
        }
    }

    return \%cds_cache;
}

sub get_simple_repeat_cache {
    my ( $sa, $slice_regexp ) = @_;    ## no critic (ProhibitReusedNames)

    my %simple_repeat_cache;

    my $slices = $sa->fetch_all('toplevel');
    if ($slice_regexp) {
        @{$slices} =
          grep { $_->seq_region_name =~ m/\A $slice_regexp \z/xms } @{$slices};
    }
    foreach
      my $slice ( sort { ncmp( $a->seq_region_name, $b->seq_region_name ) }
        @{$slices} )
    {
        my $chr = $slice->seq_region_name;
        if ( !exists $simple_repeat_cache{$chr} ) {
            $simple_repeat_cache{$chr} = Set::IntervalTree->new;
        }

        my $dust_features = $slice->get_all_RepeatFeatures('dust');
        my $trf_features  = $slice->get_all_RepeatFeatures('trf');
        foreach my $repeat ( @{$dust_features}, @{$trf_features} ) {
            $simple_repeat_cache{$chr}->insert(
                {
                    start => $repeat->seq_region_start - $SIMPLE_REPEAT_PADDING,
                    end   => $repeat->seq_region_end + $SIMPLE_REPEAT_PADDING,
                },
                $repeat->seq_region_start - $SIMPLE_REPEAT_PADDING,
                $repeat->seq_region_end + $SIMPLE_REPEAT_PADDING + 1
            );
        }
    }

    return \%simple_repeat_cache;
}

sub get_ends {
    ## no critic (ProhibitReusedNames)
    my ( $file, $slice_regexp ) = @_;
    ## use critic

    my ($extension) = $file =~ m/[.] ([[:lower:]]{3}) \z/xms;
    if ( !$extension || ( $extension ne 'csv' && $extension ne 'tsv' ) ) {
        confess sprintf '%s is not .csv or .tsv file', $file;
    }

    my %ends_for;

    open my $fh, '<', $file;    ## no critic (RequireBriefOpen)
    my $header = <$fh>;
    while ( my $line = <$fh> ) {
        my @fields = DETCT::Misc::Output::parse_line( $line, $extension );
        next if $slice_regexp && $fields[0] !~ m/\A $slice_regexp \z/xms;

        # Get region ID from chr, start or end (depending on strand) and strand
        ## no critic (ProhibitMagicNumbers)
        my $strand       = $fields[3];
        my $start_or_end = $strand > 0 ? 1 : 2;
        my @region       = @fields[ 0 .. 3 ];
        my $ends         = $fields[5];
        my $region       = join q{:}, @region[ 0, $start_or_end, 3 ];
        ## use critic
        $ends_for{$region} = $ends;
    }
    close $fh;

    return \%ends_for;
}

sub get_regions {
    ## no critic (ProhibitReusedNames)
    my ( $file, $analysis, $slice_regexp ) = @_;
    ## use critic

    my ($extension) = $file =~ m/[.] ([[:lower:]]{3}) \z/xms;
    if ( !$extension || ( $extension ne 'csv' && $extension ne 'tsv' ) ) {
        confess sprintf '%s is not .csv or .tsv file', $file;
    }

    ## no critic (ProhibitReusedNames)
    my $regions = DETCT::Misc::Output::parse_table(
        ## use critic
        {
            analysis     => $analysis,
            table_file   => $file,
            table_format => $extension,
        }
    );

    return $regions if !$slice_regexp;

    my @new_regions;
    foreach my $region ( @{$regions} ) {
        next if $region->[0] !~ m/\A $slice_regexp \z/xms;
        push @new_regions, $region;
    }

    return \@new_regions;
}

sub remove_ends_by_biotype {
    ## no critic (ProhibitReusedNames)
    my ( $regions, $ends_for, $gene_finder ) = @_;
    ## use critic

    foreach my $region ( @{$regions} ) {
        my $chr = $region->[0];
        ## no critic (ProhibitMagicNumbers)
        my $three_prime_end_pos = $region->[6];
        my $strand              = $region->[7];
        ## use critic
        next if !defined $three_prime_end_pos;
        my @three_prime_end_pos =
          ref $three_prime_end_pos eq 'ARRAY'
          ? @{$three_prime_end_pos}
          : ($three_prime_end_pos);
        foreach my $pos (@three_prime_end_pos) {
            my ( undef, $distance ) =
              $gene_finder->get_nearest_transcripts( $chr, $pos, $strand );
            if ( !defined $distance ) {
                $region =
                  remove_end_from_region( $region, $pos, $ends_for, 'biotype' );
            }
        }
    }

    return $regions;
}

sub remove_ends_near_n {
    my ( $regions, $ends_for ) = @_;    ## no critic (ProhibitReusedNames)

    foreach my $region ( @{$regions} ) {
        my @all_ends = parse_ends( $region, $ends_for );
        ## no critic (ProhibitMagicNumbers)
        my $three_prime_end_pos = $region->[6];
        ## use critic
        next if !defined $three_prime_end_pos;
        my @three_prime_end_pos =
          ref $three_prime_end_pos eq 'ARRAY'
          ? @{$three_prime_end_pos}
          : ($three_prime_end_pos);
        foreach my $pos (@three_prime_end_pos) {
            my ($end) =
              grep { $_->[$THREE_PRIME_END_POS_FIELD] == $pos } @all_ends;
            my $surrounding =
              $end->[$UPSTREAM_14_BP_FIELD] . $end->[$DOWNSTREAM_14_BP_FIELD];
            my $n_count = $surrounding =~ tr/N/N/;
            next if !$n_count;

            $region =
              remove_end_from_region( $region, $pos, $ends_for, 'nearbyN' );
        }
    }

    return $regions;
}

sub remove_ends_far_from_annotation {
    my ( $regions, $ends_for, $sa ) = @_;    ## no critic (ProhibitReusedNames)

    foreach my $region ( @{$regions} ) {
        my @all_ends = parse_ends( $region, $ends_for );
        my $chr      = $region->[0];
        ## no critic (ProhibitMagicNumbers)
        my $three_prime_end_pos = $region->[6];
        my $strand              = $region->[7];
        ## use critic
        next if !defined $three_prime_end_pos;
        my @three_prime_end_pos =
          ref $three_prime_end_pos eq 'ARRAY'
          ? @{$three_prime_end_pos}
          : ($three_prime_end_pos);
        foreach my $pos (@three_prime_end_pos) {
            my ($end) =
              grep { $_->[$THREE_PRIME_END_POS_FIELD] == $pos } @all_ends;
            my $remove = 1;
            my ( $nearest_transcripts, $distance ) =
              $gene_finder->get_nearest_transcripts( $chr, $pos, $strand );
            foreach my $transcript ( @{$nearest_transcripts} ) {
                if (
                       defined $transcript
                    && $transcript->biotype =~ m/\A protein_coding/xms
                    && defined $distance
                    && $distance >= 0
                    && abs $distance <= $annotated_distance_threshold_coding
                    && !is_in_other_gene_span(
                        $transcript, $chr, $pos, $strand, $sa
                    )
                  )
                {
                    $remove = 0;
                    last;
                }
                if (   defined $transcript
                    && $transcript->biotype !~ m/\A protein_coding/xms
                    && defined $distance
                    && abs $distance <= $annotated_distance_threshold_other )
                {
                    $remove = 0;
                    last;
                }
            }
            if ($remove) {
                $region = remove_end_from_region( $region, $pos, $ends_for,
                    'annotationdistance' );
            }
        }
    }

    return $regions;
}

sub remove_ends_beyond_five_prime {
    my ( $regions, $ends_for, $sa ) = @_;    ## no critic (ProhibitReusedNames)

    foreach my $region ( @{$regions} ) {
        my @all_ends = parse_ends( $region, $ends_for );
        my $chr      = $region->[0];
        ## no critic (ProhibitMagicNumbers)
        my $three_prime_end_pos = $region->[6];
        my $strand              = $region->[7];
        ## use critic
        next if !defined $three_prime_end_pos;
        my @three_prime_end_pos =
          ref $three_prime_end_pos eq 'ARRAY'
          ? @{$three_prime_end_pos}
          : ($three_prime_end_pos);
        foreach my $pos (@three_prime_end_pos) {
            my ($end) =
              grep { $_->[$THREE_PRIME_END_POS_FIELD] == $pos } @all_ends;
            my $remove = 1;
            my ($nearest_genes) =
              $gene_finder->get_nearest_genes( $chr, $pos, $strand );
            foreach my $gene ( @{$nearest_genes} ) {
                if ( $strand == 1 && $pos >= $gene->start ) {
                    $remove = 0;
                    last;
                }
                ## no critic (ProhibitMagicNumbers)
                elsif ( $strand == -1 && $pos <= $gene->end ) {
                    ## use critic
                    $remove = 0;
                    last;
                }
            }
            if ($remove) {
                $region =
                  remove_end_from_region( $region, $pos, $ends_for, 'beyond5' );
            }
        }
    }

    return $regions;
}

sub is_in_other_gene_span {
    my ( $transcript, $chr, $pos, $strand, $sa ) = @_;

    my $nearest_gene_stable_id = $transcript->gene->stable_id;

    my $slice = $sa->fetch_by_region( 'toplevel', $chr, $pos, $pos, $strand );
    my $overlapping_genes = $slice->get_all_Genes();
    foreach my $overlapping_gene ( @{$overlapping_genes} ) {
        next if $overlapping_gene->stable_id eq $nearest_gene_stable_id;
        next if $overlapping_gene->seq_region_strand != $strand;
        return 1;
    }

    return 0;
}

sub remove_ends_in_cds {
    ## no critic (ProhibitReusedNames)
    my ( $regions, $ends_for, $cds_cache ) = @_;
    ## use critic

    foreach my $region ( @{$regions} ) {
        my $chr = $region->[0];
        ## no critic (ProhibitMagicNumbers)
        my $strand              = $region->[7];
        my $three_prime_end_pos = $region->[6];
        ## use critic
        next if !defined $three_prime_end_pos;
        my @three_prime_end_pos =
          ref $three_prime_end_pos eq 'ARRAY'
          ? @{$three_prime_end_pos}
          : ($three_prime_end_pos);
        foreach my $pos (@three_prime_end_pos) {
            next if !exists $cds_cache->{$chr};    # e.g. spike sequences
            my $cds_intervals =
              $cds_cache->{$chr}{$strand}->fetch( $pos, $pos + 1 );
            if ( @{$cds_intervals} ) {
                $region =
                  remove_end_from_region( $region, $pos, $ends_for, 'CDS' );
            }
        }
    }

    return $regions;
}

sub remove_ends_in_simple_repeat {
    ## no critic (ProhibitReusedNames)
    my ( $regions, $ends_for, $simple_repeat_cache, $gene_finder ) = @_;
    ## use critic

    foreach my $region ( @{$regions} ) {
        my $chr = $region->[0];
        ## no critic (ProhibitMagicNumbers)
        my $three_prime_end_pos = $region->[6];
        my $strand              = $region->[7];
        ## use critic
        next if !defined $three_prime_end_pos;
        my @three_prime_end_pos =
          ref $three_prime_end_pos eq 'ARRAY'
          ? @{$three_prime_end_pos}
          : ($three_prime_end_pos);
      POS: foreach my $pos (@three_prime_end_pos) {
            next if !exists $simple_repeat_cache->{$chr}; # e.g. spike sequences

            # Keep if near required biotype
            my ($nearest_transcripts) =
              $gene_finder->get_nearest_transcripts( $chr, $pos, $strand );
            foreach my $transcript ( @{$nearest_transcripts} ) {
                next POS
                  if $keep_ends_in_simple_repeat_if_coding
                  && defined $transcript
                  && $transcript->biotype =~ m/\A protein_coding/xms;
                next POS
                  if $keep_ends_in_simple_repeat_if_other
                  && defined $transcript
                  && $transcript->biotype !~ m/\A protein_coding/xms;
            }

            my $simple_repeat_intervals =
              $simple_repeat_cache->{$chr}->fetch( $pos, $pos + 1 );
            if ( @{$simple_repeat_intervals} ) {
                $region =
                  remove_end_from_region( $region, $pos, $ends_for, 'repeat' );
            }
        }
    }

    return $regions;
}

sub remove_ends_in_transposon {
    my ( $regions, $ends_for ) = @_;    ## no critic (ProhibitReusedNames)

    foreach my $region ( @{$regions} ) {
        my @all_ends = parse_ends( $region, $ends_for );
        ## no critic (ProhibitMagicNumbers)
        my $three_prime_end_pos = $region->[6];
        ## use critic
        next if !defined $three_prime_end_pos;
        my @three_prime_end_pos =
          ref $three_prime_end_pos eq 'ARRAY'
          ? @{$three_prime_end_pos}
          : ($three_prime_end_pos);
        foreach my $pos (@three_prime_end_pos) {
            my ($end) =
              grep { $_->[$THREE_PRIME_END_POS_FIELD] == $pos } @all_ends;
            if ( length $end->[$TRANSPOSON_DISTANCE_FIELD]
                && $end->[$TRANSPOSON_DISTANCE_FIELD] == 0 )
            {
                $region = remove_end_from_region( $region, $pos, $ends_for,
                    'transposon' );
            }
        }
    }

    return $regions;
}

sub remove_polya_strict {
    my ( $regions, $ends_for ) = @_;    ## no critic (ProhibitReusedNames)

    foreach my $region ( @{$regions} ) {
        my @all_ends = parse_ends( $region, $ends_for );
        my $chr      = $region->[0];
        ## no critic (ProhibitMagicNumbers)
        my $three_prime_end_pos = $region->[6];
        my $strand              = $region->[7];
        ## use critic
        next if !defined $three_prime_end_pos;
        my @three_prime_end_pos =
          ref $three_prime_end_pos eq 'ARRAY'
          ? @{$three_prime_end_pos}
          : ($three_prime_end_pos);
        foreach my $pos (@three_prime_end_pos) {
            my ($end) =
              grep { $_->[$THREE_PRIME_END_POS_FIELD] == $pos } @all_ends;
            my $surrounding =
              $end->[$UPSTREAM_14_BP_FIELD] . $end->[$DOWNSTREAM_14_BP_FIELD];
            my $polya_count = $surrounding =~ tr/A/A/;
            my ($initial_a) = $end->[$DOWNSTREAM_14_BP_FIELD] =~ m/\A (A+)/xms;

            # Keep end if low overall A, especially at start of downstream
            next
              if $polya_count <= $polya_threshold
              && (!defined $initial_a
                || length $initial_a <= $downstream_polya_threshold );

            # Keep end if primary hexamer and polyA not above higher threshold
            next
              if exists $IS_PRIMARY_HEXAMER{ $end->[$HEXAMER_FIELD] }
              && $polya_count <= $hexamer_polya_threshold;

            # Keep end if primary hexamer and near annotated 3' end
            my ( undef, $distance ) =
              $gene_finder->get_nearest_transcripts( $chr, $pos, $strand );
            next
              if exists $IS_PRIMARY_HEXAMER{ $end->[$HEXAMER_FIELD] }
              && defined $distance
              && abs $distance <= $ANNOTATED_DISTANCE_THRESHOLD;
            $region =
              remove_end_from_region( $region, $pos, $ends_for, 'polyAstrict' );
        }
    }

    return $regions;
}

sub remove_polya_stricter {
    my ( $regions, $ends_for ) = @_;    ## no critic (ProhibitReusedNames)

    foreach my $region ( @{$regions} ) {
        my @all_ends = parse_ends( $region, $ends_for );
        ## no critic (ProhibitMagicNumbers)
        my $three_prime_end_pos = $region->[6];
        ## use critic
        next if !defined $three_prime_end_pos;
        my @three_prime_end_pos =
          ref $three_prime_end_pos eq 'ARRAY'
          ? @{$three_prime_end_pos}
          : ($three_prime_end_pos);
        foreach my $pos (@three_prime_end_pos) {
            my ($end) =
              grep { $_->[$THREE_PRIME_END_POS_FIELD] == $pos } @all_ends;
            my $downstream = substr $end->[$DOWNSTREAM_14_BP_FIELD], 0,
              $DOWNSTREAM_POLYA_LENGTH;
            my $polya_count = $downstream =~ tr/A/A/;
            next if $polya_count < $DOWNSTREAM_POLYA_THRESHOLD;
            my $remove = 1;
            if ( $polya_count == $DOWNSTREAM_POLYA_THRESHOLD ) {
                $remove = 0;
                foreach my $regexp (@POLYA_REGEXP) {
                    if ( $downstream =~ $regexp ) {
                        $remove = 1;
                        last;
                    }
                }
            }

            if ($remove) {
                $region = remove_end_from_region( $region, $pos, $ends_for,
                    'polyAstricter' );
            }
        }
    }

    return $regions;
}

sub remove_ends_without_hexamer {
    ## no critic (ProhibitReusedNames)
    my ( $regions, $ends_for, $gene_finder ) = @_;
    ## use critic

    foreach my $region ( @{$regions} ) {
        my @all_ends = parse_ends( $region, $ends_for );
        my $chr      = $region->[0];
        ## no critic (ProhibitMagicNumbers)
        my $three_prime_end_pos = $region->[6];
        my $strand              = $region->[7];
        ## use critic
        next if !defined $three_prime_end_pos;
        my @three_prime_end_pos =
          ref $three_prime_end_pos eq 'ARRAY'
          ? @{$three_prime_end_pos}
          : ($three_prime_end_pos);
        foreach my $pos (@three_prime_end_pos) {
            my ($end) =
              grep { $_->[$THREE_PRIME_END_POS_FIELD] == $pos } @all_ends;

            # Keep end if primary hexamer
            next
              if defined $end->[$HEXAMER_FIELD]
              && exists $IS_PRIMARY_HEXAMER{ $end->[$HEXAMER_FIELD] };

            # Or keep end if secondary hexamer and near annotated 3' end
            my $remove = 1;
            if ( defined $end->[$HEXAMER_FIELD]
                && exists $IS_SECONDARY_HEXAMER{ $end->[$HEXAMER_FIELD] } )
            {
                my ( undef, $distance ) =
                  $gene_finder->get_nearest_transcripts( $chr, $pos, $strand );
                if ( defined $distance
                    && abs $distance <= $ANNOTATED_DISTANCE_THRESHOLD )
                {
                    $remove = 0;
                    last;
                }
            }
            if ($remove) {
                $region =
                  remove_end_from_region( $region, $pos, $ends_for, 'hexamer' );
            }
        }
    }

    return $regions;
}

sub remove_ends_without_rnaseq {
    ## no critic (ProhibitReusedNames)
    my ( $regions, $ends_for, $gene_finder ) = @_;
    ## use critic

    foreach my $region ( @{$regions} ) {
        my @all_ends = parse_ends( $region, $ends_for );
        my $chr      = $region->[0];
        ## no critic (ProhibitMagicNumbers)
        my $three_prime_end_pos = $region->[6];
        my $strand              = $region->[7];
        ## use critic
        next if !defined $three_prime_end_pos;
        my @three_prime_end_pos =
          ref $three_prime_end_pos eq 'ARRAY'
          ? @{$three_prime_end_pos}
          : ($three_prime_end_pos);
      POS: foreach my $pos (@three_prime_end_pos) {
            my ($end) =
              grep { $_->[$THREE_PRIME_END_POS_FIELD] == $pos } @all_ends;

            # Keep if near required biotype
            my ( $nearest_transcripts, $distance ) =
              $gene_finder->get_nearest_transcripts( $chr, $pos, $strand );
            foreach my $transcript ( @{$nearest_transcripts} ) {
                next POS
                  if $keep_ends_without_rnaseq_if_coding
                  && defined $transcript
                  && $transcript->biotype =~ m/\A protein_coding/xms;
                next POS
                  if $keep_ends_without_rnaseq_if_other
                  && defined $transcript
                  && $transcript->biotype !~ m/\A protein_coding/xms;
            }

            # Keep end if continuous RNA-Seq
            if ( $end->[$CONTINUOUS_RNASEQ_TRANSCRIPTS_FIELD] ) {
                my @pairs = split /[|]/xms,
                  $end->[$CONTINUOUS_RNASEQ_TRANSCRIPTS_FIELD];
                @pairs = map { [ split />/xms ] } @pairs;
                my @distances = map { $pos - $_->[1] } @pairs;
                next if any { $_ <= $CONTINUOUS_RNASEQ_PADDING } @distances;
            }

            # Or keep end if near annotated 3' end
            if (  !defined $distance
                || abs $distance > $ANNOTATED_DISTANCE_THRESHOLD )
            {
                $region =
                  remove_end_from_region( $region, $pos, $ends_for, 'RNA-Seq' );
            }
        }
    }

    return $regions;
}

sub remove_regions_without_ends {
    my ($regions) = @_;    ## no critic (ProhibitReusedNames)

    my @new_regions;
    foreach my $region ( @{$regions} ) {
        ## no critic (ProhibitMagicNumbers)
        my $three_prime_end_pos = $region->[6];
        ## use critic
        next if !defined $three_prime_end_pos;
        push @new_regions, $region;
    }

    return \@new_regions;
}

sub remove_end_from_region {
    ## no critic (ProhibitReusedNames)
    my ( $region, $pos_to_remove, $ends_for, $reason ) = @_;
    ## use critic

    write_log( $region, $pos_to_remove, $ends_for, $reason );

    ## no critic (ProhibitMagicNumbers)
    my $three_prime_end_pos = $region->[6];
    ## use critic

    if ( ref $three_prime_end_pos ne 'ARRAY'
        && $three_prime_end_pos != $pos_to_remove )
    {
        confess sprintf q{Trying to remove unknown 3' end (%d)}, $pos_to_remove;
    }

    if ( ref $three_prime_end_pos ne 'ARRAY' ) {
        ## no critic (ProhibitMagicNumbers)
        $region->[6]  = undef;    # 3' end position
        $region->[8]  = undef;    # 3' end read count
        $region->[15] = {};       # Gene annotation
        ## use critic
    }
    else {
        my $end_count = scalar @{$three_prime_end_pos};
        my $index     = 0;
        while ( $three_prime_end_pos->[$index] != $pos_to_remove ) {
            $index++;
            confess sprintf q{Trying to remove unknown 3' end (%d)},
              $pos_to_remove
              if !defined $three_prime_end_pos->[$index];
        }
        ## no critic (ProhibitMagicNumbers)
        splice @{ $region->[6] }, $index, 1;
        splice @{ $region->[8] }, $index, 1;
        if ( scalar @{ $region->[6] } == 1 ) {
            $region->[6] = $region->[6]->[0];
        }
        if ( scalar @{ $region->[8] } == 1 ) {
            $region->[8] = $region->[8]->[0];
        }

        # Attempt to remove 3' end distance, but really should reannotate
        my $genebuild_version = ( keys %{ $region->[15] } )[0];
        if ($genebuild_version) {
            my $genes = $region->[15]->{$genebuild_version};
            my @new_genes;
            foreach my $gene ( @{$genes} ) {
                next if ref $gene->[4] ne 'ARRAY';
                if ( scalar @{ $gene->[4] } == $end_count ) {
                    splice @{ $gene->[4] }, $index, 1;
                    if ( scalar @{ $gene->[4] } == 1 ) {
                        $gene->[4] = $gene->[4]->[0];
                    }
                }
                push @new_genes, $gene;
            }
            if (@new_genes) {
                $region->[15]->{$genebuild_version} = \@new_genes;
            }
            else {
                $region->[15] = {};
            }
        }
        ## use critic
    }

    return $region;
}

sub log_kept_ends {
    my ( $regions, $ends_for ) = @_;    ## no critic (ProhibitReusedNames)

    foreach my $region ( @{$regions} ) {
        ## no critic (ProhibitMagicNumbers)
        my $three_prime_end_pos = $region->[6];
        ## use critic
        next if !defined $three_prime_end_pos;
        my @three_prime_end_pos =
          ref $three_prime_end_pos eq 'ARRAY'
          ? @{$three_prime_end_pos}
          : ($three_prime_end_pos);
        foreach my $pos (@three_prime_end_pos) {
            write_log( $region, $pos, $ends_for, 'OK' );
        }
    }

    return;
}

sub write_log {
    ## no critic (ProhibitReusedNames)
    my ( $region, $pos, $ends_for, $reason ) = @_;
    ## use critic

    return if !$log;

    my @all_ends = parse_ends( $region, $ends_for );
    my ($end) = grep { $_->[$THREE_PRIME_END_POS_FIELD] == $pos } @all_ends;

    my @output;
    push @output, $region->[0];    # Chr
    push @output, $region->[1];    # Start
    push @output, $region->[2];    # End
    my $strand = $region->[7];     ## no critic (ProhibitMagicNumbers)
    push @output, $strand;
    push @output, $pos;
    push @output, $reason;
    push @output, $end->[$THREE_PRIME_END_READ_COUNT_FIELD];
    push @output, $end->[$IS_POLYA_FIELD];
    push @output, $end->[$UPSTREAM_14_BP_FIELD] || q{-};
    push @output, $end->[$DOWNSTREAM_14_BP_FIELD] || q{-};
    push @output, $end->[$DISTANCE_HEXAMER_UPSTREAM_FIELD] || q{-};
    push @output, $end->[$HEXAMER_FIELD] || q{-};

    if ( $end->[$CONTINUOUS_RNASEQ_TRANSCRIPTS_FIELD] ) {
        my @pairs = split /[|]/xms,
          $end->[$CONTINUOUS_RNASEQ_TRANSCRIPTS_FIELD];
        @pairs = map { [ split />/xms ] } @pairs;
        push @output, join q{,}, map { $_->[0] } @pairs;    # Transcript IDs
        my @distances = map { $pos - $_->[1] } @pairs;
        if ( $strand < 0 ) {
            @distances = map { -$_ } @distances;
        }
        push @output, join q{,}, @distances;
    }
    else {
        push @output, q{-}, q{-};
    }

    ## no critic (ProhibitMagicNumbers)
    my %gene = %{ $region->[15] };
    my ($genebuild) = ( sort keys %gene )[-1];    # Highest
    ## use critic
    my ( @gene_stable_id, @gene_biotype, @transcript_stable_id,
        @transcript_biotype, @name );
    if ($genebuild) {
        foreach my $gene ( @{ $gene{$genebuild} } ) {
            my ( $gene_stable_id, $name, undef, $gene_biotype, undef,
                $transcripts )
              = @{$gene};
            push @gene_stable_id, $gene_stable_id;
            push @gene_biotype,   $gene_biotype;
            foreach my $transcript ( @{$transcripts} ) {
                my ( $transcript_stable_id, $transcript_biotype ) =
                  @{$transcript};
                push @transcript_stable_id, $transcript_stable_id;
                push @transcript_biotype,   $transcript_biotype;
            }
            push @name, $name;
        }
    }
    push @output, array_to_scalar_for_output(@gene_stable_id);
    push @output, array_to_scalar_for_output(@gene_biotype);
    push @output, array_to_scalar_for_output(@transcript_stable_id);
    push @output, array_to_scalar_for_output(@transcript_biotype);
    push @output, array_to_scalar_for_output(@name);

    write_or_die( $log_fh, sprintf "%s\n", join "\t", @output );

    return;
}

sub array_to_scalar_for_output {
    my (@array) = @_;

    if ( !scalar @array ) {
        return q{-};
    }
    elsif ( scalar @array == 1 ) {
        return $array[0];
    }
    else {
        return join q{,}, @array;
    }
}

sub parse_ends {
    my ( $region, $ends_for ) = @_;    ## no critic (ProhibitReusedNames)

    # Get region ID from chr, start or end (depending on strand) and strand
    ## no critic (ProhibitMagicNumbers)
    my $strand       = $region->[7];
    my $start_or_end = $strand > 0 ? 1 : 2;
    my $ends = $ends_for->{ join q{:}, @{$region}[ 0, $start_or_end, 7 ] };
    ## use critic
    my @ends;
    if ($ends) {
        foreach my $end ( split /,/xms, $ends ) {
            ## no critic (ProhibitMagicNumbers)
            my @end_data = split /[:\/]/xms, $end, 11;
            ## use critic
            splice @end_data, 1, 1;    # Remove redundant strand
            push @ends, \@end_data;
        }
        @ends = sort { $a->[0] <=> $b->[0] } @ends;
        if ( $strand < 0 ) {
            @ends = reverse @ends;
        }
    }

    return @ends;
}

# Get and check command line options
sub get_and_check_options {
    my ( $strict, $stricter );

    # Get options
    GetOptions(
        'dir=s'                         => \$analysis_dir,
        'analysis_yaml=s'               => \$analysis_yaml,
        'all_file=s'                    => \$all_file,
        'ends_file=s'                   => \$ends_file,
        'slice_regexp=s'                => \$slice_regexp,
        'biotype=s@{,}'                 => \@biotype,
        'strict'                        => \$strict,
        'stricter'                      => \$stricter,
        'keep_ends_without_biotype'     => \$keep_ends_without_biotype,
        'keep_regions_without_ends'     => \$keep_regions_without_ends,
        'keep_ends_near_n'              => \$keep_ends_near_n,
        'keep_ends_far_from_annotation' => \$keep_ends_far_from_annotation,
        'keep_ends_beyond_five_prime'   => \$keep_ends_beyond_five_prime,
        'keep_ends_in_cds'              => \$keep_ends_in_cds,
        'keep_ends_in_simple_repeat'    => \$keep_ends_in_simple_repeat,
        'keep_ends_in_simple_repeat_if_coding' =>
          \$keep_ends_in_simple_repeat_if_coding,
        'keep_ends_in_simple_repeat_if_other' =>
          \$keep_ends_in_simple_repeat_if_other,
        'keep_ends_in_transposon'   => \$keep_ends_in_transposon,
        'keep_polya_strict_ends'    => \$keep_polya_strict_ends,
        'keep_polya_stricter_ends'  => \$keep_polya_stricter_ends,
        'keep_ends_without_hexamer' => \$keep_ends_without_hexamer,
        'keep_ends_without_rnaseq'  => \$keep_ends_without_rnaseq,
        'keep_ends_without_rnaseq_if_coding' =>
          \$keep_ends_without_rnaseq_if_coding,
        'keep_ends_without_rnaseq_if_other' =>
          \$keep_ends_without_rnaseq_if_other,
        'polya_threshold=i'            => \$polya_threshold,
        'downstream_polya_threshold=i' => \$downstream_polya_threshold,
        'hexamer_polya_threshold=i'    => \$hexamer_polya_threshold,
        'annotated_distance_threshold_coding' =>
          \$annotated_distance_threshold_coding,
        'annotated_distance_threshold_other' =>
          \$annotated_distance_threshold_other,
        'log'  => \$log,
        'help' => \$help,
        'man'  => \$man,
    ) or pod2usage(2);

    # Documentation
    if ($help) {
        pod2usage(1);
    }
    elsif ($man) {
        pod2usage( -verbose => 2 );
    }

    # Check options
    if ( !$all_file ) {
        pod2usage("--all_file must be specified\n");
    }
    if ( !$ends_file ) {
        pod2usage("--ends_file must be specified\n");
    }
    if ( $strict && $stricter ) {
        pod2usage("Can't specify both --strict and --stricter\n");
    }

    if ($keep_ends_in_simple_repeat) {
        $keep_ends_in_simple_repeat_if_coding = 1;
        $keep_ends_in_simple_repeat_if_other  = 1;
    }
    if ($keep_ends_without_rnaseq) {
        $keep_ends_without_rnaseq_if_coding = 1;
        $keep_ends_without_rnaseq_if_other  = 1;
    }

    if ($strict) {
        $keep_regions_without_ends            = 0;
        $keep_ends_near_n                     = 1;
        $keep_ends_far_from_annotation        = 1;
        $keep_ends_beyond_five_prime          = 1;
        $keep_ends_in_cds                     = 0;
        $keep_ends_in_simple_repeat           = 1;
        $keep_ends_in_simple_repeat_if_coding = 1;
        $keep_ends_in_simple_repeat_if_other  = 1;
        $keep_ends_in_transposon              = 0;
        $keep_polya_strict_ends               = 0;
        $keep_polya_stricter_ends             = 1;
        $keep_ends_without_hexamer            = 0;
        $keep_ends_without_rnaseq             = 1;
        $keep_ends_without_rnaseq_if_coding   = 1;
        $keep_ends_without_rnaseq_if_other    = 1;
    }
    elsif ($stricter) {
        @biotype =
          qw(protein_coding antisense lincRNA misc_RNA processed_transcript);
        $keep_regions_without_ends            = 0;
        $keep_ends_near_n                     = 0;
        $keep_ends_far_from_annotation        = 0;
        $keep_ends_beyond_five_prime          = 0;
        $keep_ends_in_cds                     = 0;
        $keep_ends_in_simple_repeat           = 0;
        $keep_ends_in_simple_repeat_if_coding = 1;
        $keep_ends_in_simple_repeat_if_other  = 0;
        $keep_ends_in_transposon              = 0;
        $keep_polya_strict_ends               = 1;
        $keep_polya_stricter_ends             = 0;
        $keep_ends_without_hexamer            = 0;
        $keep_ends_without_rnaseq             = 0;
        $keep_ends_without_rnaseq_if_coding   = 1;
        $keep_ends_without_rnaseq_if_other    = 0;
    }

    return;
}

=head1 USAGE

    filter_output.pl
        [--dir directory]
        [--analysis_yaml file]
        [--all_file file]
        [--ends_file file]
        [--slice_regexp regexp]
        [--biotype biotype...]
        [--strict]
        [--stricter]
        [--keep_ends_without_biotype]
        [--keep_regions_without_ends]
        [--keep_ends_near_n]
        [--keep_ends_far_from_annotation]
        [--keep_ends_beyond_five_prime]
        [--keep_ends_in_cds]
        [--keep_ends_in_simple_repeat]
        [--keep_ends_in_simple_repeat_if_coding]
        [--keep_ends_in_simple_repeat_if_other]
        [--keep_ends_in_transposon]
        [--keep_polya_strict_ends]
        [--keep_polya_stricter_ends]
        [--keep_ends_without_hexamer]
        [--keep_ends_without_rnaseq]
        [--keep_ends_without_rnaseq_if_coding]
        [--keep_ends_without_rnaseq_if_other]
        [--polya_threshold int]
        [--downstream_polya_threshold int]
        [--hexamer_polya_threshold int]
        [--annotated_distance_threshold_coding int]
        [--annotated_distance_threshold_other int]
        [--log]
        [--help]
        [--man]

=head1 OPTIONS

=over 8

=item B<--dir DIRECTORY>

Output directory.

=item B<--analysis_yaml FILE>

YAML analysis configuration file.

=item B<--all_file FILE>

DETCT output file (containing all regions).

=item B<--ends_file FILE>

DETCT 3' ends file.

=item B<--slice_regexp REGEXP>

Regular expression for matching slice names.

=item B<--biotype BIOTYPES>

Required biotype(s).

=item B<--strict>

Apply preset "strict" configuration.

=item B<--stricter>

Apply preset "stricter" configuration.

=item B<--keep_ends_without_biotype>

Don't filter 3' ends without required biotype(s).

=item B<--keep_regions_without_ends>

Don't filter out regions lacking a 3' end.

=item B<--keep_ends_near_n>

Don't filter 3' ends with N in surrounding 28 bp.

=item B<--keep_ends_far_from_annotation>

Don't filter 3' ends over set distance from existing annotation.

=item B<--keep_ends_beyond_five_prime>

Don't filter 3' ends beyond 5' end of nearest gene.

=item B<--keep_ends_in_cds>

Don't filter 3' ends in a transcript's CDS.

=item B<--keep_ends_in_simple_repeat>

Don't filter 3' ends in or near a simple repeat.

=item B<--keep_ends_in_simple_repeat_if_coding>

Don't filter 3' ends in or near a simple repeat if nearest transcript is protein
coding.

=item B<--keep_ends_in_simple_repeat_if_other>

Don't filter 3' ends in or near a simple repeat if nearest transcript is not
protein coding.

=item B<--keep_ends_in_transposon>

Don't filter 3' ends in a transposon.

=item B<--keep_polya_strict_ends>

Don't filter out polyA 3' ends. This method is used in --strict.

=item B<--keep_polya_stricter_ends>

Don't filter out polyA 3' ends. This alternative method is used in --stricter.

=item B<--keep_ends_without_hexamer>

Don't filter out 3' ends lacking a primary hexamer.

=item B<--keep_ends_without_rnaseq>

Don't filter out 3' ends lacking continuous RNA-Seq transcripts.

=item B<--keep_ends_without_rnaseq_if_coding>

Don't filter out 3' ends lacking continuous RNA-Seq transcripts if nearest
transcript is protein coding.

=item B<--keep_ends_without_rnaseq_if_other>

Don't filter out 3' ends lacking continuous RNA-Seq transcripts if nearest
transcript is not protein coding.

=item B<--polya_threshold>

The maximum number of As allowed in the 14 bp upstream and 14 bp downstream.

=item B<--downstream_polya_threshold>

The maximum number of As allowed at the start of the 14 bp downstream.

=item B<--hexamer_polya_threshold>

The maximum number of As allowed in the surrounding 28 bp if the 3' end has a
primary hexamer.

=item B<--annotated_distance_threshold_coding>

The minimum distance a 3' end must be from existing protein-coding annotation.

=item B<--annotated_distance_threshold_other>

The minimum distance a 3' end must be from existing other annotation.

=item B<--log>

Log reason for removing each end.

=item B<--help>

Print a brief help message and exit.

=item B<--man>

Print this script's manual page and exit.

=back

=cut
