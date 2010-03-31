use inc::Module::Install 0.91;

name           'IO-Multiplex-Intermediary';
perl_version   '5.008001';
all_from       'lib/IO/Multiplex/Intermediary.pm';
license        'perl';

requires 'Moose';
requires 'namespace::autoclean';
requires 'IO::Socket::INET';
requires 'IO::Select';
requires 'List::Util';
requires 'List::MoreUtils';
requires 'Scalar::Util';
requires 'Data::UUID';
requires 'Time::HiRes';
requires 'JSON';

test_requires 'Test::More';

install_script 'bin/intermediary.pl';

WriteAll;
