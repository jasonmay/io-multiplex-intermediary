#!/usr/bin/env perl
use strict;
use warnings;
use IO::Multiplex::Intermediary;

my $intermediary = IO::Multiplex::Intermediary->new;

$intermediary->run;
