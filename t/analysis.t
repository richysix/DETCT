use warnings;
use strict;
use autodie;
use Test::More;
use Test::Exception;
use Test::Warn;
use Test::DatabaseRow;
use Test::MockObject;
use Carp;

plan tests => 136;

use DETCT::Analysis;

use IO::Socket::INET;

my $is_ensembl_reachable = is_ensembl_reachable();

my $analysis = DETCT::Analysis->new(
    {
        name        => 'zmp_ph1',
        chunk_total => 20,
    }
);
isa_ok( $analysis, 'DETCT::Analysis' );

# Test name attribute
is( $analysis->name,                'zmp_ph1', 'Get name' );
is( $analysis->set_name('zmp_ph2'), undef,     'Set name' );
is( $analysis->name,                'zmp_ph2', 'Get new name' );
throws_ok { $analysis->set_name() } qr/No name specified/ms, 'No name';
my $long_name = 'X' x ( $DETCT::Analysis::MAX_NAME_LENGTH + 1 );
throws_ok { $analysis->set_name(' ') } qr/Invalid name specified/ms,
  'Invalid name';
throws_ok { $analysis->set_name('') } qr/Empty name specified/ms, 'Empty name';
throws_ok { $analysis->set_name($long_name) } qr/longer than \d+ characters/ms,
  'Long name';

# Test reference FASTA attribute
is( $analysis->ref_fasta, undef, 'Get reference FASTA' );
is( $analysis->set_ref_fasta('t/data/test12.fa'), undef,
    'Set reference FASTA' );
is( $analysis->ref_fasta, 't/data/test12.fa', 'Get new reference FASTA' );
throws_ok { $analysis->set_ref_fasta('nonexistent') } qr/cannot be read/ms,
  'Missing reference FASTA';

# Test Ensembl host attribute
is( $analysis->ensembl_host, undef, 'Get Ensembl host' );
is( $analysis->set_ensembl_host('ensembldb.ensembl.org'),
    undef, 'Set Ensembl host' );
is( $analysis->ensembl_host, 'ensembldb.ensembl.org', 'Get new Ensembl host' );

# Test Ensembl port attribute
is( $analysis->ensembl_port,           undef, 'Get Ensembl port' );
is( $analysis->set_ensembl_port(3306), undef, 'Set Ensembl port' );
is( $analysis->ensembl_port,           3306,  'Get new Ensembl port' );
throws_ok { $analysis->set_ensembl_port(-1) } qr/Invalid Ensembl port/ms,
  'Invalid Ensembl port';

# Test Ensembl username attribute
is( $analysis->ensembl_user,                  undef, 'Get Ensembl username' );
is( $analysis->set_ensembl_user('anonymous'), undef, 'Set Ensembl username' );
is( $analysis->ensembl_user, 'anonymous', 'Get new Ensembl username' );

# Test Ensembl password attribute
is( $analysis->ensembl_pass,               undef, 'Get Ensembl password' );
is( $analysis->set_ensembl_pass('secret'), undef, 'Set Ensembl password' );
is( $analysis->ensembl_pass, 'secret', 'Get new Ensembl password' );

# Test Ensembl database name attribute
is( $analysis->ensembl_name, undef, 'Get Ensembl database name' );
is( $analysis->set_ensembl_name('zv9_core'),
    undef, 'Set Ensembl database name' );
is( $analysis->ensembl_name, 'zv9_core', 'Get new Ensembl database name' );

# Test Ensembl species attribute
is( $analysis->ensembl_species, undef, 'Get Ensembl species' );
is( $analysis->set_ensembl_species('danio_rerio'),
    undef, 'Set Ensembl species' );
is( $analysis->ensembl_species, 'danio_rerio', 'Get new Ensembl species' );

# Test chunk total attribute
is( $analysis->chunk_total,         20,    'Get chunk total' );
is( $analysis->set_chunk_total(30), undef, 'Set chunk total' );
is( $analysis->chunk_total,         30,    'Get new chunk total' );
throws_ok { $analysis->set_chunk_total() } qr/No chunk total specified/ms,
  'No chunk total';
throws_ok { $analysis->set_chunk_total(-1) } qr/Invalid chunk total/ms,
  'Invalid chunk total';

# Test total bp, sequences and chunks before adding samples
is( $analysis->total_bp, 0, 'Total bp if no sequences' );
my $sequences = $analysis->get_all_sequences();
is( scalar @{$sequences}, 0, 'No sequences' );
my $chunks = $analysis->get_all_chunks();
is( scalar @{$chunks}, 0, 'No chunks' );

# Mock sample object
my $sample = Test::MockObject->new();
$sample->set_isa('DETCT::Sample');
$sample->set_always( 'bam_file',  't/data/test1.bam' );
$sample->set_always( 'name',      'zmp_ph1_1m' );
$sample->set_always( 'tag',       'NNNNBGAGGC' );
$sample->set_always( 'condition', 'mutant' );
$sample->set_always( 'groups', [] );

# Mock sample object with different reference sequence
my $sample_diff = Test::MockObject->new();
$sample_diff->set_isa('DETCT::Sample');
$sample_diff->set_always( 'bam_file', 't/data/test3.bam' );
$sample_diff->set_always( 'name',     'zmp_ph1_1s' );
$sample_diff->set_always( 'tag',      'NNNNBCGCAA' );
$sample_diff->set_always( 'groups', [] );

my $sample2 = Test::MockObject->new();
$sample2->set_isa('DETCT::Sample');
$sample2->set_always( 'bam_file',  't/data/test2.bam' );
$sample2->set_always( 'name',      'zmp_ph1_2m' );
$sample2->set_always( 'tag',       'NNNNBCAGAG' );
$sample2->set_always( 'condition', 'mutant' );
$sample2->set_always( 'groups', [] );

# Test adding and retrieving samples
my $samples;
$samples = $analysis->get_all_samples();
is( scalar @{$samples},             0,     'No samples' );
is( $analysis->add_sample($sample), undef, 'Add sample' );

$samples = $analysis->get_all_samples();
is( scalar @{$samples}, 1, 'Get one sample' );

$analysis->add_sample($sample2);
is( scalar @{$samples}, 2, 'Get two samples' );
throws_ok { $analysis->add_sample($sample_diff) } qr/use different reference/ms,
  'Different reference for sample';
throws_ok { $analysis->add_sample() } qr/No sample specified/ms,
  'No sample specified';
throws_ok { $analysis->add_sample('invalid') } qr/Class of sample/ms,
  'Invalid sample';

$analysis = DETCT::Analysis->new(
    {
        name        => 'zmp_ph1',
        chunk_total => 20,
    }
);
$analysis->add_sample($sample);

# Mock sample object with duplicated name
my $sample_dupe_name = Test::MockObject->new();
$sample_dupe_name->set_isa('DETCT::Sample');
$sample_dupe_name->set_always( 'bam_file', 't/data/test1.bam' );
$sample_dupe_name->set_always( 'name',     'zmp_ph1_1m' );
$sample_dupe_name->set_always( 'tag',      'NNNNBAGAAG' );
$sample_dupe_name->set_always( 'groups', [] );

throws_ok { $analysis->add_sample($sample_dupe_name) } qr/is duplicated/ms,
  'Duplicated sample name';

$analysis = DETCT::Analysis->new(
    {
        name        => 'zmp_ph1',
        chunk_total => 20,
    }
);
$analysis->add_sample($sample);

# Mock sample object with same tag and BAM files
my $sample_dupe_tag_bam = Test::MockObject->new();
$sample_dupe_tag_bam->set_isa('DETCT::Sample');
$sample_dupe_tag_bam->set_always( 'name',     'zmp_ph1_4s' );
$sample_dupe_tag_bam->set_always( 'bam_file', 't/data/test1.bam' );
$sample_dupe_tag_bam->set_always( 'tag',      'NNNNBGAGGC' );
$sample_dupe_tag_bam->set_always( 'groups', [] );

throws_ok { $analysis->add_sample($sample_dupe_tag_bam) }
qr/Multiple samples have the same tag/ms, 'Duplicated tag and BAM file';

$analysis = DETCT::Analysis->new(
    {
        name        => 'zmp_ph1',
        chunk_total => 20,
    }
);
$analysis->add_sample($sample);

# Mock sample object with different number of groups
my $sample_diff_groups = Test::MockObject->new();
$sample_diff_groups->set_isa('DETCT::Sample');
$sample_diff_groups->set_always( 'name',     'zmp_ph1_2m' );
$sample_diff_groups->set_always( 'bam_file', 't/data/test2.bam' );
$sample_diff_groups->set_always( 'tag',      'NNNNBCAGAG' );
$sample_diff_groups->set_always( 'groups', ['1'] );

throws_ok { $analysis->add_sample($sample_diff_groups) }
qr/Samples do not all have same number of groups/ms, 'Different groups';

$analysis = DETCT::Analysis->new(
    {
        name        => 'zmp_ph1',
        chunk_total => 20,
    }
);
my $sample_dupe_group1 = Test::MockObject->new();
$sample_dupe_group1->set_isa('DETCT::Sample');
$sample_dupe_group1->set_always( 'name',     'zmp_ph1_1m' );
$sample_dupe_group1->set_always( 'bam_file', 't/data/test1.bam' );
$sample_dupe_group1->set_always( 'tag',      'NNNNBGAGGC' );
$sample_dupe_group1->set_always( 'groups', [ '1', '2' ] );
$analysis->add_sample($sample_dupe_group1);

# Mock sample object with different number of groups
my $sample_dupe_group2 = Test::MockObject->new();
$sample_dupe_group2->set_isa('DETCT::Sample');
$sample_dupe_group2->set_always( 'name',     'zmp_ph1_2m' );
$sample_dupe_group2->set_always( 'bam_file', 't/data/test2.bam' );
$sample_dupe_group2->set_always( 'tag',      'NNNNBCAGAG' );
$sample_dupe_group2->set_always( 'groups', [ '2', '3' ] );

throws_ok { $analysis->add_sample($sample_dupe_group2) }
qr/is duplicated between groups/ms, 'Duplicate groups';

$analysis = DETCT::Analysis->new(
    {
        name        => 'zmp_ph1',
        chunk_total => 20,
    }
);

# Mock sample object with tag missing from BAM file
my $sample_missing_tag = Test::MockObject->new();
$sample_missing_tag->set_isa('DETCT::Sample');
$sample_missing_tag->set_always( 'bam_file', 't/data/test1.bam' );
$sample_missing_tag->set_always( 'name',     'zmp_ph1_5s' );
$sample_missing_tag->set_always( 'tag',      'NNNNBTGAATC' );
$sample_missing_tag->set_always( 'groups', [] );

throws_ok { $analysis->add_sample($sample_missing_tag) }
qr/does not contain tag/ms, 'Tag missing from BAM files';

# Mock sample object with no BAM index file
my $sample_no_index = Test::MockObject->new();
$sample_no_index->set_isa('DETCT::Sample');
$sample_no_index->set_always( 'name',     'zmp_ph1_6s' );
$sample_no_index->set_always( 'bam_file', 't/data/test4.bam' );
$sample_no_index->set_always( 'tag',      'NNNNBGAGGC' );
$sample_no_index->set_always( 'groups', [] );

throws_ok { $analysis->add_sample($sample_no_index) } qr/has no index/ms,
  'BAM file with no index file';

# Test listing conditions and groups
$analysis = DETCT::Analysis->new(
    {
        name        => 'zmp_ph1',
        chunk_total => 20,
    }
);
$analysis->add_sample($sample);
$analysis->add_sample($sample2);
is( scalar $analysis->list_all_conditions(), 1, 'List conditions' );
is( scalar $analysis->list_all_groups(),     0, 'List groups' );

$analysis = DETCT::Analysis->new(
    {
        name        => 'zmp_ph1',
        chunk_total => 20,
    }
);
my $sample_groups1 = Test::MockObject->new();
$sample_groups1->set_isa('DETCT::Sample');
$sample_groups1->set_always( 'name',      'zmp_ph1_1m' );
$sample_groups1->set_always( 'bam_file',  't/data/test1.bam' );
$sample_groups1->set_always( 'tag',       'NNNNBGAGGC' );
$sample_groups1->set_always( 'condition', 'mutant' );
$sample_groups1->set_always( 'groups', ['1'] );
$analysis->add_sample($sample_groups1);
my $sample_groups2 = Test::MockObject->new();
$sample_groups2->set_isa('DETCT::Sample');
$sample_groups2->set_always( 'name',      'zmp_ph1_2m' );
$sample_groups2->set_always( 'bam_file',  't/data/test2.bam' );
$sample_groups2->set_always( 'tag',       'NNNNBCAGAG' );
$sample_groups2->set_always( 'condition', 'sibling' );
$sample_groups2->set_always( 'groups', ['2'] );
$analysis->add_sample($sample_groups2);
is( scalar $analysis->list_all_conditions(), 2, 'List two conditions' );
is( scalar $analysis->list_all_groups(),     2, 'List two groups' );
$sample_groups1->set_always( 'groups', [ '1', 'a' ] );
$sample_groups2->set_always( 'groups', [ '2', 'b' ] );
is( scalar $analysis->list_all_groups(), 4, 'List four groups' );

# Test total bp, sequences and chunks after adding samples
# Get total bp using:

=for comment
samtools view -H t/data/test1.bam | sed -e 's/.*LN://' \
| awk '{ sum += $1 } END { print sum }'
=cut

my $TOTAL_BP = 22193;

is( $analysis->total_bp, $TOTAL_BP, 'Total bp with sequences' );
$sequences = $analysis->get_all_sequences();
is( scalar @{$sequences}, 5, '5 sequences' );
$chunks = $analysis->get_all_chunks();
ok( scalar @{$chunks} > 0, 'Chunks' );

# Count sequence in chunks
my $sequence_total = 0;
foreach my $chunk ( @{$chunks} ) {
    $sequence_total += scalar @{$chunk};
}
is( $sequence_total, 5, '5 sequences in chunks' );

# Recalculate chunks so one sequence per chunk
$analysis->set_chunk_total(10000);
$chunks = $analysis->get_all_chunks();
is( scalar @{$chunks}, 5, '5 chunks' );

# Recalculate chunks so 5/3 sequences per chunk on average
$analysis->set_chunk_total(3);
$chunks = $analysis->get_all_chunks();
is( scalar @{$chunks}, 3, '3 chunks' );

# Count sequence in chunks
$sequence_total = 0;
foreach my $chunk ( @{$chunks} ) {
    $sequence_total += scalar @{$chunk};
}
is( $sequence_total, 5, '5 sequences in chunks' );

# Test test chunk attribute
is( $analysis->test_chunk,        undef, 'Get test chunk' );
is( $analysis->set_test_chunk(1), undef, 'Set test chunk' );
is( $analysis->test_chunk,        1,     'Get new test chunk' );
$chunks = $analysis->get_all_chunks();
is( scalar @{$chunks},            1,     '1 chunk' );
is( $analysis->set_test_chunk(4), undef, 'Set test chunk' );
$chunks = $analysis->get_all_chunks();
is( scalar @{$chunks}, 3, '3 chunks' );

# Test skip sequences
is( scalar @{ $analysis->get_all_skip_sequences }, 0, 'Get skip sequences' );
is( $analysis->is_skip_sequence('4'),           0, '4 is not skip sequence' );
is( scalar @{ $analysis->get_all_sequences() }, 5, '5 sequences' );
is( $analysis->add_all_skip_sequences( [ '4', '5' ] ),
    undef, 'Add skip sequences' );
is( scalar @{ $analysis->get_all_skip_sequences }, 2,
    'Get new skip sequences' );
is( $analysis->is_skip_sequence('4'),           1, '4 is skip sequence' );
is( scalar @{ $analysis->get_all_sequences() }, 5, '5 sequences' );
$analysis->add_all_sequences('t/data/test1.bam');
is( scalar @{ $analysis->get_all_sequences() }, 3, '3 sequences' );

# Test Ensembl database types
is( scalar @{ $analysis->get_all_ensembl_db_types },
    1, 'Get Ensembl database types' );
is( $analysis->get_all_ensembl_db_types->[0],
    'core', 'Get 1st Ensembl database type' );
is( $analysis->add_all_ensembl_db_types( [ 'core', 'otherfeatures' ] ),
    undef, 'Add Ensembl database types' );
is( scalar @{ $analysis->get_all_ensembl_db_types },
    2, 'Get new Ensembl database types' );
is( $analysis->get_all_ensembl_db_types->[1],
    'otherfeatures', 'Get 2nd Ensembl database type' );

# Test constructing from YAML
$analysis = DETCT::Analysis->new_from_yaml('t/data/test_analysis_de12.yaml');
isa_ok( $analysis, 'DETCT::Analysis' );
$samples = $analysis->get_all_samples();
is( scalar @{$samples}, 2, 'Get two YAML samples' );
throws_ok { $analysis = DETCT::Analysis->new_from_yaml('nonexistent.yaml') }
qr/does not exist or cannot be read/ms, 'Missing YAML file';

# Test validating analysis
throws_ok {
    $analysis =
      DETCT::Analysis->new_from_yaml('t/data/test_analysis_de13.yaml');
}
qr/use different reference/ms, 'Different reference';

# Test summary info
$analysis = DETCT::Analysis->new_from_yaml('t/data/test_analysis_de1122.yaml');
my @bam_files = $analysis->list_all_bam_files();
is( scalar @bam_files, 2,                  '2 BAM files' );
is( $bam_files[0],     't/data/test1.bam', 'Got BAM file' );
my @tags = $analysis->list_all_tags_by_bam_file('t/data/test1.bam');
is( scalar @tags, 2,            '2 tags' );
is( $tags[0],     'NNNNBAGAAG', 'Got tag' );

my $seq;

# Set FASTA index
$analysis = DETCT::Analysis->new_from_yaml('t/data/test_analysis_de12.yaml');
throws_ok { $analysis->set_fasta_index(); } qr/No FASTA index specified/ms,
  'No FASTA index';
throws_ok { $analysis->set_fasta_index('invalid'); } qr/Class of FASTA index/ms,
  'Invalid FASTA index';

# Set Ensembl slice adaptor
$analysis = DETCT::Analysis->new_from_yaml('t/data/test_analysis_de12.yaml');
throws_ok { $analysis->set_slice_adaptor(); }
qr/No Ensembl slice adaptor specified/ms, 'No slice adaptor';
throws_ok { $analysis->set_slice_adaptor('invalid'); }
qr/Class of Ensembl slice adaptor/ms, 'Invalid slice adaptor';

# Get subsequence with missing parameters
$analysis = DETCT::Analysis->new_from_yaml('t/data/test_analysis_de12.yaml');
throws_ok { $analysis->get_subsequence(); } qr/No sequence name specified/ms,
  'No sequence name';
throws_ok { $analysis->get_subsequence('1'); }
qr/No sequence start specified/ms, 'No sequence start';
throws_ok { $analysis->get_subsequence( '1', 1 ); }
qr/No sequence end specified/ms, 'No sequence end';
throws_ok { $analysis->get_subsequence( '1', 1, 10 ); }
qr/No sequence strand specified/ms, 'No sequence strand';

# Get upstream subsequence with missing parameters
$analysis = DETCT::Analysis->new_from_yaml('t/data/test_analysis_de12.yaml');
throws_ok { $analysis->get_upstream_subsequence(); }
qr/No sequence name specified/ms, 'No sequence name';
throws_ok { $analysis->get_upstream_subsequence('1'); }
qr/No sequence position specified/ms, 'No sequence position';
throws_ok { $analysis->get_upstream_subsequence( '1', 100 ); }
qr/No sequence strand specified/ms, 'No sequence strand';
throws_ok { $analysis->get_upstream_subsequence( '1', 100, 1 ); }
qr/No subsequence length specified/ms, 'No subsequence length';

# Get downstream subsequence with missing parameters
$analysis = DETCT::Analysis->new_from_yaml('t/data/test_analysis_de12.yaml');
throws_ok { $analysis->get_downstream_subsequence(); }
qr/No sequence name specified/ms, 'No sequence name';
throws_ok { $analysis->get_downstream_subsequence('1'); }
qr/No sequence position specified/ms, 'No sequence position';
throws_ok { $analysis->get_downstream_subsequence( '1', 100 ); }
qr/No sequence strand specified/ms, 'No sequence strand';
throws_ok { $analysis->get_downstream_subsequence( '1', 100, 1 ); }
qr/No subsequence length specified/ms, 'No subsequence length';

# Check getting sequence from test FASTA file
# First 10 bp of chromosome 1 should be CCAGGCGCGG according to:

=for comment
head -2 t/data/test12.fa
=cut

$analysis = DETCT::Analysis->new_from_yaml('t/data/test_analysis_de12.yaml');
$seq      = $analysis->get_subsequence( '1', 1, 10, 1 );
is( length $seq, 10,           'FASTA subsequence length' );
is( $seq,        'CCAGGCGCGG', 'FASTA subsequence' );
$seq = $analysis->get_subsequence( '1', 1, 10, -1 );
is( length $seq, 10,           'FASTA reverse complement subsequence length' );
is( $seq,        'CCGCGCCTGG', 'FASTA reverse complement subsequence' );

# Check getting subsequence outside size of sequence
$seq = $analysis->get_subsequence( '1', -1, 10, 1 );
is( length $seq, 10,           'Negative start FASTA subsequence length' );
is( $seq,        'CCAGGCGCGG', 'Negative start FASTA subsequence' );
$seq = $analysis->get_subsequence( '1', -1, -1, 1 );
is( length $seq, 1,   'Negative start and end FASTA subsequence length' );
is( $seq,        'C', 'Negative start and end FASTA subsequence' );
$seq = $analysis->get_subsequence( '1', 1_000_000_001, 1_000_000_010, 1 );
is( length $seq, 0,  'Large start and end FASTA subsequence length' );
is( $seq,        '', 'Large start and end FASTA subsequence' );

# Check getting upstream and downstream sequences from test FASTA file
# 10 bp upstream of position 11 of chromosome 1 should be CCAGGCGCGG and 10 bp
# downstream of position 1 should be CAGGCGCGGA according to:

=for comment
head -2 t/data/test12.fa
=cut

$analysis = DETCT::Analysis->new_from_yaml('t/data/test_analysis_de12.yaml');
$seq      = $analysis->get_upstream_subsequence( '1', 11, 1, 10 );
is( $seq, 'CCAGGCGCGG', 'FASTA upstream subsequence' );
$seq = $analysis->get_upstream_subsequence( '1', 1, -1, 10 );
is( $seq, 'TCCGCGCCTG', 'FASTA reverse complement upstream subsequence' );

$analysis = DETCT::Analysis->new_from_yaml('t/data/test_analysis_de12.yaml');
$seq      = $analysis->get_downstream_subsequence( '1', 1, 1, 10 );
is( $seq, 'CAGGCGCGGA', 'FASTA downstream subsequence' );
$seq = $analysis->get_downstream_subsequence( '1', 11, -1, 10 );
is( $seq, 'CCGCGCCTGG', 'FASTA reverse complement downstream subsequence' );

# Check getting sequence from Ensembl database
# First 10 bp of chromosome 1 should be TTCTTCTGGG according to:
# http://www.ensembl.org/Danio_rerio/Location/View?r=1%3A1-10
SKIP: {
    skip 'Ensembl not reachable', 4 if !$is_ensembl_reachable;

    $analysis = DETCT::Analysis->new(
        {
            name            => 'zmp_ph1',
            chunk_total     => 20,
            ensembl_species => 'danio_rerio',
        }
    );
    $seq = $analysis->get_subsequence( '1', 1, 10, 1 );
    is( length $seq, 10,           'Ensembl subsequence length' );
    is( $seq,        'TTCTTCTGGG', 'Ensembl subsequence' );
    $seq = $analysis->get_subsequence( '1', 1, 10, -1 );
    is( length $seq, 10, 'Ensembl reverse complement subsequence length' );
    is( $seq, 'CCCAGAAGAA', 'Ensembl reverse complement subsequence' );
}

# Check getting sequence without FASTA file or Ensembl database
$analysis = DETCT::Analysis->new(
    {
        name        => 'zmp_ph1',
        chunk_total => 20,
    }
);
throws_ok { $analysis->get_subsequence( '1', 1, 10, 1 ); }
qr/No reference FASTA or Ensembl database/ms, 'No FASTA or Ensembl';

# Check getting sequence from Ensembl database with explicit connection
SKIP: {
    skip 'Ensembl not reachable', 2 if !$is_ensembl_reachable;

    # Avoid warnings about loading the same databases again
    Bio::EnsEMBL::Registry::clear();

    $analysis = DETCT::Analysis->new(
        {
            name            => 'zmp_ph1',
            chunk_total     => 20,
            ensembl_host    => 'ensembldb.ensembl.org',
            ensembl_port    => 3306,
            ensembl_user    => 'anonymous',
            ensembl_pass    => '',
            ensembl_species => 'danio_rerio',
        }
    );
    $seq = $analysis->get_subsequence( '1', 1, 10, 1 );
    is( length $seq, 10,           'Ensembl subsequence length' );
    is( $seq,        'TTCTTCTGGG', 'Ensembl subsequence' );
}

# Check getting sequence from specific Ensembl database
# Get database name via:

=for comment
mysql -u anonymous -h ensembldb.ensembl.org -P 3306 -Bse \
"SHOW DATABASES LIKE 'danio_rerio_core\_%'" | sort | tail -1
=cut

SKIP: {
    skip 'Ensembl not reachable', 2 if !$is_ensembl_reachable;

    $analysis = DETCT::Analysis->new(
        {
            name         => 'zmp_ph1',
            chunk_total  => 20,
            ensembl_host => 'ensembldb.ensembl.org',
            ensembl_port => 3306,
            ensembl_user => 'anonymous',
            ensembl_pass => '',
            ensembl_name => 'danio_rerio_core_79_9',
        }
    );
    $seq = $analysis->get_subsequence( '1', 1, 10, 1 );
    is( length $seq, 10,           'Ensembl subsequence length' );
    is( $seq,        'TTCTTCTGGG', 'Ensembl subsequence' );
}

# Check getting subsequence outside size of sequence
SKIP: {
    skip 'Ensembl not reachable', 6 if !$is_ensembl_reachable;

    $seq = $analysis->get_subsequence( '1', -1, 10, 1 );
    is( length $seq, 10, 'Negative start Ensembl subsequence length' );
    is( $seq, 'TTCTTCTGGG', 'Negative start Ensembl subsequence' );
    $seq = $analysis->get_subsequence( '1', -1, -1, 1 );
    is( length $seq, 1,   'Negative start and end Ensembl subsequence length' );
    is( $seq,        'T', 'Negative start and end Ensembl subsequence' );
    $seq = $analysis->get_subsequence( '1', 1_000_000_001, 1_000_000_010, 1 );
    is( length $seq, 10, 'Large start and end Ensembl subsequence length' );
    is( $seq, 'NNNNNNNNNN', 'Large start and end Ensembl subsequence' );
}

# Check if Ensembl is reachable
sub is_ensembl_reachable {
    my $handle = IO::Socket::INET->new(
        PeerAddr => 'ensembldb.ensembl.org:3306',
        Timeout  => 1,
        Proto    => 'tcp',
    );

    if ( defined $handle && $handle ) {
        $handle->close();
        return 1;
    }
    else {
        return 0;
    }
}
