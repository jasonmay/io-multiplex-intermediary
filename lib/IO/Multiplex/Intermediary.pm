#!/usr/bin/env perl
package IO::Multiplex::Intermediary;
use Moose;
use namespace::autoclean;

use List::Util      qw(first);
use List::MoreUtils qw(any);
use Scalar::Util    qw(reftype);
use IO::Socket;
use IO::Multiplex;
use Data::UUID;
use JSON;

has mux => (
    is         => 'ro',
    isa        => 'IO::Multiplex',
    lazy_build => 1,
);

has filehandles => (
    is      => 'ro',
    isa     => 'HashRef[IO::Socket::INET]',
    default => sub { +{} },
);

has listener => (
    is         => 'ro',
    isa        => 'IO::Socket::INET',
    lazy_build => 1,
);

sub _build_listener {
    my $self   = shift;
    warn "foooioo";
    my $socket = IO::Socket::INET->new(
        LocalPort => $self->external_port,
        Proto     => 'tcp',
        Listen    => 5,
        Reuse     => 1,
    ) or die $!;
    warn $socket;
    return $socket;
}

sub id_lookup {
    my $self = shift;
    my $fh   = shift;

    return first { $self->filehandles->{$_} == $fh }
           keys %{ $self->filehandles };
}

sub _build_mux {
    my $self   = shift;
    my $mux    = IO::Multiplex->new;

    my $socket = IO::Socket::INET->new(
        LocalPort => $self->external_port,
        Proto     => 'tcp',
        Listen    => 5,
        Reuse     => 1,
    );

    $mux->listen($socket);
    $mux->set_callback_object($self);

    return $mux;
}

has external_port => (
    is  => 'ro',
    isa => 'Int',
    default => 6715
);

has client_handle => (
    is         => 'rw',
    isa        => 'IO::Socket::INET',
    lazy_build => 1,
);

sub _build_client_handle {
    my $self = shift;

    my $socket = IO::Socket::INET->new(
        LocalPort => $self->client_port,
        Proto     => 'tcp',
        Listen    => 5,
    );

    $self->mux->listen($socket);
    return $socket;
}

has client_port => (
    is  => 'ro',
    isa => 'Int',
    default => 9000
);

has client_connected => (
    is  => 'rw',
    isa => 'Bool',
    default => 0
);

has socket_info => (
    is  => 'rw',
    isa => 'HashRef[Int]',
    default => sub { +{} },
);

#TODO send backup info
sub client_connection {
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
    sub mux_connection {
        my $self = shift;
        my $mux = shift;
        my $fh = shift;
        warn "foo";

        if ($fh == $self->client_handle) {
            $self->client_connection;
            return;
        }

        my $id = $du->create_str;

        $self->filehandles->{$id} = $fh;

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

sub mux_input {
    my $self  = shift;
    my $mux   = shift;
    my $fh    = shift;
    my $input = shift;

    warn "foo";
    if ($fh == $self->client_handle) {
        $self->client_input($$input);
        return;
    }

    $self->send_to_client(
        {
            param => 'input',
            data => {
                id    => ,
                value => $$input,
            }
        }
    );
}

sub client_input {
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
                print { $self->filehandles->{ $json->{data}->{id} } } $json->{data}->{value};
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

sub mux_eof {
    my $self = shift;
    my $mux  = shift;
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

sub mux_timeout {
    my $self = shift;
    my $mux = shift;
}

sub send {
    my $self = shift;
    my $id = shift;
    my $data = shift;

    print { $self->filehandles->{$id} } to_json($data);
}

sub send_to_client {
    my $self   = shift;
    my $data   = shift;

    return unless defined $self->client_handle;
    print { $self->client_handle } to_json($data);
}

sub run {
    my $self = shift;
    $self->mux->loop;
}

sub DEMOLISH {
    my $self = shift;
    $self->listener->shutdown;
    $self->mux->close($self->listener);
    $self->mux->endloop;
}

__PACKAGE__->meta->make_immutable;

1;
