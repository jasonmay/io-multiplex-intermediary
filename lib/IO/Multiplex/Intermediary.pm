#!/usr/bin/env perl
package IO::Multiplex::Intermediary;
use Moose;
use namespace::autoclean;

use List::Util      qw(first);
use List::MoreUtils qw(any);
use Scalar::Util    qw(reftype);
use IO::Socket;
use IO::Select;
use Data::UUID;
use Data::Dumper;
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

        if ($self->client_socket && $fh == $self->client_socket) {
            $self->client_connection;
            return;
        }

        my $id = $du->create_str;

        $self->filehandles->{$id} = $fh;

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
    my $json = eval { from_json($input) };

    {
        if ($@ || !$json) {
            warn "JSON error: $@";
        }
        elsif (!exists $json->{param}) {
            warn "Invalid JSON structure!";
        }
        else {
            last unless $json->{data}->{id};
            last unless reftype($self->filehandles);
            last unless $self->filehandles->{ $json->{data}->{id} };

            if ($json->{param} eq 'output') {
                $self->filehandles->{ $json->{data}->{id} }->send($json->{data}->{value});
                if ($json->{updates}) {
                    foreach my $key  (%{ $json->{updates} }) {
                        my $value = $json->{updates}->{$key};
                        $self->socket_info->{ $json->{data}->{id} }->{ $key } = $value
                    }
                }
            }
            elsif ($json->{param} eq 'disconnect') {
                my $id = $json->{data}->{id};
                $self->filehandles->{$id}->shutdown_output;
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
    $self->client_socket->send(to_json($data) . "\n");
}

sub cycle {
    my $self = shift;
    my ($fh_set) = IO::Select->select($self->read_set, undef, undef, 0);

    foreach my $fh (@$fh_set) {
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
            if( my $buf = <$fh> ) {
                $buf =~ s/[\r\n]+$//;
                if ($fh == $self->client_socket) {
                    $self->client_input_event($buf);
                }
                else {
                    $self->input_event($fh, $buf);
                }
            }
            else {
                $self->read_set->remove($fh);
                if ($self->client_socket && $fh == $self->client_socket) {
                    $self->client_disconnect_event($fh);
                    $self->_clear_client_socket;
                }
                else {
                    $self->disconnect_event($fh);
                }
                close($fh);
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
