package Devel::StatProfiler::Aggregator;
# ABSTRACT: aggregate profiler output into one or more reports

use strict;
use warnings;

use Devel::StatProfiler::Reader;
use Devel::StatProfiler::SectionChangeReader;
use Devel::StatProfiler::Report;
use Devel::StatProfiler::EvalSource;
use Devel::StatProfiler::SourceMap;
use Devel::StatProfiler::Metadata;
use Devel::StatProfiler::Aggregate;
use Devel::StatProfiler::Utils qw(
    check_serializer
    read_data
    state_dir
    state_file
    write_data
    write_data_part
);

use File::Glob qw(bsd_glob);
use File::Path ();
use File::Basename ();
use Errno;

my $MAIN_REPORT_ID = ['__main__'];


sub new {
    my ($class, %opts) = @_;
    my $mapper = $opts{mapper} && $opts{mapper}->can_map ? $opts{mapper} : undef;
    my $self = bless {
        root_dir     => $opts{root_directory},
        parts_dir    => $opts{parts_directory} // $opts{root_directory},
        shard        => $opts{shard},
        shards       => $opts{shards} || [$opts{shard}],
        slowops      => $opts{slowops},
        flamegraph   => $opts{flamegraph},
        serializer   => $opts{serializer} || 'storable',
        processed    => {},
        reports      => {},
        partial      => {},
        source       => Devel::StatProfiler::EvalSource->new(
            serializer     => $opts{serializer},
            root_directory => $opts{root_directory},
            shard          => $opts{shard},
            genealogy      => {},
        ),
        sourcemap    => Devel::StatProfiler::SourceMap->new(
            serializer     => $opts{serializer},
            root_directory => $opts{root_directory},
            shard          => $opts{shard},
        ),
        metadata     => Devel::StatProfiler::Metadata->new(
            serializer     => $opts{serializer},
            root_directory => $opts{root_directory},
            shard          => $opts{shard},
        ),
        mapper       => $mapper,
        mixed_process=> $opts{mixed_process},
        genealogy    => {},
        last_sample  => {},
        parts        => [],
        fetchers     => $opts{fetchers},
        now          => time,
        timebox      => $opts{timebox},
    }, $class;

    check_serializer($self->{serializer});

    return $self;
}

sub can_process_trace_file {
    my ($self, @files) = @_;

    return grep {
        my $r = eval {
            ref $_ ? $_ : Devel::StatProfiler::Reader->new($_, $self->{mapper})
        } or do {
            my $errno = $!;
            my $error = $@;

            if ($error !~ /^Failed to open file/ || $errno != Errno::ENOENT) {
                die;
            }
            0;
        };

        if ($r) {
            my ($process_id, $process_ordinal, $parent_id, $parent_ordinal) =
                @{$r->get_genealogy_info};
            my $state = $self->_state($process_id) // { ordinal => 0 };

            $process_ordinal == $state->{ordinal} + 1 &&
                $self->_is_processed($parent_id, $parent_ordinal);
        } else {
            0;
        }
    } @files;
}

sub process_trace_files {
    my ($self, @files) = @_;
    my $eval_mapper = $self->{mapper} && $self->{mapper}->can_map_eval ? $self->{mapper} : undef;

    for my $file (@files) {
        my $r = ref $file ? $file : Devel::StatProfiler::Reader->new($file, $self->{mapper});
        my $sc = Devel::StatProfiler::SectionChangeReader->new($r);
        my ($process_id, $process_ordinal, $parent_id, $parent_ordinal) =
            @{$r->get_genealogy_info};
        my $state = $self->_state($process_id);
        next if $process_ordinal != $state->{ordinal} + 1;

        $self->{genealogy}{$process_id}{$process_ordinal} = [$parent_id, $parent_ordinal];
        $self->{last_sample}{$process_id} = time;
        $self->{metadata}->add_entries($r->get_custom_metadata);
        $eval_mapper->update_genealogy($process_id, $process_ordinal, $parent_id, $parent_ordinal)
            if $eval_mapper;
        $self->{source}->update_genealogy($process_id, $process_ordinal, $parent_id, $parent_ordinal)
            if $self->{source};

        if (my $reader_state = delete $state->{reader_state}) {
            $r->set_reader_state($reader_state);
        }

        my ($died, $error);
        eval {
            while ($sc->read_traces) {
                last if !$sc->sections_changed && %{$sc->get_active_sections};
                my ($report_keys, $metadata) = $self->handle_section_change($sc, $sc->get_custom_metadata);
                my $entry = $self->{partial}{"@$report_keys"} ||= {
                    report_keys => $report_keys,
                    report      => $self->_fresh_report,
                };
                if ($state->{report}) {
                    $entry->{report}->merge($state->{report});
                    $state->{report} = undef;
                }
                $entry->{report}->add_trace_file($sc);
                $entry->{report}->add_metadata($metadata) if $metadata && %$metadata;
            }

            if (!$sc->empty) {
                $state->{report} ||= $self->_fresh_report;
                $state->{report}->add_trace_file($sc);
            }
            $state->{ordinal} = $process_ordinal;
            $state->{reader_state} = $r->get_reader_state;
            $state->{modified} = 1;
            $state->{ended} = $r->is_stream_ended;

            1;
        } or do {
            $died = 1;
            $error = $@;

            $state->{ended} = 1;
        };

        $self->{source}->add_sources_from_reader($r);
        $self->{sourcemap}->add_sources_from_reader($r);

        my $metadata = $r->get_custom_metadata;
        $self->{metadata}->set_at_inc($metadata->{"\x00at_inc"})
            if $metadata->{"\x00at_inc"};

        die $error if $died;
    }
}

sub save_part {
    my ($self) = @_;

    for my $entry (values %{$self->{partial}}) {
        for my $key (@{$entry->{report_keys}}) {
            $self->_merge_report($key, $entry->{report});
        }
    }

    my $state_dir = state_dir($self);
    my $parts_dir = state_dir($self, 1);
    File::Path::mkpath([$state_dir, $parts_dir]);

    write_data_part($self, $parts_dir, 'genealogy', $self->{genealogy})
        if %{$self->{genealogy}};
    write_data_part($self, $parts_dir, 'last_sample', $self->{last_sample})
        if %{$self->{last_sample}};

    for my $process_id (keys %{$self->{processed}}) {
        my $processed = $self->{processed}{$process_id};

        next unless $processed->{modified};
        if ($processed->{ended}) {
            unlink state_file($self, 0, "processed.$process_id");
        } else {
            write_data($self, $state_dir, "processed.$process_id", $processed);
        }
    }

    $self->{metadata}->save_part($parts_dir);
    $self->{source}->save_part($parts_dir);
    $self->{sourcemap}->save_part($parts_dir);

    for my $key (keys %{$self->{reports}}) {
        my $report_dir = File::Spec::Functions::catdir(
            $self->{parts_dir}, $key, 'parts',
        );
        # writes some genealogy and source data twice, but it's OK for now
        $self->{reports}{$key}->save_part($report_dir);
    }

    my $shard_marker = File::Spec::Functions::catfile($state_dir, "shard.$self->{shard}");
    unless (-f $shard_marker) {
        open my $fh, '>', $shard_marker;
    }
}

sub _merge_report {
    my ($self, $report_id, $report) = @_;

    $self->{reports}{$report_id} ||= $self->_fresh_report;
    $self->{reports}{$report_id}->merge($report);
}

sub _state {
    my ($self, $process_id) = @_;

    return $self->{processed}{$process_id} //= do {
        my $state_file = state_file($self, 0, "processed.$process_id");
        my $processed;

        if (-f $state_file) {
            eval {
                $processed = read_data($self->{serializer}, $state_file);
                $processed->{modified} = 0;

                1;
            } or do {
                my $error = $@ || "Zombie error";

                if ($error->isa("autodie::exception") &&
                        $error->matches('open') &&
                        $error->errno == Errno::ENOENT) {
                    # silently ignore, it might have been cleaned up by
                    # another process
                } else {
                    die;
                }
            };
        }

        # initial state
        $processed // {
            process_id   => $process_id,
            ordinal      => 0,
            report       => undef,
            reader_state => undef,
            modified     => 0,
            ended        => 0,
        };
    };
}

sub _is_processed {
    my ($self, $process_id, $process_ordinal) = @_;
    my $eval_mapper = $self->{mapper} && $self->{mapper}->can_map_eval ? $self->{mapper} : undef;

    return 1 if !$eval_mapper;
    return $eval_mapper->is_processed($process_id, $process_ordinal);
}

sub _merge_genealogy {
    my ($self, $genealogy) = @_;

    for my $process_id (keys %$genealogy) {
        my $item = $genealogy->{$process_id};

        @{$self->{genealogy}{$process_id}}{keys %$item} = values %$item;
    }
}

sub _clone_genealogy {
    my ($self) = @_;
    my $genealogy = $self->{genealogy};
    my $res = {};

    for my $process_id (keys %$genealogy) {
        my $item = $genealogy->{$process_id};

        @{$res->{$process_id}}{keys %$item} = values %$item;
    }

    return $res;
}

sub _merge_last_sample {
    my ($self, $last_sample) = @_;

    for my $process_id (keys %$last_sample) {
        my $new = $last_sample->{$process_id};
        my $current = $self->{last_sample}{$process_id} // 0;

        $self->{last_sample}{$process_id} = $new > $current ? $new : $current;
    }
}

sub _all_data_files {
    my ($self, $parts, $kind) = @_;
    my (@merged);

    for my $shard ($self->{shard} ? ($self->{shard}) : @{$self->{shards}}) {
        my $info = {root_dir => $self->{root_dir}, shard => $shard};
        my $merged = state_file($info, 0, $kind);
        push @merged, (-f $merged ? $merged : ());
    }
    my @parts = $parts ? bsd_glob state_file($self, 1, "*/$kind.*") : ();

    return (\@parts, \@merged);
}

sub _load_metadata {
    my ($self, $parts) = @_;
    my $metadata = $self->{metadata} = Devel::StatProfiler::Metadata->new(
        serializer     => $self->{serializer},
        root_directory => $self->{root_dir},
        shard          => $self->{shard},
    );
    my ($metadata_parts, $metadata_merged) = _all_data_files($self, $parts, 'metadata');

    $metadata->load_and_merge(@$metadata_merged, @$metadata_parts);
    push @{$self->{parts}}, @$metadata_parts;
}

sub _load_genealogy {
    my ($self, $parts) = @_;
    my ($genealogy_parts, $genealogy_merged) = _all_data_files($self, $parts, 'genealogy');

    $self->_merge_genealogy(read_data($self->{serializer}, $_))
        for @$genealogy_merged, @$genealogy_parts;

    push @{$self->{parts}}, @$genealogy_parts;
}

sub _load_last_sample {
    my ($self, $parts) = @_;
    my ($last_sample_parts, $last_sample_merged) = _all_data_files($self, $parts, 'last_sample');

    $self->_merge_last_sample(read_data($self->{serializer}, $_))
        for @$last_sample_merged, @$last_sample_parts;

    push @{$self->{parts}}, @$last_sample_parts;
}

sub _load_source {
    my ($self, $parts) = @_;
    my $source = $self->{source} = Devel::StatProfiler::EvalSource->new(
        serializer     => $self->{serializer},
        root_directory => $self->{root_dir},
        shard          => $self->{shard},
        genealogy      => $self->_clone_genealogy,
    );
    my ($source_parts, $source_merged) = _all_data_files($self, $parts, 'source');

    $source->load_and_merge(@$source_merged, @$source_parts);
    push @{$self->{parts}}, @$source_parts;
}

sub _load_sourcemap {
    my ($self, $parts) = @_;
    my $sourcemap = $self->{sourcemap} = Devel::StatProfiler::SourceMap->new(
        serializer     => $self->{serializer},
        root_directory => $self->{root_dir},
        shard          => $self->{shard},
    );
    my ($sourcemap_parts, $sourcemap_merged) = _all_data_files($self, $parts, 'sourcemap');

    $sourcemap->load_and_merge(@$sourcemap_merged, @$sourcemap_parts);
    push @{$self->{parts}}, @$sourcemap_parts;
}

sub _load_all_metadata {
    my ($self, $parts) = @_;

    return if $self->{genealogy} && %{$self->{genealogy}};

    $self->_load_metadata($parts);
    $self->_load_genealogy($parts);
    $self->_load_last_sample($parts);
    $self->_load_source($parts);
    $self->_load_sourcemap($parts);
}

sub merge_metadata {
    my ($self) = @_;

    $self->_load_all_metadata('parts');

    $self->{metadata}->save_merged;
    $self->{source}->save_merged;
    $self->{sourcemap}->save_merged;
    write_data($self, state_dir($self), 'last_sample', $self->{last_sample});
    # genealogy needs to be saved last, because can_process_trace_files
    # assumes that if there is the genealogy the rest has been saved
    write_data($self, state_dir($self), 'genealogy', $self->{genealogy});

    for my $part (@{$self->{parts}}) {
        unlink $part;
    }
}

sub merge_report {
    my ($self, $report_id, %args) = @_;

    $self->_load_all_metadata('parts') if $args{with_metadata};

    my $suffix = $self->_suffix;
    my @report_parts = bsd_glob File::Spec::Functions::catfile($self->{parts_dir}, $report_id, 'parts', '*', "report.*.$self->{shard}.*");
    my @metadata_parts = bsd_glob File::Spec::Functions::catfile($self->{parts_dir}, $report_id, 'parts', '*', "metadata.$self->{shard}.*");
    my $report_merged = File::Spec::Functions::catfile($self->{root_dir}, $report_id, "report.$suffix.$self->{shard}");
    my $metadata_merged = File::Spec::Functions::catfile($self->{root_dir}, $report_id, "metadata.$self->{shard}");

    my $res = $self->_fresh_report(mixed_process => 1);
    my $parts = $self->_fresh_report(mixed_process => 1);

    # TODO fix this incestuous relation
    $res->{source} = $self->{source};
    $res->{sourcemap} = $self->{sourcemap};
    $res->{genealogy} = $self->{genealogy};

    if (-f $report_merged) {
        my $report = $self->_fresh_report;

        $report->load($report_merged);
        $res->merge($report);
    }
    $res->remap_names(@{$args{remap}})
        if $args{remap} && $args{remap_again};
    for my $file (grep -f $_, @report_parts) {
        my $report = $self->_fresh_report;

        $report->load($file);
        $parts->merge($report);
    }
    $parts->remap_names(@{$args{remap}})
        if $args{remap};
    $res->merge($parts) if $parts->{tick};

    for my $file (grep -f $_, ($metadata_merged, @metadata_parts)) {
        $res->load_and_merge_metadata($file);
    }

    my $report_dir = File::Spec::Functions::catdir($self->{root_dir}, $report_id);
    $res->save_aggregate($report_dir);

    $res->add_metadata($self->global_metadata) if $args{with_metadata};

    for my $part (@report_parts, @metadata_parts) {
        unlink $part;
    }

    return $res;
}

sub _suffix {
    my ($self) = @_;

    return $self->{timebox} ? $self->{now} - $self->{now} % $self->{timebox} : 0;
}

sub _fresh_report {
    my ($self, %opts) = @_;

    return Devel::StatProfiler::Report->new(
        slowops        => $self->{slowops},
        flamegraph     => $self->{flamegraph},
        serializer     => $self->{serializer},
        sources        => 0,
        root_directory => $self->{root_dir},
        parts_directory=> $self->{parts_dir},
        shard          => $self->{shard},
        mixed_process  => $opts{mixed_process} // $self->{mixed_process},
        suffix         => $self->_suffix,
    );
}

sub add_report_metadata {
    my ($self, $report_id, $metadata) = @_;

    my $report_dir = File::Spec::Functions::catdir($self->{parts_dir}, $report_id, 'parts');
    my $report_metadata = Devel::StatProfiler::Metadata->new(
        serializer     => $self->{serializer},
        root_directory => $self->{root_dir},
        shard          => $self->{shard},
    );
    $report_metadata->add_entries($metadata);
    $report_metadata->save_report_part($report_dir);
}

sub global_metadata {
    my ($self) = @_;

    return $self->{metadata}->get;
}

sub add_global_metadata {
    my ($self, $metadata) = @_;

    $self->{metadata}->add_entry($_, $metadata->{$_}) for keys %$metadata;
}

sub handle_section_change {
    my ($self, $sc, $state) = @_;

    return $MAIN_REPORT_ID;
}

# temporary during refactoring
*all_unmerged_reports = \&Devel::StatProfiler::Aggregate::all_unmerged_reports;
*_all_reports = \&Devel::StatProfiler::Aggregate::_all_reports;

1;
