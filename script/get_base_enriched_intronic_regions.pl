#!/usr/bin/env perl

# PODNAME: get_base_enriched_intronic_regions.pl
# ABSTRACT: Get intronic regions enriched for bases

## Author         : is1
## Maintainer     : is1
## Created        : 2016-03-14
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
use Bio::EnsEMBL::Registry;
use Sort::Naturally;
use DETCT::Misc qw( printf_or_die );

=head1 DESCRIPTION



=head1 EXAMPLES

    perl \
        -Ibranch-ensembl-74/ensembl/modules \
        get_base_enriched_intronic_regions.pl

=cut

# Constants
Readonly our $WINDOW_SIZE     => 100;
Readonly our $SLIDE           => 14;
Readonly our $SLIDE_THRESHOLD => 12;

# Default options
my $species        = 'Danio rerio';
my $ensembl_dbhost = 'ensembldb.ensembl.org';
my $ensembl_dbport;
my $ensembl_dbuser = 'anonymous';
my $ensembl_dbpass;
my $slice_regexp;
my ( $debug, $help, $man );

# Get and check command line options
get_and_check_options();

# Connnect to Ensembl database
Bio::EnsEMBL::Registry->load_registry_from_db(
    -host => $ensembl_dbhost,
    -port => $ensembl_dbport,
    -user => $ensembl_dbuser,
    -pass => $ensembl_dbpass,
);

# Get genebuild version
my $genebuild_version = 'e' . Bio::EnsEMBL::ApiVersion::software_version();
warn 'Genebuild version: ', $genebuild_version, "\n" if $debug;

# Get Ensembl adaptors
my $sa = Bio::EnsEMBL::Registry->get_adaptor( $species, 'core', 'Slice' );

# Ensure database connection isn't lost; Ensembl 64+ can do this more elegantly
## no critic (ProhibitMagicNumbers)
if ( Bio::EnsEMBL::ApiVersion::software_version() < 64 ) {
## use critic
    Bio::EnsEMBL::Registry->set_disconnect_when_inactive();
}
else {
    Bio::EnsEMBL::Registry->set_reconnect_when_lost();
}

# Iterate over each gene
my $slices = $sa->fetch_all('toplevel');
warn scalar @{$slices}, " slices\n" if $debug;
if ($slice_regexp) {
    @{$slices} =
      grep { $_->seq_region_name =~ m/\A $slice_regexp \z/xms } @{$slices};
    warn scalar @{$slices}, " slices after filtering\n" if $debug;
}
foreach my $slice ( sort { ncmp( $a->seq_region_name, $b->seq_region_name ) }
    @{$slices} )
{
    warn 'Slice: ', $slice->name, "\n" if $debug;

    my $genes = $slice->get_all_Genes();
    foreach my $gene ( @{$genes} ) {

        # Get non-redundant introns
        my $nr_introns = get_nr_introns($gene);

        # Get enriched windows in each intron
        get_enriched_windows( $gene, $nr_introns );

        $gene->flush_Transcripts();    # Save memory
    }
}

sub get_nr_introns {
    my ($gene) = @_;

    # Get coordinates for all introns of all transcripts of a gene
    my @intron_coords;
    my $transcripts = $gene->get_all_Transcripts();
    foreach my $transcript ( @{$transcripts} ) {
        my $introns = $transcript->get_all_Introns();
        foreach my $intron ( @{$introns} ) {
            push @intron_coords,
              [ $intron->seq_region_start, $intron->seq_region_end ];
        }
    }

    # Ignore genes without introns
    return [] if !@intron_coords;

    # Collapse to non-overlapping set of intron coordinates
    @intron_coords =
      sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @intron_coords;
    my @nr_intron_coords;
    my $current_min_start = $intron_coords[0]->[0];
    my $current_max_end   = $intron_coords[0]->[1];
    foreach my $coords (@intron_coords) {
        my ( $start, $end ) = @{$coords};
        if ( $start > $current_max_end && $start - $current_max_end != 1 ) {

            # Introns don't overlap and aren't adjacent
            push @nr_intron_coords, [ $current_min_start, $current_max_end ];
            $current_min_start = $start;
            $current_max_end   = $end;
        }
        elsif ( $end > $current_max_end ) {

            # Extend intron
            $current_max_end = $end;
        }
    }
    push @nr_intron_coords, [ $current_min_start, $current_max_end ];

    # Reverse introns if on reverse strand
    if ( $gene->seq_region_strand == -1 ) {
        @nr_intron_coords =
          reverse sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] }
          @nr_intron_coords;
    }

    # Add sequence to each intron
    my @nr_introns;
    foreach my $coords (@nr_intron_coords) {
        my ( $start, $end ) = @{$coords};
        my $slice =
          $sa->fetch_by_region( 'toplevel', $gene->seq_region_name, $start,
            $end, $gene->seq_region_strand );
        push @{$coords}, $slice->seq;

        # Ignore introns with genes on opposite strand
        my $opposite_count    = 0;
        my $overlapping_genes = $slice->get_all_Genes();
        foreach my $overlapping_gene ( @{$overlapping_genes} ) {
            next if $overlapping_gene->stable_id eq $gene->stable_id;
            next
              if $overlapping_gene->seq_region_strand ==
              $gene->seq_region_strand;
            $opposite_count++;
        }
        next if $opposite_count;

        push @nr_introns, $coords;
    }

    return \@nr_introns;
}

sub get_enriched_windows {
    my ( $gene, $nr_introns ) = @_;

    foreach my $intron ( @{$nr_introns} ) {
        my ( $intron_start, $intron_end, $intron_seq ) = @{$intron};
        my $window_start = 0;
        while ( $intron_start + $window_start + $WINDOW_SIZE <= $intron_end ) {
            my $window_seq = substr $intron_seq, $window_start, $WINDOW_SIZE;
            my @enriched_bases = check_enrichment($window_seq);
            if (@enriched_bases) {
                my $start = $intron_start + $window_start;
                my $end   = $intron_start + $window_start + $WINDOW_SIZE - 1;
                if ( $gene->seq_region_strand < 0 ) {
                    $start = $intron_end - $window_start - $WINDOW_SIZE + 1;
                    $end   = $intron_end - $window_start;
                }
                printf_or_die(
                    "%s\t%s\t%d\t%d\t%d\t%s\t%s\n", $gene->stable_id,
                    $gene->seq_region_name,         $gene->seq_region_strand,
                    $start,                         $end,
                    ( join q{,}, @enriched_bases ), $window_seq
                );
            }
            $window_start += $WINDOW_SIZE;
        }
    }

    return;
}

sub check_enrichment {
    my ($seq) = @_;

    my %enriched_base;

    foreach my $base (qw(A C G T)) {

        # Slide across sequence in 14 bp windows
        my $window_start = 0;
        while ( $window_start + $SLIDE < $WINDOW_SIZE ) {
            if ( is_polyn( ( substr $seq, $window_start, $SLIDE ), $base ) ) {
                $enriched_base{$base}++;
            }
            $window_start++;
        }
        if ( !$enriched_base{$base} ) {
            delete $enriched_base{$base};
        }
    }

    my @enriched_bases = sort keys %enriched_base;

    return @enriched_bases;
}

sub is_polyn {
    my ( $seq, $base ) = @_;

    my $is_polyn = 0;

    # Check for 12 or more bases in total out of the 14 bp
    my $n = $seq =~ s/$base/$base/xmsg;
    if ( $n >= $SLIDE_THRESHOLD ) {
        $is_polyn = 1;
    }

    return $is_polyn;
}

# Get and check command line options
sub get_and_check_options {

    # Get options
    GetOptions(
        'species=s'        => \$species,
        'ensembl_dbhost=s' => \$ensembl_dbhost,
        'ensembl_dbport=i' => \$ensembl_dbport,
        'ensembl_dbuser=s' => \$ensembl_dbuser,
        'ensembl_dbpass=s' => \$ensembl_dbpass,
        'slice_regexp=s'   => \$slice_regexp,
        'debug'            => \$debug,
        'help'             => \$help,
        'man'              => \$man,
    ) or pod2usage(2);

    # Documentation
    if ($help) {
        pod2usage(1);
    }
    elsif ($man) {
        pod2usage( -verbose => 2 );
    }

    return;
}

=head1 USAGE

    get_base_enriched_intronic_regions.pl
        [--species species]
        [--ensembl_dbhost host]
        [--ensembl_dbport port]
        [--ensembl_dbuser username]
        [--ensembl_dbpass password]
        [--slice_regexp regexp]
        [--debug]
        [--help]
        [--man]

=head1 OPTIONS

=over 8

=item B<--species SPECIES>

Species (defaults to Danio rerio).

=item B<--ensembl_dbhost HOST>

Ensembl MySQL database host.

=item B<--ensembl_dbport PORT>

Ensembl MySQL database port.

=item B<--ensembl_dbuser USERNAME>

Ensembl MySQL database username.

=item B<--ensembl_dbpass PASSWORD>

Ensembl MySQL database password.

=item B<--slice_regexp REGEXP>

Regular expression for matching slice names.

=item B<--debug>

Print debugging information.

=item B<--help>

Print a brief help message and exit.

=item B<--man>

Print this script's manual page and exit.

=back

=cut
