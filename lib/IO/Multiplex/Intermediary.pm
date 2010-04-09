#!/usr/bin/env perl
package IO::Multiplex::Intermediary;

our $VERSION = "0.02";

use Moose;
use namespace::autoclean;

use List::Util      qw(first);
use List::MoreUtils qw(any);
use IO::Socket;
use IO::Select;
use Data::UUID;
use Time::HiRes qw(gettimeofday);
use JSON;

has read_set => (
    is         => 'ro',
    isa        => 'IO::Select',
    lazy_build => 1,
);

sub _build_read_set {
    my $self = shift;
    my $select = IO::Select->new($self->external_handle);
    $select->add($self->client_handle);
    return $select;
}

has filehandles => (
    is      => 'ro',
    isa     => 'HashRef[IO::Socket::INET]',
    default => sub { +{} },
);

has external_handle => (
    is         => 'ro',
    isa        => 'IO::Socket::INET',
    lazy_build => 1,
);

sub _build_external_handle {
    my $self   = shift;
    my $socket = IO::Socket::INET->new(
        LocalPort => $self->external_port,
        Proto     => 'tcp',
        Listen    => 5,
        Reuse     => 1,
    ) or die $!;
    $socket->autoflush(1);
    return $socket;
}

has external_port => (
    is  => 'ro',
    isa => 'Int',
    default => 6715
);

has client_handle => (
    is         => 'rw',
    isa        => 'Maybe[IO::Socket::INET]',
    lazy_build => 1,
);

sub _build_client_handle {
    my $self = shift;

    my $socket = IO::Socket::INET->new(
        LocalPort => $self->client_port,
        Proto     => 'tcp',
        Listen    => 5,
        Reuse     => 1,
    );
    $socket->autoflush(1);

    return $socket;
}

has client_socket => (
    is         => 'rw',
    isa        => 'Maybe[IO::Socket::INET]',
    clearer    => '_clear_client_socket',
);

has client_port => (
    is  => 'ro',
    isa => 'Int',
    default => 9000
);

has socket_info => (
    is  => 'rw',
    isa => 'HashRef',
    default => sub { +{} },
);

sub id_lookup {
    my $self = shift;
    my $fh   = shift;

    return first { $self->filehandles->{$_} == $fh }
           keys %{ $self->filehandles };
}

#TODO send backup info
sub client_connect_event {
    my $self = shift;

    if ( scalar(%{$self->filehandles}) ) {
        foreach my $id (keys %{ $self->filehandles }) {
            $self->send_to_client(
                {
                    param => 'connect',
                    data  => {
                        id    => $id,
                    }
                }
            );
        }
    }
}

{
    my $du = Data::UUID->new;
    sub connect_event {
        my $self = shift;
        my $fh = shift;

        my $id = $du->create_str;
        $self->filehandles->{$id} = $fh;

        return unless $self->client_socket;

        if ($fh == $self->client_socket) {
            $self->client_connection;
            return;
        }


        my $data = {
            param => 'connect',
            data  => {
                id    => $id,
            }
        };
        $self->send_to_client($data);
    }
}

sub input_event {
    my $self  = shift;
    my $fh    = shift;
    my $input = shift;

    my $data = {
        param => 'input',
        data => {
            id    => $self->id_lookup($fh),
            value => $input,
        },
    };
    $self->send_to_client($data);
}

sub client_input_event {
    my $self = shift;
    my $input = shift;
    chomp($input);
    return unless $input;
    my $json = eval { from_json($input) };

    {
        if ($@ || !$json) {
            warn $input;
            warn "JSON error: $@";
        }
        elsif (!exists $json->{param}) {
            warn "Invalid JSON structure!";
        }
        else {
            last unless my $id = $json->{data}{id};
            last unless ref $self->filehandles;
            last unless $self->filehandles->{$id};

            if ($json->{param} eq 'output') {
                eval { $self->filehandles->{$id}->send($json->{data}{value}) }
                    or last;
                if ($json->{updates}) {
                    foreach my $key  (%{ $json->{updates} }) {
                        my $value = $json->{updates}{$key};
                        $self->socket_info->{$id}{$key} = $value
                    }
                }
            }
            elsif ($json->{param} eq 'disconnect') {
                my $id = $json->{data}{id};
                $self->filehandles->{$id}->close;
            }
        }
    }
}

sub disconnect_event {
    my $self = shift;
    my $fh   = shift;

    $self->send_to_client(
        {
            param => 'disconnect',
            data => {
                id => $self->id_lookup($fh),
            }
        }
    );
}

sub client_disconnect_event {
    my $self = shift;
}

sub send {
    my $self = shift;
    my $id = shift;
    my $data = shift;

    $self->filehandles->{$id}->send( to_json($data) );
}

sub send_to_client {
    my $self   = shift;
    my $data   = shift;

    return unless $self->client_socket;
    my $output = to_json $data;
    #warn "[I Sends]: $output";
    $self->client_socket->send("$output\n\e");
}

sub cycle {
    my $self = shift;

    CYCLE: foreach my $fh ($self->read_set->can_read) {
        #warn "begin loop";
        next unless $self->external_handle;
        next unless $self->client_handle;

        if ($fh == $self->external_handle) {
            my $socket = $fh->accept();
            $self->read_set->add($socket);
            $self->connect_event($socket);
        }
        elsif ($fh == $self->client_handle) {
            if ($self->client_socket) {
                $fh->accept->close;
            }
            else {
                $self->client_socket( $fh->accept() );
                $self->read_set->add($self->client_socket);
                $self->client_connect_event($self->client_socket);
            }
        }
        else {
            if(my $buf = <$fh>) {
                #my $buf = <$fh>;
                next unless $self->client_socket;
                $buf =~ s/[\r\n]+$//s;
                #warn "!!!!\n\n$buf\n\n!!!";
                if ($fh == $self->client_socket) {
                    my @packets = grep { $_ } split m[\e], $buf;
                    $self->client_input_event($_) for @packets;
                }
                else {
                    $self->input_event($fh, $buf);
                }
                #jwarn "redo";
                #jredo CYCLE;
            }
            else {
                if ($self->client_socket && $fh == $self->client_socket) {
                    $self->client_disconnect_event($fh);
                    $self->_clear_client_socket;
                }
                else {
                    $self->disconnect_event($fh);
                    $self->read_set->remove($fh);
                    delete $self->filehandles->{$fh};
                }
            }
        }
    }

    return 1;
}

sub run {
    my $self = shift;
    1 while $self->cycle;
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

=item C<client_connect_event>

Method called when the client connects to the intermediary

=item C<client_input_event>

Method called when the client sends data to the intermediary

=item C<client_disconnect_event>

Method called when the client disconnects from the intermediary

=item C<connect_event>

Method called when a user connects to the intermediary

=item C<input_event>

Method called when a user sends data to the intermediary

=item C<disconnect_event>

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
