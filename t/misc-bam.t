use Test::More;
use Test::Exception;
use Test::Warn;
use Test::DatabaseRow;
use Test::MockObject;
use Carp;

plan tests => 362;

use DETCT::Misc::BAM qw(
  get_reference_sequence_lengths
  get_sequence
  count_tags
  bin_reads
  get_read_peaks
  get_three_prime_ends
  merge_three_prime_ends
  filter_three_prime_ends
  choose_three_prime_end
  count_reads
  merge_read_counts
  stats
  downsample
);

use File::Temp qw( tempdir );

=for comment

Test random BAM files can be regenerated using:

perl -Ilib script/make_test_sam.pl --seed 10 --seq_region_count 5 \
--seq_region_max_length 10_000 --read_pair_count 100 \
--read_tags NNNNBGAGGC NNNNBAGAAG | samtools view -bS - | samtools sort - test1
perl -Ilib script/make_test_sam.pl --seed 10 --seq_region_count 5 \
--seq_region_max_length 10_000 --read_pair_count 100 \
--read_tags NNNNBCAGAG NNNNBGCACG | samtools view -bS - | samtools sort - test2
perl -Ilib script/make_test_sam.pl --seed 20 --seq_region_count 5 \
--seq_region_max_length 10_000 --read_pair_count 100 \
--read_tags NNNNBCGCAA NNNNBCAAGA | samtools view -bS - | samtools sort - test3
ls *.bam | xargs -n1 samtools index
mv test* t/data/

Some numbers in tests below will then need updating. Code to generate numbers
(using independent methods) is given before each test.

Test random FASTA files can be regenerated using:

perl -Ilib script/make_test_fasta.pl --seed 10 --seq_region_count 5 \
--seq_region_max_length 10_000 > test12.fa
perl -Ilib script/make_test_fasta.pl --seed 20 --seq_region_count 5 \
--seq_region_max_length 10_000 > test3.fa
ls *.fa | xargs -n1 samtools faidx
mv test* t/data/

=cut

my $tmp_dir = tempdir( CLEANUP => 1 );

# Check reference sequence length returned by test BAM file
throws_ok { get_reference_sequence_lengths() } qr/No BAM file specified/ms,
  'No BAM file';
my %bam_length = get_reference_sequence_lengths('t/data/test1.bam');
is( $bam_length{1}, 8789, 'Chr 1 length' );
is( $bam_length{2}, 7958, 'Chr 2 length' );
is( $bam_length{3}, 4808, 'Chr 3 length' );

# Check getting sequence from test FASTA file
# First 10 bp of chromosome 1 should be CCAGGCGCGG according to:

=for comment
head -2 t/data/test12.fa
=cut

throws_ok {
    get_sequence(
        {
            seq_name => '1',
            start    => 1,
            end      => 10,
            strand   => 1,
        }
    );
}
qr/No FASTA index or FASTA file specified/ms, 'No FASTA index or file';
throws_ok {
    get_sequence(
        {
            ref_fasta => 't/data/test12.fa',
            start     => 1,
            end       => 10,
            strand    => 1,
        }
    );
}
qr/No sequence name specified/ms, 'No sequence name';
throws_ok {
    get_sequence(
        {
            ref_fasta => 't/data/test12.fa',
            seq_name  => '1',
            end       => 10,
            strand    => 1,
        }
    );
}
qr/No sequence start specified/ms, 'No sequence start';
throws_ok {
    get_sequence(
        {
            ref_fasta => 't/data/test12.fa',
            seq_name  => '1',
            start     => 1,
            strand    => 1,
        }
    );
}
qr/No sequence end specified/ms, 'No sequence end';
throws_ok {
    get_sequence(
        {
            ref_fasta => 't/data/test12.fa',
            seq_name  => '1',
            start     => 1,
            end       => 10,
        }
    );
}
qr/No sequence strand specified/ms, 'No sequence strand';
my $seq;
$seq = get_sequence(
    {
        ref_fasta => 't/data/test12.fa',
        seq_name  => '1',
        start     => 1,
        end       => 10,
        strand    => 1,
    }
);
is( length $seq, 10,           'Subsequence length' );
is( $seq,        'CCAGGCGCGG', 'Subsequence' );
$seq = get_sequence(
    {
        ref_fasta => 't/data/test12.fa',
        seq_name  => '1',
        start     => 1,
        end       => 10,
        strand    => -1,
    }
);
is( length $seq, 10,           'Reverse complement subsequence length' );
is( $seq,        'CCGCGCCTGG', 'Reverse complement subsequence' );

# Check counting tags required parameters
throws_ok {
    count_tags(
        {
            mismatch_threshold => 2,
            seq_name           => '1',
            tags               => ['NNNNBGAGGC'],
        }
    );
}
qr/No BAM file specified/ms, 'No BAM file';
throws_ok {
    count_tags(
        {
            bam_file => 't/data/test1.bam',
            seq_name => '1',
            tags     => ['NNNNBGAGGC'],
        }
    );
}
qr/No mismatch threshold specified/ms, 'No mismatch threshold';
throws_ok {
    count_tags(
        {
            bam_file           => 't/data/test1.bam',
            mismatch_threshold => 2,
            tags               => ['NNNNBGAGGC'],
        }
    );
}
qr/No sequence name specified/ms, 'No sequence name';
throws_ok {
    count_tags(
        {
            bam_file           => 't/data/test1.bam',
            mismatch_threshold => 2,
            seq_name           => '1',
        }
    );
}
qr/No tags specified/ms, 'No tags';

my $count;

# Check tag counts returned by chromosome 1 of test BAM file
# Should be 43 random tags according to:

=for comment
samtools view -f 128 -F 1028 t/data/test1.bam 1 | awk '{ print $1 }' \
| sed -e 's/.*#//' | grep GAGGC$ | sort -u | wc -l
=cut

$count = count_tags(
    {
        bam_file           => 't/data/test1.bam',
        mismatch_threshold => 100,
        seq_name           => '1',
        tags               => ['NNNNBGAGGC'],
    }
);
is( scalar keys %{$count},                 1,  '1 tag' );
is( scalar keys %{ $count->{NNNNBGAGGC} }, 43, '43 random tags' );

# Check tag counts returned in 1000 bp onwards of chromosome 1 of test BAM file
# Should be 37 random tags according to:

=for comment
samtools view -f 128 -F 1028 t/data/test1.bam 1:1000 | awk '{ print $1 }' \
| sed -e 's/.*#//' | grep GAGGC$ | sort -u | wc -l
=cut

$count = count_tags(
    {
        bam_file           => 't/data/test1.bam',
        mismatch_threshold => 100,
        seq_name           => '1',
        start              => 1000,
        tags               => ['NNNNBGAGGC'],
    }
);
is( scalar keys %{$count},                 1,  '1 tag' );
is( scalar keys %{ $count->{NNNNBGAGGC} }, 37, '37 random tags' );

# Check tag counts returned in first 1000 bp of chromosome 1 of test BAM file
# Should be 6 random tags according to:

=for comment
samtools view -f 128 -F 1028 t/data/test1.bam 1:1-1000 | awk '{ print $1 }' \
| sed -e 's/.*#//' | grep GAGGC$ | sort -u | wc -l
=cut

$count = count_tags(
    {
        bam_file           => 't/data/test1.bam',
        mismatch_threshold => 100,
        seq_name           => '1',
        start              => 1,
        end                => 1000,
        tags               => ['NNNNBGAGGC'],
    }
);
is( scalar keys %{$count},                 1, '1 tag' );
is( scalar keys %{ $count->{NNNNBGAGGC} }, 6, '6 random tags' );

# Check tag counts returned with low mismatch threshold
# Should be 12 random tags according to:

=for comment
samtools view -f 128 -F 1028 t/data/test1.bam 1 | grep NM:i:0 \
| awk '{ if ($6 == "54M") print $1 }' \
| sed -e 's/.*#//' | grep GAGGC$ | sort -u | wc -l
=cut

$count = count_tags(
    {
        bam_file           => 't/data/test1.bam',
        mismatch_threshold => 0,
        seq_name           => '1',
        tags               => ['NNNNBGAGGC'],
    }
);
is( scalar keys %{$count},                 1,  '1 tag' );
is( scalar keys %{ $count->{NNNNBGAGGC} }, 12, '12 random tags' );

# Check binning reads required parameters
throws_ok {
    bin_reads(
        {
            mismatch_threshold => 2,
            bin_size           => 100,
            seq_name           => '1',
            tags               => ['NNNNBGAGGC'],
        }
    );
}
qr/No BAM file specified/ms, 'No BAM file';
throws_ok {
    bin_reads(
        {
            bam_file => 't/data/test1.bam',
            bin_size => 100,
            seq_name => '1',
            tags     => ['NNNNBGAGGC'],
        }
    );
}
qr/No mismatch threshold specified/ms, 'No mismatch threshold';
throws_ok {
    bin_reads(
        {
            bam_file           => 't/data/test1.bam',
            mismatch_threshold => 2,
            seq_name           => '1',
            tags               => ['NNNNBGAGGC'],
        }
    );
}
qr/No bin size specified/ms, 'No bin size';
throws_ok {
    bin_reads(
        {
            bam_file           => 't/data/test1.bam',
            mismatch_threshold => 2,
            bin_size           => 100,
            tags               => ['NNNNBGAGGC'],
        }
    );
}
qr/No sequence name specified/ms, 'No sequence name';
throws_ok {
    bin_reads(
        {
            bam_file           => 't/data/test1.bam',
            mismatch_threshold => 2,
            bin_size           => 100,
            seq_name           => '1',
        }
    );
}
qr/No tags specified/ms, 'No tags';

# Check read bins returned by test BAM file
# Should be 24 bins on forward strand according to:

=for comment
samtools view -F 1044 t/data/test1.bam 2 | grep 54M | grep NM:i:0 \
| awk '{ print ($4 - 1) / 100 "\t" ($4 + 53 - 1) / 100 }' \
| sed -e 's/\.[0-9]*//g' \
| awk '{ if ($1 == $2) print $1; else print $1 "\n" $2 }' \
| sort | uniq -c | wc -l
=cut

# And 17 bins on reverse strand according to:

=for comment
samtools view -f 16 -F 1028 t/data/test1.bam 2 | grep 54M | grep NM:i:0 \
| awk '{ print ($4 - 1) / 100 "\t" ($4 + 53 - 1) / 100 }' \
| sed -e 's/\.[0-9]*//g' \
| awk '{ if ($1 == $2) print $1; else print $1 "\n" $2 }' \
| sort | uniq -c | wc -l
=cut

$count = bin_reads(
    {
        bam_file           => 't/data/test1.bam',
        mismatch_threshold => 0,
        bin_size           => 100,
        seq_name           => '2',
        tags               => [ 'NNNNBGAGGC', 'NNNNBAGAAG' ],
    }
);
is( scalar keys %{$count},                  1,  '1 sequence' );
is( scalar keys %{ $count->{'2'} },         2,  '2 strands' );
is( scalar keys %{ $count->{'2'}->{'1'} },  24, '24 forward strand bins' );
is( scalar keys %{ $count->{'2'}->{'-1'} }, 17, '17 reverse strand bins' );

# Check read bins returned with non-existent tag
$count = bin_reads(
    {
        bam_file           => 't/data/test1.bam',
        mismatch_threshold => 0,
        bin_size           => 100,
        seq_name           => '1',
        tags               => ['NNNNTTTTTT'],
    }
);
is( scalar keys %{$count},                 1, '1 sequence' );
is( scalar keys %{ $count->{'1'}->{'1'} }, 0, '0 bins' );

# Check getting read peaks required parameters
throws_ok {
    get_read_peaks(
        {
            mismatch_threshold => 0,
            peak_buffer_width  => 100,
            seq_name           => '1',
            tags               => [ 'NNNNBGAGGC', 'NNNNBAGAAG' ],
        }
    );
}
qr/No BAM file specified/ms, 'No BAM file';
throws_ok {
    get_read_peaks(
        {
            bam_file          => 't/data/test1.bam',
            peak_buffer_width => 100,
            seq_name          => '1',
            tags              => [ 'NNNNBGAGGC', 'NNNNBAGAAG' ],
        }
    );
}
qr/No mismatch threshold specified/ms, 'No mismatch threshold';
throws_ok {
    get_read_peaks(
        {
            bam_file           => 't/data/test1.bam',
            mismatch_threshold => 0,
            seq_name           => '1',
            tags               => [ 'NNNNBGAGGC', 'NNNNBAGAAG' ],
        }
    );
}
qr/No peak buffer width specified/ms, 'No peak buffer width';
throws_ok {
    get_read_peaks(
        {
            bam_file           => 't/data/test1.bam',
            mismatch_threshold => 0,
            peak_buffer_width  => 100,
            tags               => [ 'NNNNBGAGGC', 'NNNNBAGAAG' ],
        }
    );
}
qr/No sequence name specified/ms, 'No sequence name';
throws_ok {
    get_read_peaks(
        {
            bam_file           => 't/data/test1.bam',
            mismatch_threshold => 0,
            peak_buffer_width  => 100,
            seq_name           => '1',
        }
    );
}
qr/No tags specified/ms, 'No tags';

my $peaks;

# Check read peaks returned by test BAM file
# First peak on forward strand should be 195 - 294 (3 reads) according to:

=for comment
samtools view -f 128 -F 1044 t/data/test1.bam 2 | grep 54M | grep NM:i:0 \
| awk '{ print $4 "\t" $4 + 53 }' | head -4
=cut

# Last peak on forward strand should be 6450 - 6503 (1 read) according to:

=for comment
samtools view -f 128 -F 1044 t/data/test1.bam 2 | grep 54M | grep NM:i:0 \
| awk '{ print $4 "\t" $4 + 53 }' | tail -4
=cut

# First peak on reverse strand should be 2754 - 2932 (2 reads) according to:

=for comment
samtools view -f 144 -F 1028 t/data/test1.bam 2 | grep 54M | grep NM:i:0 \
| awk '{ print $4 "\t" $4 + 53 }' | head -4
=cut

# Last peak on reverse strand should be 7777 - 7854 (2 reads) according to:

=for comment
samtools view -f 144 -F 1028 t/data/test1.bam 2 | grep 54M | grep NM:i:0 \
| awk '{ print $4 "\t" $4 + 53 }' | tail -4
=cut

$peaks = get_read_peaks(
    {
        bam_file           => 't/data/test1.bam',
        mismatch_threshold => 0,
        peak_buffer_width  => 100,
        seq_name           => '2',
        tags               => [ 'NNNNBGAGGC', 'NNNNBAGAAG' ],
    }
);
is( scalar keys %{$peaks},          1, '1 sequence' );
is( scalar keys %{ $peaks->{'2'} }, 2, '2 strands' );
is( $peaks->{'2'}->{'1'}->[0]->[0],
    195, 'Start of first peak on forward strand' );
is( $peaks->{'2'}->{'1'}->[0]->[1],
    294, 'End of first peak on forward strand' );
is( $peaks->{'2'}->{'1'}->[0]->[2],
    3, 'First peak read count on forward strand' );
is( $peaks->{'2'}->{'1'}->[-1]->[0],
    6450, 'Start of last peak on forward strand' );
is( $peaks->{'2'}->{'1'}->[-1]->[1],
    6503, 'End of last peak on forward strand' );
is( $peaks->{'2'}->{'1'}->[-1]->[2],
    1, 'Last peak read count on forward strand' );
is( $peaks->{'2'}->{'-1'}->[0]->[0],
    2754, 'Start of first peak on reverse strand' );
is( $peaks->{'2'}->{'-1'}->[0]->[1],
    2932, 'End of first peak on reverse strand' );
is( $peaks->{'2'}->{'-1'}->[0]->[2],
    2, 'First peak read count on reverse strand' );
is( $peaks->{'2'}->{'-1'}->[-1]->[0],
    7777, 'Start of last peak on reverse strand' );
is( $peaks->{'2'}->{'-1'}->[-1]->[1],
    7854, 'End of last peak on reverse strand' );
is( $peaks->{'2'}->{'-1'}->[-1]->[2],
    2, 'Last peak read count on reverse strand' );

# Check read peaks returned by test BAM file
# First peak on forward strand should be 208 - 261 (1 read) according to:

=for comment
samtools view -f 128 -F 1044 t/data/test2.bam 1 | grep 54M | grep NM:i:0 \
| awk '{ print $4 "\t" $4 + 53 }' | head -4
=cut

# Last peak on forward strand should be 7087 - 7140 (1 read) according to:

=for comment
samtools view -f 128 -F 1044 t/data/test2.bam 1 | grep 54M | grep NM:i:0 \
| awk '{ print $4 "\t" $4 + 53 }' | tail -4
=cut

# First peak on reverse strand should be 2022 - 2075 (1 read) according to:

=for comment
samtools view -f 144 -F 1028 t/data/test2.bam 1 | grep 54M | grep NM:i:0 \
| awk '{ print $4 "\t" $4 + 53 }' | head -4
=cut

# Last peak on reverse strand should be 8078 - 8142 (2 reads) according to:

=for comment
samtools view -f 144 -F 1028 t/data/test2.bam 1 | grep 54M | grep NM:i:0 \
| awk '{ print $4 "\t" $4 + 53 }' | tail -4
=cut

$peaks = get_read_peaks(
    {
        bam_file           => 't/data/test2.bam',
        mismatch_threshold => 0,
        peak_buffer_width  => 100,
        seq_name           => '1',
        tags               => [ 'NNNNBCAGAG', 'NNNNBGCACG' ],
    }
);
is( scalar keys %{$peaks},          1, '1 sequence' );
is( scalar keys %{ $peaks->{'1'} }, 2, '2 strands' );
is( $peaks->{'1'}->{'1'}->[0]->[0],
    208, 'Start of first peak on forward strand' );
is( $peaks->{'1'}->{'1'}->[0]->[1],
    261, 'End of first peak on forward strand' );
is( $peaks->{'1'}->{'1'}->[0]->[2],
    1, 'First peak read count on forward strand' );
is( $peaks->{'1'}->{'1'}->[-1]->[0],
    7087, 'Start of last peak on forward strand' );
is( $peaks->{'1'}->{'1'}->[-1]->[1],
    7140, 'End of last peak on forward strand' );
is( $peaks->{'1'}->{'1'}->[-1]->[2],
    1, 'Last peak read count on forward strand' );
is( $peaks->{'1'}->{'-1'}->[0]->[0],
    2022, 'Start of first peak on reverse strand' );
is( $peaks->{'1'}->{'-1'}->[0]->[1],
    2075, 'End of first peak on reverse strand' );
is( $peaks->{'1'}->{'-1'}->[0]->[2],
    1, 'First peak read count on reverse strand' );
is( $peaks->{'1'}->{'-1'}->[-1]->[0],
    8078, 'Start of last peak on reverse strand' );
is( $peaks->{'1'}->{'-1'}->[-1]->[1],
    8142, 'End of last peak on reverse strand' );
is( $peaks->{'1'}->{'-1'}->[-1]->[2],
    2, 'Last peak read count on reverse strand' );

# Check read peaks returned with non-existent tag
$peaks = get_read_peaks(
    {
        bam_file           => 't/data/test1.bam',
        mismatch_threshold => 0,
        peak_buffer_width  => 100,
        seq_name           => '1',
        tags               => ['NNNNTTTTTT'],
    }
);
is( scalar keys %{$peaks},             1, '1 sequence' );
is( scalar @{ $peaks->{'1'}->{'1'} },  0, '0 peaks on forward strand' );
is( scalar @{ $peaks->{'1'}->{'-1'} }, 0, '0 peaks on reverse strand' );

# Check getting 3' ends required parameters
throws_ok {
    get_three_prime_ends(
        {
            mismatch_threshold => 0,
            seq_name           => '1',
            strand             => 1,
            tags               => [ 'NNNNBGAGGC', 'NNNNBAGAAG' ],
            regions            => [ [ 1, 1000, 10, -10 ] ],
        }
    );
}
qr/No BAM file specified/ms, 'No BAM file';
throws_ok {
    get_three_prime_ends(
        {
            bam_file => 't/data/test1.bam',
            seq_name => '1',
            strand   => 1,
            tags     => [ 'NNNNBGAGGC', 'NNNNBAGAAG' ],
            regions  => [ [ 1, 1000, 10, -10 ] ],
        }
    );
}
qr/No mismatch threshold specified/ms, 'No mismatch threshold';
throws_ok {
    get_three_prime_ends(
        {
            bam_file           => 't/data/test1.bam',
            mismatch_threshold => 0,
            strand             => 1,
            tags               => [ 'NNNNBGAGGC', 'NNNNBAGAAG' ],
            regions            => [ [ 1, 1000, 10, -10 ] ],
        }
    );
}
qr/No sequence name specified/ms, 'No sequence name';
throws_ok {
    get_three_prime_ends(
        {
            bam_file           => 't/data/test1.bam',
            mismatch_threshold => 0,
            seq_name           => '1',
            tags               => [ 'NNNNBGAGGC', 'NNNNBAGAAG' ],
            regions            => [ [ 1, 1000, 10, -10 ] ],
        }
    );
}
qr/No strand specified/ms, 'No strand';
throws_ok {
    get_three_prime_ends(
        {
            bam_file           => 't/data/test1.bam',
            mismatch_threshold => 0,
            seq_name           => '1',
            strand             => 1,
            regions            => [ [ 1, 1000, 10, -10 ] ],
        }
    );
}
qr/No tags specified/ms, 'No tags';
throws_ok {
    get_three_prime_ends(
        {
            bam_file           => 't/data/test1.bam',
            mismatch_threshold => 0,
            seq_name           => '1',
            strand             => 1,
            tags               => [ 'NNNNBGAGGC', 'NNNNBAGAAG' ],
        }
    );
}
qr/No regions specified/ms, 'No regions';

my $three_prime_ends;

# Check 3' ends returned in first 2000 bp of chromosome 1 of test BAM file
# Should be 6 forward strand 3' ends according to:

=for comment
samtools view -f 128 -F 1052 t/data/test1.bam 1:1-2000 \
| grep NM:i:0 | grep 54M | awk '{ print "1:" $8 + 29 ":1" }' | sort -u | wc -l
=cut

# Should be 2 reverse strand 3' ends according to:

=for comment
samtools view -f 144 -F 1036 t/data/test1.bam 1:1-2000 \
| grep NM:i:0 | grep 54M | awk '{ print "1:" $8 ":-1" }' | sort -u | wc -l
=cut

# One forward strand 3' end should be 1:1194:1 with 1 read according to:

=for comment
samtools view -f 128 -F 1052 t/data/test1.bam 1:1-2000 \
| grep NM:i:0 | grep 54M | awk '{ print "1:" $8 + 29 ":1" }' | sort | uniq -c
=cut

# One reverse strand 3' end should be 1:1038:-1 with 1 read according to:

=for comment
samtools view -f 144 -F 1036 t/data/test1.bam 1:1-2000 \
| grep NM:i:0 | grep 54M | awk '{ print "1:" $8 ":-1" }' | sort | uniq -c
=cut

$three_prime_ends = get_three_prime_ends(
    {
        bam_file           => 't/data/test1.bam',
        mismatch_threshold => 0,
        seq_name           => '1',
        strand             => 1,
        tags               => [ 'NNNNBGAGGC', 'NNNNBAGAAG' ],
        regions            => [ [ 1, 2000, 10, -10 ] ],
    }
);
is( scalar keys %{$three_prime_ends},     1, '1 sequence' );
is( scalar @{ $three_prime_ends->{'1'} }, 1, '1 region' );
is( scalar @{ $three_prime_ends->{'1'}->[0]->[5] },
    6, q{6 forward strand 3' ends} );
my $got_forward = 0;
foreach my $three_prime_end ( @{ $three_prime_ends->{'1'}->[0]->[5] } ) {
    my ( $seq, $pos, $strand, $read_count ) = @{$three_prime_end};
    my $string_form = join q{:}, $seq, $pos, $strand;
    if ( $string_form eq '1:1194:1' ) {
        $got_forward = 1;
    }
}
ok( $got_forward, q{1 forward strand 3' end} );

$three_prime_ends = get_three_prime_ends(
    {
        bam_file           => 't/data/test1.bam',
        mismatch_threshold => 0,
        seq_name           => '1',
        strand             => -1,
        tags               => [ 'NNNNBGAGGC', 'NNNNBAGAAG' ],
        regions            => [ [ 1, 2000, 10, -10 ] ],
    }
);
is( scalar keys %{$three_prime_ends},     1, '1 sequence' );
is( scalar @{ $three_prime_ends->{'1'} }, 1, '1 region' );
is( scalar @{ $three_prime_ends->{'1'}->[0]->[5] },
    2, q{2 reverse strand 3' ends} );
my $got_reverse = 0;
foreach my $three_prime_end ( @{ $three_prime_ends->{'1'}->[0]->[5] } ) {
    my ( $seq, $pos, $strand, $read_count ) = @{$three_prime_end};
    my $string_form = join q{:}, $seq, $pos, $strand;
    if ( $string_form eq '1:1038:-1' ) {
        $got_reverse = 1;
    }
}
ok( $got_reverse, q{1 reverse strand 3' end} );

# Get 3' ends returned with non-existent tag
$three_prime_ends = get_three_prime_ends(
    {
        bam_file           => 't/data/test1.bam',
        mismatch_threshold => 0,
        seq_name           => '1',
        strand             => 1,
        tags               => ['NNNNTTTTTT'],
        regions            => [ [ 1, 2000, 10, -10 ] ],
    }
);
is( scalar keys %{$three_prime_ends},               1, '1 sequence' );
is( scalar @{ $three_prime_ends->{'1'} },           1, '1 region' );
is( scalar @{ $three_prime_ends->{'1'}->[0]->[5] }, 0, q{0 3' ends} );

# Get 3' ends for sequence name with a peak
$three_prime_ends = get_three_prime_ends(
    {
        bam_file           => 't/data/test1.bam',
        mismatch_threshold => 0,
        seq_name           => '3',
        strand             => 1,
        tags               => [ 'NNNNBGAGGC', 'NNNNBAGAAG' ],
        regions            => [ [ 1, 10000, 10, -10 ] ],
    }
);
is( scalar keys %{$three_prime_ends},     1, '1 sequence' );
is( scalar @{ $three_prime_ends->{'3'} }, 1, '1 region' );
my $max_read_count = 0;
foreach my $three_prime_end ( @{ $three_prime_ends->{'3'}->[0]->[5] } ) {
    my ( $seq, $pos, $strand, $read_count ) = @{$three_prime_end};
    if ( $read_count > $max_read_count ) {
        $max_read_count = $read_count;
    }
}
ok( $max_read_count > 1, q{Read count for 3' end of peak} );

# Check merging 3' ends required parameters
throws_ok {
    merge_three_prime_ends(
        { regions => [ [ [ 1, 1000, 10, -10, 1, [] ] ] ], } );
}
qr/No sequence name specified/ms, 'No sequence name';
throws_ok {
    merge_three_prime_ends( { seq_name => '1', } );
}
qr/No regions specified/ms, 'No regions';

# Test lists with different number of regions
throws_ok {
    merge_three_prime_ends(
        {
            seq_name => '1',
            regions  => [
                [ [ 1, 1000, 10, -10, 1, [] ], ],
                [ [ 1, 1000, 10, -10, 1, [] ], [ 2000, 3000, 10, -10, [] ], ],
            ],
        }
    );
}
qr/Number of regions does not match in all lists/ms,
  'Different number of regions';

# Test lists with different regions
throws_ok {
    merge_three_prime_ends(
        {
            seq_name => '1',
            regions  => [
                [
                    [ 1, 1000, 10, -10, 1, [] ], [ 2000, 4000, 10, -10, 1, [] ],
                ],
                [
                    [ 1, 1000, 10, -10, 1, [] ], [ 3000, 4000, 10, -10, 1, [] ],
                ],
            ],
        }
    );
}
qr/Regions not in the same order or not the same in each list/ms,
  'Different region start';
throws_ok {
    merge_three_prime_ends(
        {
            seq_name => '1',
            regions  => [
                [
                    [ 1, 1000, 10, -10, 1, [] ], [ 2000, 4000, 10, -10, 1, [] ],
                ],
                [
                    [ 1, 1000, 10, -10, 1, [] ], [ 2000, 5000, 10, -10, 1, [] ],
                ],
            ],
        }
    );
}
qr/Regions not in the same order or not the same in each list/ms,
  'Different region end';
throws_ok {
    merge_three_prime_ends(
        {
            seq_name => '1',
            regions  => [
                [
                    [ 1, 1000, 10, -10, 1, [] ], [ 2000, 4000, 10, -10, 1, [] ],
                ],
                [
                    [ 1, 1000, 10, -10, 1, [] ], [ 2000, 4000, 20, -10, 1, [] ],
                ],
            ],
        }
    );
}
qr/Regions not in the same order or not the same in each list/ms,
  'Different region maximum read count';
throws_ok {
    merge_three_prime_ends(
        {
            seq_name => '1',
            regions  => [
                [
                    [ 1, 1000, 10, -10, 1, [] ], [ 2000, 4000, 10, -10, 1, [] ],
                ],
                [
                    [ 1, 1000, 10, -10, 1, [] ], [ 2000, 4000, 10, -20, 1, [] ],
                ],
            ],
        }
    );
}
qr/Regions not in the same order or not the same in each list/ms,
  'Different region log probability sum';
throws_ok {
    merge_three_prime_ends(
        {
            seq_name => '1',
            regions  => [
                [
                    [ 1, 1000, 10, -10, 1, [] ], [ 2000, 4000, 10, -10, 1, [] ],
                ],
                [
                    [ 1,    1000, 10, -10, 1,  [] ],
                    [ 2000, 4000, 10, -10, -1, [] ],
                ],
            ],
        }
    );
}
qr/Regions not in the same order or not the same in each list/ms,
  'Different region strand';

# Test one list of regions
$three_prime_ends = merge_three_prime_ends(
    {
        seq_name => '1',
        regions  => [ [ [ 1, 1000, 10, -10, 1, [] ] ] ],
    }
);
is( scalar keys %{$three_prime_ends},     1,    '1 sequence' );
is( scalar @{ $three_prime_ends->{'1'} }, 1,    '1 region' );
is( $three_prime_ends->{'1'}->[0]->[0],   1,    'Region start' );
is( $three_prime_ends->{'1'}->[0]->[1],   1000, 'Region end' );
is( $three_prime_ends->{'1'}->[0]->[2],   10,   'Region maximum read count' );
is( $three_prime_ends->{'1'}->[0]->[3],   -10,  'Region log probability sum' );
is( $three_prime_ends->{'1'}->[0]->[4],   1,    'Region strand' );
is( @{ $three_prime_ends->{'1'}->[0]->[5] }, 0, q{No 3' ends} );

# Test two lists of regions
$three_prime_ends = merge_three_prime_ends(
    {
        seq_name => '1',
        regions  => [
            [
                [
                    1, 1000, 10, -10, 1,
                    [ [ '1', 2000, 1, 10 ], [ '1', 3000, 1, 10 ], ]
                ]
            ],
            [ [ 1, 1000, 10, -10, 1, [ [ '1', 3000, 1, 10 ], ] ] ],
        ],
    }
);
is( scalar keys %{$three_prime_ends},     1,    '1 sequence' );
is( scalar @{ $three_prime_ends->{'1'} }, 1,    '1 region' );
is( $three_prime_ends->{'1'}->[0]->[0],   1,    'Region start' );
is( $three_prime_ends->{'1'}->[0]->[1],   1000, 'Region end' );
is( $three_prime_ends->{'1'}->[0]->[2],   10,   'Region maximum read count' );
is( $three_prime_ends->{'1'}->[0]->[3],   -10,  'Region log probability sum' );
is( $three_prime_ends->{'1'}->[0]->[4],   1,    'Region strand' );
is( @{ $three_prime_ends->{'1'}->[0]->[5] },      2,    q{2 3' ends} );
is( $three_prime_ends->{'1'}->[0]->[5]->[0]->[0], '1',  q{3' end sequence} );
is( $three_prime_ends->{'1'}->[0]->[5]->[0]->[1], 3000, q{3' end position} );
is( $three_prime_ends->{'1'}->[0]->[5]->[0]->[2], 1,    q{3' end strand} );
is( $three_prime_ends->{'1'}->[0]->[5]->[0]->[3], 20,   q{3' end read count} );

# Test different strands
$three_prime_ends = merge_three_prime_ends(
    {
        seq_name => '1',
        regions  => [
            [ [ 1, 1000, 10, -10, 1, [ [ '1', 2000, 1,  10 ], ] ] ],
            [ [ 1, 1000, 10, -10, 1, [ [ '1', 2000, -1, 10 ], ] ] ],
        ],
    }
);
is( scalar keys %{$three_prime_ends},        1, '1 sequence' );
is( scalar @{ $three_prime_ends->{'1'} },    1, '1 region' );
is( @{ $three_prime_ends->{'1'}->[0]->[5] }, 2, q{2 3' ends} );

my $analysis;

# Mock analysis object returning non-polyA
$analysis = Test::MockObject->new();
$analysis->set_isa('DETCT::Analysis');
$analysis->set_always( 'get_subsequence', 'TTTTTTTTTT' );

# Check filtering 3' ends required parameters
throws_ok {
    filter_three_prime_ends(
        {
            seq_name => '1',
            regions  => [ [ [ 1, 1000, 10, -10, 1, [] ] ] ],
        }
    );
}
qr/No analysis specified/ms, 'No analysis';
throws_ok {
    filter_three_prime_ends(
        {
            analysis => $analysis,
            regions  => [ [ [ 1, 1000, 10, -10, 1, [] ] ] ],
        }
    );
}
qr/No sequence name specified/ms, 'No sequence name';
throws_ok {
    filter_three_prime_ends(
        {
            analysis => $analysis,
            seq_name => '1',
        }
    );
}
qr/No regions specified/ms, 'No regions';

# Test filtering 3' ends
$three_prime_ends = filter_three_prime_ends(
    {
        analysis => $analysis,
        seq_name => '1',
        regions  => [
            [
                1, 1000, 10, -10, 1,
                [
                    [ '1', 1000, 1,  20 ],
                    [ '1', 2000, -1, 10 ],
                    [ '1', 3000, 1,  1 ],
                    [ '1', 4000, 1,  3 ],
                ]
            ]
        ],
    }
);
is( scalar keys %{$three_prime_ends},     1,    '1 sequence' );
is( scalar @{ $three_prime_ends->{'1'} }, 1,    '1 region' );
is( $three_prime_ends->{'1'}->[0]->[0],   1,    'Region start' );
is( $three_prime_ends->{'1'}->[0]->[1],   1000, 'Region end' );
is( $three_prime_ends->{'1'}->[0]->[2],   10,   'Region maximum read count' );
is( $three_prime_ends->{'1'}->[0]->[3],   -10,  'Region log probability sum' );
is( $three_prime_ends->{'1'}->[0]->[4],   1,    'Region strand' );
is( @{ $three_prime_ends->{'1'}->[0]->[5] },      2,    q{2 3' ends} );
is( $three_prime_ends->{'1'}->[0]->[5]->[0]->[0], '1',  q{3' end sequence} );
is( $three_prime_ends->{'1'}->[0]->[5]->[0]->[1], 1000, q{3' end position} );
is( $three_prime_ends->{'1'}->[0]->[5]->[0]->[2], 1,    q{3' end strand} );
is( $three_prime_ends->{'1'}->[0]->[5]->[0]->[3], 20,   q{3' end read count} );

# Mock analysis object returning polyA
$analysis = Test::MockObject->new();
$analysis->set_isa('DETCT::Analysis');
$analysis->set_always( 'get_subsequence', 'AAAATTTTTT' );

# Test filtering 3' ends
$three_prime_ends = filter_three_prime_ends(
    {
        analysis => $analysis,
        seq_name => '1',
        regions  => [
            [
                1, 1000, 10, -10, 1,
                [
                    [ '1', 1000, 1,  20 ],
                    [ '1', 2000, -1, 10 ],
                    [ '1', 3000, 1,  1 ],
                    [ '1', 4000, 1,  3 ],
                ]
            ]
        ],
    }
);
is( scalar keys %{$three_prime_ends},     1,    '1 sequence' );
is( scalar @{ $three_prime_ends->{'1'} }, 1,    '1 region' );
is( $three_prime_ends->{'1'}->[0]->[0],   1,    'Region start' );
is( $three_prime_ends->{'1'}->[0]->[1],   1000, 'Region end' );
is( $three_prime_ends->{'1'}->[0]->[2],   10,   'Region maximum read count' );
is( $three_prime_ends->{'1'}->[0]->[3],   -10,  'Region log probability sum' );
is( $three_prime_ends->{'1'}->[0]->[4],   1,    'Region strand' );
is( @{ $three_prime_ends->{'1'}->[0]->[5] }, 0, q{0 3' ends} );

# Check choosing 3' end required parameters
throws_ok {
    choose_three_prime_end(
        { regions => [ [ [ 1, 1000, 10, -10, 1, [] ] ] ], } );
}
qr/No sequence name specified/ms, 'No sequence name';
throws_ok {
    choose_three_prime_end( { seq_name => '1', } );
}
qr/No regions specified/ms, 'No regions';

# Test choosing 3' end
$three_prime_ends = choose_three_prime_end(
    {
        seq_name => '1',
        regions  => [
            [
                1, 1000, 10, -10, 1,
                [
                    [ '1', 1000, 1,  20 ],
                    [ '1', 2000, -1, 10 ],
                    [ '1', 3000, 1,  1 ],
                    [ '1', 4000, 1,  3 ],
                ]
            ]
        ],
    }
);
is( scalar keys %{$three_prime_ends},     1,    '1 sequence' );
is( scalar @{ $three_prime_ends->{'1'} }, 1,    '1 region' );
is( $three_prime_ends->{'1'}->[0]->[0],   1,    'Region start' );
is( $three_prime_ends->{'1'}->[0]->[1],   1000, 'Region end' );
is( $three_prime_ends->{'1'}->[0]->[2],   10,   'Region maximum read count' );
is( $three_prime_ends->{'1'}->[0]->[3],   -10,  'Region log probability sum' );
is( $three_prime_ends->{'1'}->[0]->[4],   '1',  q{3' end sequence} );
is( $three_prime_ends->{'1'}->[0]->[5],   1000, q{3' end position} );
is( $three_prime_ends->{'1'}->[0]->[6],   1,    q{3' end strand} );
is( $three_prime_ends->{'1'}->[0]->[7],   20,   q{3' end read count} );

# Test choosing 3' end with no 3' ends
$three_prime_ends = choose_three_prime_end(
    {
        seq_name => '1',
        regions  => [ [ 1, 1000, 10, -10, 1, [] ] ],
    }
);
is( scalar keys %{$three_prime_ends},     1,     '1 sequence' );
is( scalar @{ $three_prime_ends->{'1'} }, 1,     '1 region' );
is( $three_prime_ends->{'1'}->[0]->[0],   1,     'Region start' );
is( $three_prime_ends->{'1'}->[0]->[1],   1000,  'Region end' );
is( $three_prime_ends->{'1'}->[0]->[2],   10,    'Region maximum read count' );
is( $three_prime_ends->{'1'}->[0]->[3],   -10,   'Region log probability sum' );
is( $three_prime_ends->{'1'}->[0]->[4],   undef, q{3' end sequence} );
is( $three_prime_ends->{'1'}->[0]->[5],   undef, q{3' end position} );
is( $three_prime_ends->{'1'}->[0]->[6],   1,     q{3' end strand} );
is( $three_prime_ends->{'1'}->[0]->[7],   undef, q{3' end read count} );

# Test choosing 3' end with reduced region end
$three_prime_ends = choose_three_prime_end(
    {
        seq_name => '1',
        regions  => [ [ 1, 1000, 10, -10, 1, [ [ '1', 900, 1, 20 ], ] ] ],
    }
);
is( scalar keys %{$three_prime_ends},     1,   '1 sequence' );
is( scalar @{ $three_prime_ends->{'1'} }, 1,   '1 region' );
is( $three_prime_ends->{'1'}->[0]->[0],   1,   'Region start' );
is( $three_prime_ends->{'1'}->[0]->[1],   900, 'Region end' );
is( $three_prime_ends->{'1'}->[0]->[2],   10,  'Region maximum read count' );
is( $three_prime_ends->{'1'}->[0]->[3],   -10, 'Region log probability sum' );
is( $three_prime_ends->{'1'}->[0]->[4],   '1', q{3' end sequence} );
is( $three_prime_ends->{'1'}->[0]->[5],   900, q{3' end position} );
is( $three_prime_ends->{'1'}->[0]->[6],   1,   q{3' end strand} );
is( $three_prime_ends->{'1'}->[0]->[7],   20,  q{3' end read count} );

# Test choosing 3' end with reduced region start
$three_prime_ends = choose_three_prime_end(
    {
        seq_name => '1',
        regions  => [ [ 1, 1000, 10, -10, -1, [ [ '1', 100, -1, 20 ], ] ] ],
    }
);
is( scalar keys %{$three_prime_ends},     1,    '1 sequence' );
is( scalar @{ $three_prime_ends->{'1'} }, 1,    '1 region' );
is( $three_prime_ends->{'1'}->[0]->[0],   100,  'Region start' );
is( $three_prime_ends->{'1'}->[0]->[1],   1000, 'Region end' );
is( $three_prime_ends->{'1'}->[0]->[2],   10,   'Region maximum read count' );
is( $three_prime_ends->{'1'}->[0]->[3],   -10,  'Region log probability sum' );
is( $three_prime_ends->{'1'}->[0]->[4],   '1',  q{3' end sequence} );
is( $three_prime_ends->{'1'}->[0]->[5],   100,  q{3' end position} );
is( $three_prime_ends->{'1'}->[0]->[6],   -1,   q{3' end strand} );
is( $three_prime_ends->{'1'}->[0]->[7],   20,   q{3' end read count} );

# Test choosing 3' end with different sequence name
$three_prime_ends = choose_three_prime_end(
    {
        seq_name => '1',
        regions  => [ [ 1, 1000, 10, -10, -1, [ [ '2', 100, -1, 20 ], ] ] ],
    }
);
is( scalar keys %{$three_prime_ends},     1,    '1 sequence' );
is( scalar @{ $three_prime_ends->{'1'} }, 1,    '1 region' );
is( $three_prime_ends->{'1'}->[0]->[0],   1,    'Region start' );
is( $three_prime_ends->{'1'}->[0]->[1],   1000, 'Region end' );
is( $three_prime_ends->{'1'}->[0]->[2],   10,   'Region maximum read count' );
is( $three_prime_ends->{'1'}->[0]->[3],   -10,  'Region log probability sum' );
is( $three_prime_ends->{'1'}->[0]->[4],   '2',  q{3' end sequence} );
is( $three_prime_ends->{'1'}->[0]->[5],   100,  q{3' end position} );
is( $three_prime_ends->{'1'}->[0]->[6],   -1,   q{3' end strand} );
is( $three_prime_ends->{'1'}->[0]->[7],   20,   q{3' end read count} );

# Test choosing 3' end beyond region start
$three_prime_ends = choose_three_prime_end(
    {
        seq_name => '1',
        regions  => [ [ 1000, 2000, 10, -10, 1, [ [ '1', 900, 1, 20 ], ] ] ],
    }
);
is( scalar keys %{$three_prime_ends},     1,    '1 sequence' );
is( scalar @{ $three_prime_ends->{'1'} }, 1,    '1 region' );
is( $three_prime_ends->{'1'}->[0]->[0],   1000, 'Region start' );
is( $three_prime_ends->{'1'}->[0]->[1],   2000, 'Region end' );
is( $three_prime_ends->{'1'}->[0]->[2],   10,   'Region maximum read count' );
is( $three_prime_ends->{'1'}->[0]->[3],   -10,  'Region log probability sum' );
is( $three_prime_ends->{'1'}->[0]->[4],   '1',  q{3' end sequence} );
is( $three_prime_ends->{'1'}->[0]->[5],   900,  q{3' end position} );
is( $three_prime_ends->{'1'}->[0]->[6],   1,    q{3' end strand} );
is( $three_prime_ends->{'1'}->[0]->[7],   20,   q{3' end read count} );
$three_prime_ends = choose_three_prime_end(
    {
        seq_name => '1',
        regions  => [ [ 1000, 2000, 10, -10, -1, [ [ '1', 900, -1, 20 ], ] ] ],
    }
);
is( scalar keys %{$three_prime_ends},     1,    '1 sequence' );
is( scalar @{ $three_prime_ends->{'1'} }, 1,    '1 region' );
is( $three_prime_ends->{'1'}->[0]->[0],   1000, 'Region start' );
is( $three_prime_ends->{'1'}->[0]->[1],   2000, 'Region end' );
is( $three_prime_ends->{'1'}->[0]->[2],   10,   'Region maximum read count' );
is( $three_prime_ends->{'1'}->[0]->[3],   -10,  'Region log probability sum' );
is( $three_prime_ends->{'1'}->[0]->[4],   '1',  q{3' end sequence} );
is( $three_prime_ends->{'1'}->[0]->[5],   900,  q{3' end position} );
is( $three_prime_ends->{'1'}->[0]->[6],   -1,   q{3' end strand} );
is( $three_prime_ends->{'1'}->[0]->[7],   20,   q{3' end read count} );

# Test choosing 3' end beyond region end
$three_prime_ends = choose_three_prime_end(
    {
        seq_name => '1',
        regions  => [ [ 1000, 2000, 10, -10, -1, [ [ '1', 2100, -1, 20 ], ] ] ],
    }
);
is( scalar keys %{$three_prime_ends},     1,    '1 sequence' );
is( scalar @{ $three_prime_ends->{'1'} }, 1,    '1 region' );
is( $three_prime_ends->{'1'}->[0]->[0],   1000, 'Region start' );
is( $three_prime_ends->{'1'}->[0]->[1],   2000, 'Region end' );
is( $three_prime_ends->{'1'}->[0]->[2],   10,   'Region maximum read count' );
is( $three_prime_ends->{'1'}->[0]->[3],   -10,  'Region log probability sum' );
is( $three_prime_ends->{'1'}->[0]->[4],   '1',  q{3' end sequence} );
is( $three_prime_ends->{'1'}->[0]->[5],   2100, q{3' end position} );
is( $three_prime_ends->{'1'}->[0]->[6],   -1,   q{3' end strand} );
is( $three_prime_ends->{'1'}->[0]->[7],   20,   q{3' end read count} );
$three_prime_ends = choose_three_prime_end(
    {
        seq_name => '1',
        regions  => [ [ 1000, 2000, 10, -10, 1, [ [ '1', 2100, 1, 20 ], ] ] ],
    }
);
is( scalar keys %{$three_prime_ends},     1,    '1 sequence' );
is( scalar @{ $three_prime_ends->{'1'} }, 1,    '1 region' );
is( $three_prime_ends->{'1'}->[0]->[0],   1000, 'Region start' );
is( $three_prime_ends->{'1'}->[0]->[1],   2000, 'Region end' );
is( $three_prime_ends->{'1'}->[0]->[2],   10,   'Region maximum read count' );
is( $three_prime_ends->{'1'}->[0]->[3],   -10,  'Region log probability sum' );
is( $three_prime_ends->{'1'}->[0]->[4],   '1',  q{3' end sequence} );
is( $three_prime_ends->{'1'}->[0]->[5],   2100, q{3' end position} );
is( $three_prime_ends->{'1'}->[0]->[6],   1,    q{3' end strand} );
is( $three_prime_ends->{'1'}->[0]->[7],   20,   q{3' end read count} );

# Test choosing 3' end with same read count
$three_prime_ends = choose_three_prime_end(
    {
        seq_name => '1',
        regions  => [
            [
                1000, 2000, 10, -10, -1,
                [ [ '1', 900, -1, 20 ], [ '1', 2200, -1, 20 ], ]
            ]
        ],
    }
);
is( scalar keys %{$three_prime_ends},     1,    '1 sequence' );
is( scalar @{ $three_prime_ends->{'1'} }, 1,    '1 region' );
is( $three_prime_ends->{'1'}->[0]->[0],   1000, 'Region start' );
is( $three_prime_ends->{'1'}->[0]->[1],   2000, 'Region end' );
is( $three_prime_ends->{'1'}->[0]->[2],   10,   'Region maximum read count' );
is( $three_prime_ends->{'1'}->[0]->[3],   -10,  'Region log probability sum' );
is( $three_prime_ends->{'1'}->[0]->[4],   '1',  q{3' end sequence} );
is( $three_prime_ends->{'1'}->[0]->[5],   900,  q{3' end position} );
is( $three_prime_ends->{'1'}->[0]->[6],   -1,   q{3' end strand} );
is( $three_prime_ends->{'1'}->[0]->[7],   20,   q{3' end read count} );
$three_prime_ends = choose_three_prime_end(
    {
        seq_name => '1',
        regions  => [
            [
                1000, 2000, 10, -10, -1,
                [ [ '1', 900, -1, 20 ], [ '1', 2100, -1, 20 ], ]
            ]
        ],
    }
);
is( scalar keys %{$three_prime_ends},     1,    '1 sequence' );
is( scalar @{ $three_prime_ends->{'1'} }, 1,    '1 region' );
is( $three_prime_ends->{'1'}->[0]->[0],   1000, 'Region start' );
is( $three_prime_ends->{'1'}->[0]->[1],   2000, 'Region end' );
is( $three_prime_ends->{'1'}->[0]->[2],   10,   'Region maximum read count' );
is( $three_prime_ends->{'1'}->[0]->[3],   -10,  'Region log probability sum' );
is( $three_prime_ends->{'1'}->[0]->[4],   '1',  q{3' end sequence} );
is( $three_prime_ends->{'1'}->[0]->[6],   -1,   q{3' end strand} );
is( $three_prime_ends->{'1'}->[0]->[7],   20,   q{3' end read count} );
$three_prime_ends = choose_three_prime_end(
    {
        seq_name => '1',
        regions  => [
            [
                1000, 2000, 10, -10, -1,
                [ [ '2', 900, -1, 20 ], [ '2', 2100, -1, 20 ], ]
            ]
        ],
    }
);
is( scalar keys %{$three_prime_ends},     1,    '1 sequence' );
is( scalar @{ $three_prime_ends->{'1'} }, 1,    '1 region' );
is( $three_prime_ends->{'1'}->[0]->[0],   1000, 'Region start' );
is( $three_prime_ends->{'1'}->[0]->[1],   2000, 'Region end' );
is( $three_prime_ends->{'1'}->[0]->[2],   10,   'Region maximum read count' );
is( $three_prime_ends->{'1'}->[0]->[3],   -10,  'Region log probability sum' );
is( $three_prime_ends->{'1'}->[0]->[4],   '2',  q{3' end sequence} );
is( $three_prime_ends->{'1'}->[0]->[6],   -1,   q{3' end strand} );
is( $three_prime_ends->{'1'}->[0]->[7],   20,   q{3' end read count} );

# Test checking for polyA
is( DETCT::Misc::BAM::is_polya('TTTTTTTTTT'), 0, 'PolyT' );
is( DETCT::Misc::BAM::is_polya('AAAATTTTTT'), 1, '>3 As at start' );
is( DETCT::Misc::BAM::is_polya('TTTTTTAAAA'), 0, '>3 As at end' );
is( DETCT::Misc::BAM::is_polya('TAAAATAAAT'), 1, '>6 As' );
is( DETCT::Misc::BAM::is_polya('AAATAAATTT'), 1, 'AAA.AAA... regexp' );
is( DETCT::Misc::BAM::is_polya('AAATAATATT'), 1, 'AAA.AA.A.. regexp' );
is( DETCT::Misc::BAM::is_polya('AAATATAATT'), 1, 'AAA.A.AA.. regexp' );
is( DETCT::Misc::BAM::is_polya('AATAAAATTT'), 1, 'AA.AAAA... regexp' );
is( DETCT::Misc::BAM::is_polya('AATAAATATT'), 1, 'AA.AAA.A.. regexp' );
is( DETCT::Misc::BAM::is_polya('AATATAAATT'), 1, 'AA.A.AAA.. regexp' );
is( DETCT::Misc::BAM::is_polya('ATAAAAATTT'), 1, 'A.AAAAA... regexp' );
is( DETCT::Misc::BAM::is_polya('ATAAAATATT'), 1, 'A.AAAA.A.. regexp' );
is( DETCT::Misc::BAM::is_polya('ATAAATAATT'), 1, 'A.AAA.AA.. regexp' );
is( DETCT::Misc::BAM::is_polya('ATAATAAATT'), 1, 'A.AA.AAA.. regexp' );
is( DETCT::Misc::BAM::is_polya('ATATAAAATT'), 1, 'A.A.AAAA.. regexp' );
is( DETCT::Misc::BAM::is_polya('AATAATAATT'), 1, 'AA.AA.AA.. regexp' );
is( DETCT::Misc::BAM::is_polya('TATAATAATA'), 0, '6 As' );

# Check counting reads required parameters
throws_ok {
    count_reads(
        {
            mismatch_threshold => 2,
            seq_name           => '1',
            regions => [ [ 1000, 2000, 10, -10, '1', 2000, 1, 10 ], ],
            tags    => ['NNNNBGAGGC'],
        }
    );
}
qr/No BAM file specified/ms, 'No BAM file';
throws_ok {
    count_reads(
        {
            bam_file => 't/data/test1.bam',
            seq_name => '1',
            regions  => [ [ 1000, 2000, 10, -10, '1', 2000, 1, 10 ], ],
            tags     => ['NNNNBGAGGC'],
        }
    );
}
qr/No mismatch threshold specified/ms, 'No mismatch threshold';
throws_ok {
    count_reads(
        {
            bam_file           => 't/data/test1.bam',
            mismatch_threshold => 2,
            regions => [ [ 1000, 2000, 10, -10, '1', 2000, 1, 10 ], ],
            tags    => ['NNNNBGAGGC'],
        }
    );
}
qr/No sequence name specified/ms, 'No sequence name';
throws_ok {
    count_reads(
        {
            bam_file           => 't/data/test1.bam',
            mismatch_threshold => 2,
            seq_name           => '1',
            tags               => ['NNNNBGAGGC'],
        }
    );
}
qr/No regions specified/ms, 'No regions';
throws_ok {
    count_reads(
        {
            bam_file           => 't/data/test1.bam',
            mismatch_threshold => 0,
            seq_name           => '1',
            regions            => [ [ 1, 2000, 10, -10, '1', 2000, 1, 10 ], ],
        }
    );
}
qr/No tags specified/ms, 'No tags';

# Check read counts returned by test BAM file
# Should be 5 reads according to:

=for comment
samtools view -f 128 -F 1044 t/data/test1.bam 1:1-2000 \
| grep 54M | grep NM:i:0 | awk '{ print $1 }' \
| sed -e 's/.*#//' | grep GAGGC$ | wc -l
=cut

$three_prime_ends = count_reads(
    {
        bam_file           => 't/data/test1.bam',
        mismatch_threshold => 0,
        seq_name           => '1',
        regions            => [ [ 1, 2000, 10, -10, '1', 2000, 1, 10 ], ],
        tags               => ['NNNNBGAGGC'],
    }
);
is( scalar keys %{$three_prime_ends},     1,    '1 sequence' );
is( scalar @{ $three_prime_ends->{'1'} }, 1,    '1 region' );
is( $three_prime_ends->{'1'}->[0]->[0],   1,    'Region start' );
is( $three_prime_ends->{'1'}->[0]->[1],   2000, 'Region end' );
is( $three_prime_ends->{'1'}->[0]->[2],   10,   'Region maximum read count' );
is( $three_prime_ends->{'1'}->[0]->[3],   -10,  'Region log probability sum' );
is( $three_prime_ends->{'1'}->[0]->[4],   '1',  q{3' end sequence} );
is( $three_prime_ends->{'1'}->[0]->[5],   2000, q{3' end position} );
is( $three_prime_ends->{'1'}->[0]->[6],   1,    q{3' end strand} );
is( $three_prime_ends->{'1'}->[0]->[7],   10,   q{3' end read count} );
is( scalar keys %{ $three_prime_ends->{'1'}->[0]->[8] }, 1, '1 tag' );
is( $three_prime_ends->{'1'}->[0]->[8]->{NNNNBGAGGC},    5, '5 reads' );

# Mock sample objects
my $sample1 = Test::MockObject->new();
$sample1->set_isa('DETCT::Sample');
$sample1->set_always( 'bam_file', '1.bam' );
$sample1->set_always( 'tag',      'AA' );
my $sample2 = Test::MockObject->new();
$sample2->set_isa('DETCT::Sample');
$sample2->set_always( 'bam_file', '2.bam' );
$sample2->set_always( 'tag',      'TT' );
my $samples = [ $sample1, $sample2 ];

# Check merging read counts required parameters
throws_ok {
    merge_read_counts(
        {
            regions => {
                '1.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { AA => 10 } ] ],
            },
            samples => $samples,
        }
    );
}
qr/No sequence name specified/ms, 'No sequence name';
throws_ok {
    merge_read_counts(
        {
            seq_name => '1',
            samples  => $samples,
        }
    );
}
qr/No regions specified/ms, 'No regions';
throws_ok {
    merge_read_counts(
        {
            seq_name => '1',
            regions  => {
                '1.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { AA => 10 } ] ],
            },
        }
    );
}
qr/No samples specified/ms, 'No samples';

# Test lists with different number of regions
throws_ok {
    merge_read_counts(
        {
            seq_name => '1',
            regions  => {
                '1.bam' => [
                    [ 1,    1000, 10, -10, '1', 2000, 1, 10, { AA => 10 } ],
                    [ 3000, 4000, 10, -10, '1', 5000, 1, 10, { AA => 10 } ],
                ],
                '2.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { TT => 10 } ] ],
            },
            samples => $samples,
        }
    );
}
qr/Number of regions does not match in all lists/ms,
  'Different number of regions';

# Test lists with different regions
throws_ok {
    merge_read_counts(
        {
            seq_name => '1',
            regions  => {
                '1.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { AA => 10 } ] ],
                '2.bam' =>
                  [ [ 2, 1000, 10, -10, '1', 2000, 1, 10, { TT => 10 } ] ],
            },
            samples => $samples,
        }
    );
}
qr/Regions not in the same order or not the same in each list/ms,
  'Different region start';
throws_ok {
    merge_read_counts(
        {
            seq_name => '1',
            regions  => {
                '1.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { AA => 10 } ] ],
                '2.bam' =>
                  [ [ 1, 1001, 10, -10, '1', 2000, 1, 10, { TT => 10 } ] ],
            },
            samples => $samples,
        }
    );
}
qr/Regions not in the same order or not the same in each list/ms,
  'Different region end';
throws_ok {
    merge_read_counts(
        {
            seq_name => '1',
            regions  => {
                '1.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { AA => 10 } ] ],
                '2.bam' =>
                  [ [ 1, 1000, 11, -10, '1', 2000, 1, 10, { TT => 10 } ] ],
            },
            samples => $samples,
        }
    );
}
qr/Regions not in the same order or not the same in each list/ms,
  'Different region maximum read count';
throws_ok {
    merge_read_counts(
        {
            seq_name => '1',
            regions  => {
                '1.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { AA => 10 } ] ],
                '2.bam' =>
                  [ [ 1, 1000, 10, -11, '1', 2000, 1, 10, { TT => 10 } ] ],
            },
            samples => $samples,
        }
    );
}
qr/Regions not in the same order or not the same in each list/ms,
  'Different region log probability sum';
throws_ok {
    merge_read_counts(
        {
            seq_name => '1',
            regions  => {
                '1.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { AA => 10 } ] ],
                '2.bam' =>
                  [ [ 1, 1000, 10, -10, '2', 2000, 1, 10, { TT => 10 } ] ],
            },
            samples => $samples,
        }
    );
}
qr/Regions not in the same order or not the same in each list/ms,
  q{Different 3' end sequence};
throws_ok {
    merge_read_counts(
        {
            seq_name => '1',
            regions  => {
                '1.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { AA => 10 } ] ],
                '2.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2001, 1, 10, { TT => 10 } ] ],
            },
            samples => $samples,
        }
    );
}
qr/Regions not in the same order or not the same in each list/ms,
  q{Different 3' end position};
throws_ok {
    merge_read_counts(
        {
            seq_name => '1',
            regions  => {
                '1.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { AA => 10 } ] ],
                '2.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, -1, 10, { TT => 10 } ] ],
            },
            samples => $samples,
        }
    );
}
qr/Regions not in the same order or not the same in each list/ms,
  q{Different 3' end strand};
throws_ok {
    merge_read_counts(
        {
            seq_name => '1',
            regions  => {
                '1.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { AA => 10 } ] ],
                '2.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 11, { TT => 10 } ] ],
            },
            samples => $samples,
        }
    );
}
qr/Regions not in the same order or not the same in each list/ms,
  q{Different 3' end read count};
throws_ok {
    merge_read_counts(
        {
            seq_name => '1',
            regions  => {
                '1.bam' =>
                  [ [ 1, 1000, 10, -10, undef, 2000, 1, 10, { AA => 10 } ] ],
                '2.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { TT => 10 } ] ],
            },
            samples => $samples,
        }
    );
}
qr/Regions not in the same order or not the same in each list/ms,
  q{3' end sequence undefined};
throws_ok {
    merge_read_counts(
        {
            seq_name => '1',
            regions  => {
                '1.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { AA => 10 } ] ],
                '2.bam' =>
                  [ [ 1, 1000, 10, -10, undef, 2000, 1, 10, { TT => 10 } ] ],
            },
            samples => $samples,
        }
    );
}
qr/Regions not in the same order or not the same in each list/ms,
  q{Other 3' end sequence undefined};
throws_ok {
    merge_read_counts(
        {
            seq_name => '1',
            regions  => {
                '1.bam' =>
                  [ [ 1, 1000, 10, -10, '1', undef, 1, 10, { AA => 10 } ] ],
                '2.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { TT => 10 } ] ],
            },
            samples => $samples,
        }
    );
}
qr/Regions not in the same order or not the same in each list/ms,
  q{3' end position undefined};
throws_ok {
    merge_read_counts(
        {
            seq_name => '1',
            regions  => {
                '1.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { AA => 10 } ] ],
                '2.bam' =>
                  [ [ 1, 1000, 10, -10, '1', undef, 1, 10, { TT => 10 } ] ],
            },
            samples => $samples,
        }
    );
}
qr/Regions not in the same order or not the same in each list/ms,
  q{Other 3' end position undefined};
throws_ok {
    merge_read_counts(
        {
            seq_name => '1',
            regions  => {
                '1.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, undef, 10, { AA => 10 } ] ],
                '2.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { TT => 10 } ] ],
            },
            samples => $samples,
        }
    );
}
qr/Regions not in the same order or not the same in each list/ms,
  q{3' end strand undefined};
throws_ok {
    merge_read_counts(
        {
            seq_name => '1',
            regions  => {
                '1.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { AA => 10 } ] ],
                '2.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, undef, 10, { TT => 10 } ] ],
            },
            samples => $samples,
        }
    );
}
qr/Regions not in the same order or not the same in each list/ms,
  q{Other 3' end strand undefined};
throws_ok {
    merge_read_counts(
        {
            seq_name => '1',
            regions  => {
                '1.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, undef, { AA => 10 } ] ],
                '2.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { TT => 10 } ] ],
            },
            samples => $samples,
        }
    );
}
qr/Regions not in the same order or not the same in each list/ms,
  q{3' end read count undefined};
throws_ok {
    merge_read_counts(
        {
            seq_name => '1',
            regions  => {
                '1.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { AA => 10 } ] ],
                '2.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, undef, { TT => 10 } ] ],
            },
            samples => $samples,
        }
    );
}
qr/Regions not in the same order or not the same in each list/ms,
  q{Other 3' end read count undefined};

# Test unknown BAM file and/or tag
throws_ok {
    merge_read_counts(
        {
            seq_name => '1',
            regions  => {
                '1.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { AA => 10 } ] ],
                '3.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { TT => 10 } ] ],
            },
            samples => $samples,
        }
    );
}
qr/Unknown BAM file/ms, q{BAM file not in samples};
throws_ok {
    merge_read_counts(
        {
            seq_name => '1',
            regions  => {
                '1.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { AA => 10 } ] ],
                '2.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { CC => 10 } ] ],
            },
            samples => $samples,
        }
    );
}
qr/Unknown BAM file/ms, q{Tag not in samples};
throws_ok {
    merge_read_counts(
        {
            seq_name => '1',
            regions  => {
                '1.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { TT => 10 } ] ],
                '2.bam' =>
                  [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { AA => 10 } ] ],
            },
            samples => $samples,
        }
    );
}
qr/Unknown BAM file/ms, q{Combination of BAM file and tag not in samples};

my $read_counts;

$read_counts = merge_read_counts(
    {
        seq_name => '1',
        regions  => {
            '1.bam' => [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { AA => 10 } ] ],
            '2.bam' => [ [ 1, 1000, 10, -10, '1', 2000, 1, 10, { TT => 20 } ] ],
        },
        samples => $samples,
    }
);
is( scalar keys %{$read_counts},     1,    '1 sequence' );
is( scalar @{ $read_counts->{'1'} }, 1,    '1 region' );
is( $read_counts->{'1'}->[0]->[0],   1,    'Region start' );
is( $read_counts->{'1'}->[0]->[1],   1000, 'Region end' );
is( $read_counts->{'1'}->[0]->[2],   10,   'Region maximum read count' );
is( $read_counts->{'1'}->[0]->[3],   -10,  'Region log probability sum' );
is( $read_counts->{'1'}->[0]->[4],   '1',  q{3' end sequence} );
is( $read_counts->{'1'}->[0]->[5],   2000, q{3' end position} );
is( $read_counts->{'1'}->[0]->[6],   1,    q{3' end strand} );
is( $read_counts->{'1'}->[0]->[7],   10,   q{3' end read count} );
is( scalar @{ $read_counts->{'1'}->[0]->[8] }, 2,  '2 samples' );
is( $read_counts->{'1'}->[0]->[8]->[0],        10, '10 reads' );
is( $read_counts->{'1'}->[0]->[8]->[1],        20, '20 reads' );

$read_counts = merge_read_counts(
    {
        seq_name => '1',
        regions  => {
            '1.bam' => [
                [ 1, 1000, 10, -10, undef, undef, undef, undef, { AA => 10 } ]
            ],
            '2.bam' => [
                [ 1, 1000, 10, -10, undef, undef, undef, undef, { TT => 20 } ]
            ],
        },
        samples => $samples,
    }
);
is( scalar keys %{$read_counts},     1,     '1 sequence' );
is( scalar @{ $read_counts->{'1'} }, 1,     '1 region' );
is( $read_counts->{'1'}->[0]->[0],   1,     'Region start' );
is( $read_counts->{'1'}->[0]->[1],   1000,  'Region end' );
is( $read_counts->{'1'}->[0]->[2],   10,    'Region maximum read count' );
is( $read_counts->{'1'}->[0]->[3],   -10,   'Region log probability sum' );
is( $read_counts->{'1'}->[0]->[4],   undef, q{3' end sequence} );
is( $read_counts->{'1'}->[0]->[5],   undef, q{3' end position} );
is( $read_counts->{'1'}->[0]->[6],   undef, q{3' end strand} );
is( $read_counts->{'1'}->[0]->[7],   undef, q{3' end read count} );
is( scalar @{ $read_counts->{'1'}->[0]->[8] }, 2,  '2 samples' );
is( $read_counts->{'1'}->[0]->[8]->[0],        10, '10 reads' );
is( $read_counts->{'1'}->[0]->[8]->[1],        20, '20 reads' );

# Stats
# Should be 2008 paired reads, 1616 mapped paired reads and 1616 properly paired
# reads according to:

=for comment
samtools view -h t/data/test1.bam | grep -E '^@SQ|#.....GAGGC' \
| samtools view -bS - | samtools flagstat -
=cut

my $stats = stats(
    {
        bam_file => 't/data/test1.bam',
        tags     => ['NNNNBGAGGC'],
    }
);
is( $stats->{NNNNBGAGGC}->{paired_read_count}, 2008, 'Paired read count' );
is( $stats->{NNNNBGAGGC}->{mapped_paired_read_count},
    1616, 'Mapped paired read count' );
is( $stats->{NNNNBGAGGC}->{properly_paired_read_count},
    1616, 'Properly paired read count' );

# Downsample

$count = downsample(
    {
        source_bam_file   => 't/data/test1.bam',
        source_read_count => 2008,
        tag               => 'NNNNBGAGGC',
        target_bam_file   => $tmp_dir . 'test1.NNNNBGAGGC.bam',
        target_read_count => 500,
        read_count_type   => 'paired',
    }
);
ok( $count <= 500, 'Downsample to 500 paired reads' );

$count = downsample(
    {
        source_bam_file   => 't/data/test1.bam',
        source_read_count => 1616,
        tag               => 'NNNNBGAGGC',
        target_bam_file   => $tmp_dir . 'test1.NNNNBGAGGC.bam',
        target_read_count => 500,
        read_count_type   => 'mapped',
    }
);
ok( $count <= 500, 'Downsample to 500 mapped paired reads' );

$count = downsample(
    {
        source_bam_file   => 't/data/test1.bam',
        source_read_count => 1616,
        tag               => 'NNNNBGAGGC',
        target_bam_file   => $tmp_dir . 'test1.NNNNBGAGGC.bam',
        target_read_count => 500,
        read_count_type   => 'proper',
    }
);
ok( $count <= 500, 'Downsample to 500 properly paired reads' );

throws_ok {
    $count = downsample(
        {
            source_read_count => 1616,
            tag               => 'NNNNBGAGGC',
            target_bam_file   => $tmp_dir . 'test1.NNNNBGAGGC.bam',
            target_read_count => 500,
            read_count_type   => 'proper',
        }
    );
}
qr/No source BAM file specified/ms, 'No source BAM file';
throws_ok {
    $count = downsample(
        {
            source_bam_file   => 't/data/test1.bam',
            tag               => 'NNNNBGAGGC',
            target_bam_file   => $tmp_dir . 'test1.NNNNBGAGGC.bam',
            target_read_count => 500,
            read_count_type   => 'proper',
        }
    );
}
qr/No source read count specified/ms, 'No source read count';
throws_ok {
    $count = downsample(
        {
            source_bam_file   => 't/data/test1.bam',
            source_read_count => 1616,
            target_bam_file   => $tmp_dir . 'test1.NNNNBGAGGC.bam',
            target_read_count => 500,
            read_count_type   => 'proper',
        }
    );
}
qr/No tag specified/ms, 'No tag';
throws_ok {
    $count = downsample(
        {
            source_bam_file   => 't/data/test1.bam',
            source_read_count => 1616,
            tag               => 'NNNNBGAGGC',
            target_read_count => 500,
            read_count_type   => 'proper',
        }
    );
}
qr/No target BAM file specified/ms, 'No target BAM file';
throws_ok {
    $count = downsample(
        {
            source_bam_file   => 't/data/test1.bam',
            source_read_count => 1616,
            tag               => 'NNNNBGAGGC',
            target_bam_file   => $tmp_dir . 'test1.NNNNBGAGGC.bam',
            read_count_type   => 'proper',
        }
    );
}
qr/No target read count specified/ms, 'No target read count';
throws_ok {
    $count = downsample(
        {
            source_bam_file   => 't/data/test1.bam',
            source_read_count => 1616,
            tag               => 'NNNNBGAGGC',
            target_bam_file   => $tmp_dir . 'test1.NNNNBGAGGC.bam',
            target_read_count => 500,
        }
    );
}
qr/No read count type specified/ms, 'No read count type';
throws_ok {
    $count = downsample(
        {
            source_bam_file   => 't/data/test1.bam',
            source_read_count => 1616,
            tag               => 'NNNNBGAGGC',
            target_bam_file   => $tmp_dir . 'test1.NNNNBGAGGC.bam',
            target_read_count => 500,
            read_count_type   => 'invalid',
        }
    );
}
qr/Invalid read count type/ms, 'Invalid read count type';
