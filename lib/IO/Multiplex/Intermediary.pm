#!/usr/bin/env perl
package IO::Multiplex::Intermediary;

our $VERSION = "0.05";

use Moose;
use namespace::autoclean;

use AnyEvent::Socket;
use AnyEvent::Handle;
use JSON;
use List::Util qw(first);
use List::MoreUtils qw(any);
use Scalar::Util qw(reftype weaken);
use Data::UUID::LibUUID;

has handles => (
    is => 'rw',
    isa => 'HashRef[AnyEvent::Handle]',
    default => sub { +{} },
);

has external_port => (
    is  => 'ro',
    isa => 'Int',
    default => 6715
);

has client_handle => (
    is      => 'rw',
    isa     => 'AnyEvent::Handle',
    clearer => '_clear_client_handle',
);

has client_port => (
    is  => 'ro',
    isa => 'Int',
    default => 9000
);

has socket_info => (
    is  => 'rw',
    isa => 'HashRef[Int]',
    default => sub { +{} },
);

has _internal_guard => (
    is  => 'rw',
    isa => 'Any',
);

has _external_guard => (
    is  => 'rw',
    isa => 'Any',
);

has pending_transactions => (
    is  => 'rw',
    isa => 'HashRef',
    default => sub { +{} },
);

has processed_transactions => (
    is  => 'rw',
    isa => 'HashRef[Str]',
    default => sub { +{} },
);

has _condvar => (
    is => 'ro',
    default => sub { AnyEvent->condvar },
);

sub BUILD {
    my $self = shift;

    my $json = JSON->new;
    weaken( my $weakself = $self );
    my $eguard = tcp_server undef, 6715, sub {
        my ($fh, $host, $port) = @_;
        my $uuid = new_uuid_string();
        my $handle = AnyEvent::Handle->new(
            fh => $fh,
            on_error => sub {
                my ($h, $fatal, $error) = @_;

                warn $error;
                $h->destroy if $fatal;
                $weakself->_disconnect( $weakself->id_lookup($h) );
            },
            on_read => sub {
                my $h = shift;
                $h->push_read(
                    line => sub {
                        my $h = shift;
                        my $input = shift;
                        if ($weakself->client_handle) {
                            my $data = +{
                                param => 'input',
                                data => {
                                    id    => $uuid,
                                    value => $input,
                                }
                            };

                            $weakself->send_to_client($data);
                        }
                        else {
                            $weakself->no_client_hook($h);
                        }
                    }
                );
            },
        );

        $weakself->_connect($uuid => $handle);
    };

    my $iguard = tcp_server undef, 9000, sub {
        my ($fh, $host, $port) = @_;
        if ($weakself->client_handle) {
            close $fh;
            return;
        }

        my $h = AnyEvent::Handle->new(
            fh       => $fh,
            on_error => sub {
                my ($fh, $fatal, $error) = @_;

                warn $error;
                $fh->destroy if $fatal;
                $weakself->_clear_client_handle();

            },
            on_read  => sub {
                my $h = shift;
                $h->push_read(
                    json => sub {
                        my $handle    = shift;
                        my $structure = shift;
                        my @elements = reftype $structure eq 'ARRAY'
                                     ? @$structure
                                     : ($structure);

                        foreach my $element (@elements) {

                            $weakself->_process_structure($element);
                        }
                    }
                );
            },
        );

        $weakself->client_handle($h);
        $weakself->client_connect;
    };

    # make scope of servers end at package destruction
    $self->_internal_guard($iguard);
    $self->_external_guard($eguard);
}

sub no_client_hook {
    my $self = shift;
    my $handle = shift;
    #$handle->push_write("The MUD is down! etc\015\012");
}

#TODO send backup info
sub client_connect {
    my $self = shift;

    my @structures = map {
        +{
            param => 'connect',
            data => {
                id => $_
            },
            txn_id => new_uuid_string(),
        }
    } keys %{ $self->handles };

    $self->multisend(@structures);
}

sub _connect {
    my $self   = shift;
    my $id     = shift;
    my $handle = shift;

    $self->handles->{$id} = $handle;

    $self->send_to_client(
        {
            param => 'connect',
            data  => {
                id => $id,
            }
        }
    );
}

sub _input {
    my $self  = shift;
    my $id    = shift;
    my $input = shift;

    $input =~ s/[\r\n]*$//;

    $self->send_to_client(
        {
            param => 'input',
            data => {
                id    => $id,
                value => $input,
            }
        }
    );
}

sub _process_structure {
    my $self      = shift;
    my $structure = shift;

    #warn Dumper($structure);
    if (!exists $structure->{param}) {
        warn "Invalid JSON structure!";
    }
    else {
        return if     $structure->{param} eq 'null';
        return unless $structure->{data}{id};
        return unless reftype($self->handles);
        return unless $self->handles->{ $structure->{data}{id} };

        my $txn_id   = $structure->{txn_id} or die "txn ID is required";
        my $dep_txns = $structure->{dep_txns} || [];
        my $id       = $structure->{data}{id};

        TXN: {
            #warn "processing: $structure->{data}{value}" if $structure->{data}{value};
            if ($self->check_dep_txns($txn_id, @$dep_txns)) {
                # warn "$structure->{data}{value} has pending deps";
                # pend txn and nothing else
                $self->pending_transactions->{$id}{$txn_id} = $structure;
                return;
            }

            $self->_process_transaction($structure);

            if (my $txns = $self->pending_transactions->{$id}) {
                foreach my $txn_id (keys %$txns) {
                    $structure = $txns->{$txn_id};
                    #warn "check pended $structure->{data}{value}";
                    if (
                    !$self->check_dep_txns(
                        $txn_id,
                        @{$structure->{dep_txns}}
                    )
                    ) {
                        delete $self->pending_transactions->{$id}{$txn_id};
                        redo TXN;
                    }
                }
            }
        }
    }
}

sub check_dep_txns {
    my $self = shift;
    my $txn_id = shift;
    my @dep_txns = @_;

    my @pt = keys %{ $self->processed_transactions || {} };
    # there are any deps?
    return 0 unless @dep_txns; #nothing depends on it
    # any deps already processed?
    return 1 if any { !$self->processed_transactions->{$_} } @dep_txns;
    # no processed deps
    return 0;
}

sub _process_transaction {
        my $self      = shift;
        my $structure = shift;

        my $id       = $structure->{data}{id};

        if ($structure->{param} eq 'output') {
            warn "output";
            $self->handles->{$id}->push_write( $structure->{data}{value} );
            if ($structure->{updates}) {
                foreach my $key  (%{ $structure->{updates} }) {
                    my $value = $structure->{updates}{$key};
                    $self->socket_info->{$id}{$key} = $value
                }
            }
        }
        elsif ($structure->{param} eq 'disconnect') {
            my $id = $structure->{data}->{id};
            $self->handles->{$id}->push_shutdown;
        }

        $self->processed_transactions->{ $structure->{txn_id} } = 1;
}

sub _disconnect {
    my $self   = shift;
    my $id     = shift;
    delete $self->handles->{$id};

    $self->send_to_client(
        {
            param => 'disconnect',
            data => {
                id => $id,
            }
        }
    );
}

sub send {
    my $self = shift;
    my $id = shift;
    my $data = shift;

    warn "handle $id doesn't exist", return unless $self->hanles->{$id};
    $self->handles->{$id}->push_write(json => $data);
}

sub multisend {
    my $self = shift;
    my @refs  = @_;

    return unless $self->client_handle;
    $self->client_handle->push_write(json => \@refs);
}

sub send_to_client {
    my $self   = shift;
    my $data   = shift;

    $data->{txn_id} ||= new_uuid_string();

    return unless defined $self->client_handle;
    $self->client_handle->push_write(json => $data);
}

sub id_lookup {
    my $self   = shift;
    my $handle = shift;

    return
        first { $self->handles->{$_} == $handle }
            keys %{ $self->handles };
}

sub run {
    my $self = shift;
    $self->_condvar->wait;
}


__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 NAME

IO::Multiplex::Intermediary - multiplexing with fault tolerance

=head1 SYNOPSIS

    use IO::Multiplex::Intermediary;

    my $intermediary = IO::Multiplex::Intermediary->new;

    $intermediary->run;

=head1 DESCRIPTION

B<WARNING! THIS MODULE HAS BEEN DEEMED ALPHA BY THE AUTHOR. THE API
MAY CHANGE IN SUBSEQUENT VERSIONS.>

This library is for users who want to optimize user experience. It
keeps the external connection operations and application operations
separate as separate processes, so that if the application crashes.

The core is robust in its simplicity. The library is meant for your
application to extend the L<IO::Multiplex::Intermediary::Client>
module that ships with this distribution and use its hooks. If the
application crashes, the end users on the external side will not
be disconnected. When the controller reconnects, the users will be
welcomed back to the real interaction in any way that the developer
who extends this module sees fit.

The intermediary opens two ports: one for end users to connect to,
and one for the application to connect to. The intermediary server
and client use JSON to communicate with each other. Here is an example
of the life cycle of the intermediary and application:

            User land       |  Intermediary      |  Application
                            |                    |
            Connect         |                    |
                            |  Accept user       |
                            |  connection        |
                            |                    |
                            |  Send the          |
                            |  connection        |
                            |  action to         |
                            |   the app          |
                            |                    |  Receive
                            |                    |  connection
                            |                    |
                            |                    |  Track any
                            |                    |  user data
                            |                    |
            User sends      |                    |
            something       |                    |
                            | Read the message   |
                            |                    |
                            | Send the message   |
                            | to the app         |
                            |                    |  Read the message
                            |                    |
                            |                    |  Process the message
                            |                    |  (build_response)
                            |                    |
                            |                    |  Send the response
                            |  Get the response  |
                            |                    |
                            |  Send the response |
                            |  to the appropriate|
                            |  user              |
           Disconnect       |                    |
                            |  Send the discon.  |
                            |  message to the    |
                            |  intermediary      |
                            |                    |  Become aware of
                            |                    |  the disconnect
                            |                    |  and act
                            |                    |  accordingly

=head1 EXAMPLES

B<NOTE>: Examples are in the examples/ directory supplied with the
distribution.

=head1 PARAMETERS FOR C<new>

=over

=item C<external_port>

This is the port that the end users will use to access the application.
If it is not specified, the default is 6715.

=item C<client_port>

This is the port that intermediary will use to communicate internally
with the application.

=head1 METHODS

=over

=item C<send($id, $data)>

Sends C<$data> (string format) to the socket that belongs to C<$id>

=back

=head1 HOOKS

These methods are NOT for complete overriding. They do important
things that involve communication with the client. They are here
so that you can hook I<around> these methods in any way you see fit.

=over

=item C<client_connect>

Method called when the client connects to the intermediary

=item C<client_input>

Method called when the client sends data to the intermediary

=item C<client_disconnect>

Method called when the client disconnects from the intermediary

=item C<connect>

Method called when a user connects to the intermediary

=item C<input>

Method called when a user sends data to the intermediary

=item C<disconnect>

Method called when a user disconnects from the intermediary

=back

=head1 SEE ALSO

=over

=item L<IO::Multiplex>

=back

=head1 AUTHOR

Jason May <jason.a.may@gmail.com>

=head1 LICENSE

This library is free software and may be distributed under the same
terms as perl itself.

=cut
