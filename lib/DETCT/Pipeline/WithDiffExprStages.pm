## no critic (RequireUseStrict, RequireUseWarnings, RequireTidyCode)
package DETCT::Pipeline::WithDiffExprStages;
## use critic

# ABSTRACT: Object representing a differential expression pipeline

## Author         : is1
## Maintainer     : is1
## Created        : 2013-01-16
## Last commit by : $Author$
## Last modified  : $Date$
## Revision       : $Revision$
## Repository URL : $HeadURL$

use warnings;
use strict;
use autodie;
use Carp;
use Try::Tiny;

use parent qw(DETCT::Pipeline);

use Class::InsideOut qw( private register id );
use Scalar::Util qw( refaddr );
use YAML qw( DumpFile LoadFile );
use DETCT::GeneFinder;
use DETCT::Misc::BAM qw(
  count_tags
  bin_reads
  get_read_peaks
  get_three_prime_ends
  merge_three_prime_ends
  filter_three_prime_ends
  choose_three_prime_end
  count_reads
  merge_read_counts
);
use DETCT::Misc::PeakHMM qw(
  merge_read_peaks
  summarise_read_peaks
  run_peak_hmm
  join_hmm_bins
);
use DETCT::Misc::R qw(
  run_deseq
);
use DETCT::Misc::Output qw(
  dump_as_table
);

=head1 SYNOPSIS

    # Brief code examples

=cut

=method all_parameters_by_bam_file_then_chunk

  Usage       : all_parameters_by_bam_file_then_chunk();
  Purpose     : Get all parameters for stage that requires jobs split up by BAM
                file then by chunk
  Returns     : Array of arrayrefs
  Parameters  : None
  Throws      : No exceptions
  Comments    : None

=cut

sub all_parameters_by_bam_file_then_chunk {
    my ($self) = @_;

    my @all_parameters;

    my $chunks = $self->analysis->get_all_chunks();

    foreach my $bam_file ( $self->analysis->list_all_bam_files() ) {
        my @tags = $self->analysis->list_all_tags_by_bam_file($bam_file);
        foreach my $chunk ( @{$chunks} ) {
            push @all_parameters, [ $bam_file, $chunk, @tags ];
        }
    }

    return @all_parameters;
}

=method all_parameters_for_count_tags

  Usage       : all_parameters_for_count_tags();
  Purpose     : Get all parameters for count_tags stage
  Returns     : Array of arrayrefs
  Parameters  : None
  Throws      : No exceptions
  Comments    : None

=cut

sub all_parameters_for_count_tags {
    my ($self) = @_;

    return $self->all_parameters_by_bam_file_then_chunk();
}

=method run_count_tags

  Usage       : run_count_tags();
  Purpose     : Run function for count_tags stage
  Returns     : undef
  Parameters  : DETCT::Pipeline::Job
  Throws      : No exceptions
  Comments    : None

=cut

sub run_count_tags {
    my ( $self, $job ) = @_;

    my ( $bam_file, $chunk, @tags ) = @{ $job->parameters };

    my %chunk_count;

    # Get count for each sequence of a chunk separately and then merge
    foreach my $seq ( @{$chunk} ) {
        my $seq_count = count_tags(
            {
                bam_file           => $bam_file,
                mismatch_threshold => $self->analysis->mismatch_threshold,
                seq_name           => $seq->name,
                tags               => \@tags,
            }
        );
        %chunk_count =
          %{ $self->hash_merge->merge( \%chunk_count, $seq_count ) };
    }

    my $output_file = $job->base_filename . '.out';

    DumpFile( $output_file, \%chunk_count );

    return;
}

=method all_parameters_for_bin_reads

  Usage       : all_parameters_for_bin_reads();
  Purpose     : Get all parameters for bin_reads stage
  Returns     : Array of arrayrefs
  Parameters  : None
  Throws      : No exceptions
  Comments    : None

=cut

sub all_parameters_for_bin_reads {
    my ($self) = @_;

    return $self->all_parameters_by_bam_file_then_chunk();
}

=method run_bin_reads

  Usage       : run_bin_reads();
  Purpose     : Run function for bin_reads stage
  Returns     : undef
  Parameters  : DETCT::Pipeline::Job
  Throws      : No exceptions
  Comments    : None

=cut

sub run_bin_reads {
    my ( $self, $job ) = @_;

    my ( $bam_file, $chunk, @tags ) = @{ $job->parameters };

    my %chunk_bins;

    # Get bins for each sequence of a chunk separately and then merge
    foreach my $seq ( @{$chunk} ) {
        my $seq_bins = bin_reads(
            {
                bam_file           => $bam_file,
                mismatch_threshold => $self->analysis->mismatch_threshold,
                bin_size           => $self->analysis->bin_size,
                seq_name           => $seq->name,
                tags               => \@tags,
            }
        );
        %chunk_bins = %{ $self->hash_merge->merge( \%chunk_bins, $seq_bins ) };
    }

    my $output_file = $job->base_filename . '.out';

    DumpFile( $output_file, \%chunk_bins );

    return;
}

=method all_parameters_for_get_read_peaks

  Usage       : all_parameters_for_get_read_peaks();
  Purpose     : Get all parameters for get_read_peaks stage
  Returns     : Array of arrayrefs
  Parameters  : None
  Throws      : No exceptions
  Comments    : None

=cut

sub all_parameters_for_get_read_peaks {
    my ($self) = @_;

    return $self->all_parameters_by_bam_file_then_chunk();
}

=method run_get_read_peaks

  Usage       : run_get_read_peaks();
  Purpose     : Run function for get_read_peaks stage
  Returns     : undef
  Parameters  : DETCT::Pipeline::Job
  Throws      : No exceptions
  Comments    : None

=cut

sub run_get_read_peaks {
    my ( $self, $job ) = @_;

    my ( $bam_file, $chunk, @tags ) = @{ $job->parameters };

    my %chunk_peaks;

    # Get read peaks for each sequence of a chunk separately and then merge
    foreach my $seq ( @{$chunk} ) {
        my $seq_peaks = get_read_peaks(
            {
                bam_file           => $bam_file,
                mismatch_threshold => $self->analysis->mismatch_threshold,
                peak_buffer_width  => $self->analysis->peak_buffer_width,
                seq_name           => $seq->name,
                tags               => \@tags,
            }
        );
        %chunk_peaks =
          %{ $self->hash_merge->merge( \%chunk_peaks, $seq_peaks ) };
    }

    my $output_file = $job->base_filename . '.out';

    DumpFile( $output_file, \%chunk_peaks );

    return;
}

=method all_parameters_for_merge_read_peaks

  Usage       : all_parameters_for_merge_read_peaks();
  Purpose     : Get all parameters for merge_read_peaks stage
  Returns     : Array of arrayrefs
  Parameters  : None
  Throws      : No exceptions
  Comments    : None

=cut

sub all_parameters_for_merge_read_peaks {
    my ($self) = @_;

    my @all_parameters;

    my $chunks = $self->analysis->get_all_chunks();

    # Work out which get_read_peaks stage files need to be combined
    foreach my $merge_chunk ( @{$chunks} ) {
        my @get_read_peaks_output_files;
        my $component = 0;
        foreach my $bam_file ( $self->analysis->list_all_bam_files() ) {
            foreach my $get_chunk ( @{$chunks} ) {
                $component++;
                if ( refaddr($merge_chunk) == refaddr($get_chunk) ) {
                    my $output_file =
                      $self->get_and_check_output_file( 'get_read_peaks',
                        $component );
                    push @get_read_peaks_output_files, $output_file;
                }
            }
        }
        push @all_parameters, [ $merge_chunk, @get_read_peaks_output_files ];
    }

    return @all_parameters;
}

=method run_merge_read_peaks

  Usage       : run_merge_read_peaks();
  Purpose     : Run function for merge_read_peaks stage
  Returns     : undef
  Parameters  : DETCT::Pipeline::Job
  Throws      : No exceptions
  Comments    : None

=cut

sub run_merge_read_peaks {
    my ( $self, $job ) = @_;

    my ( $chunk, @get_read_peaks_output_files ) = @{ $job->parameters };

    # Join lists of peaks
    my %unmerged_peaks;
    foreach my $output_file (@get_read_peaks_output_files) {
        %unmerged_peaks = %{
            $self->hash_merge->merge(
                \%unmerged_peaks, LoadFile($output_file)
            )
        };
    }

    my %chunk_peaks;

    # Merge read peaks for each sequence of a chunk separately
    foreach my $seq ( @{$chunk} ) {
        foreach my $strand (1, -1) {
            my $seq_peaks = merge_read_peaks(
                {
                    peak_buffer_width => $self->analysis->peak_buffer_width,
                    seq_name          => $seq->name,
                    strand            => $strand,
                    peaks             => $unmerged_peaks{$seq->name}->{$strand},
                }
            );
            %chunk_peaks =
              %{ $self->hash_merge->merge( \%chunk_peaks, $seq_peaks ) };
        }
    }

    my $output_file = $job->base_filename . '.out';

    DumpFile( $output_file, \%chunk_peaks );

    return;
}

=method all_parameters_for_summarise_read_peaks

  Usage       : all_parameters_for_summarise_read_peaks();
  Purpose     : Get all parameters for summarise_read_peaks stage
  Returns     : Array of arrayrefs
  Parameters  : None
  Throws      : No exceptions
  Comments    : None

=cut

sub all_parameters_for_summarise_read_peaks {
    my ($self) = @_;

    my @all_parameters;

    my $chunks = $self->analysis->get_all_chunks();

    my $component = 0;
    foreach my $chunk ( @{$chunks} ) {
        $component++;
        my $merge_read_peaks_output_file =
          $self->get_and_check_output_file( 'merge_read_peaks', $component );
        push @all_parameters, [ $chunk, $merge_read_peaks_output_file ];
    }

    return @all_parameters;
}

=method run_summarise_read_peaks

  Usage       : run_summarise_read_peaks();
  Purpose     : Run function for summarise_read_peaks stage
  Returns     : undef
  Parameters  : DETCT::Pipeline::Job
  Throws      : No exceptions
  Comments    : None

=cut

sub run_summarise_read_peaks {
    my ( $self, $job ) = @_;

    my ( $chunk, $merge_read_peaks_output_file ) = @{ $job->parameters };

    # Get merged peaks
    my %merged_peaks = %{ LoadFile($merge_read_peaks_output_file) };

    my %chunk_summary;

    # Summarise read peaks for each sequence of a chunk separately
    foreach my $seq ( @{$chunk} ) {
        my $seq_summary = summarise_read_peaks(
            {
                bin_size          => $self->analysis->bin_size,
                peak_buffer_width => $self->analysis->peak_buffer_width,
                hmm_sig_level     => $self->analysis->hmm_sig_level,
                seq_name          => $seq->name,
                seq_bp            => $seq->bp,
                read_length       => $self->analysis->read2_length,
                peaks             => $merged_peaks{ $seq->name },
            }
        );
        %chunk_summary =
          %{ $self->hash_merge->merge( \%chunk_summary, $seq_summary ) };
    }

    my $output_file = $job->base_filename . '.out';

    DumpFile( $output_file, \%chunk_summary );

    return;
}

=method all_parameters_for_run_peak_hmm

  Usage       : all_parameters_for_run_peak_hmm();
  Purpose     : Get all parameters for run_peak_hmm stage
  Returns     : Array of arrayrefs
  Parameters  : None
  Throws      : No exceptions
  Comments    : None

=cut

sub all_parameters_for_run_peak_hmm {
    my ($self) = @_;

    my @all_parameters;

    my $chunks = $self->analysis->get_all_chunks();

    # Work out which bin_reads stage files need to be combined
    my $component = 0;
    foreach my $hmm_chunk ( @{$chunks} ) {
        $component++;
        my @bin_reads_output_files;
        my $bin_component = 0;
        foreach my $bam_file ( $self->analysis->list_all_bam_files() ) {
            foreach my $bin_chunk ( @{$chunks} ) {
                $bin_component++;
                if ( refaddr($hmm_chunk) == refaddr($bin_chunk) ) {
                    my $bin_output_file =
                      $self->get_and_check_output_file( 'bin_reads',
                        $bin_component );
                    push @bin_reads_output_files, $bin_output_file;
                }
            }
        }
        my $summary_output_file =
          $self->get_and_check_output_file( 'summarise_read_peaks',
            $component );
        push @all_parameters,
          [ $hmm_chunk, $summary_output_file, @bin_reads_output_files ];
    }

    return @all_parameters;
}

=method run_run_peak_hmm

  Usage       : run_run_peak_hmm();
  Purpose     : Run function for run_peak_hmm stage
  Returns     : undef
  Parameters  : DETCT::Pipeline::Job
  Throws      : No exceptions
  Comments    : None

=cut

sub run_run_peak_hmm {
    my ( $self, $job ) = @_;

    my ( $chunk, $summary_output_file, @bin_reads_output_files ) =
      @{ $job->parameters };

    # Join read bins
    my %read_bins;
    foreach my $output_file (@bin_reads_output_files) {
        %read_bins =
          %{ $self->hash_merge->merge( \%read_bins, LoadFile($output_file) ) };
    }

    # Load summary
    my $summary = LoadFile($summary_output_file);

    my %chunk_hmm;

    # Run peak HMM for each sequence of a chunk separately
    foreach my $seq ( @{$chunk} ) {
        my $seq_hmm = run_peak_hmm(
            {
                dir           => $job->base_filename,
                hmm_sig_level => $self->analysis->hmm_sig_level,
                seq_name      => $seq->name,
                read_bins     => $read_bins{ $seq->name },
                summary       => $summary->{ $seq->name },
                hmm_binary    => $self->analysis->hmm_binary,
            }
        );
        %chunk_hmm = %{ $self->hash_merge->merge( \%chunk_hmm, $seq_hmm ) };
    }

    my $output_file = $job->base_filename . '.out';

    DumpFile( $output_file, \%chunk_hmm );

    return;
}

=method all_parameters_for_join_hmm_bins

  Usage       : all_parameters_for_join_hmm_bins();
  Purpose     : Get all parameters for join_hmm_bins stage
  Returns     : Array of arrayrefs
  Parameters  : None
  Throws      : No exceptions
  Comments    : None

=cut

sub all_parameters_for_join_hmm_bins {
    my ($self) = @_;

    my @all_parameters;

    my $chunks = $self->analysis->get_all_chunks();

    my $component = 0;
    foreach my $chunk ( @{$chunks} ) {
        $component++;
        my $run_peak_hmm_output_file =
          $self->get_and_check_output_file( 'run_peak_hmm', $component );
        push @all_parameters, [ $chunk, $run_peak_hmm_output_file ];
    }

    return @all_parameters;
}

=method run_join_hmm_bins

  Usage       : run_join_hmm_bins();
  Purpose     : Run function for join_hmm_bins stage
  Returns     : undef
  Parameters  : DETCT::Pipeline::Job
  Throws      : No exceptions
  Comments    : None

=cut

sub run_join_hmm_bins {
    my ( $self, $job ) = @_;

    my ( $chunk, $run_peak_hmm_output_file ) = @{ $job->parameters };

    # Get HMM bins
    my $hmm_bins = LoadFile($run_peak_hmm_output_file);

    my %chunk_regions;

    # Join HMM bins for each sequence of a chunk separately
    foreach my $seq ( @{$chunk} ) {
        my $seq_regions = join_hmm_bins(
            {
                bin_size => $self->analysis->bin_size,
                seq_name => $seq->name,
                hmm_bins => $hmm_bins->{ $seq->name },
            }
        );
        %chunk_regions =
          %{ $self->hash_merge->merge( \%chunk_regions, $seq_regions ) };
    }

    my $output_file = $job->base_filename . '.out';

    DumpFile( $output_file, \%chunk_regions );

    return;
}

=method all_parameters_for_get_three_prime_ends

  Usage       : all_parameters_for_get_three_prime_ends();
  Purpose     : Get all parameters for get_three_prime_ends stage
  Returns     : Array of arrayrefs
  Parameters  : None
  Throws      : No exceptions
  Comments    : None

=cut

sub all_parameters_for_get_three_prime_ends {
    my ($self) = @_;

    my @all_parameters;

    my $chunks = $self->analysis->get_all_chunks();

    foreach my $bam_file ( $self->analysis->list_all_bam_files() ) {
        my @tags      = $self->analysis->list_all_tags_by_bam_file($bam_file);
        my $component = 0;
        foreach my $chunk ( @{$chunks} ) {
            $component++;
            my $join_hmm_bins_output_file =
              $self->get_and_check_output_file( 'join_hmm_bins', $component );
            push @all_parameters,
              [ $chunk, $bam_file, $join_hmm_bins_output_file, @tags ];
        }
    }

    return @all_parameters;
}

=method run_get_three_prime_ends

  Usage       : run_get_three_prime_ends();
  Purpose     : Run function for get_three_prime_ends stage
  Returns     : undef
  Parameters  : DETCT::Pipeline::Job
  Throws      : No exceptions
  Comments    : None

=cut

sub run_get_three_prime_ends {
    my ( $self, $job ) = @_;

    my ( $chunk, $bam_file, $join_hmm_bins_output_file, @tags ) =
      @{ $job->parameters };

    # Get regions
    my $regions = LoadFile($join_hmm_bins_output_file);

    my %chunk_regions;

    # Get 3' ends for each sequence of a chunk separately
    foreach my $seq ( @{$chunk} ) {
        my $seq_regions = get_three_prime_ends(
            {
                bam_file           => $bam_file,
                mismatch_threshold => $self->analysis->mismatch_threshold,
                seq_name           => $seq->name,
                tags               => \@tags,
                regions            => $regions->{ $seq->name },
            }
        );
        %chunk_regions =
          %{ $self->hash_merge->merge( \%chunk_regions, $seq_regions ) };
    }

    my $output_file = $job->base_filename . '.out';

    DumpFile( $output_file, \%chunk_regions );

    return;
}

=method all_parameters_for_merge_three_prime_ends

  Usage       : all_parameters_for_merge_three_prime_ends();
  Purpose     : Get all parameters for merge_three_prime_ends stage
  Returns     : Array of arrayrefs
  Parameters  : None
  Throws      : No exceptions
  Comments    : None

=cut

sub all_parameters_for_merge_three_prime_ends {
    my ($self) = @_;

    my @all_parameters;

    my $chunks = $self->analysis->get_all_chunks();

    # Work out which get_three_prime_ends stage files need to be merged
    foreach my $merge_chunk ( @{$chunks} ) {
        my @get_three_prime_ends_output_files;
        my $component = 0;
        foreach my $bam_file ( $self->analysis->list_all_bam_files() ) {
            foreach my $run_chunk ( @{$chunks} ) {
                $component++;
                if ( refaddr($merge_chunk) == refaddr($run_chunk) ) {
                    my $output_file =
                      $self->get_and_check_output_file( 'get_three_prime_ends',
                        $component );
                    push @get_three_prime_ends_output_files, $output_file;
                }
            }
        }
        push @all_parameters,
          [ $merge_chunk, @get_three_prime_ends_output_files ];
    }

    return @all_parameters;
}

=method run_merge_three_prime_ends

  Usage       : run_merge_three_prime_ends();
  Purpose     : Run function for merge_three_prime_ends stage
  Returns     : undef
  Parameters  : DETCT::Pipeline::Job
  Throws      : No exceptions
  Comments    : None

=cut

sub run_merge_three_prime_ends {
    my ( $self, $job ) = @_;

    my ( $chunk, @get_three_prime_ends_output_files ) = @{ $job->parameters };

    # Load all regions
    my @list_of_lists_of_regions;
    foreach my $output_file (@get_three_prime_ends_output_files) {
        my $regions = LoadFile($output_file);
        push @list_of_lists_of_regions, $regions;
    }

    my %chunk_regions;

    # Merge 3' ends for each sequence of a chunk separately
    foreach my $seq ( @{$chunk} ) {
        my @regions = map { $_->{ $seq->name } } @list_of_lists_of_regions;
        my $seq_regions = merge_three_prime_ends(
            {
                seq_name => $seq->name,
                regions  => \@regions,
            }
        );
        %chunk_regions =
          %{ $self->hash_merge->merge( \%chunk_regions, $seq_regions ) };
    }

    my $output_file = $job->base_filename . '.out';

    DumpFile( $output_file, \%chunk_regions );

    return;
}

=method all_parameters_for_filter_three_prime_ends

  Usage       : all_parameters_for_filter_three_prime_ends();
  Purpose     : Get all parameters for filter_three_prime_ends stage
  Returns     : Array of arrayrefs
  Parameters  : None
  Throws      : No exceptions
  Comments    : None

=cut

sub all_parameters_for_filter_three_prime_ends {
    my ($self) = @_;

    my @all_parameters;

    my $chunks = $self->analysis->get_all_chunks();

    my $component = 0;
    foreach my $chunk ( @{$chunks} ) {
        $component++;
        my $merge_three_prime_ends_output_file =
          $self->get_and_check_output_file( 'merge_three_prime_ends',
            $component );
        push @all_parameters, [ $chunk, $merge_three_prime_ends_output_file ];
    }

    return @all_parameters;
}

=method run_filter_three_prime_ends

  Usage       : run_filter_three_prime_ends();
  Purpose     : Run function for filter_three_prime_ends stage
  Returns     : undef
  Parameters  : DETCT::Pipeline::Job
  Throws      : No exceptions
  Comments    : None

=cut

sub run_filter_three_prime_ends {
    my ( $self, $job ) = @_;

    my ( $chunk, $merge_three_prime_ends_output_file ) = @{ $job->parameters };

    # Get regions
    my $regions = LoadFile($merge_three_prime_ends_output_file);

    my %chunk_regions;

    # Filter 3' ends for each sequence of a chunk separately
    foreach my $seq ( @{$chunk} ) {
        my $seq_regions = filter_three_prime_ends(
            {
                analysis => $self->analysis,
                seq_name => $seq->name,
                regions  => $regions->{ $seq->name },
            }
        );
        %chunk_regions =
          %{ $self->hash_merge->merge( \%chunk_regions, $seq_regions ) };
    }

    my $output_file = $job->base_filename . '.out';

    DumpFile( $output_file, \%chunk_regions );

    return;
}

=method all_parameters_for_choose_three_prime_end

  Usage       : all_parameters_for_choose_three_prime_end();
  Purpose     : Get all parameters for choose_three_prime_end stage
  Returns     : Array of arrayrefs
  Parameters  : None
  Throws      : No exceptions
  Comments    : None

=cut

sub all_parameters_for_choose_three_prime_end {
    my ($self) = @_;

    my @all_parameters;

    my $chunks = $self->analysis->get_all_chunks();

    my $component = 0;
    foreach my $chunk ( @{$chunks} ) {
        $component++;
        my $filter_three_prime_ends_output_file =
          $self->get_and_check_output_file( 'filter_three_prime_ends',
            $component );
        push @all_parameters, [ $chunk, $filter_three_prime_ends_output_file ];
    }

    return @all_parameters;
}

=method run_choose_three_prime_end

  Usage       : run_choose_three_prime_end();
  Purpose     : Run function for choose_three_prime_end stage
  Returns     : undef
  Parameters  : DETCT::Pipeline::Job
  Throws      : No exceptions
  Comments    : None

=cut

sub run_choose_three_prime_end {
    my ( $self, $job ) = @_;

    my ( $chunk, $filter_three_prime_ends_output_file ) = @{ $job->parameters };

    # Get regions
    my $regions = LoadFile($filter_three_prime_ends_output_file);

    my %chunk_regions;

    # Choose 3' ends for each sequence of a chunk separately
    foreach my $seq ( @{$chunk} ) {
        my $seq_regions = choose_three_prime_end(
            {
                seq_name => $seq->name,
                regions  => $regions->{ $seq->name },
            }
        );
        %chunk_regions =
          %{ $self->hash_merge->merge( \%chunk_regions, $seq_regions ) };
    }

    my $output_file = $job->base_filename . '.out';

    DumpFile( $output_file, \%chunk_regions );

    return;
}

=method all_parameters_for_count_reads

  Usage       : all_parameters_for_count_reads();
  Purpose     : Get all parameters for count_reads stage
  Returns     : Array of arrayrefs
  Parameters  : None
  Throws      : No exceptions
  Comments    : None

=cut

sub all_parameters_for_count_reads {
    my ($self) = @_;

    my @all_parameters;

    my $chunks = $self->analysis->get_all_chunks();

    foreach my $bam_file ( $self->analysis->list_all_bam_files() ) {
        my @tags      = $self->analysis->list_all_tags_by_bam_file($bam_file);
        my $component = 0;
        foreach my $chunk ( @{$chunks} ) {
            $component++;
            my $choose_three_prime_end_output_file =
              $self->get_and_check_output_file( 'choose_three_prime_end',
                $component );
            push @all_parameters,
              [ $chunk, $bam_file, $choose_three_prime_end_output_file, @tags ];
        }
    }

    return @all_parameters;
}

=method run_count_reads

  Usage       : run_count_reads();
  Purpose     : Run function for count_reads stage
  Returns     : undef
  Parameters  : DETCT::Pipeline::Job
  Throws      : No exceptions
  Comments    : None

=cut

sub run_count_reads {
    my ( $self, $job ) = @_;

    my ( $chunk, $bam_file, $choose_three_prime_end_output_file, @tags ) =
      @{ $job->parameters };

    # Get regions
    my $regions = LoadFile($choose_three_prime_end_output_file);

    my %chunk_regions;

    # Count reads for each sequence of a chunk separately
    foreach my $seq ( @{$chunk} ) {
        my $seq_regions = count_reads(
            {
                bam_file           => $bam_file,
                mismatch_threshold => $self->analysis->mismatch_threshold,
                seq_name           => $seq->name,
                regions            => $regions->{ $seq->name },
                tags               => \@tags,
            }
        );
        %chunk_regions =
          %{ $self->hash_merge->merge( \%chunk_regions, $seq_regions ) };
    }

    my $output_file = $job->base_filename . '.out';

    DumpFile( $output_file, \%chunk_regions );

    return;
}

=method all_parameters_for_merge_read_counts

  Usage       : all_parameters_for_merge_read_counts();
  Purpose     : Get all parameters for merge_read_counts stage
  Returns     : Array of arrayrefs
  Parameters  : None
  Throws      : No exceptions
  Comments    : None

=cut

sub all_parameters_for_merge_read_counts {
    my ($self) = @_;

    my @all_parameters;

    my $chunks = $self->analysis->get_all_chunks();

    # Work out which count_reads stage files need to be merged
    foreach my $merge_chunk ( @{$chunks} ) {
        my %output_file_for;
        my $component = 0;
        foreach my $bam_file ( $self->analysis->list_all_bam_files() ) {
            foreach my $run_chunk ( @{$chunks} ) {
                $component++;
                if ( refaddr($merge_chunk) == refaddr($run_chunk) ) {
                    my $output_file =
                      $self->get_and_check_output_file( 'count_reads',
                        $component );
                    $output_file_for{$bam_file} = $output_file;
                }
            }
        }
        push @all_parameters, [ $merge_chunk, %output_file_for ];
    }

    return @all_parameters;
}

=method run_merge_read_counts

  Usage       : run_merge_read_counts();
  Purpose     : Run function for merge_read_counts stage
  Returns     : undef
  Parameters  : DETCT::Pipeline::Job
  Throws      : No exceptions
  Comments    : None

=cut

sub run_merge_read_counts {
    my ( $self, $job ) = @_;

    my ( $chunk, %output_file_for ) = @{ $job->parameters };

    # Load all regions
    my %hash_of_lists_of_regions;
    foreach my $bam_file ( keys %output_file_for ) {
        my $regions = LoadFile( $output_file_for{$bam_file} );
        $hash_of_lists_of_regions{$bam_file} = $regions;
    }

    my %chunk_regions;

    # Merge read counts for each sequence of a chunk separately
    foreach my $seq ( @{$chunk} ) {

        # Hash keyed by BAM file
        my %regions =
          map { $_ => $hash_of_lists_of_regions{$_}->{ $seq->name } }
          keys %hash_of_lists_of_regions;
        my $seq_regions = merge_read_counts(
            {
                seq_name => $seq->name,
                regions  => \%regions,
                samples  => $self->analysis->get_all_samples(),
            }
        );
        %chunk_regions =
          %{ $self->hash_merge->merge( \%chunk_regions, $seq_regions ) };
    }

    my $output_file = $job->base_filename . '.out';

    DumpFile( $output_file, \%chunk_regions );

    return;
}

=method all_parameters_for_run_deseq

  Usage       : all_parameters_for_run_deseq();
  Purpose     : Get all parameters for run_deseq stage
  Returns     : Arrayref
  Parameters  : None
  Throws      : No exceptions
  Comments    : None

=cut

sub all_parameters_for_run_deseq {
    my ($self) = @_;

    my @all_parameters;

    my $chunks = $self->analysis->get_all_chunks();

    my @merge_read_counts_output_files;
    my $component = 0;
    foreach my $chunk ( @{$chunks} ) {
        $component++;
        push @merge_read_counts_output_files,
          $self->get_and_check_output_file( 'merge_read_counts', $component );
    }
    push @all_parameters, \@merge_read_counts_output_files;

    return @all_parameters;
}

=method run_run_deseq

  Usage       : run_run_deseq();
  Purpose     : Run function for run_deseq stage
  Returns     : undef
  Parameters  : DETCT::Pipeline::Job
  Throws      : No exceptions
  Comments    : None

=cut

sub run_run_deseq {
    my ( $self, $job ) = @_;

    my (@merge_read_counts_output_files) = @{ $job->parameters };

    # Join regions
    my %regions;
    foreach my $output_file (@merge_read_counts_output_files) {
        %regions =
          %{ $self->hash_merge->merge( \%regions, LoadFile($output_file) ) };
    }

    my $regions_ref = run_deseq(
        {
            dir          => $job->base_filename,
            regions      => \%regions,
            samples      => $self->analysis->get_all_samples(),
            r_binary     => $self->analysis->r_binary,
            deseq_script => $self->analysis->deseq_script,
        }
    );

    my $output_file = $job->base_filename . '.out';

    DumpFile( $output_file, $regions_ref );

    return;
}

=method all_parameters_for_add_gene_annotation

  Usage       : all_parameters_for_add_gene_annotation();
  Purpose     : Get all parameters for add_gene_annotation stage
  Returns     : Arrayref
  Parameters  : None
  Throws      : No exceptions
  Comments    : None

=cut

sub all_parameters_for_add_gene_annotation {
    my ($self) = @_;

    my @all_parameters;

    my $run_deseq_output_file =
      $self->get_and_check_output_file( 'run_deseq', 1 );

    push @all_parameters, [$run_deseq_output_file];

    return @all_parameters;
}

=method run_add_gene_annotation

  Usage       : run_add_gene_annotation();
  Purpose     : Run function for add_gene_annotation stage
  Returns     : undef
  Parameters  : DETCT::Pipeline::Job
  Throws      : No exceptions
  Comments    : None

=cut

sub run_add_gene_annotation {
    my ( $self, $job ) = @_;

    my ($run_deseq_output_file) = @{ $job->parameters };

    # Get regions
    my $regions = LoadFile($run_deseq_output_file);

    # Annotate 3' ends with genes
    # Could split regions by chunk if slow
    my $gene_finder = DETCT::GeneFinder->new(
        { slice_adaptor => $self->analysis->slice_adaptor, } );
    my $annotated_regions_ref = $gene_finder->add_gene_annotation($regions);

    my $output_file = $job->base_filename . '.out';

    DumpFile( $output_file, $annotated_regions_ref );

    return;
}

=method all_parameters_for_dump_as_table

  Usage       : all_parameters_for_dump_as_table();
  Purpose     : Get all parameters for dump_as_table stage
  Returns     : Arrayref
  Parameters  : None
  Throws      : No exceptions
  Comments    : None

=cut

sub all_parameters_for_dump_as_table {
    my ($self) = @_;

    my @all_parameters;

    my $add_gene_annotation_output_file =
      $self->get_and_check_output_file( 'add_gene_annotation', 1 );

    push @all_parameters, [$add_gene_annotation_output_file];

    return @all_parameters;
}

=method run_dump_as_table

  Usage       : run_dump_as_table();
  Purpose     : Run function for dump_as_table stage
  Returns     : undef
  Parameters  : DETCT::Pipeline::Job
  Throws      : No exceptions
  Comments    : None

=cut

sub run_dump_as_table {
    my ( $self, $job ) = @_;

    my ($add_gene_annotation_output_file) = @{ $job->parameters };

    # Get regions
    my $regions = LoadFile($add_gene_annotation_output_file);

    DETCT::Misc::Output::dump_as_table(
        {
            analysis => $self->analysis,
            dir      => $job->base_filename,
            regions  => $regions,
        }
    );

    my $output_file = $job->base_filename . '.out';

    DumpFile( $output_file, 1 );

    return;
}

1;
