#!/usr/bin/env perl
use strict;
use warnings;
use Test::More tests => 2;

BEGIN {
    use_ok 'IO::Multiplex::Intermediary';
    use_ok 'IO::Multiplex::Intermediary::Client';
}

