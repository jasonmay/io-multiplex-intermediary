#!/usr/bin/env perl
use strict;
use warnings;
use Test::More tests => 1;

BEGIN {
    use_ok 'IO::Multiplex::Intermediary';
    use_ok 'IO::Multiplex::Intermediary::Client';
}

