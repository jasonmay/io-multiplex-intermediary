#!/usr/bin/env perl
use strict;
use warnings;
use IO::Multiplex::Intermediary;

my $intermediary = IO::Multiplex::Intermediary->new(
    external_port => (@ARGV ? $ARGV[0] : 6715),
);

$intermediary->run;
