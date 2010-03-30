#!/usr/bin/env perl
use strict;
use warnings;
use Test::More tests => 15;

BEGIN {
    use_ok 'IO::Multiplex::Intermediary';
    use_ok 'IO::Multiplex::Intermediary::Client';
}

# ::Intermediary methods
can_ok ('IO::Multiplex::Intermediary', 'client_connect_event');
can_ok ('IO::Multiplex::Intermediary', 'client_input_event');
can_ok ('IO::Multiplex::Intermediary', 'client_disconnect_event');

can_ok ('IO::Multiplex::Intermediary', 'connect_event');
can_ok ('IO::Multiplex::Intermediary', 'input_event');
can_ok ('IO::Multiplex::Intermediary', 'disconnect_event');

can_ok ('IO::Multiplex::Intermediary', 'send');

# ::Intermediary::Client methods
can_ok ('IO::Multiplex::Intermediary::Client', 'run');

can_ok ('IO::Multiplex::Intermediary::Client', 'build_response');

can_ok ('IO::Multiplex::Intermediary::Client', 'connect_hook');
can_ok ('IO::Multiplex::Intermediary::Client', 'input_hook');
can_ok ('IO::Multiplex::Intermediary::Client', 'disconnect_hook');

can_ok ('IO::Multiplex::Intermediary::Client', 'send');
