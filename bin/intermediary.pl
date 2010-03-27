#!/usr/bin/env perl
use strict;
use warnings;
use IO::Multiplex::Intermediary;

my $mud = IO::Multiplex::Intermediary->new;

$mud->run;
